defmodule DpExchange.Core.LinkSafetyCheckTest do
  @moduledoc """
  Exercises `DpExchange.Core.LinkSafetyCheck` against real compiled `.beam` files, reusing
  `DpExchange.Core.UnwiredFixture` — it already compiles arbitrary source into `.beam`
  files under a controllable `lib_root`, which is all this check needs too.

  The first two tests reconstruct the actual pre-fix and post-fix shape found across the
  family on 2026-09-07 (`Feed.init/1` with no `Process.flag(:trap_exit, true)`, a socket
  linked from inside a callback) — proof this check would have caught the real defect,
  without touching any venue repo.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{LinkSafetyCheck, UnwiredFixture}

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  defp violation_mfas(violations) do
    Enum.map(violations, fn v -> {v.module, v.function, v.arity} end)
  end

  describe "the defect this check exists for" do
    test "the pre-fix shape: a linked child started from a callback, no trap_exit" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "socket.ex",
            code: """
            defmodule Socket#{u} do
              def start_link(_opts), do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
            end
            """
          },
          %{
            path: "feed.ex",
            code: """
            defmodule Feed#{u} do
              use GenServer

              @impl true
              def init(_opts), do: {:ok, %{socket: nil}}

              @impl true
              def handle_call(:open, _from, state) do
                {:ok, socket} = Socket#{u}.start_link([])
                {:reply, :ok, %{state | socket: socket}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      feed = Module.concat([:"Elixir", "Feed#{u}"])

      assert {feed, :handle_call, 3} in violation_mfas(violations),
             "Socket#{u}.start_link/1 links the socket to Feed#{u}, and nothing here " <>
               "ever traps exits — this is the exact shape that crashed the feed and " <>
               "lost every subscription"
    end

    test "the post-fix shape: the same link, guarded by Process.flag(:trap_exit, true)" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "socket.ex",
            code: """
            defmodule Socket#{u} do
              def start_link(_opts), do: {:ok, spawn(fn -> Process.sleep(:infinity) end)}
            end
            """
          },
          %{
            path: "feed.ex",
            code: """
            defmodule Feed#{u} do
              use GenServer

              @impl true
              def init(_opts) do
                Process.flag(:trap_exit, true)
                {:ok, %{socket: nil}}
              end

              @impl true
              def handle_call(:open, _from, state) do
                {:ok, socket} = Socket#{u}.start_link([])
                {:reply, :ok, %{state | socket: socket}}
              end

              @impl true
              def handle_info({:EXIT, _pid, _reason}, state) do
                {:noreply, %{state | socket: nil}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      feed = Module.concat([:"Elixir", "Feed#{u}"])

      refute Enum.any?(violations, &(&1.module == feed)),
             "Feed#{u} traps exits — the exact fix all five venues shipped"
    end
  end

  describe "run/2 — what counts as a link-creating call" do
    test "Process.link/1 without trap_exit is flagged" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "linker.ex",
            code: """
            defmodule Linker#{u} do
              use GenServer

              @impl true
              def init(opts) do
                socket = Keyword.fetch!(opts, :socket)
                Process.link(socket)
                {:ok, %{socket: socket}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Linker#{u}"])
      assert {mod, :init, 1} in violation_mfas(violations)
    end

    test "spawn_link is flagged the same as an explicit start_link call" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "spawner.ex",
            code: """
            defmodule Spawner#{u} do
              use GenServer

              @impl true
              def init(_opts) do
                pid = spawn_link(fn -> :ok end)
                {:ok, %{pid: pid}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Spawner#{u}"])
      assert {mod, :init, 1} in violation_mfas(violations)
    end

    test "Process.flag(:trap_exit, false) does not count as the guard" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "socket.ex",
            code: """
            defmodule DisabledSocket#{u} do
              def start_link(_opts), do: {:ok, self()}
            end
            """
          },
          %{
            path: "feed.ex",
            code: """
            defmodule DisabledFeed#{u} do
              use GenServer

              @impl true
              def init(_opts) do
                # Explicitly OFF — must not be mistaken for the guard.
                Process.flag(:trap_exit, false)
                {:ok, socket} = DisabledSocket#{u}.start_link([])
                {:ok, %{socket: socket}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "DisabledFeed#{u}"])
      assert {mod, :init, 1} in violation_mfas(violations)
    end

    test "the link-creating call can be reached from any callback, not only init/1" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "poller.ex",
            code: """
            defmodule Poller#{u} do
              def start_link(_opts), do: {:ok, self()}
            end
            """
          },
          %{
            path: "feed.ex",
            code: """
            defmodule ContinueFeed#{u} do
              use GenServer

              @impl true
              def init(_opts) do
                Process.flag(:trap_exit, true)
                {:ok, %{poller: nil}, {:continue, :connect}}
              end

              @impl true
              def handle_continue(:connect, state) do
                {:ok, poller} = Poller#{u}.start_link([])
                {:noreply, %{state | poller: poller}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "ContinueFeed#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "trap_exit lives in init/1, the link lives in handle_continue/2 — the " <>
               "invariant holds across the whole module, not per callback"
    end
  end

  describe "run/2 — a process behaviour's own bootstrap is not the source" do
    test "start_link/1 delegating to the behaviour's own start_link is not flagged" do
      # Found running this check against the real, compiled `dp_exchange_coinbase`:
      # `Socket.start_link/1` (`use WebSockex`) delegates to `WebSockex.start_link/4` to
      # bootstrap itself — a call literally named `start_link`, on every
      # process-behaviour module in the family, always. Reconstructed here with
      # `:gen_statem` (always available; `websockex` is deliberately not a Core
      # dependency) so the fixture needs nothing this package does not already have.
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "socket.ex",
            code: """
            defmodule BootstrapOnly#{u} do
              @behaviour :gen_statem

              def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

              @impl true
              def callback_mode, do: :state_functions

              @impl true
              def init(opts), do: {:ok, :ready, opts}
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "BootstrapOnly#{u}"])

      refute Enum.any?(violations, &(&1.module == mod)),
             "the link :gen_statem.start_link/3 creates belongs to whoever calls " <>
               "BootstrapOnly#{u}.start_link/1 — this module links nothing itself"
    end

    test "a link created outside start_link/1 in the same module is still caught" do
      # Proves the exclusion is scoped to start_link/1 itself, not to the whole module —
      # a module could legitimately bootstrap via the behaviour's start_link AND
      # separately link something risky from one of its own callbacks.
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "child.ex",
            code: """
            defmodule BootstrapChild#{u} do
              def start_link(_opts), do: {:ok, self()}
            end
            """
          },
          %{
            path: "mixed.ex",
            code: """
            defmodule MixedLinker#{u} do
              @behaviour :gen_statem

              def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

              @impl true
              def callback_mode, do: :state_functions

              @impl true
              def init(opts) do
                {:ok, _child} = BootstrapChild#{u}.start_link([])
                {:ok, :ready, opts}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "MixedLinker#{u}"])

      assert Enum.any?(violations, &(&1.module == mod)),
             "init/1 links BootstrapChild#{u} and MixedLinker#{u} never traps exits — " <>
               "excusing start_link/1 must not excuse the rest of the module too"
    end
  end

  describe "run/2 — what is not a candidate at all" do
    test "a plain module (no process behaviour) calling start_link is never flagged" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "supervisor.ex",
            code: """
            defmodule PlainSup#{u} do
              def start_link(opts), do: {:ok, opts}
            end
            """
          },
          %{
            path: "facade.ex",
            code: """
            defmodule Facade#{u} do
              def start_link(opts), do: PlainSup#{u}.start_link(opts)
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      facade = Module.concat([:"Elixir", "Facade#{u}"])

      refute Enum.any?(violations, &(&1.module == facade)),
             "Facade#{u} is not a GenServer/gen_statem/GenStateMachine/WebSockex — the " <>
               "link this creates belongs to whichever process CALLS start_link/1, not " <>
               "to a process this module owns"
    end

    test "a Supervisor's own child-spec tuple is data, never a call, and is not flagged" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "child.ex",
            code: """
            defmodule Child#{u} do
              def start_link(_opts), do: {:ok, self()}
            end
            """
          },
          %{
            path: "sup.ex",
            code: """
            defmodule Sup#{u} do
              use Supervisor

              def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

              @impl true
              def init(opts) do
                Supervisor.init([{Child#{u}, opts}], strategy: :one_for_one)
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      sup = Module.concat([:"Elixir", "Sup#{u}"])

      refute Enum.any?(violations, &(&1.module == sup)),
             "{Child, opts} is an MFA tuple the :supervisor OTP behaviour starts, never " <>
               "a literal call in Sup#{u}'s own compiled code"
    end

    test "a GenServer that links nothing passes trivially" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "quiet.ex",
            code: """
            defmodule Quiet#{u} do
              use GenServer

              @impl true
              def init(state), do: {:ok, state}
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Quiet#{u}"])
      refute Enum.any?(violations, &(&1.module == mod))
    end

    test "a module whose source is outside lib_root is never analysed" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "socket.ex",
            code: """
            defmodule OutsideSocket#{u} do
              def start_link(_opts), do: {:ok, self()}
            end
            """
          },
          %{
            path: "../not_lib/outside_feed.ex",
            code: """
            defmodule OutsideFeed#{u} do
              use GenServer

              @impl true
              def init(_opts) do
                {:ok, socket} = OutsideSocket#{u}.start_link([])
                {:ok, %{socket: socket}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = LinkSafetyCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "OutsideFeed#{u}"])
      refute Enum.any?(violations, &(&1.module == mod))
    end
  end

  describe "run/2 — I/O edge cases" do
    test "an empty beam_dir yields no violations" do
      lib_root = Path.join(UnwiredFixture.run_root(), "link_empty_lib_#{uniq()}")

      beam_dir =
        Path.join(UnwiredFixture.run_root(), "link_empty_beam_#{uniq()}")

      File.mkdir_p!(beam_dir)

      assert {:ok, []} = LinkSafetyCheck.run(beam_dir, lib_root)
    end
  end

  describe "format/1" do
    test "renders one line per violation naming the module, callback and location" do
      violations = [
        %{module: Some.Feed, function: :handle_call, arity: 3, file: "/a/feed.ex", line: 12}
      ]

      rendered = LinkSafetyCheck.format(violations)

      assert rendered =~ "Some.Feed"
      assert rendered =~ "handle_call/3"
      assert rendered =~ "/a/feed.ex:12"
      assert rendered =~ "trap_exit"
    end
  end
end
