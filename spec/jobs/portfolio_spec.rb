# encoding: UTF-8
# frozen_string_literal: true

describe Jobs::Cron::Portfolio do
  let(:member) { create(:member, :level_3) }

  context 'conversion_market' do
    it 'when there is no market' do
      expect do
        Jobs::Cron::Portfolio.conversion_market('test1', 'test2')
      end.to raise_error('There is no market test1test2')
    end

    it 'when market exists' do
      market = Market.first
      expect(Jobs::Cron::Portfolio.conversion_market(market.base_unit, market.quote_unit)).to eq market.id
    end
  end

  context 'price_at' do
    after { delete_measurments("trades") }

    let!(:coin_deposit) { create(:deposit, :deposit_btc) }
    let!(:liability) { create(:liability, member: member, credit: 0.4, reference_type: 'Deposit', reference_id: coin_deposit.id) }

    it 'when there is no trades' do
      market = Market.find_by(base_unit: 'btc', quote_unit: 'usd')
      expect do
        Jobs::Cron::Portfolio.price_at(market.quote_unit, coin_deposit.currency_id, liability.created_at)
      end.to raise_error("There is no trades on market #{coin_deposit.currency_id}#{market.quote_unit}")
    end

    context 'when trade exist' do
      let(:trade) { create(:trade, :btceth, price: '5.0'.to_d, amount: '1.9'.to_d, total: '5.5'.to_d)}

      before do
        trade.write_to_influx
      end

      it 'return trade price' do
        res = Jobs::Cron::Portfolio.price_at(trade.market.quote_unit, coin_deposit.currency_id, trade.created_at + 3.hours)
        expect(res).to eq trade.price
      end

      it 'when portfolio currency id equal to currency id' do
        res = Jobs::Cron::Portfolio.price_at(coin_deposit.currency_id, coin_deposit.currency_id, trade.created_at + 3.hours)
        expect(res).to eq 1.0
      end
    end
  end

  context 'process_deposit' do
    let!(:coin_deposit) { create(:deposit, :deposit_btc) }
    let!(:fiat_deposit){ create(:deposit_usd) }

    let!(:liability1) { create(:liability, member: member, credit: 0.4, reference_type: 'Deposit', reference_id: coin_deposit.id) }
    let!(:liability2) { create(:liability, member: member, credit: 1000.0, reference_type: 'Deposit', reference_id: fiat_deposit.id) }

    let(:trade1) { create(:trade, :btceth, price: '5.0'.to_d, amount: '1.9'.to_d, total: '5.5'.to_d)}
    let(:trade2) { create(:trade, :btcusd, price: '100.0'.to_d, amount: '0.4'.to_d, total: '1.5'.to_d)}

    context 'coin deposit' do
      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade1.price)
      end
      it do
        result = Jobs::Cron::Portfolio.process_deposit(trade1.market.quote_unit, liability1.id, coin_deposit)
        result = result.split(/[(,)]/)
        expect(result[1].to_i).to eq coin_deposit.member.id
        expect(result[2]).to eq "'#{trade1.market.quote_unit}'"
        expect(result[3]).to eq "'#{coin_deposit.currency_id}'"
        expect(result[4].to_f).to eq coin_deposit.amount
        expect(result[5].to_f).to eq coin_deposit.fee
        expect(result[6].to_f).to eq coin_deposit.amount * trade1.price
        expect(result[7].to_i).to eq liability1.id
        expect(result[8].to_i).to eq 0
        expect(result[9].to_i).to eq 0
        expect(result[10].to_i).to eq 0
      end
    end

    context 'fiat deposit' do
      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade2.price)
      end
      it do
        result = Jobs::Cron::Portfolio.process_deposit(trade2.market.quote_unit, liability2.id, fiat_deposit)
        result = result.split(/[(,)]/)
        expect(result[1].to_i).to eq fiat_deposit.member.id
        expect(result[2]).to eq "'#{trade2.market.quote_unit}'"
        expect(result[3]).to eq "'#{fiat_deposit.currency_id}'"
        expect(result[4].to_f).to eq fiat_deposit.amount
        expect(result[5].to_f).to eq fiat_deposit.fee
        expect(result[6].to_f).to eq fiat_deposit.amount * trade2.price
        expect(result[7].to_i).to eq liability2.id
        expect(result[8].to_i).to eq 0
        expect(result[9].to_i).to eq 0
        expect(result[10].to_i).to eq 0
      end
    end
  end

  context 'process_withdraw' do
    before do
      member.touch_accounts
      member.accounts.map { |a| a.update(balance: 500) }
    end

    let!(:coin_withdraw) { create(:btc_withdraw, sum: 0.3.to_d, member: member, aasm_state: 'succeed') }
    let!(:fiat_withdraw){ create(:usd_withdraw, sum: 100.to_d, member: member, aasm_state: 'succeed') }

    let!(:liability1) { create(:liability, member: member, debit: 0.3, reference_type: 'Withdraw', reference_id: coin_withdraw.id) }
    let!(:liability2) { create(:liability, member: member, debit: 100.0, reference_type: 'Withdraw', reference_id: fiat_withdraw.id) }

    let(:trade1) { create(:trade, :btceth, price: '5.0'.to_d, amount: '1.9'.to_d, total: '5.5'.to_d)}
    let(:trade2) { create(:trade, :btcusd, price: '100.0'.to_d, amount: '0.4'.to_d, total: '1.5'.to_d)}

    context 'coin withdraw' do
      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade1.price)
      end

      it do
        result = Jobs::Cron::Portfolio.process_withdraw(trade1.market.quote_unit, liability1.id, coin_withdraw)
        result = result.split(/[(,)]/)

        expect(result[1].to_i).to eq coin_withdraw.member.id
        expect(result[2]).to eq "'#{trade1.market.quote_unit}'"
        expect(result[3]).to eq "'#{coin_withdraw.currency_id}'"
        expect(result[4].to_f).to eq 0
        expect(result[5].to_f).to eq 0
        expect(result[6].to_f).to eq 0
        expect(result[7].to_i).to eq liability1.id
        expect(result[8].to_f).to eq coin_withdraw.amount.to_f
        expect(result[9].to_f).to eq (coin_withdraw.amount.to_f + coin_withdraw.fee.to_f) * trade1.price.to_f
        expect(result[10].to_f).to eq coin_withdraw.fee
      end
    end

    context 'fiat withdraw' do
      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade2.price)
      end

      it do
        result = Jobs::Cron::Portfolio.process_withdraw(trade2.market.quote_unit, liability2.id, fiat_withdraw)
        result = result.split(/[(,)]/)

        expect(result[1].to_i).to eq fiat_withdraw.member.id
        expect(result[2]).to eq "'#{trade2.market.quote_unit}'"
        expect(result[3]).to eq "'#{fiat_withdraw.currency_id}'"
        expect(result[4].to_f).to eq 0
        expect(result[5].to_f).to eq 0
        expect(result[6].to_f).to eq 0
        expect(result[7].to_i).to eq liability2.id
        expect(result[8].to_f).to eq fiat_withdraw.amount.to_f
        expect(result[9].to_f).to eq (fiat_withdraw.amount.to_f + fiat_withdraw.fee.to_f) * trade2.price.to_f
        expect(result[10].to_f).to eq fiat_withdraw.fee
      end
    end
  end

  context 'process_order' do
    let!(:trade_eth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

    let!(:trade) { create(:trade, :btcusd, price: '5.0'.to_d, amount: '1.1'.to_d, total: '5.5'.to_d)}
    let!(:liability) { create(:liability, member: member, credit: 0.4, reference_type: 'Trade', reference_id: trade.id) }

    before do
      Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_eth.price.to_f)
    end

    context 'buy order' do
      it do
        result = Jobs::Cron::Portfolio.process_order(trade_eth.market.quote_unit, liability.id, trade, trade.taker_order)

        res1 = result[0].split(/[(,)]/)
        total_fees = trade.amount * trade.order_fee(trade.taker_order)
        expect(res1[1].to_i).to eq trade.taker_order.member.id
        expect(res1[2]).to eq "'#{trade_eth.market.quote_unit}'"
        expect(res1[3]).to eq "'#{trade.taker_order.income_currency.id}'"
        expect(res1[4].to_f).to eq trade.amount - total_fees
        expect(res1[5].to_f).to eq total_fees
        expect(res1[6].to_f).to eq (trade.amount - total_fees).to_f * trade_eth.price
        expect(res1[7].to_i).to eq liability.id
        expect(res1[8].to_f).to eq 0
        expect(res1[9].to_f).to eq 0
        expect(res1[10].to_f).to eq 0

        res2 = result[1].split(/[(,)]/)
        expect(res2[1].to_i).to eq trade.taker_order.member.id
        expect(res2[2]).to eq "'#{trade_eth.market.quote_unit}'"
        expect(res2[3]).to eq "'#{trade.taker_order.outcome_currency.id}'"
        expect(res2[4].to_f).to eq 0
        expect(res2[5].to_f).to eq 0
        expect(res2[6].to_f).to eq 0
        expect(res2[7].to_i).to eq liability.id
        expect(res2[8].to_f).to eq trade.total
        expect(res2[9].to_f).to eq trade.total * trade_eth.price
        expect(res2[10].to_f).to eq 0
      end
    end

    context 'sell order' do
      it do
        result = Jobs::Cron::Portfolio.process_order(trade_eth.market.quote_unit, liability.id, trade, trade.maker_order)

        res1 = result[0].split(/[(,)]/)
        total_fees =  trade.total * trade.order_fee(trade.maker_order)
        expect(res1[1].to_i).to eq trade.maker_order.member.id
        expect(res1[2]).to eq "'#{trade_eth.market.quote_unit}'"
        expect(res1[3]).to eq "'#{trade.maker_order.income_currency.id}'"
        expect(res1[4].to_f).to eq trade.total - total_fees
        expect(res1[5].to_f).to eq total_fees
        expect(res1[6].to_f).to eq (trade.total - total_fees)* trade_eth.price
        expect(res1[7].to_i).to eq liability.id
        expect(res1[8].to_f).to eq 0
        expect(res1[9].to_f).to eq 0
        expect(res1[10].to_f).to eq 0

        res2 = result[1].split(/[(,)]/)
        expect(res2[1].to_i).to eq trade.maker_order.member.id
        expect(res2[2]).to eq "'#{trade_eth.market.quote_unit}'"
        expect(res2[3]).to eq "'#{trade.maker_order.outcome_currency.id}'"
        expect(res2[4].to_f).to eq 0
        expect(res2[5].to_f).to eq 0
        expect(res2[6].to_f).to eq 0
        expect(res2[7].to_i).to eq liability.id
        expect(res2[8].to_f).to eq trade.amount
        expect(res2[9].to_f).to eq trade.amount * trade_eth.price
        expect(res2[10].to_f).to eq 0
      end
    end

    context 'market quote unit is equal to porfolio' do
      let!(:trade_eth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

      let!(:trade) { create(:trade, :btceth, price: '5.0'.to_d, amount: '1.1'.to_d, total: '5.5'.to_d)}
      let!(:liability) { create(:liability, member: member, credit: 0.4, reference_type: 'Trade', reference_id: trade.id) }

      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_eth.price.to_f)
      end

      context 'buy order' do
        it do
          result = Jobs::Cron::Portfolio.process_order(trade.market.quote_unit, liability.id, trade, trade.taker_order)

          res1 = result[0].split(/[(,)]/)
          total_fees = trade.amount * trade.order_fee(trade.taker_order)
          expect(res1[1].to_i).to eq trade.taker_order.member.id
          expect(res1[2]).to eq "'#{trade.market.quote_unit}'"
          expect(res1[3]).to eq "'#{trade.taker_order.income_currency.id}'"
          expect(res1[4].to_f).to eq trade.amount - total_fees
          expect(res1[5].to_f).to eq total_fees
          expect(res1[6].to_f).to eq (trade.amount - total_fees).to_f * trade.price
          expect(res1[7].to_i).to eq liability.id
          expect(res1[8].to_f).to eq 0
          expect(res1[9].to_f).to eq 0
          expect(res1[10].to_f).to eq 0

          res2 = result[1].split(/[(,)]/)
          expect(res2[1].to_i).to eq trade.taker_order.member.id
          expect(res2[2]).to eq "'#{trade.market.quote_unit}'"
          expect(res2[3]).to eq "'#{trade.taker_order.outcome_currency.id}'"
          expect(res2[4].to_f).to eq 0
          expect(res2[5].to_f).to eq 0
          expect(res2[6].to_f).to eq 0
          expect(res2[7].to_i).to eq liability.id
          expect(res2[8].to_f).to eq trade.total
          expect(res2[9].to_f).to eq trade.total
          expect(res2[10].to_f).to eq 0
        end
      end

      context 'sell order' do
        it do
          result = Jobs::Cron::Portfolio.process_order(trade.market.quote_unit, liability.id, trade, trade.maker_order)

          res1 = result[0].split(/[(,)]/)
          total_fees =  trade.total * trade.order_fee(trade.maker_order)
          expect(res1[1].to_i).to eq trade.maker_order.member.id
          expect(res1[2]).to eq "'#{trade.market.quote_unit}'"
          expect(res1[3]).to eq "'#{trade.maker_order.income_currency.id}'"
          expect(res1[4].to_f).to eq trade.total - total_fees
          expect(res1[5].to_f).to eq total_fees
          expect(res1[6].to_f).to eq trade.total - total_fees
          expect(res1[7].to_i).to eq liability.id
          expect(res1[8].to_f).to eq 0
          expect(res1[9].to_f).to eq 0
          expect(res1[10].to_f).to eq 0

          res2 = result[1].split(/[(,)]/)
          expect(res2[1].to_i).to eq trade.maker_order.member.id
          expect(res2[2]).to eq "'#{trade.market.quote_unit}'"
          expect(res2[3]).to eq "'#{trade.maker_order.outcome_currency.id}'"
          expect(res2[4].to_f).to eq 0
          expect(res2[5].to_f).to eq 0
          expect(res2[6].to_f).to eq 0
          expect(res2[7].to_i).to eq liability.id
          expect(res2[8].to_f).to eq trade.amount
          expect(res2[9].to_f).to eq trade.amount * trade.price
          expect(res2[10].to_f).to eq 0
        end
      end

    end
  end

  context 'process currency' do
    before(:each) do
      Portfolio.delete_all
    end

    context 'reference type withdraw' do
      before do
        member.touch_accounts
        member.accounts.map { |a| a.update(balance: 500) }
      end

      context 'creates one portfolio' do
        let!(:coin_withdraw) { create(:btc_withdraw, sum: 0.3.to_d, amount: 0.2.to_d, aasm_state: 'succeed', member: member) }
        let!(:portfolio) { create(:portfolio, last_liability_id: 1)}
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

        let!(:liability) { create(:liability, id: 2, member: member, debit: 190.0, currency_id: coin_withdraw.currency_id,
                                   reference_type: 'Withdraw', code: 212, reference_id: coin_withdraw.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(1)

          expect(Portfolio.last.member_id).to eq coin_withdraw.member_id
          expect(Portfolio.last.currency_id).to eq coin_withdraw.currency_id
          expect(Portfolio.last.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.last.total_credit).to eq 0
          expect(Portfolio.last.total_debit).to eq coin_withdraw.amount
          expect(Portfolio.last.total_debit_value).to eq (coin_withdraw.amount + coin_withdraw.fee) * trade_btceth.price
          expect(Portfolio.last.total_debit_fees).to eq coin_withdraw.fee
          expect(Portfolio.last.total_credit_fees).to eq 0
          expect(Portfolio.last.total_credit_value).to eq 0
          expect(Portfolio.last.last_liability_id).to eq liability.id
        end
      end

      context 'calculation on existing portfolio' do
        let!(:coin_withdraw) { create(:btc_withdraw, amount: 0.2.to_d, aasm_state: 'succeed', member: member) }
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}
        let!(:portfolio) { create(:portfolio, currency_id: coin_withdraw.currency_id,  portfolio_currency_id: trade_btceth.market.quote_unit, total_debit: 0.1,
                                   total_debit_fees: 0.01, total_debit_value: 0.3, member_id: coin_withdraw.member_id, last_liability_id: 1)}
        let!(:liability) { create(:liability, id: 2, member_id: coin_withdraw.member_id, currency_id: coin_withdraw.currency_id,
                                   debit: 0.3, reference_type: 'Withdraw', code: 212, reference_id: coin_withdraw.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(0)

          expect(Portfolio.last.member_id).to eq coin_withdraw.member_id
          expect(Portfolio.last.currency_id).to eq coin_withdraw.currency_id
          expect(Portfolio.last.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.last.total_credit).to eq portfolio.total_credit
          expect(Portfolio.last.total_debit).to eq coin_withdraw.amount + portfolio.total_debit
          expect(Portfolio.last.total_debit_value).to eq (coin_withdraw.amount + coin_withdraw.fee) * trade_btceth.price + portfolio.total_debit_value
          expect(Portfolio.last.total_debit_fees).to eq coin_withdraw.fee + portfolio.total_debit_fees
          expect(Portfolio.last.total_credit_fees).to eq portfolio.total_credit_fees
          expect(Portfolio.last.total_credit_value).to eq portfolio.total_credit_value
          expect(Portfolio.last.last_liability_id).to eq liability.id
        end
      end
    end

    context 'reference type deposit' do

      context 'creates one portfolio' do
        let!(:coin_deposit) { create(:deposit, :deposit_btc) }
        let!(:portfolio) { create(:portfolio, last_liability_id: 1)}
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

        let!(:liability) { create(:liability, id: 2, member: member, credit: 190.0, reference_type: 'Deposit', reference_id: coin_deposit.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(1)
          expect(Portfolio.last.member_id).to eq coin_deposit.member_id
          expect(Portfolio.last.currency_id).to eq coin_deposit.currency_id
          expect(Portfolio.last.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.last.total_credit).to eq coin_deposit.amount
          expect(Portfolio.last.total_debit).to eq 0
          expect(Portfolio.last.total_debit_value).to eq 0
          expect(Portfolio.last.total_debit_fees).to eq 0
          expect(Portfolio.last.total_credit_fees).to eq coin_deposit.fee
          expect(Portfolio.last.total_credit_value).to eq coin_deposit.amount * trade_btceth.price
          expect(Portfolio.last.last_liability_id).to eq liability.id
        end
      end

      context 'creates several portfolios' do
        let!(:coin_deposit) { create(:deposit, :deposit_btc) }
        let!(:fiat_deposit) { create(:deposit_usd) }
        let!(:portfolio) { create(:portfolio, last_liability_id: 1)}
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

        let!(:liability1) { create(:liability, id: 2, member: member, credit: 190.0, reference_type: 'Deposit', reference_id: coin_deposit.id) }
        let!(:liability2) { create(:liability, id: 3, member: member, credit: 190.0, reference_type: 'Deposit', reference_id: fiat_deposit.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(2)

          expect(Portfolio.second.member_id).to eq coin_deposit.member_id
          expect(Portfolio.second.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.second.currency_id).to eq coin_deposit.currency_id
          expect(Portfolio.second.total_credit).to eq coin_deposit.amount
          expect(Portfolio.second.total_debit).to eq 0
          expect(Portfolio.second.total_debit_value).to eq 0
          expect(Portfolio.second.total_debit_fees).to eq 0
          expect(Portfolio.second.total_credit_fees).to eq coin_deposit.fee
          expect(Portfolio.second.total_credit_value).to eq coin_deposit.amount * trade_btceth.price
          expect(Portfolio.second.last_liability_id).to eq liability1.id

          expect(Portfolio.last.member_id).to eq fiat_deposit.member_id
          expect(Portfolio.last.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.last.currency_id).to eq fiat_deposit.currency_id
          expect(Portfolio.last.total_credit).to eq fiat_deposit.amount
          expect(Portfolio.last.total_debit).to eq 0
          expect(Portfolio.last.total_debit_value).to eq 0
          expect(Portfolio.last.total_debit_fees).to eq 0
          expect(Portfolio.last.total_credit_fees).to eq fiat_deposit.fee
          expect(Portfolio.last.total_credit_value).to eq fiat_deposit.amount * trade_btceth.price
          expect(Portfolio.last.last_liability_id).to eq liability2.id
        end
      end

      context 'calculation on existing portfolio' do
        let!(:coin_deposit) { create(:deposit, :deposit_btc) }
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}
        let!(:portfolio) { create(:portfolio, currency_id: coin_deposit.currency_id,  portfolio_currency_id: trade_btceth.market.quote_unit, total_credit: 0.1, 
                                  total_credit_fees: 0.01, total_credit_value: 0.3, member_id: coin_deposit.member_id, last_liability_id: 1)}
        let!(:liability) { create(:liability, id: 2, member_id: coin_deposit.member_id, credit: 190.0, reference_type: 'Deposit', reference_id: coin_deposit.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(0)
          expect(Portfolio.last.member_id).to eq coin_deposit.member_id
          expect(Portfolio.last.portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.last.currency_id).to eq coin_deposit.currency_id
          expect(Portfolio.last.total_credit).to eq (coin_deposit.amount + portfolio.total_credit)
          expect(Portfolio.last.total_debit_fees).to eq 0
          expect(Portfolio.last.total_credit_fees).to eq (coin_deposit.fee + portfolio.total_credit_fees)
          expect(Portfolio.last.total_debit).to eq portfolio.total_debit
          expect(Portfolio.last.total_debit_value).to eq portfolio.total_debit_value
          expect(Portfolio.last.total_credit_value).to eq coin_deposit.amount * trade_btceth.price +  portfolio.total_credit_value
          expect(Portfolio.last.last_liability_id).to eq liability.id
        end
      end
    end

    context 'reference type trade' do
      context 'calculation on existing portfolio' do
        let!(:trade) { create(:trade, :btcusd, price: '5.0'.to_d, amount: '1.1'.to_d, total: '5.5'.to_d)}
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

        let!(:portfolio1) { create(:portfolio, portfolio_currency_id: trade_btceth.market.quote_unit, currency_id: 'btc',
                                    total_credit: 0.1, total_credit_fees: 0.01, total_credit_value: 0.3, total_debit: 0.2,
                                    total_debit_value: 10.0, member_id: trade.maker_order.member.id, last_liability_id: 1)}

        let!(:portfolio2) { create(:portfolio, portfolio_currency_id: trade_btceth.market.quote_unit, currency_id: 'usd',
                                    total_credit: 0.1, total_credit_fees: 0.01, total_credit_value: 0.3, total_debit: 0.2,
                                    total_debit_value: 10.0, member_id: trade.maker_order.member.id, last_liability_id: 1)}

        let!(:portfolio3) { create(:portfolio, portfolio_currency_id: trade_btceth.market.quote_unit, currency_id: 'usd',
                                    total_credit: 0.4, total_credit_fees: 0.01, total_credit_value: 0.3, total_debit: 0.2,
                                    total_debit_value: 10.0, member_id: trade.taker_order.member.id, last_liability_id: 1)}

        let!(:portfolio4) { create(:portfolio, portfolio_currency_id: trade_btceth.market.quote_unit, currency_id: 'btc',
                                    total_credit: 0.4, total_credit_fees: 0.01, total_credit_value: 0.3,
                                    total_debit: 0.2, total_debit_value: 10.0, member_id: trade.taker_order.member.id, last_liability_id: 1)}

        let!(:liability) { create(:liability, id: 2, member_id: member.id, credit: 110.0, reference_type: 'Trade', reference_id: trade.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(0)

          total_fees = trade.total * trade.order_fee(trade.maker_order)
          expect(Portfolio.all[0].member_id).to eq trade.maker_order.member.id
          expect(Portfolio.all[0].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[0].currency_id).to eq portfolio1.currency_id
          expect(Portfolio.all[0].total_credit).to eq portfolio1.total_credit
          expect(Portfolio.all[0].total_credit_fees).to eq portfolio1.total_credit_fees
          expect(Portfolio.all[0].total_debit).to eq trade.amount + portfolio1.total_debit
          expect(Portfolio.all[0].total_debit_value).to eq portfolio1.total_debit_value + trade.amount * trade_btceth.price
          expect(Portfolio.all[0].total_credit_value).to eq portfolio1.total_credit_value
          expect(Portfolio.all[0].last_liability_id).to eq liability.id

          expect(Portfolio.all[1].member_id).to eq trade.maker_order.member.id
          expect(Portfolio.all[1].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[1].currency_id).to eq portfolio2.currency_id
          expect(Portfolio.all[1].total_credit).to eq trade.total - total_fees + portfolio2.total_credit
          expect(Portfolio.all[1].total_credit_fees).to eq total_fees + + portfolio2.total_credit_fees
          expect(Portfolio.all[1].total_debit).to eq portfolio2.total_debit
          expect(Portfolio.all[1].total_debit_value).to eq portfolio2.total_debit_value
          expect(Portfolio.all[1].total_credit_value).to eq (trade.total - total_fees) * trade_btceth.price + portfolio2.total_credit_value
          expect(Portfolio.all[1].last_liability_id).to eq liability.id

          total_fees = trade.amount * trade.order_fee(trade.taker_order)
          expect(Portfolio.all[2].member_id).to eq trade.taker_order.member.id
          expect(Portfolio.all[2].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[2].currency_id).to eq portfolio3.currency_id
          expect(Portfolio.all[2].total_credit).to eq portfolio3.total_credit
          expect(Portfolio.all[2].total_debit).to eq trade.total + portfolio3.total_debit
          expect(Portfolio.all[2].total_debit_value).to eq trade.total * trade_btceth.price + portfolio3.total_debit_value
          expect(Portfolio.all[2].total_credit_fees).to eq portfolio3.total_credit_fees
          expect(Portfolio.all[2].total_credit_value).to eq portfolio3.total_credit_value
          expect(Portfolio.all[2].last_liability_id).to eq liability.id

          expect(Portfolio.all[3].member_id).to eq trade.taker_order.member.id
          expect(Portfolio.all[3].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[3].currency_id).to eq portfolio4.currency_id
          expect(Portfolio.all[3].total_credit).to eq trade.amount - total_fees + portfolio4.total_credit
          expect(Portfolio.all[3].total_debit).to eq portfolio4.total_debit
          expect(Portfolio.all[3].total_debit_value).to eq portfolio4.total_debit_value
          expect(Portfolio.all[3].total_credit_fees).to eq total_fees + portfolio4.total_credit_fees
          expect(Portfolio.all[3].total_credit_value).to eq (trade.amount - total_fees) * trade_btceth.price + portfolio4.total_credit_value
          expect(Portfolio.all[3].last_liability_id).to eq liability.id
        end
      end

      context 'creates portfolios while executing 1 trade' do
        let!(:trade) { create(:trade, :btcusd, price: '5.0'.to_d, amount: '1.1'.to_d, total: '5.5'.to_d)}
        let!(:portfolio) { create(:portfolio, last_liability_id: 1)}
        let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

        let!(:liability) { create(:liability, id: 2, member: member, credit: 110.0, reference_type: 'Trade', reference_id: trade.id) }

        before do
          Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
        end

        it do
          expect{ Jobs::Cron::Portfolio.process_currency(trade_btceth.market.quote_unit) }.to change{ Portfolio.count }.by(4)

          total_fees = trade.total * trade.order_fee(trade.maker_order)
          expect(Portfolio.all[1].member_id).to eq trade.maker_order.member.id
          expect(Portfolio.all[1].currency_id).to eq trade.maker_order.income_currency.id
          expect(Portfolio.all[1].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[1].total_credit).to eq trade.total - total_fees
          expect(Portfolio.all[1].total_debit).to eq 0
          expect(Portfolio.all[1].total_debit_value).to eq 0
          expect(Portfolio.all[1].total_credit_fees).to eq total_fees
          expect(Portfolio.all[1].total_credit_value).to eq (trade.total - total_fees) * trade_btceth.price
          expect(Portfolio.all[1].last_liability_id).to eq liability.id

          expect(Portfolio.all[2].member_id).to eq trade.maker_order.member.id
          expect(Portfolio.all[2].currency_id).to eq trade.maker_order.outcome_currency.id
          expect(Portfolio.all[2].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[2].total_credit).to eq 0
          expect(Portfolio.all[2].total_debit).to eq trade.amount
          expect(Portfolio.all[2].total_debit_value).to eq trade.amount * trade_btceth.price
          expect(Portfolio.all[2].total_credit_fees).to eq 0
          expect(Portfolio.all[2].total_credit_value).to eq 0
          expect(Portfolio.all[2].last_liability_id).to eq liability.id

          total_fees = trade.amount * trade.order_fee(trade.taker_order)
          expect(Portfolio.all[3].member_id).to eq trade.taker_order.member.id
          expect(Portfolio.all[3].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[3].currency_id).to eq trade.taker_order.income_currency.id
          expect(Portfolio.all[3].total_credit).to eq trade.amount - total_fees
          expect(Portfolio.all[3].total_debit).to eq 0
          expect(Portfolio.all[3].total_debit_value).to eq 0
          expect(Portfolio.all[3].total_credit_fees).to eq total_fees
          expect(Portfolio.all[3].total_credit_value).to eq (trade.amount - total_fees) * trade_btceth.price
          expect(Portfolio.all[3].last_liability_id).to eq liability.id

          expect(Portfolio.all[4].member_id).to eq trade.taker_order.member.id
          expect(Portfolio.all[4].portfolio_currency_id).to eq trade_btceth.market.quote_unit
          expect(Portfolio.all[4].currency_id).to eq trade.taker_order.outcome_currency.id
          expect(Portfolio.all[4].total_credit).to eq 0
          expect(Portfolio.all[4].total_debit).to eq trade.total
          expect(Portfolio.all[4].total_debit_value).to eq trade.total * trade_btceth.price
          expect(Portfolio.all[4].total_credit_fees).to eq 0
          expect(Portfolio.all[4].total_credit_value).to eq 0
          expect(Portfolio.all[4].last_liability_id).to eq liability.id
        end
      end
    end
  end

  context 'process' do
    before do
      Jobs::Cron::Portfolio.stubs(:portfolio_currencies).returns([Market.first.quote_unit, Market.second.quote_unit])
    end

    context 'no liabilities' do
      it do
        Jobs::Cron::Portfolio.process
        expect(Portfolio.count).to eq 0
      end
    end

    context 'liability for reference type deposit' do
      let!(:coin_deposit) { create(:deposit, :deposit_btc) }
      let!(:portfolio) { create(:portfolio, last_liability_id: 1)}
      let!(:trade_btceth) { create(:trade, :btceth, price: '1.0'.to_d, amount: '0.3'.to_d, total: '5.5'.to_d)}

      let!(:liability) { create(:liability, id: 2, member: member, credit: 190.0, reference_type: 'Deposit', reference_id: coin_deposit.id) }

      before do
        Jobs::Cron::Portfolio.stubs(:price_at).returns(trade_btceth.price.to_f)
      end

      it do
        expect{ Jobs::Cron::Portfolio.process }.to change{ Portfolio.count }.by(2)

        expect(Portfolio.second.member_id).to eq coin_deposit.member_id
        expect(Portfolio.second.currency_id).to eq coin_deposit.currency_id
        expect(Portfolio.second.portfolio_currency_id).to eq Market.first.quote_unit
        expect(Portfolio.second.total_credit).to eq coin_deposit.amount
        expect(Portfolio.second.total_debit).to eq 0
        expect(Portfolio.second.total_debit_value).to eq 0
        expect(Portfolio.second.total_credit_fees).to eq coin_deposit.fee
        expect(Portfolio.second.total_debit_fees).to eq 0
        expect(Portfolio.second.total_credit_value).to eq coin_deposit.amount * trade_btceth.price
        expect(Portfolio.second.last_liability_id).to eq liability.id

        expect(Portfolio.last.member_id).to eq coin_deposit.member_id
        expect(Portfolio.last.currency_id).to eq coin_deposit.currency_id
        expect(Portfolio.last.portfolio_currency_id).to eq Market.second.quote_unit
        expect(Portfolio.last.total_credit).to eq coin_deposit.amount
        expect(Portfolio.last.total_debit).to eq 0
        expect(Portfolio.last.total_debit_value).to eq 0
        expect(Portfolio.last.total_credit_fees).to eq coin_deposit.fee
        expect(Portfolio.last.total_debit_fees).to eq 0
        expect(Portfolio.last.total_credit_value).to eq coin_deposit.amount * trade_btceth.price
        expect(Portfolio.last.last_liability_id).to eq liability.id
      end
    end
  end
end
