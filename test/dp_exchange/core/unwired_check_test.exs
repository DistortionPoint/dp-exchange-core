defmodule DpExchange.Core.UnwiredCheckTest do
  @moduledoc """
  Exercises `DpExchange.Core.UnwiredCheck` against real compiled `.beam` files through
  `:beam_lib`/`:xref`, not against its internals — a mock of the call graph would only
  prove the mock agrees with itself.

  Every fixture module name is suffixed with a per-test unique integer so two `async:
  true` tests never compile the same module name into the shared code server at once.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{UnwiredCheck, UnwiredFixture}

  defp uniq, do: System.unique_integer([:positive, :monotonic])

  defp violation_mfas(violations) do
    Enum.map(violations, fn v -> {v.module, v.function, v.arity} end)
  end

  describe "run/3 — what counts as a caller" do
    test "a direct remote call wires the callee, and the caller stays unwired" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "callee.ex",
            code: """
            defmodule Callee#{u} do
              def used(x), do: x + 1
            end
            """
          },
          %{
            path: "caller.ex",
            code: """
            defmodule Caller#{u} do
              def entry, do: Callee#{u}.used(1)
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mfas = violation_mfas(violations)

      refute {Module.concat([:"Elixir", "Callee#{u}"]), :used, 1} in mfas
      assert {Module.concat([:"Elixir", "Caller#{u}"]), :entry, 0} in mfas
    end

    test "a captured function reference wires the callee" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "callee.ex",
            code: """
            defmodule Callee#{u} do
              def used(x), do: x + 2
            end
            """
          },
          %{
            path: "caller.ex",
            code: """
            defmodule Caller#{u} do
              def entry do
                fun = &Callee#{u}.used/1
                fun.(1)
              end
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      refute {Module.concat([:"Elixir", "Callee#{u}"]), :used, 1} in violation_mfas(violations)
    end

    test "apply/3 with literal module and function atoms wires the callee" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "callee.ex",
            code: """
            defmodule Callee#{u} do
              def used(x), do: x + 3
            end
            """
          },
          %{
            path: "caller.ex",
            code: """
            defmodule Caller#{u} do
              def entry, do: apply(Callee#{u}, :used, [1])
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      refute {Module.concat([:"Elixir", "Callee#{u}"]), :used, 1} in violation_mfas(violations)
    end

    test "a call from one function to another in the same module wires the callee" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "self_call.ex",
            code: """
            defmodule SelfCall#{u} do
              def entry(x), do: helper(x)
              def helper(x), do: x * 2
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mfas = violation_mfas(violations)
      mod = Module.concat([:"Elixir", "SelfCall#{u}"])

      refute {mod, :helper, 1} in mfas, "helper/1 is called by entry/1 in the same module"
      assert {mod, :entry, 1} in mfas, "nothing at all calls entry/1"
    end

    test "a function with no caller anywhere is flagged, with file and line" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "orphan.ex",
            code: """
            defmodule Orphan#{u} do
              def never_called(x), do: x
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Orphan#{u}"])

      assert [%{module: ^mod, function: :never_called, arity: 1, file: file, line: line}] =
               violations

      assert String.ends_with?(file, "orphan.ex")
      assert line == 2
    end

    test "a call from a module whose source is outside lib_root does not count" do
      u = uniq()

      # "Callee" lives under lib_root; "Outsider" is compiled with a source path that
      # is NOT under lib_root (the shape of test/support, or any fixture/fake). Its
      # call must not be able to make Callee's export look wired — that is exactly the
      # defect class this check exists for: a test calling a function directly.
      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "callee.ex",
            code: """
            defmodule OutsideCallee#{u} do
              def used(x), do: x
            end
            """
          },
          %{
            path: "../not_lib/outsider.ex",
            code: """
            defmodule Outsider#{u} do
              def entry, do: OutsideCallee#{u}.used(1)
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "OutsideCallee#{u}"])
      assert {mod, :used, 1} in violation_mfas(violations)
    end
  end

  describe "run/3 — exclusions" do
    test "excluded_modules are never reported, but their calls still wire other modules" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "internal.ex",
            code: """
            defmodule Internal#{u} do
              def helper, do: :ok
            end
            """
          },
          %{
            path: "facade.ex",
            code: """
            defmodule Facade#{u} do
              def public_api, do: Internal#{u}.helper()
            end
            """
          }
        ])

      facade = Module.concat([:"Elixir", "Facade#{u}"])
      internal = Module.concat([:"Elixir", "Internal#{u}"])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root, [facade])
      mfas = violation_mfas(violations)

      refute {facade, :public_api, 0} in mfas, "the facade is excluded outright"
      refute {internal, :helper, 1} in mfas
      refute {internal, :helper, 0} in mfas, "wired by the excluded facade's own call"
    end

    test "behaviour callbacks are excused, a plain function with the same shape is not" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "behaviour.ex",
            code: """
            defmodule Behaviour#{u} do
              @callback handle(term()) :: :ok
            end
            """
          },
          %{
            path: "impl.ex",
            code: """
            defmodule Impl#{u} do
              @behaviour Behaviour#{u}

              @impl true
              def handle(_term), do: :ok

              def not_a_callback(_term), do: :ok
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mfas = violation_mfas(violations)
      impl = Module.concat([:"Elixir", "Impl#{u}"])

      refute {impl, :handle, 1} in mfas, "handle/1 is Behaviour's own callback"
      assert {impl, :not_a_callback, 1} in mfas, "same shape, but never declared as a callback"
    end

    test "a GenServer's own callbacks are excused via GenServer.behaviour_info/1" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "gen_server.ex",
            code: """
            defmodule GS#{u} do
              use GenServer

              @impl true
              def init(state), do: {:ok, state}

              @impl true
              def handle_call(_msg, _from, state), do: {:reply, :ok, state}
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      gs = Module.concat([:"Elixir", "GS#{u}"])
      mfas = violation_mfas(violations)

      refute {gs, :init, 1} in mfas
      refute {gs, :handle_call, 3} in mfas
      # start_link/1, excused universally below, also comes free from `use GenServer`.
      refute {gs, :start_link, 1} in mfas
    end

    test "child_spec/1 and start_link/1 are always excused, on any module" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "supervisor.ex",
            code: """
            defmodule Sup#{u} do
              def start_link(opts), do: {:ok, opts}

              def child_spec(opts) do
                %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
              end
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      sup = Module.concat([:"Elixir", "Sup#{u}"])
      mfas = violation_mfas(violations)

      refute {sup, :start_link, 1} in mfas
      refute {sup, :child_spec, 1} in mfas
    end

    test "compiler-injected exports never appear as violations" do
      u = uniq()

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "struct.ex",
            code: """
            defmodule Structy#{u} do
              defstruct [:a]
            end
            """
          }
        ])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root)
      mod = Module.concat([:"Elixir", "Structy#{u}"])
      mfas = violation_mfas(violations)

      refute Enum.any?(mfas, fn {m, _f, _a} -> m == mod end),
             "__struct__/0, __struct__/1 and module_info/0,1 must all be excused: #{inspect(mfas)}"
    end
  end

  describe "run/3 — I/O edge cases" do
    test "an empty beam_dir yields no violations" do
      lib_root = Path.join([File.cwd!(), "tmp", "unwired_check_test", "empty_lib_#{uniq()}"])
      beam_dir = Path.join([File.cwd!(), "tmp", "unwired_check_test", "empty_beam_#{uniq()}"])
      File.mkdir_p!(beam_dir)

      assert {:ok, []} = UnwiredCheck.run(beam_dir, lib_root)
    end
  end

  describe "format/1" do
    test "renders one line per violation with module, function, arity and location" do
      violations = [
        %{module: Some.Mod, function: :foo, arity: 2, file: "/a/b.ex", line: 10},
        %{module: Other.Mod, function: :bar, arity: 0, file: "/a/c.ex", line: nil}
      ]

      rendered = UnwiredCheck.format(violations)

      assert rendered =~ "Some.Mod.foo/2 — /a/b.ex:10"
      assert rendered =~ "Other.Mod.bar/0 — /a/c.ex"
    end
  end
end
