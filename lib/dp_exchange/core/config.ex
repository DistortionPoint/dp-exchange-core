defmodule DpExchange.Core.Config do
  @moduledoc """
  Resolves a configurable seam, per process rather than per node.

  **Every seam in this family that a consumer's tests may need to vary goes through
  here** — which fake is in play, what that fake returns, which rate limiter is active,
  anything added later. There is one resolver so that five venue packages cannot each
  invent a variant of it.

  ## Why this is not `Application.get_env/3`

  `Application.put_env/3` is node-wide. A consumer running `async: true` — which is
  every well-built Elixir suite — has many tests on one node at once, so a test that
  configures a seam globally configures it for **every other test running beside it**.

  That is not hypothetical. In the application these packages were extracted from, seven
  tests set a global rate-limiting flag for their duration, and for that duration every
  other async test on the node was suddenly metered against a one-request bucket. An
  unrelated WebSocket test came back `{:error, {:rate_limited, 1}}` while asserting on
  connection errors. The failure was silent, intermittent and seed-dependent — the worst
  combination, and it cost a day to find.

  ## Lookup order

  1. **`Process.get/1` in the calling process** — the override a test set for itself.
  2. **The `$callers` ancestor chain.** ExUnit propagates `:"$callers"` to spawned
     `Task`s, so a task launched inside a test finds the override the test set without
     the test threading it through every closure. **This is the step that gets omitted**,
     and omitting it makes the seam work in simple tests and fail in exactly the
     concurrent ones it exists for.
  3. **`Application.get_env/3`** — the global default. This is what production reads and
     what a consumer configures normally; the process-scoped steps are a test affordance
     layered above it, not a replacement.

  ## Crossing a process boundary

  A `GenServer` runs in its own process and will not find the caller's dictionary at all,
  because it is not in the caller's `$callers` chain. **Resolve in the caller and put the
  answer in the message** — `snapshot/1` on the way in, `resolve_snapshot/4` on the way
  out. Resolving inside the server is too late, and it fails in the direction that looks
  like it works: production is unaffected, so only the consumer's async suite breaks.

  ## Examples

      # Production: reads application env, as normal.
      Config.get(:dp_exchange_core, :rate_limit_module, DefaultRateLimiter)

      # A test, for its own process tree only:
      Config.put_override(:rate_limit_module, AlwaysRateLimited)

  ## `opt/3` — the same problem, one layer down

  This module resolves *seams* — where consumer configuration meets Core. `opt/3` fixes a
  related but distinct trap that lives in `keyword()` options passed on individual calls,
  not in application config: **`Keyword.get/3` only substitutes its default for an ABSENT
  key, never for a key that is present and `nil`.**

  That distinction is invisible reading the code and is reachable on every call, because
  every venue package in this family forwards its own `opts` **unchanged**, by convention,
  through several layers — a `Feed` passes its `opts` to `PollingFeed.start_link/1`, which
  never itself set `interval_ms`. When the venue's own caller never configured a key
  either, it does not vanish; it arrives as `key: nil`, explicit and present, because
  something upstream did `Keyword.get(callers_opts, :interval_ms)` with no default and
  handed the `nil` straight through.

  `Keyword.get(opts, :interval_ms, 30_000)` against `interval_ms: nil` returns `nil`, not
  `30_000` — the default silently does not apply. This was fixed once, by hand, at exactly
  one call site (`PollingFeed`'s `:start_delay_ms`, with an incident recorded in its own
  comment) and left open everywhere else that mattered: `PollingFeed`'s `:interval_ms`
  crashed `Process.send_after/3` outright; `HttpClient`'s `:retry_attempts` was worse — a
  `nil` compares as **greater** than any integer in Erlang term ordering, so it silently
  entered the retry branch and then died computing `4 - nil`, killing the *calling* venue
  process, which this library does not supervise.

  `opt/3` is `Keyword.get/3` with that one difference: a present-and-`nil` value is treated
  the same as an absent one. It does **not** use `||`, because `||` is falsy on `false` too
  — an explicit `log_requests: false` or `raw_status: false` must survive, and a helper that
  silently overrode a real `false` back to its default would be the same bug in the other
  direction.
  """

  @typedoc "The application key a seam's global default lives under."
  @type app :: atom()

  @typedoc "The name of the seam."
  @type key :: atom()

  @doc """
  Resolves `key`, preferring a process-scoped override and falling back to `app`'s
  application environment.

  ## Examples

      iex> DpExchange.Core.Config.get(:dp_exchange_core, :nothing_configured, :fallback)
      :fallback

      iex> DpExchange.Core.Config.put_override(:some_seam, :overridden)
      iex> DpExchange.Core.Config.get(:dp_exchange_core, :some_seam, :fallback)
      :overridden
  """
  @spec get(app(), key(), term()) :: term()
  def get(app, key, default \\ nil) when is_atom(app) and is_atom(key) do
    case find_override(key) do
      :none -> Application.get_env(app, key, default)
      {:ok, value} -> value
    end
  end

  @doc """
  Reads `key` from a `keyword()` options list, treating an explicit `nil` value the same
  as an absent key.

  Unlike `Keyword.get/3`, `opt(opts, :interval_ms, 30_000)` returns `30_000` whether
  `:interval_ms` is missing from `opts` OR present as `interval_ms: nil` — the shape a
  venue's forwarded `opts` produces when nothing upstream ever set it. See this module's
  `opt/3` section for why that distinction matters and why this does not use `||`.

  ## Examples

      iex> DpExchange.Core.Config.opt([], :interval_ms, 30_000)
      30_000

      iex> DpExchange.Core.Config.opt([interval_ms: nil], :interval_ms, 30_000)
      30_000

      iex> DpExchange.Core.Config.opt([interval_ms: 5_000], :interval_ms, 30_000)
      5_000

      iex> DpExchange.Core.Config.opt([log_requests: false], :log_requests, true)
      false
  """
  @spec opt(keyword(), atom(), term()) :: term()
  def opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case Keyword.fetch(opts, key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Sets a process-scoped override for `key`, visible to this process and anything it
  spawns that carries `$callers`.

  Scoped to the calling process, so it never reaches a test running beside this one.
  """
  @spec put_override(key(), term()) :: :ok
  def put_override(key, value) when is_atom(key) do
    Process.put(override_key(key), {:ok, value})
    :ok
  end

  @doc """
  Removes a process-scoped override set by `put_override/2`.

  Only clears the calling process's own override; an ancestor's is untouched, because
  a child must not be able to reconfigure the test that spawned it.
  """
  @spec delete_override(key()) :: :ok
  def delete_override(key) when is_atom(key) do
    Process.delete(override_key(key))
    :ok
  end

  @doc """
  Finds the process-scoped override for `key` without falling back to application env.

  Returns `{:ok, value}` or `:none`. The two are distinguished deliberately: an override
  whose value is `nil` is an override, and collapsing it into "not set" would make `nil`
  unconfigurable.
  """
  @spec find_override(key()) :: {:ok, term()} | :none
  def find_override(key) when is_atom(key) do
    case Process.get(override_key(key), :none) do
      :none -> find_in_callers(Process.get(:"$callers", []), override_key(key))
      found -> found
    end
  end

  @doc """
  Captures the caller's overrides for `keys` so they can be carried across a process
  boundary in a message.

  Call this in the process that has the override — the caller — and pass the result into
  the `GenServer.call/3` or `cast/2`. The server then resolves with
  `resolve_snapshot/4`.

  ## Examples

      iex> DpExchange.Core.Config.put_override(:carried, 42)
      iex> DpExchange.Core.Config.snapshot([:carried, :absent])
      %{carried: 42}
  """
  @spec snapshot([key()]) :: %{optional(key()) => term()}
  def snapshot(keys) when is_list(keys) do
    for key <- keys, {:ok, value} <- [find_override(key)], into: %{}, do: {key, value}
  end

  @doc """
  Resolves `key` inside a process that received a `snapshot/1`.

  The snapshot wins; otherwise this falls back to `app`'s application env, exactly as
  `get/3` does — **`app` is a required argument for that reason**: this used to hardcode
  `:dp_exchange_core` regardless of what a caller passed, so a venue package snapshotting
  one of ITS OWN seams (as `dp_exchange_schwab`'s poller does with
  `DpExchange.Core.Config.snapshot/1`)
  and resolving it inside its own GenServer would have had this function consult Core's
  application env instead of its own — silently never finding a value the venue's own
  consumer configured, no matter how it was set. Found with no live caller yet: every
  known consumer reapplies a snapshot with `put_override/2` in a loop rather than calling
  this, which is why the mismatch between "falls back exactly as `get/3` does" and a
  hardcoded app went unnoticed. Fixed before a first caller could inherit it.

  This deliberately does **not** consult the server's own process dictionary: a
  long-lived server's dictionary is not scoped to any one caller, so honouring it would
  leak one caller's configuration into another's request.

  ## Examples

      iex> DpExchange.Core.Config.resolve_snapshot(%{seam: :from_caller}, :dp_exchange_core, :seam, :fallback)
      :from_caller

      iex> DpExchange.Core.Config.resolve_snapshot(%{}, :dp_exchange_core, :never_set_anywhere, :fallback)
      :fallback
  """
  @spec resolve_snapshot(%{optional(key()) => term()}, app(), key(), term()) :: term()
  def resolve_snapshot(snapshot, app, key, default \\ nil)

  def resolve_snapshot(snapshot, app, key, default)
      when is_map(snapshot) and is_atom(app) and is_atom(key) do
    Map.get_lazy(snapshot, key, fn -> Application.get_env(app, key, default) end)
  end

  defp override_key(key), do: {__MODULE__, key}

  defp find_in_callers([], _key), do: :none

  defp find_in_callers([pid | rest], key) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        case List.keyfind(dictionary, key, 0) do
          {^key, found} -> found
          nil -> find_in_callers(rest, key)
        end

      nil ->
        # The ancestor is already dead. Not an error — a test process can finish
        # while work it spawned is still running — so keep walking.
        find_in_callers(rest, key)
    end
  end
end
