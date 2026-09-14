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

    test "a bare asset is not decorated with the venue's separator" do
      # The test above cannot reach this. It uses `@concat`, whose separator is `""`, so
      # joining a bare asset to an empty quote is a no-op and passes whatever the code does.
      # With a real separator it did not: `"AAPL"` came back `"AAPL-"`.
      #
      # That is the family's signature shape — a plausible string that matches nothing. It
      # goes into a request URL, the venue answers 404, and `classify/1` reports
      # `{:refused, :not_listed}`: the package telling a caller the VENUE said a symbol is
      # not listed, when what happened is that this function invented a symbol the venue was
      # never asked about. `dp_exchange_coinbase` and `dp_exchange_robinhood` both map with
      # `sep: "-"`.
      assert "AAPL" = CanonicalPair.to_exchange(@dashed, "AAPL")
      assert "BTC" = CanonicalPair.to_exchange(@dashed, "BTC")
      assert "BRK.B" = CanonicalPair.to_exchange(@dashed, "BRK.B")
    end

    test "an alias still reverses when there is no quote to join" do
      assert "XBT" = CanonicalPair.to_exchange(@aliased, "BTC")
    end

    test "a canonical with an empty quote loses the meaningless separator" do
      # `"BTC-"` is not a pair either. Carrying the dash forward would send the venue a
      # symbol with a dangling separator.
      assert "BTC" = CanonicalPair.to_exchange(@dashed, "BTC-")
    end
  end

  describe "quotes is sorted longest-first internally, regardless of caller order (C6)" do
    # The moduledoc requires `quotes` to be given longest-first and nothing enforced it.
    # Verified live: a mapping listing `["USD", "BUSD"]` (shortest-first) mis-split
    # "ETHBUSD" into "ETHB-USD" — "USD" matched before "BUSD" got a chance to — and the
    # round-trip invariant elsewhere in this file does NOT catch that, because
    # concatenation round-trips byte-for-byte regardless of where the cut landed.
    @shortest_first %{sep: "", quotes: ~w(USD BUSD)}
    @longest_first %{sep: "", quotes: ~w(BUSD USD)}

    test "a caller-given shortest-first quote list still splits on the real quote" do
      assert "ETH-BUSD" = CanonicalPair.to_canonical(@shortest_first, "ETHBUSD")
    end

    test "shortest-first and longest-first orderings of the same quotes agree" do
      assert CanonicalPair.to_canonical(@shortest_first, "ETHBUSD") ==
               CanonicalPair.to_canonical(@longest_first, "ETHBUSD")
    end

    test "the round trip survives a shortest-first mapping" do
      assert "ETH-BUSD" ==
               @shortest_first
               |> CanonicalPair.to_exchange("ETH-BUSD")
               |> then(&CanonicalPair.to_canonical(@shortest_first, &1))
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
