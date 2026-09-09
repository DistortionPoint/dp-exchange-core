defmodule DpExchange.PurityTest do
  use ExUnit.Case, async: true

  # Phase 2.9 and 2.10 as executable checks rather than a grep someone ran once. Both
  # are properties that can only regress silently: nothing fails to compile when a host
  # module or a venue branch creeps back in.

  @venues ~w(coinbase gemini kraken binance webull robinhood schwab coingecko)

  @forbidden_namespaces [
    "DpCryptoManagement.",
    "Phoenix.",
    "Ash.",
    "Cloak.",
    "Ecto.",
    "Boundary,"
  ]

  defp lib_sources do
    Path.wildcard("lib/**/*.ex")
  end

  # Documentation legitimately names venues and the patterns this package removed —
  # explaining WHY something is absent is the most valuable thing in several of these
  # files. What must not exist is the code.
  defp code_only(source) do
    source
    |> String.replace(~r/@(module)?doc\s+"""..*?"""/s, "")
    |> String.replace(~r/@(module)?doc\s+"[^"]*"/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end

  describe "2.10 — nothing in lib/ reaches for the host application" do
    test "no forbidden namespace appears in code" do
      for path <- lib_sources(), namespace <- @forbidden_namespaces do
        refute code_only(File.read!(path)) =~ namespace,
               "#{path} references #{namespace}"
      end
    end

    test "the compiled modules call nothing outside stdlib and declared deps" do
      # The strongest form of the check: not what the source says, but what the BEAM
      # actually links against. A transitive reference no one noticed shows up here.
      allowed_prefixes = ~w(Elixir.DpExchange Elixir.Kernel Elixir.Access Elixir.Application
                            Elixir.ArgumentError Elixir.Base Elixir.Code Elixir.DateTime
                            Elixir.Decimal Elixir.Enum Elixir.Exception Elixir.File
                            Elixir.GenServer Elixir.Integer Elixir.Jason Elixir.Keyword
                            Elixir.List Elixir.Logger Elixir.Macro Elixir.Map Elixir.MapSet
                            Elixir.Module Elixir.Path Elixir.Process Elixir.Regex Elixir.Req
                            Elixir.RuntimeError Elixir.String Elixir.Supervisor Elixir.System
                            Elixir.URI Elixir.Task Elixir.Stream Elixir.Float Elixir.Tuple)

      # `beam_lib`, `xref` and `erl_anno` are `:tools`/`:stdlib` — `Core.UnwiredCheck`'s
      # call-graph engine for assertion 16 (`Core.AdapterContract`), the same family
      # `beam_lib` was already reaching for in assertion 7's own imports-chunk check.
      allowed_erlang = ~w(erlang lists maps crypto logger elixir_erl_pass ets os
                          telemetry rand binary re unicode beam_lib xref erl_anno)a

      called =
        "_build/#{Mix.env()}/lib/dp_exchange_core/ebin/*.beam"
        |> Path.wildcard()
        # Only modules whose SOURCE is under `lib/`. In `:test` this project's
        # `elixirc_paths/1` also compiles `test/support`, and its output lands in this very
        # same `ebin` directory — so without this filter the check named "nothing in lib/"
        # was quietly also policing test scaffolding. Found when `test/support`'s reference
        # venue grew an `@derive {Inspect, ...}` (assertion 22's own fix) and this test
        # failed reporting `Inspect.Any` "in lib/", where no such reference exists.
        #
        # Filtering is the right repair rather than widening `allowed_prefixes`: the
        # allow-list is what gives this test its teeth for the code that actually ships,
        # and adding an entry to satisfy a module that never ships would blunt it for the
        # one that does.
        |> Enum.filter(&compiled_from_lib?/1)
        |> Enum.flat_map(fn beam ->
          {:ok, {_module, [imports: imports]}} =
            :beam_lib.chunks(String.to_charlist(beam), [:imports])

          Enum.map(imports, fn {module, _fun, _arity} -> module end)
        end)
        |> Enum.uniq()

      unexpected =
        Enum.reject(called, fn module ->
          name = to_string(module)

          module in allowed_erlang or
            Enum.any?(allowed_prefixes, &String.starts_with?(name, &1))
        end)

      assert unexpected == [],
             "lib/ links against modules outside stdlib and declared deps: #{inspect(unexpected)}"
    end
  end

  describe "2.9 — no venue table anywhere in Core" do
    test "no module dispatches on a venue name" do
      # Reproducing the host's provider tables inside Core would be worse than leaving
      # them in the host: it would be the same defect, one layer further from the venue
      # that could correct it.
      for path <- lib_sources(), venue <- @venues do
        code = code_only(File.read!(path))

        refute code =~ ~r/"#{venue}"\s*->/i, "#{path} branches on \"#{venue}\""
        refute code =~ ~r/:#{venue}\s*->/i, "#{path} branches on :#{venue}"
      end
    end

    test "no module holds a map keyed by venue" do
      for path <- lib_sources(), venue <- @venues do
        code = code_only(File.read!(path))

        refute code =~ ~r/"#{venue}"\s*=>/i, "#{path} holds a map keyed by \"#{venue}\""
        refute code =~ ~r/#{venue}:\s/i, "#{path} holds a map or keyword keyed by #{venue}"
      end
    end
  end

  describe "D20 — Core ships no venue-specific dependency" do
    test "no transport library is declared at any strength" do
      mix_exs = code_only(File.read!("mix.exs"))

      for library <- ~w(websockex gun mint_web_socket tortoise emqtt) do
        refute mix_exs =~ ~r/\{:#{library}/, "#{library} is a venue's transport choice"
      end
    end

    test "no transport library is resolved" do
      resolved = File.ls!("deps")

      for library <- ~w(websockex gun tortoise emqtt) do
        refute library in resolved
      end
    end
  end

  describe "a library does not start itself" do
    test "there is no Application callback module" do
      # A consumer that has not asked for a venue must not find a socket open.
      config = Mix.Project.config()
      refute Keyword.has_key?(config[:app] && config, :mod)

      application = Mix.Project.config()[:application] || []
      refute Keyword.has_key?(application, :mod)
    end
  end

  # A beam's own `:compile_info` carries the absolute path of the source it was built
  # from, which is the only reliable way to tell a `lib/` module from a `test/support`
  # one once both are sitting in the same `ebin`.
  defp compiled_from_lib?(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:compile_info]) do
      {:ok, {_module, [compile_info: info]}} ->
        info
        |> Keyword.get(:source, ~c"")
        |> to_string()
        |> String.contains?("/lib/")

      _no_compile_info ->
        # Cannot prove it came from `test/support`, so keep checking it. Failing open
        # here would let a real `lib/` module skip the check by losing a chunk.
        true
    end
  end
end
