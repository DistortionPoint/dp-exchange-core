defmodule DpExchange.Core.VenueTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.{ReferenceVenue, Types, Venue}

  doctest Venue

  describe "the facade is one fixed set, never extended per venue" do
    test "every callback is declared here" do
      callbacks = Venue.behaviour_info(:callbacks)

      # Declaration — a consumer decides whether to use the package from these four,
      # so none may need a network or a credential.
      declaration =
        [{:provider_name, 0}, {:runtime_id, 0}, {:asset_classes, 0}, {:capabilities, 0}]

      for cb <- declaration do
        assert cb in callbacks
      end

      # Lifecycle, market data, account/trading, streaming, health.
      for cb <- [
            {:child_spec, 1},
            {:start_link, 1},
            {:get_price, 2},
            {:get_symbols, 1},
            {:get_order_book, 2},
            {:get_balances, 2},
            {:place_order, 3},
            {:subscribe, 2},
            {:unsubscribe, 2},
            {:coverage, 1},
            {:subscribe_notices, 1},
            {:market_status, 1},
            {:test_connection, 2},
            {:get_rate_limit_status, 2}
          ] do
        assert cb in callbacks
      end
    end

    test "only the two genuinely optional endpoints are optional" do
      # Optional means "requiring it is ceremony", not "hard to implement". Anything
      # else optional is a venue silently shipping without a capability.
      assert Enum.sort(Venue.behaviour_info(:optional_callbacks)) ==
               Enum.sort([{:list_instruments, 1}, {:quantization, 1}])
    end

    test "required_callbacks/0 is derived, not hand-maintained" do
      required = Venue.required_callbacks()

      refute {:list_instruments, 1} in required
      refute {:quantization, 1} in required
      assert {:get_price, 2} in required

      assert length(required) ==
               length(Venue.behaviour_info(:callbacks)) -
                 length(Venue.behaviour_info(:optional_callbacks))
    end
  end

  describe "no transport crosses the facade" do
    test "no callback names a transport" do
      # The moment a consumer can ask HOW data arrives, it can branch on the answer,
      # and every consumer above the package forks on transport.
      #
      # Matched per underscore-separated segment rather than as a substring: `sse` is
      # inside `asset_classes` and `ws` is inside plenty of English, so a substring
      # check reports leaks that are not there and would be muted rather than fixed.
      transports = ~w(socket sockets websocket ws mqtt sse grpc frame frames wire)

      for {name, _arity} <- Venue.behaviour_info(:callbacks),
          segment <- String.split(to_string(name), "_") do
        refute segment in transports, "callback #{name} names a transport"
      end
    end

    test "the contract states what never crosses, so an addition has to argue with it" do
      docs = Venue |> Code.fetch_docs() |> elem(4) |> Map.get("en")

      assert docs =~ "Never out"

      for forbidden <- [
            "socket handles",
            "connection pools",
            "rate-limit buckets",
            "signing keys",
            "supervisor pids"
          ] do
        assert docs =~ forbidden
      end
    end

    test "both endpoints exist on every venue, with no flag to branch on" do
      docs = Venue |> Code.fetch_docs() |> elem(4) |> Map.get("en")

      assert docs =~ "Both endpoints always exist"
      refute docs =~ "has_websocket"
    end
  end

  describe "core and peripheral" do
    test "every core endpoint is a real callback" do
      callbacks = Venue.behaviour_info(:callbacks)

      for endpoint <- Venue.core_endpoints() do
        assert endpoint in callbacks, "#{inspect(endpoint)} is core but not a callback"
      end
    end

    test "every peripheral endpoint is a real callback" do
      callbacks = Venue.behaviour_info(:callbacks)

      for {endpoint, _reason} <- Venue.peripheral_endpoints() do
        assert endpoint in callbacks, "#{inspect(endpoint)} is peripheral but not a callback"
      end
    end

    test "core and peripheral do not overlap" do
      peripheral = Venue.peripheral_endpoints() |> Map.keys() |> MapSet.new()
      core = MapSet.new(Venue.core_endpoints())

      assert MapSet.disjoint?(core, peripheral)
    end

    test "between them they classify every callback" do
      # An unclassified endpoint is one nobody decided about, which is how something
      # load-bearing quietly ends up outside the graduation bar.
      classified =
        MapSet.union(
          MapSet.new(Venue.core_endpoints()),
          Venue.peripheral_endpoints() |> Map.keys() |> MapSet.new()
        )

      unclassified = MapSet.difference(MapSet.new(Venue.behaviour_info(:callbacks)), classified)

      assert MapSet.size(unclassified) == 0,
             "unclassified endpoints: #{inspect(MapSet.to_list(unclassified))}"
    end

    test "every peripheral endpoint records WHICH test it fails" do
      # The reason is what a future classifier reasons from. A bare list would make the
      # next person guess.
      for {endpoint, reason} <- Venue.peripheral_endpoints() do
        assert is_binary(reason) and byte_size(reason) > 20,
               "#{inspect(endpoint)} is peripheral without a stated reason"

        assert reason =~ ~r/replaceable|load-bearing/,
               "#{inspect(endpoint)} does not name which of the two tests it fails"
      end
    end

    test "the trading group is core, because nothing but trading proves it" do
      core = MapSet.new(Venue.core_endpoints())

      orders = [{:place_order, 3}, {:cancel_order, 3}, {:get_order, 3}, {:get_orders, 2}]

      for endpoint <- orders do
        assert endpoint in core
      end
    end

    test "historical prices are peripheral, and demonstrably replaceable" do
      assert Venue.peripheral_endpoints()[{:get_historical_prices, 4}] =~ "replaceable"
    end

    test "preview_replace/4 and preview_order/3 are both callbacks, and different ones" do
      # The tempting simplification is one preview callback with an optional order id. It
      # would be wrong: the venue prices an amendment against the resting order's own
      # state, including whatever of it has already filled, so the two calls do not answer
      # the same question with different arguments.
      callbacks = Venue.behaviour_info(:callbacks)

      assert {:preview_order, 3} in callbacks
      assert {:preview_replace, 4} in callbacks
    end

    test "close_position/3 states why get_positions + place_order does not replace it" do
      reason = Venue.peripheral_endpoints()[{:close_position, 3}]

      assert reason =~ "irreplaceable"
      assert reason =~ "residue"
    end

    test "cancel_all_orders/2 refuses without a scope, and does not pick one" do
      # The wide scope reaches orders the caller never placed, including ones entered by a
      # person at the venue's own interface. A default here would make that the answer to a
      # question nobody asked.
      assert {:error, :scope_required} = ReferenceVenue.cancel_all_orders(%{}, [])

      assert {:ok, %{cancelled: _ids, rejected: _rejects}} =
               ReferenceVenue.cancel_all_orders(%{}, scope: :session)

      assert {:ok, _result} = ReferenceVenue.cancel_all_orders(%{}, scope: :account)
    end

    test "a rejected order is reported, not turned into a failed call" do
      # The venue answered, and some orders were already gone. An error here would tell a
      # caller nothing was cancelled when most of it was.
      assert {:ok, %{cancelled: cancelled, rejected: rejected}} =
               ReferenceVenue.cancel_all_orders(%{}, scope: :session)

      assert is_list(cancelled)
      assert is_list(rejected)
    end

    test "convert/4 is not a shorthand for the two-step form, and both are callbacks" do
      # The difference is who carries the price risk: the two-step form shows a rate and
      # holds it, and this one executes at whatever the price is on arrival. A package
      # cannot manufacture the first from the second — quoting a rate it computed itself
      # and calling it held would be a promise the venue never made.
      callbacks = Venue.behaviour_info(:callbacks)

      assert {:convert, 4} in callbacks
      assert {:quote_conversion, 4} in callbacks
      assert {:commit_conversion, 2} in callbacks

      assert Venue.peripheral_endpoints()[{:convert, 4}] =~ "NOT a shorthand"
    end

    test "convert/4 returns a conversion that has already happened" do
      assert {:ok, %Types.Conversion{status: :settled}} =
               ReferenceVenue.convert("USD", "BTC", Decimal.new("100"), [])
    end

    test "get_trade_volume/2 says why summing get_trade_history/2 is not the same" do
      reason = Venue.peripheral_endpoints()[{:get_trade_volume, 2}]

      assert reason =~ "fee"
      assert reason =~ "ledger"
    end
  end

  describe "the public tape" do
    test "get_trades/2 excludes broken trades by default" do
      # An exchange that busts an erroneous print has said it did not stand. Leaving it in
      # a series puts a phantom high or low into every range and volatility figure built on
      # it, and none of them will error.
      assert {:ok, trades} = ReferenceVenue.get_trades("BTC-USD", [])

      assert length(trades) == 1
      refute Enum.any?(trades, & &1.broken)
    end

    test "asking for them includes them, rather than hiding a bust entirely" do
      assert {:ok, trades} = ReferenceVenue.get_trades("BTC-USD", include_broken: true)

      assert length(trades) == 2
      assert Enum.any?(trades, & &1.broken)
    end

    test "a tape trade is not a fill, and the contract has both" do
      # A Fill is your execution and carries an order id because you placed the order. A
      # tape trade has no order of yours behind it.
      callbacks = Venue.behaviour_info(:callbacks)

      assert {:get_trades, 2} in callbacks
      assert {:get_trade_history, 2} in callbacks
      assert Venue.peripheral_endpoints()[{:get_trades, 2}] =~ "own fills"
    end

    test "notional is price times quantity, unrounded" do
      assert {:ok, [trade]} = ReferenceVenue.get_trades("BTC-USD", [])

      assert Decimal.equal?(
               Types.Trade.notional(trade),
               Decimal.mult(trade.price, trade.quantity)
             )
    end

    test "an FX rate names the SOURCE separately from the venue relaying it" do
      # Two facts that both look like "where this came from". Collapsing them makes a
      # Gemini-relayed BCB rate indistinguishable from one Gemini computed itself, and only
      # the second would be the venue's own claim.
      assert {:ok, %Types.FxRate{} = rate} =
               ReferenceVenue.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z], [])

      assert rate.source == "bcb"
      assert rate.provider == :reference_venue
      refute rate.source == to_string(rate.provider)
    end

    test "as_of is the instant asked for, not when it was fetched" do
      # A rate without its instant is a number with no time attached, which is not a rate.
      at = ~U[2020-07-13 15:30:59Z]
      assert {:ok, rate} = ReferenceVenue.get_fx_rate("AUDUSD", at, [])

      assert rate.as_of == at
    end

    test "the benchmark is carried, because two sources can legitimately disagree" do
      assert {:ok, rate} = ReferenceVenue.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z], [])
      assert rate.benchmark == "Spot"
    end

    test "convert/2 multiplies without rounding" do
      assert {:ok, rate} = ReferenceVenue.get_fx_rate("AUDUSD", ~U[2020-07-13 15:30:59Z], [])

      assert Decimal.equal?(
               Types.FxRate.convert(rate, Decimal.new("100")),
               Decimal.mult(Decimal.new("100"), rate.rate)
             )
    end

    test "an FX rate is peripheral, and says it is not the venue's own market" do
      assert Venue.peripheral_endpoints()[{:get_fx_rate, 3}] =~ "relaying"
    end

    test "list_networks/2 answers both directions and refuses neither" do
      # get_deposit_address/3 takes a network and nothing else in the contract says which
      # networks a venue accepts. Guessing one produces an address on a chain the venue does
      # not credit, and funds sent there are gone.
      assert {:ok, [%{"asset" => "USDC"}]} = ReferenceVenue.list_networks("USDC", [])

      assert {:ok, [%{"network" => "ethereum"}]} =
               ReferenceVenue.list_networks(nil, network: "ethereum")

      assert {:error, :asset_or_network_required} = ReferenceVenue.list_networks(nil, [])
    end

    test "list_networks/2 says why a wrong network costs money" do
      assert Venue.peripheral_endpoints()[{:list_networks, 2}] =~ "does not credit"
    end

    test "list_fee_promos/1 is not get_fees/2" do
      # get_fees/2 is the schedule applying to a credential; this is a public list of
      # symbols where the venue charges something other than that schedule. A caller
      # computing cost from the schedule alone is wrong for exactly these symbols.
      callbacks = Venue.behaviour_info(:callbacks)

      assert {:list_fee_promos, 1} in callbacks
      assert {:get_fees, 2} in callbacks

      assert {:ok, [%{"symbol" => "BTCUSD"}]} = ReferenceVenue.list_fee_promos([])
    end
  end

  describe "the money-movement writes" do
    test "a payment method is listed with its status, because presence is not usability" do
      # Venues hold new bank accounts pending verification. A caller filtering on presence
      # picks one the venue will refuse.
      assert {:ok, methods} = ReferenceVenue.list_payment_methods(%{}, [])

      assert Enum.any?(methods, &(&1["status"] == "verified"))
      assert Enum.any?(methods, &(&1["status"] == "pending"))
    end

    test "a newly added payment method is PENDING, not usable" do
      # Venues verify a new bank account out of band; the API call only starts that. A
      # caller treating success as a usable method finds the first transfer refused.
      assert {:ok, method} = ReferenceVenue.add_payment_method(%{"iban" => "GB…"}, [])
      assert method["status"] == "pending"
    end

    test "a batch answers per order, because a partial batch is the normal shape" do
      # A caller told "the batch failed" when four of five were placed has four positions it
      # does not know about.
      requests = [%{symbol: "BTC-USD"}, %{symbol: "ETH-USD"}, %{symbol: "SOL-USD"}]

      assert {:ok, results} = ReferenceVenue.place_orders(%{}, requests, [])
      assert length(results) == length(requests)
      assert Enum.any?(results, &Map.has_key?(&1, "order_id"))
      assert Enum.any?(results, &Map.has_key?(&1, "error"))
    end

    test "a payment method is read by id, because a listing is a snapshot" do
      # A method's verification state changes without the account doing anything. Selecting
      # the row out of an earlier listing reads a status that may have been true an hour ago.
      assert {:ok, method} = ReferenceVenue.get_payment_method(%{}, "bank-1", [])
      assert method["id"] == "bank-1"
      assert method["status"]
    end

    test "a notional balance keeps the quantity and the valuation apart" do
      # The quantity is the venue's ledger; the notional figure is the venue's valuation at
      # a rate it chose and need not publish. One struct would invite reading either as the
      # other, and the valuation is the one that is only ever an estimate.
      assert {:ok, [row]} = ReferenceVenue.get_notional_balances(%{}, "USD", [])
      assert row["amount"] != row["amountNotional"]
      refute is_nil(row["amount"])
      refute is_nil(row["amountNotional"])
    end

    test "custody fees are their own list, because they have no trade behind them" do
      # A fee taken out of the balance directly is a reduction a consumer reconciling
      # against fills alone cannot explain.
      assert {:ok, [fee]} = ReferenceVenue.list_custody_fees(%{}, [])
      assert fee["currency"]
      assert fee["amount"]
    end

    test "transfer_internal/4 is not withdraw/5, and both are callbacks" do
      # Conflating them is dangerous in both directions: reaching for withdraw/5 for an
      # internal move pays a network fee it did not need to, and reaching for this
      # expecting an external transfer sends nothing anywhere.
      callbacks = Venue.behaviour_info(:callbacks)

      assert {:transfer_internal, 4} in callbacks
      assert {:withdraw, 5} in callbacks
      assert Venue.peripheral_endpoints()[{:transfer_internal, 4}] =~ "no chain is"
    end

    test "an internal transfer needs both ends" do
      assert {:error, {:missing_option, :from}} =
               ReferenceVenue.transfer_internal("BTC", Decimal.new("1"), [to: "b"], [])

      assert {:error, {:missing_option, :to}} =
               ReferenceVenue.transfer_internal("BTC", Decimal.new("1"), [from: "a"], [])

      assert {:ok, %{"from" => "a", "to" => "b"}} =
               ReferenceVenue.transfer_internal("BTC", Decimal.new("1"), [from: "a", to: "b"], [])
    end

    test "requesting an approved address returns PENDING — it is not permission" do
      # An address on the allowlist is one funds can be sent to, so venues hold new entries
      # under a time lock. A caller must not treat success here as permission to withdraw.
      assert {:ok, requested} =
               ReferenceVenue.request_approved_address("ethereum", "0xabc", "desk", [])

      assert requested["status"] == "pending"
      refute requested["status"] == "active"
    end

    test "the allowlist write says a successful response is not permission" do
      assert Venue.peripheral_endpoints()[{:request_approved_address, 4}] =~
               "NOT permission to withdraw"
    end

    test "removal is its own callback, and the asymmetry is stated" do
      # The venue is slow to widen what funds may reach and quick to narrow it.
      assert {:ok, %{"status" => "removed"}} =
               ReferenceVenue.remove_approved_address("ethereum", "0xabc", [])

      assert Venue.peripheral_endpoints()[{:remove_approved_address, 3}] =~ "immediate"
    end

    test "transactions are wider than fills and wider than transfers" do
      # It includes fees, interest, dividends and adjustments alongside deposits and fills,
      # and summing it is not a balance.
      assert {:ok, rows} = ReferenceVenue.get_transactions(%{}, [])

      kinds = Enum.map(rows, & &1["type"])
      assert "Trade" in kinds
      assert "Deposit" in kinds
      assert "Fee" in kinds

      assert Venue.peripheral_endpoints()[{:get_transactions, 2}] =~ "not a balance"
    end
  end

  describe "not_supported/0" do
    test "is the atom, never the string" do
      # The source this was extracted from used both — in one module, both forms — so a
      # caller matching the atom silently missed the string and treated a refusal as an
      # unrecognised error.
      assert {:error, reason} = Venue.not_supported()
      assert is_atom(reason)
      assert reason == :not_supported
    end
  end

  describe "notice_kinds/0" do
    test "delegates to the single notice vocabulary" do
      assert Venue.notice_kinds() == DpExchange.Core.Notice.kinds()
    end
  end
end
