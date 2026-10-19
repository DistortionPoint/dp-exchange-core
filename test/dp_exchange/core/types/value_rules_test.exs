defmodule DpExchange.Core.Types.ValueRulesTest do
  @moduledoc """
  The value rules each type's own doc states, held at `new/1`: identifying text is non-blank,
  containers have the right shape, sizes and amounts have the right sign, and a broadcast
  withdrawal names its transaction.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{
    ApprovedAddress,
    AuctionImbalance,
    Balance,
    ContractStats,
    Conversion,
    CorporateEvent,
    DepositAddress,
    Filing,
    Fill,
    FinancialStatement,
    FxRate,
    NewsItem,
    OptionChain,
    OptionContract,
    OptionGreeks,
    Portfolio,
    ScreenerResult,
    StakingBalance,
    StakingRate,
    StakingReward,
    StakingTransaction,
    VolumeProfile,
    Watchlist,
    Withdrawal
  }

  @ts ~U[2026-10-19 12:00:00Z]
  @date ~D[2026-10-19]

  defp dec(value), do: Decimal.new(value)

  defp put(attrs, field, value), do: Keyword.put(attrs, field, value)

  # `module.new(attrs with field = value)` raises `ArgumentError` naming `field`.
  defp refuse(module, attrs, field, value) do
    assert_raise ArgumentError, ~r/#{field}/, fn -> module.new(put(attrs, field, value)) end
  end

  describe "identifying text is a non-blank string" do
    test "deposit address, approved address, conversion, fill and balance" do
      deposit = [asset: "USDC", network: "ethereum", address: "0xabc", provider: :reference]
      approved = [address: "0xabc", network: "ethereum", status: :active, provider: :reference]
      conversion = [id: "q", status: :quoted, from_asset: "USD", to_asset: "BTC", provider: :ref]

      fill = [
        order_id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        quantity: dec("1"),
        price: dec("1"),
        timestamp: @ts,
        provider: :reference
      ]

      balance = [currency: "USD", balance: dec("1"), timestamp: @ts, provider: :reference]

      for bad <- ["", "   ", :eth, 5] do
        refuse(DepositAddress, deposit, :network, bad)
        refuse(DepositAddress, deposit, :address, bad)
        refuse(ApprovedAddress, approved, :network, bad)
        refuse(Conversion, conversion, :to_asset, bad)
        refuse(Fill, fill, :order_id, bad)
        refuse(Balance, balance, :currency, bad)
      end

      assert %DepositAddress{} = DepositAddress.new(deposit)
      assert %Fill{} = Fill.new(fill)
    end

    test "a deposit memo_required is true, false or nil, and nil is not false" do
      attrs = [asset: "XRP", network: "ripple", address: "r1", provider: :reference]

      refuse(DepositAddress, attrs, :memo_required, "no")
      assert %DepositAddress{memo_required: nil} = DepositAddress.new(attrs)
    end

    test "an auction imbalance side is the venue's string, not an atom" do
      attrs = [symbol: "AAPL", auction: :closing, observed_at: @ts, provider: :reference]

      refuse(AuctionImbalance, attrs, :side, :buy)
      assert %AuctionImbalance{side: "2"} = AuctionImbalance.new(put(attrs, :side, "2"))
    end
  end

  describe "containers have the right shape" do
    test "free-form maps, dates and booleans" do
      event = [symbol: "AAPL", kind: :dividend, provider: :reference]
      statement = [symbol: "AAPL", kind: :income, line_items: %{}, provider: :reference]

      refuse(CorporateEvent, event, :details, a: 1)
      refuse(CorporateEvent, event, :ex_date, ~U[2026-10-19 00:00:00Z])
      refuse(CorporateEvent, event, :confirmed, "yes")
      refuse(FinancialStatement, statement, :line_items, [{"a", 1}])
      refuse(FinancialStatement, statement, :period_end, "2026-03-31")
      refuse(Filing, [symbol: "AAPL", provider: :reference], :period_end, "2026-03-31")
      refuse(Portfolio, [id: "p", provider: :reference], :deleted, "no")

      assert %CorporateEvent{ex_date: @date} = CorporateEvent.new(put(event, :ex_date, @date))
    end

    test "symbol lists keep nil (not fetched) apart from [] (empty) and refuse the rest" do
      watchlist = [id: "w", provider: :reference]
      news = [id: "n", provider: :reference]

      for bad <- ["BTC-USD", [:btc], ["BTC-USD", ""], %{}] do
        refuse(Watchlist, watchlist, :symbols, bad)
        refuse(NewsItem, news, :symbols, bad)
      end

      assert %Watchlist{symbols: nil} = Watchlist.new(watchlist)
      assert %Watchlist{symbols: []} = Watchlist.new(put(watchlist, :symbols, []))
      assert %NewsItem{symbols: ["AAPL"]} = NewsItem.new(put(news, :symbols, ["AAPL"]))
    end

    test "a screener rank is a positive integer or nil, and metrics a map" do
      attrs = [symbol: "AAPL", screener: "top", provider: :reference]

      for bad <- [0, -1, 1.5, "1"], do: refuse(ScreenerResult, attrs, :rank, bad)

      refuse(ScreenerResult, attrs, :metrics, a: 1)
      assert %ScreenerResult{rank: 3} = ScreenerResult.new(put(attrs, :rank, 3))
      assert %ScreenerResult{rank: nil} = ScreenerResult.new(attrs)
    end

    test "an option chain's expiries are keyed on Dates" do
      attrs = [underlying: "XYZ", expiries: %{}, provider: :reference]

      refuse(OptionChain, attrs, :expiries, %{"2026-10-19" => %{}})
      chain = %{@date => %{dec("500") => %{}}}
      assert %OptionChain{} = OptionChain.new(put(attrs, :expiries, chain))
    end
  end

  describe "sign and magnitude" do
    test "option contract: strike and multiplier above zero, an expiry that is a Date" do
      attrs = [underlying: "XYZ", expiry: @date, strike: dec("500"), right: :call, provider: :ref]

      refuse(OptionContract, attrs, :strike, dec("0"))
      refuse(OptionContract, attrs, :multiplier, dec("-100"))
      refuse(OptionContract, attrs, :expiry, "2026-10-19")
      refuse(OptionContract, attrs, :mini, "yes")
      assert %OptionContract{} = OptionContract.new(put(attrs, :multiplier, dec("100")))
    end

    test "option greeks: open interest and implied volatility are not negative" do
      refuse(OptionGreeks, [provider: :ref], :open_interest, dec("-1"))
      refuse(OptionGreeks, [provider: :ref], :implied_volatility, dec("-3"))
      assert %OptionGreeks{} = OptionGreeks.new(delta: dec("-0.4"), provider: :ref)
    end

    test "fx rate and contract prices above zero, open interest not negative" do
      refuse(FxRate, [pair: "GBPUSD", as_of: @ts, provider: :ref], :rate, dec("0"))

      stats = [symbol: "BTC-PERP", provider: :reference]
      refuse(ContractStats, stats, :mark_price, dec("0"))
      refuse(ContractStats, stats, :open_interest, dec("-1"))
    end

    test "volume profile volumes are not negative, a delta is signed" do
      attrs = [symbol: "A", timeframe: "1h", opened_at: @ts, provider: :reference]

      refuse(VolumeProfile, attrs, :buy_volume, dec("-1"))
      assert %VolumeProfile{} = VolumeProfile.new(put(attrs, :delta, dec("-5")))
    end

    test "staking: balances and rates are not negative, a reward's accrual count is a count" do
      refuse(StakingBalance, [asset: "ETH", provider: :reference], :staked, dec("-1"))
      refuse(StakingRate, [asset: "ETH", provider: :reference], :apy_pct, dec("-1"))

      reward = [asset: "ETH", amount: dec("0.01"), provider: :reference]
      refuse(StakingReward, reward, :amount, dec("-1"))

      for bad <- [-1, 1.5, dec("2")], do: refuse(StakingReward, reward, :accrual_count, bad)

      assert %StakingReward{accrual_count: 0} = StakingReward.new(put(reward, :accrual_count, 0))
    end

    test "staking transaction: a positive amount and progress that is not negative" do
      tx = [id: "t", type: :unstake, asset: "ETH", amount: dec("1"), provider: :reference]

      refuse(StakingTransaction, tx, :amount, dec("0"))
      refuse(StakingTransaction, tx, :amount_remaining, dec("-1"))
      assert %StakingTransaction{} = StakingTransaction.new(put(tx, :amount_remaining, 0))
    end
  end

  describe "Withdrawal.new/1" do
    defp withdrawal do
      [id: "w", status: :requested, asset: "BTC", amount: dec("1"), provider: :reference]
    end

    test "an amount above zero and a fee that is not negative" do
      refuse(Withdrawal, withdrawal(), :amount, dec("0"))
      refuse(Withdrawal, withdrawal(), :fee, dec("-0.1"))
      assert %Withdrawal{} = Withdrawal.new(put(withdrawal(), :fee, dec("0")))
    end

    test "a broadcast withdrawal names its transaction, other statuses need not" do
      broadcast = put(withdrawal(), :status, :broadcast)

      for bad <- [nil, "", "  "], do: refuse(Withdrawal, broadcast, :tx_id, bad)

      assert %Withdrawal{tx_id: "0xdead"} = Withdrawal.new(put(broadcast, :tx_id, "0xdead"))
      assert %Withdrawal{tx_id: nil} = Withdrawal.new(withdrawal())
    end
  end
end
