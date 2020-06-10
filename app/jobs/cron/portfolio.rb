module Jobs::Cron
  class Portfolio
    Error = Class.new(StandardError)

    class <<self
      def max_liability(portfolio_currency)
        res = ::Portfolio.where(portfolio_currency_id: portfolio_currency).maximum('last_liability_id')
        res.present? ? res : 0
      end

      def portfolio_currencies
        ENV.fetch('PORTFOLIO_CURRENCIES', '').split(',')
      end

      def conversion_market(currency, portfolio_currency)
        market = Market.find_by(base_unit: currency, quote_unit: portfolio_currency)
        raise Error, "There is no market #{currency}#{portfolio_currency}" unless market.present?

        market.id
      end

      def price_at(portfolio_currency, currency, at)
        return 1.0 if portfolio_currency == currency

        market = conversion_market(currency, portfolio_currency)
        nearest_trade = Trade.nearest_trade_from_influx(market, at)
        Rails.logger.info { "Nearest trade on #{market} trade: #{nearest_trade}" }
        raise Error, "There is no trades on market #{market}" unless nearest_trade.present?

        nearest_trade[:price]
      end

      def process_order(portfolio_currency, liability_id, trade, order)
        queries = []
        Rails.logger.info { "Process order: #{order.id}" }
        if order.side == 'buy'
          total_credit_fees = trade.amount * trade.order_fee(order)
          total_credit = trade.amount - total_credit_fees
          total_debit = trade.total
        else
          total_credit_fees = trade.total * trade.order_fee(order)
          total_credit = trade.total - total_credit_fees
          total_debit = trade.amount
        end

        if trade.market.quote_unit == portfolio_currency
          income_currency_id = order.income_currency.id
          order.side == 'buy' ? total_credit_value = total_credit * trade.price : total_credit_value = total_credit
          queries << build_query(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          order.side == 'buy' ? total_debit_value = total_debit : total_debit_value = total_debit * trade.price
          queries << build_query(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        else
          income_currency_id = order.income_currency.id
          total_credit_value = (total_credit) * price_at(portfolio_currency, income_currency_id, trade.created_at)
          queries << build_query(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          total_debit_value = (total_debit) * price_at(portfolio_currency, outcome_currency_id, trade.created_at)
          queries << build_query(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        end

        queries
      end

      def process_deposit(portfolio_currency, liability_id, deposit)
        Rails.logger.info { "Process deposit: #{deposit.id}" }
        total_credit = deposit.amount
        total_credit_fees = deposit.fee
        total_credit_value = total_credit * price_at(portfolio_currency, deposit.currency_id, deposit.created_at)
        build_query(deposit.member_id, portfolio_currency, deposit.currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)
      end

      def process_withdraw(portfolio_currency, liability_id, withdraw)
        Rails.logger.info { "Process withdraw: #{withdraw.id}" }
        total_debit = withdraw.amount
        total_debit_fees = withdraw.fee
        total_debit_value = (total_debit + total_debit_fees) * price_at(portfolio_currency, withdraw.currency_id, withdraw.created_at)

        build_query(withdraw.member_id, portfolio_currency, withdraw.currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, total_debit_fees)
      end

      def process
        l_count = 0
        portfolio_currencies.each do |portfolio_currency|
          begin
            l_count += process_currency(portfolio_currency)
          rescue StandardError => e
            Rails.logger.error("Failed to process currency #{portfolio_currency}: #{e}: #{e.backtrace.join("\n")}")
          end
        end

        sleep 2 if l_count == 0
      end

      def process_currency(portfolio_currency)
        l_count = 0
        queries = []
        liability_pointer = max_liability(portfolio_currency)
        # We use MIN function here instead of ANY_VALUE to be compatible with many MySQL versions
        ActiveRecord::Base.connection
          .select_all("SELECT MAX(id) id, MIN(reference_type) reference_type, MIN(reference_id) reference_id " \
                      "FROM liabilities WHERE id > #{liability_pointer} " \
                      "AND ((reference_type IN ('Trade','Deposit','Adjustment') AND code IN (201,202)) " \
                      "OR (reference_type IN ('Withdraw') AND code IN (211,212))) " \
                      "GROUP BY reference_id ORDER BY MAX(id) ASC LIMIT 10000")
          .each do |liability|
            l_count += 1
            Rails.logger.info { "Process liability: #{liability['id']}" }

            case liability['reference_type']
              when 'Deposit'
                deposit = Deposit.find(liability['reference_id'])
                queries << process_deposit(portfolio_currency, liability['id'], deposit)
              when 'Trade'
                trade = Trade.find(liability['reference_id'])
                queries += process_order(portfolio_currency, liability['id'], trade, trade.maker_order)
                queries += process_order(portfolio_currency, liability['id'], trade, trade.taker_order)
              when 'Withdraw'
                withdraw = Withdraw.find(liability['reference_id'])
                queries << process_withdraw(portfolio_currency, liability['id'], withdraw)
            end
        end

        transfers = {}
        liabilities = ActiveRecord::Base.connection
        .select_all("SELECT MAX(id) id, currency_id, member_id, reference_type, reference_id, SUM(credit-debit) as total FROM liabilities "\
                    "WHERE reference_type = 'Transfer' AND id > #{liability_pointer} "\
                    "GROUP BY currency_id, member_id, reference_type, reference_id")

        liabilities.each do |l|
          next if l['total'].zero?

          l_count += 1
          ref = l['reference_id']
          cid = l['currency_id']
          transfers[ref] ||= {}
          transfers[ref][cid] ||= {
            type: nil,
            liabilities: []
          }

          transfers[ref][cid][:liabilities] << l
        end

        transfers.each do |ref, transfer|
          case transfer.size # number of currencies in the transfer
          when 1
            # Probably a lock transfer, ignoring

          when 2
            # We have 2 currencies exchanges, so we can integrate those numbers in acquisition cost calculation
            store = Hash.new do |member_store, mid|
              member_store[mid] = Hash.new do |h, k|
                h[k] = {
                  total_debit_fees: 0,
                  total_credit_fees: 0,
                  total_credit: 0,
                  total_debit: 0,
                  total_amount: 0,
                  liability_id: 0
                }
              end
            end

            transfer.each do |cid, infos|
              Operations::Revenue.where(reference_type: 'Transfer', reference_id: ref, currency_id: cid).each do |fee|
                store[fee.member_id][cid][:total_debit_fees] += fee.credit
                store[fee.member_id][cid][:total_debit] -= fee.credit
                # We don't support fees payed on credit, they are all considered debit fees
              end

              infos[:liabilities].each do |l|
                store[l['member_id']] ||= {}
                store[l['member_id']][cid]

                if l['total'].positive?
                  store[l['member_id']][cid][:total_credit] += l['total']
                  store[l['member_id']][cid][:total_amount] += l['total']
                else
                  store[l['member_id']][cid][:total_debit] -= l['total']
                  store[l['member_id']][cid][:total_amount] -= l['total']
                end
                store[l['member_id']][cid][:liability_id] = l['id'] if store[l['member_id']][cid][:liability_id] < l['id']
              end
            end

            def price_of_transfer(a_total, b_total)
              b_total / a_total
            end

            store.each do |member_id, stats|
              a, b = stats.keys

              if a == portfolio_currency
                b, a = stats.keys
              elsif b != portfolio_currency
                raise 'Need direct conversion for transfers'
              end
              next if stats[b][:total_amount].zero?

              price = price_of_transfer(stats[a][:total_amount], stats[b][:total_amount])

              a_total_credit_value = stats[a][:total_credit] * price
              b_total_credit_value = stats[b][:total_credit]

              a_total_debit_value = stats[a][:total_debit] * price
              b_total_debit_value = stats[b][:total_debit]

              queries << build_query(member_id, portfolio_currency, a, stats[a][:total_credit], stats[a][:total_credit_fees], a_total_credit_value, stats[a][:liability_id], stats[a][:total_debit], a_total_debit_value, stats[a][:total_debit_fees])
              queries << build_query(member_id, portfolio_currency, b, stats[b][:total_credit], stats[b][:total_credit_fees], b_total_credit_value, stats[b][:liability_id], stats[b][:total_debit], b_total_debit_value, stats[b][:total_debit_fees])
            end

          else
            raise 'Transfers with more than 2 currencies brakes pnl calculation'
          end
        end

        update_portfolio(queries) unless queries.empty?

        l_count
      end

      def build_query(member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, total_debit, total_debit_value, total_debit_fees)
        "INSERT INTO portfolios (member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, last_liability_id, total_debit, total_debit_value, total_debit_fees, total_balance_value) " \
        "VALUES (#{member_id},'#{portfolio_currency_id}','#{currency_id}',#{total_credit},#{total_credit_fees},#{total_credit_value},#{liability_id},#{total_debit},#{total_debit_value},#{total_debit_fees},#{total_credit_value}) " \
        "ON DUPLICATE KEY UPDATE " \
        "total_credit = total_credit + VALUES(total_credit), " \
        "total_credit_fees = total_credit_fees + VALUES(total_credit_fees), " \
        "total_debit_fees = total_debit_fees + VALUES(total_debit_fees), " \
        "total_credit_value = total_credit_value + VALUES(total_credit_value), " \
        "total_debit_value = total_debit_value + VALUES(total_debit_value), " \
        "total_debit = total_debit + VALUES(total_debit), " \
        "total_balance_value = total_balance_value + VALUES(total_balance_value) - IF(total_credit = 0, 0, (#{total_debit+total_debit_fees}) * (total_credit_value / total_credit)), " \
        "updated_at = NOW(), " \
        "last_liability_id = VALUES(last_liability_id)"
      end

      def update_portfolio(queries)
        ActiveRecord::Base.connection.transaction do
          queries.each do |query|
            ActiveRecord::Base.connection.exec_query(query)
          end
        end
      end
    end
  end
end
