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
  """

  use GenServer

  require Logger

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
    state = %{
      fetch: Keyword.get(opts, :fetch),
      fetch_all: Keyword.get(opts, :fetch_all),
      sink: Keyword.fetch!(opts, :sink),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      label: Keyword.get(opts, :label, "polling-feed"),
      # Injected like the sink, so the feed never reaches outside its own inputs.
      # Defaults to a no-op: a caller that does not care about refusals gets a
      # working feed, not a crash.
      on_refusal: Keyword.get(opts, :on_refusal, fn _symbol, _reason -> :ok end),
      symbols: MapSet.new(Keyword.get(opts, :symbols, [])),
      # `|| @default_start_delay_ms`, not just a `Keyword.get/3` default: a caller that
      # forwards its own `opts` unchanged (as every venue's `Feed` does) hands this key
      # through with an explicit `nil` when its own caller never set it, and `Keyword.get/3`
      # only substitutes a default for an ABSENT key, not a present-and-nil one. Without the
      # `||`, that `nil` reaches `Process.send_after/3` downstream and crashes the feed.
      start_delay_ms:
        Keyword.get(opts, :start_delay_ms, @default_start_delay_ms) || @default_start_delay_ms,
      last_ok: %{},
      failures_since_ok: 0,
      last_error: nil
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
    case safely(fn -> state.fetch_all.(MapSet.to_list(symbols)) end) do
      {:ok, events} ->
        now = System.monotonic_time(:millisecond)

        # Coverage is recorded from what came BACK, not what was asked for. A
        # symbol missing from the response is one the venue did not answer for,
        # and marking it covered would be the feed asserting a delivery that
        # never happened.
        Enum.each(events, state.sink)

        seen = Map.new(events, fn event -> {event.symbol, now} end)
        record_success(%{state | last_ok: Map.merge(state.last_ok, seen)}, events != [])

      {:error, reason} ->
        record_failure(state, "bulk fetch", reason)
    end
  end

  defp fetch_one_and_publish(symbol, state) do
    case safely(fn -> state.fetch.(symbol) end) do
      {:ok, event} ->
        %{state | last_ok: Map.put(state.last_ok, symbol, System.monotonic_time(:millisecond))}
        |> tap(fn _state -> state.sink.(event) end)
        |> record_success(true)

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

  defp record_success(state, false), do: state

  defp record_success(state, true), do: %{state | failures_since_ok: 0, last_error: nil}

  # One failure is noise; a whole cycle of them with nothing succeeding means
  # the feed is delivering nothing, which reads downstream as a quiet venue.
  defp record_failure(state, what, reason) do
    failures = state.failures_since_ok + 1
    Logger.debug("[#{state.label}] #{what}: #{inspect(reason)}")

    if delivering_nothing?(state, failures) do
      Logger.warning(
        "[#{state.label}] has delivered NOTHING in #{failures} consecutive attempts — " <>
          "this venue is indistinguishable from quiet while it lasts. Last error: " <>
          inspect(reason)
      )
    end

    %{state | failures_since_ok: failures, last_error: reason}
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
