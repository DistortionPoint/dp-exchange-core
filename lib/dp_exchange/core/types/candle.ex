defmodule DpExchange.Core.Types.Candle do
  @moduledoc """
  One OHLC bar over an interval.

  ## Why this type exists

  `get_historical_prices/4` declared `[Types.Quote.t()]` and the venues returned bare maps
  with their own keys. Both are wrong in the same direction: **a bar is not a quote.** A
  quote is one price at an instant; a bar is four prices and a volume over a span. Flattening
  a bar into a quote either discards the open, high and low, or keeps the close and calls it
  "the price" — a plausible number with the wrong meaning, which is this family's recurring
  defect.

  The untyped map was the more immediate problem: with no type, each venue package chose its
  own keys and nothing compared them. A consumer switching venues got a different map and no
  error.

  ## `:opened_at`, not `:timestamp`

  **Venues disagree about whether a bar is stamped at its open or its close**, and the
  difference is one whole interval. A daily series stamped at the close and joined to one
  stamped at the open is misaligned by a day, and every value in both is correct — which is
  why nothing catches it.

  So the field is named for what it holds. A venue that publishes close-stamped bars
  subtracts the interval on the way in; a venue whose convention is unclear is a venue whose
  candles this package should not be shipping.

  ## `:volume` is `nil` when the venue publishes none

  Never `0`. One venue in this family reports no crypto volume anywhere, and a `0` there
  would claim a genuinely flat interval — a much stronger statement than "not reported", and
  one a consumer might act on.
  """

  @enforce_keys [:symbol, :timeframe, :opened_at, :open, :high, :low, :close, :provider]
  defstruct [
    :symbol,
    :timeframe,
    :opened_at,
    :open,
    :high,
    :low,
    :close,
    :volume,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          timeframe: String.t(),
          opened_at: DateTime.t(),
          open: Decimal.t(),
          high: Decimal.t(),
          low: Decimal.t(),
          close: Decimal.t(),
          volume: Decimal.t() | nil,
          provider: atom()
        }

  @doc """
  Whether the bar's own values are internally consistent — high is the highest, low the
  lowest.

  A bar failing this is malformed at the venue, and worth catching at the boundary rather
  than discovering downstream: a high below the close will silently corrupt any range,
  breakout or volatility calculation built on the series, and none of those will error.
  """
  @spec coherent?(t()) :: boolean()
  def coherent?(%__MODULE__{open: o, high: h, low: l, close: c}) do
    Enum.all?([o, c, l], &(Decimal.compare(h, &1) != :lt)) and
      Enum.all?([o, c, h], &(Decimal.compare(l, &1) != :gt))
  end
end
