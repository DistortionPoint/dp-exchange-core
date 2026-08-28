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
        quotes: ["USDC", "USD", ...],  # known quote assets, LONGEST-FIRST
        asset_aliases: %{"XBT" => "BTC"} # exchange base code → canonical (optional)
      }

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
      Enum.find_value(mapping.quotes, :nomatch, fn q ->
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
