defmodule DpExchange.Core.OrderRoundTripCheck do
  @moduledoc """
  Asks a venue's fake whether it accepts the order id its own `place_order/3` just returned.

  ## The defect this exists for

  **A fake that refuses its own ids.** `dp_exchange_gemini`'s fake answered `place_order/3`
  with an order, and then answered `get_order/3` and `cancel_order/3` for that same order
  `{:error, {:invalid_order_id, _}}` — the id it had minted was not one its own read and
  cancel would take (gemini issue #5). Every assertion in `Core.AdapterContract` passed:
  group 5 calls `get_order/3` with an id it makes up and accepts a refusal as an answer,
  group 12 asks only that an active endpoint not answer `:not_supported`, and nothing placed
  an order and then used what came back. A consumer's tier-1 test that places, reads back
  and cancels — the first thing anyone writes against a trading fake — could not pass.

  The same class is recorded in `dp_exchange_webull`'s fake, whose `place_order/3` echoed a
  caller-chosen `client_order_id` that its own `get_order/3` and `cancel_order/3` then
  refused as `:not_found` because they knew only one fixed id. Different mechanics, one
  shape: the fake is a set of independently written functions, and nothing made them agree
  about the one value that connects them.

  ## What it checks

  For a venue that declares `{:place_order, 3}` active:

    1. `place_order/3` is called with a well-formed order and must answer
       `{:ok, %Types.Order{}}` with a non-empty binary `:id`.
    2. If `{:get_order, 3}` is active, `get_order/3` is called with that id and must answer
       `{:ok, %Types.Order{}}`.
    3. If `{:cancel_order, 3}` is active, `cancel_order/3` is called with that id and must
       answer `{:ok, %Types.Order{}}` or `{:ok, :cancelled}` — the two shapes
       `c:DpExchange.Core.Venue.cancel_order/3` allows.

  The read runs before the cancel, so a fake that forgets an order on cancel is not blamed
  for the read.

  ## What it deliberately does not do

    * **It does not require the answered order to carry the placed id.** A venue may
      key an order by a client id on the way in and its own id on the way out, and the
      contract does not say which. The id is checked for being *accepted*, not for being
      *echoed*.
    * **It does not fail a venue that declares `get_order/3` or `cancel_order/3`
      `:unsupported`.** Those are not asked at all; their `{:error, :not_supported}` is
      group 12's.
    * **It does not run when `place_order/3` is `:unsupported`.** There is no id to carry.
      `run/3` answers `:skipped`, and a caller reading that as a pass is right.
    * **It does not call `place_orders/3`, `replace_order/4` or `close_position/3`.** They
      mint ids too, and a fake that breaks on those is a separate finding for the day one
      is found.
    * **It does not prove the real venue behaves this way.** It drives a fake. A fake that
      accepts its own ids says the fake is self-consistent, nothing more.

  ## Fail closed

  An active `place_order/3` that does not answer an order is not a skip. This check
  answers `{:error, {:place_order_answered, term}}` and the caller fails, because treating
  a refusal as "nothing to round-trip" is how three packages once passed assertions that
  never ran on them (see `docs/reference/core/assertion-coverage.md`, "Second axis"). The
  remedy is in the message the suite attaches: either the endpoint is not really active, or
  the fake needs an option the call did not carry — declare it in `endpoint_opts:`.

  A raise or an exit from the fake is captured and reported as the answer; it does not
  escape and take the rest of the test with it.
  """

  alias DpExchange.Core.{Capabilities, Types}

  @typedoc """
  The arguments for each call. `place_order` is the full argument list; the other two are
  functions from the placed id to the full argument list, so the id lands in whichever
  position the caller's own call shape puts it.
  """
  @type calls :: %{
          place_order: [term()],
          get_order: (String.t() -> [term()]),
          cancel_order: (String.t() -> [term()])
        }

  @typedoc "A follow-up the fake refused, with the id it was given and what it answered."
  @type violation :: %{step: :get_order | :cancel_order, id: String.t(), answered: term()}

  @doc """
  Places an order on `fake` and offers the id it returns to `get_order/3` and
  `cancel_order/3`.

  `caps` is the venue's `Capabilities`, read to decide which of the three are active.

  Returns `:skipped` when `place_order/3` is `:unsupported`, `{:ok, violations}` when it ran
  (`[]` is a pass), and `{:error, reason}` when `place_order/3` is active and did not
  answer an order with an id.
  """
  @spec run(module(), Capabilities.t(), calls()) ::
          :skipped | {:ok, [violation()]} | {:error, term()}
  def run(fake, caps, calls) do
    if Capabilities.active?(caps, {:place_order, 3}) do
      with {:ok, id} <- place(fake, calls.place_order) do
        {:ok, follow_up(fake, caps, id, calls)}
      end
    else
      :skipped
    end
  end

  @doc "Renders `run/3` violations as one line per refused follow-up, for a failure message."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      "  #{violation.step}/3 refused #{inspect(violation.id)}, the id place_order/3 just " <>
        "returned. It answered: #{inspect(violation.answered, limit: 8)}"
    end)
  end

  @doc "Renders a `run/3` error, for a failure message."
  @spec format_error(term()) :: String.t()
  def format_error({:place_order_answered, answered}) do
    "place_order/3 is declared active but the fake answered #{inspect(answered, limit: 8)} " <>
      "rather than an order"
  end

  def format_error({:no_order_id, order}) do
    "place_order/3 answered an order with no usable :id (#{inspect(order.id)}), so there " <>
      "is nothing to hand get_order/3 or cancel_order/3"
  end

  def format_error(other), do: "unexpected result #{inspect(other, limit: 8)}"

  defp place(fake, args) do
    case invoke(fake, :place_order, args) do
      {:ok, %Types.Order{id: id}} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, %Types.Order{} = order} -> {:error, {:no_order_id, order}}
      other -> {:error, {:place_order_answered, other}}
    end
  end

  # Read before cancel: a fake that drops the order on cancel must not be blamed for the read.
  defp follow_up(fake, caps, id, calls) do
    [:get_order, :cancel_order]
    |> Enum.filter(&Capabilities.active?(caps, {&1, 3}))
    |> Enum.flat_map(&check_step(fake, &1, id, calls))
  end

  defp check_step(fake, step, id, calls) do
    build_args = Map.fetch!(calls, step)
    answered = invoke(fake, step, build_args.(id))

    if accepted?(step, answered), do: [], else: [%{step: step, id: id, answered: answered}]
  end

  defp accepted?(:get_order, {:ok, %Types.Order{}}), do: true
  defp accepted?(:cancel_order, {:ok, %Types.Order{}}), do: true
  defp accepted?(:cancel_order, {:ok, :cancelled}), do: true
  defp accepted?(_step, _answered), do: false

  defp invoke(fake, name, args) do
    apply(fake, name, args)
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {kind, reason}
  end
end
