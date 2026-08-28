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
  answer in the message** — `snapshot/2` on the way in, `resolve_snapshot/3` on the way
  out. Resolving inside the server is too late, and it fails in the direction that looks
  like it works: production is unaffected, so only the consumer's async suite breaks.

  ## Examples

      # Production: reads application env, as normal.
      Config.get(:dp_exchange_core, :rate_limit_module, DefaultRateLimiter)

      # A test, for its own process tree only:
      Config.put_override(:rate_limit_module, AlwaysRateLimited)
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
  `resolve_snapshot/3`.

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

  The snapshot wins; otherwise this falls back to application env exactly as `get/3`
  does. It deliberately does **not** consult the server's own process dictionary: a
  long-lived server's dictionary is not scoped to any one caller, so honouring it would
  leak one caller's configuration into another's request.

  ## Examples

      iex> DpExchange.Core.Config.resolve_snapshot(%{seam: :from_caller}, :seam, :fallback)
      :from_caller

      iex> DpExchange.Core.Config.resolve_snapshot(%{}, :dp_exchange_core, :fallback)
      :fallback
  """
  @spec resolve_snapshot(%{optional(key()) => term()}, key(), term()) :: term()
  def resolve_snapshot(snapshot, key, default \\ nil)

  def resolve_snapshot(snapshot, key, default) when is_map(snapshot) and is_atom(key) do
    Map.get_lazy(snapshot, key, fn -> Application.get_env(:dp_exchange_core, key, default) end)
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
