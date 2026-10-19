defmodule DpExchange.Core.Types.BookLevelValuesTest do
  @moduledoc """
  The values a book level may hold, held at the constructor. `OrderBook`'s moduledoc says a
  negative size or a price `<= 0` refuses the whole book and a size of 0 is dropped from a
  snapshot; `new/1` used to check shape and order only, so a decoder that let one through
  built a book that every later calculation read as plausible.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{OrderBook, OrderBookDelta}

  @ts ~U[2026-10-19 12:00:00Z]

  defp dec(value), do: Decimal.new(value)

  defp book(overrides) do
    OrderBook.new(
      Keyword.merge(
        [
          symbol: "BTC-USD",
          bids: [{dec("100"), dec("1")}],
          asks: [{dec("101"), dec("1")}],
          observed_at: @ts,
          provider: :reference
        ],
        overrides
      )
    )
  end

  defp delta(levels) do
    OrderBookDelta.new(symbol: "BTC-USD", levels: levels, timestamp: @ts, provider: :reference)
  end

  describe "OrderBook.new/1 level values" do
    test "a book of positive prices and sizes builds" do
      assert %OrderBook{} = book([])
    end

    test "a price of zero, a negative price, a zero size and a negative size are each refused" do
      bad_levels = [
        {dec("0"), dec("1")},
        {dec("-1"), dec("1")},
        {dec("1"), dec("0")},
        {dec("1"), dec("-2")},
        {0, 1},
        {1, 0}
      ]

      for bad <- bad_levels do
        assert_raise ArgumentError, ~r/bids.*above zero/, fn -> book(bids: [bad]) end
        assert_raise ArgumentError, ~r/asks.*above zero/, fn -> book(asks: [bad]) end
      end
    end

    test "the refusal names the level and does not depend on where in the side it sits" do
      bids = [{dec("100"), dec("1")}, {dec("99"), dec("-3")}]

      assert_raise ArgumentError, ~r/-3/, fn -> book(bids: bids) end
    end
  end

  describe "OrderBookDelta.new/1 level values" do
    test "a removal (quantity zero) and an ordinary level build" do
      levels = [{:bid, dec("100"), dec("0")}, {:ask, dec("101"), dec("2")}]

      assert %OrderBookDelta{levels: ^levels} = delta(levels)
    end

    test "a negative quantity and a price at or below zero are refused" do
      bad_levels = [
        {:bid, dec("100"), dec("-1")},
        {:ask, dec("0"), dec("1")},
        {:ask, dec("-5"), dec("1")},
        {:bid, 0, 1}
      ]

      for bad <- bad_levels do
        assert_raise ArgumentError, ~r/levels.*above zero/, fn -> delta([bad]) end
      end
    end
  end
end
