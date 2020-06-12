# frozen_string_literal: true

module API
  module V2
    module Account
      class Stats < Grape::API
        desc 'Get assets pnl calculated into one currency'
        params do
          optional :pnl_currency,
                   type: String,
                   values: { value: -> { Currency.visible.codes(bothcase: true) }, message: 'pnl.currency.doesnt_exist' },
                   desc: 'Currency code in which the PnL is calculated'
        end
        get '/stats/pnl' do
          query = 'SELECT pnl_currency_id, currency_id, total_credit, total_debit, total_credit_value, total_debit_value, ' \
                  'total_credit_value / total_credit `average_buy_price`, total_debit_value / total_debit `average_sell_price` ' \
                  'FROM stats_member_pnl WHERE member_id = ? '
          query += "AND pnl_currency_id = '#{params[:pnl_currency]}'" if params[:pnl_currency].present?

          sanitized_query = ActiveRecord::Base.sanitize_sql_for_conditions([query, current_user.id])
          result = ActiveRecord::Base.connection.exec_query(sanitized_query).to_hash
          present paginate(result.each(&:symbolize_keys!)), with: API::V2::Entities::Pnl
        end
      end
    end
  end
end
