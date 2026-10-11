defmodule RoundTripFake.Kept do
  @moduledoc false
  # A conforming fake: it mints a fresh id per order and remembers it, so the id round-trips.
  # The memory is the process dictionary, which is what the check's own process shares.
  alias DpExchange.Core.Types.Order

  @spec place_order(map(), map(), keyword()) :: {:ok, Order.t()}
  def place_order(_credentials, _request, _opts) do
    id = "placed-#{System.unique_integer([:positive])}"
    Process.put({__MODULE__, id}, true)
    {:ok, order(id)}
  end

  @spec get_order(map(), String.t(), keyword()) :: {:ok, Order.t()} | {:refused, :not_found}
  def get_order(_credentials, id, _opts) do
    if Process.get({__MODULE__, id}), do: {:ok, order(id)}, else: {:refused, :not_found}
  end

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, :cancelled} | {:refused, :not_found}
  def cancel_order(_credentials, id, _opts) do
    if Process.get({__MODULE__, id}), do: {:ok, :cancelled}, else: {:refused, :not_found}
  end

  @spec order(String.t() | nil) :: Order.t()
  def order(id) do
    %Order{
      id: id,
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      quantity: Decimal.new("1"),
      status: :open,
      provider: :round_trip_fake
    }
  end
end

defmodule RoundTripFake.CancelsWithOrder do
  @moduledoc false
  # Conforming too: a cancel may answer the order rather than `:cancelled`.
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  defdelegate place_order(credentials, request, opts), to: RoundTripFake.Kept

  @spec get_order(map(), String.t(), keyword()) :: term()
  defdelegate get_order(credentials, id, opts), to: RoundTripFake.Kept

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def cancel_order(_credentials, id, _opts),
    do: {:ok, %{RoundTripFake.Kept.order(id) | status: :cancelled}}
end

defmodule RoundTripFake.RefusesOwnIdOnRead do
  @moduledoc false
  # The gemini issue #5 shape: `place_order/3` mints an id its own `get_order/3` refuses,
  # because the read only knows one fixed id.
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("placed-1")}

  @spec get_order(map(), String.t(), keyword()) :: term()
  def get_order(_credentials, "fixed-order-1", _opts),
    do: {:ok, RoundTripFake.Kept.order("fixed-order-1")}

  def get_order(_credentials, id, _opts), do: {:error, {:invalid_order_id, id}}

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, :cancelled}
  def cancel_order(_credentials, _id, _opts), do: {:ok, :cancelled}
end

defmodule RoundTripFake.RefusesOwnIdOnCancel do
  @moduledoc false
  # The read takes the id; the cancel does not.
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("placed-1")}

  @spec get_order(map(), String.t(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def get_order(_credentials, id, _opts), do: {:ok, RoundTripFake.Kept.order(id)}

  @spec cancel_order(map(), String.t(), keyword()) :: {:refused, term()}
  def cancel_order(_credentials, id, _opts), do: {:refused, {:cancel_rejected, id}}
end

defmodule RoundTripFake.ReadsABareMap do
  @moduledoc false
  # Accepts the id and answers it as venue JSON rather than an `Order`.
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("placed-1")}

  @spec get_order(map(), String.t(), keyword()) :: {:ok, map()}
  def get_order(_credentials, id, _opts), do: {:ok, %{"orderId" => id}}

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, :cancelled}
  def cancel_order(_credentials, _id, _opts), do: {:ok, :cancelled}
end

defmodule RoundTripFake.RaisesOnRead do
  @moduledoc false
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("placed-1")}

  @spec get_order(map(), String.t(), keyword()) :: no_return()
  def get_order(_credentials, id, _opts), do: raise(ArgumentError, "unknown order #{id}")

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, :cancelled}
  def cancel_order(_credentials, _id, _opts), do: {:ok, :cancelled}
end

defmodule RoundTripFake.PlaceRefused do
  @moduledoc false
  @spec place_order(map(), map(), keyword()) :: {:error, term()}
  def place_order(_credentials, _request, _opts), do: {:error, {:missing_account, :account_id}}
end

defmodule RoundTripFake.PlacesOnly do
  @moduledoc false
  # Defines no `get_order/3` or `cancel_order/3` at all; calling either would be an
  # `UndefinedFunctionError`, which the check would report, so a pass proves it never did.
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("placed-1")}
end

defmodule RoundTripFake.PlacesWithNoId do
  @moduledoc false
  @spec place_order(map(), map(), keyword()) :: {:ok, DpExchange.Core.Types.Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order(nil)}
end

defmodule DpExchange.Core.OrderRoundTripCheckTest do
  @moduledoc """
  `DpExchange.Core.OrderRoundTripCheck` against fakes that are wrong in one way each, run
  directly rather than through `Core.AdapterContract`'s generated group 31 (whose own
  conforming case is `AdapterContractTest`, against the reference venue).
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, OrderRoundTripCheck}

  defp caps(endpoints \\ %{}) do
    Capabilities.new(endpoints: endpoints, supported_quotes: ~w(USD))
  end

  # The calls the suite builds: the order's full argument list, and the follow-ups as
  # functions of the placed id.
  defp calls do
    %{
      place_order: [%{}, %{symbol: "BTC-USD"}, []],
      get_order: fn id -> [%{}, id, []] end,
      cancel_order: fn id -> [%{}, id, []] end
    }
  end

  describe "run/3 — a fake that agrees with itself" do
    test "an id it minted is accepted by its read and its cancel" do
      assert {:ok, []} = OrderRoundTripCheck.run(RoundTripFake.Kept, caps(), calls())
    end

    test "a cancel that answers the order rather than :cancelled is accepted too" do
      assert {:ok, []} = OrderRoundTripCheck.run(RoundTripFake.CancelsWithOrder, caps(), calls())
    end
  end

  describe "run/3 — a fake that refuses its own id" do
    test "a read that knows only a fixed id is caught, with the id and the answer" do
      assert {:ok, [violation]} =
               OrderRoundTripCheck.run(RoundTripFake.RefusesOwnIdOnRead, caps(), calls())

      assert violation == %{
               step: :get_order,
               id: "placed-1",
               answered: {:error, {:invalid_order_id, "placed-1"}}
             }
    end

    test "a cancel that refuses the placed id is caught" do
      assert {:ok, [violation]} =
               OrderRoundTripCheck.run(RoundTripFake.RefusesOwnIdOnCancel, caps(), calls())

      assert violation.step == :cancel_order
      assert violation.id == "placed-1"
      assert violation.answered == {:refused, {:cancel_rejected, "placed-1"}}
    end

    test "a read that accepts the id but answers a bare map is caught" do
      assert {:ok, [%{step: :get_order, answered: {:ok, %{"orderId" => "placed-1"}}}]} =
               OrderRoundTripCheck.run(RoundTripFake.ReadsABareMap, caps(), calls())
    end

    test "a raise is reported as the answer and does not escape" do
      assert {:ok, [%{step: :get_order, answered: {:raised, %ArgumentError{}}}]} =
               OrderRoundTripCheck.run(RoundTripFake.RaisesOnRead, caps(), calls())
    end
  end

  describe "run/3 — what is not asked" do
    test "a get_order/3 declared :unsupported is not called" do
      endpoints = %{{:get_order, 3} => :unsupported}

      assert {:ok, []} =
               OrderRoundTripCheck.run(RoundTripFake.RefusesOwnIdOnRead, caps(endpoints), calls())
    end

    test "a cancel_order/3 declared :unsupported is not called" do
      endpoints = %{{:cancel_order, 3} => :unsupported}

      assert {:ok, []} =
               OrderRoundTripCheck.run(
                 RoundTripFake.RefusesOwnIdOnCancel,
                 caps(endpoints),
                 calls()
               )
    end

    test "with both declared :unsupported a fake that only places has nothing to refuse" do
      endpoints = %{{:get_order, 3} => :unsupported, {:cancel_order, 3} => :unsupported}

      assert {:ok, []} =
               OrderRoundTripCheck.run(RoundTripFake.PlacesOnly, caps(endpoints), calls())
    end

    test "a place_order/3 declared :unsupported skips the whole check" do
      endpoints = %{{:place_order, 3} => :unsupported}

      assert :skipped =
               OrderRoundTripCheck.run(RoundTripFake.RefusesOwnIdOnRead, caps(endpoints), calls())
    end
  end

  describe "run/3 — an active place_order/3 that cannot start the round trip" do
    test "a refusal is an error, not a skip" do
      assert {:error, {:place_order_answered, {:error, {:missing_account, :account_id}}}} =
               OrderRoundTripCheck.run(RoundTripFake.PlaceRefused, caps(), calls())
    end

    test "an order with no id is an error, because there is nothing to hand the follow-ups" do
      assert {:error, {:no_order_id, %{id: nil}}} =
               OrderRoundTripCheck.run(RoundTripFake.PlacesWithNoId, caps(), calls())
    end
  end

  describe "format/1 and format_error/1" do
    test "format/1 names the step, the id and the answer, one line each" do
      rendered =
        OrderRoundTripCheck.format([
          %{step: :get_order, id: "placed-1", answered: {:error, :nope}},
          %{step: :cancel_order, id: "placed-1", answered: {:refused, :nope}}
        ])

      assert rendered =~ "get_order/3 refused \"placed-1\""
      assert rendered =~ "{:error, :nope}"
      assert rendered =~ "cancel_order/3 refused \"placed-1\""
      assert length(String.split(rendered, "\n")) == 2
    end

    test "format_error/1 says what place_order/3 answered" do
      assert OrderRoundTripCheck.format_error({:place_order_answered, {:error, :x}}) =~
               "{:error, :x}"

      assert OrderRoundTripCheck.format_error({:no_order_id, %{id: ""}}) =~ "no usable :id"
      assert OrderRoundTripCheck.format_error(:something_else) =~ ":something_else"
    end
  end
end
