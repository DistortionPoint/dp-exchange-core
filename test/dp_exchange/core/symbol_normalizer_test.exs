defmodule DpExchange.Core.SymbolNormalizerTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.SymbolNormalizer

  describe "the behaviour is obligatory in both directions" do
    test "declares exactly the two callbacks a venue must implement" do
      callbacks = SymbolNormalizer.behaviour_info(:callbacks)

      assert {:to_canonical_symbol, 1} in callbacks
      assert {:to_exchange_symbol, 1} in callbacks
      assert length(callbacks) == 2
    end

    test "neither direction is optional" do
      # This is what makes the multi-venue promise safe: a package shipping only one
      # direction fails the compiler's missing-callback check rather than silently
      # round-tripping wrong. `optional_callbacks` is absent, so the list is empty.
      optional =
        SymbolNormalizer.module_info(:attributes)
        |> Keyword.get_values(:optional_callbacks)
        |> List.flatten()

      assert optional == []
    end
  end
end
