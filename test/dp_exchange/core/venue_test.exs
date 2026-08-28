defmodule DpExchange.Core.VenueTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Venue

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
