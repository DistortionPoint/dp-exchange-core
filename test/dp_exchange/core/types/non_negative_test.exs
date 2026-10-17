defmodule DpExchange.Core.Types.NonNegativeTest do
  @moduledoc """
  A size, quantity or volume is never negative. A negative one is a decode bug (a flipped
  sign, a delta read as a level) and every value around it stays plausible, so each type's
  `new/1` refuses it by field name; zero and `nil` stay legal.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{Candle, Fill, Quote, TopOfBook, Trade, Validate}

  @ts ~U[2026-10-17 12:00:00Z]

  defp trade(quantity) do
    [
      id: "1",
      symbol: "BTC-USD",
      side: :buy,
      price: Decimal.new("100"),
      quantity: quantity,
      timestamp: @ts,
      provider: :reference
    ]
  end

  defp candle(volume) do
    [
      symbol: "BTC-USD",
      timeframe: "1h",
      opened_at: @ts,
      open: Decimal.new(1),
      high: Decimal.new(2),
      low: Decimal.new(1),
      close: Decimal.new(2),
      volume: volume,
      provider: :reference
    ]
  end

  defp top(bid_size, ask_size) do
    [
      symbol: "BTC-USD",
      bid: Decimal.new(1),
      ask: Decimal.new(2),
      bid_size: bid_size,
      ask_size: ask_size,
      observed_at: @ts,
      provider: :reference
    ]
  end

  defp fill(quantity) do
    [
      order_id: "o1",
      symbol: "BTC-USD",
      side: :buy,
      quantity: quantity,
      price: Decimal.new(1),
      fee: Decimal.new(0),
      timestamp: @ts,
      provider: :reference
    ]
  end

  test "Trade refuses a negative quantity, accepts zero" do
    assert_raise ArgumentError, ~r/quantity.*never negative/, fn ->
      Trade.new(trade(Decimal.new("-1")))
    end

    assert %Trade{} = Trade.new(trade(Decimal.new(0)))
  end

  test "Candle refuses a negative volume, accepts zero and nil" do
    assert_raise ArgumentError, ~r/volume.*never negative/, fn ->
      Candle.new(candle(Decimal.new("-0.5")))
    end

    assert %Candle{} = Candle.new(candle(Decimal.new(0)))
    assert %Candle{volume: nil} = Candle.new(candle(nil))
  end

  test "TopOfBook refuses a negative size on either side" do
    assert_raise ArgumentError, ~r/bid_size/, fn ->
      TopOfBook.new(top(Decimal.new(-1), Decimal.new(1)))
    end

    assert_raise ArgumentError, ~r/ask_size/, fn ->
      TopOfBook.new(top(Decimal.new(1), -2))
    end

    assert %TopOfBook{} = TopOfBook.new(top(Decimal.new(0), nil))
  end

  test "Fill refuses a negative quantity" do
    assert_raise ArgumentError, ~r/quantity.*never negative/, fn ->
      Fill.new(fill(Decimal.new("-3")))
    end
  end

  test "Quote refuses a negative volume" do
    assert_raise ArgumentError, ~r/volume.*never negative/, fn ->
      Quote.new(
        symbol: "BTC-USD",
        price: Decimal.new(1),
        volume: Decimal.new(-1),
        observed_at: @ts,
        provider: :reference
      )
    end
  end

  test "non_negative!/2 passes the struct through when every field is fine" do
    built = %Trade{Trade.new(trade(Decimal.new(2))) | id: "x"}

    assert Validate.non_negative!(built, [:quantity]) == built
  end
end
