defmodule DpExchange.Core.PollingFeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.PollingFeed

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
