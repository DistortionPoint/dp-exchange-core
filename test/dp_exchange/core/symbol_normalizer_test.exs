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
      # round-tripping wrong. Asked of `behaviour_info/1`, the function the compiler's own
      # missing-callback check reads: a read of `module_info(:attributes)` for an
      # `optional_callbacks` key answered `[]` whether or not any callback was optional.
      assert SymbolNormalizer.behaviour_info(:optional_callbacks) == []
    end
  end
end
