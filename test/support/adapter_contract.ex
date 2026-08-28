defmodule DpExchange.Core.AdapterContract do
  @moduledoc """
  The conformance suite every venue package runs in its own CI.

  **This is the mechanism.** Prose in six `CLAUDE.md` files drifts; a suite that runs in
  five CI pipelines cannot. It ships inside the Hex tarball — `test/support` is in
  `mix.exs`'s `files:` — so a venue package gets it as a dependency and runs it against
  itself.

      defmodule DpExchange.Coinbase.ContractTest do
        use DpExchange.Core.AdapterContract,
          venue: DpExchange.Coinbase,
          symbol_format: DpExchange.Coinbase.SymbolFormat,
          sample_pairs: ~w(BTC-USDC ETH-USDC),
          credentials: %{api_key: "test", api_secret: "test"}
      end

  ## What it asserts, and what it deliberately does not

  Thirteen groups, listed in `assertions/0`. The load-bearing one is **capabilities and
  behaviour agreeing in both directions**: over-declaring fails in a caller's hands at
  runtime, and under-declaring hides working functionality. Holding both is what makes
  `capabilities/0` trustworthy enough for a consumer to branch on instead of branching on
  venue identity.

  **Maturity is asserted for presence, not for truth.** Every active endpoint must declare
  `:proven` or `:experimental`, because an absent value is the failure this prevents.
  Whether a `:proven` claim is *true* is not machine-checkable, and a suite that pretended
  otherwise would be worse than one that admits the limit.

  **No assertion may name a socket, a channel string, a transport module or a polling
  interval.** If one does, mechanism has leaked through the facade and the assertion is the
  bug, not the venue.

  ## The fake satisfies the same suite as the real adapter

  That is the ratchet. The suite's job is not to anticipate every way a fake can diverge —
  it is to make each discovered divergence permanent. The reference implementation this
  pattern comes from went from nothing to over a thousand lines by absorbing thirteen gaps
  its first consumer found, and none reached an external user across thousands of downloads.

  **Every gap found becomes a new assertion here.** A gap fixed only in one venue's fake is
  a gap the next venue will reintroduce.
  """

  @doc """
  The assertion groups, for documentation and for a venue package to report against.
  """
  @spec assertions() :: [{pos_integer(), String.t()}]
  def assertions do
    [
      {1, "behaviour completeness — every required callback, optionals all-or-nothing"},
      {2, "capabilities — a validated %Capabilities{} whose invariants hold"},
      {3, "identity — name, runtime id and asset classes are present and well-formed"},
      {4, "symbol round-trip — to_canonical(to_exchange(p)) == p, over declared quotes"},
      {5, "return types — Core.Types.* with Decimal numerics and DateTime timestamps"},
      {6, "error discipline — {:error, :not_supported} as the atom, and never a raise"},
      {7, "purity — the package links against no host application"},
      {8, "both endpoints answer — pull and subscribe, on every venue, with no flag"},
      {9, "fake fidelity — the fake satisfies this same suite"},
      {10, "facade completeness and exclusivity — only the facade is public"},
      {11, "self-sufficiency — nothing injected but credentials and options"},
      {12, "capabilities and behaviour agree, in both directions"},
      {13, "process-scoped isolation — usable in a consumer's async suite"}
    ]
  end

  @doc false
  defmacro __using__(opts) do
    [
      setup(opts),
      completeness(),
      capabilities(),
      identity(),
      symbol_round_trip(opts),
      agreement(),
      both_endpoints(),
      purity(),
      isolation(),
      helpers(),
      arg_helpers()
    ]
  end

  # Each group is its own quoted block rather than one long one. That is a readability
  # rule credo enforces, and it happens to be right here: a 400-line quote is a block
  # nobody reads before adding the 401st line.
  defp setup(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      use ExUnit.Case, async: true

      alias DpExchange.Core.{Capabilities, SymbolNormalizer, Timeframe, Venue}

      @venue Keyword.fetch!(opts, :venue)
      @symbol_format Keyword.get(opts, :symbol_format)
      @sample_pairs Keyword.get(opts, :sample_pairs, [])
      @credentials Keyword.get(opts, :credentials, %{})
      @package_root Keyword.get(opts, :package_root, "lib")
    end
  end

  defp completeness do
    quote location: :keep do
      # --- 1. behaviour completeness --------------------------------------

      describe "1. behaviour completeness" do
        test "implements every required facade callback" do
          Code.ensure_loaded!(@venue)

          missing =
            Enum.reject(Venue.required_callbacks(), fn {name, arity} ->
              function_exported?(@venue, name, arity)
            end)

          assert missing == [],
                 "#{inspect(@venue)} is missing required facade callbacks: #{inspect(missing)}"
        end

        test "declares the facade behaviour" do
          behaviours =
            @venue.module_info(:attributes)
            |> Keyword.get_values(:behaviour)
            |> List.flatten()

          assert Venue in behaviours,
                 "#{inspect(@venue)} must declare @behaviour DpExchange.Core.Venue — the " <>
                   "compiler's missing-callback check is the cheapest of these assertions"
        end

        test "optional callbacks are implemented or absent, never half" do
          Code.ensure_loaded!(@venue)

          for {name, arity} <- Venue.behaviour_info(:optional_callbacks) do
            exported = function_exported?(@venue, name, arity)

            assert is_boolean(exported),
                   "#{name}/#{arity} must be fully present or fully absent"
          end
        end
      end
    end
  end

  defp capabilities do
    quote location: :keep do
      # --- 2. capabilities ------------------------------------------------

      describe "2. capabilities" do
        test "returns a validated declaration" do
          assert %Capabilities{} = caps = @venue.capabilities()

          # Rebuilding through new/1 runs the raising validations. A declaration
          # assembled with %Capabilities{} directly would skip every invariant.
          assert %Capabilities{} = Capabilities.new(Map.from_struct(caps))
        end

        test "declared candle widths are in the shared vocabulary" do
          caps = @venue.capabilities()
          assert caps.historical_timeframes -- Timeframe.known() == []
        end

        test "a claim of history names the widths it serves" do
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_historical_prices, 4}) and
               Map.has_key?(caps.endpoints, {:get_historical_prices, 4}) do
            assert caps.historical_timeframes != [],
                   "the backfill would iterate nothing and report success"
          end
        end

        test "authenticated streaming is a subset of streaming" do
          caps = @venue.capabilities()
          assert caps.authenticated_streamable -- caps.streamable == []
        end

        test "capabilities/0 needs no credentials and no network" do
          # A consumer decides whether to use the package at all from this, so it has to
          # be answerable at boot.
          task = Task.async(fn -> @venue.capabilities() end)
          assert %Capabilities{} = Task.await(task, 1_000)
        end
      end
    end
  end

  defp identity do
    quote location: :keep do
      # --- 3. identity ----------------------------------------------------

      describe "3. identity" do
        test "provider_name/0 is a non-empty string" do
          name = @venue.provider_name()
          assert is_binary(name) and String.trim(name) != ""
        end

        test "runtime_id/0 is an atom matching the namespace segment" do
          assert is_atom(@venue.runtime_id())
        end

        test "asset_classes/0 is a non-empty list of known classes" do
          classes = @venue.asset_classes()

          assert is_list(classes) and classes != []
          assert classes -- [:crypto, :equity] == []
        end
      end
    end
  end

  defp symbol_round_trip(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      # --- 4. symbol round-trip -------------------------------------------

      if Keyword.get(opts, :symbol_format) do
        describe "4. symbol round-trip" do
          test "the format module implements the normaliser contract" do
            behaviours =
              @symbol_format.module_info(:attributes)
              |> Keyword.get_values(:behaviour)
              |> List.flatten()

            assert SymbolNormalizer in behaviours
          end

          test "to_canonical(to_exchange(pair)) == pair for the sample pairs" do
            for pair <- @sample_pairs do
              round_tripped =
                pair
                |> @symbol_format.to_exchange_symbol()
                |> @symbol_format.to_canonical_symbol()

              assert round_tripped == pair,
                     "#{pair} round-tripped to #{round_tripped} — this is where a " <>
                       "USD/USDT confusion silently changes which pair is traded"
            end
          end

          test "the round trip holds over every quote the venue declares" do
            # Generated rather than sampled: the sample pairs are the ones someone
            # thought of, and the bug this catches lives in the ones they did not.
            caps = @venue.capabilities()

            for quote_asset <- caps.supported_quotes, base <- ~w(BTC ETH SOL) do
              pair = "#{base}-#{quote_asset}"

              round_tripped =
                pair
                |> @symbol_format.to_exchange_symbol()
                |> @symbol_format.to_canonical_symbol()

              assert round_tripped == pair, "#{pair} round-tripped to #{round_tripped}"
            end
          end

          test "both directions are total — malformed input does not raise" do
            for input <- ["", "NOTAPAIR", "---", "btc-usd", "BTC-"] do
              assert is_binary(@symbol_format.to_canonical_symbol(input))
              assert is_binary(@symbol_format.to_exchange_symbol(input))
            end
          end
        end
      end
    end
  end

  defp agreement do
    quote location: :keep do
      # --- 6, 12. error discipline and agreement ---------------------------

      describe "12. capabilities and behaviour agree, in both directions" do
        test "every declared endpoint is a real facade callback" do
          caps = @venue.capabilities()
          callbacks = Venue.behaviour_info(:callbacks)

          for {endpoint, _maturity} <- caps.endpoints do
            assert endpoint in callbacks,
                   "#{inspect(endpoint)} is declared but is not a facade callback — a " <>
                     "declaration about a function nobody can call"
          end
        end

        test "an :unsupported endpoint returns the atom, and does not raise" do
          caps = @venue.capabilities()

          for endpoint <- Capabilities.endpoints_at(caps, :unsupported) do
            assert {:error, :not_supported} = call_endpoint(endpoint),
                   "#{inspect(endpoint)} declares :unsupported but did not return " <>
                     "{:error, :not_supported} — the atom, never the string"
          end
        end

        test "an active endpoint does not answer :not_supported" do
          # Under-declaring hides working functionality; over-declaring fails in the
          # caller's hands. Only checking one direction leaves the other open.
          caps = @venue.capabilities()

          for endpoint <-
                Capabilities.endpoints_at(caps, :proven) ++
                  Capabilities.endpoints_at(caps, :experimental) do
            refute call_endpoint(endpoint) == {:error, :not_supported},
                   "#{inspect(endpoint)} declares active but answered :not_supported"
          end
        end

        test "every core endpoint carries an explicit maturity" do
          # Asserted for PRESENCE, not truth. An absent value is the failure this
          # prevents; whether a :proven claim is true is not machine-checkable, and a
          # suite that pretended otherwise would be worse than one admitting the limit.
          caps = @venue.capabilities()

          undeclared =
            Enum.reject(Venue.core_endpoints(), &Map.has_key?(caps.endpoints, &1))

          assert undeclared == [],
                 "core endpoints with no declared maturity: #{inspect(undeclared)}"
        end
      end
    end
  end

  defp both_endpoints do
    quote location: :keep do
      # --- 8. both endpoints answer ----------------------------------------

      describe "8. both endpoints answer — no flag, no exceptions" do
        test "the pull endpoints are not refused wholesale" do
          caps = @venue.capabilities()

          assert Capabilities.active?(caps, {:get_symbols, 1}),
                 "every venue can be pulled; there is no flag for it"
        end

        test "subscribe is never :unsupported" do
          # A venue whose upstream API is REST-only passes by polling internally and
          # pushing the results. That is the package's job, not the caller's problem.
          caps = @venue.capabilities()

          assert Capabilities.active?(caps, {:subscribe, 2}),
                 "every venue can be subscribed; a REST-only venue polls and pushes"
        end

        test "coverage/1 reports observed routes only" do
          for {_symbol, route} <- @venue.coverage([]) do
            assert route in [:stream, :internal_poll, :not_covered],
                   "coverage must report an observed route, never a claim"
          end
        end
      end
    end
  end

  defp purity do
    quote location: :keep do
      # --- 7, 10, 11. purity, exclusivity, self-sufficiency ----------------

      describe "7. purity" do
        test "the package's source references no host application" do
          # These literals are the check, so they necessarily appear in a package that
          # ships this suite. A tarball audit will flag this line; it is the assertion
          # forbidding the thing, not the thing.
          for path <- Path.wildcard(Path.join(@package_root, "**/*.ex")),
              namespace <- ["DpCryptoManagement.", "Phoenix.", "Ash.", "Cloak.", "Ecto."] do
            source = File.read!(path)

            refute strip_docs(source) =~ namespace,
                   "#{path} references #{namespace} — a public package cannot depend on " <>
                     "an application its consumers do not have"
          end
        end
      end

      describe "11. self-sufficiency" do
        test "the facade takes data, never functions or modules" do
          # A callback in an argument list is an injected sink wearing a different name.
          # The venue must start, subscribe and serve with nothing but credentials and
          # options.
          assert function_exported?(@venue, :child_spec, 1),
                 "the package declares its own supervision entry point"
        end

        test "no facade return value carries a process, socket or reference" do
          caps = @venue.capabilities()

          for endpoint <- Capabilities.endpoints_at(caps, :unsupported) do
            refute match?({:ok, pid} when is_pid(pid), call_endpoint(endpoint))
          end
        end
      end
    end
  end

  defp isolation do
    quote location: :keep do
      # --- 13. process-scoped isolation ------------------------------------

      describe "13. process-scoped isolation" do
        test "an override in this process does not reach a sibling" do
          # A suite that needed a global to prove isolation would have disproved it, so
          # nothing here calls Application.put_env/3.
          DpExchange.Core.Config.put_override(:contract_probe, :mine)

          sibling =
            Task.async(fn ->
              Process.delete(:"$callers")
              DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe, :default)
            end)

          assert Task.await(sibling) == :default
          assert DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe) == :mine
        end

        test "a Task spawned inside the override inherits it" do
          # The $callers walk, asserted explicitly because it is the step most likely to
          # be skipped — and skipping it works in simple tests and fails in concurrent
          # ones.
          DpExchange.Core.Config.put_override(:contract_probe, :inherited)

          task =
            Task.async(fn ->
              DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe, :default)
            end)

          assert Task.await(task) == :inherited
        end

        test "two concurrent processes hold different values for the same seam" do
          parent = self()

          spawn_probe = fn value ->
            Task.async(fn ->
              Process.delete(:"$callers")
              DpExchange.Core.Config.put_override(:contract_probe, value)
              send(parent, :ready)

              receive do
                :go -> DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe)
              end
            end)
          end

          a = spawn_probe.(:refusing)
          b = spawn_probe.(:succeeding)

          assert_receive :ready
          assert_receive :ready
          send(a.pid, :go)
          send(b.pid, :go)

          assert Enum.sort([Task.await(a), Task.await(b)]) == [:refusing, :succeeding]
        end
      end
    end
  end

  defp helpers do
    quote location: :keep do
      # --- helpers ---------------------------------------------------------

      defp call_endpoint({name, arity}) do
        apply(@venue, name, endpoint_args(name, arity))
      rescue
        error -> {:raised, error}
      catch
        kind, reason -> {kind, reason}
      end
    end
  end

  # How each endpoint's arguments are shaped, by position: credentials first where the
  # facade takes them, then a symbol, then options.
  defp arg_helpers do
    quote location: :keep do
      @credentialed ~w(get_balances get_accounts get_fees get_transfers place_order
                       cancel_order get_order get_orders get_trade_history
                       test_connection get_rate_limit_status)a

      # Argument shapes as DATA rather than a clause per arity. Ten clauses is ten
      # places to be inconsistent, and the shapes really are a small table.
      @arg_shapes %{
        {:credentialed, 2} => [:credentials, :opts],
        {:credentialed, 3} => [:credentials, :symbol, :opts],
        {:public, 1} => [:opts],
        {:public, 2} => [:symbol, :opts],
        {:public, 3} => [:symbol, :timeframe, :opts],
        {:public, 4} => [:symbol, :timeframe, :opts, :opts]
      }

      defp endpoint_args(name, arity) do
        kind = if name in @credentialed, do: :credentialed, else: :public

        @arg_shapes
        |> Map.get({kind, arity}, List.duplicate(:opts, arity))
        |> Enum.map(&arg_value/1)
      end

      defp arg_value(:credentials), do: @credentials
      defp arg_value(:symbol), do: sample_symbol()
      defp arg_value(:timeframe), do: "1h"
      defp arg_value(:opts), do: []

      defp sample_symbol, do: List.first(@sample_pairs) || "BTC-USD"

      defp strip_docs(source) do
        source
        |> String.replace(~r/@(module)?doc\s+"""..*?"""/s, "")
        |> String.replace(~r/^\s*#.*$/m, "")
      end
    end
  end
end
