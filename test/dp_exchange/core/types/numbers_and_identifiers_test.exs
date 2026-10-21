defmodule DpExchange.Core.Types.NumbersAndIdentifiersTest do
  @moduledoc """
  The numbers and identifiers a constructor used to take on trust (tick AQ, lens S): a candle
  price at or below zero, a candle width Core cannot name, a fill at a price of zero, a negative
  order size, a conversion at a rate of zero, a sequence number that is text, an instrument
  whose base is an atom, and a basis-point integer that becomes a `Decimal` no constructor
  accepts.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Instrument, Timeframe}

  alias DpExchange.Core.Types.{
    Candle,
    Conversion,
    Fill,
    Order,
    OrderBook,
    OrderBookDelta,
    StakingRate,
    VolumeProfile
  }

  @ts ~U[2026-10-21 12:00:00Z]

  defp dec(value), do: Decimal.new(value)

  defp candle(overrides \\ []) do
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

  defp fill(overrides) do
    Keyword.merge(
      [
        order_id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        quantity: dec("1"),
        price: dec("100"),
        timestamp: @ts,
        provider: :reference
      ],
      overrides
    )
  end

  defp order(overrides) do
    Keyword.merge(
      [
        id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        quantity: dec("1"),
        status: :open,
        provider: :reference
      ],
      overrides
    )
  end

  defp conversion(overrides) do
    Keyword.merge(
      [id: "q-1", status: :quoted, from_asset: "USD", to_asset: "BTC", provider: :reference],
      overrides
    )
  end

  defp book(overrides) do
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
  end

  defp delta(overrides) do
    Keyword.merge(
      [
        symbol: "BTC-USD",
        levels: [{:bid, dec("100"), dec("1")}],
        timestamp: @ts,
        provider: :reference
      ],
      overrides
    )
  end

  describe "Candle.new/1 prices and width" do
    test "an open, high, low or close at or below zero is refused, naming the field" do
      # The sign is judged before coherence, so one bad price is enough to name.
      for field <- [:open, :high, :low, :close], bad <- [dec("0"), dec("-1"), 0, -5] do
        error = assert_raise ArgumentError, fn -> Candle.new(candle([{field, bad}])) end

        assert error.message =~ inspect(field)
        assert error.message =~ "above zero"
      end
    end

    test "a positive bar still builds" do
      assert %Candle{} = Candle.new(candle())
    end

    test "a width outside the vocabulary is refused, including near misses and non-text" do
      for bad <- ["1H", "60m", "3m", "1 h", "", " ", :"1h", 3600, "1d "] do
        error = assert_raise ArgumentError, fn -> Candle.new(candle(timeframe: bad)) end

        assert error.message =~ ":timeframe"
        assert error.message =~ "1h"
      end
    end

    test "every nameable width builds, the three that cannot be bucketed included" do
      for width <- Timeframe.nameable() do
        assert %Candle{timeframe: ^width} = Candle.new(candle(timeframe: width))
      end

      assert Enum.all?(~w(1w 1M 1y), &(&1 in Timeframe.nameable()))
    end
  end

  describe "VolumeProfile.new/1 width" do
    @profile [symbol: "AAPL", opened_at: @ts, provider: :reference]

    test "a width outside the vocabulary is refused" do
      for bad <- ["1H", "60m", "", :day] do
        assert_raise ArgumentError, ~r/:timeframe/, fn ->
          VolumeProfile.new([{:timeframe, bad} | @profile])
        end
      end
    end

    test "a nameable width builds" do
      assert %VolumeProfile{timeframe: "1d"} = VolumeProfile.new([{:timeframe, "1d"} | @profile])
    end
  end

  describe "Fill.new/1 price" do
    test "a price of zero or less is refused, as a public trade's is" do
      for bad <- [dec("0"), dec("-0.5"), 0, -1] do
        error = assert_raise ArgumentError, fn -> Fill.new(fill(price: bad)) end

        assert error.message =~ ":price"
        assert error.message =~ "above zero"
      end
    end

    test "a maker rebate, a negative fee, is still a fill" do
      assert %Fill{} = Fill.new(fill(fee: dec("-0.01")))
    end

    test "a positive price builds" do
      assert %Fill{price: %Decimal{}} = Fill.new(fill([]))
    end
  end

  describe "Order.new/1 sizes" do
    test "a negative quantity or filled quantity is refused" do
      for field <- [:quantity, :filled_quantity], bad <- [dec("-1"), -3] do
        error = assert_raise ArgumentError, fn -> Order.new(order([{field, bad}])) end

        assert error.message =~ inspect(field)
        assert error.message =~ "never negative"
      end
    end

    test "zero, nil and positive sizes build, and a price is not held to a sign" do
      assert %Order{} = Order.new(order(quantity: dec("0"), filled_quantity: dec("0")))
      assert %Order{} = Order.new(order(quantity: nil, filled_quantity: nil))
      assert %Order{price: %Decimal{}} = Order.new(order(price: dec("0")))
    end
  end

  describe "Conversion.new/1 rate and amounts" do
    test "a rate of zero or less is refused" do
      for bad <- [dec("0"), dec("-1.5"), 0] do
        assert_raise ArgumentError, ~r/:rate/, fn -> Conversion.new(conversion(rate: bad)) end
      end
    end

    test "a negative amount on either side is refused, zero is not" do
      for field <- [:from_amount, :to_amount] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Conversion.new(conversion([{field, dec("-1")}]))
        end

        assert %Conversion{} = Conversion.new(conversion([{field, dec("0")}]))
      end
    end

    test "a quote with a positive rate and amounts builds" do
      built =
        Conversion.new(
          conversion(rate: dec("0.00002"), from_amount: dec("100"), to_amount: dec("0.002"))
        )

      assert Decimal.eq?(built.rate, dec("0.00002"))
    end
  end

  describe "book sequence numbers" do
    test "a sequence that is not an integer is refused on a book and on a delta" do
      # `"7" > 6` is true in Erlang term order, so a consumer dropping frames whose sequence is
      # `<=` the last applied would apply a stale one.
      for bad <- ["7", dec("7"), :seven, [7], %{n: 7}] do
        assert_raise ArgumentError, ~r/:sequence/, fn -> OrderBook.new(book(sequence: bad)) end

        assert_raise ArgumentError, ~r/:sequence/, fn ->
          OrderBookDelta.new(delta(sequence: bad))
        end
      end
    end

    test "an integer, a negative integer and nil build" do
      for good <- [0, 7, -1, nil, 10_000_000_000_000_000_000_000] do
        assert %OrderBook{sequence: ^good} = OrderBook.new(book(sequence: good))
        assert %OrderBookDelta{sequence: ^good} = OrderBookDelta.new(delta(sequence: good))
      end
    end

    test "a float is refused too, by the scan every constructor shares" do
      assert_raise ArgumentError, ~r/float/, fn -> OrderBook.new(book(sequence: 7.0)) end

      assert_raise ArgumentError, ~r/float/, fn ->
        OrderBookDelta.new(delta(sequence: 7.0))
      end
    end
  end

  describe "Instrument.new/1 base and quote" do
    test "an atom, a number or a blank string is refused" do
      for field <- [:base, :quote], bad <- [:btc, 5, "", "  ", %{}] do
        assert_raise ArgumentError, ~r/#{field}/, fn ->
          Instrument.new([{:symbol, "BTC-USD"}, {field, bad}])
        end
      end
    end

    test "text and nil build" do
      assert %Instrument{base: "BTC", quote: "USD"} =
               Instrument.new(symbol: "BTC-USD", base: "BTC", quote: "USD")

      assert %Instrument{base: nil, quote: nil} = Instrument.new(symbol: "BTC-USD")
    end
  end

  describe "StakingRate.bps_to_pct/1 reads an integer or a float as it reads text" do
    test "an integer past what a string may carry is unreadable, as its text is" do
      huge = Integer.pow(10, 5_000)

      assert StakingRate.bps_to_pct(huge) == nil
      assert StakingRate.bps_to_pct(-huge) == nil
      assert StakingRate.bps_to_pct(Integer.to_string(huge)) == nil
      assert StakingRate.bps_to_pct(Integer.pow(10, 34)) == nil
    end

    test "the largest integer a string may carry still converts, to a value a type takes" do
      largest = Integer.pow(10, 34) - 1

      assert %Decimal{} = pct = StakingRate.bps_to_pct(largest)

      assert %StakingRate{rate_pct: ^pct} =
               StakingRate.new(asset: "ETH", provider: :reference, rate_pct: pct)
    end

    test "an ordinary integer and float convert exactly" do
      assert Decimal.eq?(StakingRate.bps_to_pct(450), dec("4.5"))
      assert Decimal.eq?(StakingRate.bps_to_pct(0.1), dec("0.001"))
      assert Decimal.eq?(StakingRate.bps_to_pct(-250), dec("-2.5"))
    end

    test "a float at the edge of the representable range converts or is nil, never raises" do
      for float <- [1.0e308, 1.0e-300, -1.0e308] do
        result = StakingRate.bps_to_pct(float)
        assert result == nil or match?(%Decimal{}, result)
      end
    end
  end
end
