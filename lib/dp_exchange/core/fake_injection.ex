defmodule DpExchange.Core.FakeInjection do
  @moduledoc """
  Deterministic failure injection and a credential-free wiring mode, for a venue's `Fake`
  to consult at the entry of its own public functions.

  ## Why this exists

  A consumer migrating fully onto the real per-venue `Fake` modules for testing (rather
  than keeping a parallel hand-rolled test double indefinitely) needs two things none of
  the four `Fake`s exposed on their own: a way to make a `Fake` fail on demand, to test a
  consumer's own retry/circuit-breaker/alerting code without reaching a real venue; and a
  way to skip a `Fake`'s venue-faithful credential check, to test pure dispatch/decode
  logic without constructing valid-looking credentials for every call.

  ## Deterministic, never a rate

  Every outcome here is queued explicitly and consumed in order. There is no
  `error_rate: 0.5`-shaped knob and there will not be one: a test that fails 30% of the
  time on its own schedule is not more useful than one that never fails, and "dialable"
  was always asking for exact, reproducible control, not simulated flakiness.

  ## Two independent axes

  **Which functions one override reaches** is not configurable — every public function a
  `Fake` gates through `next_outcome/1` or `next_outcome/2` is gated the same way. This
  was a real design question (see `docs/design/2026-09-04_webull-sharding-and-fake-injection.md`
  §3.6.1 in `dp_exchange_core`) and the answer is uniform gating: the feature this
  replaces asked for exactly one knob, and building per-function targeting nobody asked
  for is the same speculative surface this family's own conventions rule out on a bug fix.

  **Which symbol one override reaches**, for a function that takes one, IS configurable —
  a symbol-targeted override can never be satisfied by, or interfere with, a call for a
  different symbol (§3.6.2). `queue_failures/2` and `fail_always/2` are whole-call;
  `queue_failures/3` and `fail_always/3` target one symbol. A symbol-specific queue is
  always checked before the whole-call one.

  ## Built on `Config`, not a new mechanism

  Every value here lives behind `DpExchange.Core.Config.put_override/2` — process-scoped,
  `$callers`-aware, safe under `async: true`, for the exact reason `Config`'s own
  moduledoc gives: a node-wide seam configured by one test configures it for every other
  async test running beside it. **This means injection only reaches a `Fake` function
  called from the configuring test's own process (or a `Task` it spawned)** — a `Fake`
  called from inside a separately-supervised `GenServer` (as some streaming paths are)
  will not see it, the same limitation every other `Config`-based seam in this family
  already has.

  ## Scope

  Whole-call injection is exactly that: it picks the outcome one `Fake` function call
  returns. It does not simulate a partially-failing *batch* — a function that takes a
  list of symbols in one call (a venue's own bulk subscribe, say) and needs one symbol
  within that batch to fail while the rest succeed needs the fake response itself to
  carry partial success, which this does not attempt. Flagged as an open question in the
  design doc, not resolved here.
  """

  alias DpExchange.Core.Config

  # Every venue's state lives under ONE static override key, keyed by `venue` inside the
  # stored map — never by interpolating `venue` into a dynamically-created atom. `venue`
  # is developer-supplied here, not user input, but Config.put_override/2 requires an
  # atom key, and a per-venue atom built from a runtime value is exactly the pattern
  # sobelow flags on sight (DOS.BinToAtom) regardless of how bounded the actual input is
  # in practice.
  @override_key :fake_injection

  @typedoc "Whatever a `Venue` callback may return: a value to hand back as-is."
  @type outcome :: term()

  @typedoc "Injection state for one venue, held behind one `Config` override."
  @type state :: %{
          global: [outcome()],
          global_always: outcome() | :none,
          by_symbol: %{optional(String.t()) => [outcome()]},
          symbol_always: %{optional(String.t()) => outcome()},
          bypass_credentials?: boolean()
        }

  @doc """
  Queues `outcomes` to be returned, in order, by the next matching whole-call
  `next_outcome/1` reads (and `next_outcome/2` reads for a symbol with no
  symbol-specific queue of its own). Each call to `next_outcome/1` or `2` pops one entry;
  once exhausted, normal `Fake` behaviour resumes.
  """
  @spec queue_failures(atom(), [outcome()]) :: :ok
  def queue_failures(venue, outcomes) when is_atom(venue) and is_list(outcomes) do
    update(venue, fn state -> %{state | global: state.global ++ outcomes} end)
  end

  @doc """
  Queues `outcomes` for `symbol` only. A call naming a different symbol — or no symbol at
  all — never sees these and is never affected by them.
  """
  @spec queue_failures(atom(), String.t(), [outcome()]) :: :ok
  def queue_failures(venue, symbol, outcomes)
      when is_atom(venue) and is_binary(symbol) and is_list(outcomes) do
    update(venue, fn state ->
      %{state | by_symbol: Map.update(state.by_symbol, symbol, outcomes, &(&1 ++ outcomes))}
    end)
  end

  @doc "Every whole-call `next_outcome/1` (and unmatched `next_outcome/2`) returns `outcome` until `reset/1`."
  @spec fail_always(atom(), outcome()) :: :ok
  def fail_always(venue, outcome) when is_atom(venue) do
    update(venue, fn state -> %{state | global_always: {:some, outcome}} end)
  end

  @doc "Every `next_outcome/2` for `symbol` returns `outcome` until `reset/1`."
  @spec fail_always(atom(), String.t(), outcome()) :: :ok
  def fail_always(venue, symbol, outcome) when is_atom(venue) and is_binary(symbol) do
    update(venue, fn state ->
      %{state | symbol_always: Map.put(state.symbol_always, symbol, outcome)}
    end)
  end

  @doc "For a `Fake` function with no symbol argument."
  @spec next_outcome(atom()) :: {:override, outcome()} | :none
  def next_outcome(venue) when is_atom(venue), do: next_outcome(venue, nil)

  @doc """
  For a `Fake` function whose call names `symbol`. Checks, in order: an always-fail set
  for this exact symbol, a queued outcome for this exact symbol, an always-fail set for
  every call, a queued whole-call outcome — the first of these that has something wins.
  """
  @spec next_outcome(atom(), String.t() | nil) :: {:override, outcome()} | :none
  def next_outcome(venue, symbol) when is_atom(venue) do
    state = get_state(venue)

    cond do
      symbol && Map.has_key?(state.symbol_always, symbol) ->
        {:override, Map.fetch!(state.symbol_always, symbol)}

      symbol && Map.get(state.by_symbol, symbol, []) != [] ->
        [outcome | rest] = Map.fetch!(state.by_symbol, symbol)
        put_state(venue, %{state | by_symbol: Map.put(state.by_symbol, symbol, rest)})
        {:override, outcome}

      state.global_always != :none ->
        {:some, outcome} = state.global_always
        {:override, outcome}

      state.global != [] ->
        [outcome | rest] = state.global
        put_state(venue, %{state | global: rest})
        {:override, outcome}

      true ->
        :none
    end
  end

  @doc """
  Makes `venue`'s `Fake` skip its normal credential check for the rest of this process
  (or a `Task` it spawns) — the default, venue-faithful refusal is untouched for any test
  that does not call this.
  """
  @spec bypass_credentials(atom()) :: :ok
  def bypass_credentials(venue) when is_atom(venue) do
    update(venue, fn state -> %{state | bypass_credentials?: true} end)
  end

  @doc "Whether `bypass_credentials/1` is in effect for `venue` in the calling process."
  @spec credentials_bypassed?(atom()) :: boolean()
  def credentials_bypassed?(venue) when is_atom(venue), do: get_state(venue).bypass_credentials?

  @doc "Clears every override (queued failures, always-fail, credential bypass) for `venue`."
  @spec reset(atom()) :: :ok
  def reset(venue) when is_atom(venue) do
    Config.put_override(@override_key, Map.delete(all_state(), venue))
  end

  defp update(venue, fun), do: venue |> get_state() |> fun.() |> then(&put_state(venue, &1))

  defp get_state(venue), do: Map.get(all_state(), venue, default_state())

  defp put_state(venue, state) do
    Config.put_override(@override_key, Map.put(all_state(), venue, state))
  end

  defp all_state do
    case Config.find_override(@override_key) do
      {:ok, all} -> all
      :none -> %{}
    end
  end

  defp default_state do
    %{
      global: [],
      global_always: :none,
      by_symbol: %{},
      symbol_always: %{},
      bypass_credentials?: false
    }
  end
end
