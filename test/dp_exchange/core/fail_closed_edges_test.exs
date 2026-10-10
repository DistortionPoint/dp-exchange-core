defmodule DpExchange.Core.FailClosedEdgesTest do
  @moduledoc """
  Inputs that used to be accepted, or refused for the wrong reason, found reviewing the
  contract and value types on 2026-10-10.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, Notice, Telemetry, Timeframe}
  alias DpExchange.Core.Types.Quote

  describe "Timeframe" do
    test "an exact boundary at millisecond precision is aligned" do
      at = DateTime.from_unix!(1_700_006_400_000, :millisecond)

      assert at.microsecond == {0, 3}
      assert Timeframe.aligned?(at, "1h")
      refute Timeframe.aligned?(DateTime.add(at, 1, :millisecond), "1h")
    end

    test "a time before 1970 falls in its own bucket, not the next one" do
      at = DateTime.from_unix!(-1)
      assert Timeframe.boundary(at, "1h") == DateTime.from_unix!(-3_600)
    end
  end

  describe "Validate refuses what no field can carry" do
    @valid [symbol: "BTC-USD", observed_at: ~U[2026-10-10 00:00:00Z], provider: :x]

    test "a NaN or infinite Decimal" do
      for bad <- [Decimal.new("NaN"), Decimal.new("Infinity"), Decimal.new("-Infinity")] do
        assert_raise ArgumentError, ~r/not a number/, fn ->
          Quote.new([price: bad] ++ @valid)
        end
      end
    end

    test "a NaiveDateTime where a DateTime is promised" do
      assert_raise ArgumentError, ~r/NaiveDateTime/, fn ->
        Quote.new(Keyword.put(@valid, :observed_at, ~N[2026-10-10 00:00:00]) ++ [price: 1])
      end
    end
  end

  describe "Notice" do
    test "a header spelling of a credential key is refused" do
      for key <- ["api-key", "X-Api-Key", "client_secret"] do
        assert_raise ArgumentError, ~r/credential-shaped/, fn ->
          Notice.new(:degraded, :v, details: %{key => "x"})
        end
      end
    end

    test "a nil provider or a NaiveDateTime :at is refused" do
      assert_raise ArgumentError, ~r/provider/, fn -> Notice.new(:link_up, nil) end

      assert_raise ArgumentError, ~r/DateTime/, fn ->
        Notice.new(:link_up, :v, at: ~N[2026-10-10 00:00:00])
      end
    end
  end

  describe "Telemetry" do
    test "link_down/2 takes a raw reason instead of raising into the feed" do
      assert :ok = Telemetry.link_down(:v, {:closed, :econnreset})
    end

    test "endpoint/1 strips userinfo and the fragment as well as the query" do
      assert Telemetry.endpoint("https://user:pass@api.venue.test/v1/x?token=1#frag") ==
               "https://api.venue.test/v1/x"
    end
  end

  describe "Capabilities" do
    test "max_leverage must be positive and finite" do
      for bad <- [Decimal.new(0), Decimal.new(-2), Decimal.new("NaN")] do
        assert_raise ArgumentError, fn ->
          Capabilities.new(supports_margin: true, max_leverage: bad)
        end
      end
    end
  end
end
