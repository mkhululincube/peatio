module Jobs::Cron
  class StatsMemberPnl
    Error = Class.new(StandardError)

    class <<self
      def max_liability(pnl_currency)
        res = ::StatsMemberPnl.where(pnl_currency_id: pnl_currency.id).maximum('last_liability_id')
        res.present? ? res : 0
      end

      def pnl_currencies
        @pnl_currencies ||= ENV.fetch('PNL_CURRENCIES', '').split(',').map {|id| Currency.find(id) }
      end

      def conversion_paths
        @conversion_paths ||= parse_conversion_paths(ENV.fetch('CONVERSION_PATHS', ''))
      end

      def parse_conversion_paths(str)
        paths = {}
        str.to_s.split(';').each do |path|
          raise 'Failed to parse CONVERSION_PATHS' if path.count(':') != 1

          mid, markets = path.split(':')
          raise 'Failed to parse CONVERSION_PATHS' if mid.empty? || mid.count('/') != 1

          paths[mid] = markets.split(',').map do |m|
            a, b = m.split('/')
            raise 'Failed to parse CONVERSION_PATHS' if a.to_s.empty? || b.to_s.empty?
            reverse = false
            if a.start_with?('_')
              reverse = true
              a = a[1..-1]
            end
            [a, b, reverse]
          end
        end
        paths
      end

      def conversion_market(currency_id, pnl_currency_id)
        market = Market.find_by(base_unit: currency_id, quote_unit: pnl_currency_id)
        raise Error, "There is no market #{currency_id}/#{pnl_currency_id}" unless market.present?

        market.id
      end

      def price_at(currency_id, pnl_currency_id, at)
        return 1.0 if currency_id == pnl_currency_id

        if (path = conversion_paths["#{currency_id}/#{pnl_currency_id}"])
          return path.reduce(1) do |price, (a, b, reverse)|
            if reverse
              price / price_at(a, b, at)
            else
              price * price_at(a, b, at)
            end
          end
        end

        market = conversion_market(currency_id, pnl_currency_id)
        nearest_trade = Trade.nearest_trade_from_influx(market, at)
        Rails.logger.debug { "Nearest trade on #{market} trade: #{nearest_trade}" }
        raise Error, "There is no trades on market #{market}" unless nearest_trade.present?

        nearest_trade[:price]
      end

      def process_order(pnl_currency, liability_id, trade, order)
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

        if trade.market.quote_unit == pnl_currency.id
          income_currency_id = order.income_currency.id
          order.side == 'buy' ? total_credit_value = total_credit * trade.price : total_credit_value = total_credit
          queries << build_query(order.member_id, pnl_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          order.side == 'buy' ? total_debit_value = total_debit : total_debit_value = total_debit * trade.price
          queries << build_query(order.member_id, pnl_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        else
          income_currency_id = order.income_currency.id
          total_credit_value = (total_credit) * price_at(income_currency_id, pnl_currency.id, trade.created_at)
          queries << build_query(order.member_id, pnl_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          total_debit_value = (total_debit) * price_at(outcome_currency_id, pnl_currency.id, trade.created_at)
          queries << build_query(order.member_id, pnl_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        end

        queries
      end

      def process_adjustment(pnl_currency, liability_id, adjustment)
        Rails.logger.info { "Process adjustment: #{adjustment.id}" }
        if adjustment.amount < 0
          total_credit = total_credit_value = 0
          total_debit = -adjustment.amount
          total_debit_value = total_debit * price_at(adjustment.currency_id, pnl_currency.id, adjustment.created_at)
        else
          total_debit = total_debit_value = 0
          total_credit = adjustment.amount
          total_credit_value = total_credit * price_at(adjustment.currency_id, pnl_currency.id, adjustment.created_at)
        end
        account_number_hash = Operations.split_account_number(account_number: adjustment.receiving_account_number)
        member = Member.find_by(uid: account_number_hash[:member_uid]) if account_number_hash.key?(:member_uid)
        build_query(member.id, pnl_currency, adjustment.currency_id, total_credit, 0.0, total_credit_value, liability_id, total_debit, total_debit_value, 0)
      end

      def process_deposit(pnl_currency, liability_id, deposit)
        Rails.logger.info { "Process deposit: #{deposit.id}" }
        total_credit = deposit.amount
        total_credit_fees = deposit.fee
        total_credit_value = total_credit * price_at(deposit.currency_id, pnl_currency.id, deposit.created_at)
        build_query(deposit.member_id, pnl_currency, deposit.currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)
      end

      def process_withdraw(pnl_currency, liability_id, withdraw)
        Rails.logger.info { "Process withdraw: #{withdraw.id}" }
        total_debit = withdraw.amount
        total_debit_fees = withdraw.fee
        total_debit_value = (total_debit + total_debit_fees) * price_at(withdraw.currency_id, pnl_currency.id, withdraw.created_at)

        build_query(withdraw.member_id, pnl_currency, withdraw.currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, total_debit_fees)
      end

      def process
        l_count = 0
        pnl_currencies.each do |pnl_currency|
          begin
            l_count += process_currency(pnl_currency)
          rescue StandardError => e
            Rails.logger.error("Failed to process currency #{pnl_currency.id}: #{e}: #{e.backtrace.join("\n")}")
          end
        end

        sleep 2 if l_count == 0
      end

      def process_currency(pnl_currency)
        l_count = 0
        batch_size = 1000
        queries = []
        liability_pointer = max_liability(pnl_currency)
        # We use MIN function here instead of ANY_VALUE to be compatible with many MySQL versions
        ActiveRecord::Base.connection
          .select_all("SELECT MAX(id) id, MIN(reference_type) reference_type, MIN(reference_id) reference_id " \
                      "FROM liabilities WHERE id > #{liability_pointer} " \
                      "AND ((reference_type IN ('Trade','Deposit','Adjustment') AND code IN (201,202)) " \
                      "OR (reference_type IN ('Withdraw') AND code IN (211,212))) " \
                      "GROUP BY reference_type, reference_id ORDER BY MAX(id) ASC LIMIT #{batch_size}")
          .each do |liability|
            l_count += 1
            Rails.logger.info { "Process liability: #{liability['id']} (#{liability['reference_type']})" }
            case liability['reference_type']
              when 'Adjustment'
                adjustment = Adjustment.find(liability['reference_id'])
                queries << process_adjustment(pnl_currency, liability['id'], adjustment)
              when 'Deposit'
                deposit = Deposit.find(liability['reference_id'])
                queries << process_deposit(pnl_currency, liability['id'], deposit)
              when 'Trade'
                trade = Trade.find(liability['reference_id'])
                queries += process_order(pnl_currency, liability['id'], trade, trade.maker_order)
                queries += process_order(pnl_currency, liability['id'], trade, trade.taker_order)
              when 'Withdraw'
                withdraw = Withdraw.find(liability['reference_id'])
                queries << process_withdraw(pnl_currency, liability['id'], withdraw)
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

              if a == pnl_currency.id
                b, a = stats.keys
              elsif b != pnl_currency.id
                raise 'Need direct conversion for transfers'
              end
              next if stats[b][:total_amount].zero?

              price = price_of_transfer(stats[a][:total_amount], stats[b][:total_amount])

              a_total_credit_value = stats[a][:total_credit] * price
              b_total_credit_value = stats[b][:total_credit]

              a_total_debit_value = stats[a][:total_debit] * price
              b_total_debit_value = stats[b][:total_debit]

              queries << build_query(member_id, pnl_currency, a, stats[a][:total_credit], stats[a][:total_credit_fees], a_total_credit_value, stats[a][:liability_id], stats[a][:total_debit], a_total_debit_value, stats[a][:total_debit_fees])
              queries << build_query(member_id, pnl_currency, b, stats[b][:total_credit], stats[b][:total_credit_fees], b_total_credit_value, stats[b][:liability_id], stats[b][:total_debit], b_total_debit_value, stats[b][:total_debit_fees])
            end

          else
            raise 'Transfers with more than 2 currencies brakes pnl calculation'
          end
        end

        update_pnl(queries) unless queries.empty?

        l_count
      end

      def build_query(member_id, pnl_currency, currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, total_debit, total_debit_value, total_debit_fees)
        average_balance_price = total_credit.zero? ? 0 : (total_credit_value / total_credit)
        'INSERT INTO stats_member_pnl (member_id, pnl_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, last_liability_id, total_debit, total_debit_value, total_debit_fees, total_balance_value, average_balance_price) ' \
        "VALUES (#{member_id},'#{pnl_currency.id}','#{currency_id}',#{total_credit},#{total_credit_fees},#{total_credit_value},#{liability_id},#{total_debit},#{total_debit_value},#{total_debit_fees},#{total_credit_value},#{average_balance_price}) " \
        'ON DUPLICATE KEY UPDATE ' \
        'total_balance_value = total_balance_value + VALUES(total_balance_value) - IF(VALUES(total_debit) = 0, 0, (VALUES(total_debit) + VALUES(total_debit_fees)) * average_balance_price), ' \
        "average_balance_price = IF(VALUES(total_credit) = 0, average_balance_price, total_balance_value / (VALUES(total_credit) + total_credit - total_debit)), " \
        'total_credit = total_credit + VALUES(total_credit), ' \
        'total_credit_fees = total_credit_fees + VALUES(total_credit_fees), ' \
        'total_debit_fees = total_debit_fees + VALUES(total_debit_fees), ' \
        'total_credit_value = total_credit_value + VALUES(total_credit_value), ' \
        'total_debit_value = total_debit_value + VALUES(total_debit_value), ' \
        'total_debit = total_debit + VALUES(total_debit), ' \
        'updated_at = NOW(), ' \
        'last_liability_id = VALUES(last_liability_id)'
      end

      def update_pnl(queries)
        ActiveRecord::Base.connection.transaction do
          queries.each do |query|
            ActiveRecord::Base.connection.exec_query(query)
          end
        end
      end
    end
  end
end
