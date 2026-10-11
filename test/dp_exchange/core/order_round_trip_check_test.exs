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

defmodule RoundTripFake.Mint do
  @moduledoc false
  # Reads and cancels are `Kept`'s, so an id is accepted only if it was minted through
  # `mint/0`. Each minting call here is told how to behave by `opts[:mode]`, which travels in
  # the check's own call arguments and so stays async-safe.
  alias DpExchange.Core.Types.Order
  alias RoundTripFake.Kept

  @spec place_order(map(), map(), keyword()) :: {:ok, Order.t()}
  defdelegate place_order(credentials, request, opts), to: Kept

  @spec get_order(map(), String.t(), keyword()) :: term()
  defdelegate get_order(credentials, id, opts), to: Kept

  @spec cancel_order(map(), String.t(), keyword()) :: term()
  defdelegate cancel_order(credentials, id, opts), to: Kept

  @spec mint() :: Order.t()
  def mint do
    id = "minted-#{System.unique_integer([:positive])}"
    Process.put({Kept, id}, true)
    Kept.order(id)
  end

  @spec place_orders(map(), [map()], keyword()) :: term()
  def place_orders(_credentials, requests, opts) do
    case Keyword.get(opts, :mode, :ok) do
      :ok -> {:ok, requests |> Enum.with_index() |> Enum.map(&batch_entry/1)}
      :forgets -> {:ok, [Kept.order("ghost-1")]}
      :forgets_in_tuple -> {:ok, [{:ok, Kept.order("ghost-2")}]}
      :short -> {:ok, []}
      :bad_element -> {:ok, [nil]}
      :no_id -> {:ok, [Kept.order(nil)]}
      :error -> {:error, :down}
      :not_list -> {:ok, :accepted}
    end
  end

  # Index 0 and the rest are orders; 1 is a refusal, 2 is venue JSON, 3 an `{:ok, order}`,
  # 4 a `{:refused, _}`: every shape the callback's partial batch can hold.
  defp batch_entry({_request, 1}), do: {:error, :insufficient_buying_power}
  defp batch_entry({_request, 2}), do: %{"order_id" => "venue-json-1"}
  defp batch_entry({_request, 3}), do: {:ok, mint()}
  defp batch_entry({_request, 4}), do: {:refused, :market_closed}
  defp batch_entry({_request, _index}), do: mint()

  @spec replace_order(map(), String.t(), map(), keyword()) :: term()
  def replace_order(_credentials, id, _changes, opts) do
    case Keyword.get(opts, :mode, :ok) do
      :ok -> if Process.get({Kept, id}), do: {:ok, mint()}, else: {:refused, :not_found}
      :forgets -> {:ok, Kept.order("ghost-3")}
      :refused -> {:error, :cannot_replace}
      :bare -> {:ok, %{"orderId" => id}}
      :no_id -> {:ok, Kept.order(nil)}
    end
  end

  @spec close_position(map(), String.t(), keyword()) :: term()
  def close_position(_credentials, _symbol, opts) do
    case Keyword.get(opts, :mode, :ok) do
      :ok -> {:ok, mint()}
      :refused -> {:refused, :no_position}
      :error -> {:error, :no_position}
      :forgets -> {:ok, Kept.order("ghost-4")}
      :not_supported -> {:error, :not_supported}
      :bare -> {:ok, %{}}
      :no_id -> {:ok, Kept.order(nil)}
    end
  end
end

defmodule RoundTripFake.SameId do
  @moduledoc false
  # Every minting call answers one id, and the read refuses it.
  alias DpExchange.Core.Types.Order

  @spec place_order(map(), map(), keyword()) :: {:ok, Order.t()}
  def place_order(_credentials, _request, _opts), do: {:ok, RoundTripFake.Kept.order("same-1")}

  @spec close_position(map(), String.t(), keyword()) :: {:ok, Order.t()}
  def close_position(_credentials, _symbol, _opts),
    do: {:ok, RoundTripFake.Kept.order("same-1")}

  @spec get_order(map(), String.t(), keyword()) :: {:error, :nope}
  def get_order(_credentials, _id, _opts), do: {:error, :nope}

  @spec cancel_order(map(), String.t(), keyword()) :: {:ok, :cancelled}
  def cancel_order(_credentials, _id, _opts), do: {:ok, :cancelled}
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
               minted_by: :place_order,
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

  # The calls for the other three minting endpoints, each told its behaviour through `mode`.
  defp mint_calls(modes) do
    batch = fn requests -> [%{}, requests, [mode: Keyword.get(modes, :place_orders, :ok)]] end
    request = %{symbol: "BTC-USD"}

    Map.merge(calls(), %{
      place_orders: batch.(List.duplicate(request, Keyword.get(modes, :batch_size, 1))),
      replace_order: fn id ->
        [%{}, id, %{}, [mode: Keyword.get(modes, :replace_order, :ok)]]
      end,
      close_position: [%{}, "BTC-USD", [mode: Keyword.get(modes, :close_position, :ok)]]
    })
  end

  defp run_mint(modes, endpoints \\ %{}),
    do: OrderRoundTripCheck.run(RoundTripFake.Mint, caps(endpoints), mint_calls(modes))

  describe "run/3 — place_orders/3" do
    test "every shape a partial batch holds is accepted, and the minted ids round-trip" do
      assert {:ok, []} = run_mint(batch_size: 6)
    end

    test "an id in a batch the read refuses is caught, attributed to place_orders/3" do
      assert {:ok, violations} = run_mint(place_orders: :forgets)

      assert Enum.map(violations, &{&1.step, &1.minted_by, &1.id}) == [
               {:get_order, :place_orders, "ghost-1"},
               {:cancel_order, :place_orders, "ghost-1"}
             ]
    end

    test "an id inside an {:ok, order} entry is round-tripped too" do
      assert {:ok, [%{id: "ghost-2", minted_by: :place_orders} | _rest]} =
               run_mint(place_orders: :forgets_in_tuple)
    end

    test "a batch of the wrong length fails closed" do
      assert {:error, {:batch_length, 1, 0}} = run_mint(place_orders: :short)
    end

    test "an entry that is neither an order, a refusal nor a map fails closed" do
      assert {:error, {:batch_element, nil}} = run_mint(place_orders: :bad_element)
    end

    test "an order entry with no id fails closed" do
      assert {:error, {:no_order_id, :place_orders, %{id: nil}}} =
               run_mint(place_orders: :no_id)
    end

    test "a refused or malformed whole batch fails closed" do
      assert {:error, {:place_orders_answered, {:error, :down}}} = run_mint(place_orders: :error)

      assert {:error, {:place_orders_answered, {:ok, :accepted}}} =
               run_mint(place_orders: :not_list)
    end

    test "a place_orders/3 declared :unsupported is not called" do
      endpoints = %{{:place_orders, 3} => :unsupported}
      assert {:ok, []} = run_mint([place_orders: :error], endpoints)
    end
  end

  describe "run/3 — replace_order/4" do
    test "the id a replace answers is accepted by the read and the cancel" do
      assert {:ok, []} = run_mint([])
    end

    test "a replaced id the read refuses is caught, attributed to replace_order/4" do
      assert {:ok, violations} = run_mint(replace_order: :forgets)

      assert Enum.map(violations, &{&1.step, &1.minted_by}) == [
               {:get_order, :replace_order},
               {:cancel_order, :replace_order}
             ]
    end

    test "a refused replace of an order just placed fails closed" do
      assert {:error, {:replace_order_answered, {:error, :cannot_replace}}} =
               run_mint(replace_order: :refused)
    end

    test "a replace that answers venue JSON rather than an order fails closed" do
      assert {:error, {:replace_order_answered, {:ok, %{"orderId" => _id}}}} =
               run_mint(replace_order: :bare)
    end

    test "a replaced order with no id fails closed" do
      assert {:error, {:no_order_id, :replace_order, %{id: nil}}} =
               run_mint(replace_order: :no_id)
    end

    test "a replace_order/4 declared :unsupported is not called" do
      assert {:ok, []} =
               run_mint([replace_order: :refused], %{{:replace_order, 4} => :unsupported})
    end

    test "without an active place_order/3 there is no order to replace, so it is not called" do
      endpoints = %{{:place_order, 3} => :unsupported, {:place_orders, 3} => :unsupported}

      assert {:ok, []} = run_mint([replace_order: :refused, close_position: :refused], endpoints)
    end
  end

  describe "run/3 — close_position/3" do
    test "an order it answers has its id round-tripped" do
      assert {:ok, []} = run_mint(close_position: :ok)
    end

    test "a refusal is not applicable, because the suite opens no position" do
      assert {:ok, []} = run_mint(close_position: :refused)
      assert {:ok, []} = run_mint(close_position: :error)
    end

    test "a refusal alone still counts as having run, not as skipped" do
      endpoints = %{{:place_order, 3} => :unsupported, {:place_orders, 3} => :unsupported}
      assert {:ok, []} = run_mint([close_position: :refused, replace_order: :ok], endpoints)
    end

    test "an id the read refuses is caught, attributed to close_position/3" do
      assert {:ok, violations} = run_mint(close_position: :forgets)

      assert Enum.map(violations, &{&1.step, &1.minted_by}) == [
               {:get_order, :close_position},
               {:cancel_order, :close_position}
             ]
    end

    test ":not_supported from an active endpoint fails closed" do
      assert {:error, {:close_position_answered, {:error, :not_supported}}} =
               run_mint(close_position: :not_supported)
    end

    test "a bare map is not an allowed shape" do
      assert {:error, {:close_position_answered, {:ok, %{}}}} = run_mint(close_position: :bare)
    end

    test "an order with no id fails closed" do
      assert {:error, {:no_order_id, :close_position, %{id: nil}}} =
               run_mint(close_position: :no_id)
    end
  end

  describe "run/3 — several calls, one fake" do
    test "an id minted by two calls is asked once, and attributed to the first" do
      calls = Map.put(calls(), :close_position, [%{}, "BTC-USD", []])

      assert {:ok, [violation]} = OrderRoundTripCheck.run(RoundTripFake.SameId, caps(), calls)

      assert %{step: :get_order, id: "same-1", minted_by: :place_order} = violation
    end

    test "with every minting call :unsupported nothing runs" do
      endpoints = %{
        {:place_order, 3} => :unsupported,
        {:place_orders, 3} => :unsupported,
        {:replace_order, 4} => :unsupported,
        {:close_position, 3} => :unsupported
      }

      assert :skipped = run_mint([], endpoints)
    end
  end

  describe "format/1 and format_error/1" do
    test "format/1 names the call that minted the id" do
      rendered =
        OrderRoundTripCheck.format([
          %{step: :get_order, id: "x", minted_by: :replace_order, answered: {:error, :nope}}
        ])

      assert rendered =~ "the id replace_order/4 just returned"
    end

    test "format_error/1 names each new failure" do
      assert OrderRoundTripCheck.format_error({:place_orders_answered, {:error, :x}}) =~
               "place_orders/3"

      assert OrderRoundTripCheck.format_error({:batch_length, 3, 1}) =~ "1 entries for 3"
      assert OrderRoundTripCheck.format_error({:batch_element, nil}) =~ "nil"
      assert OrderRoundTripCheck.format_error({:replace_order_answered, :x}) =~ "replace_order/4"

      assert OrderRoundTripCheck.format_error({:close_position_answered, :x}) =~
               "close_position/3"

      assert OrderRoundTripCheck.format_error({:no_order_id, :close_position, %{id: nil}}) =~
               "close_position/3 answered an order with no usable :id"
    end
  end

  describe "format/1 and format_error/1 — place_order/3" do
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
