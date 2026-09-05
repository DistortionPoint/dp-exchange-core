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
  """
  @spec to_exchange(mapping(), String.t()) :: String.t()
  def to_exchange(mapping, canonical) when is_map(mapping) and is_binary(canonical) do
    {base, quote_} = split_canonical(canonical)
    base_ex = reverse_alias(aliases(mapping), base)
    "#{base_ex}#{mapping.sep}#{quote_}"
  end

  # --- internal ----------------------------------------------------------

  defp aliases(mapping), do: Map.get(mapping, :asset_aliases, %{})

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
      quotes = Enum.sort_by(mapping.quotes, &byte_size/1, :desc)

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

  defp reverse_alias(aliases, base) do
    Enum.find_value(aliases, base, fn {ex_code, canon_code} ->
      if canon_code == base, do: ex_code
    end)
  end
end
