defmodule DpExchange.Core.Types.VolumeProfile do
  @moduledoc """
  Traded volume split by price and by side within one interval — a "footprint" bar.

  ## A candle says where; this says how much, and who lifted it

  A `Candle` gives four prices and a total volume. It cannot say that of 1,000 shares
  traded, 600 went through at the ask and 400 at the bid, nor that most of the buying
  happened at one price and the selling at another. That split is the whole content here.

  **The two are not derivable from one another in either direction.** A candle cannot be
  reconstructed from a profile that carries no open, and a profile cannot be inferred from
  a candle's single volume number — which is why this is a separate type rather than fields
  bolted onto `Candle`.

  ## `:delta` is signed, and it is not an error when it disagrees with the totals

  `:delta` is the venue's own buy-minus-sell figure. This type does **not** recompute it
  from `:buy_volume` and `:sell_volume`, and does not correct it when the three disagree: a
  venue that classifies some prints as neither aggressive buy nor aggressive sell will
  report totals that do not reconcile, and that gap is information about the venue's
  classifier rather than a fault to paper over.

  ## `:buy_at_price` and `:sell_at_price` are maps keyed on the venue's price string

  Kept as the venue sent them — `%{"24.20" => Decimal, "24.21" => Decimal}` — rather than
  re-keyed on `Decimal`. Two price strings that parse to equal decimals are the same level,
  and merging them here would silently combine two of the venue's rows into one; leaving
  them alone keeps the venue's own grid visible.

  Empty maps mean the venue reported no split, **not** that nothing traded at any price.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :timeframe, :opened_at, :provider]
  defstruct [
    :symbol,
    :timeframe,
    :opened_at,
    :total_volume,
    :delta,
    :buy_volume,
    :sell_volume,
    :buy_at_price,
    :sell_at_price,
    :session,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          timeframe: String.t(),
          opened_at: DateTime.t(),
          total_volume: Decimal.t() | nil,
          delta: Decimal.t() | nil,
          buy_volume: Decimal.t() | nil,
          sell_volume: Decimal.t() | nil,
          buy_at_price: %{String.t() => Decimal.t()} | nil,
          sell_at_price: %{String.t() => Decimal.t()} | nil,
          session: atom() | nil,
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  The price with the most volume across both sides — the point of control.

  Returns the venue's own price string, or `nil` when neither side reported a split.
  **`nil` is not a price**, and a caller that needs one must treat the interval as
  un-profiled rather than substituting the close.

  Ties return the lower price, chosen so the answer is stable across calls rather than
  dependent on map ordering. A caller that cares about ties should read the maps.
  """
  @spec point_of_control(t()) :: String.t() | nil
  def point_of_control(%__MODULE__{buy_at_price: buys, sell_at_price: sells}) do
    buys = buys || %{}
    sells = sells || %{}

    merged =
      Map.merge(buys, sells, fn _price, buy, sell -> Decimal.add(buy, sell) end)

    case Enum.to_list(merged) do
      [] ->
        nil

      levels ->
        # An explicit comparator, because `Decimal` in a sort key would be compared by
        # Erlang term order — which orders the struct's fields, not the number. That
        # silently returns the wrong level and looks like it worked.
        levels
        |> Enum.sort(fn {price_a, volume_a}, {price_b, volume_b} ->
          case Decimal.compare(volume_a, volume_b) do
            :gt -> true
            :lt -> false
            :eq -> lower_price?(price_a, price_b)
          end
        end)
        |> hd()
        |> elem(0)
    end
  end

  # Ties break on what the price string MEANS, not on how it sorts as text.
  #
  # This was `price_a <= price_b`. The keys here are the venue's own price strings — see the
  # moduledoc on why they are kept that way — so that was a lexicographic comparison, and
  # lexicographic order is not numeric order wherever the strings differ in digit count:
  # `"10.00" <= "9.00"` is true, and `"100.5" <= "99"` is true. The doc above promises the
  # LOWER price, and on any tie spanning a digit-count boundary it returned the higher one.
  #
  # Nothing about that was visible. The answer was still one of the tied prices, so it stayed
  # plausible and only its meaning was wrong — and the test that covered ties compared
  # "24.20" with "24.21", where the two orders happen to agree, so it passed throughout.
  defp lower_price?(price_a, price_b) do
    case {parsed_price(price_a), parsed_price(price_b)} do
      # Neither is a number this module can read. Any total order will do, and the string one
      # is deterministic, which is what the tie-break is for.
      {nil, nil} ->
        price_a <= price_b

      # A price that parses beats one that does not, rather than the answer depending on
      # which unreadable key the venue happened to send first.
      {nil, _parsed} ->
        false

      {_parsed, nil} ->
        true

      {a, b} ->
        # Two spellings of the same number — "24.2" and "24.20" — are two of the venue's own
        # rows and both are kept (see the moduledoc). They cannot be ordered by value, so the
        # string breaks that tie and the answer stays stable across calls.
        case Decimal.compare(a, b) do
          :eq -> price_a <= price_b
          :lt -> true
          :gt -> false
        end
    end
  end

  # A whole-string parse only: `Decimal.parse/1` answers `{decimal, rest}` and would read
  # "12abc" as 12, which is a value invented from a key this module cannot actually read.
  defp parsed_price(price) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, ""} -> decimal
      _partial_or_error -> nil
    end
  end

  defp parsed_price(_other), do: nil
end
