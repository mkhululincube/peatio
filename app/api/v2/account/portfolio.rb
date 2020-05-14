# frozen_string_literal: true

module API
  module V2
    module Account
      class Portfolio < Grape::API
        desc 'Get Crypto-Currency portfolio'
        params do
          optional :portfolio_currency,
                   type: String,
                   values: { value: -> { Currency.visible.codes(bothcase: true) }, message: 'portfolio.currency.doesnt_exist' },
                   desc: 'Portfolio currency code'
        end
        get '/portfolio' do
          query = 'SELECT portfolio_currency_id, currency_id, total_credit, total_debit, total_credit_value, total_debit_value, ' \
                  'total_credit_value / total_credit `average_buy_price`, total_debit_value / total_debit `average_sell_price` ' \
                  'FROM portfolios WHERE member_id = ? '
          query += "AND portfolio_currency_id = '#{params[:portfolio_currency]}'" if params[:portfolio_currency].present?

          sanitized_query = ActiveRecord::Base.sanitize_sql_for_conditions([query, current_user.id])
          result = ActiveRecord::Base.connection.exec_query(sanitized_query).to_hash
          present paginate(result.each(&:symbolize_keys!)), with: API::V2::Entities::Portfolio
        end
      end
    end
  end
end
