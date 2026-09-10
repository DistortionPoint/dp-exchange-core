defmodule DpExchange.Core.TypesTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{Balance, Fill, Order, OrderBook, Quote, Trade}

  # What is worth testing about a struct is the part that can refuse: `@enforce_keys`.
  # Everything the contract calls load-bearing must be impossible to omit, because the
  # family's recurring failure mode is a plausible value with the wrong meaning — and a
  # missing timestamp silently becomes "now" in the mind of whoever reads it next.

  @ts ~U[2026-08-27 12:00:00Z]

  describe "every type refuses to be built without the fields the contract needs" do
    test "Quote requires symbol, price, observed_at and provider" do
      assert_raise ArgumentError, fn -> struct!(Quote, symbol: "BTC-USD") end
      assert_raise ArgumentError, fn -> struct!(Quote, %{symbol: "BTC-USD", price: dec(1)}) end
    end

    test "Trade requires its identity, side, price, quantity and time" do
      assert_raise ArgumentError, fn -> struct!(Trade, symbol: "BTC-USD", side: :buy) end
    end

    test "Fill requires the order it belongs to" do
      assert_raise ArgumentError, fn ->
        struct!(Fill, symbol: "BTC-USD", side: :buy, quantity: dec(1), price: dec(2))
      end
    end

    test "Order requires an id, side, type, quantity and status" do
      assert_raise ArgumentError, fn -> struct!(Order, symbol: "BTC-USD", side: :buy) end
    end

    test "OrderBook requires both sides and a time" do
      assert_raise ArgumentError, fn -> struct!(OrderBook, symbol: "BTC-USD", bids: []) end
    end
  end

  describe "Balance carries the moment we asked" do
    test "a balance cannot be built without a timestamp" do
      # The reason this field exists: a balance has no venue event time, so without
      # "when we asked" there is no way to tell a current balance from a stale one.
      assert_raise ArgumentError, fn ->
        struct!(Balance, currency: "USD", balance: dec(100), provider: :test_venue)
      end
    end

    test "a balance with a timestamp builds, and keeps the instant it was given" do
      balance = %Balance{
        currency: "USD",
        balance: dec(100),
        timestamp: @ts,
        provider: :test_venue
      }

      assert balance.timestamp == @ts
      assert balance.available_balance == nil
      assert balance.hold == nil
    end
  end

  describe "timestamps are the venue's own, never rewritten" do
    test "a Quote keeps the venue's instant it was constructed with, however old" do
      ancient = ~U[2019-01-01 00:00:00Z]

      quote_struct = %Quote{
        symbol: "BTC-USD",
        price: dec(42_000),
        venue_time: ancient,
        observed_at: ~U[2026-09-10 00:00:00Z],
        provider: :test_venue
      }

      assert quote_struct.venue_time == ancient
    end

    test "a Quote the venue gave no time for keeps venue_time nil, never a substituted clock" do
      # The whole reason `:timestamp` became two fields in 0.2.0. A venue that publishes no
      # time for a frame — Schwab's LEVELONE_* quotes, Gemini's partial-depth books — used
      # to leave a package choosing between lying in a field documented as the venue's and
      # dropping real data. `nil` here is information: the venue did not date this.
      quote_struct = %Quote{
        symbol: "BTC-USD",
        price: dec(42_000),
        observed_at: ~U[2026-09-10 00:00:00Z],
        provider: :test_venue
      }

      assert is_nil(quote_struct.venue_time)
      assert quote_struct.observed_at == ~U[2026-09-10 00:00:00Z]
    end

    test "observed_at is mandatory on a Quote, so no consumer has to invent a time" do
      # Requested by the consumer who decided this design (issue #31) and load-bearing: it
      # is what makes a nullable `venue_time` safe to honour strictly. Drop the guarantee
      # and every caller needs a fallback — the substitution this change removed, relocated
      # into consumer code.
      assert_raise ArgumentError, fn ->
        Quote.new(symbol: "BTC-USD", price: dec(1), provider: :test_venue)
      end
    end

    test "observed_at is mandatory on an OrderBook for the same reason" do
      assert_raise ArgumentError, fn ->
        OrderBook.new(symbol: "BTC-USD", bids: [], asks: [], provider: :test_venue)
      end
    end

    test "an OrderBook the venue gave no time for keeps venue_time nil" do
      book =
        OrderBook.new(
          symbol: "BTC-USD",
          bids: [],
          asks: [],
          observed_at: ~U[2026-09-10 00:00:00Z],
          provider: :test_venue
        )

      assert is_nil(book.venue_time)
    end

    test "an Order that the venue gave no times for keeps nil, not a substituted clock" do
      order = %Order{
        id: "abc",
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        quantity: dec(1),
        status: :open,
        provider: :test_venue
      }

      assert order.created_at == nil
      assert order.updated_at == nil
    end
  end

  describe "OrderBook levels" do
    test "holds {price, quantity} tuples on both sides" do
      book = %OrderBook{
        symbol: "BTC-USD",
        bids: [{dec(100), dec(2)}, {dec(99), dec(5)}],
        asks: [{dec(101), dec(1)}, {dec(102), dec(3)}],
        venue_time: @ts,
        observed_at: @ts,
        provider: :test_venue
      }

      assert [{best_bid, _bid_qty} | _rest_bids] = book.bids
      assert [{best_ask, _ask_qty} | _rest_asks] = book.asks
      assert Decimal.lt?(best_bid, best_ask)
      assert book.sequence == nil
    end
  end

  describe "Trade.broken defaults to false and never leaks nil (C7)" do
    # `:broken` is not `@enforce_keys`'d — a caller omitting it gets the documented
    # default. Before this fix, a PRESENT `broken: nil` (what a JSON decode produces from
    # a venue field that came back `null`) bypassed that default entirely and built
    # `%Trade{broken: nil}`, a value outside the `boolean()` typespec that only looked
    # safe because `nil` and `false` are both falsy in a bare `if`.
    @trade_attrs [
      id: "1",
      symbol: "BTC-USD",
      side: :buy,
      price: Decimal.new(1),
      quantity: Decimal.new(1),
      timestamp: ~U[2026-08-27 12:00:00Z],
      provider: :v
    ]

    test "omitted defaults to false" do
      assert Trade.new(@trade_attrs).broken == false
    end

    test "an explicit nil normalises to false rather than leaking through" do
      assert Trade.new(@trade_attrs ++ [broken: nil]).broken == false
    end

    test "an explicit true is kept" do
      assert Trade.new(@trade_attrs ++ [broken: true]).broken == true
    end

    test "an explicit false is kept" do
      assert Trade.new(@trade_attrs ++ [broken: false]).broken == false
    end
  end

  defp dec(n), do: Decimal.new(n)
end
