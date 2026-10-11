defmodule DpExchange.Core.OrderRoundTripCheck do
  @moduledoc """
  Asks a venue's fake whether it accepts the order ids its own order-minting calls just
  returned.

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

  Four calls mint order ids. Each is exercised **only when `capabilities/0` declares it
  active**, and the ids it mints are collected:

    * `place_order/3` must answer `{:ok, %Types.Order{}}` with a non-empty binary `:id`.
    * `place_orders/3` must answer `{:ok, list}` with one entry per request. An entry that
      is a `%Types.Order{}` (bare, or as `{:ok, order}`) must carry a non-empty binary
      `:id`, which is collected. An entry that is a refusal (`{:error, _}` or
      `{:refused, _}`) is the venue refusing that one order — the callback documents the
      partial batch as the expected shape — and is **not** a round-trip failure. A bare map
      (venue JSON, which is all `[map()]` promises) names an id this check cannot read
      without guessing the key, so it is not asked about.
    * `replace_order/4` is exercised on an order the check places for the purpose (needs
      `place_order/3` active), and must answer `{:ok, %Types.Order{}}` with an id. The id
      the replace answered is collected; the order that was replaced is not, because a
      venue may legitimately have retired it.
    * `close_position/3` answers an order like `place_order/3` does. The suite opens no
      position, so a refusal (`{:error, _}` or `{:refused, _}`) is an answer
      `c:DpExchange.Core.Venue.close_position/3`'s `result/1` type allows, and the call is
      **not applicable** rather than failed. `{:error, :not_supported}` is not such an
      answer for an active endpoint, nor is any other shape.

  Every distinct collected id is then offered to the fake, reads first, then cancels:

    1. If `{:get_order, 3}` is active, `get_order/3` must answer `{:ok, %Types.Order{}}`.
    2. If `{:cancel_order, 3}` is active, `cancel_order/3` must answer
       `{:ok, %Types.Order{}}` or `{:ok, :cancelled}` — the two shapes
       `c:DpExchange.Core.Venue.cancel_order/3` allows.

  All reads run before any cancel, so a fake that forgets an order on cancel is not blamed
  for a read.

  ## What it deliberately does not do

    * **It does not require the answered order to carry the placed id.** A venue may
      key an order by a client id on the way in and its own id on the way out, and the
      contract does not say which. The id is checked for being *accepted*, not for being
      *echoed*.
    * **It does not fail a venue that declares `get_order/3` or `cancel_order/3`
      `:unsupported`.** Those are not asked at all; their `{:error, :not_supported}` is
      group 12's.
    * **It does not run a minting call that is `:unsupported`.** There is no id to carry.
      `run/3` answers `:skipped` only when none of the four ran, and a caller reading that
      as a pass is right.
    * **It does not exercise `replace_order/4` without `place_order/3`.** The suite has no
      order it could honestly say is open to replace; `place_order/3` being `:unsupported`
      makes the replace not applicable here.
    * **It does not read ids out of venue JSON.** A `place_orders/3` entry that is a bare
      map is skipped, not guessed at.
    * **It does not prove the real venue behaves this way.** It drives a fake. A fake that
      accepts its own ids says the fake is self-consistent, nothing more.

  ## Fail closed

  An active minting call that does not answer as above is not a skip. This check answers
  `{:error, reason}` and the caller fails, because treating a refusal as "nothing to
  round-trip" is how three packages once passed assertions that never ran on them (see
  `docs/reference/core/assertion-coverage.md`, "Second axis"). The one exception is
  `close_position/3`'s refusal, for the reason above. The remedy is in the message the suite
  attaches: either the endpoint is not really active, or the fake needs an option the call
  did not carry — declare it in `endpoint_opts:`.

  A raise or an exit from the fake is captured and reported as the answer; it does not
  escape and take the rest of the test with it.
  """

  alias DpExchange.Core.{Capabilities, Types}

  @mint_steps [:place_order, :place_orders, :replace_order, :close_position]
  @arities %{place_order: 3, place_orders: 3, replace_order: 4, close_position: 3}

  @typedoc """
  The arguments for each call. `place_order`, `place_orders` and `close_position` are full
  argument lists; `replace_order`, `get_order` and `cancel_order` are functions from an
  order id to the full argument list, so the id lands in whichever position the caller's own
  call shape puts it. Every key but `place_order` is optional; a missing key means that call
  is not made.
  """
  @type calls :: %{
          required(:place_order) => [term()],
          required(:get_order) => (String.t() -> [term()]),
          required(:cancel_order) => (String.t() -> [term()]),
          optional(:place_orders) => [term()],
          optional(:replace_order) => (String.t() -> [term()]),
          optional(:close_position) => [term()]
        }

  @typedoc """
  A follow-up the fake refused: the id, the call that minted it, and what was answered.
  """
  @type violation :: %{
          step: :get_order | :cancel_order,
          id: String.t(),
          minted_by: :place_order | :place_orders | :replace_order | :close_position,
          answered: term()
        }

  @doc """
  Mints order ids on `fake` and offers each to `get_order/3` and `cancel_order/3`.

  `caps` is the venue's `Capabilities`, read to decide which calls are active.

  Returns `:skipped` when none of `place_order/3`, `place_orders/3`, `replace_order/4` and
  `close_position/3` could run, `{:ok, violations}` when at least one did (`[]` is a pass),
  and `{:error, reason}` when an active minting call did not answer as the contract
  requires.
  """
  @spec run(module(), Capabilities.t(), calls()) ::
          :skipped | {:ok, [violation()]} | {:error, term()}
  def run(fake, caps, calls) do
    case Enum.filter(@mint_steps, &runnable?(caps, calls, &1)) do
      [] ->
        :skipped

      steps ->
        with {:ok, minted} <- mint_all(fake, steps, calls) do
          {:ok, follow_up(fake, caps, minted, calls)}
        end
    end
  end

  @doc "Renders `run/3` violations as one line per refused follow-up, for a failure message."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      minted_by = Map.get(violation, :minted_by, :place_order)

      "  #{violation.step}/3 refused #{inspect(violation.id)}, the id " <>
        "#{minted_by}/#{Map.fetch!(@arities, minted_by)} just returned. " <>
        "It answered: #{inspect(violation.answered, limit: 8)}"
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

  def format_error({:no_order_id, step, order}) do
    "#{step}/#{Map.get(@arities, step, "?")} answered an order with no usable :id " <>
      "(#{inspect(order.id)}), so there is nothing to hand get_order/3 or cancel_order/3"
  end

  def format_error({:place_orders_answered, answered}) do
    "place_orders/3 is declared active but the fake answered #{inspect(answered, limit: 8)} " <>
      "rather than {:ok, list}"
  end

  def format_error({:batch_length, expected, got}) do
    "place_orders/3 answered #{got} entries for #{expected} requests; the callback " <>
      "documents one entry per request, each an order or that order's refusal"
  end

  def format_error({:batch_element, element}) do
    "place_orders/3 answered an entry that is neither an order, a refusal nor a map: " <>
      inspect(element, limit: 8)
  end

  def format_error({:replace_order_answered, answered}) do
    "replace_order/4 is declared active but the fake answered #{inspect(answered, limit: 8)} " <>
      "for an order the check had just placed, rather than an order"
  end

  def format_error({:close_position_answered, answered}) do
    "close_position/3 is declared active but the fake answered #{inspect(answered, limit: 8)}" <>
      " rather than an order or a refusal (a refusal is allowed: no position was opened)"
  end

  def format_error(other), do: "unexpected result #{inspect(other, limit: 8)}"

  defp runnable?(caps, calls, :replace_order) do
    runnable?(caps, calls, :place_order) and plain_runnable?(caps, calls, :replace_order)
  end

  defp runnable?(caps, calls, step), do: plain_runnable?(caps, calls, step)

  defp plain_runnable?(caps, calls, step) do
    Map.has_key?(calls, step) and Capabilities.active?(caps, {step, Map.fetch!(@arities, step)})
  end

  defp mint_all(fake, steps, calls) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, acc} ->
      case mint(fake, step, calls) do
        {:ok, ids} -> {:cont, {:ok, acc ++ Enum.map(ids, &{step, &1})}}
        :not_applicable -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp mint(fake, :place_order, calls) do
    with {:ok, id} <- place(fake, calls.place_order), do: {:ok, [id]}
  end

  defp mint(fake, :place_orders, calls) do
    args = calls.place_orders

    case invoke(fake, :place_orders, args) do
      {:ok, results} when is_list(results) -> batch_ids(results, expected_count(args))
      other -> {:error, {:place_orders_answered, other}}
    end
  end

  # The order replaced is placed for the purpose and then left alone: a venue may
  # legitimately have retired it, so it is not offered to get_order/3 or cancel_order/3.
  defp mint(fake, :replace_order, calls) do
    with {:ok, base} <- place(fake, calls.place_order) do
      case invoke(fake, :replace_order, calls.replace_order.(base)) do
        {:ok, %Types.Order{} = order} -> order_id(order, :replace_order)
        other -> {:error, {:replace_order_answered, other}}
      end
    end
  end

  defp mint(fake, :close_position, calls) do
    case invoke(fake, :close_position, calls.close_position) do
      {:ok, %Types.Order{} = order} -> order_id(order, :close_position)
      {:error, :not_supported} = answered -> {:error, {:close_position_answered, answered}}
      {kind, _reason} when kind in [:error, :refused] -> :not_applicable
      other -> {:error, {:close_position_answered, other}}
    end
  end

  defp order_id(%Types.Order{id: id}, _step) when is_binary(id) and id != "", do: {:ok, [id]}
  defp order_id(%Types.Order{} = order, step), do: {:error, {:no_order_id, step, order}}

  defp expected_count([_credentials, requests | _rest]) when is_list(requests),
    do: length(requests)

  defp expected_count(_args), do: nil

  defp batch_ids(results, expected) do
    if is_integer(expected) and length(results) != expected do
      {:error, {:batch_length, expected, length(results)}}
    else
      collect_batch(results, [])
    end
  end

  defp collect_batch([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect_batch([element | rest], acc) do
    case batch_element(element) do
      {:id, id} -> collect_batch(rest, [id | acc])
      :skip -> collect_batch(rest, acc)
      {:error, _reason} = error -> error
    end
  end

  defp batch_element(%Types.Order{id: id}) when is_binary(id) and id != "", do: {:id, id}
  defp batch_element(%Types.Order{} = order), do: {:error, {:no_order_id, :place_orders, order}}
  defp batch_element({:ok, %Types.Order{} = order}), do: batch_element(order)
  defp batch_element({kind, _reason}) when kind in [:ok, :error, :refused], do: :skip
  defp batch_element(%{} = _venue_json), do: :skip
  defp batch_element(other), do: {:error, {:batch_element, other}}

  defp place(fake, args) do
    case invoke(fake, :place_order, args) do
      {:ok, %Types.Order{id: id}} when is_binary(id) and id != "" -> {:ok, id}
      {:ok, %Types.Order{} = order} -> {:error, {:no_order_id, order}}
      other -> {:error, {:place_order_answered, other}}
    end
  end

  # Every read before any cancel: a fake that drops an order on cancel must not be blamed
  # for a read. Each distinct id is asked once, attributed to the first call that minted it.
  defp follow_up(fake, caps, minted, calls) do
    ids = Enum.uniq_by(minted, fn {_step, id} -> id end)

    [:get_order, :cancel_order]
    |> Enum.filter(&Capabilities.active?(caps, {&1, 3}))
    |> Enum.flat_map(fn step ->
      Enum.flat_map(ids, fn {minted_by, id} -> check_step(fake, step, id, minted_by, calls) end)
    end)
  end

  defp check_step(fake, step, id, minted_by, calls) do
    build_args = Map.fetch!(calls, step)
    answered = invoke(fake, step, build_args.(id))

    if accepted?(step, answered),
      do: [],
      else: [%{step: step, id: id, minted_by: minted_by, answered: answered}]
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
