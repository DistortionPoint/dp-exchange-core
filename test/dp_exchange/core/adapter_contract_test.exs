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

    test "a listed group without its own describe is deliberate, and these are the three" do
      # The reverse direction is NOT asserted, because the mapping is deliberately not 1:1
      # and pinning it would make the list harder to write honestly rather than easier.
      #
      #   * 9 (fake fidelity) is cross-cutting: several groups each check part of it, and no
      #     single describe owns it.
      #
      # **5 (return types) was on this list, and that was the gap.** It was called
      # cross-cutting too — and the parts other groups checked were real, but none asked what
      # 5 states: does an endpoint answer with the `Core.Types` struct its callback promises?
      # `dp_exchange_schwab`'s `get_order/3` and `get_orders/2` returned raw JSON maps, fake
      # included, and nothing here could see it. 5 now has its own describe, reading the
      # promise from `Core.Venue`'s `@callback` specs. A group on this list is one whose
      # check lives elsewhere; "cross-cutting" is worth checking is actually true.
      #   * 6 (error discipline) is checked inside group 12's describe — `{:error,
      #     :not_supported}` as the atom, in both directions against `capabilities/0`.
      #   * 10 (facade completeness and exclusivity) is checked inside group 1's.
      #
      # Pinned so that if one of the three later grows its own describe, or stops being
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

      assert Enum.sort(listed -- Enum.uniq(running)) == [6, 9, 10]
    end
  end

  # --- the call-shape table every fake-driven assertion and assertion 17 share -------

  describe "arg_shape/3 and credentialed_callbacks/0" do
    test "every callback that takes credentials() first is credentialed, by spec" do
      credentialed = DpExchange.Core.AdapterContract.credentialed_callbacks()

      # The eleven the hand-written list did not name, plus the ones it did. A union such as
      # `credentials() | nil` counts, so `test_connection/2` is here too.
      expected =
        ~w(get_balances get_accounts get_fees get_transfers place_order cancel_order get_order
           get_orders get_trade_history test_connection get_rate_limit_status
           list_payment_methods get_payment_method get_notional_balances list_custody_fees
           get_transactions place_orders cancel_all_orders preview_order replace_order
           preview_replace close_position get_trade_volume)a

      assert Enum.sort(expected) == Enum.sort(credentialed)
    end

    test "a callback that does not take credentials first is not credentialed" do
      credentialed = DpExchange.Core.AdapterContract.credentialed_callbacks()

      for name <- ~w(get_price get_symbols withdraw get_deposit_address stake subscribe)a do
        refute name in credentialed, "#{name} takes no credentials() argument"
      end
    end

    test "every credentialed callback is called with its credential first" do
      credentialed = DpExchange.Core.AdapterContract.credentialed_callbacks()

      for {name, arity} <- DpExchange.Core.Venue.behaviour_info(:callbacks),
          name in credentialed do
        shape = DpExchange.Core.AdapterContract.arg_shape(name, arity, true)

        assert hd(shape) == :credentials, "#{name}/#{arity} was shaped #{inspect(shape)}"
        assert length(shape) == arity, "#{name}/#{arity} was shaped #{inspect(shape)}"
      end
    end

    test "an order write is shaped as an order, whatever its credentialed flag" do
      shape = &DpExchange.Core.AdapterContract.arg_shape/3

      assert shape.(:place_order, 3, true) == [:credentials, :order_request, :opts]
      assert shape.(:place_order, 3, false) == [:credentials, :order_request, :opts]
      assert shape.(:place_orders, 3, true) == [:credentials, :order_requests, :opts]
      assert shape.(:preview_order, 3, true) == [:credentials, :order_request, :opts]
      assert shape.(:replace_order, 4, true) == [:credentials, :order_id, :order_changes, :opts]
      assert shape.(:preview_replace, 4, true) == [:credentials, :order_id, :order_changes, :opts]
    end

    test "the default shapes follow arity and the credentialed flag" do
      shape = &DpExchange.Core.AdapterContract.arg_shape/3

      assert shape.(:get_balances, 2, true) == [:credentials, :opts]
      assert shape.(:get_order, 3, true) == [:credentials, :symbol, :opts]
      assert shape.(:get_price, 2, false) == [:symbol, :opts]
      assert shape.(:get_historical_prices, 4, false) == [:symbol, :timeframe, :opts, :opts]
      assert shape.(:quantization, 1, false) == [:symbol]
    end

    test "a callback whose arguments are an asset, an amount or a time is shaped by its spec" do
      # By arity alone `stake/3` was called with "1h" where its Decimal amount belongs and
      # `withdraw/5` with five keyword lists; the fakes raised and the raise was accepted.
      shape = &DpExchange.Core.AdapterContract.arg_shape/3

      assert shape.(:stake, 3, false) == [:asset, :amount, :opts]
      assert shape.(:convert, 4, false) == [:asset, :quote_asset, :amount, :opts]
      assert shape.(:withdraw, 5, false) == [:asset, :network, :amount, :address, :opts]
      assert shape.(:get_fx_rate, 3, false) == [:fx_pair, :at, :opts]
      assert shape.(:get_financials, 3, false) == [:symbol, :statement_kind, :opts]
    end

    test "every callback's shape has exactly its arity" do
      credentialed = DpExchange.Core.AdapterContract.credentialed_callbacks()

      for {name, arity} <- DpExchange.Core.Venue.behaviour_info(:callbacks) do
        shape = DpExchange.Core.AdapterContract.arg_shape(name, arity, name in credentialed)
        assert length(shape) == arity, "#{name}/#{arity} was shaped #{inspect(shape)}"
      end
    end
  end

  # --- assertion 7's decision, which could not reject a dependency -------------------

  describe "permitted_apps/2 and foreign_modules/3" do
    test "a dependency declared with a requirement AND options is declared" do
      permitted =
        DpExchange.Core.AdapterContract.permitted_apps(:decimal, [
          {:jason, "~> 1.4", optional: true},
          {:telemetry, "~> 1.0"},
          {:sibling, path: "../sibling"}
        ])

      for app <- ~w(decimal jason telemetry sibling) do
        assert MapSet.member?(permitted, app), "#{app} is declared"
      end

      refute MapSet.member?(permitted, "req")
    end

    test "a dependency's own runtime dependencies are permitted with it" do
      permitted = DpExchange.Core.AdapterContract.permitted_apps(:req, [])

      assert MapSet.member?(permitted, "req")
      assert MapSet.member?(permitted, "finch")
    end

    test "a module is judged by the application it is built into, not by a deps/ path" do
      lib_dir = Path.join(Mix.Project.build_path(), "lib")

      # The premise the old check got wrong: a dependency is loaded from the build path.
      for module <- [Decimal, Jason, Req] do
        assert module |> :code.which() |> to_string() |> String.starts_with?(lib_dir)
      end

      permitted = DpExchange.Core.AdapterContract.permitted_apps(:decimal, [])

      assert DpExchange.Core.AdapterContract.foreign_modules(
               [Decimal, Jason, Req],
               permitted,
               lib_dir
             ) == [Jason, Req]
    end

    test "OTP and the Elixir standard library are always permitted" do
      lib_dir = Path.join(Mix.Project.build_path(), "lib")
      permitted = DpExchange.Core.AdapterContract.permitted_apps(:decimal, [])

      assert DpExchange.Core.AdapterContract.foreign_modules(
               [Enum, String, :lists, :erlang],
               permitted,
               lib_dir
             ) == []
    end

    test "the package's own modules are permitted only when its own app is" do
      lib_dir = Path.join(Mix.Project.build_path(), "lib")
      own = DpExchange.Core.AdapterContract.permitted_apps(:dp_exchange_core, [])
      other = DpExchange.Core.AdapterContract.permitted_apps(:decimal, [])
      modules = [DpExchange.Core.Venue]

      assert DpExchange.Core.AdapterContract.foreign_modules(modules, own, lib_dir) == []
      assert DpExchange.Core.AdapterContract.foreign_modules(modules, other, lib_dir) == modules
    end

    test "a module no application provides is foreign" do
      lib_dir = Path.join(Mix.Project.build_path(), "lib")
      permitted = DpExchange.Core.AdapterContract.permitted_apps(:decimal, [])
      host_module = Module.concat(["Contract", "HostApplication", "Nowhere"])

      assert DpExchange.Core.AdapterContract.foreign_modules([host_module], permitted, lib_dir) ==
               [host_module]
    end
  end
end
