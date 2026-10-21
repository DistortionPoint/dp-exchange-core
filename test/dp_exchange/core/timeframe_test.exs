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

    test "the whole table is pinned, so a wrong width cannot hide among the unpinned ones" do
      expected = [
        {"1m", 60},
        {"5m", 300},
        {"10m", 600},
        {"15m", 900},
        {"30m", 1_800},
        {"1h", 3_600},
        {"2h", 7_200},
        {"4h", 14_400},
        {"6h", 21_600},
        {"12h", 43_200},
        {"1d", 86_400}
      ]

      for {label, width} <- expected do
        assert Timeframe.seconds(label) == {:ok, width}
      end

      assert Timeframe.known() == Enum.map(expected, &elem(&1, 0))
      assert Timeframe.nameable() == Timeframe.known() ++ ~w(1w 1M 1y)
    end

    test "10m is modelled — Schwab serves it, and 600 seconds is not ambiguous" do
      # Added when Schwab's /pricehistory turned out to serve a 10-minute candle.
      # Its absence here was not neutral: `aligned?/2` returns true for a width it
      # cannot model, so every 10m candle passed the authenticity check unexamined.
      assert {:ok, 600} = Timeframe.seconds("10m")
      boundary = Timeframe.boundary(~U[2026-08-31 14:07:33Z], "10m")
      assert DateTime.compare(boundary, ~U[2026-08-31 14:00:00Z]) == :eq
      refute Timeframe.aligned?(~U[2026-08-31 14:07:00Z], "10m")
      assert Timeframe.aligned?(~U[2026-08-31 14:10:00Z], "10m")
    end

    test "an unmodelled width is :error, not the nearest one" do
      # This is the whole point of the function. A `1w` silently becoming `1d`
      # mis-buckets every candle it touches, and every value stays plausible.
      assert :error = Timeframe.seconds("1w")
      assert :error = Timeframe.seconds("1M")
      assert :error = Timeframe.seconds("1y")
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

  describe "nameable/0 — wider than known/0, and that gap is the design" do
    test "every bucketable width is also nameable" do
      for tf <- Timeframe.known(), do: assert(Timeframe.nameable?(tf))
    end

    test "1w, 1M and 1y are nameable but have no width" do
      # The whole reason the two lists differ. A venue may serve a weekly, monthly or
      # yearly candle; nothing in Core can say where any of those buckets start (a week
      # depends on the venue's start-of-week, a month is not a fixed number of seconds,
      # and neither is a year — 365 or 366 days depending which one). Refusing the label
      # would force such a venue to under-declare what it serves — exactly what
      # `dp_exchange_webull` had to work around for `1y` until this widened (2026-09-06).
      for tf <- ~w(1w 1M 1y) do
        assert Timeframe.nameable?(tf)
        assert Timeframe.seconds(tf) == :error
        refute tf in Timeframe.known()
      end
    end

    test "a string outside the vocabulary is neither" do
      refute Timeframe.nameable?("3m")
      refute Timeframe.nameable?("2w")
      refute Timeframe.nameable?(:"1d")
      refute Timeframe.nameable?(nil)
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
      assert Timeframe.aligned?(~U[2026-08-04 16:01:33Z], "1y")
    end

    test "a non-DateTime is not aligned" do
      refute Timeframe.aligned?("2026-08-06", "1d")
      refute Timeframe.aligned?(nil, "1d")
    end
  end

  describe "boundary/2" do
    test "truncates to the start of the containing bucket" do
      at = ~U[2026-08-06 13:47:12Z]

      for {expected, width} <- [
            {~U[2026-08-06 00:00:00Z], "1d"},
            {~U[2026-08-06 12:00:00Z], "4h"},
            {~U[2026-08-06 13:45:00Z], "15m"}
          ] do
        assert DateTime.compare(Timeframe.boundary(at, width), expected) == :eq
      end
    end

    test "is idempotent — a boundary is its own boundary" do
      for tf <- Timeframe.known() do
        once = Timeframe.boundary(~U[2026-08-06 13:47:12Z], tf)
        assert DateTime.compare(once, Timeframe.boundary(once, tf)) == :eq
        assert Timeframe.aligned?(once, tf)
      end
    end

    test "a time before year 0 is bucketed, not raised on" do
      # `DateTime.from_unix!/1` raises "invalid Unix time" for any year before 0000, though a
      # `DateTime` is valid from -9999 and a venue timestamp with a bad year can build one.
      early = DateTime.new!(Date.new!(-1, 6, 15), ~T[10:30:00], "Etc/UTC")

      day = DateTime.new!(Date.new!(-1, 6, 15), ~T[00:00:00], "Etc/UTC")
      hour = DateTime.new!(Date.new!(-1, 6, 15), ~T[10:00:00], "Etc/UTC")

      assert DateTime.compare(Timeframe.boundary(early, "1d"), day) == :eq
      assert DateTime.compare(Timeframe.boundary(early, "1h"), hour) == :eq
    end

    test "an unmodelled timeframe returns the input untouched" do
      dt = ~U[2026-08-06 13:47:12Z]
      assert DateTime.compare(dt, Timeframe.boundary(dt, "1w")) == :eq
    end
  end
end
