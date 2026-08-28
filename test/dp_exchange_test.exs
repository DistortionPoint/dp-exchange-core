# Defined at the top level, NOT nested inside the test module: `defmodule` inside
# `defmodule DpExchangeTest` would create `DpExchangeTest.DpExchange.TestVenue` and
# alias `DpExchange` to the nested namespace for the rest of the file.

# A stand-in for a venue package, which is a separate Hex package and so is never
# present in this repo's own test run. It is a real module implementing the one thing
# `venue/1` uses to tell a venue from any other module under the namespace — nothing
# is stubbed and no expectation is recorded.
defmodule DpExchange.TestVenue do
  @moduledoc false
  @spec capabilities() :: map()
  def capabilities, do: %{}
end

# Under the namespace, loadable, and deliberately NOT a venue. This is the module that
# would wrongly resolve if `venue/1` checked only that the name existed.
defmodule DpExchange.NotAVenue do
  @moduledoc false
  @spec something_else() :: :ok
  def something_else, do: :ok
end

defmodule DpExchangeTest do
  use ExUnit.Case, async: true

  doctest DpExchange

  describe "venue/1 resolves a name to its facade module" do
    test "accepts a lowercase string" do
      assert {:ok, DpExchange.TestVenue} = DpExchange.venue("test_venue")
    end

    test "accepts an atom" do
      assert {:ok, DpExchange.TestVenue} = DpExchange.venue(:test_venue)
    end

    test "accepts the already-camelized form" do
      assert {:ok, DpExchange.TestVenue} = DpExchange.venue("TestVenue")
    end
  end

  describe "venue/1 fails closed" do
    test "a name that was never compiled does not resolve" do
      assert {:error, :unknown_venue} = DpExchange.venue("definitely_not_a_venue")
    end

    test "a name that was never compiled does not create an atom" do
      # The failure mode this guards: `String.to_atom/1` on caller-supplied input grows
      # the atom table, which is never garbage collected. `Module.safe_concat/2` raises
      # instead, and `venue/1` turns that into an error rather than letting it escape.
      #
      # Asserted by the atom's ABSENCE rather than by a count. `:atom_count` is
      # node-global, so with `async: true` it moves for reasons that have nothing to do
      # with this function — which is precisely the class of failure §7.8 exists to
      # prevent, and this test had it. It failed three runs in eight before the rewrite.
      for i <- 1..200 do
        assert {:error, :unknown_venue} = DpExchange.venue("hostile_input_#{i}")

        assert_raise ArgumentError, fn ->
          String.to_existing_atom("Elixir.DpExchange.HostileInput#{i}")
        end
      end
    end

    test "a loaded module under the namespace that is not a venue does not resolve" do
      assert Code.ensure_loaded?(DpExchange.NotAVenue)
      assert {:error, :unknown_venue} = DpExchange.venue("not_a_venue")
    end

    test "the Core namespace itself does not resolve as a venue" do
      assert {:error, :unknown_venue} = DpExchange.venue("core")
    end

    test "an unrelated existing module does not resolve" do
      assert {:error, :unknown_venue} = DpExchange.venue("Elixir.String")
    end
  end
end
