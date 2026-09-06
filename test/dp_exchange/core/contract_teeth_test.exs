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
end
