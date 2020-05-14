# frozen_string_literal: true

class CreatePortfolios < ActiveRecord::Migration[5.2]
  def change
    create_table :portfolios do |t|
      t.integer :member_id, null: false
      t.string :portfolio_currency_id, limit: 10, null: false
      t.string :currency_id,           limit: 10, null: false
      t.decimal :total_credit,         precision: 32, scale: 16
      t.decimal :total_credit_fees,       precision: 32, scale: 16
      t.decimal :total_debit_fees,      precision: 32, scale: 16
      t.decimal :total_debit,          precision: 32, scale: 16
      t.decimal :total_credit_value,   precision: 32, scale: 16
      t.decimal :total_debit_value,    precision: 32, scale: 16
      t.bigint :last_liability_id
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP" }

      t.index [:last_liability_id]
      t.index %i[portfolio_currency_id currency_id member_id], unique: true, :name => 'index_currency_ids_and_member_id'
    end
  end
end
