# Venues that are wrong in one specific way each. A conformance suite that passes
# everything proves nothing, so these exist to show each assertion actually bites.

defmodule Broken.OverDeclares do
  @moduledoc false
  # Declares an endpoint active, then refuses it. Fails in the caller's hands at runtime.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_transfers, 2} => :proven},
      supported_quotes: ~w(USD)
    )
  end

  @spec get_transfers(map(), keyword()) :: term()
  def get_transfers(_credentials, _opts), do: {:error, :not_supported}
end

defmodule Broken.UnderDeclares do
  @moduledoc false
  # Declares :unsupported, then works. Hides functionality a consumer could have used.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_transfers, 2} => :unsupported},
      supported_quotes: ~w(USD)
    )
  end

  @spec get_transfers(map(), keyword()) :: term()
  def get_transfers(_credentials, _opts), do: {:ok, []}
end

defmodule Broken.SilentlyUnsupported do
  @moduledoc false
  # Under-declares by SAYING NOTHING rather than by declaring `:unsupported` — the gap
  # `Broken.UnderDeclares` above does not reach. `{:get_fx_rate, 3}` never appears in
  # `endpoints`, so `Capabilities.active?/2`'s own documented default ("anything not named
  # in the map is :experimental — the only honest default") makes it active. The function
  # answers `{:error, :not_supported}` anyway: the exact disagreement assertion 12 exists
  # to catch, reachable here only because it was never named rather than because it was
  # named wrong.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(endpoints: %{}, supported_quotes: ~w(USD))
  end

  @spec get_fx_rate(String.t(), DateTime.t(), keyword()) :: term()
  def get_fx_rate(_pair, _at, _opts), do: {:error, :not_supported}
end

defmodule Broken.StringRefusal do
  @moduledoc false
  # The atom/string confusion, in the code as it was found: a caller matching the atom
  # silently misses this and treats a refusal as an unrecognised error.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_transfers, 2} => :unsupported},
      supported_quotes: ~w(USD)
    )
  end

  @spec get_transfers(map(), keyword()) :: term()
  def get_transfers(_credentials, _opts), do: {:error, "not_supported"}
end

defmodule Broken.SymbolFormat do
  @moduledoc false
  # Quote assets handed to `CanonicalPair` in the WRONG order — shortest-first, with `USD`
  # a suffix of `BUSD`. This used to be the entire USD/USDT/USDC bug: `BTCBUSD` parsed as
  # `BTC-USD` with a stray character and every value downstream stayed plausible while
  # naming a pair that does not exist. `CanonicalPair` now sorts `quotes` longest-first
  # internally (C6), so this mapping — deliberately still given in the wrong order — is
  # the regression test proving a caller cannot get this wrong any more.
  #
  # That containment is the actual collision: `USDT` and `USDC` do NOT end with `USD`, so
  # those three round-trip in either order, and a test built on them would have proved
  # nothing either way.
  @behaviour DpExchange.Core.SymbolNormalizer

  @mapping %{sep: "", quotes: ~w(USD BUSD)}

  @impl true
  def to_canonical_symbol(native),
    do: DpExchange.Core.CanonicalPair.to_canonical(@mapping, native)

  @impl true
  def to_exchange_symbol(canonical),
    do: DpExchange.Core.CanonicalPair.to_exchange(@mapping, canonical)
end

defmodule Broken.CoverageByKind.Conforming do
  @moduledoc false
  # Both invariants hold: the union of symbols across kinds matches coverage/1 exactly,
  # and every kind reported is one `streamable` actually declares. If a future edit to
  # the assertion starts failing this fixture, the assertion got stricter than the
  # design allows.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:coverage, 1} => :proven},
      supported_quotes: ~w(USD),
      streamable: [:quotes, :order_book]
    )
  end

  @spec coverage(keyword()) :: %{String.t() => atom()}
  def coverage(_opts), do: %{"BTC-USD" => :stream, "ETH-USD" => :internal_poll}

  @spec coverage_by_kind(keyword()) :: %{atom() => %{String.t() => atom()}}
  def coverage_by_kind(_opts) do
    %{
      quotes: %{"BTC-USD" => :stream},
      order_book: %{"BTC-USD" => :stream, "ETH-USD" => :internal_poll}
    }
  end
end

defmodule Broken.CoverageByKind.UnionViolation do
  @moduledoc false
  # Drops ETH-USD from the union on purpose — coverage/1 reports it, coverage_by_kind/1
  # does not. This is the exact shape #22 would have been caught by: two sources of
  # truth that are allowed to disagree are not really two sources of truth.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:coverage, 1} => :proven},
      supported_quotes: ~w(USD),
      streamable: [:quotes, :order_book]
    )
  end

  @spec coverage(keyword()) :: %{String.t() => atom()}
  def coverage(_opts), do: %{"BTC-USD" => :stream, "ETH-USD" => :stream}

  @spec coverage_by_kind(keyword()) :: %{atom() => %{String.t() => atom()}}
  def coverage_by_kind(_opts), do: %{quotes: %{"BTC-USD" => :stream}}
end

defmodule Broken.CoverageByKind.UndeclaredKind do
  @moduledoc false
  # Reports :order_book while `streamable` declares only :quotes — a contradiction
  # between two of the venue's own declarations.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:coverage, 1} => :proven},
      supported_quotes: ~w(USD),
      streamable: [:quotes]
    )
  end

  @spec coverage(keyword()) :: %{String.t() => atom()}
  def coverage(_opts), do: %{"BTC-USD" => :stream}

  @spec coverage_by_kind(keyword()) :: %{atom() => %{String.t() => atom()}}
  def coverage_by_kind(_opts) do
    %{quotes: %{"BTC-USD" => :stream}, order_book: %{"BTC-USD" => :stream}}
  end
end

defmodule Broken.CredentialGate.NeverChecks do
  @moduledoc false
  # Declares `credential_benefit: :required` — public data is not served at all without
  # credentials — and then serves `get_balances/2` regardless of what credentials it was
  # given. The exact shape found independently in two venue packages the same week this
  # assertion was written: a venue where every request is signed and there is no
  # anonymous endpoint, whose fake nonetheless answered `{:ok, _}` for `%{}` or `nil`.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_balances, 2} => :proven},
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec get_balances(map(), keyword()) :: term()
  def get_balances(_credentials, _opts), do: {:ok, []}
end

defmodule Broken.CredentialGate.Conforming do
  @moduledoc false
  # Same declaration, but the fake actually gates on credentials — this is what
  # assertion 17 must NOT reject, or it would be flagging a venue for having the
  # property it declares.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_balances, 2} => :proven},
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec get_balances(map(), keyword()) :: term()
  def get_balances(credentials, _opts) do
    if map_size(credentials) > 0 do
      {:ok, []}
    else
      {:error, {:missing_credentials, :fixture}}
    end
  end

  # `test_connection/2` legitimately answers without credentials even here — its own
  # callback doc allows `credentials() | nil`, "the credential, IF GIVEN, is accepted".
  # Assertion 17 must not gate this one at all.
  @spec test_connection(map() | nil, keyword()) :: term()
  def test_connection(_credentials, _opts), do: {:ok, %{reachable: true}}
end

defmodule Broken.CredentialGate.CryptoOnlyMarketStatus do
  @moduledoc false
  # A crypto-only `:required` venue. `market_status/1` answers `:open` unconditionally
  # and never touches a credential — `Core.Venue`'s own doc says crypto venues answer
  # `:open`, and this venue's `asset_classes/0` being exactly `[:crypto]` is what lets
  # the credential gate skip this one callback (`market_status_crypto_exempt?/2` in
  # `AdapterContract`). This is `dp_exchange_robinhood`'s real shape.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:market_status, 1} => :proven},
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec asset_classes() :: [atom()]
  def asset_classes, do: [:crypto]

  @spec market_status(keyword()) :: term()
  def market_status(_opts), do: {:ok, :open}
end

defmodule Broken.CredentialGate.MixedAssetMarketStatus do
  @moduledoc false
  # Same declaration, but this venue also serves equities — `dp_exchange_schwab`'s real
  # shape, where `market_status/1` calls an authenticated `/markets` endpoint. Here the
  # callback is written the naive way, answering `:open` unconditionally with no
  # credential check at all, which must still be CAUGHT: a venue that is not crypto-only
  # can have real, authenticated market hours, so the exemption above must not reach it.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:market_status, 1} => :proven},
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec asset_classes() :: [atom()]
  def asset_classes, do: [:crypto, :equity]

  @spec market_status(keyword()) :: term()
  def market_status(_opts), do: {:ok, :open}
end

defmodule Broken.CredentialGate.NoVenueContactFees do
  @moduledoc false
  # A `:required` venue whose `get_fees/2` answers a captured published rate and never
  # builds a request — `dp_exchange_webull`'s real shape. Declared in
  # `no_venue_contact`, so the gate must not flag it even though this venue is not
  # crypto-only and `get_fees/2` is not one of the two name-based exemptions either.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_fees, 2} => :proven},
      no_venue_contact: [{:get_fees, 2}],
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec get_fees(map(), keyword()) :: term()
  def get_fees(_credentials, _opts), do: {:ok, %{crypto_spread_pct: Decimal.new("1.00")}}
end

defmodule Broken.CredentialGate.UndeclaredNoVenueContactFees do
  @moduledoc false
  # The identical fixture, minus the `no_venue_contact` declaration — this is the
  # 2026-09-06 shape found on `dp_exchange_webull` before the fix: nothing declares the
  # endpoint credential-free, so the gate must still catch it.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_fees, 2} => :proven},
      supported_quotes: ~w(USD),
      credential_benefit: :required
    )
  end

  @spec get_fees(map(), keyword()) :: term()
  def get_fees(_credentials, _opts), do: {:ok, %{crypto_spread_pct: Decimal.new("1.00")}}
end

defmodule Broken.Subscribe.RawPayload do
  @moduledoc false
  # `subscribe/2` pushes the venue's raw response map instead of building the
  # `Types.Quote` the doc promises — the shape of "raw undecoded JSON forwarded to
  # subscribers": a decoder with a real caller (so assertion 16's wiring check has
  # nothing to flag) that simply never gets called before the sink does.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:subscribe, 2} => :proven},
      supported_quotes: ~w(USD)
    )
  end

  @spec runtime_id() :: atom()
  def runtime_id, do: :broken_raw_payload

  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(symbols, opts) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols do
      send(target, {:dp_exchange, runtime_id(), %{"symbol" => symbol, "price" => "42000.50"}})
    end

    :ok
  end
end

defmodule Broken.Subscribe.WrongTag do
  @moduledoc false
  # Tags the pushed message with a hardcoded atom rather than runtime_id/0 — a caller
  # subscribed to several venues cannot tell this one apart from another.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:subscribe, 2} => :proven},
      supported_quotes: ~w(USD)
    )
  end

  @spec runtime_id() :: atom()
  def runtime_id, do: :broken_wrong_tag

  @spec subscribe([String.t()], keyword()) :: :ok
  def subscribe(symbols, opts) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols do
      send(
        target,
        {:dp_exchange, :some_other_venue,
         %DpExchange.Core.Types.Quote{
           symbol: symbol,
           price: Decimal.new("42000.50"),
           volume: Decimal.new("1"),
           timestamp: DateTime.utc_now(),
           provider: runtime_id()
         }}
      )
    end

    :ok
  end
end

defmodule Broken.HistoricalPrices.Substitutes do
  @moduledoc false
  # Serves ANY timeframe at the nearest width it actually has, rather than refusing one
  # `historical_timeframes` does not name — the family's own named recurring failure
  # mode, applied to candles: every value stays plausible and only the meaning (the
  # width) is wrong.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{{:get_historical_prices, 4} => :proven},
      supported_quotes: ~w(USD),
      historical_timeframes: ~w(1h)
    )
  end

  @spec get_historical_prices(String.t(), String.t(), keyword(), keyword()) :: term()
  def get_historical_prices(symbol, _timeframe, _range, _opts) do
    # Silently substitutes "1h" for whatever was actually asked for.
    {:ok,
     [
       %DpExchange.Core.Types.Candle{
         symbol: symbol,
         timeframe: "1h",
         opened_at: DateTime.utc_now(),
         open: Decimal.new("1"),
         high: Decimal.new("1"),
         low: Decimal.new("1"),
         close: Decimal.new("1"),
         volume: Decimal.new("1"),
         provider: :broken_substitutes
       }
     ]}
  end
end

defmodule DpExchange.Core.ContractTeethTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, ReferenceVenue, UnwiredCheck, UnwiredFixture, Venue}

  describe "assertion 12 catches both directions of disagreement" do
    test "over-declaring is caught" do
      caps = Broken.OverDeclares.capabilities()
      active = Capabilities.endpoints_at(caps, :proven)

      assert {:get_transfers, 2} in active

      assert Broken.OverDeclares.get_transfers(%{}, []) == {:error, :not_supported},
             "declared active, answers not_supported — the suite must reject this"
    end

    test "under-declaring is caught" do
      caps = Broken.UnderDeclares.capabilities()

      assert {:get_transfers, 2} in Capabilities.endpoints_at(caps, :unsupported)

      refute Broken.UnderDeclares.get_transfers(%{}, []) == {:error, :not_supported},
             "declared unsupported but works — hidden functionality the suite must reject"
    end

    test "a string refusal does not satisfy the atom assertion" do
      refute Broken.StringRefusal.get_transfers(%{}, []) == {:error, :not_supported}
      assert Broken.StringRefusal.get_transfers(%{}, []) == {:error, "not_supported"}
    end

    test "under-declaring BY SILENCE — never naming the endpoint at all — used to slip " <>
           "past the same check that catches under-declaring by a wrong VALUE" do
      # `AdapterContract`'s "an active endpoint does not answer :not_supported" test used
      # to enumerate `Capabilities.endpoints_at(caps, :proven) ++
      # Capabilities.endpoints_at(caps, :experimental)` — which iterates only the
      # EXPLICIT entries in `capabilities().endpoints`. `Capabilities.active?/2`'s own
      # documented default treats an ABSENT key as active too ("anything not named in the
      # map is :experimental"), so an endpoint never mentioned at all was active by that
      # same default and the enumeration silently skipped it anyway.
      caps = Broken.SilentlyUnsupported.capabilities()

      # It is active by the documented default...
      assert Capabilities.active?(caps, {:get_fx_rate, 3})

      # ...and answers :not_supported anyway — over-declaring, by omission.
      assert Broken.SilentlyUnsupported.get_fx_rate("USD-EUR", DateTime.utc_now(), []) ==
               {:error, :not_supported}

      # This is exactly what the old enumeration missed: the endpoint above is active,
      # but it appears in NEITHER list, because it was never entered into `endpoints` at
      # all — not `:proven`, not `:experimental`, not `:unsupported`.
      refute {:get_fx_rate, 3} in Capabilities.endpoints_at(caps, :proven)
      refute {:get_fx_rate, 3} in Capabilities.endpoints_at(caps, :experimental)

      # The fixed check enumerates every facade callback and asks `active?/2` directly,
      # which is what `AdapterContract` now does — see its "12. capabilities and
      # behaviour agree" group.
      assert {:get_fx_rate, 3} in Venue.behaviour_info(:callbacks)
    end
  end

  describe "assertion 4 catches the round-trip bug it was written for" do
    test "a mapping with quotes given shortest-first no longer breaks the round trip (C6)" do
      round_tripped =
        "BTC-BUSD"
        |> Broken.SymbolFormat.to_exchange_symbol()
        |> Broken.SymbolFormat.to_canonical_symbol()

      # Before C6: `BTCBUSD` ends with `USD` before it ends with `BUSD`, so a shortest-first
      # `quotes` list split the base as `BTCB` and this assertion was `"BTCB-USD"` — every
      # value downstream stayed plausible while naming a pair that does not exist, and
      # nothing caught it, because concatenation round-trips byte-for-byte regardless of
      # where the cut landed. `CanonicalPair` now sorts `quotes` longest-first internally
      # before matching, so the caller's (wrong) ordering here no longer matters.
      assert round_tripped == "BTC-BUSD"
    end

    test "the same mapping ordered longest-first round-trips correctly" do
      correct = %{sep: "", quotes: ~w(BUSD USD)}

      round_tripped =
        DpExchange.Core.CanonicalPair.to_canonical(
          correct,
          DpExchange.Core.CanonicalPair.to_exchange(correct, "BTC-BUSD")
        )

      assert round_tripped == "BTC-BUSD"
    end

    test "the reference venue's hostile mapping survives the same input" do
      # Same shape, ordered correctly — which is the difference the assertion exists to
      # detect, and why the reference fake is deliberately separator-less.
      for pair <- ~w(BTC-USD BTC-USDT BTC-USDC BTC-BUSD ETH-EUR) do
        round_tripped =
          pair
          |> ReferenceVenue.SymbolFormat.to_exchange_symbol()
          |> ReferenceVenue.SymbolFormat.to_canonical_symbol()

        assert round_tripped == pair
      end
    end
  end

  describe "assertion 1 catches an incomplete facade" do
    test "a module missing a required callback is detectable" do
      missing =
        Enum.reject(Venue.required_callbacks(), fn {name, arity} ->
          function_exported?(Broken.OverDeclares, name, arity)
        end)

      assert length(missing) > 20, "an almost-empty module must fail behaviour completeness"
    end

    test "the reference venue is complete" do
      Code.ensure_loaded!(ReferenceVenue)

      missing =
        Enum.reject(Venue.required_callbacks(), fn {name, arity} ->
          function_exported?(ReferenceVenue, name, arity)
        end)

      assert missing == []
    end
  end

  describe "the reference venue exercises both directions, not just the happy one" do
    test "it refuses two endpoints for real" do
      # A fake where everything works proves only half the contract.
      caps = ReferenceVenue.capabilities()
      unsupported = Capabilities.endpoints_at(caps, :unsupported)

      assert {:get_transfers, 2} in unsupported
      assert {:quantization, 1} in unsupported

      assert ReferenceVenue.get_transfers(%{}, []) == {:error, :not_supported}
      assert ReferenceVenue.quantization("BTC-USD") == {:error, :not_supported}
    end

    test "it distinguishes a refusal from an error" do
      # A symbol the venue does not carry is permanent; an unsupported timeframe is a
      # caller mistake. Collapsing them makes a delisting look like a retryable blip.
      assert {:refused, :symbol_not_listed} = ReferenceVenue.get_price("NOPE-USD", [])

      assert {:error, {:unsupported_timeframe, "1w"}} =
               ReferenceVenue.get_historical_prices("BTC-USD", "1w", [], [])
    end

    test "it pushes on subscribe, as a REST-only venue would" do
      assert :ok = ReferenceVenue.subscribe(~w(BTC-USD), to: self())
      assert_receive {:dp_exchange, :reference_venue, %DpExchange.Core.Types.Quote{}}
    end

    test "it emits notices on its own channel" do
      assert :ok = ReferenceVenue.subscribe_notices(to: self())
      assert_receive {:dp_exchange, :reference_venue, %DpExchange.Core.Notice{kind: :link_up}}
    end
  end

  describe "assertion 15 catches coverage_by_kind drifting from coverage/1" do
    # Each test below replicates the exact computation `AdapterContract`'s "15. coverage
    # by kind" group runs, against the same fixtures — proving the computation itself is
    # right, the same pattern assertions 1, 4 and 12 above use in this file.

    test "a conforming fake satisfies both checks" do
      fixture = Broken.CoverageByKind.Conforming
      by_kind = fixture.coverage_by_kind([])
      coverage_symbols = fixture.coverage([]) |> Map.keys() |> MapSet.new()
      union = by_kind |> Map.values() |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

      assert union == coverage_symbols

      declared = MapSet.new(fixture.capabilities().streamable)
      reported = by_kind |> Map.keys() |> MapSet.new()
      assert MapSet.subset?(reported, declared)
    end

    test "a fake whose union drops a symbol coverage/1 reports is caught" do
      fixture = Broken.CoverageByKind.UnionViolation
      by_kind = fixture.coverage_by_kind([])
      coverage_symbols = fixture.coverage([]) |> Map.keys() |> MapSet.new()
      union = by_kind |> Map.values() |> Enum.flat_map(&Map.keys/1) |> MapSet.new()

      refute union == coverage_symbols,
             "this fixture drops ETH-USD from coverage_by_kind/1 on purpose — the suite " <>
               "must reject the drift"
    end

    test "a fake reporting a kind it does not declare streamable is caught" do
      fixture = Broken.CoverageByKind.UndeclaredKind
      declared = MapSet.new(fixture.capabilities().streamable)
      reported = fixture.coverage_by_kind([]) |> Map.keys() |> MapSet.new()

      refute MapSet.subset?(reported, declared),
             "this fixture reports :order_book while streamable declares only :quotes — " <>
               "the suite must reject a venue contradicting its own declaration"
    end

    test "the reference venue does not export coverage_by_kind/1, and the suite around " <>
           "it stays green anyway" do
      # AdapterContractTest runs the full suite, including the new group, against
      # ReferenceVenue today — this is what proves an absent optional callback does not
      # fail conformance. If this assertion ever starts failing, ReferenceVenue adopted
      # the callback and a different fixture is needed for the not-adopted-yet branch.
      Code.ensure_loaded?(ReferenceVenue)

      refute function_exported?(ReferenceVenue, :coverage_by_kind, 1),
             "ReferenceVenue now exports coverage_by_kind/1 — this test no longer proves " <>
               "the suite tolerates an ABSENT callback and needs a fixture that lacks it"
    end
  end

  describe "assertion 16 catches an unwired internal function" do
    # Reproduces the shape of the real thing rather than a synthetic shell: a facade
    # (excluded, like `@venue`), an internal module with one function the facade calls
    # (`Feed.subscribe_notices/2`'s wired sibling) and one it should call but does not
    # (`Auth.refresh/2`, `Feed.subscribe_notices/2` themselves, pre-fix — see
    # `Core.UnwiredCheck`'s moduledoc). A test calling the unwired one directly, the way
    # every one of the six real instances shipped, must not be enough to satisfy it.
    test "an internal function only a test calls is flagged" do
      u = System.unique_integer([:positive, :monotonic])

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "auth.ex",
            code: """
            defmodule TeethAuth#{u} do
              def needs_refresh?(_credentials), do: true
              def refresh(_credentials, _opts), do: {:ok, %{}}
            end
            """
          },
          %{
            path: "venue.ex",
            code: """
            defmodule TeethVenue#{u} do
              # The bug, reproduced: the facade never calls Auth.refresh/2 or
              # Auth.needs_refresh?/1, exactly as dp_exchange_schwab's did before
              # bf2e241 wired it in.
              def sign(_credentials), do: :ok
            end
            """
          }
        ])

      facade = Module.concat([:"Elixir", "TeethVenue#{u}"])
      auth = Module.concat([:"Elixir", "TeethAuth#{u}"])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root, [facade])
      mfas = Enum.map(violations, fn v -> {v.module, v.function, v.arity} end)

      assert {auth, :refresh, 2} in mfas
      assert {auth, :needs_refresh?, 1} in mfas
    end

    test "wiring the facade to the internal function clears the finding" do
      u = System.unique_integer([:positive, :monotonic])

      {beam_dir, lib_root} =
        UnwiredFixture.compile!([
          %{
            path: "auth.ex",
            code: """
            defmodule TeethAuthFixed#{u} do
              def refresh(_credentials, _opts), do: {:ok, %{}}
            end
            """
          },
          %{
            path: "venue.ex",
            code: """
            defmodule TeethVenueFixed#{u} do
              def sign(credentials), do: TeethAuthFixed#{u}.refresh(credentials, [])
            end
            """
          }
        ])

      facade = Module.concat([:"Elixir", "TeethVenueFixed#{u}"])
      auth = Module.concat([:"Elixir", "TeethAuthFixed#{u}"])

      assert {:ok, violations} = UnwiredCheck.run(beam_dir, lib_root, [facade])
      mfas = Enum.map(violations, fn v -> {v.module, v.function, v.arity} end)

      refute {auth, :refresh, 2} in mfas,
             "the facade now calls Auth.refresh/2 — the same fix bf2e241 made for real"
    end
  end

  describe "assertion 17 catches a fake that never checks credentials" do
    # Replicates `AdapterContract`'s "17. credential gate" computation against these
    # fixtures directly, the same pattern assertions 1, 4, 12 and 15 already use in this
    # file — the private helpers the real assertion calls
    # (`credential_gated?/1`, `stripped_credential_args/2`) only exist inside a module
    # that `use`s `AdapterContract`, so the equivalent check is rebuilt here from the same
    # public primitives (`Capabilities.active?/2`, `Venue.behaviour_info/1`) the real one
    # is built on.
    @credentialed ~w(get_balances get_accounts get_fees get_transfers place_order
                     cancel_order get_order get_orders get_trade_history
                     test_connection get_rate_limit_status)a
    @credential_gated @credentialed -- [:test_connection, :get_rate_limit_status]

    test "a fake succeeding with stripped credentials, on a venue requiring them, is caught" do
      caps = Broken.CredentialGate.NeverChecks.capabilities()
      assert caps.credential_benefit == :required

      gated_and_active =
        for {name, arity} <- Venue.behaviour_info(:callbacks),
            name in @credential_gated,
            Capabilities.active?(caps, {name, arity}),
            do: {name, arity}

      assert {:get_balances, 2} in gated_and_active

      assert match?(
               {:ok, _},
               Broken.CredentialGate.NeverChecks.get_balances(%{}, [])
             ),
             "this fixture answers :ok with stripped credentials on purpose — the suite " <>
               "must reject a fake that does this"
    end

    test "a fake that actually gates on credentials satisfies the same check" do
      caps = Broken.CredentialGate.Conforming.capabilities()
      assert caps.credential_benefit == :required

      refute match?(
               {:ok, _},
               Broken.CredentialGate.Conforming.get_balances(%{}, [])
             ),
             "the conforming fixture refuses stripped credentials and must not be flagged"

      assert match?(
               {:ok, _},
               Broken.CredentialGate.Conforming.get_balances(%{fake: "cred"}, [])
             ),
             "real credentials still work — this is a gate, not a permanent refusal"
    end

    test "test_connection/2 is excluded from the gate even on a venue requiring credentials" do
      # Its own callback doc allows `credentials() | nil` — answering without one is the
      # documented behaviour, not the defect this assertion exists to catch.
      refute :test_connection in @credential_gated

      assert match?(
               {:ok, _},
               Broken.CredentialGate.Conforming.test_connection(nil, [])
             )
    end

    # `market_status/1` is not in `@credential_gated` above (it takes no positional
    # credential at all) and is not a name-based exemption either — whether the gate
    # reaches it depends on `asset_classes/0`, replicated directly here the same way
    # `market_status_crypto_exempt?/2` computes it in `AdapterContract`.
    test "market_status/1 is exempt on a crypto-only :required venue" do
      venue = Broken.CredentialGate.CryptoOnlyMarketStatus
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      assert venue.asset_classes() == [:crypto]

      assert match?({:ok, _}, venue.market_status(credentials: %{})),
             "a crypto-only venue answers :open with no credential by design — the " <>
               "gate must not flag this callback here"
    end

    test "market_status/1 is still reached by the gate on a venue that is not crypto-only" do
      venue = Broken.CredentialGate.MixedAssetMarketStatus
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      assert venue.asset_classes() != [:crypto]

      assert match?({:ok, _}, venue.market_status(credentials: %{})),
             "this fixture answers :ok with stripped credentials on purpose — a venue " <>
               "serving more than crypto is not exempt, so a real fake shaped this way " <>
               "must be rejected the same as any other unchecked credentialed callback"
    end

    # `get_fees/2` is not a name-based exemption and not crypto-only-exempt — whether
    # the gate reaches it depends on `Capabilities.no_venue_contact?/2`, exercised
    # directly here the same way `AdapterContract` reads it.
    test "get_fees/2 is exempt when declared in no_venue_contact" do
      venue = Broken.CredentialGate.NoVenueContactFees
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      assert Capabilities.no_venue_contact?(caps, {:get_fees, 2})

      assert match?({:ok, _}, venue.get_fees(%{}, [])),
             "an endpoint declared no_venue_contact answers a captured or locally " <>
               "computed value with no credential by design — the gate must not flag " <>
               "this callback here"
    end

    test "get_fees/2 is still reached by the gate when not declared in no_venue_contact" do
      venue = Broken.CredentialGate.UndeclaredNoVenueContactFees
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      refute Capabilities.no_venue_contact?(caps, {:get_fees, 2})

      assert match?({:ok, _}, venue.get_fees(%{}, [])),
             "this fixture answers :ok with stripped credentials on purpose — with no " <>
               "no_venue_contact declaration this is exactly the 2026-09-06 " <>
               "dp_exchange_webull defect, and a real fake shaped this way must still " <>
               "be rejected"
    end
  end

  describe "assertion 20 catches a subscribe/2 push that is not a Core.Types.* struct" do
    # Replicates the exact computation `AdapterContract`'s "20. subscribed push shape"
    # group runs, against these fixtures directly — the same pattern used above for
    # assertions 1, 4, 12, 15, 16 and 17.
    test "a raw, undecoded payload is caught" do
      assert :ok = Broken.Subscribe.RawPayload.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, _runtime_id, payload}, 500

      refute is_struct(payload),
             "this fixture pushes a bare map on purpose — the exact 'raw JSON forwarded " <>
               "to subscribers' shape the assertion exists to catch — and the suite " <>
               "must reject it"
    end

    test "a message tagged with something other than runtime_id/0 is caught" do
      venue = Broken.Subscribe.WrongTag
      assert :ok = venue.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, runtime_id, %DpExchange.Core.Types.Quote{}}, 500

      refute runtime_id == venue.runtime_id(),
             "this fixture tags its message with a hardcoded atom on purpose — a caller " <>
               "subscribed to several venues could not tell them apart, and the suite " <>
               "must reject it"
    end

    test "the reference venue satisfies both halves" do
      assert :ok = DpExchange.Core.ReferenceVenue.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, runtime_id, payload}, 500

      assert runtime_id == DpExchange.Core.ReferenceVenue.runtime_id()
      assert %DpExchange.Core.Types.Quote{} = payload
    end
  end

  describe "assertion 21 catches a historical timeframe silently served at the " <>
             "nearest width" do
    test "a fake that substitutes rather than refuses is caught" do
      venue = Broken.HistoricalPrices.Substitutes
      caps = venue.capabilities()

      undeclared = DpExchange.Core.Timeframe.nameable() -- caps.historical_timeframes
      assert "1d" in undeclared, "1d must be outside this fixture's declared 1h-only vocabulary"

      assert match?(
               {:ok, _},
               venue.get_historical_prices("BTC-USD", "1d", [], [])
             ),
             "this fixture silently substitutes its one declared width for whatever was " <>
               "asked on purpose — a missing granularity becoming the closest one — and " <>
               "the suite must reject it"
    end

    test "the reference venue refuses a width it does not declare" do
      caps = DpExchange.Core.ReferenceVenue.capabilities()
      undeclared = DpExchange.Core.Timeframe.nameable() -- caps.historical_timeframes

      assert undeclared != []

      [unserved | _rest] = undeclared

      refute match?(
               {:ok, _},
               DpExchange.Core.ReferenceVenue.get_historical_prices("BTC-USD", unserved, [], [])
             )
    end
  end
end
