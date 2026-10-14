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
  absent from `coverage/1` until one succeeds. It is never dropped: this module cannot
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

  ## A fetch that never returns fails just as loudly — and never blocks a health check

  Two hazards live here. They look like one and needed two separate fixes.

  **The hang.** Nothing in this module's own code can time out a caller's `fetch`, so that
  has to be a boundary this module imposes. Without one, a single hung fetch (a socket that
  never closes, an HTTP client with no timeout of its own) blocks this GenServer forever.
  So every fetch runs inside a disposable task and a hang past `:fetch_timeout_ms` becomes
  an ordinary fetch failure — retried next tick, counted toward `failures_since_ok`,
  escalated the same way a real error would be. The default is derived from the poll
  interval and clamped between `@min_fetch_timeout_ms` and `@max_fetch_timeout_ms`, so this
  module never trades an unbounded hang for a merely very long one, and never turns a fast
  interval into an accidental timeout on an ordinary, slower-than-a-tick HTTP round trip.

  **Waiting on that task was the second hazard, and it is the one that bit.** This module
  used to run the fetch in a task and then BLOCK on it inside `handle_info`. The task
  bounded the hang; it did nothing at all for the mailbox. With `@min_fetch_timeout_ms` at
  30 seconds and `GenServer.call/2`'s default timeout at five, a `coverage/1` or `status/1`
  arriving during an ordinary in-flight fetch was not unlucky — it was a **guaranteed**
  timeout. In `dp_exchange_robinhood` that exit propagated out of the venue `Feed`'s own
  `handle_call` and killed it (dp-exchange-core issue #28): a read-only health check
  terminated the thing it was checking, the feed restarted without the subscription state
  its static start opts never carried, and coverage went 61 pairs to 0 and stayed there —
  while the process sat alive and idle, so every liveness probe kept passing.

  So the fetch result now arrives as a **message**. `handle_info` starts the task and
  returns immediately, and `coverage/1` and `status/1` answer from state at any point
  during a fetch. A health check can no longer be what breaks the thing it observes.

  **Concurrency is deliberately still one.** A tick arriving while a fetch is in flight is
  queued, not started — which is exactly what the mailbox did when the fetch was
  synchronous. Letting ticks overlap would quietly multiply a venue's request rate the
  moment a fetch grew slower than its interval, and an unexamined multiplier on request
  volume is a defect class this family has paid for more than once. Rescheduling still
  happens only after a job finishes, so there is at most one pending job per symbol and the
  queue cannot grow without bound.

  ## A consumer's callback cannot take the feed down

  `:sink`, `:on_refusal` and `:on_notice` run inside this process. A raise, exit or throw in
  one is caught, logged as a warning that names the callback and the exception's module (not
  its message, which can quote the venue payload it was handed), and the feed carries on.
  Without that the callback's failure restarted the feed, and the restart lost every scope
  set by `update_symbols/2`. A callback that fails on every event is therefore a log line per
  event, not a restart loop.
  """

  use GenServer

  require Logger

  alias DpExchange.Core.{Config, Notice, Telemetry}

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
  module did not already handle, other than reporting the
  whole batch as an ordinary `{:error, reason}` — which, unlike a real `:refused`, is
  retried forever and never reaches `on_refusal`, so the caller never learns to drop the
  symbol from its scope. `dp_exchange_robinhood` documented this exact gap as the reason
  it stayed on per-symbol `:fetch` rather than adopt this endpoint's own documented
  repeatable-query bulk mode.

  A bulk response with zero events (`{:ok, []}`) is treated as delivering nothing for
  escalation purposes even though the call itself succeeded.
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

  @doc """
  Starts a polling feed. An explicit `nil` for any option below is read as absent.

  ## Options

    * `:sink` - **required**, a 1-arity function called with each event a fetch produces.
      A missing or non-function value stops the feed at start.
    * `:fetch` - `t:fetch/0`, one symbol per call.
    * `:fetch_all` - `t:fetch_all/0`, the whole symbol set per call. At least one of
      `:fetch` and `:fetch_all` is required; with neither the feed stops with `:no_fetcher`.
    * `:symbols` - the symbols to poll (default: `[]`; see `update_symbols/2`).
    * `:interval_ms` - poll interval, a positive integer (default: `#{@default_interval_ms}`).
    * `:start_delay_ms` - wait before the first sweep, a non-negative integer (default:
      `#{@default_start_delay_ms}`).
    * `:fetch_timeout_ms` - a fetch still running after this is a failure, a positive
      integer (default: the interval, clamped to
      `#{@min_fetch_timeout_ms}`..`#{@max_fetch_timeout_ms}`).
    * `:label` - names this feed in notices and logs (default: `"polling-feed"`).
    * `:provider` - what a `Core.Notice` from this feed names as its provider (default:
      `:label`).
    * `:on_refusal` - `(symbol, reason -> any)`, called once per refused symbol (default:
      no-op).
    * `:on_notice` - `t:notice_handler/0` (default: no-op).
    * `:name` - registered name (default: unregistered).

  A duration that is not of the stated kind stops the feed at start with
  `{:invalid_option, key, value}`, the way a missing `:sink` does. `interval_ms: 0` would
  otherwise re-poll the venue as fast as the fetch returns.
  """
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
  @spec update_symbols(pid() | atom(), [String.t()] | MapSet.t(String.t())) :: :ok
  # A list or a `MapSet`, anything else refused HERE in the caller. This is a cast, so a
  # `nil` or a bare map was handled inside the feed, where `MapSet.new/1` raised and killed
  # it: the restart started from its static start opts and lost every scope set by earlier
  # `update_symbols/2` calls, which is the incident `guarded/3` and `safely/1` exist to
  # prevent. The mistake belongs at the call.
  def update_symbols(server, symbols) when is_list(symbols) or is_struct(symbols, MapSet),
    do: GenServer.cast(server, {:update_symbols, symbols})

  @impl true
  def init(opts) do
    # **Every fetch task is LINKED to this process (`Task.async/1`), and a linked process that
    # dies abnormally takes an untrapping owner with it.** `safely/1` converts a raise, exit
    # or throw INSIDE the fetch, but not a task killed from outside: a heap limit, a process
    # the fetch itself linked to crashing, an operator's `Process.exit/2`. Any of those sent
    # the exit signal here, the feed died, and the restart came back from its static start
    # opts and lost every scope set by `update_symbols/2`: the incident this module's
    # moduledoc records for a raising callback, arriving through the link instead of a raise.
    # Trapping turns the signal into an `{:EXIT, _, _}` message (ignored by the catch-all
    # `handle_info/2`) and leaves the monitor's `:DOWN` to record the fetch as failed, which
    # is what the `:DOWN` clause below was always documented to do and could not reach.
    # Core's own `LinkSafetyCheck` flags this exact shape in a venue's process.
    Process.flag(:trap_exit, true)

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
      # What a `Core.Notice` from this feed names as its `provider`.
      #
      # It used to be `label` itself, and that made `notice.provider` unusable for the one
      # thing a consumer reaches for it for. A venue's own `Feed` builds its notices with the
      # venue ATOM (`Notice.new(:link_down, :robinhood, ...)`), while the poller inside the
      # same package built them with a STRING — so one venue emitted both `:robinhood` and
      # `"robinhood"`, and Schwab emitted `:schwab` alongside `"schwab-fallback-poll"`. A
      # consumer routing notices by provider silently dropped or mis-filed every notice that
      # came from the poll, and nothing failed: the value stayed plausible and only its
      # meaning was wrong.
      #
      # Defaulting to `label` keeps every existing caller answering exactly what it did
      # before; a venue that wants `provider` to mean the venue passes its own atom. The
      # label still identifies WHICH feed inside `message` and `details.label`, which is what
      # it was good at.
      provider: Config.opt(opts, :provider, Config.opt(opts, :label, "polling-feed")),

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
      # Symbols whose refusal has been reported and that have not delivered since. See
      # `report_refusal/3`.
      refused: MapSet.new(),
      failures_since_ok: 0,
      last_error: nil,
      # Latches to `:dead` the instant the feed crosses into delivering-nothing, and back
      # to `:ok` on recovery. `record_failure/3` and `record_success/1` read this to fire
      # `on_notice` exactly once per transition — never once per failed tick, and never
      # once per sweep while an outage continues (unlike the "delivered NOTHING" log line,
      # which repeats every sweep by design; see `delivering_nothing?/2`).
      notice_state: :ok,
      # Whether `[:dp_exchange, :link, :up]` has been emitted for this feed. See
      # `record_success/1`.
      link_up_sent: false,
      # The single in-flight fetch, or `nil`. See the moduledoc: the task exists to bound a
      # hang, and NOT waiting on it is what keeps `coverage/1` and `status/1` answerable
      # while a fetch is running.
      in_flight: nil,
      # Ticks that arrived while a fetch was in flight, oldest first. This is the mailbox
      # queue the synchronous version had, made explicit — concurrency stays at one.
      queue: :queue.new(),
      # Per-symbol mode: the symbols that already have a tick coming — a timer pending, a
      # job queued, or a fetch in flight. **This is the set `update_symbols/2` must consult,
      # and `state.symbols` is not it.**
      #
      # `handle_cast({:update_symbols, _})` scheduled `wanted - state.symbols`, reasoning
      # that a symbol already in scope already has a timer. True for a symbol that stayed;
      # false for one that LEFT and came back, because the removal took it out of
      # `state.symbols` while its pending timer went on existing. The re-add then counted it
      # as new and set a second timer, and neither ever expires — `reschedule/2` re-arms both
      # forever.
      #
      # Measured before the fix, per-symbol mode at a 200ms interval, one symbol churned and
      # one left alone as a control: three remove/re-add cycles took the churned symbol from
      # 5 fetches a second to 20 — **x4, permanently** — while the control stayed at 5. Each
      # cycle stacks another timer. That is the multiplier this module's own
      # `update_symbols` comment says it exists to prevent, arriving through the one door the
      # guard did not cover.
      scheduled: MapSet.new()
    }

    case validate_options(state) do
      :ok -> {:ok, start_polling(state)}
      {:error, reason} -> {:stop, reason}
    end
  end

  # The first option that cannot work, in the order a reader would fix them, or `:ok`.
  # Every check is a plain boolean over `state`, so none can raise, and the list is data
  # rather than a `cond` so adding a check does not add a branch to `init/1`.
  defp validate_options(state) do
    [
      # Neither fetcher means a feed that would run forever delivering nothing, which is
      # indistinguishable from a quiet venue. Refuse to start instead.
      {not (is_nil(state.fetch) and is_nil(state.fetch_all)), :no_fetcher},
      # **Checked here, at start, because the alternative was a crash loop.** `:sink` is
      # read with `Keyword.fetch!/2`, which proves only that the KEY is present — `sink: nil`
      # passes it. The feed then started cleanly and died with `{:badfun, nil}` on its first
      # successful fetch, measured; under a supervisor that restarts straight back into the
      # same death, with a message naming `apply_result/3` rather than the option that is
      # wrong. It is the shape this module's own `init/1` comment records for `:on_refusal`,
      # arriving through the one required function the `Config.opt/3` fix could not reach —
      # a required option has no default to fall back to.
      {is_function(state.sink, 1), {:invalid_option, :sink, state.sink}},
      {is_nil(state.fetch) or is_function(state.fetch, 1),
       {:invalid_option, :fetch, state.fetch}},
      {is_nil(state.fetch_all) or is_function(state.fetch_all, 1),
       {:invalid_option, :fetch_all, state.fetch_all}},
      # **The three durations are checked here, at start, for the same reason as `:sink`.**
      # `interval_ms: 0` made `Process.send_after/3` fire at once, forever: a feed that
      # re-polled the venue as fast as the fetch returned, which is the request-rate
      # multiplier this module's moduledoc is built to prevent. A negative or non-integer
      # value raised inside `init/1`, a restart loop whose message named `send_after/3`
      # rather than the option. A `fetch_timeout_ms` of `0` timed every fetch out before it
      # started, so the feed delivered nothing and reported it as a venue fault.
      {is_integer(state.interval_ms) and state.interval_ms > 0,
       {:invalid_option, :interval_ms, state.interval_ms}},
      {is_integer(state.start_delay_ms) and state.start_delay_ms >= 0,
       {:invalid_option, :start_delay_ms, state.start_delay_ms}},
      {is_integer(state.fetch_timeout_ms) and state.fetch_timeout_ms > 0,
       {:invalid_option, :fetch_timeout_ms, state.fetch_timeout_ms}}
    ]
    |> Enum.find_value(:ok, &first_invalid/1)
  end

  defp first_invalid({true, _reason}), do: nil
  defp first_invalid({false, reason}), do: {:error, reason}

  @impl true
  def handle_call(:coverage, _from, state) do
    coverage = Map.new(fresh_symbols(state), &{&1, :internal_poll})

    {:reply, coverage, state}
  end

  # Windowed like `coverage/1`. It used `last_ok` as ever-delivered, which is pruned only by
  # `update_symbols/2`, so one success at boot kept `delivering: true` on a feed dead for
  # hours — on the read the moduledoc offers as the health check.
  def handle_call(:status, _from, state) do
    covered = length(fresh_symbols(state))

    status = %{
      delivering: covered > 0,
      symbols: MapSet.size(state.symbols),
      covered: covered,
      failures_since_ok: state.failures_since_ok,
      last_error: state.last_error
    }

    {:reply, status, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_cast({:update_symbols, symbols}, state) do
    wanted = MapSet.new(symbols)

    # Only symbols with no tick already coming are scheduled, and only in per-symbol mode.
    # Scheduling one that already has a timer stacks a second on it, doubling this venue's
    # request rate every time the scope is touched.
    #
    # The set to subtract is `state.scheduled`, NOT `state.symbols` — see that field's own
    # comment in `init/1` for the measurement. A symbol removed and re-added is absent from
    # `state.symbols` and still very much present in the timer queue.
    state =
      if is_nil(state.fetch_all) do
        scheduled = schedule_each(MapSet.difference(wanted, state.scheduled), state.interval_ms)
        %{state | scheduled: MapSet.union(state.scheduled, scheduled)}
      else
        state
      end

    {:noreply,
     %{
       state
       | symbols: wanted,
         last_ok: Map.take(state.last_ok, MapSet.to_list(wanted)),
         refused: MapSet.intersection(state.refused, wanted)
     }}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  # **A bulk tick with nothing wanted asks nothing.** It used to run the fetch with `[]`, and a
  # venue answering an empty ask with `{:ok, []}`, the only honest answer, was recorded as
  # `:empty_response`, a failure. So a feed started before its consumer subscribed, or left
  # idle after the last unsubscribe, escalated to "delivering nothing" and warned every
  # interval about symbols nobody had asked for. The clock keeps running, so the next tick
  # after `update_symbols/2` adds one fetches it, on the one timer chain there is.
  def handle_info(:poll_all, state) do
    if MapSet.size(state.symbols) == 0,
      do: {:noreply, reschedule(state, :all)},
      else: {:noreply, enqueue(state, :all)}
  end

  def handle_info({:poll, symbol}, state) do
    if MapSet.member?(state.symbols, symbol) do
      # Stays in `scheduled`: the timer has fired, but this symbol still has a tick in the
      # pipeline — queued now, in flight next, re-armed by `reschedule/2` after that. It
      # leaves the set only where that chain actually ends, below and in `reschedule/2`.
      {:noreply, enqueue(state, {:one, symbol})}
    else
      # Dropped from scope while a tick was pending. Not rescheduling is what removes it,
      # and forgetting it here is what lets a later re-add schedule it again exactly once.
      {:noreply, %{state | scheduled: MapSet.delete(state.scheduled, symbol)}}
    end
  end

  # The in-flight fetch outlived `:fetch_timeout_ms`. Ordered ABOVE the `{ref, result}`
  # clause below deliberately: that pattern is a bare two-tuple and would be tried against
  # this message first, and while the `in_flight` guard would reject it, relying on a
  # rejection to route a message is the kind of ordering nobody re-derives correctly later.
  def handle_info(
        {:fetch_timeout, ref},
        %{in_flight: %{ref: ref, task: task} = flight} = state
      ) do
    # `Task.shutdown/2` unlinks before it kills, so killing the task cannot take this
    # process with it. Its return value is used rather than discarded: a task that finished
    # in the instant between the timer firing and this clause running produced a real
    # result, and throwing that away to record a timeout would be a lie about the venue.
    # This is exactly what the old synchronous `Task.yield(...) || Task.shutdown(...)` did.
    result =
      case Task.shutdown(task, :brutal_kill) do
        {:ok, late_result} -> late_result
        {:exit, reason} -> {:error, {:fetch_crashed, opaque_reason(reason)}}
        nil -> {:error, :fetch_timeout}
      end

    {:noreply, finish(state, flight, result)}
  end

  # The task died without answering. `safely/1` converts a raise, a throw and an `exit`
  # inside the fetch into `{:error, reason}` before they can get here, so this is reachable
  # only by something killing the task from outside — which is a fetch failure like any
  # other to a caller of this module, not a new failure path.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{in_flight: %{ref: ref, timer: timer} = flight} = state
      ) do
    Process.cancel_timer(timer)
    {:noreply, finish(state, flight, {:error, {:fetch_crashed, opaque_reason(reason)}})}
  end

  # The fetch answered. This is the path that used to be a blocking `Task.yield/2` inside
  # `handle_info` — see the moduledoc for what that cost.
  def handle_info({ref, result}, %{in_flight: %{ref: ref, timer: timer} = flight} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    {:noreply, finish(state, flight, result)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # One completion, whatever produced it: record the outcome, put this job's next tick back
  # on the clock, then start whatever queued up while it ran. Rescheduling happens HERE and
  # nowhere else, which is what bounds the queue — a symbol cannot have a second tick
  # pending until its first has finished.
  defp finish(state, %{job: job} = flight, result) do
    state
    |> Map.put(:in_flight, nil)
    |> apply_flight(flight, result)
    |> reschedule(job)
    |> start_next()
  end

  # **A bulk result for a set that is entirely gone is dropped, not counted.** Interleaving:
  # (1) a bulk fetch for {A, B} is in flight; (2) `update_symbols(feed, [])` (the consumer
  # unsubscribed everything); (3) the fetch answers `{:ok, [A, B]}`, or `{:error, _}`. Every
  # event is now unwanted, so `publish_and_record/2` recorded `{:unrequested_symbols, _}` and an
  # error counted as well: `last_ok` had been pruned empty, so `delivering_nothing?/2` held and
  # the feed warned and sent a `:coverage_change` outage notice and `[:link, :down]` for symbols
  # nobody wanted any more. The per-symbol path has always dropped this (`apply_result/3`); this
  # is the same rule for the bulk job, decided against the set the fetch was ASKED for.
  #
  # **And a bulk result's events for symbols removed in flight are dropped before counting.**
  # The disjoint case above was the whole-set version; the partial one remained: asked {A, B},
  # then `update_symbols([B, C])`, then an answer carrying only A. A was asked for and is no
  # longer wanted, so it is neither delivered nor a venue answering what nobody asked for, but
  # `publish_and_record/2` saw every event unwanted and recorded `{:unrequested_symbols, ["A"]}`
  # as a failure. Only a symbol the fetch did NOT ask for is unrequested.
  defp apply_flight(state, %{job: :all, asked: asked}, result) do
    if MapSet.disjoint?(asked, state.symbols) do
      state
    else
      case result |> proper_lists_only() |> drop_removed_in_flight(asked, state.symbols) do
        :removed_in_flight -> state
        kept -> apply_result(state, :all, kept)
      end
    end
  end

  defp apply_flight(state, %{job: job}, result), do: apply_result(state, job, result)

  # **An improper list in a bulk answer is a failure, not a crash.** `{:ok, [event | :tail]}`
  # matched `{:ok, [_first | _rest]}` and then raised in `Enum.reject/2` (and in `Enum.all?/2`
  # for `{:refused, _}`) inside this process: the restart lost every runtime `update_symbols/2`
  # scope, the incident `safely/1` exists to prevent, reached through the shape of a list a
  # fetch built from a venue payload. Reported like any other answer outside `t:fetch_all/0`.
  defp proper_lists_only({tag, list} = result) when tag in [:ok, :refused] and is_list(list) do
    if proper_list?(list), do: result, else: {:bad_fetch_result_improper_list, tag}
  end

  defp proper_lists_only(result), do: result

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper_tail), do: false

  # A result left empty BY this filter is not the venue answering nothing (`:empty_response`):
  # it answered, about symbols no longer wanted. It is ignored rather than counted either way.
  defp drop_removed_in_flight({:ok, [_first | _rest] = events}, asked, wanted) do
    kept = Enum.reject(events, &removed_in_flight?(&1, asked, wanted))
    if kept == [], do: :removed_in_flight, else: {:ok, kept}
  end

  defp drop_removed_in_flight(result, _asked, _wanted), do: result

  defp removed_in_flight?(%{symbol: symbol}, asked, wanted),
    do: MapSet.member?(asked, symbol) and not MapSet.member?(wanted, symbol)

  defp removed_in_flight?(_not_an_event, _asked, _wanted), do: false

  # An Erlang `:queue`, not a list appended to: with thousands of symbols and a fetch slower
  # than the interval the queue holds one job per symbol, and `queue ++ [job]` copied all of
  # them on every tick (O(n) each, O(n^2) a cycle) inside the one process that answers
  # `status/1`. `:queue.in/2` is amortised constant time and keeps the same FIFO order.
  defp enqueue(state, job), do: start_next(%{state | queue: :queue.in(job, state.queue)})

  # Concurrency is one, by construction. See the moduledoc: this is the mailbox queue the
  # synchronous version had, made explicit, and NOT an invitation to raise the limit — a
  # venue's request rate is the thing on the other side of it.
  #
  # Both conditions are in the head rather than in a guard: a fetch starts only when
  # nothing is in flight AND something is waiting. Anything else — a fetch already running,
  # an empty queue, or both — falls through to the catch-all and leaves the state alone.
  # A queued symbol unsubscribed before its turn is skipped, not fetched: its result would
  # be dropped by `apply_result/3` anyway, after spending a venue request.
  #
  # **Skipping it ends its chain, so it leaves `scheduled` here.** It used to stay in the set,
  # and this was the one exit that forgot it: `{:poll, _}` and `reschedule/2` both delete. A
  # symbol removed while queued and later re-added then looked already scheduled to
  # `update_symbols/2`, got no timer, and was never polled again, with `coverage/1` silent
  # about it. Found 2026-10-10 by reading the path.
  defp start_next(%{in_flight: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, {:one, symbol} = job}, rest} ->
        if MapSet.member?(state.symbols, symbol) do
          start_fetch(state, job, rest)
        else
          start_next(%{state | queue: rest, scheduled: MapSet.delete(state.scheduled, symbol)})
        end

      {{:value, job}, rest} ->
        start_fetch(state, job, rest)

      {:empty, _queue} ->
        state
    end
  end

  defp start_next(state), do: state

  defp start_fetch(state, job, rest) do
    task = Task.async(fn -> safely(fetch_fun(state, job)) end)
    timer = Process.send_after(self(), {:fetch_timeout, task.ref}, state.fetch_timeout_ms)

    # `asked` is the scope at the instant the fetch started: see `apply_flight/3`.
    flight = %{ref: task.ref, task: task, job: job, timer: timer, asked: state.symbols}
    %{state | queue: rest, in_flight: flight}
  end

  # Built from the two values the fetch needs rather than by closing over `state`, so the
  # symbol list and `last_ok` map are not copied into every task.
  defp fetch_fun(%{fetch_all: fetch_all, symbols: symbols}, :all) do
    wanted = MapSet.to_list(symbols)
    fn -> fetch_all.(wanted) end
  end

  defp fetch_fun(%{fetch: fetch}, {:one, symbol}), do: fn -> fetch.(symbol) end

  defp reschedule(state, :all) do
    Process.send_after(self(), :poll_all, state.interval_ms)
    state
  end

  defp reschedule(state, {:one, symbol}) do
    # Only a symbol still in scope is re-armed. It used to re-arm unconditionally and let
    # `handle_info({:poll, _})` drop the tick on arrival, which worked but left the symbol
    # counted as scheduled for a further interval — long enough for a re-add to see a clear
    # field and set a second timer.
    if MapSet.member?(state.symbols, symbol) do
      Process.send_after(self(), {:poll, symbol}, state.interval_ms)
      %{state | scheduled: MapSet.put(state.scheduled, symbol)}
    else
      %{state | scheduled: MapSet.delete(state.scheduled, symbol)}
    end
  end

  defp apply_result(state, :all, result) do
    case result do
      {:bad_fetch_result_improper_list, tag} ->
        record_failure(state, "bulk fetch", {:bad_fetch_result, {tag, :improper_list}})

      {:ok, []} ->
        # A bulk endpoint that answers successfully with zero events delivers exactly
        # nothing, same as an outright failure would — a bad credential filtered down to
        # an empty result set server-side is indistinguishable from one that raised, from
        # this module's side. Routing it through `record_success(state, false)` would be a
        # silent no-op forever: that path never reaches `delivering_nothing?`, so a bulk
        # venue stuck returning `{:ok, []}` every cycle would never trip the escalation
        # this module's moduledoc promises for exactly this shape.
        record_failure(state, "bulk fetch", :empty_response)

      {:ok, events} when is_list(events) ->
        if Enum.all?(events, &(is_map(&1) and is_map_key(&1, :symbol))),
          do: publish_and_record(state, events),
          else: record_failure(state, "bulk fetch", {:bad_fetch_result, :event_without_symbol})

      {:refused, refusals} when is_list(refusals) ->
        # See `t:fetch_all/0` — the batch analogue of `fetch`'s own `{:refused, reason}`.
        # Each named symbol is reported once, the same as the per-symbol path, rather than
        # silently retried forever as an ordinary `{:error, reason}` would be.
        apply_refusals(state, refusals)

      {:error, reason} ->
        record_failure(state, "bulk fetch", reason)

      # **An answer outside `t:fetch_all/0` is a failure, not a crash.** There was no
      # catch-all, so a fetch returning `:ok`, `nil` or `{:ok, nil}` raised `CaseClauseError`
      # in this process, and an event that was not a map raised on `& &1.symbol`. Either way
      # the restart lost every runtime `update_symbols/2` scope, the incident `safely/1`
      # exists to prevent, reached through a return instead of a raise. Found 2026-10-10 by
      # reading the path.
      other ->
        record_failure(state, "bulk fetch", {:bad_fetch_result, other})
    end
  end

  # **A result is applied only for a symbol still wanted.** A fetch runs in a task, and
  # `update_symbols/2` can remove its symbol while it is in flight. The result that came back
  # afterwards used to reach the sink, which delivered to a consumer that had just
  # unsubscribed, and went into `last_ok`. So `coverage/1` answered `:internal_poll` for a
  # symbol nobody wanted, until the next `update_symbols/2` pruned it. Found 2026-09-27 by
  # reading the path; the tests under "a result for a symbol no longer wanted" pin it.
  #
  # **That holds for a refusal and an error too, not only a delivery.** Only the delivery arms
  # checked the scope, so a `{:refused, _}` for a symbol removed in flight still called
  # `on_refusal` (a consumer told about a symbol it had unsubscribed) and put the symbol into
  # `refused`, where nothing pruned it until the next `update_symbols/2`; an `{:error, _}` for
  # one counted toward `failures_since_ok` and could trip the delivering-nothing notice.
  defp apply_result(state, {:one, symbol}, result) do
    if MapSet.member?(state.symbols, symbol),
      do: apply_wanted(state, symbol, result),
      else: state
  end

  defp apply_wanted(state, symbol, result) do
    case result do
      # **The event must be for the symbol that was asked.** The bulk path refuses events
      # nobody asked for (`{:unrequested_symbols, _}` below), and this path checked nothing:
      # a venue answering `"BTC-USD"` with an event spelled `"XBT-USD"` reached the sink
      # under that spelling while `coverage/1` reported `"BTC-USD"` as delivered. Found
      # 2026-10-10 by reading the path.
      {:ok, %{symbol: ^symbol} = event} ->
        deliver_one(state, symbol, event)

      {:ok, %{symbol: other}} ->
        record_failure(state, symbol, {:unrequested_symbols, [other]})

      # The venue says it does not carry this symbol. Reported outward — a
      # consumer drops it from its collection scope — rather than retried every
      # cycle forever. This recording used to live in shared collection code, so
      # moving a venue behind its own feed silently stopped it: one venue's 17
      # refused pairs sat on the page as "never arrived", with nothing left to
      # notice them.
      {:refused, reason} ->
        state
        |> report_refusal(symbol, reason)
        |> record_failure(symbol, reason)

      {:error, reason} ->
        record_failure(state, symbol, reason)

      # Outside `t:fetch/0`, including an event with no `:symbol` to check. See the bulk
      # clause above: a failure, never a crash of the feed.
      other ->
        record_failure(state, symbol, {:bad_fetch_result, other})
    end
  end

  # **A refusal list that is not `[{symbol, reason}]` is a failure, not a crash.** The reduce
  # matched `{symbol, reason}` in its fn head, so one malformed element (a bare symbol, a
  # three-tuple) raised `FunctionClauseError` in this process and the restart lost every
  # runtime `update_symbols/2` scope: the same incident the catch-all clauses above close for
  # an answer outside `t:fetch_all/0`, reached through a malformed element of a valid one.
  defp apply_refusals(state, refusals) do
    if Enum.all?(refusals, &match?({symbol, _reason} when is_binary(symbol), &1)) do
      # Only a symbol still in scope is reported or latched. `refused` is pruned by
      # `update_symbols/2` alone, so a venue naming symbols nobody asked for (or that were
      # removed in flight) would otherwise grow it, and tell the consumer about them.
      state =
        Enum.reduce(refusals, state, fn {symbol, reason}, acc ->
          if MapSet.member?(acc.symbols, symbol),
            do: report_refusal(acc, symbol, reason),
            else: acc
        end)

      record_failure(state, "bulk fetch", {:refused, refusals})
    else
      record_failure(state, "bulk fetch", {:bad_fetch_result, {:refused, refusals}})
    end
  end

  # **Reported once, as the typedoc says, and still asked.** `on_refusal` fired every cycle
  # the venue refused, so a consumer got the same refusal every interval for as long as it
  # kept the symbol. Now it fires once per refusal, and the latch clears the moment the
  # symbol delivers again. The symbol stays polled, because a pair the venue lists later
  # must be able to come back without the consumer re-adding it.
  defp report_refusal(state, symbol, reason) do
    if MapSet.member?(state.refused, symbol) do
      state
    else
      guarded(state, :on_refusal, fn -> state.on_refusal.(symbol, reason) end)
      %{state | refused: MapSet.put(state.refused, symbol)}
    end
  end

  # **A consumer's callback is not allowed to take the feed down.** `sink`, `on_refusal` and
  # `on_notice` run inside this GenServer, so a raise in one killed the feed, and the restart
  # lost every runtime `update_symbols/2` scope: the incident `safely/1` closes for the fetch,
  # reached through the other side of the feed. The failure is logged, naming the callback
  # and the exception's MODULE only: an exception message can quote its arguments, and the
  # argument here is a venue payload. The feed carries on, and a sink that raises for every
  # event is a sink the consumer reads about in its log, not a feed that restarts forever.
  defp guarded(state, callback, fun) do
    fun.()
    :ok
  rescue
    exception ->
      Logger.warning(
        "[#{state.label}] #{callback} callback raised #{inspect(exception.__struct__)}; " <>
          "the feed continues"
      )

      :ok
  catch
    kind, _reason ->
      Logger.warning(
        "[#{state.label}] #{callback} callback ended with a #{kind}; the feed continues"
      )

      :ok
  end

  defp deliver_one(state, symbol, event) do
    %{
      state
      | last_ok: Map.put(state.last_ok, symbol, System.monotonic_time(:millisecond)),
        refused: MapSet.delete(state.refused, symbol)
    }
    |> tap(fn _state -> guarded(state, :sink, fn -> state.sink.(event) end) end)
    |> tap(fn _state -> report_delivery(state, event) end)
    |> record_success()
  end

  # Only events for symbols still wanted are delivered and counted; see `apply_result/3`.
  # One that is not wanted is either a symbol removed while this fetch was in flight, or
  # one the venue answered that nobody asked for. If EVERY event is unwanted, the drop would
  # look exactly like a quiet venue, and the likeliest cause is a venue whose event symbols
  # are not spelled the way they were asked for. So that case is a failure, named, and
  # reaches `delivering_nothing?/2` like any other.
  defp publish_and_record(state, events) do
    case Enum.split_with(events, &MapSet.member?(state.symbols, &1.symbol)) do
      {[], [_first | _rest] = unwanted} ->
        names = unwanted |> Enum.map(& &1.symbol) |> Enum.uniq() |> Enum.take(5)
        record_failure(state, "bulk fetch", {:unrequested_symbols, names})

      {wanted, _unwanted} ->
        publish_wanted(state, wanted)
    end
  end

  defp publish_wanted(state, events) do
    now = System.monotonic_time(:millisecond)

    # Coverage is recorded from what came BACK, not what was asked for. A
    # symbol missing from the response is one the venue did not answer for,
    # and marking it covered would be the feed asserting a delivery that
    # never happened.
    Enum.each(events, fn event ->
      guarded(state, :sink, fn -> state.sink.(event) end)
      report_delivery(state, event)
    end)

    seen = Map.new(events, fn event -> {event.symbol, now} end)

    record_success(%{
      state
      | last_ok: Map.merge(state.last_ok, seen),
        refused: MapSet.difference(state.refused, MapSet.new(Map.keys(seen)))
    })
  end

  # A fetch calls into HTTP and the venue's own parsing, and an exception there
  # must not take the feed down for every other symbol. One symbol raising
  # killed the whole of Robinhood's 87, and the supervisor restarted it straight
  # into the same raise.
  #
  # Not a swallow: the exception becomes the same failure the error path already
  # counts, so a feed broken this way still reports it is delivering nothing.
  #
  # Runs INSIDE the task, so the conversion happens before the result is ever sent back —
  # which is why the `:DOWN` clause above is unreachable by ordinary fetch failure.
  defp safely(fetch) do
    fetch.()

    # BOUNDARY: one symbol's exception must not kill the whole feed.
  rescue
    exception -> {:error, exception_text(exception)}
  catch
    :exit, reason -> {:error, {:exit, opaque_reason(reason)}}
    # A `throw` escaped: it killed the task, and through its link the feed itself.
    :throw, value -> {:error, {:throw, opaque_reason(value)}}
  end

  # **A thrown value or exit reason travels only as far as its shape is safe.** Both are
  # whatever the failing code held: an exit from `GenServer.call/3` carries the call's own
  # message, `{reason, {GenServer, :call, [server, request, timeout]}}`, and a fetch that
  # calls with its credentials put them there. The reason became `last_error` and reached
  # `status/1`, the "delivered NOTHING" warning and a notice, the same channels
  # `exception_text/1` closes for raises. An atom, a number or a tuple of those (`:boom`,
  # `{:shutdown, :killed}`) says what happened and holds nothing; text is bounded; anything
  # else keeps its leading atom, if it has one, and withholds the rest.
  defp opaque_reason(reason) when is_atom(reason) or is_number(reason), do: reason
  defp opaque_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 2_048)

  defp opaque_reason(reason) when is_tuple(reason) do
    elements = Tuple.to_list(reason)

    cond do
      Enum.all?(elements, &(is_atom(&1) or is_number(&1))) -> reason
      is_atom(hd(elements)) -> {hd(elements), :withheld}
      true -> :withheld
    end
  end

  defp opaque_reason(_reason), do: :withheld

  # **Only a hand-written message travels; any other exception travels as its module.**
  # `Exception.message/1` of a `KeyError`, `FunctionClauseError`, `MatchError` or
  # `Protocol.UndefinedError` inspects the term the failing code held, and a fetch holds its
  # credentials: `Map.fetch!(credentials, :api_key)` on a plain-map credential printed the whole
  # map, secret included. The text became `last_error` (returned by `status/1`), the "delivered
  # NOTHING" warning and a notice's `details.last_error`, all of which reach logs and public
  # issues. The callback path in `guarded/3` already withholds the message for the same reason.
  defp exception_text(%RuntimeError{message: message}) when is_binary(message),
    do: String.slice(message, 0, 2_048)

  defp exception_text(exception),
    do: "#{inspect(exception.__struct__)} raised (message withheld: it can quote arguments)"

  defp fresh_symbols(state) do
    now = System.monotonic_time(:millisecond)
    window = state.interval_ms * @coverage_grace
    for {symbol, at} <- state.last_ok, now - at <= window, do: symbol
  end

  # Recovery: this feed was latched `:dead` (see `notice_state` in `init/1`) and just
  # published something. `on_notice` fires the recovery half of the pair here, once, on
  # the transition back out — a consumer that learned a feed died and never learned it
  # recovered is only half-served.
  #
  # Called only on an actual delivery (a non-empty publish): `apply_result/3`
  # routes a `{:ok, []}` bulk response through `record_failure/3` instead, precisely so
  # this function's `:dead` clause — and the recovery notice it fires — only ever fires
  # when something was truly delivered. There is no `record_success(state, false)`
  # clause; every caller already knows it delivered before reaching here.
  # A polling route has a LINK too — see `Core.Telemetry`'s "Why the category is `:link` and
  # not `:ws`". What carries the route is package-internal, so a venue that polls reports
  # `[:dp_exchange, :link, …]` exactly as a venue that holds a socket does, and a consumer's
  # dashboard does not have to know which is which.
  #
  # Mapped onto the latch that already exists rather than a new one: `notice_state` fires
  # `on_notice` exactly once per crossing, so the telemetry inherits that and cannot storm
  # on a long outage. `:link, :down` is this feed crossing into delivering-nothing — the
  # closest true statement a poller can make about a route it does not hold open — and
  # `:link, :up` is the recovery.
  defp record_success(%{notice_state: :dead} = state) do
    notice =
      Notice.new(:coverage_change, state.provider,
        severity: :info,
        message:
          "#{state.label} has resumed delivering after #{state.failures_since_ok} " <>
            "consecutive failures",
        details: %{label: state.label, consecutive_failures: state.failures_since_ok}
      )

    guarded(state, :on_notice, fn -> state.on_notice.(notice) end)
    Telemetry.link_up(state.provider)
    %{state | failures_since_ok: 0, last_error: nil, notice_state: :ok, link_up_sent: true}
  end

  # **The first delivery is the route being established, and it says so.** `[:dp_exchange,
  # :link, :up]` was emitted only on recovery from delivering-nothing, so a feed that started
  # and worked never emitted one: a dashboard counting ups against downs, or keeping the last
  # link event per provider, saw a healthy venue with no `:up` at all. Emitted once, on the
  # first success, and never again until a `:down` has been followed by its recovery.
  defp record_success(%{link_up_sent: false} = state) do
    Telemetry.link_up(state.provider)
    %{state | failures_since_ok: 0, last_error: nil, link_up_sent: true}
  end

  defp record_success(state), do: %{state | failures_since_ok: 0, last_error: nil}

  # One failure is noise; a whole cycle of them with nothing succeeding means
  # the feed is delivering nothing, which reads downstream as a quiet venue.
  defp record_failure(state, what, reason) do
    failures = state.failures_since_ok + 1
    # Bounded: `reason` is whatever the fetch answered, a decoded venue body included, and the
    # warning below repeats every sweep for as long as an outage lasts.
    # A function, so the `inspect/2` of a decoded venue body is built only when the debug level
    # is enabled: a failing feed does this on every tick and the node runs at info.
    Logger.debug(fn -> "[#{state.label}] #{what}: #{bounded(reason)}" end)

    state =
      if delivering_nothing?(state, failures) do
        Logger.warning(
          "[#{state.label}] has delivered NOTHING in #{failures} consecutive attempts — " <>
            "this venue is indistinguishable from quiet while it lasts. Last error: " <>
            bounded(reason)
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
      Notice.new(:coverage_change, state.provider,
        severity: :warning,
        message: "#{state.label} has delivered nothing in #{failures} consecutive attempts",
        details: %{
          label: state.label,
          consecutive_failures: failures,
          last_error: notice_reason(reason)
        }
      )

    guarded(state, :on_notice, fn -> state.on_notice.(notice) end)
    # Bounded: the reason is a venue error body or a decoded payload, and telemetry metadata
    # is copied to every attached handler and exporter.
    Telemetry.link_down(state.provider, bounded(reason))
    %{state | notice_state: :dead}
  end

  defp bounded(reason), do: inspect(reason, limit: 20, printable_limit: 512)

  # **What a fetch's failure reason becomes inside a notice's `details`.** `Notice.new/3`
  # refuses a credential-shaped key at ANY depth (a credential nested in a payload reaches a
  # public issue as surely as a top-level one), and a fetch's `{:error, reason}` is whatever
  # the venue or the caller's decoder produced: a `{:bad_fetch_result, answer}` or a decoded
  # error body keyed `"signature"` or `"token"` is an ordinary 401 shape. Passed through
  # raw, that raised `ArgumentError` out of `record_failure/3` inside this GenServer, which
  # restarted it from its static start opts and lost every `update_symbols/2` scope, on the
  # exact path that exists to report an outage. A scalar reason (an atom, a string, a number)
  # has no keys and travels as it was; anything structured is carried as bounded text, the
  # same shape `Telemetry.link_down/2` already sends for it.
  defp notice_reason(reason) when is_atom(reason) or is_number(reason), do: reason
  # A binary is bounded too: `HttpClient`'s own error text is already an excerpt, but a
  # caller's fetch may answer any string, and a notice reaches every handler and exporter.
  defp notice_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 2_048)

  defp notice_reason(reason), do: bounded(reason)

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
  # One per delivered payload, which is what makes this comparable with a streaming venue's
  # per-frame event. `link_event/2`, not `/3`: a poll has no frame, so there is no point at
  # which a byte count means what it does on a socket, and `:bytes` is ABSENT rather than a
  # confident zero. A consumer summing bytes across a mixed fleet then gets the throughput
  # of the streaming venues, correctly, instead of a total depressed by every polling venue.
  defp report_delivery(state, event) do
    Telemetry.link_event(state.provider, delivery_type(event))
    :ok
  end

  # The struct names its own kind, in the same spirit as every `coverage_by_kind/1` in the
  # family: never a channel name, never a subscription intent, only what actually arrived.
  # `Module.split/1` raises for a module atom not prefixed `Elixir.` (an Erlang-style struct
  # module such as `:foo`), and this runs inside the feed process on every delivery.
  defp delivery_type(%module{}) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest |> String.split(".") |> List.last()
      other -> other
    end
  end

  defp delivery_type(_other), do: "unknown"

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

  defp start_polling(%{fetch_all: nil} = state) do
    scheduled = schedule_each(state.symbols, state.interval_ms, state.start_delay_ms)
    %{state | scheduled: MapSet.union(state.scheduled, scheduled)}
  end

  defp start_polling(state) do
    Process.send_after(self(), :poll_all, state.start_delay_ms)
    state
  end

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

  # Takes the symbol set and returns it, rather than taking and returning `state`. Threading
  # the whole state through here is the obvious shape and Dialyzer rejects it: `state` now
  # carries `:scheduled`, a `MapSet`, and passing a map with an opaque subterm as an argument
  # trips `call_without_opaque`. It is the same PLT trap this module's sibling checks already
  # record for `MapSet.member?/2` — see `Core.Notice`'s `@credential_keys` comment. Callers
  # union the result into `:scheduled` themselves.
  defp schedule_each(symbols, interval_ms, start_delay_ms \\ 0) do
    count = max(MapSet.size(symbols), 1)
    spread = min(interval_ms, @first_sweep_ms)
    step = max(div(spread, count), 1)

    symbols
    |> Enum.with_index()
    |> Enum.each(fn {symbol, index} ->
      Process.send_after(self(), {:poll, symbol}, start_delay_ms + index * step)
    end)

    symbols
  end
end
