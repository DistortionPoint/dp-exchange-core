defmodule DpExchange.Core.FanoutTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Fanout, Notice}

  # A subscriber that never consumes on its own, so everything sent to it stays queued —
  # which is what a stalled consumer looks like from the sender's side, and the only way to
  # build a real backlog without guessing at timing. It answers `{:drain, from}` through a
  # selective receive, so a test can make it catch up on demand; see `drain/1`.
  defp stalled_subscriber do
    pid = spawn(fn -> stalled_loop() end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp stalled_loop do
    receive do
      {:drain, from} ->
        flush()
        send(from, :drained)
        stalled_loop()
    end
  end

  defp flush do
    receive do
      _anything -> flush()
    after
      0 -> :ok
    end
  end

  defp backlog(pid, n), do: Enum.each(1..n, fn _each -> send(pid, :filler) end)

  defp queue_len(pid) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)
    len
  end

  describe "the bound" do
    test "a subscriber under the bound is sent to" do
      subscriber = stalled_subscriber()

      assert {1, dropping, []} = Fanout.deliver([subscriber], :payload, MapSet.new())
      assert Enum.empty?(dropping)
      assert queue_len(subscriber) == 1
    end

    test "a subscriber at or past the bound is not sent to, and its queue stops growing" do
      subscriber = stalled_subscriber()
      backlog(subscriber, 10)

      assert {0, dropping, [{^subscriber, :dropping, 10}]} =
               Fanout.deliver([subscriber], :payload, MapSet.new(), max_queue_len: 10)

      assert MapSet.member?(dropping, subscriber)

      # The whole point: the mailbox did not grow. This is the failure the contract names —
      # "growing a mailbox silently until the node dies" — and the assertion that it does
      # not happen is the one worth having.
      assert queue_len(subscriber) == 10
    end

    test "the bound is inclusive: a queue exactly at it is already too long" do
      subscriber = stalled_subscriber()
      backlog(subscriber, 4)

      assert {0, _dropping, [{^subscriber, :dropping, 4}]} =
               Fanout.deliver([subscriber], :payload, MapSet.new(), max_queue_len: 4)
    end

    test "one slow subscriber does not stop delivery to a healthy one" do
      # The property that makes dropping acceptable at all. A venue whose fan-out stalled or
      # dropped for everyone because one consumer fell behind would have turned one
      # misbehaving consumer into an outage for every other.
      slow = stalled_subscriber()
      healthy = stalled_subscriber()
      backlog(slow, 10)

      assert {1, dropping, [{^slow, :dropping, 10}]} =
               Fanout.deliver([slow, healthy], :payload, MapSet.new(), max_queue_len: 10)

      assert MapSet.member?(dropping, slow)
      refute MapSet.member?(dropping, healthy)
      assert queue_len(healthy) == 1
      assert queue_len(slow) == 10
    end

    test "the default bound is stated, not implicit" do
      assert Fanout.default_max_queue_len() == 10_000
    end
  end

  describe "transitions are reported once, not per dropped message" do
    test "a subscriber already known to be dropping reports nothing further" do
      # A notice per dropped message would arrive at the rate of the stream the consumer
      # cannot keep up with, into the same fan-out that is already overloaded.
      subscriber = stalled_subscriber()
      backlog(subscriber, 10)
      opts = [max_queue_len: 10]

      {0, dropping, [_first]} = Fanout.deliver([subscriber], :a, MapSet.new(), opts)

      assert {0, ^dropping, []} = Fanout.deliver([subscriber], :b, dropping, opts)
      assert {0, ^dropping, []} = Fanout.deliver([subscriber], :c, dropping, opts)
    end

    test "catching up reports :resumed exactly once, and delivery restarts" do
      subscriber = stalled_subscriber()
      backlog(subscriber, 10)
      opts = [max_queue_len: 10]

      {0, dropping, _started} = Fanout.deliver([subscriber], :a, MapSet.new(), opts)

      # The consumer drains. `:sys`-free and deterministic: take the messages out of the
      # jump the backlog. See `stalled_subscriber/0`.
      drain(subscriber)

      assert {1, resumed_set, [{^subscriber, :resumed, 0}]} =
               Fanout.deliver([subscriber], :b, dropping, opts)

      assert Enum.empty?(resumed_set)
      assert {1, _still_empty, []} = Fanout.deliver([subscriber], :c, resumed_set, opts)
    end

    test "a subscriber that dies while dropping leaves the set without being pruned" do
      # The set is rebuilt from what was observed, never edited in place, so there is no
      # separate cleanup path that could be forgotten and leak pids for the life of a feed.
      subscriber = stalled_subscriber()
      backlog(subscriber, 10)
      opts = [max_queue_len: 10]

      {0, dropping, _started} = Fanout.deliver([subscriber], :a, MapSet.new(), opts)
      assert MapSet.member?(dropping, subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

      assert {0, after_death, []} = Fanout.deliver([subscriber], :b, dropping, opts)
      assert Enum.empty?(after_death)
    end
  end

  describe "resolve/1" do
    test "a live pid resolves to itself" do
      subscriber = stalled_subscriber()
      assert Fanout.resolve(subscriber) == subscriber
    end

    test "a dead pid resolves to nil, and is skipped rather than reported as behind" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      assert Fanout.resolve(pid) == nil
      assert {0, dropping, []} = Fanout.deliver([pid], :payload, MapSet.new())
      assert Enum.empty?(dropping)
    end

    test "a registered name resolves to whatever answers to it now" do
      subscriber = stalled_subscriber()
      name = :"fanout_test_#{System.unique_integer([:positive])}"
      Process.register(subscriber, name)

      assert Fanout.resolve(name) == subscriber
      assert {1, _dropping, []} = Fanout.deliver([name], :payload, MapSet.new())
      assert queue_len(subscriber) == 1
    end

    test "a name nothing answers to resolves to nil" do
      assert Fanout.resolve(:no_process_answers_to_this_name) == nil
    end
  end

  describe "max_queue_len!/2" do
    test "absent, it is the stated default" do
      assert Fanout.max_queue_len!([], :test_venue) == Fanout.default_max_queue_len()
    end

    test "a positive integer is taken as given" do
      assert Fanout.max_queue_len!([max_queue_len: 250], :test_venue) == 250
      assert Fanout.max_queue_len!([max_queue_len: 1], :test_venue) == 1
    end

    test "anything else fails loudly at init, naming the venue and the value" do
      # Silently falling back to the default would leave a consumer believing it configured
      # a bound it did not — a back-pressure setting that reads as applied and is not, which
      # is the exact class of defect this module exists inside.
      for bad <- ["10000", 0, -1, 10_000.0, nil, :default] do
        assert_raise ArgumentError, fn -> Fanout.max_queue_len!([max_queue_len: bad], :gemini) end
      end

      error =
        assert_raise ArgumentError, fn ->
          Fanout.max_queue_len!([max_queue_len: "10000"], :gemini)
        end

      assert error.message =~ ":gemini"
      assert error.message =~ ~s("10000")
    end
  end

  describe "watch/2 and forget/2 — the dead-subscriber leak" do
    test "a pid is monitored once, however many times it subscribes" do
      subscriber = stalled_subscriber()

      monitors = Fanout.watch(subscriber, %{})
      assert %{^subscriber => ref} = monitors
      assert is_reference(ref)

      # A consumer re-subscribing must not stack monitors: each one delivers its own
      # `:DOWN`, so N monitors on one pid means N-1 messages nothing will match.
      assert Fanout.watch(subscriber, monitors) == monitors
    end

    test "a registered name is deliberately NOT monitored" do
      # A name is not a process. `subscribe/2` accepts one precisely so a consumer can
      # restart under it, and a monitor fires when the CURRENT HOLDER dies — pruning on that
      # would silently unsubscribe a consumer whose supervisor is about to bring it straight
      # back. A name cannot leak anyway: the set holds one atom however many restarts happen.
      assert Fanout.watch(:some_registered_name, %{}) == %{}
    end

    test "a dead pid's monitor fires, and forget/2 cleans the map" do
      subscriber = stalled_subscriber()
      monitors = Fanout.watch(subscriber, %{})
      %{^subscriber => ref} = monitors

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

      assert Fanout.forget(subscriber, monitors) == %{}
    end

    test "forget/2 on an explicit unsubscribe demonitors, so no stray :DOWN arrives" do
      # The monitor is still LIVE here, unlike the `:DOWN` case. Without the demonitor the
      # feed would later receive a `:DOWN` for a subscriber it has already forgotten — and
      # `flush: true` covers the pid that dies in the same instant it unsubscribes.
      subscriber = stalled_subscriber()
      monitors = Fanout.watch(subscriber, %{})

      assert Fanout.forget(subscriber, monitors) == %{}

      Process.exit(subscriber, :kill)
      refute_receive {:DOWN, _ref, :process, ^subscriber, _reason}, 100
    end

    test "forget/2 on a pid that was never watched is a no-op, not a crash" do
      # A name subscriber reaches this path: it is in the subscriber set and never in
      # `monitors`, so unsubscribing one must not raise.
      assert Fanout.forget(self(), %{}) == %{}
    end

    test "pruning is what keeps the fan-out flat, and the cost of not doing it is real" do
      # Measured rather than asserted in the abstract: `deliver/4` walks the whole set and
      # calls `Process.alive?/1` per entry, per message, so an unpruned set makes every
      # message linearly more expensive. 0 dead is ~0.095 us and 1000 dead is ~22.8 us on
      # the machine this was written on — 240x. This test does not pin those numbers, which
      # are hardware; it pins the PROPERTY that a pruned set does strictly less work.
      live = stalled_subscriber()
      dead = for _each <- 1..40, do: dead_subscriber()

      unpruned = MapSet.new([live | dead])
      pruned = MapSet.new([live])

      assert timed(unpruned) > timed(pruned),
             "a set carrying dead subscribers must cost more to fan out than one without " <>
               "them — if this ever stops being true, the leak stopped mattering and this " <>
               "machinery can go"

      # And the pruning itself is correct: every dead pid is gone, the live one is not.
      remaining = Enum.filter(unpruned, &Fanout.resolve/1)
      assert remaining == [live]
    end

    defp timed(subscribers) do
      {us, _result} =
        :timer.tc(fn ->
          Enum.each(1..2_000, fn _each -> Fanout.deliver(subscribers, :x, MapSet.new()) end)
        end)

      us
    end

    defp dead_subscriber do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      pid
    end
  end

  describe "notice_for/3" do
    test "the dropping notice is a warning and carries the numbers a consumer needs" do
      pid = self()

      assert %Notice{kind: :degraded, severity: :warning, details: details, message: message} =
               Fanout.notice_for({pid, :dropping, 12_345}, :test_venue, 10_000)

      assert details.queue_len == 12_345
      assert details.bound == 10_000
      assert details.dropping == :newest
      assert details.subscriber == inspect(pid)
      assert message =~ "12345"
      assert message =~ "10000"
    end

    test "the resumed notice is info, and is what closes the bracket" do
      # "Data loss started" with no matching "it stopped" is an alarm a consumer cannot
      # size — it cannot tell a five-second stall from an ongoing outage.
      assert %Notice{kind: :degraded, severity: :info, details: details} =
               Fanout.notice_for({self(), :resumed, 3}, :test_venue, 10_000)

      assert details.queue_len == 3
      assert details.dropping == :none
    end

    test "the provider is the venue's own, never invented here" do
      assert %Notice{provider: :coinbase} =
               Fanout.notice_for({self(), :dropping, 1}, :coinbase, 1)
    end
  end

  # Makes the subscriber consume everything queued and say so.
  #
  # `{:drain, from}` is sent BEHIND a backlog of filler and is still matched immediately:
  # the subscriber's `receive` is selective, so it scans past messages that do not match
  # rather than taking them in order. That is what makes a real backlog drainable on demand
  # without killing the process — which would prove nothing, since a caught-up subscriber
  # and a dead one are exactly what this test needs to tell apart.
  defp drain(pid) do
    send(pid, {:drain, self()})
    assert_receive :drained, 1_000
  end
end
