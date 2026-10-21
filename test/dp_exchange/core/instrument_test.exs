defmodule DpExchange.Core.InstrumentTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Instrument

  doctest Instrument

  describe "new/1" do
    test "requires a symbol and defaults conservatively" do
      instrument = Instrument.new(symbol: "BTC-USD")

      assert instrument.symbol == "BTC-USD"
      assert instrument.instrument == :unknown
      # Not `:tradable`: an omitted status is no evidence the instrument can be traded.
      assert instrument.status == :unknown
      assert instrument.base == nil
      assert instrument.quote == nil
    end

    test "refuses to be built without a symbol" do
      assert_raise ArgumentError, fn -> Instrument.new(base: "BTC", quote: "USD") end
    end

    test "refuses to be built with an explicit nil symbol (C7)" do
      # `@enforce_keys` guards presence, not `nil` — before this fix, `new/1` called
      # `struct!/2` directly rather than routing through `Types.Validate`, so a PRESENT
      # `symbol: nil` built an `%Instrument{}` whose typespec says `symbol: String.t()`
      # can never be `nil`, with no check anywhere catching it.
      assert_raise ArgumentError, fn ->
        Instrument.new(symbol: nil, base: "BTC", quote: "USD")
      end
    end
  end

  describe "new/1 closed vocabularies" do
    test "accepts every value in the typespecs" do
      for instrument <- [:spot, :perp, :future, :unknown],
          status <- [:tradable, :delisted, :unknown] do
        built = Instrument.new(symbol: "BTC-USD", instrument: instrument, status: status)
        assert {built.instrument, built.status} == {instrument, status}
      end
    end

    test "refuses a raw venue string or a misspelt atom" do
      assert_raise ArgumentError, ~r/:status/, fn ->
        Instrument.new(symbol: "BTC-USD", status: "online")
      end

      assert_raise ArgumentError, ~r/:status/, fn ->
        Instrument.new(symbol: "BTC-USD", status: :tradeable)
      end

      assert_raise ArgumentError, ~r/:instrument/, fn ->
        Instrument.new(symbol: "BTC-USD", instrument: "swap")
      end
    end

    test "trading_disabled is :unknown, not delisted" do
      assert :unknown = Instrument.status_from("trading_disabled")
    end
  end

  describe "instrument_from/1 — an unrecognised type must be visible" do
    test "recognises spot" do
      assert :spot = Instrument.instrument_from("spot")
      assert :spot = Instrument.instrument_from("SPOT")
    end

    test "recognises the perpetual vocabularies the venues actually publish" do
      # Gemini publishes `swap` for its perpetuals; Coinbase uses `future` and
      # `perpetual`. Same instrument, three spellings.
      assert :perp = Instrument.instrument_from("swap")
      assert :perp = Instrument.instrument_from("perp")
      assert :perp = Instrument.instrument_from("perpetual")
    end

    test "a bare `future` is :unknown: it cannot say perpetual from dated" do
      assert :unknown = Instrument.instrument_from("future")
      assert :unknown = Instrument.instrument_from("FUTURE")
    end

    test "instrument_from/2 reads the venue's expiry kind" do
      assert :perp = Instrument.instrument_from("future", "PERPETUAL")
      assert :future = Instrument.instrument_from("FUTURE", "expiring")
      assert :future = Instrument.instrument_from("perp", "EXPIRING")
    end

    test "instrument_from/2 falls back to /1 when the expiry kind is unreadable" do
      assert :unknown = Instrument.instrument_from("future", nil)
      assert :unknown = Instrument.instrument_from("future", "unknown_kind")
      assert :perp = Instrument.instrument_from("swap", nil)
      assert :spot = Instrument.instrument_from("spot", "expiring")
      assert :unknown = Instrument.instrument_from("option", "expiring")
      assert :unknown = Instrument.instrument_from(nil, "perpetual")
    end

    test "an unrecognised type is :unknown, NOT :spot" do
      # The failure this prevents: a venue inventing a new contract type and having
      # it silently admitted into a spot-only fleet because :spot was the default.
      assert :unknown = Instrument.instrument_from("inverse_perpetual")
      assert :unknown = Instrument.instrument_from("option")
      assert :unknown = Instrument.instrument_from("")
    end

    test "a missing type is :unknown" do
      assert :unknown = Instrument.instrument_from(nil)
      assert :unknown = Instrument.instrument_from(:spot)
    end
  end

  describe "status_from/1" do
    test "recognises the tradable vocabularies" do
      assert :tradable = Instrument.status_from("online")
      assert :tradable = Instrument.status_from("open")
      assert :tradable = Instrument.status_from("active")
    end

    test "limit_only counts as tradable" do
      # The venue still matches orders. Treating it as delisted silently drops a
      # live book, which is a loss of real trading capability, not a safety measure.
      assert :tradable = Instrument.status_from("limit_only")
    end

    test "recognises the terminal states" do
      assert :delisted = Instrument.status_from("closed")
      assert :delisted = Instrument.status_from("delisted")
      assert :delisted = Instrument.status_from("offline")
    end

    test "an unrecognised status is :unknown, not tradable" do
      assert :unknown = Instrument.status_from("halted_pending_news")
      assert :unknown = Instrument.status_from(nil)
    end

    test "the venue's case does not change the reading, and a non-string is never one" do
      assert :tradable = Instrument.status_from("ONLINE")
      assert :tradable = Instrument.status_from("Limit_Only")
      assert :delisted = Instrument.status_from("Delisted")
      assert :delisted = Instrument.status_from("OFFLINE")
      assert :perp = Instrument.instrument_from("SWAP")

      # An atom is not the venue's string: `:online` is no evidence of anything.
      assert :unknown = Instrument.status_from(:online)
      assert :unknown = Instrument.status_from(1)
      assert :unknown = Instrument.status_from("")
    end
  end
end
