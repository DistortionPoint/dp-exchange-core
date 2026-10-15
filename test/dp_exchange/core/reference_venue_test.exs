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
