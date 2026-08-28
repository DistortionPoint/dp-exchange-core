defmodule DpExchange.Core.CanonicalPairTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.CanonicalPair

  doctest CanonicalPair

  # The three real mapping shapes across the family, used as fixtures rather than
  # invented ones: a dash venue whose native form is already canonical, a no-separator
  # venue, and one with asset aliases for legacy codes.
  @dashed %{sep: "-", quotes: ~w(USDC USDT USD EUR GBP BTC ETH)}
  @concat %{sep: "", quotes: ~w(USDC USDT USD EUR GBP BTC ETH)}
  @aliased %{sep: "", quotes: ~w(USD EUR BTC ETH), asset_aliases: %{"XBT" => "BTC"}}

  describe "to_canonical/2" do
    test "splits a separator-bearing native symbol" do
      assert "BTC-USD" = CanonicalPair.to_canonical(@dashed, "BTC-USD")
      assert "ETH-EUR" = CanonicalPair.to_canonical(@dashed, "eth-eur")
    end

    test "splits a separator-less symbol on the longest matching quote" do
      # The ordering in `quotes` is load-bearing: USDC must win over USD, or
      # BTCUSDC parses as BTC-USD with a stray C and the pair silently changes.
      assert "BTC-USDC" = CanonicalPair.to_canonical(@concat, "BTCUSDC")
      assert "BTC-USD" = CanonicalPair.to_canonical(@concat, "BTCUSD")
      assert "BTC-USDT" = CanonicalPair.to_canonical(@concat, "BTCUSDT")
    end

    test "applies asset aliases to the base" do
      assert "BTC-USD" = CanonicalPair.to_canonical(@aliased, "XBTUSD")
    end

    test "unparseable input is uppercased, never dropped" do
      # Losing a symbol is worse than passing one through unrecognised: a dropped
      # symbol is invisible, a strange one is reviewable.
      assert "NOTAPAIR" = CanonicalPair.to_canonical(@concat, "notapair")
      assert "BTCUSD" = CanonicalPair.to_canonical(%{sep: "/", quotes: ~w(USD)}, "BTCUSD")
    end

    test "a quote with no base does not match" do
      assert "USD" = CanonicalPair.to_canonical(@concat, "USD")
    end
  end

  describe "to_exchange/2" do
    test "joins with the venue's separator" do
      assert "BTC-USD" = CanonicalPair.to_exchange(@dashed, "BTC-USD")
      assert "BTCUSD" = CanonicalPair.to_exchange(@concat, "BTC-USD")
    end

    test "reverses asset aliases" do
      assert "XBTUSD" = CanonicalPair.to_exchange(@aliased, "BTC-USD")
    end

    test "a bare asset with no quote survives" do
      assert "BTC" = CanonicalPair.to_exchange(@concat, "BTC")
    end
  end

  describe "the round-trip invariant the conformance suite asserts" do
    @pairs ~w(BTC-USD ETH-USD BTC-USDC ETH-EUR BTC-USDT ETH-GBP)

    test "to_canonical(to_exchange(p)) == p for a dashed venue" do
      for p <- @pairs do
        assert p == CanonicalPair.to_canonical(@dashed, CanonicalPair.to_exchange(@dashed, p))
      end
    end

    test "to_canonical(to_exchange(p)) == p for a separator-less venue" do
      for p <- @pairs do
        assert p == CanonicalPair.to_canonical(@concat, CanonicalPair.to_exchange(@concat, p))
      end
    end

    test "to_canonical(to_exchange(p)) == p through an asset alias" do
      for p <- ~w(BTC-USD BTC-EUR ETH-USD) do
        assert p == CanonicalPair.to_canonical(@aliased, CanonicalPair.to_exchange(@aliased, p))
      end
    end
  end
end
