defmodule DpExchange.Core.DefaultRateLimiter do
  @moduledoc """
  An in-process rate limiter, and the default implementation of
  `DpExchange.Core.RateLimitBehaviour`.

  A venue package needs a ceiling whether or not its consumer has one. This is that
  ceiling: no external store, no shared infrastructure, one `GenServer` per limiter,
  started by whoever supervises the venue.

  ## Written from the contract, not ported

  The implementation this was derived from had four defects, each of which is a test
  here. They are worth stating because three of the four are silent, and silence is what
  made them survive:

    1. **A weight-N acquire was N sequential calls.** It looped, taking one token at a
       time, ignoring the underlying limiter's native cost argument. That is N round
       trips where one would do; each carrying a 30-second timeout, so a weight-10
       acquire could block for 300 seconds where the design intended 30; the group was
       not atomic, so two concurrent weight-N acquires interleaved; and a failure partway
       had already consumed tokens for a request that never happened, which nothing
       released. **Here one acquire is one atomic reservation.**
    2. **`check/3` discarded `weight`.** It answered `:ok` when there was room for
       exactly one, whatever was asked. **Here every entry point honours `weight`.**
    3. **`acquire/3` failed closed and `check/3` failed open**, undocumented, on the same
       condition. That was half the contract's fault — `check/3` had no way to say "I
       could not tell" — so the contract was widened rather than the workaround copied.
       **Here both fail closed**, and an unknown answer is `{:error, reason}`.
    4. **`1..weight` is descending when weight is 0.** On Elixir 1.18.4,
       `Enum.to_list(1..0) == [1, 0]`, so `record(provider, 0, opts)` recorded *two*
       requests — inflating the exact meter it exists to keep honest. The compile-time
       warning does not fire because the bound is a variable, and `pos_integer()` in a
       typespec is not a runtime check. **Here weight is validated at the boundary.**

  ## It holds no venue knowledge

  There is no table of venues in this module and there must never be one. Limits are
  configuration a consumer supplies at `start_link/1`; a venue's own ceiling is the
  venue package's business. Baking venue facts into shared code is the pattern this
  whole family exists to remove, and reproducing it *inside* Core would be worse than
  leaving it in the host.

  ## The algorithm

  A virtual-scheduling token bucket (GCRA). One integer per provider — the time at which
  its next request may proceed — advanced by `weight × emission_interval` on every
  reservation, and allowed to run ahead of now by a burst tolerance. Reserving `weight`
  is a single addition, which is what makes it atomic without a lock.

  `acquire/3` computes the wait inside the server, commits the reservation, and sleeps
  in the *caller*. The server never blocks, so one slow caller cannot stall the limiter
  for everyone else.

  ## Not started is not "no limit"

  Every callback returns `{:error, :not_started}` when the named limiter is not running.
  Failing open would meter nothing while reporting success, which is exactly the failure
  the ceiling exists to prevent: a venue answering with HTTP 429 while the budget panel
  reads comfortable.
  """

  use GenServer

  alias DpExchange.Core.Config

  @behaviour DpExchange.Core.RateLimitBehaviour

  @typedoc "Per-provider limits, or the `:default` used for any provider not listed."
  @type limits :: %{optional(atom() | String.t() | :default) => limit()}

  @typedoc "`limit` requests per `per_ms`, tolerating `burst` above the smooth rate."
  @type limit :: %{limit: pos_integer(), per_ms: pos_integer(), burst: non_neg_integer()}

  @default_limit %{limit: 10, per_ms: 1_000, burst: 10}

  # --- lifecycle ---------------------------------------------------------

  @doc """
  Starts a limiter.

  ## Options

    * `:name` — the registered name. Defaults to this module, which is what the
      callbacks use when `opts` names no limiter.
    * `:limits` — a map of provider to `t:limit/0`, plus an optional `:default`.
      Anything not listed uses `:default`, and an unconfigured `:default` uses
      10 requests per second with a burst of 10.

  A consumer supervises this. Nothing starts it implicitly — a package that opened a
  limiter on load would be starting processes behind the application that depends on it.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # --- RateLimitBehaviour ------------------------------------------------

  @doc """
  Reserves `weight` tokens, waiting until they are available.

  Returns `:ok` once the reservation is honoured, `{:error, :rate_limit_timeout}` if the
  wait would exceed `:timeout`, or `{:error, reason}` if the answer is unknown.

  **One reservation, not `weight` of them.** The wait is served in the calling process,
  so a caller waiting does not stall the limiter for anyone else. A reservation that
  cannot be honoured within the timeout is **not** committed — the tokens are not
  consumed for a request that will never be made.

  ## `:timeout` must survive an explicit `nil`

  `HttpClient.limiter_opts/1` forwards `:timeout` verbatim from whatever `opts` its own
  caller passed, so `timeout: nil` reaches here whenever nothing upstream ever set it —
  the same forwarding pattern documented on `DpExchange.Core.Config.opt/3`. Reading it with
  a plain `Keyword.get(opts, :timeout, 30_000)` would return `nil` in that case, not
  `30_000`, and the `wait_ms > timeout` check below is `wait_ms > nil` — which Erlang term
  ordering makes **always false**, because `nil` sorts above every integer. "Fail closed
  after N ms" would silently become "wait however long it takes", verified live against an
  exhausted bucket. `Config.opt/3` is used here for exactly that reason.
  """
  @impl DpExchange.Core.RateLimitBehaviour
  @spec acquire(atom() | String.t(), pos_integer(), keyword()) ::
          :ok | {:error, :rate_limit_timeout} | {:error, term()}
  def acquire(provider, weight, opts \\ []) do
    with {:ok, weight} <- validate_weight(weight),
         timeout = Config.opt(opts, :timeout, 30_000),
         {:ok, wait_ms} <- call(opts, {:acquire, provider, weight, timeout}) do
      if wait_ms > 0, do: Process.sleep(wait_ms)
      :ok
    end
  end

  @doc """
  Answers whether `weight` tokens are available right now, without reserving them.

  `{:error, reason}` when the limiter is not running or the weight is invalid — a caller
  must treat that as "do not proceed", because not knowing is not the same as having
  capacity.
  """
  @impl DpExchange.Core.RateLimitBehaviour
  @spec check(atom() | String.t(), pos_integer(), keyword()) ::
          :ok | {:rate_limited, non_neg_integer()} | {:error, term()}
  def check(provider, weight, opts \\ []) do
    with {:ok, weight} <- validate_weight(weight),
         {:ok, wait_ms} <- call(opts, {:check, provider, weight}) do
      if wait_ms == 0, do: :ok, else: {:rate_limited, wait_ms}
    end
  end

  @doc """
  Records that `weight` requests were actually sent.

  Fills the bucket that `acquire/3` and `check/3` measure against. A venue package
  issuing its own HTTP calls — rather than going through a client that records on its
  behalf — must call this, or its ceiling meters against a bucket nothing writes to and
  every check passes.

  **Cannot fail.** Metering must never be the reason a market-data call does not happen;
  a missed record costs accuracy in the ceiling, not the request. An invalid weight is
  ignored rather than raising, and — unlike the implementation this replaces — a weight
  of `0` records nothing rather than two.
  """
  @impl DpExchange.Core.RateLimitBehaviour
  @spec record(atom() | String.t(), pos_integer(), keyword()) :: :ok
  def record(provider, weight, opts \\ []) do
    with {:ok, weight} <- validate_weight(weight) do
      call(opts, {:record, provider, weight})
    end

    :ok
  catch
    :exit, _reason -> :ok
  end

  @doc """
  The limiter's current view of a provider, for tests and diagnostics.

  Returns `%{next_allowed_in_ms: non_neg_integer()}` — zero when the provider may
  proceed immediately.
  """
  @spec inspect_provider(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect_provider(provider, opts \\ []) do
    with {:ok, wait_ms} <- call(opts, {:check, provider, 1}) do
      {:ok, %{next_allowed_in_ms: wait_ms}}
    end
  end

  # --- server ------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       limits: Config.opt(opts, :limits, %{}),
       # provider => theoretical arrival time, in native monotonic milliseconds
       tat: %{}
     }}
  end

  @impl GenServer
  def handle_call({:acquire, provider, weight, timeout}, _from, state) do
    {wait_ms, new_tat} = reserve(state, provider, weight)

    if wait_ms > timeout do
      # Deliberately NOT committed. Consuming tokens for a request that will not be
      # made is how a partial failure leaks capacity nothing ever gives back.
      {:reply, {:error, :rate_limit_timeout}, state}
    else
      {:reply, {:ok, wait_ms}, put_in(state.tat[provider], new_tat)}
    end
  end

  def handle_call({:check, provider, weight}, _from, state) do
    {wait_ms, _new_tat} = reserve(state, provider, weight)
    {:reply, {:ok, wait_ms}, state}
  end

  def handle_call({:record, provider, weight}, _from, state) do
    {_wait_ms, new_tat} = reserve(state, provider, weight)
    {:reply, {:ok, 0}, put_in(state.tat[provider], new_tat)}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  # --- internal ----------------------------------------------------------

  # Virtual scheduling. `tat` is the time this provider's next request may proceed if no
  # burst were allowed; the tolerance lets it run that far ahead of now. Reserving
  # `weight` advances it by `weight` emission intervals — one addition, so a weight of
  # ten is as atomic as a weight of one.
  #
  # ## All integers, and that is not fussiness
  #
  # The obvious version computes `emission_interval = per_ms / limit` as a float. With
  # `limit: 3, per_ms: 1000` that is 333.333…; three of them sum to 1000.0000000000002
  # while the tolerance sums to 999.9999999999999, so the third acquire lands a
  # ten-billionth of a millisecond past the boundary and `ceil/1` rounds that to a whole
  # millisecond of wait. **A ceiling declared as 3 per second then grants 2.**
  #
  # Worse, it is timing-dependent in the wrong direction: the error only shows when no
  # whole millisecond has elapsed between calls — that is, exactly when the caller is
  # fast enough for the ceiling to matter. A slow caller never sees it, so it survives
  # casual testing and quietly leaves a third of a venue's budget unused.
  #
  # So `tat` is carried **scaled by `limit`**, in units of millisecond × limit, where
  # every quantity is an exact integer.
  defp reserve(state, provider, weight) do
    %{limit: limit, per_ms: per_ms, burst: burst} = limit_for(state, provider)

    now_scaled = System.monotonic_time(:millisecond) * limit

    tat_scaled = max(Map.get(state.tat, provider, now_scaled), now_scaled)
    new_tat_scaled = tat_scaled + weight * per_ms
    allowed_at_scaled = new_tat_scaled - burst * per_ms

    wait_ms = max(0, ceil_div(allowed_at_scaled - now_scaled, limit))
    {wait_ms, new_tat_scaled}
  end

  # Integer ceiling division. `div/2` truncates toward zero, so the usual
  # `div(a + b - 1, b)` is wrong for a negative numerator — and the numerator here is
  # negative whenever there is capacity to spare, which is the common case.
  defp ceil_div(numerator, denominator) when numerator <= 0, do: div(numerator, denominator)
  defp ceil_div(numerator, denominator), do: div(numerator - 1, denominator) + 1

  # No venue table here, and never one: limits are the consumer's configuration.
  defp limit_for(state, provider) do
    Map.get(state.limits, provider) ||
      Map.get(state.limits, :default) ||
      @default_limit
  end

  # `pos_integer()` in a typespec is a promise, not a check. The defect this prevents
  # was a weight of 0 walking a descending range and recording twice.
  defp validate_weight(weight) when is_integer(weight) and weight > 0, do: {:ok, weight}
  defp validate_weight(weight), do: {:error, {:invalid_weight, weight}}

  defp call(opts, message) do
    server = Config.opt(opts, :limiter, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, reason -> {:error, {:limiter_unavailable, reason}}
  end
end
