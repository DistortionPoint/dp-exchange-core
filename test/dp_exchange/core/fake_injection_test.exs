defmodule DpExchange.Core.FakeInjectionTest do
  # Each ExUnit test runs in its own process, so — like Config itself — this needs no
  # per-test namespacing to stay isolated under async: true.
  use ExUnit.Case, async: true

  alias DpExchange.Core.FakeInjection

  describe "no override configured" do
    test "next_outcome/1 is :none" do
      assert FakeInjection.next_outcome(:webull) == :none
    end

    test "next_outcome/2 is :none" do
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == :none
    end

    test "credentials_bypassed?/1 is false" do
      refute FakeInjection.credentials_bypassed?(:webull)
    end
  end

  describe "queue_failures/2 — whole-call, deterministic order" do
    test "returns queued outcomes in order, then resumes normal behaviour" do
      FakeInjection.queue_failures(:webull, [{:error, :timeout}, {:refused, :rate_limited}])

      assert FakeInjection.next_outcome(:webull) == {:override, {:error, :timeout}}
      assert FakeInjection.next_outcome(:webull) == {:override, {:refused, :rate_limited}}
      assert FakeInjection.next_outcome(:webull) == :none
    end

    test "a symbol-taking call with no symbol-specific queue falls through to the whole-call queue" do
      FakeInjection.queue_failures(:webull, [{:error, :timeout}])

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :timeout}}
    end
  end

  describe "queue_failures/3 — per symbol, never affects another symbol" do
    test "a symbol-specific queue is consumed only by calls naming that symbol" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:refused, :not_listed}])

      assert FakeInjection.next_outcome(:webull, "ETH-USD") == :none

      assert FakeInjection.next_outcome(:webull, "BTC-USD") ==
               {:override, {:refused, :not_listed}}

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == :none
    end

    test "a symbol-specific queue is checked before the whole-call queue" do
      FakeInjection.queue_failures(:webull, [{:error, :whole_call}])
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :symbol_specific}])

      assert FakeInjection.next_outcome(:webull, "BTC-USD") ==
               {:override, {:error, :symbol_specific}}

      # The whole-call queue is untouched by the symbol-specific pop above.
      assert FakeInjection.next_outcome(:webull, "ETH-USD") == {:override, {:error, :whole_call}}
    end

    test "one symbol failing never fails a different symbol's call" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :timeout}])

      assert FakeInjection.next_outcome(:webull, "ETH-USD") == :none
      assert FakeInjection.next_outcome(:webull) == :none
    end
  end

  describe "fail_always/2 and /3 — never pop, never exhaust" do
    test "fail_always/2 answers every whole-call read the same way" do
      FakeInjection.fail_always(:webull, {:error, :down})

      assert FakeInjection.next_outcome(:webull) == {:override, {:error, :down}}
      assert FakeInjection.next_outcome(:webull) == {:override, {:error, :down}}
    end

    test "fail_always/3 answers every read for that symbol, and only that symbol" do
      FakeInjection.fail_always(:webull, "BTC-USD", {:error, :down})

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :down}}
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :down}}
      assert FakeInjection.next_outcome(:webull, "ETH-USD") == :none
    end

    test "a symbol-specific always-fail is checked before a whole-call always-fail" do
      FakeInjection.fail_always(:webull, {:error, :whole_call})
      FakeInjection.fail_always(:webull, "BTC-USD", {:error, :symbol_specific})

      assert FakeInjection.next_outcome(:webull, "BTC-USD") ==
               {:override, {:error, :symbol_specific}}

      assert FakeInjection.next_outcome(:webull, "ETH-USD") == {:override, {:error, :whole_call}}
    end
  end

  describe "bypass_credentials/1" do
    test "is true only for the venue it was set for" do
      FakeInjection.bypass_credentials(:webull)

      assert FakeInjection.credentials_bypassed?(:webull)
      refute FakeInjection.credentials_bypassed?(:coinbase)
    end
  end

  describe "reset/1" do
    test "clears queued failures, always-fail and the credential bypass together" do
      FakeInjection.queue_failures(:webull, [{:error, :timeout}])
      FakeInjection.fail_always(:webull, "BTC-USD", {:error, :down})
      FakeInjection.bypass_credentials(:webull)

      FakeInjection.reset(:webull)

      assert FakeInjection.next_outcome(:webull) == :none
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == :none
      refute FakeInjection.credentials_bypassed?(:webull)
    end

    test "resetting one venue leaves another venue's configuration untouched" do
      FakeInjection.fail_always(:webull, {:error, :down})
      FakeInjection.fail_always(:coinbase, {:error, :down})

      FakeInjection.reset(:webull)

      assert FakeInjection.next_outcome(:webull) == :none
      assert FakeInjection.next_outcome(:coinbase) == {:override, {:error, :down}}
    end
  end

  describe "a symbol's queue is pruned when its last outcome is popped" do
    # The agent state is `%{venue => state}`; reading it is the only way to see that an empty
    # list was not left behind, because `next_outcome/2` answers `:none` either way.
    defp by_symbol(venue) do
      {:ok, agent} = DpExchange.Core.Config.find_override(:fake_injection)
      Agent.get(agent, &Map.fetch!(&1, venue).by_symbol)
    end

    test "the symbol's entry is removed after its last pop" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :one}, {:error, :two}])
      assert Map.keys(by_symbol(:webull)) == ["BTC-USD"]

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :one}}
      assert Map.keys(by_symbol(:webull)) == ["BTC-USD"]

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :two}}
      assert by_symbol(:webull) == %{}
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == :none
    end

    test "other symbols' queues are untouched by the prune" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :btc}])
      FakeInjection.queue_failures(:webull, "ETH-USD", [{:error, :eth}])

      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :btc}}
      assert by_symbol(:webull) == %{"ETH-USD" => [{:error, :eth}]}
    end

    test "queuing no outcomes for a symbol leaves no entry" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [])
      assert by_symbol(:webull) == %{}
    end

    test "a symbol can be queued again after it was pruned" do
      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :one}])
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :one}}

      FakeInjection.queue_failures(:webull, "BTC-USD", [{:error, :again}])
      assert FakeInjection.next_outcome(:webull, "BTC-USD") == {:override, {:error, :again}}
    end
  end

  describe "isolation between venues" do
    test "queuing for one venue never answers a read for another" do
      FakeInjection.queue_failures(:webull, [{:error, :timeout}])

      assert FakeInjection.next_outcome(:coinbase) == :none
    end
  end

  describe "isolation across processes" do
    test "an override set in this test is invisible to an unrelated process", %{} do
      FakeInjection.fail_always(:webull, {:error, :down})

      {:ok, agent} = Agent.start_link(fn -> FakeInjection.next_outcome(:webull) end)
      assert Agent.get(agent, & &1) == :none
    end

    test "a Task consumes a queued outcome, and the test's next call sees the following one" do
      FakeInjection.queue_failures(:webull, [{:error, :first}, {:error, :second}])

      assert Task.async(fn -> FakeInjection.next_outcome(:webull) end) |> Task.await() ==
               {:override, {:error, :first}}

      assert FakeInjection.next_outcome(:webull) == {:override, {:error, :second}}
      assert FakeInjection.next_outcome(:webull) == :none
    end

    test "tasks racing for one queue each receive a different outcome" do
      outcomes = for n <- 1..20, do: {:error, n}
      FakeInjection.queue_failures(:webull, outcomes)

      got =
        1..20
        |> Task.async_stream(fn _i -> FakeInjection.next_outcome(:webull) end, max_concurrency: 8)
        |> Enum.map(fn {:ok, {:override, outcome}} -> outcome end)

      assert Enum.sort(got) == Enum.sort(outcomes)
      assert FakeInjection.next_outcome(:webull) == :none
    end

    test "the shared state ends when the configuring process exits normally" do
      test_pid = self()

      {pid, ref} =
        spawn_monitor(fn ->
          FakeInjection.queue_failures(:webull, [{:error, :first}])
          {:ok, agent} = DpExchange.Core.Config.find_override(:fake_injection)
          send(test_pid, {:agent, agent})
        end)

      assert_receive {:agent, agent}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      agent_ref = Process.monitor(agent)
      assert_receive {:DOWN, ^agent_ref, :process, ^agent, _reason}, 5_000
    end

    test "the watcher ends when the agent dies first, instead of waiting for the owner" do
      # The watcher waited on the owner alone, so an agent killed from outside left it
      # running until the owner exited, and the next configuration started another.
      Process.flag(:trap_exit, true)
      FakeInjection.queue_failures(:webull, [{:error, :first}])
      {:ok, agent} = DpExchange.Core.Config.find_override(:fake_injection)

      {:monitored_by, watchers} = Process.info(agent, :monitored_by)
      assert watchers != []
      refs = Map.new(watchers, &{Process.monitor(&1), &1})

      Process.exit(agent, :kill)

      for {ref, watcher} <- refs do
        assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}, 5_000
      end

      # A stale handle is "nothing configured", and configuring again starts a fresh agent.
      assert FakeInjection.next_outcome(:webull) == :none
      FakeInjection.queue_failures(:webull, [{:error, :again}])
      assert FakeInjection.next_outcome(:webull) == {:override, {:error, :again}}
    end

    test "resetting a venue nothing was configured for is a no-op, not an error" do
      assert FakeInjection.reset(:webull) == :ok
      assert FakeInjection.next_outcome(:webull) == :none
    end

    # The configuring process's agent can die between the liveness check and the call that
    # follows it. A handle to a process that is alive but exits on its first call is exactly
    # that moment, made deterministic: each read below must report "nothing configured".
    test "an agent that dies mid-call means nothing is configured, never a crash" do
      dying_agent = fn ->
        pid =
          spawn(fn ->
            receive do
              {:"$gen_call", _from, _request} -> exit(:agent_died)
            end
          end)

        DpExchange.Core.Config.put_override(:fake_injection, pid)
      end

      dying_agent.()
      assert FakeInjection.next_outcome(:webull) == :none

      dying_agent.()
      refute FakeInjection.credentials_bypassed?(:webull)

      dying_agent.()
      assert FakeInjection.reset(:webull) == :ok
    end

    test "an override set in this test IS visible to a Task it spawns" do
      FakeInjection.fail_always(:webull, {:error, :down})

      assert Task.async(fn -> FakeInjection.next_outcome(:webull) end) |> Task.await() ==
               {:override, {:error, :down}}
    end
  end
end
