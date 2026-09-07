defmodule DpExchange.Core.PollingFeed do
  @moduledoc """
  A feed built from repeated fetches, for a venue package to use INSIDE its own feed.

  ## Why this lives in the contract and not in a consumer

  A venue with no streaming API still has to present a feed, or every consumer
  above it forks on transport — which is the drift the facade exists to undo.
  Robinhood has no socket and never will; its feed is this module, and nothing
  above the package can tell the difference.

  Venues WITH sockets use it too, for the symbols their stream does not reach.
  That gap-filling decision belongs to the venue because only the venue can make
  it correctly: Webull's stream is bounded by "3 messages per second per
  connection", and which symbols lose that race is knowable only by watching its
  own sockets. Shared code had to guess, and guessed that 151 delivering-nothing
  symbols were a quiet market.

  Shipping it in the contract rather than in a consumer means a venue package can
  build a feed without reaching for anything outside its own dependencies — which
  is the property that lets a venue be a standalone package at all.

  ## Bulk where the venue offers it, per-symbol where it does not

  A venue with an overview endpoint fetches its whole set in one request
  (`:fetch_all`). Robinhood's 87 pairs cost one call per cycle that way and 87
  without, and its rate limiter is not hypothetical — dropping to per-symbol
  fetches would multiply this venue's request count by the size of its catalog.

  Where only a per-symbol endpoint exists (`:fetch`), every symbol runs on its
  own schedule rather than the set being swept in a burst. A burst is what a
  rate limiter sees as an attack, and it makes the first symbol in the list
  permanently fresher than the last, so start times are spread across the
  interval to keep the request rate flat.

  ## A fetch that fails does not stop the feed

  A symbol whose fetch fails is retried on the next tick and reported as
  `:not_covered` until one succeeds. It is never dropped: this module cannot
  tell a delisted symbol from a network blip, and the layer that CAN — the venue
  answering with an explicit refusal — handles that separately.

  ## A feed delivering NOTHING says so, loudly

  Individual failures are debug-level, because a handful of them are ordinary.
  A feed where *nothing at all* is succeeding is not ordinary, and it is the
  most expensive failure shape in collection: it is indistinguishable from a
  quiet venue, which is how one venue's feed ran through its first deployment
  publishing nothing at all: it had been handed a credential whose key was still
  ciphertext. Credentials are accepted as an opaque map, so a wrong one is not an
  error at the boundary — it is a fetch that fails, and the per-symbol failures
  were invisible at debug level.

  So a feed that has delivered nothing since it started escalates: it warns once
  it has failed a full cycle with zero successes, and keeps warning while that
  holds. Never a silent retry loop.

  The warning above is a log line, and a log nobody greps in time is exactly how
  DpCryptoManagement's issue #21 stayed hidden — the feed said "has delivered
  NOTHING in 154 consecutive attempts" to its own log, and a human found that
  sentence by grepping, not because anything downstream reacted to it. So this
  module ALSO emits an `on_notice` callback — the same injected-function shape as
  `on_refusal` — carrying a `Core.Notice{kind: :coverage_change}` the instant it
  crosses INTO the delivering-nothing state, and a recovery notice the instant it
  crosses back out. Once per transition, not once per failed tick and not once
  per sweep thereafter: a 342-symbol feed retrying every symbol every cycle would
  otherwise turn one outage into a notice storm. `on_notice` defaults to a no-op,
  so a caller that does not wire it up gets a working feed, not a crash — the
  same contract `on_refusal` already keeps.

  ## A fetch that never returns fails just as loudly

  `fetch` and `fetch_all` run synchronously inside `handle_info`, and nothing in this
  module's own code can time one out — that has to be a boundary this module imposes.
  Without one, a single hung fetch (a socket that never closes, an HTTP client with no
  timeout of its own) blocks this GenServer's mailbox indefinitely: every other symbol
  stops ticking, and `status/1` and `coverage/1` — the calls a health check makes to find
  out whether this feed is the one delivering nothing — never answer either. That is a
  worse failure than the one the escalating warning above exists to catch, because it
  disables the very mechanism meant to report it.

  So every fetch runs inside a bounded, disposable task (see `bounded_fetch/2`) and a hang
  past `:fetch_timeout_ms` becomes an ordinary fetch failure — retried next tick, counted
  toward `failures_since_ok`, escalated the same way a real error would be. The default
  timeout is derived from the poll interval and clamped between `@min_fetch_timeout_ms` and
  `@max_fetch_timeout_ms`, so this module never trades an unbounded hang for a merely very
  long one, and never turns a fast interval into an accidental timeout on an ordinary,
  slower-than-a-tick HTTP round trip.
  """

  use GenServer

  require Logger

  alias DpExchange.Core.{Config, Notice}

  @typedoc """
  Fetches one symbol's current price.

  Three outcomes, and the third matters. `{:ok, event}` publishes.
  `{:error, reason}` is retried on the next tick — this module cannot tell a
  delisted symbol from a network blip, so it must not decide. `{:refused,
  reason}` is the venue stating it does not carry the symbol at all, which only
  the adapter can recognise, and which is reported once rather than retried
  forever.
  """
  @type fetch ::
          (String.t() -> {:ok, map()} | {:error, term()} | {:refused, term()})

  @typedoc """
  Fetches many symbols in one call, for a venue whose upstream API answers a batch as
  cheaply as one symbol.

  `{:ok, events}` publishes every event and is the only outcome most bulk fetchers ever
  need. `{:error, reason}` is retried next cycle, same as `fetch`'s `:error` — this module
  still cannot tell a delisted symbol from a network blip and must not decide for one.

  `{:refused, refusals}` is `fetch`'s `:refused` scaled to a batch: `refusals` is a
  `[{symbol, reason}]` list naming every symbol in THIS call that the venue stated it does
  not carry at all, reported through `on_refusal` once each rather than retried forever.
  Added because its absence was a real gap: before it existed, a batch fetcher that found
  one bad symbol mixed into an otherwise-live request had no outcome to return that this
  module's `fetch_all_and_publish/1` did not already handle, other than reporting the
  whole batch as an ordinary `{:error, reason}` — which, unlike a real `:refused`, is
  retried forever and never reaches `on_refusal`, so the caller never learns to drop the
  symbol from its scope. `dp_exchange_robinhood` documented this exact gap as the reason
  it stayed on per-symbol `:fetch` rather than adopt this endpoint's own documented
  repeatable-query bulk mode.

  A bulk response with zero events (`{:ok, []}`) is treated as delivering nothing for
  escalation purposes even though the call itself succeeded — see `fetch_all_and_publish/1`.
  """
  @type fetch_all ::
          ([String.t()] ->
             {:ok, [map()]} | {:error, term()} | {:refused, [{String.t(), term()}]})

  @typedoc """
  Receives a `Core.Notice.t()` the instant this feed crosses into or back out of the
  delivering-nothing state. Injected like `sink` and `on_refusal`, so the feed never
  reaches outside its own inputs to publish one.
  """
  @type notice_handler :: (Notice.t() -> any())

  @default_interval_ms 30_000

  # Nothing is fetched for the first stretch after start.
  #
  # A feed begins as soon as its supervisor starts it, which at boot is before
  # the rest of the platform is up. The first fetch went out while the rate
  # limiter's registry did not yet exist, raised, and the supervisor restarted
  # the feed straight back into the same raise — a crash loop that would have
  # taken the infrastructure tree down with it on reaching max_restarts.
  #
  # Delaying costs one cycle of one venue's data at boot and removes an entire
  # class of ordering dependency, so a feed cannot be broken by something being
  # moved earlier or later in the supervision tree afterwards.
  @default_start_delay_ms 8_000

  # A symbol counts as covered while something arrived within this multiple of
  # its own interval. Two intervals rather than one, so a single slow or failed
  # fetch reads as jitter instead of an outage.
  @coverage_grace 2

  # A fetch that never returns is not covered by `safely/1` — that catches a raise or an
  # `exit`, not a call that simply hangs. Verified: a fetcher doing `Process.sleep(:infinity)`
  # left `status/1` and `coverage/1` unanswerable, every symbol dark, with nothing logged —
  # the exact silent failure this module's moduledoc says it exists to make loud. `handle_info`
  # ran the fetch inline with no boundary, so one hung HTTP call wedged the whole feed's
  # mailbox, not just the symbol that hung.
  #
  # `:fetch_timeout_ms` bounds it. The default is DERIVED from the poll interval, but
  # clamped rather than used outright — `interval_ms` alone is the wrong number at both
  # ends:
  #
  #   * Too tight, and it kills fetches that were never hanging. A `fetch` is typically
  #     built on `HttpClient`, whose own per-request timeout defaults to 30s, and a single
  #     ordinary call can carry up to `retry_attempts` of those plus backoff. A feed polling
  #     every second — an entirely reasonable interval — would otherwise get a
  #     `:fetch_timeout_ms` of 1_000 and kill a normal retry sequence before `HttpClient`'s
  #     own timeout ever had a chance to fire. `@min_fetch_timeout_ms` floors it above that.
  #   * Too loose, and a venue polled once an hour could wedge this feed for an hour: no
  #     single hang should outlast the time it takes to notice one. `@max_fetch_timeout_ms`
  #     caps it.
  #
  # A hang past the boundary is reported through the same failure path as any other fetch
  # error — retried next tick, counted toward `failures_since_ok`, and escalated by the
  # existing "delivered NOTHING" warning — rather than a special case.
  @min_fetch_timeout_ms 30_000
  @max_fetch_timeout_ms 60_000

  defp default_fetch_timeout_ms(interval_ms) do
    interval_ms
    |> max(@min_fetch_timeout_ms)
    |> min(@max_fetch_timeout_ms)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Which symbols this poller is currently delivering.

  OBSERVED: a symbol appears only once a fetch has actually succeeded for it and
  is still recent. A symbol that has been asked for and never answered is absent,
  because reporting it as covered would be the venue asserting a delivery that
  never happened.
  """
  @spec coverage(pid() | atom()) :: %{String.t() => :internal_poll}
  def coverage(server), do: GenServer.call(server, :coverage)

  @doc """
  Whether this feed is delivering, and what went wrong if it is not.

  Exposed as DATA and not only as a log line, because "delivering nothing" is
  the condition a health check has to be able to ask about. Robinhood's feed ran
  a whole deployment publishing nothing — a log nobody greps in time is how that
  stays true for hours.
  """
  @spec status(pid() | atom()) :: %{
          delivering: boolean(),
          symbols: non_neg_integer(),
          covered: non_neg_integer(),
          failures_since_ok: non_neg_integer(),
          last_error: term()
        }
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Replace the symbol set without restarting the poller.
  """
  @spec update_symbols(pid() | atom(), [String.t()]) :: :ok
  def update_symbols(server, symbols), do: GenServer.cast(server, {:update_symbols, symbols})

  @impl true
  def init(opts) do
    # Bound first: the fetch timeout's own default is derived from the interval.
    interval_ms = Config.opt(opts, :interval_ms, @default_interval_ms)

    state = %{
      fetch: Keyword.get(opts, :fetch),
      fetch_all: Keyword.get(opts, :fetch_all),
      sink: Keyword.fetch!(opts, :sink),
      # Every default below goes through `Config.opt/3`, not `Keyword.get/3`, and that is
      # not interchangeable. A caller that forwards its own `opts` unchanged (as every
      # venue's `Feed` does, by family convention) hands each of these keys through with an
      # explicit `nil` when ITS OWN caller never set them — `Keyword.get/3` only substitutes
      # a default for an ABSENT key, not a present-and-nil one. This was originally fixed by
      # hand at exactly one call site here (`:start_delay_ms`, `|| @default_start_delay_ms`)
      # after that `nil` reached `Process.send_after/3` and crashed the feed into a restart
      # loop straight back into the same crash. It was open at every other site in this
      # `init/1` — `:interval_ms` crashed the same way, `:on_refusal` raised
      # `BadFunctionError`, `:symbols` raised inside `MapSet.new/1` — until `Config.opt/3`
      # closed the trap as a class rather than one incident at a time. See its moduledoc.
      interval_ms: interval_ms,
      label: Config.opt(opts, :label, "polling-feed"),
      # Injected like the sink, so the feed never reaches outside its own inputs.
      # Defaults to a no-op: a caller that does not care about refusals gets a
      # working feed, not a crash.
      on_refusal: Config.opt(opts, :on_refusal, fn _symbol, _reason -> :ok end),
      # Same shape, same trap, same fix as `on_refusal` above: a venue's `Feed` wrapper
      # forwards its own `opts` unchanged, so an `on_notice` this feed's caller never set
      # arrives as `on_notice: nil` rather than absent whenever ITS caller never set one
      # either. `Config.opt/3` is what keeps that `nil` from reaching `state.on_notice.()`
      # as a `BadFunctionError`. Defaults to a no-op: a caller that does not care about
      # notices gets a working feed, not a crash.
      on_notice: Config.opt(opts, :on_notice, fn _notice -> :ok end),
      symbols: MapSet.new(Config.opt(opts, :symbols, [])),
      start_delay_ms: Config.opt(opts, :start_delay_ms, @default_start_delay_ms),
      # See `@max_fetch_timeout_ms` above for why this exists and how the default is chosen.
      fetch_timeout_ms:
        Config.opt(opts, :fetch_timeout_ms, default_fetch_timeout_ms(interval_ms)),
      last_ok: %{},
      failures_since_ok: 0,
      last_error: nil,
      # Latches to `:dead` the instant the feed crosses into delivering-nothing, and back
      # to `:ok` on recovery. `record_failure/3` and `record_success/1` read this to fire
      # `on_notice` exactly once per transition — never once per failed tick, and never
      # once per sweep while an outage continues (unlike the "delivered NOTHING" log line,
      # which repeats every sweep by design; see `delivering_nothing?/2`).
      notice_state: :ok
    }

    if is_nil(state.fetch) and is_nil(state.fetch_all) do
      # Neither fetcher means a feed that would run forever delivering nothing,
      # which is indistinguishable from a quiet venue. Refuse to start instead.
      {:stop, :no_fetcher}
    else
      start_polling(state)
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:coverage, _from, state) do
    now = System.monotonic_time(:millisecond)
    window = state.interval_ms * @coverage_grace

    coverage =
      state.last_ok
      |> Enum.filter(fn {_symbol, at} -> now - at <= window end)
      |> Map.new(fn {symbol, _at} -> {symbol, :internal_poll} end)

    {:reply, coverage, state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      delivering: state.last_ok != %{},
      symbols: MapSet.size(state.symbols),
      covered: map_size(state.last_ok),
      failures_since_ok: state.failures_since_ok,
      last_error: state.last_error
    }

    {:reply, status, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_cast({:update_symbols, symbols}, state) do
    wanted = MapSet.new(symbols)

    # Only NEW symbols are scheduled, and only in per-symbol mode. Rescheduling
    # the existing ones would stack a second timer on each, doubling this
    # venue's request rate every time the scope is touched.
    if is_nil(state.fetch_all) do
      schedule_each(MapSet.difference(wanted, state.symbols), state.interval_ms)
    end

    {:noreply, %{state | symbols: wanted, last_ok: Map.take(state.last_ok, symbols)}}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_info(:poll_all, state) do
    state = fetch_all_and_publish(state)
    Process.send_after(self(), :poll_all, state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:poll, symbol}, state) do
    if MapSet.member?(state.symbols, symbol) do
      state = fetch_one_and_publish(symbol, state)
      Process.send_after(self(), {:poll, symbol}, state.interval_ms)
      {:noreply, state}
    else
      # Dropped from scope while a tick was in flight. Not rescheduling is what
      # removes it.
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp fetch_all_and_publish(%{symbols: symbols} = state) do
    case bounded_fetch(
           fn -> state.fetch_all.(MapSet.to_list(symbols)) end,
           state.fetch_timeout_ms
         ) do
      {:ok, []} ->
        # A bulk endpoint that answers successfully with zero events delivers exactly
        # nothing, same as an outright failure would — a bad credential filtered down to
        # an empty result set server-side is indistinguishable from one that raised, from
        # this module's side. Routing it through `record_success(state, false)` would be a
        # silent no-op forever: that path never reaches `delivering_nothing?`, so a bulk
        # venue stuck returning `{:ok, []}` every cycle would never trip the escalation
        # this module's moduledoc promises for exactly this shape.
        record_failure(state, "bulk fetch", :empty_response)

      {:ok, events} ->
        publish_and_record(state, events)

      {:refused, refusals} ->
        # See `t:fetch_all/0` — the batch analogue of `fetch`'s own `{:refused, reason}`.
        # Each named symbol is reported once, the same as the per-symbol path, rather than
        # silently retried forever as an ordinary `{:error, reason}` would be.
        Enum.each(refusals, fn {symbol, reason} -> state.on_refusal.(symbol, reason) end)
        record_failure(state, "bulk fetch", {:refused, refusals})

      {:error, reason} ->
        record_failure(state, "bulk fetch", reason)
    end
  end

  defp publish_and_record(state, events) do
    now = System.monotonic_time(:millisecond)

    # Coverage is recorded from what came BACK, not what was asked for. A
    # symbol missing from the response is one the venue did not answer for,
    # and marking it covered would be the feed asserting a delivery that
    # never happened.
    Enum.each(events, state.sink)

    seen = Map.new(events, fn event -> {event.symbol, now} end)
    record_success(%{state | last_ok: Map.merge(state.last_ok, seen)})
  end

  defp fetch_one_and_publish(symbol, state) do
    case bounded_fetch(fn -> state.fetch.(symbol) end, state.fetch_timeout_ms) do
      {:ok, event} ->
        %{state | last_ok: Map.put(state.last_ok, symbol, System.monotonic_time(:millisecond))}
        |> tap(fn _state -> state.sink.(event) end)
        |> record_success()

      # The venue says it does not carry this symbol. Reported outward — a
      # consumer drops it from its collection scope — rather than retried every
      # cycle forever. This recording used to live in shared collection code, so
      # moving a venue behind its own feed silently stopped it: one venue's 17
      # refused pairs sat on the page as "never arrived", with nothing left to
      # notice them.
      {:refused, reason} ->
        state.on_refusal.(symbol, reason)
        record_failure(state, symbol, reason)

      {:error, reason} ->
        record_failure(state, symbol, reason)
    end
  end

  # A fetch calls into HTTP and the venue's own parsing, and an exception there
  # must not take the feed down for every other symbol. One symbol raising
  # killed the whole of Robinhood's 87, and the supervisor restarted it straight
  # into the same raise.
  #
  # Not a swallow: the exception becomes the same failure the error path already
  # counts, so a feed broken this way still reports it is delivering nothing.
  defp safely(fetch) do
    fetch.()

    # BOUNDARY: one symbol's exception must not kill the whole feed.
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # `safely/1` is a boundary for a raise or an `exit`, and only that — it still calls
  # `fetch.()` inline, so a fetch that never returns (a blocked socket, an HTTP client with
  # no timeout of its own) still blocks `handle_info` and, with it, every other symbol's
  # tick and every `status/1` or `coverage/1` call waiting on this GenServer's mailbox.
  # Verified: a fetcher doing `Process.sleep(:infinity)` left the whole feed unanswerable.
  #
  # `bounded_fetch/2` closes that gap by running the (already exception-safe) fetch inside
  # its own process and waiting only up to `timeout_ms` for it. `Task.async/1` links the
  # task to this process, but nothing here can turn that link into a crash: `fetch` is
  # wrapped in `safely/1` before it ever reaches the task, so an ordinary raise or exit is
  # already converted to `{:error, reason}` inside the task and never becomes an abnormal
  # exit; the one abnormal exit this function itself can cause — killing the task after a
  # timeout — is handled by `Task.shutdown/2`, which unlinks before it kills. A hang past
  # `timeout_ms` becomes `{:error, :fetch_timeout}`, which the two callers already treat as
  # an ordinary fetch failure: retried next tick, counted toward `failures_since_ok`, and
  # escalated by the existing "delivered NOTHING" warning if it keeps happening — no new
  # failure path, because a hang is not a new kind of failure to a caller of this module.
  defp bounded_fetch(fetch, timeout_ms) do
    task = Task.async(fn -> safely(fetch) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:fetch_crashed, reason}}
      nil -> {:error, :fetch_timeout}
    end
  end

  # Recovery: this feed was latched `:dead` (see `notice_state` in `init/1`) and just
  # published something. `on_notice` fires the recovery half of the pair here, once, on
  # the transition back out — a consumer that learned a feed died and never learned it
  # recovered is only half-served.
  #
  # Called only on an actual delivery (a non-empty publish): `fetch_all_and_publish/1`
  # routes a `{:ok, []}` bulk response through `record_failure/3` instead, precisely so
  # this function's `:dead` clause — and the recovery notice it fires — only ever fires
  # when something was truly delivered. There is no `record_success(state, false)`
  # clause; every caller already knows it delivered before reaching here.
  defp record_success(%{notice_state: :dead} = state) do
    notice =
      Notice.new(:coverage_change, state.label,
        severity: :info,
        message:
          "#{state.label} has resumed delivering after #{state.failures_since_ok} " <>
            "consecutive failures",
        details: %{label: state.label, consecutive_failures: state.failures_since_ok}
      )

    state.on_notice.(notice)
    %{state | failures_since_ok: 0, last_error: nil, notice_state: :ok}
  end

  defp record_success(state), do: %{state | failures_since_ok: 0, last_error: nil}

  # One failure is noise; a whole cycle of them with nothing succeeding means
  # the feed is delivering nothing, which reads downstream as a quiet venue.
  defp record_failure(state, what, reason) do
    failures = state.failures_since_ok + 1
    Logger.debug("[#{state.label}] #{what}: #{inspect(reason)}")

    state =
      if delivering_nothing?(state, failures) do
        Logger.warning(
          "[#{state.label}] has delivered NOTHING in #{failures} consecutive attempts — " <>
            "this venue is indistinguishable from quiet while it lasts. Last error: " <>
            inspect(reason)
        )

        notify_delivering_nothing(state, failures, reason)
      else
        state
      end

    %{state | failures_since_ok: failures, last_error: reason}
  end

  # Fires `on_notice` exactly once per crossing into delivering-nothing. Once
  # `notice_state` is already `:dead`, every later sweep re-enters this same "delivering
  # nothing" branch (that repetition is what keeps the log line above alive for the
  # duration of an outage), but this clause short-circuits so the NOTICE does not repeat
  # with it — a notice per sweep on a long outage is still a storm, just a slower one.
  defp notify_delivering_nothing(%{notice_state: :dead} = state, _failures, _reason), do: state

  defp notify_delivering_nothing(state, failures, reason) do
    notice =
      Notice.new(:coverage_change, state.label,
        severity: :warning,
        message: "#{state.label} has delivered nothing in #{failures} consecutive attempts",
        details: %{label: state.label, consecutive_failures: failures, last_error: reason}
      )

    state.on_notice.(notice)
    %{state | notice_state: :dead}
  end

  # How stale the newest success may be before the feed counts as delivering
  # nothing. Generous against the slowest interval in the fleet so an ordinary
  # sweep can never trip it.
  @nothing_delivered_after_ms 300_000

  # Warn once a full sweep's worth of attempts has failed with no RECENT
  # success, then once per sweep after that — loud enough to find, quiet enough
  # to not drown the log while an outage continues.
  #
  # The test used to be `state.last_ok == %{}` — "nothing has EVER succeeded".
  # `last_ok` accumulates one entry per symbol and nothing ever removes them, so
  # after a feed's first successful fetch that condition is false forever and
  # this warning can never fire again. Every individual failure is `Logger.debug`
  # and the node runs at info, so a feed that worked once and then stopped
  # produced no log at any level.
  #
  # That is exactly what one venue's feed did on 2026-08-27: it delivered, went
  # silent at 18:22:56Z, and the only evidence anywhere was outside code inferring
  # the outage from the ABSENCE of ticks. The feed itself — the one process that
  # knew WHY — said nothing, three restarts in a row, because its "am I broken"
  # check had been dead since its first success.
  #
  # Recency, not ever-ness: a feed whose newest success is older than
  # `@nothing_delivered_after_ms` is not delivering, whatever it managed hours
  # ago.
  defp delivering_nothing?(state, failures) do
    per_sweep = max(MapSet.size(state.symbols), 1)
    sweep = if is_nil(state.fetch_all), do: per_sweep, else: 1

    rem(failures, sweep) == 0 and stale_success?(state)
  end

  defp stale_success?(%{last_ok: last_ok}) when map_size(last_ok) == 0, do: true

  defp stale_success?(%{last_ok: last_ok}) do
    newest = last_ok |> Map.values() |> Enum.max()

    System.monotonic_time(:millisecond) - newest > @nothing_delivered_after_ms
  end

  defp start_polling(%{fetch_all: nil} = state),
    do: schedule_each(state.symbols, state.interval_ms, state.start_delay_ms)

  defp start_polling(state), do: Process.send_after(self(), :poll_all, state.start_delay_ms)

  # Start times spread across the interval, so the venue sees a flat request
  # rate instead of the whole symbol set arriving at once.
  # The FIRST sweep is compressed; later ones use the full interval.
  #
  # Spreading the first pass across the whole interval means a venue takes that
  # long to have any coverage at all — 90 seconds for Webull, on top of the
  # start delay — and every restart shows most of its pairs stopped until it
  # finishes. Before these feeds existed, a Quantum task swept everything every
  # 30 seconds and there was no such window.
  #
  # So the opening sweep is spread over `@first_sweep_ms` instead, fast enough
  # that coverage is up almost immediately, and each symbol then reschedules
  # itself at the real interval. The venue sees one brisker-than-usual minute at
  # boot and its normal rate thereafter.
  @first_sweep_ms 20_000

  defp schedule_each(symbols, interval_ms, start_delay_ms \\ 0) do
    count = max(MapSet.size(symbols), 1)
    spread = min(interval_ms, @first_sweep_ms)
    step = max(div(spread, count), 1)

    symbols
    |> Enum.with_index()
    |> Enum.each(fn {symbol, index} ->
      Process.send_after(self(), {:poll, symbol}, start_delay_ms + index * step)
    end)
  end
end
