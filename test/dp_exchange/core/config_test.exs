defmodule DpExchange.Core.ConfigTest do
  # async: true is not incidental here — it is the property under test. If these tests
  # could not run concurrently, the module would have failed at its only job.
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  doctest Config

  describe "get/3 falls back to application env" do
    test "returns the default when nothing is configured" do
      assert Config.get(:dp_exchange_core, :never_set_anywhere, :fallback) == :fallback
    end

    test "returns nil when no default is given" do
      assert Config.get(:dp_exchange_core, :never_set_anywhere) == nil
    end
  end

  describe "opt/3 — Keyword.get/3 that treats a present nil as absent (C1)" do
    test "an absent key returns the default, same as Keyword.get/3" do
      assert Config.opt([], :interval_ms, 30_000) == 30_000
    end

    test "a present value overrides the default, same as Keyword.get/3" do
      assert Config.opt([interval_ms: 5_000], :interval_ms, 30_000) == 5_000
    end

    test "a present-and-nil key returns the default — the case Keyword.get/3 gets wrong" do
      # This is the whole reason `opt/3` exists. Every venue package forwards its own
      # `opts` unchanged by family convention, so `interval_ms: nil` is what arrives
      # whenever nothing upstream ever set it — not an absent key, a present one.
      # `Keyword.get(opts, :interval_ms, 30_000)` against `interval_ms: nil` returns `nil`,
      # not `30_000`.
      assert Config.opt([interval_ms: nil], :interval_ms, 30_000) == 30_000
    end

    test "an explicit false is preserved, not treated as absent" do
      # `opt/3` deliberately does not use `||` for this reason: `||` is falsy on `false`
      # too, and a helper that silently overrode a real `false` back to its default would
      # be the same bug in the other direction — a caller that explicitly set
      # `log_requests: false` or `raw_status: false` must have that honoured.
      assert Config.opt([log_requests: false], :log_requests, true) == false
    end

    test "the FIRST value for a duplicated key wins, same as Keyword.fetch/2" do
      assert Config.opt([weight: 1, weight: 2], :weight, 5) == 1
      assert Config.opt([weight: nil, weight: 2], :weight, 5) == 5
    end
  end

  describe "a process-scoped override beats application env" do
    test "the calling process sees its own override" do
      Config.put_override(:seam, :overridden)
      assert Config.get(:dp_exchange_core, :seam, :fallback) == :overridden
    end

    test "an override of nil is an override, not an absence" do
      # Collapsing {:ok, nil} into "not set" would make nil unconfigurable, and nil is
      # a legitimate value for a seam meaning "no module injected".
      Config.put_override(:nil_seam, nil)
      assert Config.get(:dp_exchange_core, :nil_seam, :fallback) == nil
      assert Config.find_override(:nil_seam) == {:ok, nil}
    end

    test "delete_override/1 restores the fallback" do
      Config.put_override(:temporary, :set)
      assert Config.get(:dp_exchange_core, :temporary, :fallback) == :set

      Config.delete_override(:temporary)
      assert Config.get(:dp_exchange_core, :temporary, :fallback) == :fallback
    end

    test "overrides are keyed per seam, not shared" do
      Config.put_override(:seam_a, :a)
      Config.put_override(:seam_b, :b)

      assert Config.get(:dp_exchange_core, :seam_a, :fallback) == :a
      assert Config.get(:dp_exchange_core, :seam_b, :fallback) == :b
    end
  end

  describe "the override does not escape the process tree" do
    test "an unrelated process does not see it" do
      # This is the whole point. The incident being prevented: a global flag set by one
      # test metered every other async test on the node against a one-request bucket.
      Config.put_override(:isolated, :mine)

      task =
        Task.async(fn ->
          # Deliberately started with no $callers link to this test.
          Process.delete(:"$callers")
          Config.get(:dp_exchange_core, :isolated, :fallback)
        end)

      assert Task.await(task) == :fallback
      assert Config.get(:dp_exchange_core, :isolated, :fallback) == :mine
    end

    test "two concurrent processes hold different values for the same seam" do
      # Two tests wanting the same fake to behave differently — one simulating a 429,
      # one succeeding — is the case that global config cannot express at all.
      parent = self()

      a =
        Task.async(fn ->
          Process.delete(:"$callers")
          Config.put_override(:shared, :a)
          send(parent, :ready)
          receive do: (:go -> Config.get(:dp_exchange_core, :shared))
        end)

      b =
        Task.async(fn ->
          Process.delete(:"$callers")
          Config.put_override(:shared, :b)
          send(parent, :ready)
          receive do: (:go -> Config.get(:dp_exchange_core, :shared))
        end)

      assert_receive :ready
      assert_receive :ready
      send(a.pid, :go)
      send(b.pid, :go)

      assert Enum.sort([Task.await(a), Task.await(b)]) == [:a, :b]
    end
  end

  describe "the $callers walk — the step people omit" do
    test "a spawned Task inherits the override" do
      # ExUnit propagates $callers to Tasks. Without the walk, any work a test spawns
      # loses the override — which makes the seam work in simple tests and fail in
      # exactly the concurrent ones it exists for.
      Config.put_override(:inherited, :from_test)

      task = Task.async(fn -> Config.get(:dp_exchange_core, :inherited, :fallback) end)
      assert Task.await(task) == :from_test
    end

    test "a nested Task two levels deep still inherits it" do
      Config.put_override(:deep, :from_test)

      outer =
        Task.async(fn ->
          inner = Task.async(fn -> Config.get(:dp_exchange_core, :deep, :fallback) end)
          Task.await(inner)
        end)

      assert Task.await(outer) == :from_test
    end

    test "a nearer ancestor's override wins over a further one" do
      Config.put_override(:layered, :outer)

      task =
        Task.async(fn ->
          Config.put_override(:layered, :inner)
          nested = Task.async(fn -> Config.get(:dp_exchange_core, :layered, :fallback) end)
          Task.await(nested)
        end)

      assert Task.await(task) == :inner
      assert Config.get(:dp_exchange_core, :layered, :fallback) == :outer
    end

    test "a dead ancestor does not stop the walk" do
      # A test process can finish while work it spawned is still running. Treating a
      # dead ancestor as an error would turn ordinary shutdown into a crash.
      Config.put_override(:survives, :yes)

      {dead_pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

      task =
        Task.async(fn ->
          Process.put(:"$callers", [dead_pid | Process.get(:"$callers", [])])
          Config.get(:dp_exchange_core, :survives, :fallback)
        end)

      assert Task.await(task) == :yes
    end
  end

  describe "crossing a process boundary" do
    test "snapshot/1 captures only the seams that are actually overridden" do
      Config.put_override(:captured, 1)
      assert Config.snapshot([:captured, :not_set]) == %{captured: 1}
    end

    test "a GenServer cannot see the caller's override without a snapshot" do
      # The failure this documents: a server is not in the caller's $callers chain, so
      # resolving inside the server silently reads global config. Production is
      # unaffected, so only a consumer's async suite breaks.
      {:ok, server} = Agent.start_link(fn -> :ok end)
      Config.put_override(:not_carried, :caller_value)

      resolved =
        Agent.get(server, fn _state ->
          Config.get(:dp_exchange_core, :not_carried, :fallback)
        end)

      assert resolved == :fallback
    end

    test "resolve_snapshot/3 carries the caller's value across that boundary" do
      {:ok, server} = Agent.start_link(fn -> :ok end)
      Config.put_override(:carried, :caller_value)

      snapshot = Config.snapshot([:carried])

      resolved =
        Agent.get(server, fn _state ->
          Config.resolve_snapshot(snapshot, :carried, :fallback)
        end)

      assert resolved == :caller_value
    end

    test "an empty snapshot falls back rather than reading the server's dictionary" do
      # A long-lived server's dictionary is not scoped to any one caller, so honouring
      # it would leak one caller's configuration into another's request.
      Config.put_override(:server_local, :should_not_be_used)
      assert Config.resolve_snapshot(%{}, :server_local, :fallback) == :fallback
    end
  end
end
