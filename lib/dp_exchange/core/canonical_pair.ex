defmodule DpExchange.Core.CanonicalPair do
  @moduledoc """
  The **generic, venue-agnostic** symbol normaliser.

  Canonical form is `BASE-QUOTE`, uppercase, dash-separated (`BTC-USD`). This
  module holds **no venue-specific knowledge** — it converts given a `mapping` that
  each venue package declares inside itself. That split is what keeps Core free of
  venue facts: the venue supplies its separator, quote list and asset aliases; the
  string surgery lives here, once.

  ## Mapping

      %{
        sep: "-" | "",                 # native separator
        quotes: ["USDC", "USD", ...],  # known quote assets
        asset_aliases: %{"XBT" => "BTC"} # exchange base code → canonical (optional)
      }

  A malformed mapping is refused by both directions with an `ArgumentError` naming the key:
  `:sep` must be a binary, `:quotes` a list of binaries, and `:asset_aliases` a map (or a list of
  pairs) whose codes on both sides are non-blank binaries.

  ## `quotes` is sorted longest-first internally, whatever order the caller gives it

  A concat-style mapping (`sep: ""`) has to find the SUFFIX among `quotes` that ends the
  native symbol, and the wrong quote can end it too: `quotes: ["USD", "BUSD"]` against
  `"ETHBUSD"` matches `"USD"` first and cuts `"ETHB-USD"` — wrong, because `"BUSD"` was the
  actual quote. This module used to trust the caller to list `quotes` longest-first, and a
  venue mapping that got the order wrong mis-split silently: the base/quote invariant below
  does **not** catch it, because `to_exchange(m, to_canonical(m, p))` concatenates
  `base <> quote` either way and round-trips byte-for-byte regardless of where the cut
  landed. So `quotes` is sorted by length, descending, before any match is attempted — a
  caller cannot get the ordering wrong any more, whatever it hands in.

  ## Invariant

  `to_canonical(m, to_exchange(m, p)) == p` for every pair. The conformance suite
  asserts this against each venue's own mapping, so a venue whose two directions
  disagree fails before it ships.
  """

  @type mapping :: %{
          required(:sep) => String.t(),
          required(:quotes) => [String.t()],
          optional(:asset_aliases) => %{optional(String.t()) => String.t()}
        }

  @doc """
  Exchange-native symbol → canonical `BASE-QUOTE`, per the connector's `mapping`.
  Unparseable / already-dashed input → uppercased input (never dropped).
  """
  @spec to_canonical(mapping(), String.t()) :: String.t()
  def to_canonical(mapping, native) when is_map(mapping) and is_binary(native) do
    check_mapping!(mapping)
    upper = String.upcase(native)

    case split_native(mapping, upper) do
      {base, quote_} ->
        base_canon = Map.get(aliases(mapping), base, base)
        "#{base_canon}-#{quote_}"

      :nomatch ->
        upper
    end
  end

  @doc """
  Canonical `BASE-QUOTE` → exchange-native, per the connector's `mapping`.

  Input with no quote part is not a pair and is never decorated with a trailing separator,
  which would be a symbol no venue was ever asked about. It comes back uppercased, with an
  `asset_aliases` entry reversed if one applies, and otherwise as it was given. Input with
  no base part (`"-USD"`) is not a pair either, and comes back uppercased and otherwise
  untouched rather than as the bare quote.
  """
  @spec to_exchange(mapping(), String.t()) :: String.t()
  def to_exchange(mapping, canonical) when is_map(mapping) and is_binary(canonical) do
    check_mapping!(mapping)

    case split_canonical(canonical) do
      # No quote part, so this is not a pair and there is nothing to join. Returned as it
      # came, the way `to_canonical/2` returns input it cannot split — the two directions
      # agree about what they cannot interpret.
      #
      # It used to build `"#{base}#{sep}"` regardless, so a mapping with a real separator
      # turned `"AAPL"` into `"AAPL-"`. That is the family's signature shape: a plausible
      # string that matches nothing. It goes into a request URL, the venue answers 404, and
      # `classify/1` reports `{:refused, :not_listed}` — the package telling a caller the
      # VENUE said a symbol is not listed, when what actually happened is that this function
      # invented a symbol the venue was never asked about.
      #
      # `dp_exchange_coinbase` and `dp_exchange_robinhood` both map with `sep: "-"`; the
      # concat venues were never exposed, because joining with `""` is a no-op. The test
      # covering a bare symbol used the concat mapping, which is why this survived.
      #
      # **A pair with no base is not a pair either.** `"-USD"` split to `{"", "USD"}` and was
      # joined to `"" <> sep <> "USD"`: `"USD"` on a concat venue, the QUOTE currency sent as
      # though it were a product, and `"-USD"` with the separator on one that has one.
      # `to_canonical/2` already returns a native symbol with an empty side as it came
      # (`split_native/2` answers `:nomatch`), so the two directions agree again.
      {"", _quote} ->
        String.upcase(canonical)

      {base, ""} ->
        reverse_alias(aliases(mapping), base)

      {base, quote_} ->
        base_ex = reverse_alias(aliases(mapping), base)
        "#{base_ex}#{mapping.sep}#{quote_}"
    end
  end

  # --- internal ----------------------------------------------------------

  # **A malformed mapping is refused by both directions alike.** A missing or non-binary
  # `:sep` was a `KeyError` in `to_exchange/2` but silently read as "no separator" by
  # `to_canonical/2` (a missing key falls through to the concat clause), and `sep: nil` crashed
  # inside `String.contains?/2`. A mapping that breaks the round-trip invariant by being half
  # understood is worse than one that raises at the first symbol. `:quotes`, when present,
  # must be a list of binaries: a string there matched nothing and every symbol came back
  # unsplit.
  defp check_mapping!(%{sep: sep} = mapping) when is_binary(sep) do
    case Map.get(mapping, :quotes, []) do
      quotes when is_list(quotes) ->
        if Enum.all?(quotes, &is_binary/1), do: :ok, else: bad_mapping!(:quotes, quotes)

      other ->
        bad_mapping!(:quotes, other)
    end
  end

  defp check_mapping!(mapping), do: bad_mapping!(:sep, Map.get(mapping, :sep))

  defp bad_mapping!(key, value) do
    wanted =
      case key do
        :sep -> "a binary"
        :asset_aliases -> "a map (or a list of pairs) of binary => binary"
        _quotes -> "a list of binaries"
      end

    raise ArgumentError,
          "CanonicalPair mapping #{inspect(key)} must be #{wanted}, got " <>
            inspect(value, limit: 10, printable_limit: 80)
  end

  # Uppercased, like the input. A mapping written `%{"xbt" => "btc"}` or `quotes: ["usdt"]`
  # was compared against uppercased symbols and silently never matched, and `to_canonical/2`
  # handed the input back as if it were already canonical.
  #
  # **Cached, keyed by the alias map itself.** This used to rebuild and upcase the whole map on
  # every call, and venues call `to_canonical/2` once per message. The key is the caller's own
  # `asset_aliases` term, not a name or a hash of it, so a cache hit is by definition the same
  # aliases and a changed mapping can only miss: there is nothing to invalidate and nothing
  # that can serve one mapping's aliases for another's. (This is not the quote-suffix sort
  # below, whose per-call decision stands.)
  #
  # The cache is one `:persistent_term` holding a map, capped at `@alias_cache_limit`
  # distinct alias maps. A venue has one mapping, so the cap is never reached in production;
  # a test suite minting a mapping per test cannot grow it without bound either: past the cap
  # a new mapping is computed per call, as it always was. Concurrent first calls may each
  # write and one write may be lost, which only means one more miss. The single key is
  # rewritten at most `@alias_cache_limit` times in the life of the node.
  @alias_cache_key {__MODULE__, :aliases}
  @alias_cache_limit 64

  defp aliases(mapping) do
    case Map.get(mapping, :asset_aliases, %{}) do
      raw when is_map(raw) and not is_struct(raw) and map_size(raw) == 0 -> %{}
      raw when is_map(raw) and not is_struct(raw) -> cached_aliases(raw)
      # Not a map (a list of pairs was accepted here before): computed per call, never cached.
      raw when is_list(raw) -> upcase_aliases(raw)
      # Anything else has no pairs to read. `Map.new/2` raised `Protocol.UndefinedError` from
      # inside the first symbol conversion, naming `Enumerable` and not the mapping.
      raw -> bad_mapping!(:asset_aliases, raw)
    end
  end

  defp cached_aliases(raw) do
    cache = alias_cache()
    {upcased, updated} = cache_lookup(cache, raw, @alias_cache_limit)

    if map_size(updated) != map_size(cache) do
      :persistent_term.put(@alias_cache_key, updated)
    end

    upcased
  end

  # Pure: the upcased aliases for `raw` and the cache to keep. A hit returns `cache` as it
  # was; a miss adds `raw` only while the cache holds fewer than `limit` maps.
  @doc false
  @spec cache_lookup(map(), map(), pos_integer()) :: {map(), map()}
  def cache_lookup(cache, raw, limit) do
    case cache do
      %{^raw => upcased} ->
        {upcased, cache}

      _miss ->
        upcased = upcase_aliases(raw)
        kept = if map_size(cache) < limit, do: Map.put(cache, raw, upcased), else: cache
        {upcased, kept}
    end
  end

  # **Every entry is a pair of binaries, or the mapping is refused.** An atom, a `nil` or a
  # number on either side raised `FunctionClauseError` from `String.upcase/1` (or, for a
  # non-pair element of a list, from the anonymous function) inside the first symbol a venue
  # converted, which names neither the mapping nor the alias that is wrong. A blank code on
  # either side is refused too: it matches every symbol's empty remainder or maps one to
  # nothing. This runs once per distinct alias map (a hit in the cache above skips it).
  defp upcase_aliases(raw) do
    Map.new(raw, fn
      {exchange, canonical} when is_binary(exchange) and is_binary(canonical) ->
        alias_pair!(raw, String.upcase(exchange), String.upcase(canonical))

      _not_a_pair_of_binaries ->
        bad_mapping!(:asset_aliases, raw)
    end)
  end

  defp alias_pair!(raw, "", _canonical), do: bad_mapping!(:asset_aliases, raw)
  defp alias_pair!(raw, _exchange, ""), do: bad_mapping!(:asset_aliases, raw)
  defp alias_pair!(_raw, exchange, canonical), do: {exchange, canonical}

  @doc false
  @spec alias_cache() :: %{optional(map()) => map()}
  def alias_cache, do: :persistent_term.get(@alias_cache_key, %{})

  @doc false
  @spec alias_cache_limit() :: pos_integer()
  def alias_cache_limit, do: @alias_cache_limit

  # Split native into {base, quote}. Three cases:
  #   * a real separator ("-", "/") → split on it;
  #   * concat (sep "") → match the longest known quote suffix;
  #   * already-canonical dashed input → :nomatch (returned as-is, round-trips).
  defp split_native(%{sep: sep} = _mapping, upper) when sep != "" do
    if String.contains?(upper, sep) do
      case String.split(upper, sep, parts: 2) do
        [base, quote_] when base != "" and quote_ != "" -> {base, quote_}
        _other -> :nomatch
      end
    else
      :nomatch
    end
  end

  defp split_native(mapping, upper) do
    if String.contains?(upper, "-") do
      :nomatch
    else
      # Sorted longest-first HERE, rather than trusted from `mapping.quotes` as given. The
      # moduledoc requires longest-first — a suffix match against `["USD", "BUSD"]` cuts
      # "ETHBUSD" into "ETHB-USD" because "USD" matches first — and nothing enforced it: a
      # caller supplying quotes in the wrong order got a silent mis-split. Worse, the
      # module's own round-trip invariant does NOT catch it, because concatenation
      # round-trips byte-for-byte regardless of where the cut was made — "ETHB" + "USD" is
      # still "ETHBUSD". Sorting internally means a caller cannot get this wrong, whatever
      # order it hands in.
      #
      # **Profiled 2026-09-07 and deliberately left per-call.** Two independent hot-path
      # audits flagged this sort as recomputed on every `to_canonical/2` rather than once,
      # and measured it: 0.18µs per call, roughly a third of `to_canonical/2`'s own cost —
      # about 2ms spread across the 11,000-frame window a consumer actually reported. That
      # is not a bottleneck by three orders of magnitude, and hoisting it means either
      # trusting `mapping.quotes` to arrive pre-sorted (exactly the caller mistake this
      # sort exists to make impossible) or caching keyed on the mapping, which buys
      # microseconds at the price of cache-invalidation on a path where being wrong means
      # delivering one market's data under another market's name. Recorded here so the
      # next profile does not re-open it: the cost is known, it was weighed, and
      # correctness won.
      # An empty quote is dropped: every string ends with `""`, so it "matched" any symbol no
      # real quote did and cut it into `{symbol, ""}`, which became `"BTCXYZ-"`.
      quotes =
        mapping
        |> Map.get(:quotes, [])
        |> Enum.map(&String.upcase/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.sort_by(&byte_size/1, :desc)

      Enum.find_value(quotes, :nomatch, fn q ->
        if String.ends_with?(upper, q) and byte_size(upper) > byte_size(q) do
          {binary_part(upper, 0, byte_size(upper) - byte_size(q)), q}
        end
      end)
    end
  end

  defp split_canonical(canonical) do
    case String.split(String.upcase(canonical), "-", parts: 2) do
      [base, quote_] -> {base, quote_}
      [single] -> {single, ""}
    end
  end

  # **Two exchange codes for one canonical code are refused, not picked between.** This was
  # `Enum.find_value/3` over the alias map, so `%{"XBT" => "BTC", "XXBT" => "BTC"}` sent
  # whichever code map iteration order reached first, and the other was unreachable. The
  # round-trip invariant cannot catch it, because `to_canonical/2` accepts both. Found
  # 2026-10-10 by reading the path. A mapping that cannot say which code to send is a
  # broken mapping, and raising names it at the first outbound symbol.
  defp reverse_alias(aliases, base) do
    case for({ex_code, ^base} <- aliases, do: ex_code) do
      [] ->
        base

      [ex_code] ->
        ex_code

      ex_codes ->
        raise ArgumentError,
              "asset_aliases maps #{inspect(Enum.sort(ex_codes))} all to #{inspect(base)} — " <>
                "to_exchange/2 cannot choose which one to send"
    end
  end
end
