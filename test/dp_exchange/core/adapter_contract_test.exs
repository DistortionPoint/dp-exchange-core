defmodule DpExchange.Core.AdapterContractTest do
  @moduledoc """
  Core running its own conformance suite against its own reference venue.

  This is what stops the suite's first real exercise happening in a venue repo that
  cannot fix it.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Core.ReferenceVenue,
    fake: DpExchange.Core.ReferenceVenue,
    symbol_format: DpExchange.Core.ReferenceVenue.SymbolFormat,
    sample_pairs: ~w(BTC-USDC ETH-USD BTC-USDT),
    credentials: %{api_key: "reference", api_secret: "reference"},
    # The reference venue lives in `test/support/`, not `lib/` — this package is not
    # itself venue-shaped, and assertion 16 must scope to where the fixture actually
    # is rather than to Core's own many consumer-facing modules.
    package_root: "test/support"

  # --- the published list against the suite that actually runs -----------------

  describe "assertions/0 is the list venues report against, so it must not drift" do
    # `assertions/0` is public, documented as "for documentation and for a venue package to
    # report against", and until now **no test called it**. Nothing connected it to the suite
    # it describes, so an assertion group added without a matching entry — or an entry left
    # behind after a group was renamed — would ship silently. Adding group 25 is what
    # surfaced this: the list had to be updated by hand and nothing would have noticed if it
    # had not been.
    #
    # Checked against the describes THIS module actually generated, rather than by parsing
    # the macro's source, so it reflects the suite as run.
    test "every numbered group that runs is listed" do
      listed =
        DpExchange.Core.AdapterContract.assertions()
        |> Enum.map(&elem(&1, 0))
        |> MapSet.new()

      running =
        __MODULE__.__ex_unit__().tests
        |> Enum.map(& &1.tags.describe)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^(\d+)\./, name) do
            [_whole, n] -> [String.to_integer(n)]
            _unnumbered -> []
          end
        end)
        |> MapSet.new()

      undocumented = MapSet.difference(running, listed)

      assert Enum.empty?(undocumented),
             "assertion group(s) #{inspect(Enum.sort(undocumented))} run in this suite but " <>
               "are absent from assertions/0. A venue reporting against that list would " <>
               "claim conformance it was never measured for."
    end

    test "the numbering is contiguous from 1, so a gap means a group was dropped" do
      numbers = DpExchange.Core.AdapterContract.assertions() |> Enum.map(&elem(&1, 0))

      assert numbers == Enum.to_list(1..length(numbers)),
             "assertions/0 numbers must run 1..n with no gaps and no repeats — got " <>
               inspect(numbers)
    end

    test "a listed group without its own describe is deliberate, and these are the four" do
      # The reverse direction is NOT asserted, because the mapping is deliberately not 1:1
      # and pinning it would make the list harder to write honestly rather than easier.
      #
      #   * 5 (return types) and 9 (fake fidelity) are cross-cutting: several groups each
      #     check part of them, and no single describe owns either.
      #   * 6 (error discipline) is checked inside group 12's describe — `{:error,
      #     :not_supported}` as the atom, in both directions against `capabilities/0`.
      #   * 10 (facade completeness and exclusivity) is checked inside group 1's.
      #
      # Pinned so that if one of the four later grows its own describe, or stops being
      # covered where it is, this test is where the next reader finds out what was intended.
      listed = DpExchange.Core.AdapterContract.assertions() |> Enum.map(&elem(&1, 0))

      running =
        __MODULE__.__ex_unit__().tests
        |> Enum.map(& &1.tags.describe)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn name ->
          case Regex.run(~r/^(\d+)\./, name) do
            [_whole, n] -> [String.to_integer(n)]
            _unnumbered -> []
          end
        end)

      assert Enum.sort(listed -- Enum.uniq(running)) == [5, 6, 9, 10]
    end
  end
end
