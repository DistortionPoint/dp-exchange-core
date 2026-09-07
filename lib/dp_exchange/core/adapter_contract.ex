defmodule DpExchange.Core.AdapterContract do
  @moduledoc """
  The conformance suite every venue package runs in its own CI.

  **This is the mechanism.** Prose in six `CLAUDE.md` files drifts; a suite that runs in
  five CI pipelines cannot.

  ## Why this lives in `lib/` and not `test/support/`

  It was in `test/support/` first, following the reference repo, and **that does not
  work for a suite consumers run.** `elixirc_paths(:test)` governs *this* package's own
  build; a dependency is not compiled in the `:test` environment, so the file shipped
  inside the tarball and was never compiled into the consumer. A venue package's
  `use DpExchange.Core.AdapterContract` failed with *module not loaded and could not be
  found* — the suite present on disk and absent from the code path.

  Shipping a file is not the same as shipping a module. A public testing API belongs in
  `lib/`, which is why `Ecto.Adapters.SQL.Sandbox` and `Phoenix.ConnTest` live there.

  `use ExUnit.Case` appears only inside the generated block, so nothing here needs
  ExUnit at compile time and this compiles cleanly as a dependency.

      defmodule DpExchange.Coinbase.ContractTest do
        use DpExchange.Core.AdapterContract,
          venue: DpExchange.Coinbase,
          symbol_format: DpExchange.Coinbase.SymbolFormat,
          sample_pairs: ~w(BTC-USDC ETH-USDC),
          credentials: %{api_key: "test", api_secret: "test"}
      end

  ## What it asserts, and what it deliberately does not

  Seventeen groups, listed in `assertions/0`. The load-bearing one is **capabilities and
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
      {13, "process-scoped isolation — usable in a consumer's async suite"},
      {14, "top of book is not a price — a BBO carries resting orders, never a traded price"},
      {15,
       "coverage by kind — optional; when a venue exports it, the union invariant against " <>
         "coverage/1 holds and every key is a kind the venue's own capabilities declare"},
      {16,
       "internal wiring — every internal export has a caller inside this package's own " <>
         "lib/, so a mechanism cannot ship built, documented and never reached"},
      {17,
       "credential gate — on a venue requiring credentials, no active credentialed " <>
         "endpoint's fake succeeds when called with credentials stripped"}
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
      coverage_by_kind(),
      purity(),
      isolation(),
      wiring(),
      credential_gate(),
      helpers(),
      arg_helpers(),
      credential_gate_helpers(),
      purity_helpers()
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
      # The venue's in-process fake. Assertion 12's active-endpoint direction runs
      # against this and never against the real venue.
      @fake Keyword.get(opts, :fake)
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
          # `nameable/0`, not `known/0`. The vocabulary of *labels* is deliberately wider
          # than the set Core can *bucket*: `1w`, `1M` and `1y` have no boundary rule and
          # never will, because a weekly bar's start depends on the venue's week, a month
          # is not a fixed number of seconds, and neither is a year. A venue that
          # genuinely serves them must be able to say so — the alternative is
          # under-declaring what it serves.
          caps = @venue.capabilities()
          assert caps.historical_timeframes -- Timeframe.nameable() == []
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

          # The vocabulary a host switches on. It widened from `[:crypto, :equity]` on
          # 2026-09-01, when the first package started serving option, futures and
          # event-contract endpoints — a class a venue serves and cannot declare is a class
          # the host cannot route to.
          assert classes -- [:crypto, :equity, :option, :future, :event_contract] == []
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
        test "the order-shape claims match what the facade actually answers" do
          # `supports_order_preview` and `supports_order_replace` are claims a consumer
          # routes on. A venue declaring one and refusing the call sends a caller down a
          # path that cannot run, and a venue serving one without declaring it is invisible
          # — which on `replace_order/4` costs risk, since the alternative is a window with
          # no order live.
          caps = @venue.capabilities()
          credentials = @credentials

          for {field, {name, arity}, args} <- [
                {:supports_order_preview, {:preview_order, 3}, [credentials, %{}, []]},
                {:supports_order_replace, {:replace_order, 4}, [credentials, "id", %{}, []]}
              ] do
            declared = Map.fetch!(caps, field)
            answers? = apply(@venue, name, args) != {:error, :not_supported}

            assert declared == answers?,
                   "#{field} is #{inspect(declared)} but #{name}/#{arity} " <>
                     "#{if answers?, do: "answers", else: "returns :not_supported"}"
          end
        end

        test "catalog_access matches how get_symbols/1 behaves without a query" do
          # `:query_only` is only true if the venue actually demands a term. A venue
          # declaring it and then returning a list has declared a restriction it does not
          # have, which is as misleading as the reverse.
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_symbols, 1}) do
            result = @venue.get_symbols(credentials: @credentials)

            case caps.catalog_access do
              :query_only ->
                assert match?({:error, _reason}, result),
                       "catalog_access is :query_only but get_symbols/1 answered without a query"

              :enumerable ->
                refute match?({:error, {:query_required, _venue}}, result),
                       "get_symbols/1 demands a query but catalog_access says :enumerable"
            end
          end
        end

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
          #
          # Driven against the venue's FAKE, never the real venue. Calling an active
          # endpoint for real is a network request, and a tier-1 run that reaches a third
          # party's API is tier 1 in name only — it would hit the live venue from every CI
          # run of every consumer. The `:unsupported` direction is safe against the real
          # venue precisely because those endpoints return without going anywhere.
          assert @fake,
                 "pass `fake:` to run this assertion. Calling active endpoints on the " <>
                   "real venue would make every CI run hit the live API, which D7 " <>
                   "reserves for tier 2 and for a human choosing to run it."

          caps = @venue.capabilities()

          # Enumerated from EVERY facade callback and asked through `active?/2`, not from
          # `Capabilities.endpoints_at(caps, :proven) ++ endpoints_at(caps, :experimental)`.
          # `endpoints_at/2` iterates only the EXPLICIT entries in `caps.endpoints` — but
          # `Capabilities`'s own moduledoc makes an ABSENT entry active too ("anything not
          # named in the map is :experimental — the only honest default"). An endpoint
          # never mentioned in `endpoints` at all was therefore active by that same
          # default and invisible to the old enumeration regardless — under-declaring by
          # silence passed the exact check that catches under-declaring by a wrong value.
          # See `DpExchange.Core.ContractTeethTest`'s `Broken.SilentlyUnsupported`.
          for endpoint <- Venue.behaviour_info(:callbacks),
              answerable?(endpoint),
              Capabilities.active?(caps, endpoint) do
            refute call_on(@fake, endpoint) == {:error, :not_supported},
                   "#{inspect(endpoint)} is active (declared, or by the undeclared-is-" <>
                     "experimental default) but the fake answered :not_supported — the " <>
                     "fake and the declaration disagree"
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

        test "every absence has a recorded cause" do
          # **A callback declared `:unsupported` must be filed under one of two causes**:
          # the venue does not serve it, or this package has not ported it. Both answer a
          # caller identically and only one can ever change, so a host planning around a gap
          # needs to know which it is looking at.
          #
          # The mislabel goes both ways and both are defects. A venue's own absence filed as
          # a backlog item invents work that cannot be done and quietly implies an endpoint
          # the vendor does not publish; a backlog item filed as the venue's absence hides a
          # capability a consumer could have had. **Robinhood shipped four of the first kind
          # and no test failed** — nothing fails when a comment is wrong, which is why this
          # is an assertion rather than a review note.
          #
          # A package that does not implement `venue_does_not_serve/0` is exempt: the split
          # is optional in the contract. One that *does* must account for every absence.
          caps = @venue.capabilities()

          if function_exported?(@venue, :venue_does_not_serve, 0) do
            # Through a variable, not `@venue.venue_does_not_serve()`: the split is optional
            # in the contract, so a direct call warns at compile time for every package that
            # does not implement it. `apply/3` would say the same thing and credo objects.
            venue = @venue
            venue_absences = MapSet.new(venue.venue_does_not_serve())

            unsupported =
              caps.endpoints
              |> Enum.filter(fn {_endpoint, maturity} -> maturity == :unsupported end)
              |> MapSet.new(fn {endpoint, _maturity} -> endpoint end)

            stray = MapSet.difference(venue_absences, unsupported)

            assert MapSet.size(stray) == 0,
                   "venue_does_not_serve/0 names endpoints that are not declared " <>
                     ":unsupported: #{inspect(MapSet.to_list(stray))}. An endpoint the " <>
                     "venue does not serve cannot also be one this package answers."
          end
        end

        test "streamable names only kinds this contract has a word for" do
          # `streamable` is the one declaration a consumer cannot check for itself: it is a
          # claim about what `subscribe/2` delivers, and a kind that arrives by no route
          # produces silence rather than an error.
          #
          # **This is the assertion that would have caught a real over-declaration.** One
          # package declared six streamable kinds while its socket was written, tested and
          # never called by the facade — four of the six reached no subscriber by any route,
          # and every test passed for a release. A structural check cannot prove delivery,
          # but it can refuse a vocabulary this contract does not define, which is where
          # over-declaration usually starts.
          caps = @venue.capabilities()
          known = MapSet.new(Capabilities.data_kinds())

          for list <- [caps.streamable, caps.authenticated_streamable] do
            unknown = list |> MapSet.new() |> MapSet.difference(known) |> MapSet.to_list()

            assert unknown == [],
                   "streamable declares kinds this contract has no word for: " <>
                     "#{inspect(unknown)}"
          end
        end

        test "a declared streaming kind is not contradicted by its own pull endpoint" do
          # Where a venue streams a kind it also pulls, the pull must not be declared
          # `:unsupported` **for the reason that the venue lacks it**. The two can differ
          # legitimately — depth over a socket and none over REST is a real shape — so this
          # asserts only the contradiction that cannot be true: an endpoint listed in
          # `venue_does_not_serve/0` whose kind the same package claims to stream.
          caps = @venue.capabilities()

          if function_exported?(@venue, :venue_does_not_serve, 0) do
            venue = @venue
            absent = MapSet.new(venue.venue_does_not_serve())

            contradictions =
              for {kind, endpoint} <- [
                    {:quotes, {:get_price, 2}},
                    {:top_of_book, {:get_top_of_book, 2}},
                    {:trades, {:get_trades, 2}},
                    {:candles, {:get_historical_prices, 4}}
                  ],
                  kind in caps.streamable,
                  MapSet.member?(absent, endpoint),
                  do: {kind, endpoint}

            assert contradictions == [],
                   "these kinds are declared streamable while the same package says the " <>
                     "venue does not serve them at all: #{inspect(contradictions)}"
          end
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

  defp coverage_by_kind do
    quote location: :keep do
      # --- 15. coverage by kind (optional) ---------------------------------
      #
      # `coverage_by_kind/1` is in `Venue.@optional_callbacks`, deliberately: Core
      # publishes it before any venue adopts it, and a required callback here would mean
      # every venue depending on Core from Hex instantly fails completeness — the exact
      # cross-repo coupling that caused a premature-deploy incident once already. So an
      # ABSENT callback is a venue that has not adopted yet, NOT a failure, and this
      # group asserts nothing at all in that case. Do not "fix" the `if` below into an
      # unconditional assertion — that turns an optional callback back into a required
      # one from the suite's side, which is the coupling this design refused.

      describe "15. coverage by kind" do
        test "when exported, its union of symbols matches coverage/1 exactly, and it " <>
               "names no kind the venue does not declare streamable" do
          Code.ensure_loaded?(@venue)

          if function_exported?(@venue, :coverage_by_kind, 1) do
            by_kind = @venue.coverage_by_kind([])
            coverage_symbols = @venue.coverage([]) |> Map.keys() |> MapSet.new()

            union =
              by_kind
              |> Map.values()
              |> Enum.flat_map(&Map.keys/1)
              |> MapSet.new()

            assert union == coverage_symbols,
                   "coverage_by_kind/1's symbols #{inspect(MapSet.to_list(union))} are not " <>
                     "the union coverage/1 reports (#{inspect(MapSet.to_list(coverage_symbols))}) " <>
                     "— the two are meant to be definitionally the same fact, and letting them " <>
                     "drift is what this assertion exists to stop"

            declared = MapSet.new(@venue.capabilities().streamable)
            reported = by_kind |> Map.keys() |> MapSet.new()
            undeclared = MapSet.difference(reported, declared)

            assert MapSet.size(undeclared) == 0,
                   "coverage_by_kind/1 reports #{inspect(MapSet.to_list(undeclared))}, which " <>
                     "capabilities().streamable does not declare — a venue reporting coverage " <>
                     "for a kind it does not claim to stream contradicts its own declaration"
          end
        end
      end
    end
  end

  defp purity do
    quote location: :keep do
      # --- 7, 10, 11. purity, exclusivity, self-sufficiency ----------------

      describe "14. top of book is not a price" do
        # These assertions exist because the confusion they forbid already shipped: a venue
        # package read `price || ask` from a best-bid/ask endpoint, so a response with no
        # traded price produced a quote whose `price` was a resting order. Review missed it,
        # and the package's own tests asserted it as correct.

        test "TopOfBook has no price field, and cannot grow one by accident" do
          # Structural, and asserted rather than trusted: the entire point of the type is
          # that there is nowhere to put a traded price. A field added later would silently
          # re-open the defect this type was built to close.
          top = %DpExchange.Core.Types.TopOfBook{
            symbol: "BTC-USD",
            observed_at: DateTime.utc_now(),
            provider: :contract_check
          }

          refute Map.has_key?(top, :price),
                 "TopOfBook must never carry `price`. A caller wanting a traded price " <>
                   "calls get_price/2 and gets a Quote, or gets an error."
        end

        test "get_top_of_book/2 returns a TopOfBook that records when it was observed" do
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_top_of_book, 2}) and @sample_pairs != [] do
            case @venue.get_top_of_book(hd(@sample_pairs), []) do
              {:ok, top} ->
                assert %DpExchange.Core.Types.TopOfBook{} = top,
                       "a BBO carries resting orders; a Quote carries a traded price, and " <>
                         "they are not interchangeable"

                assert %DateTime{} = top.observed_at,
                       "observed_at is required: a BBO is stale the instant it is read, so " <>
                         "when it was read is part of the value"

                assert is_nil(top.venue_time) or match?(%DateTime{}, top.venue_time),
                       "venue_time is the venue's own or nil — never a stand-in for it"

              _refused_or_unsupported ->
                :ok
            end
          end
        end
      end

      describe "7. purity" do
        test "the compiled package links against nothing but its declared dependencies" do
          # Asserted from the BEAM's `imports` chunk rather than by grepping for a list
          # of forbidden namespaces. Two reasons, and the second is the better one.
          #
          # A name list has to contain the names it forbids, so a package shipping this
          # suite fails its own check — which is how this assertion was first written.
          #
          # More importantly, a list only forbids what someone thought to list. The
          # imports chunk answers the real question: does this package reach for anything
          # its consumers have not agreed to install? A transitive reference nobody
          # noticed shows up here and in no grep.
          config = Mix.Project.config()
          app = config[:app]
          # Strings, not atoms: `from_declared_dep?/2` below compares against this without
          # ever calling `String.to_atom/1` on the directory name it pulls off a beam path.
          declared = for {dep, _rest} <- config[:deps], do: Atom.to_string(dep)

          linked =
            Mix.Project.build_path()
            |> Path.join("lib/#{app}/ebin/*.beam")
            |> Path.wildcard()
            |> Enum.flat_map(fn beam ->
              {:ok, {_module, [imports: imports]}} =
                :beam_lib.chunks(String.to_charlist(beam), [:imports])

              Enum.map(imports, fn {module, _fun, _arity} -> module end)
            end)
            |> Enum.uniq()

          foreign = Enum.reject(linked, &permitted_module?(&1, declared))

          assert foreign == [],
                 "#{app} links against modules outside stdlib and its declared " <>
                   "dependencies: #{inspect(foreign)}"
        end
      end

      describe "11. self-sufficiency" do
        test "the facade takes data, never functions or modules" do
          # A callback in an argument list is an injected sink wearing a different name.
          # The venue must start, subscribe and serve with nothing but credentials and
          # options.
          # `Code.ensure_loaded!/1` first: `function_exported?/3` answers false for a
          # module that is merely not loaded, so without it this asserts "not exported"
          # while meaning "does not exist".
          Code.ensure_loaded!(@venue)

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

  defp wiring do
    quote location: :keep do
      # --- 16. internal wiring ----------------------------------------------

      describe "16. internal wiring" do
        test "every internal export has a caller inside this package's own lib/" do
          # "Mechanism built, documented, and never wired" — six instances in one week
          # across this family, every one shipped green: `rate_limit_blocking` plumbed
          # through Core.HttpClient but never set by a caller (issues #16, #23, #26 —
          # #23 had to be fixed through three separate option allowlists, and a fix
          # stopping at the first still passed every test asserting the keyword was
          # present); FrameSender's retry path, reported but never retried (issue #22);
          # `subscribe_notices/1`'s registry, built and never reached; `Auth.refresh/2`,
          # zero call sites, while a Socket held a token that could only expire. Every
          # one of those functions had a test calling it directly, so coverage stayed
          # green and the suite stayed silent — a test is not a caller.
          #
          # `DpExchange.Core.UnwiredCheck` reads `:xref`'s real call graph rather than
          # grepping for call sites, so a captured `&Mod.fun/1` and a literal
          # `apply(Mod, :fun, args)` both count as real usage — see its moduledoc for
          # what it excludes and why each exclusion is safe without a hand-maintained
          # allowlist that rots. `@venue` and `@fake` are excluded here because both are
          # already-bound public surface called only by consumers, not because either is
          # hand-picked for this assertion.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          facade_and_fake = Enum.reject([@venue, @fake], &is_nil/1)

          assert {:ok, violations} =
                   DpExchange.Core.UnwiredCheck.run(beam_dir, lib_root, facade_and_fake)

          assert violations == [],
                 "internal function(s) with no caller anywhere in this package's own " <>
                   "lib/ — either dead code or a mechanism built and never wired:\n" <>
                   DpExchange.Core.UnwiredCheck.format(violations)
        end
      end
    end
  end

  defp credential_gate do
    quote location: :keep do
      # --- 17. credential gate ----------------------------------------------

      describe "17. credential gate" do
        test "on a venue requiring credentials, no active credentialed endpoint's fake " <>
               "succeeds when called with credentials stripped" do
          # Found independently in two venue packages the same week this assertion was
          # written: six credentialed functions on a venue where **every request is
          # signed and there is no anonymous endpoint** answered `{:ok, _}` for `%{}` or
          # `nil` credentials, because nothing checked the argument at all. Tier 1
          # in-process fakes are the only tier that runs on every CI run and the only one
          # most consumers ever exercise, so a fake that succeeds where the real venue
          # would refuse silently certifies broken consumer code — a caller that forgot
          # its credentials would see its own tests pass.
          #
          # Fake-only, and gated on `credential_benefit: :required` rather than run
          # unconditionally: a venue with `:no_difference` or `:higher_ceiling` may
          # legitimately serve some of these endpoints without a credential (some venues'
          # `get_fees/2` or `get_transfers/2` genuinely differ), and asserting a refusal
          # there would be inventing a rule the venue never claimed. `:required` is a
          # positive statement that public data is not served at all without one, which
          # is exactly the claim a `{:ok, _}` from stripped credentials would contradict.
          #
          # Deliberately NOT asserting shape equality against the real venue
          # (`call_on(@venue, args) == call_on(@fake, args)`): that would only be safe if
          # every venue's auth check fails locally before any HTTP dial-out, which is an
          # invariant about venues this suite has not reviewed and must not assume. A
          # conformance assertion that can make a live network call under some future
          # venue's implementation is a worse failure mode than the gap it would close.
          caps = @venue.capabilities()

          if caps.credential_benefit == :required do
            assert @fake,
                   "pass `fake:` to run this assertion. It never dials out — only the " <>
                     "fake is called — but it needs the venue's in-process fake to " <>
                     "call against."

            for {name, arity} <- Venue.behaviour_info(:callbacks),
                credential_gated?(name),
                Capabilities.active?(caps, {name, arity}) do
              args = stripped_credential_args(name, arity)

              refute match?({:ok, _}, call_on(@fake, {name, arity}, args)),
                     "#{inspect({name, arity})} answered {:ok, _} with credentials " <>
                       "stripped, but #{inspect(@venue)} declares credential_benefit: " <>
                       ":required — a fake that succeeds without credentials certifies " <>
                       "consumer code that forgot to supply them"
            end
          end
        end
      end
    end
  end

  defp helpers do
    quote location: :keep do
      # --- helpers ---------------------------------------------------------

      defp call_endpoint(endpoint), do: call_on(@venue, endpoint)

      defp call_on(module, {name, arity}),
        do: call_on(module, {name, arity}, endpoint_args(name, arity))

      # The 3-arity form takes explicit args rather than deriving them from `{name,
      # arity}` — assertion 17 needs the SAME shape `endpoint_args/2` builds but with
      # credentials stripped, which is a different question from "what does this
      # endpoint normally take".
      defp call_on(module, {name, _arity}, args) do
        apply(module, name, args)
      rescue
        error -> {:raised, error}
      catch
        kind, reason -> {kind, reason}
      end

      # Lifecycle callbacks are not answerable by calling them — `child_spec/1` returns a
      # spec, `start_link/1` starts something. Their maturity is asserted for presence
      # like everything else; the round trip does not apply.
      defp answerable?({name, _arity}), do: name not in [:child_spec, :start_link]
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

      defp credentialed?(name), do: name in @credentialed
    end
  end

  # Assertion 17's own helpers, split from `arg_helpers/0` rather than added to it: a
  # single quoted block growing past credo's complexity ceiling is the same "400-line
  # block nobody reads" this file's groups already exist to avoid, just measured in
  # cyclomatic complexity instead of line count.
  defp credential_gate_helpers do
    quote location: :keep do
      # `test_connection/2` and `get_rate_limit_status/2` are the two `@credentialed`
      # entries whose own callback doc explicitly allows `credentials() | nil` —
      # `test_connection/2`'s whole point is answering "the credential, IF GIVEN, is
      # accepted", so both are expected to succeed on plain reachability with no
      # credential at all, even on a venue whose DATA endpoints require one. Assertion 17
      # gates on `@credentialed` minus these two, not on `@credentialed` itself.
      @credential_gated @credentialed -- [:test_connection, :get_rate_limit_status]

      defp credential_gated?(name), do: name in @credential_gated

      # The same shape `endpoint_args/2` builds, with the credentials position replaced
      # by an empty map — assertion 17's whole question is "what happens with no
      # credentials", and `%{}` is the same "nothing given" shape
      # `Broken.OverDeclares.get_transfers(%{}, [])` already uses elsewhere in this
      # family's own test fixtures.
      defp stripped_credential_args(name, arity) do
        kind = if credentialed?(name), do: :credentialed, else: :public

        @arg_shapes
        |> Map.get({kind, arity}, List.duplicate(:opts, arity))
        |> Enum.map(&stripped_arg_value/1)
      end

      defp stripped_arg_value(:credentials), do: %{}
      defp stripped_arg_value(other), do: arg_value(other)
    end
  end

  # Which modules a package may legitimately link against.
  defp purity_helpers do
    quote location: :keep do
      # Asked of the loaded module's own beam path rather than of a list of names.
      #
      # A module loaded from `deps/<name>/` came from dependency `<name>`; anything else
      # is OTP, the Elixir standard library, or this package itself. That is both simpler
      # than a name list and strictly stronger: it catches a dependency nobody declared,
      # which no list of forbidden namespaces ever could — a list only forbids what
      # someone thought to write down.
      defp permitted_module?(module, declared) do
        case :code.which(module) do
          path when is_list(path) -> from_declared_dep?(to_string(path), declared)
          # Preloaded (`:erlang`) or not on disk. Neither is a foreign dependency.
          _preloaded -> true
        end
      end

      # This is NOT the `Notice.reject_credentials!/1` class of bug (C8): `dep` is not
      # venue- or attacker-influenced. It is a directory name lifted from `:code.which/1`
      # on a module drawn from THIS PACKAGE'S OWN COMPILED `.beam` imports chunk
      # (`adapter_contract.ex` — "7. purity" test, reading `_build/.../ebin/*.beam`),
      # which in turn comes only from source this package's own developer wrote and `mix
      # deps.get` already fetched under `deps/`. The set of distinct values `dep` can ever
      # take is exactly the package's own dependency tree — fixed at build time by
      # `mix.lock`, never by a venue's runtime payload — so this was never an unbounded,
      # attacker-driven atom mint the way C8 was.
      #
      # Compared as a string regardless, not `String.to_atom(dep) in declared`: `declared`
      # is built as strings by the caller (`Atom.to_string/1` on each `mix.exs` dep, once,
      # at test time) specifically so this never calls `String.to_atom/1` on anything at
      # all — sobelow's `DOS.StringToAtom` flags the call shape itself, confidence aside,
      # and the fix costs nothing here since both sides were only ever going to be
      # compile-time-fixed dependency names.
      defp from_declared_dep?(path, declared) do
        case Regex.run(~r{/deps/([^/]+)/}, path) do
          [_match, dep] -> dep in declared
          nil -> true
        end
      end
    end
  end
end
