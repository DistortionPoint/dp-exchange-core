defmodule DpExchange.Core.Types.OrderLifecycleTest do
  @moduledoc """
  What `Order.new/1` refuses in the vocabularies and in the status beside the fill figure
  (tick AR, lens X): an unknown side, type, status or time in force is an error and never a
  default, and a status is not built beside a `:filled_quantity` that contradicts it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.Capabilities
  alias DpExchange.Core.Types.{Order, OrderLeg}

  defp dec(value), do: Decimal.new(value)

  defp order(overrides \\ []) do
    Keyword.merge(
      [
        id: "o-1",
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        quantity: dec("2"),
        status: :open,
        provider: :reference
      ],
      overrides
    )
  end

  describe "the closed vocabularies have no default" do
    test "an absent time in force stays nil and is never filled in" do
      assert %Order{time_in_force: nil} = Order.new(order())
      assert %Order{time_in_force: nil} = Order.new(order(time_in_force: nil))
    end

    test "every time in force Capabilities names builds, and carries through" do
      assert :gtc in Capabilities.time_in_force()

      for tif <- Capabilities.time_in_force() do
        assert %Order{time_in_force: ^tif} = Order.new(order(time_in_force: tif))
      end
    end

    test "a time in force outside Capabilities.time_in_force/0 is refused, naming the field" do
      for bad <- [:good_til_cancelled, :GTC, :gfd, "gtc", "DAY", 1, %{}] do
        error = assert_raise ArgumentError, fn -> Order.new(order(time_in_force: bad)) end

        assert error.message =~ ":time_in_force"
        assert error.message =~ "must be one of"
      end
    end

    test "a side, type or status outside the types is refused, whatever its case or spelling" do
      for {field, bad} <- [
            side: "BUY",
            side: :BUY,
            side: :long,
            side: :short,
            order_type: :LIMIT,
            order_type: "limit",
            order_type: :stop_loss,
            status: :canceled,
            status: :new,
            status: :done,
            status: "open",
            status: :unknown
          ] do
        error = assert_raise ArgumentError, fn -> Order.new(order([{field, bad}])) end

        assert error.message =~ inspect(field)
      end
    end

    test "nil is the venue's silence in each vocabulary, and builds as nil" do
      built = Order.new(order(side: nil, order_type: nil, status: nil, time_in_force: nil))

      assert %Order{side: nil, order_type: nil, status: nil, time_in_force: nil} = built
    end
  end

  describe "a status beside a filled quantity that contradicts it" do
    test ":filled and :partially_filled with nothing filled are refused" do
      for status <- [:filled, :partially_filled], zero <- [dec("0"), 0, dec("0.000")] do
        error =
          assert_raise ArgumentError, fn ->
            Order.new(order(status: status, filled_quantity: zero))
          end

        assert error.message =~ "contradicts"
        assert error.message =~ inspect(status)
        assert error.message =~ "nothing is filled"
      end
    end

    test ":pending, :open and :partially_filled with the whole size filled are refused" do
      for status <- [:pending, :open, :partially_filled], filled <- [dec("2"), dec("2.5"), 3] do
        error =
          assert_raise ArgumentError, fn ->
            Order.new(order(status: status, filled_quantity: filled))
          end

        assert error.message =~ "contradicts"
        assert error.message =~ "the whole quantity is filled"
      end
    end

    test "the consistent pairs build" do
      assert %Order{status: :filled} =
               Order.new(order(status: :filled, filled_quantity: dec("2")))

      assert %Order{status: :partially_filled} =
               Order.new(order(status: :partially_filled, filled_quantity: dec("0.5")))

      assert %Order{status: :open} = Order.new(order(status: :open, filled_quantity: dec("0")))
      assert %Order{status: :pending} = Order.new(order(status: :pending, filled_quantity: 0))
    end

    test "nothing is judged where the venue stated no figure" do
      for status <- [:filled, :partially_filled, :open, :pending] do
        assert %Order{status: ^status} = Order.new(order(status: status, filled_quantity: nil))

        assert %Order{status: ^status} =
                 Order.new(order(status: status, quantity: nil, filled_quantity: dec("1")))
      end
    end

    test ":filled with only part of a positive quantity filled is refused, not rewritten" do
      for filled <- [dec("1.9"), dec("0.000001"), 1] do
        error =
          assert_raise ArgumentError, fn ->
            Order.new(order(status: :filled, filled_quantity: filled))
          end

        assert error.message =~ "only part of the quantity is filled"
      end

      # A cancel after a part fill is the venue's `:cancelled`, with the figure kept exactly.
      built = Order.new(order(status: :cancelled, filled_quantity: dec("1.9")))

      assert built.status == :cancelled
      assert Decimal.eq?(built.filled_quantity, dec("1.9"))
    end

    test "a filled quantity above the size is not judged" do
      assert %Order{status: :filled} =
               Order.new(order(status: :filled, filled_quantity: dec("2.0000001")))
    end

    test ":cancelled, :rejected and :expired keep whatever was filled before they ended" do
      for status <- [:cancelled, :rejected, :expired], filled <- [dec("0"), dec("1"), dec("2")] do
        assert %Order{status: ^status} = Order.new(order(status: status, filled_quantity: filled))
      end
    end

    test "a zero-size order that is open and unfilled is not called fully filled" do
      assert %Order{} =
               Order.new(order(status: :open, quantity: dec("0"), filled_quantity: dec("0")))
    end
  end

  describe "legs" do
    test "nil, an empty list and a list of OrderLeg build" do
      leg = OrderLeg.new(symbol: "AAPL 260116C00200000", side: :buy, ratio: 1)

      assert %Order{legs: nil} = Order.new(order())
      assert %Order{legs: []} = Order.new(order(legs: []))
      assert %Order{legs: [^leg]} = Order.new(order(legs: [leg]))
    end

    test "a bare map, a non-list or a list holding anything else is refused" do
      leg = OrderLeg.new(symbol: "AAPL", side: :buy, ratio: 1)

      for bad <- [%{symbol: "AAPL"}, "legs", [%{symbol: "AAPL"}], [leg, :leg], [nil]] do
        error = assert_raise ArgumentError, fn -> Order.new(order(legs: bad)) end

        assert error.message =~ ":legs"
        assert error.message =~ "OrderLeg"
      end
    end
  end
end
