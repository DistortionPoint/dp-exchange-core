defmodule DpExchange.Core.BehavioursTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{DataProvider, FeedBehaviour, RateLimitBehaviour}

  # These are contracts, so what is worth asserting is the contract itself: which
  # callbacks exist, and which a venue may omit. An optional callback that should have
  # been required is a venue silently shipping without a capability; a required one that
  # should have been optional is ceremony every venue has to fake.

  describe "DataProvider" do
    test "declares the full facade surface" do
      assert length(DataProvider.behaviour_info(:callbacks)) == 24
    end

    test "the declaration callbacks are all required" do
      callbacks = DataProvider.behaviour_info(:callbacks)
      optional = DataProvider.behaviour_info(:optional_callbacks)

      for cb <- [{:provider_name, 0}, {:runtime_id, 0}, {:capabilities, 0}] do
        assert cb in callbacks
        refute cb in optional
      end
    end

    test "list_instruments/1 is optional, by design" do
      # Single-quote `-USD` venues derive base and quote trivially and have no
      # non-spot instruments, so requiring an implementation there is ceremony.
      assert {:list_instruments, 1} in DataProvider.behaviour_info(:optional_callbacks)
    end

    test "every optional callback is also a declared callback" do
      callbacks = DataProvider.behaviour_info(:callbacks)

      for cb <- DataProvider.behaviour_info(:optional_callbacks) do
        assert cb in callbacks
      end
    end
  end

  describe "FeedBehaviour" do
    test "declares three callbacks, none optional" do
      assert length(FeedBehaviour.behaviour_info(:callbacks)) == 3
      assert FeedBehaviour.behaviour_info(:optional_callbacks) == []
    end
  end

  describe "RateLimitBehaviour" do
    test "declares acquire, check and record, none optional" do
      callbacks = RateLimitBehaviour.behaviour_info(:callbacks)

      assert {:acquire, 3} in callbacks
      assert {:check, 3} in callbacks
      assert {:record, 3} in callbacks
      assert RateLimitBehaviour.behaviour_info(:optional_callbacks) == []
    end

    test "defines no functions of its own — it is a pure contract" do
      # The property the host had to assert with `use Boundary, deps: []`, and that is
      # structural here. A contract module that implements anything is no longer a
      # contract both sides can depend on; it is code one of them now owns.
      #
      # Asserted through the export list rather than the BEAM `imports` chunk: cover
      # instrumentation rewrites imports, so an imports-based check fails under
      # `mix test --cover` while nothing is actually wrong. Exports are stable across
      # both compilation modes.
      own_functions =
        RateLimitBehaviour.module_info(:exports)
        |> Enum.reject(fn {name, _arity} ->
          # Compiler-generated on every module, in every compilation mode.
          name in [:module_info, :behaviour_info, :__info__]
        end)

      assert own_functions == []
    end
  end
end
