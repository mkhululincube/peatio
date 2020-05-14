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
        values = []
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
          values << portfolios_values(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          order.side == 'buy' ? total_debit_value = total_debit : total_debit_value = total_debit * trade.price
          values << portfolios_values(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        else
          income_currency_id = order.income_currency.id
          total_credit_value = (total_credit) * price_at(portfolio_currency, income_currency_id, trade.created_at)
          values << portfolios_values(order.member_id, portfolio_currency, income_currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)

          outcome_currency_id = order.outcome_currency.id
          total_debit_value = (total_debit) * price_at(portfolio_currency, outcome_currency_id, trade.created_at)
          values << portfolios_values(order.member_id, portfolio_currency, outcome_currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, 0)
        end

        values.flatten
      end

      def process_deposit(portfolio_currency, liability_id, deposit)
        Rails.logger.info { "Process deposit: #{deposit.id}" }
        total_credit = deposit.amount
        total_credit_fees = deposit.fee
        total_credit_value = total_credit * price_at(portfolio_currency, deposit.currency_id, deposit.created_at)
        portfolios_values(deposit.member_id, portfolio_currency, deposit.currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, 0, 0, 0)
      end

      def process_withdraw(portfolio_currency, liability_id, withdraw)
        Rails.logger.info { "Process withdraw: #{withdraw.id}" }
        total_debit = withdraw.amount
        total_debit_fees = withdraw.fee
        total_debit_value = (total_debit + total_debit_fees) * price_at(portfolio_currency, withdraw.currency_id, withdraw.created_at)

        portfolios_values(withdraw.member_id, portfolio_currency, withdraw.currency_id, 0, 0, 0, liability_id, total_debit, total_debit_value, total_debit_fees)
      end

      def process
        portfolio_currencies.each do |portfolio_currency|
          begin
            process_currency(portfolio_currency)
          rescue StandardError => e
            Rails.logger.error("Failed to process currency #{portfolio_currency}: #{e}")
          end
        end

        sleep 2
      end

      def process_currency(portfolio_currency)
        values = []
        ActiveRecord::Base.connection
          .select_all("SELECT MAX(id) id, ANY_VALUE(reference_type) reference_type, ANY_VALUE(reference_id) reference_id " \
                      "FROM liabilities WHERE id > #{max_liability(portfolio_currency)} " \
                      "AND ((reference_type IN ('Trade','Deposit', 'Adjustment') AND code IN (201,202)) " \
                      "OR (reference_type = 'Withdraw' AND code IN (211,212))) GROUP BY reference_id ORDER BY MAX(id) ASC LIMIT 10000")
          .each do |liability|
            Rails.logger.info { "Process liability: #{liability['id']}" }

            case liability['reference_type']
              when 'Deposit'
                deposit = Deposit.find(liability['reference_id'])
                values << process_deposit(portfolio_currency, liability['id'], deposit)
              when 'Trade'
                trade = Trade.find(liability['reference_id'])
                values << process_order(portfolio_currency, liability['id'], trade, trade.maker_order)
                values << process_order(portfolio_currency, liability['id'], trade, trade.taker_order)
                values = values.flatten
              when 'Withdraw'
                withdraw = Withdraw.find(liability['reference_id'])
                values << process_withdraw(portfolio_currency, liability['id'], withdraw)
            end
        end
        create_or_update_portfolio(values) if values.present?
      end

      def portfolios_values(member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, liability_id, total_debit, total_debit_value, total_debit_fees)
        "(#{member_id},'#{portfolio_currency_id}','#{currency_id}',#{total_credit},#{total_credit_fees},#{total_credit_value},#{liability_id},#{total_debit},#{total_debit_value},#{total_debit_fees})"
      end

      def create_or_update_portfolio(values)
        sql = "INSERT INTO portfolios (member_id, portfolio_currency_id, currency_id, total_credit, total_credit_fees, total_credit_value, last_liability_id, total_debit, total_debit_value, total_debit_fees) " \
              "VALUES #{values.join(',')} " \
              "ON DUPLICATE KEY UPDATE " \
              "total_credit = total_credit + VALUES(total_credit), " \
              "total_credit_fees = total_credit_fees + VALUES(total_credit_fees), " \
              "total_debit_fees = total_debit_fees + VALUES(total_debit_fees), " \
              "total_credit_value = total_credit_value + VALUES(total_credit_value), " \
              "total_debit_value = total_debit_value + VALUES(total_debit_value), " \
              "total_debit = total_debit + VALUES(total_debit), " \
              "updated_at = NOW(), " \
              "last_liability_id = VALUES(last_liability_id)"

        ActiveRecord::Base.connection.exec_query(sql)
      end
    end
  end
end
