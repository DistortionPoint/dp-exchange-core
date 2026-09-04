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

    test "an override set in this test IS visible to a Task it spawns" do
      FakeInjection.fail_always(:webull, {:error, :down})

      assert Task.async(fn -> FakeInjection.next_outcome(:webull) end) |> Task.await() ==
               {:override, {:error, :down}}
    end
  end
end
