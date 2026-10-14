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
    OrderBookDelta,
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

    test "a Decimal with an absurd exponent is refused, in any field" do
      # `Decimal.parse("1e5000")` is a well-formed value. `Decimal.add/2` and `compare/2`
      # align exponents with `10^difference`, so one such price made a consumer's
      # `TopOfBook.mid/1` or `crossed?/1` allocate a number of that many digits.
      for exp <- [5_000, -5_000, 999_999_999] do
        huge = %Decimal{sign: 1, coef: 1, exp: exp}

        for field <- [:open, :close, :volume] do
          error =
            assert_raise ArgumentError, fn ->
              Candle.new(Keyword.put(@valid_candle, field, huge))
            end

          assert error.message =~ "exponent"
          assert error.message =~ Atom.to_string(field)
        end
      end

      # Decimal 3.2 refuses to parse "1e999999999" itself, but "1e5000" parses.
      {parsed, ""} = Decimal.parse("1e5000")
      broken = Keyword.put(@valid_candle, :high, parsed)
      assert_raise ArgumentError, ~r/exponent/, fn -> Candle.new(broken) end
    end

    test "the exponent bound is inclusive at +/-1000" do
      limit = Validate.max_decimal_exponent()
      assert limit == 1_000

      at_top = %Decimal{sign: 1, coef: 1, exp: limit}
      at_bottom = %Decimal{sign: 1, coef: 1, exp: -limit}
      past_top = %Decimal{sign: 1, coef: 1, exp: limit + 1}

      assert %Candle{} = Candle.new(Keyword.put(@valid_candle, :open, at_top))
      assert %Candle{} = Candle.new(Keyword.put(@valid_candle, :low, at_bottom))

      assert_raise ArgumentError, ~r/exponent/, fn ->
        Candle.new(Keyword.put(@valid_candle, :open, past_top))
      end
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

    test "rejects a status outside its vocabulary" do
      for bad <- ["quoted", :pending, :SETTLED] do
        assert_raise ArgumentError, ~r/status/, fn ->
          Conversion.new(Keyword.put(@valid, :status, bad))
        end
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

    test "rejects a kind outside its vocabulary" do
      for bad <- ["dividend", :merger] do
        assert_raise ArgumentError, ~r/kind/, fn ->
          CorporateEvent.new(Keyword.put(@valid, :kind, bad))
        end
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

    test "rejects a side or liquidity outside the vocabulary the type states" do
      # `:long` on a fill reads as no side to a consumer matching `:buy | :sell`, and
      # `"maker"` matches neither `:maker` nor `:taker`. Both built before.
      for bad <- [:long, "buy", :Buy, nil] do
        assert_raise ArgumentError, ~r/side|nil/, fn ->
          Fill.new(Keyword.put(@valid, :side, bad))
        end
      end

      for bad <- ["maker", :both] do
        assert_raise ArgumentError, ~r/liquidity/, fn ->
          Fill.new(Keyword.put(@valid, :liquidity, bad))
        end
      end

      for ok <- [:maker, :taker, nil] do
        assert %Fill{liquidity: ^ok} = Fill.new(Keyword.put(@valid, :liquidity, ok))
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

    test "rejects a kind outside its vocabulary" do
      for bad <- ["income", :ratios] do
        assert_raise ArgumentError, ~r/kind/, fn ->
          FinancialStatement.new(Keyword.put(@valid, :kind, bad))
        end
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

    test "rejects a right outside :call and :put" do
      for bad <- ["call", :CALL, :long] do
        assert_raise ArgumentError, ~r/right/, fn ->
          OptionContract.new(Keyword.put(@valid, :right, bad))
        end
      end

      assert %OptionContract{right: :put} = OptionContract.new(Keyword.put(@valid, :right, :put))
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

    test "accepts every order type Capabilities lets a venue declare, and nothing else" do
      for type <- [:trailing_stop, :trailing_stop_limit, :market_on_close, :limit_on_close] do
        assert %Order{order_type: ^type} = Order.new(Keyword.put(@valid, :order_type, type))
      end

      assert_raise ArgumentError, ~r/order_type/, fn ->
        Order.new(Keyword.put(@valid, :order_type, :trailing))
      end
    end

    test "still enforces PRESENCE of every enforced key, same as before this fix" do
      assert_raise ArgumentError, fn -> Order.new(Keyword.delete(@valid, :quantity)) end
    end

    test "refuses a side, order_type or status outside the vocabulary the types state" do
      # `"OPEN"` and `:canceled` are plausible venue spellings that match no branch of a
      # consumer's `case`; the moduledoc's answer for an unrecognised status is `nil`.
      for {field, bad} <- [side: "buy", side: :long, order_type: :trailing, status: :canceled] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Order.new(Keyword.put(@valid, field, bad))
        end
      end
    end

    test "accepts every atom the types state" do
      statuses = [:pending, :open, :partially_filled, :filled, :cancelled, :rejected, :expired]
      types = [:market, :limit, :stop, :stop_limit, :post_only, :ioc, :fok]

      for status <- statuses, type <- types do
        attrs = @valid |> Keyword.put(:status, status) |> Keyword.put(:order_type, type)
        assert %Order{} = Order.new(attrs)
      end
    end
  end

  describe "OrderBook.new/1" do
    @valid [symbol: "BTC-USD", bids: [], asks: [], observed_at: @ts, provider: :reference]

    test "builds with valid attrs" do
      assert %OrderBook{symbol: "BTC-USD"} = OrderBook.new(@valid)
    end

    test "rejects a nil observed_at" do
      assert_raise ArgumentError, ~r/observed_at/, fn ->
        OrderBook.new(Keyword.put(@valid, :observed_at, nil))
      end
    end

    test "rejects bids that rise or asks that fall, the best price must come first" do
      d = &Decimal.new/1

      assert_raise ArgumentError, ~r/bids.*not sorted/, fn ->
        OrderBook.new(Keyword.put(@valid, :bids, [{d.("99"), d.("1")}, {d.("100"), d.("1")}]))
      end

      assert_raise ArgumentError, ~r/asks.*not sorted/, fn ->
        OrderBook.new(Keyword.put(@valid, :asks, [{d.("102"), d.("1")}, {d.("101"), d.("1")}]))
      end

      sorted = [bids: [{d.("100"), d.("1")}, {d.("99"), d.("2")}], asks: [{d.("101"), d.("1")}]]
      assert %OrderBook{} = OrderBook.new(Keyword.merge(@valid, sorted))
    end

    test "rejects levels that are not {price, quantity} pairs" do
      for bad <- [:none, [{Decimal.new("1")}], [{"1", "1"}], [{Decimal.new("1"), nil}]] do
        assert_raise ArgumentError, ~r/bids.*pairs/, fn ->
          OrderBook.new(Keyword.put(@valid, :bids, bad))
        end
      end
    end
  end

  describe "OrderBookDelta.new/1 levels" do
    @delta [
      symbol: "BTC-USD",
      levels: [{:bid, Decimal.new("100"), Decimal.new("1")}],
      timestamp: @ts,
      provider: :reference
    ]

    test "rejects a level whose side is outside :bid | :ask, or that is not a triple" do
      bad_levels = [
        [{:buy, Decimal.new("100"), Decimal.new("1")}],
        [{"bid", Decimal.new("100"), Decimal.new("1")}],
        [{Decimal.new("100"), Decimal.new("1")}],
        :none
      ]

      for bad <- bad_levels do
        assert_raise ArgumentError, ~r/levels/, fn ->
          OrderBookDelta.new(Keyword.put(@delta, :levels, bad))
        end
      end
    end
  end

  describe "AuctionImbalance.new/1 auction" do
    test "rejects an auction outside :opening | :closing" do
      attrs = [symbol: "AAPL", auction: :midday, observed_at: @ts, provider: :reference]

      assert_raise ArgumentError, ~r/auction/, fn -> AuctionImbalance.new(attrs) end
    end
  end

  describe "OrderBookDelta.new/1" do
    @valid [
      symbol: "BTC-USD",
      levels: [{:bid, Decimal.new("100"), Decimal.new("1")}],
      timestamp: @ts,
      provider: :reference
    ]

    test "builds with valid attrs" do
      assert %OrderBookDelta{symbol: "BTC-USD"} = OrderBookDelta.new(@valid)
    end

    test "rejects a nil levels — the whole point of the type is what it changed" do
      assert_raise ArgumentError, ~r/levels/, fn ->
        OrderBookDelta.new(Keyword.put(@valid, :levels, nil))
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

    test "rejects a ratio that is not a positive integer" do
      # A ratio of 0 is a leg that trades nothing; 1.0 and a Decimal are counts a venue would
      # round. Each built before, and the spread still validated as a spread.
      for bad <- [0, -1, Decimal.new(1), "1"] do
        assert_raise ArgumentError, ~r/ratio.*positive integer/, fn ->
          OrderLeg.new(Keyword.put(@valid, :ratio, bad))
        end
      end

      # A float is refused for being a float, before the ratio check is reached.
      assert_raise ArgumentError, ~r/ratio.*float/, fn ->
        OrderLeg.new(Keyword.put(@valid, :ratio, 1.0))
      end
    end

    test "rejects a side or position effect outside the vocabulary the type states" do
      assert_raise ArgumentError, ~r/side/, fn ->
        OrderLeg.new(Keyword.put(@valid, :side, :long))
      end

      assert_raise ArgumentError, ~r/position_effect/, fn ->
        OrderLeg.new(Keyword.put(@valid, :position_effect, :flatten))
      end

      assert %OrderLeg{position_effect: :close} =
               OrderLeg.new(Keyword.put(@valid, :position_effect, :close))
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

    test "rejects a side that is not :long or :short" do
      # `:buy` is an order's side, not a position's. It built, and a consumer matching
      # `:long | :short` read it as no side or as the wrong one.
      for bad <- [:buy, :sell, "long", :Long] do
        assert_raise ArgumentError, ~r/side/, fn ->
          Position.new(Keyword.put(@valid, :side, bad))
        end
      end

      assert %Position{side: :short} = Position.new(Keyword.put(@valid, :side, :short))
    end
  end

  describe "Quote.new/1" do
    @valid [symbol: "BTC-USD", price: Decimal.new("100"), observed_at: @ts, provider: :reference]

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

    test "rejects a type outside its vocabulary" do
      for bad <- ["stake", :restake] do
        assert_raise ArgumentError, ~r/type/, fn ->
          StakingTransaction.new(Keyword.put(@valid, :type, bad))
        end
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

    test "accepts a nil id, because a venue tape can carry no trade id" do
      # `dp_exchange_webull`'s `tick` topic publishes no per-print identifier, on the socket
      # or on its REST tape, and says so in its usage rules. It could not call this
      # constructor — its own comment records that `Trade.new/1` "is deliberately not used
      # here: it would raise on the very absence this comment and the moduledoc both document
      # as real rather than accidental".
      #
      # A rule two packages route around is not a rule; it is a constructor nobody can use.
      assert %Trade{id: nil} = Trade.new(Keyword.put(@valid, :id, nil))
    end

    test "accepts a nil side, because a venue can decline to say who lifted" do
      # `dp_exchange_gemini`: "Absent means the venue did not say which side lifted, and
      # neither answer is honest." `dp_exchange_webull` matches only the venue's documented
      # `"B"`/`"S"` and answers `nil` otherwise — "a real trade with an unknown aggressor,
      # rather than a guess that would put volume on the wrong side of a delta".
      assert %Trade{side: nil} = Trade.new(Keyword.put(@valid, :side, nil))
    end

    test "rejects a side outside :buy | :sell | nil, and a broken that is not a boolean" do
      # `"buy"` and `:Buy` match neither branch of a consumer's `case`, so the volume lands on
      # no side and nothing says why.
      for bad <- ["buy", :Buy, :long] do
        assert_raise ArgumentError, ~r/side/, fn ->
          Trade.new(Keyword.put(@valid, :side, bad))
        end
      end

      assert_raise ArgumentError, ~r/broken/, fn ->
        Trade.new(Keyword.put(@valid, :broken, "yes"))
      end
    end

    test "still rejects the fields no venue has an honest nil for" do
      for field <- [:symbol, :price, :timestamp, :provider] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Trade.new(Keyword.put(@valid, field, nil))
        end
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

    test "rejects a status outside its vocabulary" do
      for bad <- ["requested", :settled] do
        assert_raise ArgumentError, ~r/status/, fn ->
          Withdrawal.new(Keyword.put(@valid, :status, bad))
        end
      end
    end
  end

  describe "one walk refuses floats, NaN and exponents (found 2026-10-14)" do
    @statement [symbol: "AAPL", kind: :income, provider: :reference]

    test "a float is allowed in a free-form map, NaN in the same map is not" do
      free_form = %{"margin" => 0.25, "n" => [1.5]}

      assert %FinancialStatement{} =
               FinancialStatement.new([{:line_items, free_form} | @statement])

      assert_raise ArgumentError, ~r/line_items.*NaN/, fn ->
        FinancialStatement.new([{:line_items, %{"x" => Decimal.new("NaN")}} | @statement])
      end
    end

    test "a float in a tuple nested in a list is refused, and an absurd exponent beside it" do
      assert_raise ArgumentError, ~r/line_items.*float/, fn ->
        FinancialStatement.new([{:line_items, [{:a, {:b, 1.5}}]} | @statement])
      end

      assert_raise ArgumentError, ~r/line_items.*exponent/, fn ->
        FinancialStatement.new([{:line_items, [{:a, Decimal.new("1e5000")}]} | @statement])
      end
    end
  end

  describe "unrepresentable values inside a level (found 2026-10-10)" do
    @book [symbol: "BTC-USD", asks: [], observed_at: @ts, provider: :reference]

    test "a float in a Decimal field or inside a level is refused, an integer is not" do
      assert_raise ArgumentError, ~r/bids.*float/, fn ->
        OrderBook.new(Keyword.put(@book, :bids, [{100.5, Decimal.new("1")}]))
      end

      assert_raise ArgumentError, ~r/price.*float/, fn ->
        Quote.new(
          symbol: "BTC-USD",
          price: 0.1,
          observed_at: @ts,
          provider: :reference
        )
      end

      assert %Quote{} =
               Quote.new(
                 symbol: "BTC-USD",
                 price: 1,
                 observed_at: @ts,
                 provider: :reference
               )
    end

    test "a NaN price inside an OrderBook level is refused" do
      bids = [{Decimal.new("100"), Decimal.new("1")}, {Decimal.new("NaN"), Decimal.new("1")}]

      assert_raise ArgumentError, ~r/bids.*NaN/, fn ->
        OrderBook.new(Keyword.put(@book, :bids, bids))
      end
    end

    test "an infinite quantity inside an OrderBookDelta level is refused" do
      levels = [{:ask, Decimal.new("100"), Decimal.new("Infinity")}]

      assert_raise ArgumentError, ~r/levels.*inf/, fn ->
        OrderBookDelta.new(
          symbol: "BTC-USD",
          levels: levels,
          timestamp: @ts,
          provider: :reference
        )
      end
    end

    test "a NaN volume inside a VolumeProfile price map is refused" do
      assert_raise ArgumentError, ~r/buy_at_price.*NaN/, fn ->
        VolumeProfile.new(
          symbol: "AAPL",
          timeframe: "1d",
          opened_at: @ts,
          provider: :reference,
          buy_at_price: %{"100" => Decimal.new("NaN")}
        )
      end
    end

    test "finite price maps still build" do
      profile =
        VolumeProfile.new(
          symbol: "AAPL",
          timeframe: "1d",
          opened_at: @ts,
          provider: :reference,
          buy_at_price: %{"100" => Decimal.new("5")}
        )

      assert VolumeProfile.point_of_control(profile) == "100"
    end

    test "an improper list is an ArgumentError naming the field, not a FunctionClauseError" do
      bids = [{Decimal.new("100"), Decimal.new("1")} | :tail]

      assert_raise ArgumentError, ~r/bids.*improper list/, fn ->
        OrderBook.new(Keyword.put(@book, :bids, bids))
      end
    end

    test "finite levels still build" do
      bids = [{Decimal.new("100"), Decimal.new("1")}]
      assert %OrderBook{bids: ^bids} = OrderBook.new(Keyword.put(@book, :bids, bids))
    end
  end

  describe "a Decimal field must hold a Decimal, an integer, or nil where the type allows it" do
    @candle [
      symbol: "BTC-USD",
      timeframe: "1h",
      opened_at: @ts,
      open: Decimal.new("100"),
      high: Decimal.new("110"),
      low: 95,
      close: Decimal.new("105"),
      provider: :reference
    ]

    test "Validate.decimals!/2 names module, field and a truncated value" do
      built = Candle.new(@candle)
      assert ^built = Validate.decimals!(built, [:open, :low, :volume])

      error =
        assert_raise ArgumentError, fn ->
          Validate.decimals!(%{built | open: String.duplicate("x", 500)}, [:open])
        end

      assert error.message =~ "Candle"
      assert error.message =~ ":open"
      assert error.message =~ "..."
      assert String.length(error.message) < 500
    end

    test "Validate.decimal!/3 and decimal_map_values!/2 accept Decimals and integers only" do
      assert :ok = Validate.decimal!(Candle, :open, Decimal.new("1"))
      assert :ok = Validate.decimal!(Candle, :open, 1)

      for bad <- ["1.5", "abc", %{}, :one, nil, [1]] do
        assert_raise ArgumentError, ~r/Candle.*:open/, fn ->
          Validate.decimal!(Candle, :open, bad)
        end
      end

      profile = VolumeProfile.new(symbol: "A", timeframe: "1d", opened_at: @ts, provider: :x)

      assert %VolumeProfile{buy_at_price: %{"1" => 2}} =
               Validate.decimal_map_values!(%{profile | buy_at_price: %{"1" => 2}}, [
                 :buy_at_price
               ])

      assert_raise ArgumentError, ~r/buy_at_price/, fn ->
        Validate.decimal_map_values!(%{profile | buy_at_price: [1]}, [:buy_at_price])
      end
    end

    test "Candle refuses a string, map or atom in any Decimal field; integer and nil pass" do
      for field <- [:open, :high, :low, :close, :volume], bad <- ["1.5", "abc", %{a: 1}, :x] do
        error =
          assert_raise ArgumentError, fn -> Candle.new(Keyword.put(@candle, field, bad)) end

        assert error.message =~ Atom.to_string(field)
      end

      assert %Candle{volume: 7} = Candle.new(Keyword.put(@candle, :volume, 7))
      assert %Candle{volume: nil} = Candle.new(Keyword.put(@candle, :volume, nil))
    end

    test "TopOfBook refuses a string bid and accepts Decimal, integer and nil" do
      base = [symbol: "BTC-USD", observed_at: @ts, provider: :reference]

      for field <- [:bid, :ask, :bid_size, :ask_size] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          TopOfBook.new(Keyword.put(base, field, "100.5"))
        end
      end

      assert %TopOfBook{bid: 100, ask: %Decimal{}} =
               TopOfBook.new([{:bid, 100}, {:ask, Decimal.new("101")} | base])

      assert %TopOfBook{bid: nil} = TopOfBook.new(Keyword.put(base, :bid, nil))
    end

    test "OrderBook levels refuse a string price or quantity (already per-element)" do
      for bad <- [[{"1", Decimal.new("1")}], [{Decimal.new("1"), "1"}]] do
        assert_raise ArgumentError, ~r/bids.*pairs/, fn ->
          OrderBook.new(
            symbol: "A",
            bids: bad,
            asks: [],
            observed_at: @ts,
            provider: :reference
          )
        end
      end
    end

    test "OrderBookDelta levels refuse a string price or quantity, accept Decimal and integer" do
      attrs = [symbol: "A", timestamp: @ts, provider: :reference]

      for bad <- [{:bid, "100", Decimal.new("1")}, {:ask, Decimal.new("100"), "1"}] do
        assert_raise ArgumentError, ~r/levels/, fn ->
          OrderBookDelta.new([{:levels, [bad]} | attrs])
        end
      end

      ok = [{:bid, Decimal.new("100"), 0}, {:ask, 101, Decimal.new("2")}]
      assert %OrderBookDelta{levels: ^ok} = OrderBookDelta.new([{:levels, ok} | attrs])
    end

    test "Fill and Order refuse a string in their Decimal fields" do
      fill = [
        order_id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("1"),
        price: Decimal.new("100"),
        timestamp: @ts,
        provider: :reference
      ]

      for field <- [:quantity, :price, :fee] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Fill.new(Keyword.put(fill, field, "1.5"))
        end
      end

      assert %Fill{quantity: 3, fee: nil} = Fill.new(Keyword.put(fill, :quantity, 3))

      order = [
        id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        quantity: Decimal.new("1"),
        status: :open,
        provider: :reference
      ]

      for field <- [:quantity, :price, :stop_price, :filled_quantity, :average_price, :fee] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Order.new(Keyword.put(order, field, "1.5"))
        end
      end

      assert %Order{quantity: nil} = Order.new(Keyword.put(order, :quantity, nil))
    end

    test "Trade, Quote, Position and Balance refuse a string" do
      assert_raise ArgumentError, ~r/price/, fn ->
        Trade.new(
          id: "t",
          symbol: "A",
          side: :buy,
          price: "1",
          quantity: 1,
          timestamp: @ts,
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/volume/, fn ->
        Quote.new(symbol: "A", price: 1, volume: "9", observed_at: @ts, provider: :x)
      end

      assert_raise ArgumentError, ~r/leverage/, fn ->
        Position.new(symbol: "A", side: :long, quantity: 1, leverage: "3", provider: :x)
      end

      assert_raise ArgumentError, ~r/hold/, fn ->
        Balance.new(currency: "USD", balance: 1, hold: "2", timestamp: @ts, provider: :x)
      end
    end

    test "the rest of the Decimal-bearing types refuse a string" do
      assert_raise ArgumentError, ~r/rate/, fn ->
        FxRate.new(pair: "GBPUSD", rate: "1.27", as_of: @ts, provider: :x)
      end

      assert_raise ArgumentError, ~r/strike/, fn ->
        OptionContract.new(
          underlying: "X",
          expiry: @date,
          strike: "500",
          right: :call,
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/delta/, fn ->
        OptionGreeks.new(provider: :x, delta: "0.5")
      end

      assert_raise ArgumentError, ~r/amount/, fn ->
        Withdrawal.new(id: "w", status: :requested, asset: "BTC", amount: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/amount/, fn ->
        StakingReward.new(asset: "ETH", amount: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/amount_remaining/, fn ->
        StakingTransaction.new(
          id: "t",
          type: :stake,
          asset: "ETH",
          amount: 1,
          amount_remaining: "1",
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/apy_pct/, fn ->
        StakingRate.new(asset: "ETH", apy_pct: "4.2", provider: :x)
      end

      assert_raise ArgumentError, ~r/staked/, fn ->
        StakingBalance.new(asset: "ETH", staked: "10", provider: :x)
      end

      assert_raise ArgumentError, ~r/by_provider/, fn ->
        StakingBalance.new(asset: "ETH", staked: 1, by_provider: %{"a" => "1"}, provider: :x)
      end

      assert_raise ArgumentError, ~r/mark_price/, fn ->
        ContractStats.new(symbol: "A", mark_price: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/amount/, fn ->
        Funding.new(symbol: "A", amount: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/fee/, fn ->
        Conversion.new(
          id: "q",
          status: :quoted,
          from_asset: "USD",
          to_asset: "BTC",
          fee: "1",
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/amount/, fn ->
        CorporateEvent.new(symbol: "A", kind: :dividend, amount: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/near_price/, fn ->
        AuctionImbalance.new(
          symbol: "A",
          auction: :closing,
          observed_at: @ts,
          near_price: "1",
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/total_volume/, fn ->
        VolumeProfile.new(
          symbol: "A",
          timeframe: "1d",
          opened_at: @ts,
          total_volume: "1",
          provider: :x
        )
      end

      assert_raise ArgumentError, ~r/buy_at_price/, fn ->
        VolumeProfile.new(
          symbol: "A",
          timeframe: "1d",
          opened_at: @ts,
          buy_at_price: %{"1" => "2"},
          provider: :x
        )
      end
    end

    test "OptionChain refuses a string underlying_price or strike key, accepts Decimals" do
      row = %{call: nil, put: nil}

      assert_raise ArgumentError, ~r/underlying_price/, fn ->
        OptionChain.new(underlying: "X", expiries: %{}, underlying_price: "1", provider: :x)
      end

      assert_raise ArgumentError, ~r/strike key/, fn ->
        OptionChain.new(underlying: "X", expiries: %{@date => %{"500" => row}}, provider: :x)
      end

      assert_raise ArgumentError, ~r/expiry to strikes/, fn ->
        OptionChain.new(underlying: "X", expiries: [], provider: :x)
      end

      assert_raise ArgumentError, ~r/map of Decimal strike/, fn ->
        OptionChain.new(underlying: "X", expiries: %{@date => []}, provider: :x)
      end

      chain =
        OptionChain.new(
          underlying: "X",
          expiries: %{@date => %{Decimal.new("500") => row}},
          underlying_price: 5,
          provider: :x
        )

      assert [%Decimal{}] = OptionChain.strikes(chain, @date)
    end
  end
end
