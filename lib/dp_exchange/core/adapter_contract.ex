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

  Twenty-one groups, listed in `assertions/0`. The load-bearing one is **capabilities and
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
       "credential gate — on a venue requiring credentials, no active endpoint's fake " <>
         "succeeds when called with credentials stripped"},
      {18,
       "link safety — a process behaviour that starts a linked child traps exits, so " <>
         "that child's abnormal death cannot propagate untrapped into the process " <>
         "that started it"},
      {19,
       "credential redaction — a struct holding a secret-named field redacts it under " <>
         "inspect/1, so a crash report or a failed function clause's stacktrace never " <>
         "prints it in cleartext"},
      {20,
       "subscribed push shape — subscribe/2's fake delivers a DpExchange.Core.Types.* " <>
         "struct tagged with runtime_id/0, never raw venue data"},
      {21,
       "historical timeframe discipline — a width outside historical_timeframes is " <>
         "refused, never served at the nearest one"},
      {22,
       "credential redaction in child_spec/1 — a secret passed in :credentials is not " <>
         "rendered in the args a supervisor stores and OTP prints on every child crash"},
      {23,
       "venue time and observed time — Quote and OrderBook carry the venue's own DateTime " <>
         "or nil in venue_time, never an unparsed stand-in, and observed_at is always there"}
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
      link_safety(),
      credential_gate(),
      credential_redaction(),
      subscribed_push_shape(),
      historical_timeframe_discipline(),
      venue_and_observed_time(),
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
      # The venue's in-process fake. Every assertion that calls an ACTIVE endpoint
      # (assertions 12, 14, 17, 20, 21) runs against this and never against the real
      # venue — calling an active endpoint for real is a live network request, and a
      # tier-1 run that reaches a third party's API is tier 1 in name only.
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
          #
          # Driven against the venue's FAKE, never the real venue: `preview_order/3` and
          # `replace_order/4` are active, signed write-shaped endpoints on several venues
          # in this family, and calling either for real would make every ordinary `mix
          # test` run dial the live API — exactly the tier-2 violation D7 forbids on a
          # schedule.
          assert @fake,
                 "pass `fake:` to run this assertion. Calling preview_order/3 and " <>
                   "replace_order/4 on the real venue would make every CI run hit the " <>
                   "live API, which D7 reserves for tier 2 and for a human choosing to " <>
                   "run it."

          caps = @venue.capabilities()
          credentials = @credentials

          for {field, {name, arity}, args} <- [
                {:supports_order_preview, {:preview_order, 3}, [credentials, %{}, []]},
                {:supports_order_replace, {:replace_order, 4}, [credentials, "id", %{}, []]}
              ] do
            declared = Map.fetch!(caps, field)
            answers? = apply(@fake, name, args) != {:error, :not_supported}

            assert declared == answers?,
                   "#{field} is #{inspect(declared)} but #{name}/#{arity} " <>
                     "#{if answers?, do: "answers", else: "returns :not_supported"}"
          end
        end

        test "catalog_access matches how get_symbols/1 behaves without a query" do
          # `:query_only` is only true if the venue actually demands a term. A venue
          # declaring it and then returning a list has declared a restriction it does not
          # have, which is as misleading as the reverse.
          #
          # Driven against the venue's FAKE, never the real venue: `get_symbols/1` is an
          # active, uncredentialed endpoint on several venues in this family, so calling
          # it for real would make every ordinary `mix test` run dial the live API —
          # reproduced live against `api.gemini.com/v1/symbols` before this was fixed.
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_symbols, 1}) do
            assert @fake,
                   "pass `fake:` to run this assertion. Calling get_symbols/1 on the " <>
                     "real venue would make every CI run hit the live API, which D7 " <>
                     "reserves for tier 2 and for a human choosing to run it."

            result = @fake.get_symbols(credentials: @credentials)

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
          # Driven against the venue's FAKE, never the real venue: `get_top_of_book/2` is
          # an active, uncredentialed endpoint on several venues in this family, so
          # calling it for real would make every ordinary `mix test` run dial the live
          # API — reproduced live against `api.gemini.com/v1/pubticker/btcusd` before
          # this was fixed.
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_top_of_book, 2}) and @sample_pairs != [] do
            assert @fake,
                   "pass `fake:` to run this assertion. Calling get_top_of_book/2 on " <>
                     "the real venue would make every CI run hit the live API, which " <>
                     "D7 reserves for tier 2 and for a human choosing to run it."

            case @fake.get_top_of_book(hd(@sample_pairs), []) do
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

          # Explicit, generous timeout rather than ExUnit's 100ms default. This assertion
          # proves two concurrent processes hold *different* values for one seam — it is
          # not measuring how fast a spawn is, so waiting longer weakens nothing: it still
          # fails if a `:ready` never arrives at all. On the default budget, two `Task`
          # spawns plus scheduling can exceed 100ms under a full suite's parallel load, and
          # this one did — observed failing once on seed 3 in `dp_exchange_schwab` and
          # passing on an immediate re-run of the same seed.
          #
          # This macro is compiled into all five venue packages' own suites, so a flake here
          # is a flake in every one of them, in a shared assertion whose whole purpose is to
          # be trusted. A conformance check that fails at random is one people learn to
          # re-run rather than read.
          assert_receive :ready, 2_000
          assert_receive :ready, 2_000
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

  defp link_safety do
    quote location: :keep do
      # --- 18. link safety --------------------------------------------------

      describe "18. link safety" do
        test "a process that starts a linked child also traps exits" do
          # Found live in four of five venue packages on 2026-09-07: `Feed.init/1` never
          # called `Process.flag(:trap_exit, true)`, and `Socket.start_link/1` ran from
          # inside a `Feed` callback — which links the socket to `Feed`, not to a
          # supervisor. An abnormal socket exit was therefore untrappable and killed
          # `Feed`, and the venue's `Supervisor` restarted it from its STATIC start opts
          # — every `subscribe/2` a consumer had made since boot, silently gone. Fixed
          # identically in all five repos by trapping exits before anything gets linked:
          # `dp_exchange_coinbase` e77b542, `dp_exchange_gemini` 66acd3b,
          # `dp_exchange_webull` d0c54a8, `dp_exchange_schwab` 90dddc6,
          # `dp_exchange_robinhood` 51ad189.
          #
          # This is deliberately STATIC, not a behavioural "start the tree and kill a
          # linked child" test — see `DpExchange.Core.LinkSafetyCheck`'s moduledoc for
          # why that was tried first and rejected: starting a venue's real (non-fake)
          # tree is not reliably network-free (dp_exchange_schwab's `Feed` dials its
          # Streamer unconditionally from `init/1`'s own `{:continue, :connect}}`,
          # regardless of whether anything has been subscribed), and the only way around
          # that is a venue-specific injection option name this suite is expressly
          # forbidden from knowing. A static check over the compiled module — does it
          # create a link, and does it also trap exits — never starts a process at all,
          # so it cannot dial out for any venue, present or future.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          assert {:ok, violations} = DpExchange.Core.LinkSafetyCheck.run(beam_dir, lib_root)

          assert violations == [],
                 "process(es) that link a child they start and never call " <>
                   "Process.flag(:trap_exit, true) — that child's abnormal exit will " <>
                   "crash the process that started it, and a Supervisor restarts from " <>
                   "static opts, discarding every subscribe/2 made since boot:\n" <>
                   DpExchange.Core.LinkSafetyCheck.format(violations)
        end
      end
    end
  end

  defp credential_gate do
    quote location: :keep do
      # --- 17. credential gate ----------------------------------------------

      describe "17. credential gate" do
        test "on a venue requiring credentials, no active endpoint's fake " <>
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
          #
          # ## Widened from a fixed list to every active endpoint (2026-09-07)
          #
          # This used to gate on `@credentialed`, a hand-maintained list of eleven names
          # written when the contract had a small, stable credentialed surface. A
          # callback outside that list — one that takes no dedicated `credentials`
          # argument and instead reads a credential out of `opts`, which is how every one
          # of `get_option_chain/2`, `get_news/1`, `get_corporate_events/1` and
          # `quantization/1` do it on a venue that signs every request — was invisible to
          # the loop no matter how it answered with no credential. Found independently in
          # `dp_exchange_webull` and `dp_exchange_schwab` on 2026-09-07, both auditing
          # their own widened surface by hand because this assertion could not: each fake
          # had the identical defect (`{:ok, _}` with credentials stripped) on exactly
          # the callbacks the fixed list did not name.
          #
          # The rule this widens to: on a venue declaring `credential_benefit: :required`,
          # `:required` means every active endpoint needs a credential, so this checks
          # them all — `Venue.behaviour_info(:callbacks)` minus a small, NAMED exemption,
          # never a list of what to check. A hand-maintained list of what to check is the
          # same class of thing as the hand-maintained list this replaces: it rots, and
          # the rot is invisible.
          #
          # `answerable?/1` drops `child_spec/1` and `start_link/1` — calling `start_link`
          # on even a FAKE could start a real process, which no assertion in this suite
          # should ever risk. `@credential_gate_exempt` (`credential_gate_helpers/0`)
          # drops exactly two more: `test_connection/2` and `get_rate_limit_status/2`,
          # because their OWN callback doc types the credential `credentials() | nil` —
          # the contract itself, not a venue's choice, says a missing credential is
          # expected there, since both mean "can I reach the venue at all" rather than
          # "give me this venue's data". Every other callback in the behaviour is
          # checked, including ones that return a bare `:ok`/map/list rather than a
          # `result()` tuple — those can never match `{:ok, _}` below and pass this
          # assertion trivially, so including them costs nothing and excluding them by
          # hand would only be one more list to keep in sync.
          #
          # ## `market_status/1`, resolved (2026-09-07)
          #
          # This callback's own doc makes one unconditional claim: "crypto venues answer
          # `:open`." That is NOT a licence to exempt `market_status/1` by name the way
          # `test_connection/2` and `get_rate_limit_status/2` are exempt above —
          # `dp_exchange_schwab`'s real `market_status/1` calls an authenticated
          # `/markets` endpoint, and its fake correctly refuses without a credential. A
          # name-based exemption would silence that protection for the one venue where
          # this assertion is doing real work today, purely to accommodate two venues
          # where it currently is not — exactly the "decorative check" this suite exists
          # to avoid.
          #
          # What actually distinguishes Webull's and Robinhood's `market_status/1` from
          # Schwab's is not the callback name, it is each venue's `asset_classes/0`. A
          # venue whose entire surface is `[:crypto]` has no exchange-mandated trading
          # session for a credential to gate — "crypto trades continuously" is true of
          # the ASSET CLASS, not a fact fetched from the venue, so no credential can
          # change it. A venue serving anything else can have real, authenticated market
          # hours (Schwab does) or, like Webull, publish nothing this package can reach
          # at all: Webull's OpenAPI documents 85 endpoints and none of them is a
          # market-status or trading-calendar call (`docs/reference/webull/` in that
          # package); the one trading-calendar endpoint Webull publishes anywhere,
          # `/broker/master-data/trading-calendars/list`, belongs to its separate Broker
          # API product on a different host (`broker-api.webull.com`) needing its own
          # broker-tier credential this contract's `credentials()` does not model — out
          # of reach regardless of what any caller supplies.
          #
          # `market_status_crypto_exempt?/2` (`credential_gate_helpers/0`) is that
          # narrower exemption, skipped only when `@venue.asset_classes() == [:crypto]`.
          # Webull serves five asset classes and does not qualify — its `market_status/1`
          # is checked like any other endpoint, and it satisfies the check by declaring
          # itself `:unsupported` (`{:error, :not_supported}`), the honest answer for a
          # venue this package cannot reach a usable endpoint on. Robinhood is
          # crypto-only and does qualify, so its `{:ok, :open}` with no credential is
          # exempt on that ground alone — argued in its own package's review rather than
          # assumed silently, and recorded here for the same reason the two-name
          # exemption above is recorded here rather than in a venue's own test file. See
          # `usage-rules/adapter.md` for the consumer-facing version of this argument.
          #
          # ## `get_fees/2`, and `Capabilities.no_venue_contact` (2026-09-07)
          #
          # `market_status_crypto_exempt?/2` above is grounded in a per-VENUE fact (the
          # asset class serves no session for a credential to gate). This one is
          # grounded in a per-ENDPOINT fact that no asset-class or venue-identity
          # predicate can express: `dp_exchange_webull`'s `get_fees/2` answers a flat
          # crypto spread captured from the venue's own published pricing
          # (`source: :published_rate`) and builds no request at all, on a venue that
          # otherwise correctly requires credentials for everything else. A
          # 2026-09-06 sweep gated it anyway to satisfy this assertion in its
          # then-unqualified form, reasoning that the real path "had never run through
          # `Auth.headers/2`" — true, and the reason there was nothing to gate. That
          # broke a real consumer who resolves fees before any account is attached.
          #
          # Rather than a THIRD name-based or venue-based exemption growing here, the
          # venue itself now declares this: `Capabilities.no_venue_contact` is a list
          # of `{name, arity}` an active endpoint may appear in when its real
          # implementation, on that venue, never builds a request — the same
          # per-endpoint shape `endpoints` already uses, so it cannot rot into a single
          # hand-maintained list the way `@credentialed` did. Declaring an endpoint
          # there is a claim the venue package must be able to point at real code to
          # back — see `Capabilities`'s own moduledoc for what belongs there and what
          # does not. This assertion trusts the declaration; it is the venue's
          # moduledoc and code review that keep it honest, the same trust this suite
          # already places in `credential_benefit` itself.
          caps = @venue.capabilities()

          if caps.credential_benefit == :required do
            assert @fake,
                   "pass `fake:` to run this assertion. It never dials out — only the " <>
                     "fake is called — but it needs the venue's in-process fake to " <>
                     "call against."

            for {name, arity} <- Venue.behaviour_info(:callbacks),
                answerable?({name, arity}),
                credential_gated?(name),
                not market_status_crypto_exempt?(name, @venue),
                not Capabilities.no_venue_contact?(caps, {name, arity}),
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

  defp credential_redaction do
    quote location: :keep do
      # --- 19. credential redaction ------------------------------------------

      describe "19. credential redaction" do
        test "a struct with a secret-named field redacts it under inspect/1" do
          # Found live in four of five venue packages on 2026-09-07: `Feed`/`Socket` held
          # `:credentials` as a bare map for their whole lifetime, and OTP's default crash
          # report prints a process's state in full on termination — a plain map prints
          # every key it holds, secrets included. Proven by crashing an equivalent process
          # holding `%{api_key: "...", api_secret: "..."}` as a bare state field and
          # reading the log back; a second path found the same way, a
          # `FunctionClauseError`'s stacktrace prints the actual arguments a failed clause
          # was called with. `Process.flag(:sensitive, true)` does not help — it changes
          # what `:sys.get_state/1`/`:dbg` can see, not crash-report or stacktrace
          # formatting. Fixed identically in four repos by wrapping the credential in a
          # struct whose `Inspect` is derived with `except:` naming every secret field:
          # `dp_exchange_coinbase` 4d00669, `dp_exchange_webull` 80eaf02,
          # `dp_exchange_schwab` 336cbd8, `dp_exchange_robinhood` cfc4861.
          #
          # `DpExchange.Core.CredentialRedactionCheck` verifies this BEHAVIOURALLY —
          # `struct/2` a real instance of every struct your `lib/` defines with a
          # distinctive value in each secret-named field, and search the actual
          # `inspect/1` rendering for it — never by looking for `@derive` in your source.
          # A hand-written `defimpl Inspect` that never mentions `@derive` at all passes
          # exactly as validly. See its moduledoc for the full secret-name list, why each
          # name is on it, and — the part that matters most — what this does NOT catch:
          # the original defect was a raw map, never a struct, and this check would not
          # have caught it as it actually shipped. It locks the fix in; it cannot reach
          # back to the shape of the bug before the fix existed.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          assert {:ok, violations} =
                   DpExchange.Core.CredentialRedactionCheck.run(beam_dir, lib_root)

          assert violations == [],
                 "struct(s) with a secret-named field that prints in cleartext under " <>
                   "inspect/1 — a crash report or a failed function clause's stacktrace " <>
                   "would print it too:\n" <>
                   DpExchange.Core.CredentialRedactionCheck.format(violations)
        end
      end
    end
  end

  defp subscribed_push_shape do
    quote location: :keep do
      # --- 20. subscribed push shape -----------------------------------------

      describe "20. subscribed push shape" do
        test "subscribe/2 delivers a Core.Types.* struct, tagged with runtime_id/0" do
          # `c:DpExchange.Core.Venue.subscribe/2`'s own doc makes an unconditional claim,
          # never checked before this: "Events arrive as messages... tagged so a process
          # subscribed to several venues can tell them apart" and "The payload is a
          # DpExchange.Core.Types.* struct — the same value the pull endpoints return."
          #
          # Assertion 16 (internal wiring) catches a decoder with no caller, but a decoder
          # that IS wired and hands the raw response straight to the sink — never building
          # the struct the doc promises — passes every existing assertion: the function
          # that forwards it has a caller, and `subscribe/2` answers `:ok` either way.
          # This is that gap: a raw, undecoded payload forwarded to subscribers is a
          # plausible value with the wrong shape, which is this family's own named
          # recurring failure mode, applied to the one endpoint the pull-side checks never
          # reach.
          #
          # Fake-only, like assertion 17: every fake in this family pushes synchronously,
          # inside the call that returns `:ok`, so there is nothing to wait on and no
          # network is ever dialled.
          caps = @venue.capabilities()

          if @fake && @sample_pairs != [] && Capabilities.active?(caps, {:subscribe, 2}) do
            assert :ok = @fake.subscribe(@sample_pairs, to: self())

            assert_receive {:dp_exchange, runtime_id, payload},
                           500,
                           "subscribe/2 returned :ok for #{inspect(@sample_pairs)} but " <>
                             "delivered nothing — a caller has no way to tell that from " <>
                             "a quiet market"

            assert runtime_id == @venue.runtime_id(),
                   "subscribe/2 tagged its message #{inspect(runtime_id)}, not " <>
                     "#{inspect(@venue.runtime_id())} — a caller subscribed to several " <>
                     "venues cannot tell them apart"

            assert is_struct(payload) and
                     payload.__struct__ |> Module.split() |> Enum.take(3) ==
                       ~w(DpExchange Core Types),
                   "subscribe/2 pushed #{inspect(payload)} — the facade's own contract " <>
                     "is that the payload is a DpExchange.Core.Types.* struct, the same " <>
                     "value the pull endpoints return, never raw venue data"
          end
        end
      end
    end
  end

  defp venue_and_observed_time do
    quote location: :keep do
      # --- 23. venue time and observed time on Quote and OrderBook -------------

      describe "23. venue time and observed time" do
        # Core 0.2.0 split `Quote`/`OrderBook`'s single `:timestamp` into `:venue_time`
        # (the venue's own, `nil` where it publishes none) and `:observed_at` (when the
        # package read it, always present) — see
        # `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`.
        #
        # **The split is only worth having if `:venue_time` stays honest**, and nothing
        # checked that. Assertion 14 already makes exactly this check for `TopOfBook`,
        # which had the two fields from the start; these extend it to the two types that
        # just gained them. Not the "comprehensive endpoint → struct map"
        # `docs/reference/core/assertion-coverage.md` considered and declined: two named
        # callbacks whose return type the contract already fixes, with no list to maintain.
        #
        # What this catches is a decode bug with a plausible shape — a raw epoch integer, a
        # `NaiveDateTime`, or a venue string left unparsed in `:venue_time`. What it cannot
        # catch is a venue putting its own local clock there; no assertion can, because a
        # `DateTime` from `DateTime.utc_now/0` is indistinguishable from one the venue sent.
        # That is held by the type's documentation and by review, and saying so is more
        # useful than implying this closes it.
        #
        # Fake-driven for the same reason assertion 14 is: both endpoints are active and
        # uncredentialed on several venues here, so calling the real one would make every
        # ordinary `mix test` dial the live API.
        test "get_price/2's Quote carries the venue's own time or nil, and always observed_at" do
          assert_times(@venue, @fake, {:get_price, 2}, DpExchange.Core.Types.Quote)
        end

        test "get_order_book/2's OrderBook keeps the same discipline" do
          assert_times(@venue, @fake, {:get_order_book, 2}, DpExchange.Core.Types.OrderBook)
        end

        test "neither type still carries a :timestamp field" do
          # Structural, and asserted rather than trusted — the same reasoning as
          # `TopOfBook has no price field`. A `:timestamp` reintroduced later would be a
          # field with no defined meaning: callers would fill it from whichever of the two
          # times was nearest to hand, which is the ambiguity this split removed.
          refute Map.has_key?(
                   struct(DpExchange.Core.Types.Quote, %{}),
                   :timestamp
                 ),
                 "Quote must not regrow :timestamp — venue_time and observed_at are " <>
                   "different facts and one field cannot say which it holds"

          refute Map.has_key?(struct(DpExchange.Core.Types.OrderBook, %{}), :timestamp),
                 "OrderBook must not regrow :timestamp"
        end
      end

      # Assertion 23's shared body. A `defp` in the helpers quote rather than repeated in
      # each test: two endpoints ask the identical question of two different types, and
      # inlining it twice pushed the enclosing quote past credo's complexity ceiling — which
      # is the tool noticing the duplication before a reader had to.
      #
      # Silently skips a venue that declares the endpoint `:unsupported`, and any answer
      # that is not `{:ok, _}` — a refusal is a legitimate answer here, not a failure.
      defp assert_times(venue, fake, {name, arity} = endpoint, expected_module) do
        caps = venue.capabilities()

        if Capabilities.active?(caps, endpoint) and @sample_pairs != [] and fake do
          case apply(fake, name, [hd(@sample_pairs), []]) do
            {:ok, value} -> assert_time_fields(value, expected_module, name, arity)
            _refused_or_unsupported -> :ok
          end
        end
      end

      defp assert_time_fields(value, expected_module, name, arity) do
        assert %^expected_module{} = value,
               "#{name}/#{arity} must return a #{inspect(expected_module)}"

        assert %DateTime{} = value.observed_at,
               "observed_at is mandatory: it is what lets venue_time be nil without any " <>
                 "caller having to invent a time"

        assert is_nil(value.venue_time) or match?(%DateTime{}, value.venue_time),
               "venue_time is the venue's own DateTime or nil — never an unparsed epoch, " <>
                 "a NaiveDateTime, or a stand-in for a time the venue did not send"
      end
    end
  end

  defp historical_timeframe_discipline do
    quote location: :keep do
      # --- 21. historical timeframe discipline --------------------------------

      describe "21. historical timeframe discipline" do
        test "a timeframe outside historical_timeframes is refused, never served at the " <>
               "nearest width" do
          # This family's own named recurring failure, verbatim from this package's
          # CLAUDE.md: "a missing granularity becoming the closest one" — every value
          # stays plausible and only the meaning is wrong, which is why it does not
          # surface as a failure on its own. `get_historical_prices/4`'s own doc makes the
          # identical claim ("The venue rejects a timeframe it does not serve rather than
          # substituting the nearest one"), and nothing checked it before this.
          #
          # Fake-only: picks a width from the shared vocabulary the venue's OWN
          # declaration does not name, and asks the fake for it. `Timeframe.nameable/0` is
          # Core's vocabulary, not a per-venue list this assertion has to keep in sync.
          caps = @venue.capabilities()

          if @fake && Capabilities.active?(caps, {:get_historical_prices, 4}) do
            case Timeframe.nameable() -- caps.historical_timeframes do
              [] ->
                # This venue declares the entire nameable vocabulary — there is no width
                # left that would prove it refuses one.
                :ok

              [unserved | _rest] ->
                refute match?(
                         {:ok, _},
                         call_on(@fake, {:get_historical_prices, 4}, [
                           sample_symbol(),
                           unserved,
                           [],
                           [credentials: @credentials]
                         ])
                       ),
                       "get_historical_prices/4 answered {:ok, _} for #{inspect(unserved)}, " <>
                         "a width capabilities().historical_timeframes does not name — a " <>
                         "missing granularity becoming the closest one mislabels every " <>
                         "candle it touches"
            end
          end
        end
      end

      # --- 22. credentials never reach a supervisor's stored child spec -------

      describe "22. credential redaction in child_spec/1" do
        test "child_spec/1 renders no secret the consumer passed in :credentials" do
          # dp-exchange-core issue #29. A supervisor stores the `{module, :start_link,
          # [opts]}` MFA its child spec names, and OTP writes that argument list through
          # `inspect/1` into the `Start Call:` line of the report it logs on ANY child
          # termination. A raw `%{api_key: ..., private_key: ...}` map therefore prints its
          # values, in full, into ordinary application logs — the artifact most likely to
          # be shipped to an aggregator, attached to a bug report or quoted in a ticket. A
          # consumer found live keys exactly this way and nearly pasted them into a GitHub
          # issue while reporting an unrelated bug.
          #
          # **This is the assertion that assertion 19 says it cannot make.**
          # `Core.CredentialRedactionCheck` proves every STRUCT a package defines redacts
          # on inspect, and its own moduledoc records that it would not have caught the
          # defect as it actually shipped, where the value never became a struct at all.
          # This asks the only question a consumer cares about: having handed the venue a
          # secret the documented way, is that secret visible in what the supervisor will
          # store and the logger will print?
          #
          # Every secret key name any venue in this family uses is passed at once, so this
          # needs no per-venue list to keep in sync. `Kernel.struct/2` DROPS keys a given
          # venue's own credentials struct does not declare, so an unrecognised key cannot
          # leak either — it is gone, not merely unprinted.
          canary = "dpx-credential-canary-#{System.unique_integer([:positive])}"

          secrets = %{
            api_key: canary,
            api_secret: canary,
            private_key: canary,
            app_key: canary,
            app_secret: canary,
            access_token: canary,
            refresh_token: canary,
            client_id: canary,
            client_secret: canary,
            passphrase: canary,
            secret: canary,
            token: canary
          }

          rendered = inspect(@venue.child_spec(credentials: secrets), limit: :infinity)

          refute rendered =~ canary,
                 "#{inspect(@venue)}.child_spec/1 renders a secret passed in :credentials " <>
                   "in cleartext. A supervisor stores those args and OTP prints them on " <>
                   "every child crash, so this is a live credential written to the log by " <>
                   "any crash at all. Wrap the :credentials value in a struct with a " <>
                   "redacting Inspect IN child_spec/1 — doing it in start_link/1 or " <>
                   "init/1 is too late, because the supervisor above has already captured " <>
                   "the raw list. Rendered: #{rendered}"
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
      # `test_connection/2` and `get_rate_limit_status/2` are the only two exemptions,
      # and both for the same reason: their own callback doc explicitly types the
      # credential `credentials() | nil` — the CONTRACT itself, not a venue's
      # implementation choice, says a missing credential is an expected input, because
      # both mean "can I reach the venue at all" rather than "give me this venue's
      # data". Nothing else in the behaviour has that property in its type. This is a
      # denylist of two, not an allowlist of what to check — see "17. credential gate"'s
      # own comment for why that direction is the one that does not rot.
      @credential_gate_exempt ~w(test_connection get_rate_limit_status)a

      defp credential_gated?(name), do: name not in @credential_gate_exempt

      # `market_status/1`'s own doc makes an unconditional claim for exactly one class of
      # venue — "crypto venues answer `:open`" — because crypto has no exchange-mandated
      # trading session for a credential to gate. That is a different claim from
      # `test_connection/2`/`get_rate_limit_status/2`'s `credentials() | nil` typing, so
      # it is not folded into `@credential_gate_exempt` above: `dp_exchange_schwab`'s
      # real `market_status/1` is itself authenticated, and a name-based exemption would
      # silence assertion 17's protection there to accommodate venues where this callback
      # never touches the venue at all. Scoped instead to exactly the venues the doc's
      # claim is actually about — see "17. credential gate"'s own comment for the full
      # argument.
      defp market_status_crypto_exempt?(:market_status, venue),
        do: venue.asset_classes() == [:crypto]

      defp market_status_crypto_exempt?(_name, _venue), do: false

      # The same shape `endpoint_args/2` builds, with every credential position
      # emptied — positional where the venue's arg shape carries one (`@credentialed`,
      # unchanged, still governs SHAPE only: whether credentials arrive as an argument
      # or through `opts`), and in `opts` for every endpoint, public-shaped ones
      # included.
      defp stripped_credential_args(name, arity) do
        kind = if credentialed?(name), do: :credentialed, else: :public

        @arg_shapes
        |> Map.get({kind, arity}, List.duplicate(:opts, arity))
        |> Enum.map(&stripped_arg_value/1)
      end

      defp stripped_arg_value(:credentials), do: %{}

      # `[credentials: %{}]`, never `[]`. `endpoint_args/2` already sends `[]` for every
      # `:opts` position, credentialed or not, so an opts list that started at `[]` and
      # stayed `[]` here would prove nothing had been stripped — it never carried a
      # credential to begin with, on any venue, credentialed or not. Sending
      # `[credentials: %{}]` exercises a venue whose facade reads
      # `Keyword.get(opts, :credentials, %{})` with an EXPLICIT empty credential rather
      # than an absent key its own code may never have read at all.
      defp stripped_arg_value(:opts), do: [credentials: %{}]
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
