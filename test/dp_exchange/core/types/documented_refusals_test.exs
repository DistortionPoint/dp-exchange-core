defmodule DpExchange.Core.Types.DocumentedRefusalsTest do
  @moduledoc """
  Refusals the type docs state and `new/1` used to skip: a coherent bar, a traded price above
  zero, a resting bid or ask above zero (a venue's `0` is `nil`), and a position size above
  zero.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{Candle, Position, Quote, TopOfBook, Trade}

  @ts ~U[2026-10-19 12:00:00Z]

  defp dec(value), do: Decimal.new(value)

  defp candle(overrides) do
    Keyword.merge(
      [
        symbol: "BTC-USD",
        timeframe: "1h",
        opened_at: @ts,
        open: dec("100"),
        high: dec("110"),
        low: dec("95"),
        close: dec("105"),
        provider: :reference
      ],
      overrides
    )
  end

  describe "Candle.new/1 coherence" do
    test "a coherent bar builds, including a flat one" do
      assert %Candle{} = Candle.new(candle([]))
      flat = [open: dec("5"), high: dec("5"), low: dec("5"), close: dec("5")]
      assert %Candle{} = Candle.new(candle(flat))
    end

    test "a high below the low, or an open or close outside the range, is refused" do
      incoherent = [
        [high: dec("90")],
        [open: dec("111")],
        [open: dec("94")],
        [close: dec("111")],
        [close: dec("94")]
      ]

      for overrides <- incoherent do
        assert_raise ArgumentError, ~r/incoherent/, fn -> Candle.new(candle(overrides)) end
      end
    end

    test "a struct literal can still hold one, and coherent?/1 still says so" do
      bar = struct!(Candle, candle(high: dec("90")))
      refute Candle.coherent?(bar)
    end
  end

  describe "traded and resting prices" do
    test "Quote and Trade refuse a price of zero or less" do
      for bad <- [dec("0"), dec("-1"), 0] do
        assert_raise ArgumentError, ~r/price.*above zero/, fn ->
          Quote.new(symbol: "BTC-USD", price: bad, observed_at: @ts, provider: :reference)
        end

        assert_raise ArgumentError, ~r/price.*above zero/, fn ->
          Trade.new(
            id: "1",
            symbol: "BTC-USD",
            side: :buy,
            price: bad,
            quantity: dec("1"),
            timestamp: @ts,
            provider: :reference
          )
        end
      end
    end

    test "TopOfBook refuses a bid or ask of zero or less, and keeps nil as one-sided" do
      base = [symbol: "BTC-USD", observed_at: @ts, provider: :reference]

      for key <- [:bid, :ask], bad <- [dec("0"), dec("-1")] do
        assert_raise ArgumentError, ~r/#{key}.*above zero/, fn ->
          TopOfBook.new([{key, bad} | base])
        end
      end

      assert %TopOfBook{bid: nil, ask: nil} = TopOfBook.new(base)
    end
  end

  describe "Position.new/1 size" do
    test "a quantity of zero or less is refused, a positive one builds" do
      base = [symbol: "BTC-PERP", side: :long, provider: :reference]

      for bad <- [dec("0"), dec("-0.2"), 0] do
        assert_raise ArgumentError, ~r/quantity.*above zero/, fn ->
          Position.new([{:quantity, bad} | base])
        end
      end

      assert %Position{} = Position.new([{:quantity, dec("0.2")} | base])
    end
  end
end
