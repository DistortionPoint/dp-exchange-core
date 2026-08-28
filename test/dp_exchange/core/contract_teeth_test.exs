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
  # Quote assets in the wrong order, which is the entire USD/USDT/USDC bug: `BTCUSDC`
  # parses as `BTC-USD` with a stray character and every value downstream stays plausible.
  @behaviour DpExchange.Core.SymbolNormalizer

  # Shortest-first, with `USD` a suffix of `BUSD`. That containment is the actual
  # collision: `USDT` and `USDC` do NOT end with `USD`, so those three round-trip in
  # either order, and a test built on them would have proved nothing.
  @mapping %{sep: "", quotes: ~w(USD BUSD)}

  @impl true
  def to_canonical_symbol(native),
    do: DpExchange.Core.CanonicalPair.to_canonical(@mapping, native)

  @impl true
  def to_exchange_symbol(canonical),
    do: DpExchange.Core.CanonicalPair.to_exchange(@mapping, canonical)
end

defmodule DpExchange.Core.ContractTeethTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{Capabilities, ReferenceVenue, Venue}

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
    test "a quote that contains a shorter quote breaks the round trip when misordered" do
      round_tripped =
        "BTC-BUSD"
        |> Broken.SymbolFormat.to_exchange_symbol()
        |> Broken.SymbolFormat.to_canonical_symbol()

      # `BTCBUSD` ends with `USD` before it ends with `BUSD`, so shortest-first splits
      # the base as `BTCB`. Every value downstream stays plausible while naming a pair
      # that does not exist.
      refute round_tripped == "BTC-BUSD"
      assert round_tripped == "BTCB-USD"
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
end
