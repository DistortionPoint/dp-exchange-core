defmodule DpExchange.Core.PollingFeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Notice, PollingFeed}

  # This module warns loudly and by design when a feed delivers nothing — that is the
  # behaviour under test, not noise to silence. Captured so a passing run stays quiet.
  @moduletag :capture_log

  # Real GenServers, real timers, real functions. Nothing here is a mock: the fetch
  # is an ordinary anonymous function, and the sink sends to the test process, which
  # is how a venue package would wire it to anything else.

  # `start_delay_ms: 0` so a test does not wait out the boot delay. The delay itself
  # is tested separately, because it exists for a reason worth keeping.
  defp start_feed(opts) do
    defaults = [sink: sink_to_self(), start_delay_ms: 0, interval_ms: 50]
    pid = start_supervised!({PollingFeed, Keyword.merge(defaults, opts)})
    pid
  end

  defp sink_to_self do
    test = self()
    fn event -> send(test, {:published, event}) end
  end

  defp event(symbol), do: %{symbol: symbol, price: Decimal.new(1)}

  describe "a feed with no fetcher refuses to start" do
    test "neither :fetch nor :fetch_all stops with :no_fetcher" do
      # A feed that would run forever delivering nothing is indistinguishable from
      # a quiet venue, which is the most expensive failure shape here.
      Process.flag(:trap_exit, true)
      assert {:error, :no_fetcher} = PollingFeed.start_link(sink: sink_to_self())
    end

    test "a missing sink is a caller error, not a silently discarded feed" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :sink}, _stack}} = PollingFeed.start_link(fetch: & &1)
    end
  end

  describe "bulk mode (:fetch_all)" do
    test "publishes every event the venue returned" do
      start_feed(
        fetch_all: fn symbols -> {:ok, Enum.map(symbols, &event/1)} end,
        symbols: ~w(BTC-USD ETH-USD)
      )

      assert_receive {:published, %{symbol: s1}}, 500
      assert_receive {:published, %{symbol: s2}}, 500
      assert Enum.sort([s1, s2]) == ~w(BTC-USD ETH-USD)
    end

    test "coverage records what came BACK, not what was asked for" do
      # A symbol missing from the response is one the venue did not answer for.
      # Marking it covered would be the feed asserting a delivery that never
      # happened — which is the whole reason coverage is observed, not intended.
      pid =
        start_feed(
          fetch_all: fn _symbols -> {:ok, [event("BTC-USD")]} end,
          symbols: ~w(BTC-USD ETH-USD)
        )

      assert_receive {:published, _event}, 500

      coverage = PollingFeed.coverage(pid)
      assert coverage["BTC-USD"] == :internal_poll
      refute Map.has_key?(coverage, "ETH-USD")
    end

    test "a refused symbol is reported through on_refusal instead of crashing the feed" do
      # Before this fix: `{:refused, _}` matched neither `{:ok, events}` nor
      # `{:error, reason}` in `fetch_all_and_publish/1`'s case statement, so it raised
      # `CaseClauseError` inside `handle_info` and took the whole feed down — exactly the
      # gap `dp_exchange_robinhood`'s Feed moduledoc documented as the reason it stayed on
      # per-symbol `:fetch` rather than adopt this venue's own repeatable-query bulk mode.
      test = self()

      pid =
        start_feed(
          fetch_all: fn _symbols -> {:refused, [{"DOGE-USD", "not listed"}]} end,
          symbols: ~w(DOGE-USD),
          on_refusal: fn symbol, reason -> send(test, {:refused, symbol, reason}) end
        )

      assert_receive {:refused, "DOGE-USD", "not listed"}, 500
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "a batch refusing every symbol still reports and does not crash" do
      pid =
        start_feed(
          fetch_all: fn _symbols -> {:refused, [{"A-USD", :nope}, {"B-USD", :nope}]} end,
          symbols: ~w(A-USD B-USD)
        )

      Process.sleep(50)
      assert Process.alive?(pid)
      assert PollingFeed.coverage(pid) == %{}
    end

    test "a successful call with zero events counts toward delivering nothing" do
      # `{:ok, []}` succeeds at the transport layer but delivers nothing — a bad
      # credential filtered to an empty result set server-side is indistinguishable, from
      # this module's side, from a fetch that failed outright. Before this fix, an empty
      # bulk response went through `record_success(state, false)`, a silent no-op that
      # never reached `delivering_nothing?` — so a bulk venue stuck returning `{:ok, []}`
      # every cycle would never trip the escalation this module's moduledoc promises.
      pid = start_feed(fetch_all: fn _symbols -> {:ok, []} end, symbols: ~w(BTC-USD))

      Process.sleep(120)
      status = PollingFeed.status(pid)

      refute status.delivering
      assert status.failures_since_ok > 0
      assert status.last_error == :empty_response
    end
  end

  describe "per-symbol mode (:fetch)" do
    test "publishes each symbol independently" do
      start_feed(fetch: fn symbol -> {:ok, event(symbol)} end, symbols: ~w(BTC-USD ETH-USD))

      assert_receive {:published, %{symbol: _}}, 500
      assert_receive {:published, %{symbol: _}}, 500
    end

    test "a refusal is reported once, through the injected callback" do
      test = self()

      start_feed(
        fetch: fn symbol -> {:refused, "not listed: #{symbol}"} end,
        symbols: ~w(DOGE-USD),
        on_refusal: fn symbol, reason -> send(test, {:refused, symbol, reason}) end
      )

      assert_receive {:refused, "DOGE-USD", "not listed: DOGE-USD"}, 500
    end

    test "a refusal defaults to a no-op rather than crashing the feed" do
      # A caller that does not care about refusals gets a working feed, not a crash.
      pid = start_feed(fetch: fn _symbol -> {:refused, :nope} end, symbols: ~w(DOGE-USD))

      Process.sleep(120)
      assert Process.alive?(pid)
    end
  end

  describe "a fetch that fails does not stop the feed" do
    test "the symbol is retried and stays uncovered until one succeeds" do
      test = self()
      counter = :counters.new(1, [])

      pid =
        start_feed(
          fetch: fn symbol ->
            case :counters.get(counter, 1) do
              0 ->
                :counters.add(counter, 1, 1)
                send(test, :first_fetch_failed)
                {:error, :timeout}

              _succeeded ->
                {:ok, event(symbol)}
            end
          end,
          symbols: ~w(BTC-USD)
        )

      # A failed fetch covers nothing — checked the instant the failure happened rather
      # than at a wall-clock moment, which races the very retry this test waits for and
      # failed one run in six that way.
      assert_receive :first_fetch_failed, 500
      assert PollingFeed.coverage(pid) == %{}

      # It is retried rather than dropped.
      assert_receive {:published, %{symbol: "BTC-USD"}}, 500
      assert PollingFeed.coverage(pid)["BTC-USD"] == :internal_poll
    end

    test "a raising fetch is contained" do
      pid = start_feed(fetch: fn _symbol -> raise "venue exploded" end, symbols: ~w(BTC-USD))

      Process.sleep(120)
      assert Process.alive?(pid)
      assert PollingFeed.coverage(pid) == %{}
    end
  end

  describe "status/1 makes 'delivering nothing' visible" do
    test "a feed that has never succeeded reports it" do
      pid = start_feed(fetch: fn _symbol -> {:error, :down} end, symbols: ~w(BTC-USD))

      Process.sleep(120)
      status = PollingFeed.status(pid)

      refute status.delivering
      assert status.symbols == 1
      assert status.covered == 0
      assert status.failures_since_ok > 0
      assert status.last_error != nil
    end

    test "a delivering feed reports it" do
      pid = start_feed(fetch: fn symbol -> {:ok, event(symbol)} end, symbols: ~w(BTC-USD))

      assert_receive {:published, _event}, 500
      status = PollingFeed.status(pid)

      assert status.delivering
      assert status.covered == 1
      assert status.failures_since_ok == 0
    end
  end

  describe "update_symbols/2" do
    test "adds symbols and drops coverage for removed ones" do
      pid = start_feed(fetch: fn symbol -> {:ok, event(symbol)} end, symbols: ~w(BTC-USD))
      assert_receive {:published, %{symbol: "BTC-USD"}}, 500

      PollingFeed.update_symbols(pid, ~w(ETH-USD))
      assert_receive {:published, %{symbol: "ETH-USD"}}, 500

      # BTC-USD left the scope, so its coverage goes with it rather than lingering
      # as a stale claim of delivery.
      coverage = PollingFeed.coverage(pid)
      refute Map.has_key?(coverage, "BTC-USD")
    end

    test "an existing symbol is not rescheduled a second time" do
      # Rescheduling would stack a second timer on each symbol, doubling this
      # venue's request rate every time the scope is touched.
      counter = :counters.new(1, [])

      pid =
        start_feed(
          fetch: fn symbol -> :counters.add(counter, 1, 1) && {:ok, event(symbol)} end,
          symbols: ~w(BTC-USD),
          interval_ms: 10_000
        )

      assert_receive {:published, _event}, 500
      PollingFeed.update_symbols(pid, ~w(BTC-USD))
      Process.sleep(100)

      assert :counters.get(counter, 1) == 1
      assert Process.alive?(pid)
    end
  end

  describe "the boot delay" do
    test "nothing is fetched during the start delay" do
      # The delay exists because a feed starts as soon as its supervisor does,
      # which at boot is before the rest of a consumer's tree is up. The first
      # fetch went out into a half-started system, raised, and the supervisor
      # restarted it straight back into the same raise.
      start_feed(
        fetch: fn symbol -> {:ok, event(symbol)} end,
        symbols: ~w(BTC-USD),
        start_delay_ms: 300
      )

      refute_receive {:published, _event}, 150
      assert_receive {:published, _event}, 500
    end

    test "an explicit nil falls back to the default instead of crashing the feed" do
      # A venue's own Feed wrapper builds this list from `Keyword.get(opts, :start_delay_ms)`
      # with no default of its own, forwarding a PRESENT key with a nil value whenever its
      # caller never set one. `Keyword.get/3` only substitutes a default for an ABSENT key,
      # so this is not the same case as simply omitting the option — it is the case that
      # crashed in production.
      pid =
        start_supervised!(
          {PollingFeed,
           sink: sink_to_self(),
           interval_ms: 50,
           start_delay_ms: nil,
           fetch: fn symbol -> {:ok, event(symbol)} end,
           symbols: ~w(BTC-USD)}
        )

      assert Process.alive?(pid)
      assert_receive {:published, _event}, 9_000
    end
  end

  describe "the nil-vs-absent Keyword.get trap, fixed as a class (C1)" do
    test "an explicit nil interval_ms falls back to the default instead of crashing the feed" do
      # Before this fix: `Keyword.get(opts, :interval_ms, @default_interval_ms)` returns
      # `nil` (not the default) when `interval_ms` is PRESENT and `nil` — the shape a
      # venue's forwarded `opts` produce when nothing upstream ever set it. That `nil`
      # reached `Process.send_after(self(), _, state.interval_ms)` on the very first
      # reschedule and crashed the feed into a restart loop straight back into the same
      # crash.
      pid =
        start_supervised!(
          {PollingFeed,
           sink: sink_to_self(),
           start_delay_ms: 0,
           interval_ms: nil,
           fetch: fn symbol -> {:ok, event(symbol)} end,
           symbols: ~w(BTC-USD)}
        )

      assert_receive {:published, _event}, 500
      # The reschedule inside handle_info is where the crash happened — give it a beat
      # past the first publish and confirm the feed is still standing.
      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "an explicit nil on_refusal falls back to a no-op instead of crashing the feed" do
      # Before this fix: `state.on_refusal.(symbol, reason)` with `on_refusal: nil` raises
      # `BadFunctionError`, because `Keyword.get/3`'s default never applied to a
      # present-and-nil key.
      pid =
        start_feed(
          fetch: fn _symbol -> {:refused, :nope} end,
          symbols: ~w(DOGE-USD),
          on_refusal: nil
        )

      Process.sleep(120)
      assert Process.alive?(pid)
    end

    test "an explicit nil symbols falls back to an empty set instead of crashing init" do
      # Before this fix: `MapSet.new(Keyword.get(opts, :symbols, []))` with `symbols: nil`
      # raises `Protocol.UndefinedError` inside `MapSet.new/1`, failing `init/1` outright.
      pid =
        start_supervised!(
          {PollingFeed,
           sink: sink_to_self(),
           start_delay_ms: 0,
           fetch: fn symbol -> {:ok, event(symbol)} end,
           symbols: nil}
        )

      assert Process.alive?(pid)
      assert PollingFeed.status(pid).symbols == 0
    end
  end

  describe "a hung fetch does not wedge the whole feed, silently (C2)" do
    test "status/1 stays answerable while a fetch hangs, bounded by :fetch_timeout_ms" do
      # Verified against the unfixed code: a fetcher doing `Process.sleep(:infinity)` left
      # `PollingFeed.status/1` unanswerable — `handle_info` ran the fetch inline with no
      # timeout boundary, wedging this GenServer's mailbox, every other symbol's tick, and
      # the exact health-check calls this module's own moduledoc says exist to catch a
      # silently-broken feed.
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol ->
            send(test, :fetch_started)
            Process.sleep(:infinity)
          end,
          symbols: ~w(BTC-USD),
          fetch_timeout_ms: 100,
          interval_ms: 500
        )

      # Deterministic ordering: wait for the hang to actually be in flight inside
      # `handle_info` before calling `status/1`, so this test cannot race the timer that
      # schedules the first `:poll` message.
      assert_receive :fetch_started, 500

      # GenServer.call's default 5s timeout is the proof: before this fix this call did
      # not return at all, because the hang was unbounded, not merely slow.
      status = PollingFeed.status(pid)

      refute status.delivering
      assert status.failures_since_ok >= 1
      assert status.last_error == :fetch_timeout
    end

    test "the hung symbol is retried like any other failure, not dropped" do
      test = self()

      pid =
        start_feed(
          fetch: fn symbol ->
            send(test, {:attempt, symbol})
            Process.sleep(:infinity)
          end,
          symbols: ~w(BTC-USD),
          fetch_timeout_ms: 50,
          interval_ms: 50
        )

      assert_receive {:attempt, "BTC-USD"}, 500
      assert_receive {:attempt, "BTC-USD"}, 500
      assert Process.alive?(pid)
    end

    test "a fetch that returns just under the timeout still publishes normally" do
      # The boundary must not punish an ordinary slow-but-completing fetch.
      start_feed(
        fetch: fn symbol ->
          Process.sleep(20)
          {:ok, event(symbol)}
        end,
        symbols: ~w(BTC-USD),
        fetch_timeout_ms: 500
      )

      assert_receive {:published, %{symbol: "BTC-USD"}}, 500
    end
  end

  describe "on_notice: the delivering-nothing transition (issue #21)" do
    test "fires once on the crossing into delivering nothing, not once per failed tick or sweep after" do
      # Three symbols, so `sweep` (the number of failures a full cycle takes) is 3 —
      # large enough to prove this is NOT firing on every individual fetch failure.
      test = self()

      start_feed(
        fetch: fn symbol ->
          send(test, {:attempt, symbol})
          {:error, :down}
        end,
        symbols: ~w(BTC-USD ETH-USD SOL-USD),
        on_notice: fn notice -> send(test, {:notice, notice}) end
      )

      # The first full sweep: one failed attempt per symbol, in whatever order the
      # staggered start times deliver them.
      for _attempt <- 1..3, do: assert_receive({:attempt, _symbol}, 500)

      assert_receive {:notice, notice}, 500

      assert %Notice{kind: :coverage_change, severity: :warning} = notice
      assert notice.provider == "polling-feed"
      assert notice.details.label == "polling-feed"
      assert notice.details.consecutive_failures == 3
      assert notice.details.last_error == :down

      # The outage continues for two more full sweeps' worth of attempts. No second
      # notice — this is a transition, fired once, not a per-tick or per-sweep signal.
      for _attempt <- 1..6, do: assert_receive({:attempt, _symbol}, 500)
      refute_receive {:notice, _}, 200
    end

    test "emits a recovery notice, distinct from the dead one, when the feed resumes delivering" do
      test = self()
      counter = :counters.new(1, [])

      start_feed(
        fetch: fn symbol ->
          case :counters.get(counter, 1) do
            0 ->
              :counters.add(counter, 1, 1)
              {:error, :down}

            _succeeded ->
              {:ok, event(symbol)}
          end
        end,
        symbols: ~w(BTC-USD),
        on_notice: fn notice -> send(test, {:notice, notice}) end
      )

      assert_receive {:notice, dead_notice}, 500
      assert %Notice{kind: :coverage_change, severity: :warning} = dead_notice

      assert_receive {:published, %{symbol: "BTC-USD"}}, 500

      assert_receive {:notice, recovered_notice}, 500
      assert %Notice{kind: :coverage_change, severity: :info} = recovered_notice
      assert recovered_notice.details.label == "polling-feed"
      assert recovered_notice.details.consecutive_failures == 1

      # Steady-state delivery afterward raises no further notice.
      assert_receive {:published, %{symbol: "BTC-USD"}}, 500
      refute_receive {:notice, _}, 200
    end

    test "an absent :on_notice does not crash the feed while it is delivering nothing" do
      test = self()

      pid =
        start_feed(
          fetch: fn symbol ->
            send(test, {:attempt, symbol})
            {:error, :down}
          end,
          symbols: ~w(BTC-USD)
        )

      assert_receive {:attempt, "BTC-USD"}, 500
      assert_receive {:attempt, "BTC-USD"}, 500
      assert Process.alive?(pid)
    end

    test "an explicit nil on_notice falls back to the no-op instead of crashing the feed (C1)" do
      # Same nil-vs-absent trap `on_refusal` and every other injected option in this
      # module already guard against: a venue's `Feed` wrapper forwards its own `opts`
      # unchanged, so `on_notice: nil` is what arrives when nothing upstream set it.
      test = self()

      pid =
        start_feed(
          fetch: fn symbol ->
            send(test, {:attempt, symbol})
            {:error, :down}
          end,
          symbols: ~w(BTC-USD),
          on_notice: nil
        )

      assert_receive {:attempt, "BTC-USD"}, 500
      assert_receive {:attempt, "BTC-USD"}, 500
      assert Process.alive?(pid)
    end
  end

  describe "unknown messages" do
    test "an unknown call is answered rather than crashing the caller" do
      pid = start_feed(fetch: fn symbol -> {:ok, event(symbol)} end, symbols: ~w(BTC-USD))
      assert {:error, :unknown_call} = GenServer.call(pid, :nonsense)
    end

    test "an unknown cast and info are ignored" do
      pid = start_feed(fetch: fn symbol -> {:ok, event(symbol)} end, symbols: ~w(BTC-USD))

      GenServer.cast(pid, :nonsense)
      send(pid, :nonsense)
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end
end
