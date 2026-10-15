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

  describe "a malformed mapping is refused by both directions" do
    test "a missing, nil or non-binary :sep raises in to_canonical and to_exchange" do
      for bad <- [%{quotes: ["USD"]}, %{sep: nil, quotes: ["USD"]}, %{sep: :dash, quotes: []}] do
        assert_raise ArgumentError, ~r/:sep/, fn -> CanonicalPair.to_canonical(bad, "BTCUSD") end
        assert_raise ArgumentError, ~r/:sep/, fn -> CanonicalPair.to_exchange(bad, "BTC-USD") end
      end
    end

    test "a :quotes that is not a list of binaries raises, in both directions" do
      for bad <- ["USD", :usd, %{}, [:usd], [1], ["USD", nil]] do
        mapping = %{sep: "", quotes: bad}

        assert_raise ArgumentError, ~r/:quotes/, fn ->
          CanonicalPair.to_canonical(mapping, "BTCUSD")
        end

        assert_raise ArgumentError, ~r/:quotes/, fn ->
          CanonicalPair.to_exchange(mapping, "BTC-USD")
        end
      end
    end

    test "an absent :quotes is an empty list, and an empty native symbol is returned as it came" do
      assert CanonicalPair.to_canonical(%{sep: ""}, "btcusd") == "BTCUSD"
      assert CanonicalPair.to_canonical(@concat, "") == ""
      assert CanonicalPair.to_exchange(@concat, "") == ""
    end
  end

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

    test "a mapping written in lowercase still matches the uppercased input" do
      # Compared against uppercased symbols, a lowercase quote or alias never matched, and
      # the input came back as if it were already canonical.
      lower = %{sep: "", quotes: ~w(usdt usd), asset_aliases: %{"xbt" => "btc"}}

      assert "BTC-USDT" = CanonicalPair.to_canonical(lower, "XBTUSDT")
      assert "XBTUSD" = CanonicalPair.to_exchange(lower, "BTC-USD")
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

    test "a canonical with an empty base is not turned into the bare quote" do
      # `"-USD"` split to `{"", "USD"}` and was joined to `"" <> sep <> "USD"` — `"USD"` on a
      # concat venue, the quote currency sent as though it were a product. It is not a pair,
      # so it comes back as it was given, which is what `to_canonical/2` does with the same
      # shape.
      assert "-USD" = CanonicalPair.to_exchange(@concat, "-USD")
      assert "-USD" = CanonicalPair.to_exchange(@dashed, "-usd")
      assert "-USD" = CanonicalPair.to_exchange(@aliased, "-USD")
      assert "-USD" = CanonicalPair.to_canonical(@dashed, "-USD")
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

  describe "an empty quote in the mapping" do
    test "never matches: a symbol no real quote ends is returned as it came" do
      mapping = %{sep: "", quotes: ["", "USD"]}

      assert CanonicalPair.to_canonical(mapping, "BTCXYZ") == "BTCXYZ"
      assert CanonicalPair.to_canonical(mapping, "BTCUSD") == "BTC-USD"
    end
  end

  describe "the upcased alias map is cached, keyed by the caller's own alias map" do
    defp unique_aliases(code), do: %{"x#{code}" => "btc#{code}"}

    test "a miss stores the upcased map under the raw map, and a hit returns it unchanged" do
      raw = %{"xbt" => "btc"}

      assert {%{"XBT" => "BTC"}, cache} = CanonicalPair.cache_lookup(%{}, raw, 4)
      assert cache == %{raw => %{"XBT" => "BTC"}}
      assert {%{"XBT" => "BTC"}, ^cache} = CanonicalPair.cache_lookup(cache, raw, 4)
    end

    test "a miss at the limit is answered but not stored" do
      full = %{%{"a" => "b"} => %{"A" => "B"}}
      raw = %{"c" => "d"}

      assert {%{"C" => "D"}, ^full} = CanonicalPair.cache_lookup(full, raw, 1)
    end

    test "the cache key is the alias map's content, so a different map is a different entry" do
      first = %{"xbt" => "btc"}
      second = %{"xbt" => "eth"}
      {_upcased, cache} = CanonicalPair.cache_lookup(%{}, first, 4)

      assert {%{"XBT" => "ETH"}, cache} = CanonicalPair.cache_lookup(cache, second, 4)
      assert map_size(cache) == 2
    end

    test "a real call goes through the cache and answers the same as before" do
      raw = unique_aliases(System.unique_integer([:positive]))
      mapping = %{sep: "", quotes: ~w(USD), asset_aliases: raw}
      [{exchange, canonical}] = Map.to_list(raw)

      assert CanonicalPair.to_canonical(mapping, exchange <> "usd") ==
               String.upcase(canonical) <> "-USD"

      # Twice: the second call is the hit path, whichever way the cache stood.
      assert CanonicalPair.to_canonical(mapping, exchange <> "usd") ==
               String.upcase(canonical) <> "-USD"
    end

    test "two mappings never see each other's aliases" do
      n = System.unique_integer([:positive])
      one = %{sep: "", quotes: ~w(USD), asset_aliases: %{"Q#{n}" => "AAA"}}
      two = %{sep: "", quotes: ~w(USD), asset_aliases: %{"Q#{n}" => "BBB"}}

      assert CanonicalPair.to_canonical(one, "Q#{n}USD") == "AAA-USD"
      assert CanonicalPair.to_canonical(two, "Q#{n}USD") == "BBB-USD"
      assert CanonicalPair.to_canonical(one, "Q#{n}USD") == "AAA-USD"
    end

    test "a mapping with no aliases is never cached" do
      empty = %{sep: "", quotes: ~w(USD), asset_aliases: %{}}

      assert CanonicalPair.to_canonical(%{sep: "", quotes: ~w(USD)}, "BTCUSD") == "BTC-USD"
      assert CanonicalPair.to_canonical(empty, "BTCUSD") == "BTC-USD"
      refute Map.has_key?(CanonicalPair.alias_cache(), %{})
    end

    test "the cache is bounded, and a mapping past the bound is still answered correctly" do
      base = System.unique_integer([:positive])
      limit = CanonicalPair.alias_cache_limit()

      for i <- 1..(limit * 2) do
        raw = %{"y#{base}_#{i}" => "z#{i}"}
        mapping = %{sep: "", quotes: ~w(USD), asset_aliases: raw}

        assert CanonicalPair.to_canonical(mapping, "Y#{base}_#{i}USD") == "Z#{i}-USD"
        assert CanonicalPair.to_exchange(mapping, "Z#{i}-USD") == "Y#{base}_#{i}USD"
        assert map_size(CanonicalPair.alias_cache()) <= limit
      end
    end

    test "a non-map asset_aliases (a keyword list) is still read, and never cached" do
      mapping = %{sep: "", quotes: ~w(USD), asset_aliases: [{"xk", "kk"}]}

      assert CanonicalPair.to_canonical(mapping, "XKUSD") == "KK-USD"
      refute Map.has_key?(CanonicalPair.alias_cache(), [{"xk", "kk"}])
    end
  end

  describe "two exchange codes for one canonical code (found 2026-10-10)" do
    test "to_exchange/2 refuses to choose between them" do
      mapping = %{sep: "", quotes: ~w(USD), asset_aliases: %{"XBT" => "BTC", "XXBT" => "BTC"}}

      assert_raise ArgumentError, ~r/cannot choose/, fn ->
        CanonicalPair.to_exchange(mapping, "BTC-USD")
      end

      # Inbound is unaffected: both codes still read as the canonical one.
      assert CanonicalPair.to_canonical(mapping, "XXBTUSD") == "BTC-USD"
      assert CanonicalPair.to_canonical(mapping, "XBTUSD") == "BTC-USD"
    end
  end
end
