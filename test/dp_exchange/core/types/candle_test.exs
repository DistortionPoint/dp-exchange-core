defmodule DpExchange.Core.Types.CandleTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.Candle

  defp candle(o, h, l, c) do
    %Candle{
      symbol: "BTC-USD",
      timeframe: "1h",
      opened_at: ~U[2026-08-31 12:00:00Z],
      open: Decimal.new(o),
      high: Decimal.new(h),
      low: Decimal.new(l),
      close: Decimal.new(c),
      provider: :reference
    }
  end

  describe "coherent?/1" do
    test "a well-formed bar is coherent" do
      assert Candle.coherent?(candle("100", "110", "95", "105"))
    end

    test "a high below the close is not" do
      # Worth catching at the boundary: every range, breakout and volatility calculation
      # built on the series would be silently wrong, and none of them would error.
      refute Candle.coherent?(candle("100", "104", "95", "105"))
    end

    test "a low above the open is not" do
      refute Candle.coherent?(candle("100", "110", "101", "105"))
    end

    test "a flat bar where all four are equal is coherent" do
      assert Candle.coherent?(candle("100", "100", "100", "100"))
    end
  end

  describe "the shape" do
    test "the time field is named for the convention it holds" do
      # Venues disagree about whether a bar is stamped at open or close, and the difference
      # is a whole interval. A field called `timestamp` would hide which one this is.
      c = candle("100", "110", "95", "105")
      assert c.opened_at
      refute Map.has_key?(c, :timestamp)
    end

    test "volume defaults to nil, not zero" do
      # One venue reports no crypto volume anywhere; a 0 would claim a flat interval.
      assert candle("100", "110", "95", "105").volume == nil
    end

    test "all four prices are required" do
      assert_raise ArgumentError, fn ->
        struct!(Candle,
          symbol: "BTC-USD",
          timeframe: "1h",
          opened_at: ~U[2026-08-31 12:00:00Z],
          open: Decimal.new("1"),
          provider: :reference
        )
      end
    end
  end
end
