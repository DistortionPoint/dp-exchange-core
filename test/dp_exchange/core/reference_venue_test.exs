defmodule DpExchange.Core.ReferenceVenueTest do
  @moduledoc """
  The refusals `DpExchange.Core.ReferenceVenue` makes that no conformance assertion drives.

  The reference venue is what a venue author copies, so each refusal here is the family
  convention a copy inherits: a malformed input is named and refused, never defaulted.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.ReferenceVenue, as: Reference
  alias DpExchange.Core.Types

  @limit %{symbol: "BTC-USD", side: :buy, order_type: :limit, quantity: "1", price: "100"}

  describe "start_link/1 and child_spec/1" do
    test "the reference venue is a stateless facade: there is no process to start" do
      assert Reference.start_link([]) == :ignore
    end

    test "options without credentials, or with a credentials value that is not a map, pass through" do
      assert %{id: :ref, start: {Reference, :start_link, [[name: :ref]]}} =
               Reference.child_spec(name: :ref)

      assert %{start: {Reference, :start_link, [[credentials: nil]]}} =
               Reference.child_spec(credentials: nil)
    end
  end

  describe "place_order/3 refusals" do
    test "a side may be spelled as text in any case, and the order carries the atom" do
      for {spelled, side} <- [{"Buy", :buy}, {"SELL", :sell}] do
        assert {:ok, %Types.Order{side: ^side}} =
                 Reference.place_order(%{}, %{@limit | side: spelled}, [])
      end
    end

    test "text that is not a side is refused with the value, not defaulted" do
      assert {:error, {:invalid_side, "short"}} =
               Reference.place_order(%{}, %{@limit | side: "short"}, [])
    end

    test "a missing side is a missing field" do
      assert {:error, {:missing_field, :side}} =
               Reference.place_order(%{}, Map.delete(@limit, :side), [])
    end

    test "an order type the venue does not serve is refused" do
      assert {:error, {:unsupported_order_type, :stop}} =
               Reference.place_order(%{}, %{@limit | order_type: :stop}, [])
    end

    test "a time in force the venue does not serve is refused with the combination" do
      assert {:error, {:unsupported_order_combination, :limit, :day}} =
               Reference.place_order(%{}, Map.put(@limit, :time_in_force, :day), [])
    end

    test "a missing quantity is a missing field" do
      assert {:error, {:missing_field, :quantity}} =
               Reference.place_order(%{}, Map.delete(@limit, :quantity), [])
    end

    test "a market order carries no price, and none is invented" do
      market = @limit |> Map.delete(:price) |> Map.put(:order_type, :market)

      assert {:ok, %Types.Order{order_type: :market, price: nil}} =
               Reference.place_order(%{}, market, [])
    end

    test "an amount with an exponent past the bound is refused before it is compared" do
      # `Decimal.gt?/2` aligns exponents with `10^difference`: these made the venue allocate
      # a number of a billion digits before it refused them. Refused unread, with the value as
      # given, the way NaN is.
      hostile = [
        %Decimal{sign: 1, coef: 1, exp: 999_999_999},
        %Decimal{sign: 1, coef: 1, exp: -999_999_999},
        Decimal.new("1e5000")
      ]

      for bad <- hostile do
        assert {:error, {:invalid_quantity, ^bad}} =
                 Reference.place_order(%{}, %{@limit | quantity: bad}, [])

        assert {:error, {:invalid_price, ^bad}} =
                 Reference.place_order(%{}, %{@limit | price: bad}, [])

        assert {:error, {:invalid_amount, ^bad}} = Reference.convert("BTC", "USD", bad, [])
      end

      # The largest exponent admitted still places, so the bound is a bound and not a refusal
      # of anything with an exponent.
      edge = %Decimal{sign: 1, coef: 1, exp: 1_000}
      assert {:ok, %Types.Order{}} = Reference.place_order(%{}, %{@limit | quantity: edge}, [])
    end

    test "a blank or non-text client order id is refused, a text one accepted" do
      for bad <- ["  ", 42] do
        assert {:error, {:invalid_client_order_id, ^bad}} =
                 Reference.place_order(%{}, Map.put(@limit, :client_order_id, bad), [])
      end

      assert {:ok, %Types.Order{}} =
               Reference.place_order(%{}, Map.put(@limit, :client_order_id, "mine-1"), [])
    end
  end

  describe "the other refusals" do
    test "get_historical_prices/4 refuses a symbol that is not text before looking anything up" do
      assert {:error, {:invalid_symbol, nil}} =
               Reference.get_historical_prices(nil, "1h", {~D[2026-01-01], ~D[2026-01-02]}, [])
    end

    test "get_historical_prices/4 refuses :limit, which it has no parameter for (MD4)" do
      assert {:error, {:unsupported_option, :limit}} =
               Reference.get_historical_prices("BTC-USD", "1h", [], limit: 5)
    end

    test "get_historical_prices/4 refuses a malformed range, not raises on it" do
      # `Core.Venue`: `{:invalid_range, range}` is a malformed `:start`/`:end` (not DateTimes,
      # or `:start` not before `:end`). The range was read with `Keyword.get/2`, so a tuple
      # raised and a string reached `DateTime.compare/2`.
      earlier = ~U[2026-08-27 11:00:00Z]
      later = ~U[2026-08-27 13:00:00Z]

      bad_ranges = [
        {earlier, later},
        nil,
        [start: "2026-08-27"],
        [end: 5],
        [start: later, end: earlier],
        [start: earlier, end: earlier],
        [start: earlier] ++ [:end]
      ]

      for bad <- bad_ranges do
        assert {:error, {:invalid_range, ^bad}} =
                 Reference.get_historical_prices("BTC-USD", "1h", bad, [])
      end

      assert {:ok, [_bar]} =
               Reference.get_historical_prices("BTC-USD", "1h", [start: earlier, end: later], [])

      assert {:ok, [_bar]} = Reference.get_historical_prices("BTC-USD", "1h", [start: nil], [])
    end

    test "get_historical_prices/4 checks the range after the symbol and before the options" do
      assert {:error, {:invalid_symbol, nil}} =
               Reference.get_historical_prices(nil, "1h", :nope, [])

      assert {:error, {:invalid_range, :nope}} =
               Reference.get_historical_prices("BTC-USD", "1h", :nope, limit: 5)
    end

    test "get_volume_profile/3 refuses what the contract refuses, in its order" do
      assert {:error, {:invalid_symbol, nil}} = Reference.get_volume_profile(nil, "1h", [])
      assert {:error, {:invalid_symbol, "  "}} = Reference.get_volume_profile("  ", "1h", [])

      assert {:error, {:unknown_option, :nope}} =
               Reference.get_volume_profile("BTC-USD", "1h", nope: 1)

      assert {:refused, :not_listed} = Reference.get_volume_profile("NOPE-USD", "1h", [])

      assert {:error, {:unsupported_timeframe, "1w"}} =
               Reference.get_volume_profile("BTC-USD", "1w", [])

      assert {:ok, [%Types.VolumeProfile{symbol: "BTC-USD", timeframe: "1h"}]} =
               Reference.get_volume_profile("BTC-USD", "1h", [])
    end

    test "preview_order/3 checks its request exactly as place_order/3 does" do
      assert {:error, {:invalid_order_request, nil}} = Reference.preview_order(%{}, nil, [])

      assert {:error, {:missing_field, :order_type}} =
               Reference.preview_order(%{}, Map.delete(@limit, :order_type), [])

      assert {:error, {:invalid_quantity, "0"}} =
               Reference.preview_order(%{}, %{@limit | quantity: "0"}, [])

      assert {:error, {:unsupported_order_field, :leverage}} =
               Reference.preview_order(%{}, Map.put(@limit, :leverage, 2), [])

      # The request before the options.
      assert {:error, {:missing_field, :side}} =
               Reference.preview_order(%{}, Map.delete(@limit, :side), nope: 1)

      assert {:error, {:unknown_option, :nope}} = Reference.preview_order(%{}, @limit, nope: 1)
      assert {:ok, %{request: @limit}} = Reference.preview_order(%{}, @limit, [])
    end

    test "replace_order/4 and preview_replace/4 judge every field of a change map" do
      {:ok, %{id: id}} = Reference.place_order(%{}, @limit, [])

      calls = [
        &Reference.replace_order(%{}, id, &1, []),
        &Reference.preview_replace(%{}, id, &1, [])
      ]

      for call <- calls do
        # A non-map and an empty map change nothing.
        for bad <- [nil, [price: "1"], "price", %{}] do
          assert {:error, {:invalid_order_request, ^bad}} = call.(bad)
        end

        assert {:error, {:unsupported_order_field, :leverage}} = call.(%{leverage: 2})
        assert {:error, {:invalid_symbol, "  "}} = call.(%{symbol: "  "})
        assert {:error, {:invalid_side, "up"}} = call.(%{side: "up"})
        assert {:error, {:unsupported_order_type, :stop}} = call.(%{order_type: :stop})

        assert {:error, {:unsupported_order_combination, _type, :day}} =
                 call.(%{time_in_force: :day})

        assert {:error, {:invalid_quantity, "-1"}} = call.(%{quantity: "-1"})
        assert {:error, {:invalid_quantity, 0.5}} = call.(%{quantity: 0.5})
        assert {:error, {:invalid_price, nil}} = call.(%{price: nil})
        assert {:error, {:invalid_price, "0"}} = call.(%{price: "0"})
        assert {:error, {:unexpected_field, :stop_price}} = call.(%{stop_price: "1"})
        assert {:error, {:invalid_client_order_id, "  "}} = call.(%{client_order_id: "  "})
      end

      # A field the map leaves out is not required: that is what makes it a change.
      assert {:ok, %{id: ^id, status: :open}} =
               Reference.replace_order(%{}, id, %{price: "2"}, [])

      assert {:ok, %{order_id: ^id}} = Reference.preview_replace(%{}, id, %{quantity: 2}, [])
    end

    test "replace_order/4 checks the id, then the change map, then the options, then the order" do
      assert {:error, {:invalid_order_id, nil}} = Reference.replace_order(%{}, nil, %{}, [])

      assert {:error, {:invalid_order_request, %{}}} =
               Reference.replace_order(%{}, "order-1", %{}, nope: 1)

      assert {:error, {:unknown_option, :nope}} =
               Reference.replace_order(%{}, "order-1", %{price: "1"}, nope: 1)

      assert {:refused, :not_found} = Reference.replace_order(%{}, "order-1", %{price: "1"}, [])
    end

    test "a cancelled order is final: it is not cancelled again, replaced or re-opened" do
      {:ok, %{id: id}} = Reference.place_order(%{}, @limit, [])

      assert {:ok, %Types.Order{status: :cancelled}} = Reference.cancel_order(%{}, id, [])

      assert {:refused, {:order_not_cancellable, :cancelled}} =
               Reference.cancel_order(%{}, id, [])

      assert {:refused, {:order_not_replaceable, :cancelled}} =
               Reference.replace_order(%{}, id, %{price: "2"}, [])

      assert {:ok, %Types.Order{status: :cancelled}} = Reference.get_order(%{}, id, [])
    end

    test "get_trade_history/2 answers a Fill that its own constructor builds" do
      assert {:ok, [%Types.Fill{} = fill]} = Reference.get_trade_history(%{}, [])
      assert fill == Types.Fill.new(Map.from_struct(fill))
    end

    test "place_orders/3 refuses requests that are not a proper list, before the options" do
      for bad <- [nil, %{}, "orders", @limit, [@limit | @limit]] do
        refused = {:error, {:invalid_argument, :requests}}

        assert Reference.place_orders(%{}, bad, []) == refused
        assert Reference.place_orders(%{}, bad, nope: 1) == refused
      end

      assert {:error, {:unknown_option, :nope}} = Reference.place_orders(%{}, [@limit], nope: 1)
      assert {:ok, [%{"order_id" => _id}]} = Reference.place_orders(%{}, [@limit], [])
    end

    test "get_trades/2 checks the symbol, then its options, and refuses :since and :limit" do
      assert {:error, {:invalid_symbol, ""}} = Reference.get_trades("", limit: 5)

      assert {:error, {:invalid_option, :include_broken, "no"}} =
               Reference.get_trades("BTC-USD", include_broken: "no")

      assert {:error, {:unsupported_option, :since}} =
               Reference.get_trades("BTC-USD", since: ~U[2026-08-28 00:00:00Z])

      assert {:error, {:unsupported_option, :limit}} = Reference.get_trades("BTC-USD", limit: 1)
      assert {:refused, :not_listed} = Reference.get_trades("NOPE-USD", [])
      assert {:ok, [%{broken: false}]} = Reference.get_trades("BTC-USD", [])
      assert {:ok, [_kept, _broken]} = Reference.get_trades("BTC-USD", include_broken: true)
    end

    test "cancel_all_orders/2 names a scope the venue does not know" do
      assert {:error, {:unsupported_scope, :everything}} =
               Reference.cancel_all_orders(%{}, scope: :everything)
    end

    test "get_auction_imbalance/2 refuses a bad symbol before it looks at the auction" do
      for bad <- [nil, "", "  ", :aapl, 5, ["AAPL"]] do
        assert {:error, {:invalid_symbol, ^bad}} =
                 Reference.get_auction_imbalance(bad, auction: :opening)

        assert {:error, {:invalid_symbol, ^bad}} = Reference.get_auction_imbalance(bad, [])
      end
    end

    test "get_auction_imbalance/2 serves both auctions and names one it does not know" do
      for auction <- [:opening, :closing] do
        assert {:ok, [%Types.AuctionImbalance{auction: ^auction}]} =
                 Reference.get_auction_imbalance("AAPL", auction: auction)
      end

      assert {:error, {:unsupported_auction, :midday}} =
               Reference.get_auction_imbalance("AAPL", auction: :midday)
    end

    test "subscribe/2 delivers to a registered name as it does to a pid" do
      name = :"reference_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert :ok = Reference.subscribe(["BTC-USD"], to: name)
      assert_receive {:dp_exchange, _venue, %Types.Quote{symbol: "BTC-USD"}}, 5_000
    end
  end
end
