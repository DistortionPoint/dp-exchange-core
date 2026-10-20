defmodule DpExchange.Core.Types.BoundedMessagesTest do
  @moduledoc """
  A constructor's refusal names the offending value, and that value is whatever a venue
  decoder parsed: a megabyte body, or a caller-supplied map holding anything. The message is
  logged, copied into crash reports and pasted, so it names the value in bounded form and a
  huge value must not make a huge message.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.{
    Candle,
    Fill,
    OrderBook,
    OrderBookDelta,
    OrderLeg,
    Position,
    Quote,
    StakingReward,
    Validate,
    Withdrawal
  }

  # A message names at most four values (a Candle's), each clipped to ~200 bytes, beside its
  # own text. The unbounded renderings these values would otherwise produce are 80_000 bytes
  # and more.
  @ceiling 2_000

  defp now, do: DateTime.utc_now()

  # A Decimal with 20_000 digits, built as a struct so no parser limit applies.
  defp huge_decimal, do: %Decimal{sign: 1, coef: Integer.pow(10, 20_000), exp: 0}

  defp huge_list, do: Enum.to_list(1..100_000)
  defp huge_text, do: String.duplicate("x", 200_000)
  defp huge_map, do: Map.new(1..50_000, &{&1, &1})

  defp message(fun) do
    error = assert_raise(ArgumentError, fun)
    Exception.message(error)
  end

  defp assert_bounded(fun) do
    text = message(fun)
    assert byte_size(text) < @ceiling, "message was #{byte_size(text)} bytes"
    text
  end

  defp quote_attrs(overrides) do
    Keyword.merge(
      [symbol: "BTC-USD", price: Decimal.new(1), observed_at: now(), provider: :t],
      overrides
    )
  end

  describe "the identity and shape checks of Validate" do
    test "a huge :symbol is named in bounded form" do
      for bad <- [huge_list(), huge_map(), huge_text() |> String.to_charlist()] do
        text = assert_bounded(fn -> Quote.new(quote_attrs(symbol: bad)) end)
        assert text =~ "field :symbol is"
      end
    end

    test "a huge :provider is named in bounded form" do
      text = assert_bounded(fn -> Quote.new(quote_attrs(provider: huge_map())) end)
      assert text =~ "field :provider is"
    end

    test "a huge value in a time field is named in bounded form" do
      text = assert_bounded(fn -> Quote.new(quote_attrs(venue_time: huge_text())) end)
      assert text =~ "venue_time"
    end

    test "a huge value for a vocabulary field is named in bounded form" do
      attrs = [
        order_id: "o1",
        symbol: "BTC-USD",
        side: huge_list(),
        quantity: Decimal.new(1),
        price: Decimal.new(1),
        timestamp: now(),
        provider: :t
      ]

      text = assert_bounded(fn -> Fill.new(attrs) end)
      assert text =~ "field :side is"
    end

    test "a huge value for a count is named in bounded form" do
      attrs = [symbol: "BTC-USD", side: :buy, ratio: huge_text()]
      text = assert_bounded(fn -> OrderLeg.new(attrs) end)
      assert text =~ "must be a positive integer"
    end

    test "a huge value that should have been a Decimal is named in bounded form" do
      text = assert_bounded(fn -> Quote.new(quote_attrs(price: huge_map())) end)
      assert text =~ "must be a Decimal"
    end

    test "a huge value that should have been text is named in bounded form" do
      attrs = [
        order_id: huge_list(),
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new(1),
        price: Decimal.new(1),
        timestamp: now(),
        provider: :t
      ]

      text = assert_bounded(fn -> Fill.new(attrs) end)
      assert text =~ "order_id"
    end

    test "a huge Decimal below the floor is named in bounded form" do
      negative = %Decimal{huge_decimal() | sign: -1}
      text = assert_bounded(fn -> Quote.new(quote_attrs(price: negative)) end)
      assert text =~ "above zero"
    end

    test "a small value still reads as plain inspect/1 printed it" do
      text = message(fn -> Quote.new(quote_attrs(price: Decimal.new("-1.5"))) end)
      # `inspect/1` itself, whatever the decimal version prints (`Decimal.new("-1.5")` on 3.x,
      # `#Decimal<-1.5>` on 2.x, both admitted by `mix.exs`).
      assert text =~ "is #{inspect(Decimal.new("-1.5"))} "
    end

    test "show/1 cuts a list to five items and text to forty bytes" do
      assert Validate.show([1, 2, 3]) == "[1, 2, 3]"
      assert Validate.show(Enum.to_list(1..50)) =~ "..."
      assert byte_size(Validate.show(huge_text())) < 100
    end
  end

  describe "the per-type refusals" do
    test "OrderBook names a bad level, a bad side and an unsorted pair in bounded form" do
      base = [symbol: "BTC-USD", observed_at: now(), provider: :t, asks: []]

      level = {Decimal.new(0), huge_decimal()}
      assert_bounded(fn -> OrderBook.new([bids: [level]] ++ base) end)

      assert_bounded(fn -> OrderBook.new([bids: huge_list()] ++ base) end)

      big = huge_decimal()
      unsorted = [{Decimal.new(1), big}, {big, big}]
      assert_bounded(fn -> OrderBook.new([bids: unsorted] ++ base) end)
    end

    test "OrderBookDelta names a bad level list and a bad level in bounded form" do
      base = [symbol: "BTC-USD", timestamp: now(), provider: :t]

      assert_bounded(fn -> OrderBookDelta.new([levels: huge_list()] ++ base) end)

      bad = {:bid, Decimal.new(0), huge_decimal()}
      assert_bounded(fn -> OrderBookDelta.new([levels: [bad]] ++ base) end)
    end

    test "Candle names an incoherent bar in bounded form" do
      attrs = [
        symbol: "BTC-USD",
        timeframe: "1h",
        opened_at: now(),
        open: huge_decimal(),
        high: Decimal.new(1),
        low: huge_decimal(),
        close: huge_decimal(),
        provider: :t
      ]

      assert_bounded(fn -> Candle.new(attrs) end)
    end

    test "Quote names an unknown volume window in bounded form" do
      attrs = quote_attrs(volume: Decimal.new(1), volume_window: huge_map())
      assert_bounded(fn -> Quote.new(attrs) end)
    end

    test "Position, StakingReward and Withdrawal name a huge value in bounded form" do
      position = [
        symbol: "BTC-USD",
        side: :long,
        quantity: Decimal.new(1),
        instrument_type: huge_text(),
        provider: :t
      ]

      assert_bounded(fn -> Position.new(position) end)

      reward = [asset: "ETH", amount: Decimal.new(1), accrual_count: huge_map(), provider: :t]
      assert_bounded(fn -> StakingReward.new(reward) end)

      withdrawal = [
        id: "w1",
        status: :broadcast,
        asset: "BTC",
        amount: Decimal.new(1),
        tx_id: huge_list(),
        provider: :t
      ]

      assert_bounded(fn -> Withdrawal.new(withdrawal) end)
    end
  end
end
