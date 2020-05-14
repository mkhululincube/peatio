# encoding: UTF-8
# frozen_string_literal: true

FactoryBot.define do
  factory :portfolio do
    member { create(:member, :level_3) }
    currency_id { Currency.ids.sample }
    portfolio_currency_id { Currency.ids.sample }
    total_credit { 0 }
    total_debit_fees { 0 }
    total_credit_fees { 0 }
    total_debit { 0 }
    total_credit_value { 0 }
    total_debit_value { 0 }
    last_liability_id { 0 }
  end
end
