defmodule DpExchange.Core.Types.OrderBookDeltaTest do
  @moduledoc """
  `DpExchange.Core.Types.OrderBookDelta` — the incremental type that lets a venue package
  pass a book update straight through instead of accumulating one.

  What each test proves:

    * validation follows the same `nil`-vs-absent convention every other `Types.*` module
      has, so a decode bug here fails the same way it would anywhere else in the family
    * a zero-quantity level survives `new/1` completely unchanged — this type does not
      interpret "level ceased to exist" into a dropped entry or any other resolved form,
      because resolving it is the state-keeping this type exists to avoid
    * `:sequence` defaults to `nil`, the same convention `OrderBook` uses, so an absent
      sequence is never mistaken for "the first update"
    * the struct cannot be confused with `OrderBook` — no `:bids`/`:asks` keys exist on it —
      which is the type-level fix for the "read one delta as though it were the whole book"
      incident recorded in the moduledoc
    * levels keep the venue's own flat, mixed-side order rather than being split or re-sorted
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.OrderBookDelta

  @ts ~U[2026-09-06 12:00:00Z]

  defp valid_attrs(overrides \\ []) do
    Keyword.merge(
      [
        symbol: "BTC-USD",
        levels: [{:bid, Decimal.new("100.00"), Decimal.new("1.5")}],
        timestamp: @ts,
        provider: :reference
      ],
      overrides
    )
  end

  describe "new/1 — validation follows the shared Types.Validate convention" do
    test "builds with valid attrs" do
      assert %OrderBookDelta{symbol: "BTC-USD"} = OrderBookDelta.new(valid_attrs())
    end

    test "rejects a nil symbol" do
      assert_raise ArgumentError, ~r/symbol/, fn ->
        OrderBookDelta.new(valid_attrs(symbol: nil))
      end
    end

    test "rejects a nil levels" do
      assert_raise ArgumentError, ~r/levels/, fn ->
        OrderBookDelta.new(valid_attrs(levels: nil))
      end
    end

    test "rejects a nil timestamp" do
      assert_raise ArgumentError, ~r/timestamp/, fn ->
        OrderBookDelta.new(valid_attrs(timestamp: nil))
      end
    end

    test "rejects a nil provider" do
      assert_raise ArgumentError, ~r/provider/, fn ->
        OrderBookDelta.new(valid_attrs(provider: nil))
      end
    end

    test "an absent required field is rejected the same as an explicit nil" do
      assert_raise ArgumentError, fn ->
        OrderBookDelta.new(Keyword.delete(valid_attrs(), :timestamp))
      end
    end

    test "an empty levels list is not the same as a missing one, and is accepted" do
      # A delta frame that changed nothing is unusual but not invalid — the venue said so,
      # and this type does not second-guess it.
      assert %OrderBookDelta{levels: []} = OrderBookDelta.new(valid_attrs(levels: []))
    end
  end

  describe ":sequence defaults to nil, the same convention OrderBook uses" do
    test "not passing :sequence leaves it nil" do
      delta = OrderBookDelta.new(valid_attrs())
      assert delta.sequence == nil
    end

    test "an explicit sequence is carried through untouched" do
      delta = OrderBookDelta.new(valid_attrs(sequence: 42))
      assert delta.sequence == 42
    end
  end

  describe "a zero quantity is carried through unchanged — it is not resolved here" do
    test "new/1 does not drop, filter, or otherwise interpret a zero-quantity level" do
      zeroed = [{:bid, Decimal.new("100.00"), Decimal.new("0")}]

      delta = OrderBookDelta.new(valid_attrs(levels: zeroed))

      assert delta.levels == zeroed
      assert [{:bid, price, quantity}] = delta.levels
      assert Decimal.equal?(price, Decimal.new("100.00"))
      assert Decimal.equal?(quantity, Decimal.new("0"))
    end

    test "a mix of live and vanished levels in one delta both survive, untouched" do
      mixed = [
        {:bid, Decimal.new("100.00"), Decimal.new("2.0")},
        {:bid, Decimal.new("99.50"), Decimal.new("0")},
        {:ask, Decimal.new("101.00"), Decimal.new("0")}
      ]

      delta = OrderBookDelta.new(valid_attrs(levels: mixed))

      assert delta.levels == mixed
    end
  end

  describe "the shape itself — this cannot be mistaken for OrderBook" do
    test "carries no bids or asks keys" do
      delta = OrderBookDelta.new(valid_attrs())

      refute Map.has_key?(delta, :bids)
      refute Map.has_key?(delta, :asks)
    end

    test "carries a :levels key instead, holding the venue's own flat, mixed-side order" do
      # The venue's own delta frame interleaves sides in one ordered list — reshaping that
      # into per-side lists here would either drop the venue's ordering or invent one that
      # was never sent, so `new/1` must preserve it exactly as given.
      ordered = [
        {:ask, Decimal.new("101.00"), Decimal.new("3.0")},
        {:bid, Decimal.new("100.00"), Decimal.new("1.0")},
        {:ask, Decimal.new("101.50"), Decimal.new("0")}
      ]

      delta = OrderBookDelta.new(valid_attrs(levels: ordered))

      assert delta.levels == ordered
    end

    test "the struct name distinguishes it from OrderBook even holding equivalent data" do
      delta = OrderBookDelta.new(valid_attrs())
      refute match?(%DpExchange.Core.Types.OrderBook{}, delta)
    end
  end
end
