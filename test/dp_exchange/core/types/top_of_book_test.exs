defmodule DpExchange.Core.Types.TopOfBookTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Types.TopOfBook

  defp book(bid, ask) do
    %TopOfBook{
      symbol: "BTC-USD",
      bid: bid && Decimal.new(bid),
      ask: ask && Decimal.new(ask),
      observed_at: ~U[2026-08-31 12:00:00Z],
      provider: :reference
    }
  end

  describe "mid/1" do
    test "is the midpoint of the two resting orders" do
      assert Decimal.equal?(TopOfBook.mid(book("100", "102")), Decimal.new("101"))
    end

    test "is nil when either side is missing, rather than the side that is present" do
      # A one-sided book has no mid. Returning the live side would hand back a number that
      # looks like a mid and is not one.
      assert TopOfBook.mid(book(nil, "102")) == nil
      assert TopOfBook.mid(book("100", nil)) == nil
      assert TopOfBook.mid(book(nil, nil)) == nil
    end
  end

  describe "spread/1" do
    test "is ask minus bid" do
      assert Decimal.equal?(TopOfBook.spread(book("100", "102")), Decimal.new("2"))
    end

    test "is nil on a one-sided book" do
      assert TopOfBook.spread(book(nil, "102")) == nil
      assert TopOfBook.spread(book("100", nil)) == nil
    end
  end

  describe "crossed?/1" do
    test "a normal book is not crossed" do
      refute TopOfBook.crossed?(book("100", "102"))
    end

    test "a bid above the ask is crossed" do
      assert TopOfBook.crossed?(book("103", "102"))
    end

    test "a bid equal to the ask is crossed — a locked book is not a normal state either" do
      assert TopOfBook.crossed?(book("102", "102"))
    end

    test "a one-sided book is not crossed, because there is nothing to cross" do
      refute TopOfBook.crossed?(book(nil, "102"))
      refute TopOfBook.crossed?(book("100", nil))
    end
  end

  describe "the shape itself" do
    test "carries no price, and a caller cannot set one" do
      # The whole point of the type. If this ever passes with a :price key, the defect it
      # was built to close has been re-opened.
      refute Map.has_key?(book("100", "102"), :price)
    end

    test "observed_at is required" do
      assert_raise ArgumentError, fn ->
        struct!(TopOfBook, symbol: "BTC-USD", provider: :reference)
      end
    end

    test "sizes default to nil — not published, never zero" do
      b = book("100", "102")
      assert b.bid_size == nil
      assert b.ask_size == nil
    end

    test "venue_time defaults to nil, because many BBO endpoints publish none" do
      assert book("100", "102").venue_time == nil
    end
  end
end
