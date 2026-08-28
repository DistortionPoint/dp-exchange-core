defmodule DpExchange.Core.TimeframeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Timeframe

  doctest Timeframe

  describe "seconds/1 fails closed rather than defaulting" do
    test "returns the width of every modelled timeframe" do
      assert {:ok, 60} = Timeframe.seconds("1m")
      assert {:ok, 3_600} = Timeframe.seconds("1h")
      assert {:ok, 86_400} = Timeframe.seconds("1d")
    end

    test "an unmodelled width is :error, not the nearest one" do
      # This is the whole point of the function. A `1w` silently becoming `1d`
      # mis-buckets every candle it touches, and every value stays plausible.
      assert :error = Timeframe.seconds("1w")
      assert :error = Timeframe.seconds("1M")
      assert :error = Timeframe.seconds("3m")
    end

    test "non-binary input is :error rather than a crash" do
      assert :error = Timeframe.seconds(:"1m")
      assert :error = Timeframe.seconds(60)
      assert :error = Timeframe.seconds(nil)
    end
  end

  describe "known/0" do
    test "lists every modelled timeframe shortest first" do
      known = Timeframe.known()

      assert "1m" == hd(known)
      assert "1d" == List.last(known)

      widths =
        Enum.map(known, fn tf ->
          {:ok, s} = Timeframe.seconds(tf)
          s
        end)

      assert widths == Enum.sort(widths)
    end

    test "every listed timeframe has a width" do
      for tf <- Timeframe.known() do
        assert {:ok, _width} = Timeframe.seconds(tf)
      end
    end
  end

  describe "aligned?/2 — the cheap test of authenticity" do
    test "a real bucket-start passes" do
      assert Timeframe.aligned?(~U[2026-08-06 00:00:00Z], "1d")
      assert Timeframe.aligned?(~U[2026-08-06 12:00:00Z], "4h")
      assert Timeframe.aligned?(~U[2026-08-06 12:05:00Z], "5m")
    end

    test "an off-boundary instant fails" do
      refute Timeframe.aligned?(~U[2026-08-06 00:00:01Z], "1d")
      refute Timeframe.aligned?(~U[2026-08-06 13:00:00Z], "4h")
    end

    test "the 2026-08-06 fabricated-candle shape is caught" do
      # The live incident this function exists for: a venue adapter, short of real
      # history, synthesised candles at `now - i * granularity` — arbitrary
      # sub-second instants carrying prices from a hardcoded table, tagged "1d" and
      # fed to backtests. Nothing downstream could tell them from real bars.
      fabricated = ~U[2026-08-04 16:01:33.654710Z]
      real = ~U[2026-08-06 00:00:00Z]

      refute Timeframe.aligned?(fabricated, "1d")
      assert Timeframe.aligned?(real, "1d")
    end

    test "sub-second precision fails even on an otherwise-aligned second" do
      {:ok, with_micros} = DateTime.new(~D[2026-08-06], ~T[00:00:00.000001])
      refute Timeframe.aligned?(with_micros, "1d")
    end

    test "an unmodelled timeframe returns true — no rule is not the same as invalid" do
      # Returning false here would reject all of a venue's real data for the sole
      # reason that we do not model its width.
      assert Timeframe.aligned?(~U[2026-08-04 16:01:33Z], "1w")
      assert Timeframe.aligned?(~U[2026-08-04 16:01:33Z], "1M")
    end

    test "a non-DateTime is not aligned" do
      refute Timeframe.aligned?("2026-08-06", "1d")
      refute Timeframe.aligned?(nil, "1d")
    end
  end

  describe "boundary/2" do
    test "truncates to the start of the containing bucket" do
      assert ~U[2026-08-06 00:00:00Z] = Timeframe.boundary(~U[2026-08-06 13:47:12Z], "1d")
      assert ~U[2026-08-06 12:00:00Z] = Timeframe.boundary(~U[2026-08-06 13:47:12Z], "4h")
      assert ~U[2026-08-06 13:45:00Z] = Timeframe.boundary(~U[2026-08-06 13:47:12Z], "15m")
    end

    test "is idempotent — a boundary is its own boundary" do
      for tf <- Timeframe.known() do
        once = Timeframe.boundary(~U[2026-08-06 13:47:12Z], tf)
        assert once == Timeframe.boundary(once, tf)
        assert Timeframe.aligned?(once, tf)
      end
    end

    test "an unmodelled timeframe returns the input untouched" do
      dt = ~U[2026-08-06 13:47:12Z]
      assert dt == Timeframe.boundary(dt, "1w")
    end
  end
end
