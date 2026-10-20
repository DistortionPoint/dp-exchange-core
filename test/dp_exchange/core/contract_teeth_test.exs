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
           venue_time: DateTime.utc_now(),
           observed_at: DateTime.utc_now(),
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

defmodule Broken.Convention.Lax do
  @moduledoc false
  # Breaks every family convention at once: accepts a malformed list and a bad subscriber,
  # answers a blank symbol with data, places any request including a price on a market order,
  # and answers a blank order id by raising or exiting instead of refusing it.
  @spec capabilities() :: DpExchange.Core.Capabilities.t()
  def capabilities do
    DpExchange.Core.Capabilities.new(
      endpoints: %{},
      supported_quotes: ~w(USD),
      supported_order_types: [:market, :limit],
      supported_time_in_force: [:gtc]
    )
  end

  @spec subscribe(term(), keyword()) :: :ok
  def subscribe(_symbols, _opts), do: :ok

  @spec unsubscribe(term(), keyword()) :: :ok
  def unsubscribe(_symbols, _opts), do: :ok

  @spec update_symbols(term(), keyword()) :: :ok
  def update_symbols(_symbols, _opts), do: :ok

  @spec subscribe_notices(keyword()) :: {:error, :feed_not_started}
  def subscribe_notices(_opts), do: {:error, :feed_not_started}

  @spec get_price(term(), keyword()) :: {:ok, :price}
  def get_price(_symbol, _opts), do: {:ok, :price}

  @spec get_top_of_book(term(), keyword()) :: {:refused, :not_listed}
  def get_top_of_book(_symbol, _opts), do: {:refused, :not_listed}

  @spec place_order(map(), term(), keyword()) :: {:ok, :placed}
  def place_order(_credentials, _request, _opts), do: {:ok, :placed}

  @spec get_order(map(), term(), keyword()) :: no_return()
  def get_order(_credentials, _id, _opts), do: raise(ArgumentError, "blank id")

  @spec cancel_order(map(), term(), keyword()) :: no_return()
  def cancel_order(_credentials, _id, _opts), do: exit(:no_process)
end

defmodule DpExchange.Core.ContractTeethTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{
    AdapterContract,
    Capabilities,
    ReferenceVenue,
    UnwiredCheck,
    UnwiredFixture,
    Venue
  }

  describe "assertion 12 catches both directions of disagreement" do
    test "over-declaring is caught" do
      caps = Broken.OverDeclares.capabilities()
      active = Capabilities.endpoints_at(caps, :proven)

      assert {:get_transfers, 2} in active

      assert Broken.OverDeclares.get_transfers(%{}, []) == {:error, :not_supported},
             "declared active, answers not_supported — the suite must reject this"

      # The decision the suite makes about that answer, not only the fixture's own.
      assert AdapterContract.active_endpoint_fault(Broken.OverDeclares.get_transfers(%{}, [])) ==
               :not_supported
    end

    test "a fake that RAISES on an active endpoint is caught, and refusals are not" do
      # `call_on/3` reports a raise as `{:raised, error}`; that is not `{:error, :not_supported}`
      # so the old `refute result == {:error, :not_supported}` passed it.
      assert AdapterContract.active_endpoint_fault({:raised, %ArgumentError{}}) == :raised

      assert AdapterContract.active_endpoint_fault({:error, :not_supported}) == :not_supported
      assert AdapterContract.active_endpoint_fault({:error, "not_supported"}) == nil
      assert AdapterContract.active_endpoint_fault({:refused, :not_listed}) == nil
      assert AdapterContract.active_endpoint_fault({:ok, []}) == nil
      assert AdapterContract.active_endpoint_fault(:ok) == nil
    end

    test "under-declaring is caught" do
      caps = Broken.UnderDeclares.capabilities()

      assert {:get_transfers, 2} in Capabilities.endpoints_at(caps, :unsupported)

      # The decision the suite makes about that answer, not a comparison made here: declared
      # unsupported but it works is hidden functionality the suite must reject.
      assert AdapterContract.unsupported_fault(Broken.UnderDeclares.get_transfers(%{}, [])) ==
               :served
    end

    test "a string refusal does not satisfy the atom assertion" do
      assert AdapterContract.unsupported_fault(Broken.StringRefusal.get_transfers(%{}, [])) ==
               :string_refusal

      # The atom is the only answer that passes; a raise and any other shape are named too.
      assert AdapterContract.unsupported_fault({:error, :not_supported}) == nil
      assert AdapterContract.unsupported_fault({:raised, %ArgumentError{}}) == :raised
      assert AdapterContract.unsupported_fault({:error, :rate_limited}) == :other
      assert AdapterContract.unsupported_fault({:refused, :not_listed}) == :other
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
      missing = AdapterContract.missing_required_callbacks(Broken.OverDeclares)

      assert length(missing) > 20, "an almost-empty module must fail behaviour completeness"
      assert {:get_price, 2} in missing
      refute {:get_transfers, 2} in missing
      # It exports `capabilities/0` and `get_transfers/2`, and nothing else that is required.
      assert length(missing) == length(Venue.required_callbacks()) - 2
    end

    test "the reference venue is complete" do
      assert AdapterContract.missing_required_callbacks(ReferenceVenue) == []
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
      assert {:refused, :not_listed} = ReferenceVenue.get_price("NOPE-USD", [])

      assert {:error, {:unsupported_timeframe, "1w"}} =
               ReferenceVenue.get_historical_prices("BTC-USD", "1w", [], [])
    end

    test "it pushes on subscribe, as a REST-only venue would" do
      assert :ok = ReferenceVenue.subscribe(~w(BTC-USD), to: self())
      assert_receive {:dp_exchange, :reference_venue, %DpExchange.Core.Types.Quote{}}, 5_000
    end

    test "registering for notices sends none, and a bad subscriber is refused" do
      # Family convention 9: a registration is not an event. A `:link_up` here would be one
      # the real feeds never send, and a consumer's tier-1 test would certify it.
      assert :ok = ReferenceVenue.subscribe_notices(to: self())
      refute_receive {:dp_exchange, :reference_venue, %DpExchange.Core.Notice{}}, 500

      assert {:error, {:invalid_subscriber, 42}} =
               ReferenceVenue.subscribe_notices(to: 42)
    end
  end

  describe "assertion 15 catches coverage_by_kind drifting from coverage/1" do
    # Each test below replicates the exact computation `AdapterContract`'s "15. coverage
    # by kind" group runs, against the same fixtures — proving the computation itself is
    # right, the same pattern assertions 1, 4 and 12 above use in this file.

    # Each test runs `AdapterContract.coverage_by_kind_fault/3`, the decision the group makes.
    defp by_kind_fault(fixture) do
      AdapterContract.coverage_by_kind_fault(
        fixture.coverage_by_kind([]),
        fixture.coverage([]),
        fixture.capabilities().streamable
      )
    end

    test "a conforming fake satisfies both checks" do
      assert by_kind_fault(Broken.CoverageByKind.Conforming) == nil
    end

    test "a fake whose union drops a symbol coverage/1 reports is caught" do
      # Drops ETH-USD from coverage_by_kind/1 on purpose.
      assert by_kind_fault(Broken.CoverageByKind.UnionViolation) ==
               {:union_mismatch, ["BTC-USD"], ["BTC-USD", "ETH-USD"]}
    end

    test "a fake reporting a kind it does not declare streamable is caught" do
      # Reports :order_book while streamable declares only :quotes.
      assert by_kind_fault(Broken.CoverageByKind.UndeclaredKind) ==
               {:undeclared_kinds, [:order_book]}
    end

    test "a symbol kind-reported and not in coverage/1 is a mismatch too, and the union " <>
           "is judged before the kinds" do
      assert AdapterContract.coverage_by_kind_fault(
               %{quotes: %{"A" => :stream, "B" => :stream}},
               %{"A" => :stream},
               [:quotes]
             ) == {:union_mismatch, ["A", "B"], ["A"]}

      assert AdapterContract.coverage_by_kind_fault(%{books: %{"A" => :stream}}, %{}, [:quotes]) ==
               {:union_mismatch, ["A"], []}
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

      gated_and_active = AdapterContract.credential_gated_endpoints(caps, [:equity])

      assert {:get_balances, 2} in gated_and_active

      # The decision the group makes about the stripped call's answer, not a match on the
      # fixture's own canned one: this fixture answers `:ok` with stripped credentials on
      # purpose, and the suite must reject a fake that does.
      stripped = Broken.CredentialGate.NeverChecks.get_balances(%{}, [])
      assert AdapterContract.credential_gate_fault(stripped) == {:succeeded, {:ok, []}}
    end

    test "a fake that actually gates on credentials satisfies the same check" do
      caps = Broken.CredentialGate.Conforming.capabilities()
      assert caps.credential_benefit == :required

      stripped = Broken.CredentialGate.Conforming.get_balances(%{}, [])

      assert AdapterContract.credential_gate_fault(stripped) == nil,
             "the conforming fixture refuses stripped credentials and must not be flagged"

      # A raise or exit is not a refusal either: the gate holds for the wrong reason.
      assert {:raised, _exception} =
               AdapterContract.credential_gate_fault({:raised, %ArgumentError{}})

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

      # And the decision itself, which is what the suite calls: neither `credentials() | nil`
      # callback is ever selected, on any venue, however it declares them.
      all_active = Capabilities.new(endpoints: %{}, supported_quotes: ~w(USD))
      selected = AdapterContract.credential_gated_endpoints(all_active, [:equity])

      refute Enum.any?(selected, fn {name, _arity} ->
               name in [:test_connection, :get_rate_limit_status, :child_spec, :start_link]
             end)

      assert {:get_balances, 2} in selected

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

      refute {:market_status, 1} in AdapterContract.credential_gated_endpoints(
               caps,
               venue.asset_classes()
             )

      assert match?({:ok, _}, venue.market_status(credentials: %{})),
             "a crypto-only venue answers :open with no credential by design — the " <>
               "gate must not flag this callback here"
    end

    test "market_status/1 is still reached by the gate on a venue that is not crypto-only" do
      venue = Broken.CredentialGate.MixedAssetMarketStatus
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      assert venue.asset_classes() != [:crypto]

      assert {:market_status, 1} in AdapterContract.credential_gated_endpoints(
               caps,
               venue.asset_classes()
             )

      # Answers `:ok` with stripped credentials on purpose: a venue serving more than crypto
      # is not exempt, so a real fake shaped this way is rejected like any other unchecked
      # credentialed callback.
      answer = venue.market_status(credentials: %{})
      assert {:succeeded, _answer} = AdapterContract.credential_gate_fault(answer)
    end

    # `get_fees/2` is not a name-based exemption and not crypto-only-exempt — whether
    # the gate reaches it depends on `Capabilities.no_venue_contact?/2`, exercised
    # directly here the same way `AdapterContract` reads it.
    test "get_fees/2 is exempt when declared in no_venue_contact" do
      venue = Broken.CredentialGate.NoVenueContactFees
      caps = venue.capabilities()

      assert caps.credential_benefit == :required
      assert Capabilities.no_venue_contact?(caps, {:get_fees, 2})

      refute {:get_fees, 2} in AdapterContract.credential_gated_endpoints(caps, [:equity])

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

      assert {:get_fees, 2} in AdapterContract.credential_gated_endpoints(caps, [:equity])

      # Answers `:ok` with stripped credentials on purpose: with no `no_venue_contact`
      # declaration this is the 2026-09-06 dp_exchange_webull defect, and a real fake shaped
      # this way must still be rejected.
      answer = venue.get_fees(%{}, [])
      assert {:succeeded, _answer} = AdapterContract.credential_gate_fault(answer)
    end
  end

  describe "assertion 20 catches a subscribe/2 push that is not a Core.Types.* struct" do
    # Runs `AdapterContract.subscribed_push_fault/2`, the decision the "20. subscribed push
    # shape" group makes, on what these fixtures actually push.
    test "a raw, undecoded payload is caught" do
      venue = Broken.Subscribe.RawPayload
      assert :ok = venue.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, _runtime_id, _payload} = message, 5_000

      # A bare map on purpose: the 'raw JSON forwarded to subscribers' shape.
      fault = AdapterContract.subscribed_push_fault(message, venue.runtime_id())
      assert fault == :not_a_core_struct
    end

    test "a message tagged with something other than runtime_id/0 is caught" do
      venue = Broken.Subscribe.WrongTag
      assert :ok = venue.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, _runtime_id, %DpExchange.Core.Types.Quote{}} = message, 5_000

      # A hardcoded atom on purpose: a caller subscribed to several venues could not tell
      # them apart.
      fault = AdapterContract.subscribed_push_fault(message, venue.runtime_id())
      assert fault == :wrong_tag
    end

    test "a struct outside Core.Types is not a Core.Types struct" do
      id = ReferenceVenue.runtime_id()

      assert AdapterContract.subscribed_push_fault({:dp_exchange, id, %URI{}}, id) ==
               :not_a_core_struct

      assert AdapterContract.subscribed_push_fault({:dp_exchange, id, nil}, id) ==
               :not_a_core_struct
    end

    test "the reference venue satisfies both halves" do
      assert :ok = ReferenceVenue.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, _runtime_id, _payload} = message, 5_000

      fault = AdapterContract.subscribed_push_fault(message, ReferenceVenue.runtime_id())
      assert fault == nil
    end
  end

  describe "assertion 21 catches a historical timeframe silently served at the " <>
             "nearest width" do
    test "a fake that substitutes rather than refuses is caught" do
      venue = Broken.HistoricalPrices.Substitutes
      caps = venue.capabilities()

      # The width the suite asks for, chosen by the suite's own function.
      unserved = AdapterContract.unserved_timeframe(caps)
      assert unserved in DpExchange.Core.Timeframe.nameable()
      refute unserved in caps.historical_timeframes

      # This fixture silently substitutes its one declared width for whatever was asked, on
      # purpose: a missing granularity becoming the closest one.
      answer = venue.get_historical_prices("BTC-USD", unserved, [], [])
      assert AdapterContract.timeframe_fault(answer) == :substituted
    end

    test "the reference venue refuses a width it does not declare" do
      unserved = AdapterContract.unserved_timeframe(ReferenceVenue.capabilities())

      assert is_binary(unserved)

      answer = ReferenceVenue.get_historical_prices("BTC-USD", unserved, [], [])
      assert AdapterContract.timeframe_fault(answer) == nil
    end

    test "a venue declaring the whole vocabulary has no width to ask for" do
      caps =
        Capabilities.new(
          endpoints: %{},
          supported_quotes: ~w(USD),
          historical_timeframes: DpExchange.Core.Timeframe.nameable()
        )

      assert AdapterContract.unserved_timeframe(caps) == nil
    end

    test "only a success counts as serving a width that was not declared" do
      assert AdapterContract.timeframe_fault({:ok, []}) == :substituted
      assert AdapterContract.timeframe_fault({:error, :unsupported_timeframe}) == nil
      assert AdapterContract.timeframe_fault({:refused, :unsupported_timeframe}) == nil
    end
  end

  describe "assertions 32 to 35 catch a venue that ignores the family conventions" do
    @base_request %{
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: Decimal.new("0.001"),
      price: Decimal.new("1")
    }

    defp all_cases do
      streaming = AdapterContract.streaming_refusal_cases("BTC-USD", [])

      symbols =
        AdapterContract.single_symbol_refusal_cases(fn _name -> [credentials: %{}] end)

      orders =
        for {request, reason} <- AdapterContract.order_request_cases(@base_request),
            do: {:place_order, [%{}, request, []], reason}

      ids = AdapterContract.order_id_refusal_cases(fn _name -> [[], [credentials: %{}]] end)

      streaming ++ symbols ++ orders ++ ids
    end

    test "the lax module is faulted on every single case, whatever way it is lax" do
      module = Broken.Convention.Lax
      cases = all_cases()
      eligible = AdapterContract.eligible_cases(module, module.capabilities(), cases)

      assert length(eligible) == length(cases)

      faults = AdapterContract.case_faults(module, eligible)

      assert length(faults) == length(cases)
      kinds = faults |> Enum.map(&elem(&1, 3)) |> Enum.map(&(&1 == :raised)) |> Enum.uniq()
      assert Enum.sort(kinds) == [false, true], "both an answer and a raise are faulted"
    end

    test "the reference venue is refused nothing it should accept: no case is faulted" do
      module = ReferenceVenue
      cases = all_cases()
      eligible = AdapterContract.eligible_cases(module, module.capabilities(), cases)

      assert AdapterContract.case_faults(module, eligible) == []
      assert length(eligible) == length(cases)
    end

    test "refusal_fault names exactly what went wrong" do
      want = {:invalid_symbols, nil}

      assert AdapterContract.refusal_fault({:error, want}, want) == nil
      assert AdapterContract.refusal_fault(:ok, want) == {:answered, :ok}

      other = {:error, {:invalid_symbols, 1}}
      assert AdapterContract.refusal_fault(other, want) == {:answered, other}

      not_started = {:error, :feed_not_started}
      assert AdapterContract.refusal_fault(not_started, want) == {:answered, not_started}

      assert AdapterContract.refusal_fault({:raised, %ArgumentError{}}, :x) == :raised
      assert AdapterContract.refusal_fault({:exit, :noproc}, :x) == :raised
      assert AdapterContract.refusal_fault({:throw, :x}, :x) == :raised
    end

    test "a callback declared unsupported, or not exported, is not asked" do
      caps =
        Capabilities.new(
          endpoints: %{{:get_order, 3} => :unsupported},
          supported_quotes: ~w(USD)
        )

      eligible =
        AdapterContract.eligible_cases(Broken.Convention.Lax, caps, all_cases())

      refute Enum.any?(eligible, fn {name, _args, _expected} -> name == :get_order end)
      assert Enum.any?(eligible, fn {name, _args, _expected} -> name == :cancel_order end)

      assert AdapterContract.eligible_cases(Broken.OverDeclares, caps, all_cases()) == []
    end

    test "nothing eligible fails only when an unexported call is declared active" do
      cases = all_cases()

      all_off =
        for {name, args, _expected} <- cases, into: %{}, do: {{name, length(args)}, :unsupported}

      unsupported = Capabilities.new(endpoints: all_off, supported_quotes: ~w(USD))
      declared = Capabilities.new(endpoints: %{}, supported_quotes: ~w(USD))

      # Every driven call declared `:unsupported`: nothing is owed, so nothing is missing.
      refute AdapterContract.nothing_checked?(Broken.OverDeclares, unsupported, cases)

      # Declared active but not exported: the run examined nothing it should have.
      assert AdapterContract.eligible_cases(Broken.OverDeclares, declared, cases) == []
      assert AdapterContract.nothing_checked?(Broken.OverDeclares, declared, cases)

      # Something eligible: checked.
      refute AdapterContract.nothing_checked?(Broken.Convention.Lax, declared, cases)
    end

    test "a failure message prints the call and the expectation, never its arguments" do
      secret = %{api_secret: "never-print-this"}
      cases = [{:get_order, [secret, nil, []], {:invalid_order_id, nil}}]
      faults = AdapterContract.case_faults(Broken.Convention.Lax, cases)
      message = AdapterContract.format_case_faults(faults)

      assert message =~ "get_order/3"
      assert message =~ "invalid_order_id"
      refute message =~ "never-print-this"
    end

    test "the cases cover every bad value the conventions name" do
      cases = AdapterContract.streaming_refusal_cases("BTC-USD", [])
      reasons = Enum.map(cases, &elem(&1, 2))

      assert {:invalid_symbols, nil} in reasons
      assert {:invalid_symbols, ["  "]} in reasons
      assert {:invalid_symbols, "BTC-USD"} in reasons
      assert {:invalid_subscriber, true} in reasons
      assert {:invalid_subscriber, false} in reasons
      refute Enum.any?(reasons, &(&1 == {:invalid_subscriber, nil}))

      # Symbols are judged before the subscriber: this call is wrong in both ways.
      assert {:subscribe, [nil, [to: 42]], {:invalid_symbols, nil}} in cases

      assert AdapterContract.invalid_single_symbols() == [nil, 42, "  "]
      assert AdapterContract.invalid_order_ids() == [nil, "  "]
      assert Enum.any?(AdapterContract.invalid_symbol_lists("A"), &(not is_list(&1)))
    end

    test "a price on a market order must be refused, not dropped" do
      price = {:error, {:unexpected_field, :price}}
      duration = {:error, {:unsupported_order_combination, :market, :gtc}}

      assert AdapterContract.market_price_fault([duration, price]) == nil
      assert AdapterContract.market_price_fault([price]) == nil

      # Dropped: the order placed is not the order asked for.
      assert AdapterContract.market_price_fault([duration, {:ok, :placed}]) ==
               {:answered, {:ok, :placed}}

      # Only ever refused for the duration: nothing showed what the price does.
      assert AdapterContract.market_price_fault([duration]) == :price_never_refused
      # No market type declared: nothing was asked, so nothing is owed.
      assert AdapterContract.market_price_fault([]) == nil

      assert AdapterContract.market_price_fault([{:raised, %ArgumentError{}}, price]) ==
               {:answered, {:raised, %ArgumentError{}}}
    end

    test "a good-till-date duration refused for its expiry key is a duration refusal" do
      price = {:error, {:unexpected_field, :price}}
      expiry = {:error, {:missing_field, :expire_time}}

      assert AdapterContract.market_price_fault([expiry, price]) == nil
      assert AdapterContract.market_price_fault([expiry]) == :price_never_refused

      # A missing order type is not a duration refusal.
      no_type = {:error, {:missing_field, :order_type}}
      assert AdapterContract.market_price_fault([no_type, price]) == {:answered, no_type}
    end

    test "a stop price on the base request is not carried onto the market order" do
      caps = %DpExchange.Core.Capabilities{
        endpoints: %{},
        supported_quotes: ["USD"],
        supported_order_types: [:market, :stop_limit]
      }

      base = %{order_type: :limit, price: Decimal.new("2"), stop_price: Decimal.new("3")}
      [request] = AdapterContract.market_price_requests(base, caps)
      refute Map.has_key?(request, :stop_price)
      assert request.order_type == :market
    end

    test "market requests carry a price, and are not built for a venue with no market type" do
      caps = ReferenceVenue.capabilities()
      requests = AdapterContract.market_price_requests(@base_request, caps)

      assert length(requests) == 3
      assert Enum.all?(requests, &(&1.order_type == :market and &1.price != nil))
      assert Enum.any?(requests, &(not Map.has_key?(&1, :time_in_force)))

      no_market = Capabilities.new(endpoints: %{}, supported_quotes: ~w(USD))
      assert AdapterContract.market_price_requests(@base_request, no_market) == []
    end

    test "the reference venue refuses a market price, and a lax one drops it" do
      caps = ReferenceVenue.capabilities()
      requests = AdapterContract.market_price_requests(@base_request, caps)

      answers = for r <- requests, do: ReferenceVenue.place_order(%{}, r, [])
      assert AdapterContract.market_price_fault(answers) == nil

      lax = for r <- requests, do: Broken.Convention.Lax.place_order(%{}, r, [])
      assert {:answered, {:ok, :placed}} = AdapterContract.market_price_fault(lax)
    end

    test "the reference venue's order checks follow the family order and tags" do
      place = fn request -> ReferenceVenue.place_order(%{}, request, []) end

      assert {:error, {:invalid_symbol, "  "}} = place.(%{@base_request | symbol: "  "})
      assert {:error, {:invalid_side, :short}} = place.(%{@base_request | side: :short})
      assert {:error, {:invalid_quantity, 0.5}} = place.(%{@base_request | quantity: 0.5})
      assert {:error, {:invalid_price, "-1"}} = place.(%{@base_request | price: "-1"})

      assert {:error, {:invalid_quantity, %Decimal{coef: :NaN}}} =
               place.(%{@base_request | quantity: Decimal.new("NaN")})

      assert {:error, {:unexpected_field, :stop_price}} =
               place.(Map.put(@base_request, :stop_price, Decimal.new("1")))

      assert {:ok, %{side: :sell}} = place.(%{@base_request | side: "SELL"})
    end
  end

  describe "assertions 36 to 39 catch a venue that ignores the market-data conventions" do
    alias DpExchange.Core.Types.{Candle, OrderBook, TopOfBook, Trade}

    defp bar(opened_at, price \\ "1") do
      p = Decimal.new(price)

      %Candle{
        symbol: "BTC-USD",
        timeframe: "1h",
        opened_at: opened_at,
        open: p,
        high: p,
        low: p,
        close: p,
        volume: nil,
        provider: :teeth
      }
    end

    defp book(bids, asks) do
      level = fn {price, size} -> {Decimal.new(price), Decimal.new(size)} end

      %OrderBook{
        symbol: "BTC-USD",
        bids: Enum.map(bids, level),
        asks: Enum.map(asks, level),
        observed_at: ~U[2026-08-27 12:00:00Z],
        provider: :teeth
      }
    end

    test "probe_timeframe prefers 1h, then a fixed width, then the first declared" do
      new = fn widths ->
        Capabilities.new(
          endpoints: %{},
          supported_quotes: ~w(USD),
          historical_timeframes: widths
        )
      end

      assert AdapterContract.probe_timeframe(new.(~w(1m 1h 1d))) == "1h"
      assert AdapterContract.probe_timeframe(new.(~w(1M 5m))) == "5m"
      assert AdapterContract.probe_timeframe(new.(~w(1M 1w))) == "1M"
      assert AdapterContract.probe_timeframe(new.([])) == nil
    end

    test "include_partial cases name each bad value; a lax venue is faulted on all" do
      cases = AdapterContract.include_partial_refusal_cases("BTC-USD", "1h", credentials: %{})

      assert {:get_historical_prices, ["BTC-USD", "1h", [], opts], expected} = hd(cases)
      assert expected == {:invalid_option, :include_partial, opts[:include_partial]}
      refute Enum.any?(cases, fn {_n, [_s, _t, _r, o], _e} -> o[:include_partial] == nil end)

      # The reference venue, which checks the option, is refused nothing; one that accepts
      # any value answers `{:ok, _}` and is faulted.
      assert AdapterContract.case_faults(ReferenceVenue, cases) == []

      {_name, _args, want} = hd(cases)
      assert AdapterContract.refusal_fault({:ok, []}, want) == {:answered, {:ok, []}}
    end

    test "candles out of order or off their grid are faulted" do
      a = ~U[2026-08-27 10:00:00Z]
      b = ~U[2026-08-27 11:00:00Z]

      assert AdapterContract.candle_series_fault([bar(a), bar(b)], "1h", [:crypto]) == nil

      assert AdapterContract.candle_series_fault([bar(b), bar(a)], "1h", [:crypto]) ==
               {:unordered, a}

      assert AdapterContract.candle_series_fault([bar(a), bar(a)], "1h", [:crypto]) ==
               {:unordered, a}

      off = ~U[2026-08-27 10:30:00Z]

      assert AdapterContract.candle_series_fault([bar(off)], "1h", [:crypto]) ==
               {:unaligned, off}
    end

    test "a bar labelled with another width than the one asked for is faulted, first" do
      # Group 21 holds the refusal of a width the venue does not serve. This holds the label
      # of one it does: a served width answered with bars stamped as another is the same
      # substitution, one field later, and every bar then joins the wrong series.
      at = ~U[2026-08-27 10:00:00Z]
      daily = %{bar(at) | timeframe: "1d"}

      assert AdapterContract.candle_series_fault([bar(at), daily], "1h", [:crypto]) ==
               {:wrong_timeframe, "1d"}

      # Judged before the grid and the order: the label is what is wrong with this series.
      off_grid_and_mislabelled = %{bar(~U[2026-08-27 10:30:00Z]) | timeframe: "1m"}

      assert AdapterContract.candle_series_fault([off_grid_and_mislabelled], "1h", [:crypto]) ==
               {:wrong_timeframe, "1m"}
    end

    test "a session-traded venue gets a 30-minute grid for a wider intraday width only" do
      open = ~U[2026-08-27 13:30:00Z]

      assert AdapterContract.candle_series_fault([bar(open)], "1h", [:equity]) == nil

      assert AdapterContract.candle_series_fault([bar(open)], "1h", [:crypto]) ==
               {:unaligned, open}

      assert AdapterContract.candle_series_fault([bar(open)], "1h", [:crypto, :equity]) == nil

      # 30 minutes and under stay strict, and so do days.
      quarter = ~U[2026-08-27 13:20:00Z]

      quarter_bar = %{bar(quarter) | timeframe: "15m"}

      assert AdapterContract.candle_series_fault([quarter_bar], "15m", [:equity]) ==
               {:unaligned, quarter}

      daily_bar = %{bar(open) | timeframe: "1d"}

      assert AdapterContract.candle_series_fault([daily_bar], "1d", [:equity]) ==
               {:unaligned, open}

      off = ~U[2026-08-27 13:45:00Z]

      assert AdapterContract.candle_series_fault([bar(off)], "1h", [:equity]) ==
               {:unaligned, off}
    end

    test "range probes keep the first bar and drop the last" do
      a = ~U[2026-08-27 10:00:00Z]
      b = ~U[2026-08-27 11:00:00Z]
      c = ~U[2026-08-27 12:00:00Z]

      assert AdapterContract.candle_range_probes([]) == []

      assert AdapterContract.candle_range_probes([bar(a), bar(b), bar(c)]) ==
               [{[start: a, end: c], [a]}]

      assert AdapterContract.candle_range_probes([bar(a)]) ==
               [{[start: a], [a]}, {[end: a], []}]
    end

    test "an end that is inclusive, a start that is exclusive, or a stray bar is faulted" do
      a = ~U[2026-08-27 10:00:00Z]
      c = ~U[2026-08-27 12:00:00Z]
      range = [start: a, end: c]

      assert AdapterContract.range_fault(range, {:ok, [bar(a)]}, [a]) == nil
      both = {:ok, [bar(a), bar(c)]}
      assert AdapterContract.range_fault(range, both, [a]) == {:outside_range, c}
      assert AdapterContract.range_fault(range, {:ok, []}, [a]) == {:missing, a}
      assert AdapterContract.range_fault([start: c], {:ok, [bar(a)]}, [c]) == {:outside_range, a}
      assert AdapterContract.range_fault([end: a], {:ok, [bar(a)]}, []) == {:outside_range, a}

      # A refusal says nothing about the bounds.
      assert AdapterContract.range_fault(range, {:error, :range_too_wide}, [a]) == nil
    end

    test "the reference venue keeps [start, end) and a lax venue that ignores it is faulted" do
      a = ~U[2026-08-27 12:00:00Z]
      ask = fn range -> ReferenceVenue.get_historical_prices("BTC-USDC", "1h", range, []) end

      for {range, must} <- AdapterContract.candle_range_probes(elem(ask.([]), 1)) do
        assert AdapterContract.range_fault(range, ask.(range), must) == nil
      end

      # Ignoring `:end`, as a venue that has the bar whatever the range says.
      ignores_end = {:ok, [bar(a)]}
      assert AdapterContract.range_fault([end: a], ignores_end, []) == {:outside_range, a}
    end

    test "a book deeper than the depth asked for is faulted" do
      deep = {:ok, book([{"2", "1"}, {"1", "1"}], [{"3", "1"}])}
      shallow = {:ok, book([{"2", "1"}], [{"3", "1"}])}

      assert AdapterContract.book_probe_depth() == 1
      assert AdapterContract.book_depth_fault(shallow, 1) == nil
      assert AdapterContract.book_depth_fault(deep, 1) == {:too_many_levels, :bids, 2}

      asks = {:ok, book([{"2", "1"}], [{"3", "1"}, {"4", "1"}])}
      assert AdapterContract.book_depth_fault(asks, 1) == {:too_many_levels, :asks, 2}
      # A venue's own minimum is the family's refusal; anything else that is not a book is a
      # fake that did not honour `:depth`, not a pass for having examined nothing.
      assert AdapterContract.book_depth_fault({:error, {:invalid_option, :depth, 1}}, 1) == nil
      assert AdapterContract.book_depth_fault({:error, :nope}, 1) == {:answered, {:error, :nope}}

      assert AdapterContract.book_depth_fault({:refused, :no_quote}, 1) ==
               {:answered, {:refused, :no_quote}}

      assert AdapterContract.book_depth_fault({:raised, %RuntimeError{message: "x"}}, 1) ==
               {:answered, {:raised, %RuntimeError{message: "x"}}}
    end

    test "catalog_access: :query_only needs exactly {:error, {:query_required, venue}}" do
      required = {:error, {:query_required, :venue}}

      assert AdapterContract.catalog_access_fault(:query_only, required) == nil

      for other <- [
            {:error, {:missing_credentials, :venue}},
            {:error, :not_supported},
            {:error, "boom"},
            {:ok, []}
          ] do
        assert AdapterContract.catalog_access_fault(:query_only, other) == {:answered, other}
      end

      assert AdapterContract.catalog_access_fault(:enumerable, {:ok, []}) == nil
      assert AdapterContract.catalog_access_fault(:enumerable, {:error, :x}) == nil
      assert AdapterContract.catalog_access_fault(:enumerable, required) == :query_required
    end

    test "the reference venue honours :depth" do
      {:ok, one} = ReferenceVenue.get_order_book("BTC-USDC", depth: 1)
      assert length(one.bids) == 1 and length(one.asks) == 1
    end

    test "a limit is refused as unsupported, tolerated, or faulted for anything else" do
      ok = {:ok, book([{"2", "1"}], [{"3", "1"}])}

      assert AdapterContract.book_limit_fault(ok, ok) == nil
      assert AdapterContract.book_limit_fault(ok, {:error, {:unsupported_option, :limit}}) == nil
      assert AdapterContract.book_limit_fault(ok, {:error, {:invalid_option, :limit, 1}}) == nil
      assert AdapterContract.book_limit_fault(ok, {:raised, %ArgumentError{}}) == :raised
      assert AdapterContract.book_limit_fault(ok, {:exit, :boom}) == :raised

      assert AdapterContract.book_limit_fault(ok, {:error, {:unsupported_option, :depth}}) ==
               {:answered, {:error, {:unsupported_option, :depth}}}

      assert AdapterContract.book_limit_fault(ok, {:refused, :x}) == {:answered, {:refused, :x}}
      # No baseline success, nothing to compare with.
      assert AdapterContract.book_limit_fault({:error, :x}, {:refused, :x}) == nil
    end

    test "assertion 43: an ignored unknown option is a fault, a refusal or :not_supported is not" do
      probe = AdapterContract.unknown_option_probe()
      assert probe == :dp_contract_unknown_option

      assert AdapterContract.unknown_option_fault({:error, {:unknown_option, probe}}) == nil
      assert AdapterContract.unknown_option_fault({:error, :not_supported}) == nil

      # Ignored: the call carried on as if the key were absent.
      assert AdapterContract.unknown_option_fault({:ok, [1]}) == {:ignored, {:ok, [1]}}

      assert AdapterContract.unknown_option_fault({:refused, :not_listed}) ==
               {:ignored, {:refused, :not_listed}}

      # A refusal that names another key, another tag or a bare atom is not the family tag.
      for wrong <- [
            {:error, {:unknown_option, :limt}},
            {:error, {:unsupported_option, probe}},
            {:error, {:invalid_option, probe, true}},
            {:error, :unknown_option},
            :error
          ] do
        assert AdapterContract.unknown_option_fault(wrong) == {:wrong_error, wrong}
      end

      assert AdapterContract.unknown_option_fault({:raised, %ArgumentError{}}) ==
               {:raised, {:raised, %ArgumentError{}}}

      assert {:raised, {:exit, :boom}} = AdapterContract.unknown_option_fault({:exit, :boom})
    end

    test "the reference venue refuses an unknown option on each read, symbol checked first" do
      probe = AdapterContract.unknown_option_probe()
      refusal = {:error, {:unknown_option, probe}}

      assert ReferenceVenue.get_price("BTC-USDC", [{probe, true}]) == refusal
      assert ReferenceVenue.get_top_of_book("BTC-USDC", [{probe, true}]) == refusal
      assert ReferenceVenue.get_symbols([{probe, true}]) == refusal
      assert ReferenceVenue.get_order_book("BTC-USDC", [{probe, nil}]) == refusal
      assert ReferenceVenue.get_trades("BTC-USDC", [{probe, true}]) == refusal
      assert {:error, {:invalid_symbol, nil}} = ReferenceVenue.get_price(nil, [{probe, true}])
      assert {:ok, _quote} = ReferenceVenue.get_price("BTC-USDC", credentials: %{})
    end

    test "a price at or below zero is faulted on a quote, trade and candle" do
      zero = Decimal.new("0")

      quote_ = %DpExchange.Core.Types.Quote{
        symbol: "X",
        price: zero,
        observed_at: ~U[2026-08-27 12:00:00Z],
        provider: :teeth
      }

      assert AdapterContract.market_value_fault(quote_) == {:non_positive, :price, zero}

      trade = %Trade{
        id: nil,
        symbol: "X",
        side: nil,
        price: Decimal.new("-1"),
        quantity: Decimal.new("1"),
        timestamp: ~U[2026-08-27 12:00:00Z],
        provider: :teeth
      }

      assert AdapterContract.market_value_fault([trade]) ==
               {:non_positive, :price, Decimal.new("-1")}

      assert AdapterContract.market_value_fault(%{bar(~U[2026-08-27 10:00:00Z]) | low: zero}) ==
               {:non_positive, :low, zero}

      assert AdapterContract.market_value_fault(bar(~U[2026-08-27 10:00:00Z])) == nil
      assert AdapterContract.market_value_fault(:not_a_struct) == nil
    end

    test "a top of book bid or ask is nil or above zero" do
      top = fn bid, ask ->
        %TopOfBook{
          symbol: "X",
          bid: bid,
          ask: ask,
          bid_size: nil,
          ask_size: nil,
          observed_at: ~U[2026-08-27 12:00:00Z],
          provider: :teeth
        }
      end

      assert AdapterContract.market_value_fault(top.(nil, Decimal.new("1"))) == nil
      zero = Decimal.new("0")

      assert AdapterContract.market_value_fault(top.(Decimal.new("1"), zero)) ==
               {:non_positive, :ask, zero}

      # A price that is not a Decimal at all cannot be judged positive, so it is faulted.
      assert AdapterContract.market_value_fault(top.("1.5", Decimal.new("1"))) ==
               {:non_positive, :bid, "1.5"}
    end

    test "a book level whose price is not a Decimal is faulted, not passed" do
      assert AdapterContract.market_value_fault(book([{"2", "1"}], [{"3", "1"}])) == nil

      assert AdapterContract.market_value_fault(%{
               book([], [])
               | bids: [{2.5, Decimal.new("1")}]
             }) == {:non_positive, {:bids, :price}, 2.5}
    end

    test "a book level with no size or no price, or a side out of order, is faulted" do
      assert AdapterContract.market_value_fault(book([{"2", "1"}, {"1", "3"}], [{"3", "1"}])) ==
               nil

      assert AdapterContract.market_value_fault(book([{"2", "0"}], [{"3", "1"}])) ==
               {:non_positive, {:bids, :size}, Decimal.new("0")}

      assert AdapterContract.market_value_fault(book([{"2", "1"}], [{"0", "1"}])) ==
               {:non_positive, {:asks, :price}, Decimal.new("0")}

      assert AdapterContract.market_value_fault(book([{"1", "1"}, {"2", "1"}], [{"3", "1"}])) ==
               {:unsorted, :bids}

      assert AdapterContract.market_value_fault(book([{"2", "1"}], [{"4", "1"}, {"3", "1"}])) ==
               {:unsorted, :asks}

      assert AdapterContract.market_value_fault(%{book([], []) | bids: :nope}) ==
               {:unreadable_level, :bids, :nope}

      assert AdapterContract.market_value_fault(%{book([], []) | asks: [:level]}) ==
               {:unreadable_level, :asks, :level}
    end
  end
end
