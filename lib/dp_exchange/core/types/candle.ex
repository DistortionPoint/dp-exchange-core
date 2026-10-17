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

  ## `:opened_at` is the bucket start, aligned to the width

  `:opened_at` is the **start** of the bucket and is aligned to the timeframe's width
  (`DpExchange.Core.Timeframe.aligned?/2`). A venue whose bar time is not provably the open
  time checks that on decode and refuses a reply holding a bar that is not aligned,
  `{:error, {:unaligned_candle, time}}`, rather than rounding it into place.

  **The grid depends on the instrument.** Crypto is strict: every width is aligned on the UTC
  grid. For a session-traded instrument (equities, options, futures, events) widths of 30
  minutes and under stay on the strict UTC grid, while a wider intraday width is
  session-anchored and only needs **30-minute** alignment, because US equity sessions open at
  09:30 ET (so a `1h` bar opens at 13:30 or 14:30 UTC). Daily and longer bars are not
  intraday: see below.

  **Equity daily and weekly bars** are stamped by the venue at exchange-local midnight (or
  another local instant). They are mapped to `00:00:00` UTC **of the same session date**.
  The date is the fact; the instant is an artefact of the zone it was written in, and
  converting the instant would put a New York session on the neighbouring calendar day
  depending on the season. Two venues' daily series therefore join on `opened_at` exactly.

  ## A bar may still be forming

  A bar is **in progress** while `opened_at + width > now`. `get_historical_prices/4` does not
  return one unless the caller passes `include_partial: true` (default `false`). This struct
  has **no flag** saying a bar is partial, so with `include_partial: true` the last bar is
  as-of the call and **may still change**: do not store it as a finished bar. Only the last
  bar of a series can be in progress.

  ## `:volume` is `nil` when the venue publishes none

  Never `0`. One venue in this family reports no crypto volume anywhere, and a `0` there
  would claim a genuinely flat interval — a much stronger statement than "not reported", and
  one a consumer might act on.
  """

  alias DpExchange.Core.Types.Validate

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
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — a `%__MODULE__{open: nil, ...}` literal
  builds fine despite `open`'s typespec forbidding it, and blows up later inside `Decimal`
  instead of at the boundary. This is the exact defect that motivated
  `DpExchange.Core.Types.Validate`, written up there in full.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@enforce_keys, attrs)
    |> Validate.decimals!([:open, :high, :low, :close, :volume])
    |> Validate.non_negative!([:volume])
  end

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
