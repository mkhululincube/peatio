# frozen_string_literal: true

module API
  module V2
    module Entities
      class Portfolio < Base
        expose(
          :currency_id,
          as: :currency,
          documentation: {
            type: String,
            desc: 'Currency code.'
          }
        )

        expose(
          :portfolio_currency_id,
          as: :portfolio_currency,
          documentation: {
            type: String,
            desc: 'Portfolio currency code.'
          }
        )

        expose(
          :total_credit,
          documentation: {
            type: BigDecimal,
            desc: 'Total credit.'
          }
        )

        expose(
          :total_debit,
          documentation: {
            type: BigDecimal,
            desc: 'Total debit.'
          }
        )

        expose(
          :total_credit_value,
          documentation: {
            type: BigDecimal,
            desc: 'Total credit value.'
          }
        )

        expose(
          :total_debit_value,
          documentation: {
            type: BigDecimal,
            desc: 'Total debit value.'
          }
        )

        expose(
          :average_buy_price,
          documentation: {
            type: BigDecimal,
            desc: 'Average buy price.'
          }
        )

        expose(
          :average_sell_price,
          documentation: {
            type: BigDecimal,
            desc: 'Average sell price.'
          }
        )
      end
    end
  end
end
