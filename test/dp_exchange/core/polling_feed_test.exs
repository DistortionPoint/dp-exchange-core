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

      # `status/1` is a `GenServer.call` — it cannot reply until every message already
      # queued ahead of it (here, nothing further after the refusal above) has been
      # handled, so a reply is itself the proof the feed is still standing. Waiting a
      # guessed duration and then checking `Process.alive?/1` proved the same thing only
      # as long as the guess was long enough; this proves it regardless of timing.
      refute PollingFeed.status(pid).delivering
    end

    test "a batch refusing every symbol still reports and does not crash" do
      test = self()

      pid =
        start_feed(
          fetch_all: fn _symbols -> {:refused, [{"A-USD", :nope}, {"B-USD", :nope}]} end,
          symbols: ~w(A-USD B-USD),
          on_refusal: fn symbol, reason -> send(test, {:refused, symbol, reason}) end
        )

      assert_receive {:refused, "A-USD", :nope}, 500
      assert_receive {:refused, "B-USD", :nope}, 500
      # A `GenServer.call` reply is proof of no crash by construction — it cannot answer
      # from a dead process.
      assert PollingFeed.coverage(pid) == %{}
    end

    test "a successful call with zero events counts toward delivering nothing" do
      # `{:ok, []}` succeeds at the transport layer but delivers nothing — a bad
      # credential filtered to an empty result set server-side is indistinguishable, from
      # this module's side, from a fetch that failed outright. Before this fix, an empty
      # bulk response went through `record_success(state, false)`, a silent no-op that
      # never reached `delivering_nothing?` — so a bulk venue stuck returning `{:ok, []}`
      # every cycle would never trip the escalation this module's moduledoc promises.
      test = self()

      pid =
        start_feed(
          fetch_all: fn _symbols -> {:ok, []} end,
          symbols: ~w(BTC-USD),
          # Real observable, not a guessed duration: with one symbol, a bulk venue's
          # sweep is one call, so `record_failure/3` crosses into "delivering nothing"
          # on the very first tick and fires `on_notice` right then — see
          # `delivering_nothing?/2`. Waiting for that message is waiting for the exact
          # state transition the assertions below check, not for a fixed amount of time
          # to have probably been enough.
          on_notice: fn notice -> send(test, {:notice, notice}) end
        )

      assert_receive {:notice, _notice}, 500
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
      # `on_refusal` is deliberately left unset — the default no-op is what is under
      # test — so `on_notice` (unrelated to `on_refusal`, and fired on the very same
      # first-tick transition per `delivering_nothing?/2`) is the synchronisation
      # signal instead, rather than a callback that would replace the default path
      # this test exists to exercise.
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol -> {:refused, :nope} end,
          symbols: ~w(DOGE-USD),
          on_notice: fn notice -> send(test, {:notice, notice}) end
        )

      assert_receive {:notice, _notice}, 500
      assert PollingFeed.status(pid).failures_since_ok >= 1
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
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol -> raise "venue exploded" end,
          symbols: ~w(BTC-USD),
          on_notice: fn notice -> send(test, {:notice, notice}) end
        )

      assert_receive {:notice, _notice}, 500
      assert PollingFeed.coverage(pid) == %{}
    end
  end

  describe "status/1 makes 'delivering nothing' visible" do
    test "a feed that has never succeeded reports it" do
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol -> {:error, :down} end,
          symbols: ~w(BTC-USD),
          on_notice: fn notice -> send(test, {:notice, notice}) end
        )

      assert_receive {:notice, _notice}, 500
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

      # `update_symbols/2` is a cast; `status/1` right after it is a call, and a
      # GenServer answers a call only once every message queued ahead of it —
      # including this cast — has been handled. That makes the reply itself proof the
      # cast was processed (with no reschedule: `interval_ms: 10_000` means nothing
      # would have naturally re-ticked in this test's runtime regardless, so this is a
      # deterministic replacement, not a shorter guess at the same wait).
      status = PollingFeed.status(pid)

      assert status.symbols == 1
      assert :counters.get(counter, 1) == 1
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

      # Asserted on the resolved state rather than by waiting for a fetch to arrive.
      # "Falls back to the default" IS a statement about the resolved value, so checking it
      # directly says exactly that; waiting 8s for the delay to elapse only says it eventually
      # fetched, and infers the rest. It also cost 8 of this suite's 12.4 seconds — a single
      # test, and the kind of wall-clock wait that produced three CI-only flakes in this
      # family this week. `nothing is fetched during the start delay` above still proves the
      # delay is honoured behaviourally, on a 300ms delay it sets itself.
      assert Process.alive?(pid)
      assert :sys.get_state(pid).start_delay_ms == 8_000
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
      # The reschedule inside `handle_info` is where the crash happened, immediately
      # after the publish — a synchronous call right after the publish forces that
      # same `handle_info` to have fully returned (a GenServer cannot answer a call
      # until the message ahead of it is done being handled), which is what "still
      # standing" actually needs to mean here rather than "alive after a guessed gap".
      assert PollingFeed.status(pid).delivering
    end

    test "an explicit nil on_refusal falls back to a no-op instead of crashing the feed" do
      # Before this fix: `state.on_refusal.(symbol, reason)` with `on_refusal: nil` raises
      # `BadFunctionError`, because `Keyword.get/3`'s default never applied to a
      # present-and-nil key. `on_refusal` is explicitly `nil` here — the fallback under
      # test — so, as in the analogous default-path test above, `on_notice` (unrelated,
      # and fired on this same first-tick transition) is the synchronisation signal.
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol -> {:refused, :nope} end,
          symbols: ~w(DOGE-USD),
          on_refusal: nil,
          on_notice: fn notice -> send(test, {:notice, notice}) end
        )

      assert_receive {:notice, _notice}, 500
      assert PollingFeed.status(pid).failures_since_ok >= 1
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
    test "status/1 answers DURING a hang that outlasts GenServer.call's own timeout" do
      # Two fixes are layered here, and this test has been rewritten once — for the second
      # one, which it was actively hiding.
      #
      # Originally: a fetcher doing `Process.sleep(:infinity)` left `status/1` unanswerable
      # forever, because `handle_info` ran the fetch inline with no boundary at all. Fixed
      # by running every fetch inside a task bounded by `:fetch_timeout_ms`.
      #
      # That was not enough, and the SHAPE OF THIS TEST is why nobody noticed: it used a
      # 100 ms timeout, so `status/1` returned as soon as the fetch was abandoned and the
      # test happily read the recorded failure. The call was still BLOCKING for the whole
      # timeout. The real default floor is `@min_fetch_timeout_ms` — 30 seconds — against
      # `GenServer.call/2`'s 5-second default, so a health check landing during an ordinary
      # in-flight fetch was not unlucky, it was a guaranteed timeout. In
      # `dp_exchange_robinhood` that exit propagated out of the venue `Feed`'s own
      # `handle_call` and killed it: dp-exchange-core issue #28, where a read-only coverage
      # check took a live venue to zero pairs and left it there.
      #
      # The timeout below is therefore deliberately LONGER than `GenServer.call/2`'s
      # default. If this call ever blocks on the fetch again it cannot return, it exits,
      # and this test fails instead of quietly passing for the wrong reason.
      test = self()

      pid =
        start_feed(
          fetch: fn _symbol ->
            send(test, :fetch_started)
            Process.sleep(:infinity)
          end,
          symbols: ~w(BTC-USD),
          fetch_timeout_ms: 30_000,
          interval_ms: 500
        )

      # Deterministic ordering: wait for the hang to actually be in flight before calling
      # `status/1`, so this test cannot race the timer that schedules the first `:poll`.
      assert_receive :fetch_started, 500

      # Answered while the fetch is still hanging, and answered HONESTLY: nothing has been
      # delivered, and nothing has failed either, because the fetch has not finished. A
      # feed that reported a failure here would be inventing one.
      status = PollingFeed.status(pid)

      refute status.delivering
      assert status.failures_since_ok == 0
      assert status.last_error == nil

      # Still alive and still hanging — asking the question did not disturb the subject,
      # which is the whole point of #28.
      assert Process.alive?(pid)
    end

    test "coverage/1 answers during a hang too, and reports what actually arrived" do
      # `coverage/1` is the call the consumer's health check actually makes, and it is the
      # one that killed the feed in #28. One symbol delivers, a second hangs; coverage must
      # come back promptly and name only the symbol that really arrived.
      test = self()

      pid =
        start_feed(
          fetch: fn
            "BTC-USD" ->
              {:ok, event("BTC-USD")}

            "ETH-USD" ->
              send(test, :hang_started)
              Process.sleep(:infinity)
          end,
          symbols: ~w(BTC-USD ETH-USD),
          fetch_timeout_ms: 30_000,
          interval_ms: 500
        )

      assert_receive {:published, %{symbol: "BTC-USD"}}, 500
      assert_receive :hang_started, 500

      coverage = PollingFeed.coverage(pid)

      assert coverage["BTC-USD"] == :internal_poll
      refute Map.has_key?(coverage, "ETH-USD")
      assert Process.alive?(pid)
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

      # Sent by this same process, to the same mailbox, ahead of the call below —
      # Erlang's per-sender-per-receiver FIFO ordering means the GenServer must handle
      # both unknown messages before it can even dequeue this `status` call, so a
      # reply here already proves both were ignored without crashing.
      assert PollingFeed.status(pid).symbols == 1
    end
  end
end
