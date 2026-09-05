defmodule DpExchange.Core.Types.ValidateTest do
  @moduledoc """
  Regression coverage for C5: `@enforce_keys` guards presence, not `nil`.

  Before this fix, `%Candle{open: nil, high: ..., low: ..., close: ..., ...}` built
  without complaint despite `Candle`'s own typespec declaring `open: Decimal.t()` — never
  `Decimal.t() | nil` — and the failure only surfaced later, deep inside `Decimal`, far
  from the decode bug that actually produced the `nil`. `DpExchange.Core.Types.Validate`
  closes that gap, and every `Types.*` module now exposes a `new/1` built on it.

  This file tests the shared mechanism directly (against `Candle`, the module named in the
  design doc's own example), then proves every other type's `new/1` is actually wired to
  it — one `describe` block per module, each asserting a real build succeeds and a `nil` in
  a required field is rejected by name.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{
    ApprovedAddress,
    AuctionImbalance,
    Balance,
    Candle,
    ContractStats,
    Conversion,
    CorporateEvent,
    DepositAddress,
    Filing,
    Fill,
    FinancialStatement,
    Funding,
    FxRate,
    NewsItem,
    OptionChain,
    OptionContract,
    OptionGreeks,
    Order,
    OrderBook,
    OrderLeg,
    Portfolio,
    Position,
    Quote,
    ScreenerResult,
    StakingBalance,
    StakingRate,
    StakingReward,
    StakingTransaction,
    TopOfBook,
    Trade,
    Validate,
    VolumeProfile,
    Watchlist,
    Withdrawal
  }

  @ts ~U[2026-09-05 12:00:00Z]
  @date ~D[2026-03-15]

  describe "Validate.new!/3 — the mechanism, against the module the design doc used" do
    @valid_candle [
      symbol: "BTC-USD",
      timeframe: "1h",
      opened_at: @ts,
      open: Decimal.new("100"),
      high: Decimal.new("110"),
      low: Decimal.new("95"),
      close: Decimal.new("105"),
      provider: :reference
    ]

    test "builds the struct when every required field is present and non-nil" do
      required = [:symbol, :timeframe, :opened_at, :open, :high, :low, :close, :provider]
      assert %Candle{} = Validate.new!(Candle, required, @valid_candle)
    end

    test "THE regression: a nil in a required field is rejected, not silently accepted" do
      # This is exactly the scenario C5 was written against: a decode bug on a renamed
      # venue key (`Map.get(json, "open")` on a key that does not exist) produces `open:
      # nil`, and `%Candle{open: nil, ...}` — the direct struct literal — builds fine
      # despite the typespec. `new/1` must not.
      broken = Keyword.put(@valid_candle, :open, nil)

      assert_raise ArgumentError, ~r/open/, fn -> Candle.new(broken) end
    end

    test "the raised message names the module and the field, not just 'nil'" do
      broken = Keyword.put(@valid_candle, :close, nil)

      error =
        assert_raise ArgumentError, fn -> Candle.new(broken) end

      assert error.message =~ "Candle"
      assert error.message =~ "close"
    end

    test "an absent required field is still rejected, same as before this fix" do
      # `@enforce_keys` already caught this half of the trap; `new/1` must not regress it.
      assert_raise ArgumentError, fn ->
        Candle.new(Keyword.delete(@valid_candle, :high))
      end
    end

    test "a field that is not in required_non_nil may still be nil" do
      # `Validate.new!/3` only checks the fields it is told to — `Candle` has no optional
      # enforced fields, so this is asserted against a field outside `@enforce_keys`
      # entirely (`:volume`), which must pass through untouched.
      assert %Candle{volume: nil} = Candle.new(@valid_candle)
    end

    test "does not coerce, default, or guess — it only accepts or refuses" do
      built = Candle.new(@valid_candle)
      assert Decimal.equal?(built.open, Decimal.new("100"))
    end
  end

  describe "ApprovedAddress.new/1" do
    @valid [address: "0xabc", network: "ethereum", status: :active, provider: :reference]

    test "builds with valid attrs" do
      assert %ApprovedAddress{status: :active} = ApprovedAddress.new(@valid)
    end

    test "rejects a nil provider" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        ApprovedAddress.new(Keyword.put(@valid, :provider, nil))
      end
    end
  end

  describe "AuctionImbalance.new/1" do
    @valid [symbol: "AAPL", auction: :closing, observed_at: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %AuctionImbalance{auction: :closing} = AuctionImbalance.new(@valid)
    end

    test "rejects a nil observed_at" do
      assert_raise ArgumentError, ~r/observed_at/, fn ->
        AuctionImbalance.new(Keyword.put(@valid, :observed_at, nil))
      end
    end
  end

  describe "Balance.new/1" do
    @valid [currency: "USD", balance: Decimal.new("100"), timestamp: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %Balance{currency: "USD"} = Balance.new(@valid)
    end

    test "rejects a nil timestamp — a balance with no freshness is indistinguishable from stale" do
      assert_raise ArgumentError, ~r/timestamp/, fn ->
        Balance.new(Keyword.put(@valid, :timestamp, nil))
      end
    end
  end

  describe "ContractStats.new/1" do
    @valid [symbol: "BTC-PERP", provider: :reference]

    test "builds with valid attrs" do
      assert %ContractStats{symbol: "BTC-PERP"} = ContractStats.new(@valid)
    end

    test "rejects a nil provider" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        ContractStats.new(Keyword.put(@valid, :provider, nil))
      end
    end
  end

  describe "Conversion.new/1" do
    @valid [id: "q-1", status: :quoted, from_asset: "USD", to_asset: "BTC", provider: :reference]

    test "builds with valid attrs" do
      assert %Conversion{status: :quoted} = Conversion.new(@valid)
    end

    test "rejects a nil status" do
      assert_raise ArgumentError, ~r/status/, fn ->
        Conversion.new(Keyword.put(@valid, :status, nil))
      end
    end
  end

  describe "CorporateEvent.new/1" do
    @valid [symbol: "AAPL", kind: :dividend, provider: :reference]

    test "builds with valid attrs" do
      assert %CorporateEvent{kind: :dividend} = CorporateEvent.new(@valid)
    end

    test "rejects a nil kind" do
      assert_raise ArgumentError, ~r/kind/, fn ->
        CorporateEvent.new(Keyword.put(@valid, :kind, nil))
      end
    end
  end

  describe "DepositAddress.new/1" do
    @valid [asset: "USDC", network: "ethereum", address: "0xabc", provider: :reference]

    test "builds with valid attrs" do
      assert %DepositAddress{asset: "USDC"} = DepositAddress.new(@valid)
    end

    test "rejects a nil network — an address without one is not safely usable" do
      assert_raise ArgumentError, ~r/network/, fn ->
        DepositAddress.new(Keyword.put(@valid, :network, nil))
      end
    end
  end

  describe "Filing.new/1" do
    @valid [symbol: "AAPL", provider: :reference]

    test "builds with valid attrs" do
      assert %Filing{symbol: "AAPL"} = Filing.new(@valid)
    end

    test "rejects a nil symbol" do
      assert_raise ArgumentError, ~r/symbol/, fn ->
        Filing.new(Keyword.put(@valid, :symbol, nil))
      end
    end
  end

  describe "Fill.new/1" do
    @valid [
      order_id: "o-1",
      symbol: "BTC-USD",
      side: :buy,
      quantity: Decimal.new("1"),
      price: Decimal.new("100"),
      timestamp: @ts,
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %Fill{order_id: "o-1"} = Fill.new(@valid)
    end

    test "rejects a nil price" do
      assert_raise ArgumentError, ~r/price/, fn ->
        Fill.new(Keyword.put(@valid, :price, nil))
      end
    end
  end

  describe "FinancialStatement.new/1" do
    @valid [symbol: "AAPL", kind: :income, line_items: %{}, provider: :reference]

    test "builds with valid attrs" do
      assert %FinancialStatement{kind: :income} = FinancialStatement.new(@valid)
    end

    test "rejects nil line_items" do
      assert_raise ArgumentError, ~r/line_items/, fn ->
        FinancialStatement.new(Keyword.put(@valid, :line_items, nil))
      end
    end
  end

  describe "Funding.new/1" do
    @valid [symbol: "BTC-PERP", provider: :reference]

    test "builds with valid attrs" do
      assert %Funding{symbol: "BTC-PERP"} = Funding.new(@valid)
    end

    test "rejects a nil provider" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        Funding.new(Keyword.put(@valid, :provider, nil))
      end
    end
  end

  describe "FxRate.new/1" do
    @valid [pair: "GBPUSD", rate: Decimal.new("1.27"), as_of: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %FxRate{pair: "GBPUSD"} = FxRate.new(@valid)
    end

    test "rejects a nil rate" do
      assert_raise ArgumentError, ~r/rate/, fn ->
        FxRate.new(Keyword.put(@valid, :rate, nil))
      end
    end
  end

  describe "NewsItem.new/1" do
    @valid [id: "n-1", provider: :reference]

    test "builds with valid attrs" do
      assert %NewsItem{id: "n-1"} = NewsItem.new(@valid)
    end

    test "rejects a nil id" do
      assert_raise ArgumentError, ~r/id/, fn ->
        NewsItem.new(Keyword.put(@valid, :id, nil))
      end
    end
  end

  describe "OptionChain.new/1" do
    @valid [underlying: "XYZ", expiries: %{}, provider: :reference]

    test "builds with valid attrs" do
      assert %OptionChain{underlying: "XYZ"} = OptionChain.new(@valid)
    end

    test "rejects nil expiries" do
      assert_raise ArgumentError, ~r/expiries/, fn ->
        OptionChain.new(Keyword.put(@valid, :expiries, nil))
      end
    end
  end

  describe "OptionContract.new/1" do
    @valid [
      underlying: "XYZ",
      expiry: @date,
      strike: Decimal.new("500"),
      right: :call,
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %OptionContract{right: :call} = OptionContract.new(@valid)
    end

    test "rejects a nil strike" do
      assert_raise ArgumentError, ~r/strike/, fn ->
        OptionContract.new(Keyword.put(@valid, :strike, nil))
      end
    end
  end

  describe "OptionGreeks.new/1" do
    @valid [provider: :reference]

    test "builds with valid attrs" do
      assert %OptionGreeks{provider: :reference} = OptionGreeks.new(@valid)
    end

    test "rejects a nil provider — the only field this type enforces" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        OptionGreeks.new(Keyword.put(@valid, :provider, nil))
      end
    end
  end

  describe "Order.new/1 — only :provider is required non-nil, by design" do
    @valid [
      id: "o-1",
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      quantity: Decimal.new("1"),
      status: :open,
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %Order{status: :open} = Order.new(@valid)
    end

    test "rejects a nil provider" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        Order.new(Keyword.put(@valid, :provider, nil))
      end
    end

    test "does NOT reject a nil id — Robinhood's cancel acknowledgement has one and nothing else" do
      # This is the case `Order`'s moduledoc was widened for. A validating constructor
      # that rejected `id: nil` would break it, which is exactly why `new/1` here uses a
      # narrower `required_non_nil` than `@enforce_keys`.
      assert %Order{id: nil} = Order.new(Keyword.put(@valid, :id, nil))
    end

    test "does not reject a nil side, order_type, or status either — the venue's word, or nothing" do
      assert %Order{side: nil} = Order.new(Keyword.put(@valid, :side, nil))
      assert %Order{order_type: nil} = Order.new(Keyword.put(@valid, :order_type, nil))
      assert %Order{status: nil} = Order.new(Keyword.put(@valid, :status, nil))
    end

    test "still enforces PRESENCE of every enforced key, same as before this fix" do
      assert_raise ArgumentError, fn -> Order.new(Keyword.delete(@valid, :quantity)) end
    end
  end

  describe "OrderBook.new/1" do
    @valid [symbol: "BTC-USD", bids: [], asks: [], timestamp: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %OrderBook{symbol: "BTC-USD"} = OrderBook.new(@valid)
    end

    test "rejects a nil timestamp" do
      assert_raise ArgumentError, ~r/timestamp/, fn ->
        OrderBook.new(Keyword.put(@valid, :timestamp, nil))
      end
    end
  end

  describe "OrderLeg.new/1" do
    @valid [symbol: "AAPL 240315C00500000", side: :buy, ratio: 1]

    test "builds with valid attrs" do
      assert %OrderLeg{ratio: 1} = OrderLeg.new(@valid)
    end

    test "rejects a nil ratio" do
      assert_raise ArgumentError, ~r/ratio/, fn ->
        OrderLeg.new(Keyword.put(@valid, :ratio, nil))
      end
    end
  end

  describe "Portfolio.new/1" do
    @valid [id: "p-1", provider: :reference]

    test "builds with valid attrs" do
      assert %Portfolio{id: "p-1"} = Portfolio.new(@valid)
    end

    test "rejects a nil id" do
      assert_raise ArgumentError, ~r/id/, fn ->
        Portfolio.new(Keyword.put(@valid, :id, nil))
      end
    end
  end

  describe "Position.new/1" do
    @valid [symbol: "BTC-PERP", side: :long, quantity: Decimal.new("1"), provider: :reference]

    test "builds with valid attrs" do
      assert %Position{side: :long} = Position.new(@valid)
    end

    test "rejects a nil side" do
      assert_raise ArgumentError, ~r/side/, fn ->
        Position.new(Keyword.put(@valid, :side, nil))
      end
    end
  end

  describe "Quote.new/1" do
    @valid [symbol: "BTC-USD", price: Decimal.new("100"), timestamp: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %Quote{symbol: "BTC-USD"} = Quote.new(@valid)
    end

    test "rejects a nil price" do
      assert_raise ArgumentError, ~r/price/, fn ->
        Quote.new(Keyword.put(@valid, :price, nil))
      end
    end
  end

  describe "ScreenerResult.new/1" do
    @valid [symbol: "AAPL", screener: "top_gainers", provider: :reference]

    test "builds with valid attrs" do
      assert %ScreenerResult{screener: "top_gainers"} = ScreenerResult.new(@valid)
    end

    test "rejects a nil screener" do
      assert_raise ArgumentError, ~r/screener/, fn ->
        ScreenerResult.new(Keyword.put(@valid, :screener, nil))
      end
    end
  end

  describe "StakingBalance.new/1" do
    @valid [asset: "ETH", staked: Decimal.new("10"), provider: :reference]

    test "builds with valid attrs" do
      assert %StakingBalance{asset: "ETH"} = StakingBalance.new(@valid)
    end

    test "rejects a nil staked" do
      assert_raise ArgumentError, ~r/staked/, fn ->
        StakingBalance.new(Keyword.put(@valid, :staked, nil))
      end
    end
  end

  describe "StakingRate.new/1" do
    @valid [asset: "ETH", provider: :reference]

    test "builds with valid attrs" do
      assert %StakingRate{asset: "ETH"} = StakingRate.new(@valid)
    end

    test "rejects a nil asset" do
      assert_raise ArgumentError, ~r/asset/, fn ->
        StakingRate.new(Keyword.put(@valid, :asset, nil))
      end
    end
  end

  describe "StakingReward.new/1" do
    @valid [asset: "ETH", amount: Decimal.new("0.01"), provider: :reference]

    test "builds with valid attrs" do
      assert %StakingReward{asset: "ETH"} = StakingReward.new(@valid)
    end

    test "rejects a nil amount" do
      assert_raise ArgumentError, ~r/amount/, fn ->
        StakingReward.new(Keyword.put(@valid, :amount, nil))
      end
    end
  end

  describe "StakingTransaction.new/1" do
    @valid [id: "t-1", type: :stake, asset: "ETH", amount: Decimal.new("1"), provider: :reference]

    test "builds with valid attrs" do
      assert %StakingTransaction{type: :stake} = StakingTransaction.new(@valid)
    end

    test "rejects a nil type" do
      assert_raise ArgumentError, ~r/type/, fn ->
        StakingTransaction.new(Keyword.put(@valid, :type, nil))
      end
    end
  end

  describe "TopOfBook.new/1" do
    @valid [symbol: "BTC-USD", observed_at: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %TopOfBook{symbol: "BTC-USD"} = TopOfBook.new(@valid)
    end

    test "rejects a nil observed_at" do
      assert_raise ArgumentError, ~r/observed_at/, fn ->
        TopOfBook.new(Keyword.put(@valid, :observed_at, nil))
      end
    end
  end

  describe "Trade.new/1" do
    @valid [
      id: "t-1",
      symbol: "BTC-USD",
      side: :buy,
      price: Decimal.new("100"),
      quantity: Decimal.new("1"),
      timestamp: @ts,
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %Trade{id: "t-1"} = Trade.new(@valid)
    end

    test "rejects a nil quantity" do
      assert_raise ArgumentError, ~r/quantity/, fn ->
        Trade.new(Keyword.put(@valid, :quantity, nil))
      end
    end
  end

  describe "VolumeProfile.new/1" do
    @valid [symbol: "AAPL", timeframe: "5m", opened_at: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %VolumeProfile{symbol: "AAPL"} = VolumeProfile.new(@valid)
    end

    test "rejects a nil opened_at" do
      assert_raise ArgumentError, ~r/opened_at/, fn ->
        VolumeProfile.new(Keyword.put(@valid, :opened_at, nil))
      end
    end
  end

  describe "Watchlist.new/1" do
    @valid [id: "w-1", provider: :reference]

    test "builds with valid attrs" do
      assert %Watchlist{id: "w-1"} = Watchlist.new(@valid)
    end

    test "rejects a nil id" do
      assert_raise ArgumentError, ~r/id/, fn ->
        Watchlist.new(Keyword.put(@valid, :id, nil))
      end
    end
  end

  describe "Withdrawal.new/1" do
    @valid [
      id: "wd-1",
      status: :requested,
      asset: "BTC",
      amount: Decimal.new("0.5"),
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %Withdrawal{status: :requested} = Withdrawal.new(@valid)
    end

    test "rejects a nil amount" do
      assert_raise ArgumentError, ~r/amount/, fn ->
        Withdrawal.new(Keyword.put(@valid, :amount, nil))
      end
    end
  end
end
