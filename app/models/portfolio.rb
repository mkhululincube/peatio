# encoding: UTF-8
# frozen_string_literal: true

class Portfolio < ApplicationRecord
  # == Constants ============================================================

  # == Extensions ===========================================================

  # == Attributes ===========================================================

  # == Relationships ========================================================

  belongs_to :currency, required: true, foreign_key: :currency_id
  belongs_to :currency, required: true, foreign_key: :portfolio_currency_id
  belongs_to :member, required: true

  # == Validations ==========================================================

  validates :total_credit, :total_debit, :total_credit_fees, :total_debit_fees,
            :total_credit_value, :total_debit_value,
            numericality: { greater_than_or_equal_to: 0 }
  # == Scopes ===============================================================

  # == Callbacks ============================================================

  # == Class Methods ========================================================

  # == Instance Methods =====================================================
end

# == Schema Information
# Schema version: 20200514132805
#
# Table name: portfolios
#
#  id                    :bigint           not null, primary key
#  member_id             :integer          not null
#  portfolio_currency_id :string(10)       not null
#  currency_id           :string(10)       not null
#  total_credit          :decimal(32, 16)
#  total_credit_fees        :decimal(32, 16)
#  total_debit_fees       :decimal(32, 16)
#  total_debit           :decimal(32, 16)
#  total_credit_value    :decimal(32, 16)
#  total_debit_value     :decimal(32, 16)
#  last_liability_id     :bigint
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_currency_ids_and_member_id       (portfolio_currency_id,currency_id,member_id) UNIQUE
#  index_portfolios_on_last_liability_id  (last_liability_id)
#
