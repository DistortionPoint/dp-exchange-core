defmodule DpExchange.Core.Timeframe do
  @moduledoc """
  The canonical timeframe vocabulary: a string label, its width in seconds, and
  the boundary every real candle of that width sits on.

  ## Why alignment is part of the vocabulary

  A candle is not just "OHLC at a time" — it is OHLC *for a specific bucket*. A
  `1d` bar means midnight-to-midnight UTC; a `4h` bar means one of the six fixed
  4-hour windows in a day. Every real source honours that: venue candle
  endpoints return bucket-start timestamps, and any honest aggregation over them
  rolls up on bucket boundaries.

  That makes alignment a **cheap, total test of authenticity**, and it caught a
  live data-integrity bug on 2026-08-06. The Gemini adapter, when its historical
  path returned too little data, synthesised candles at `now - i * granularity`
  — arbitrary sub-second timestamps carrying prices from a hardcoded table. The
  poison is visible at a glance once you know to look:

      2026-08-06T00:00:00Z        close 64698.60   <- real
      2026-08-04T16:01:33.654710Z close 42912.10   <- fabricated (42_500 base)

  Both were tagged `timeframe: "1d"`, both fed backtests and the shadow gate.
  Nothing downstream could tell them apart, because nothing downstream checked
  the one property a fabricated bar cannot fake without also being right.

  So this module ships `aligned?/2`, and a consumer storing candles should enforce
  it on the write path — a misaligned candle rejected rather than stored — and filter
  on the read path, so rows written before the guard existed never reach a backtest.
  Core cannot enforce that itself: it owns no storage. It owns the test.

  ## Two vocabularies: what can be bucketed, and what can be named

  `known/0` is the set of widths this module can **bucket** — every one has an
  entry in `@seconds`, so `aligned?/2` and `boundary/2` can answer for it.

  `nameable/0` is wider. It is the set of widths Core can **read as a label**,
  and it adds `1w`, `1M` and `1y`.

  A `1w` bar's boundary depends on which weekday the venue starts its week, `1M`
  is not a fixed number of seconds at all, and neither is `1y` — a calendar
  year is 365 or 366 days depending which one, and encoding either as a fixed
  second count would silently mis-bucket the other. None of the three will ever
  get a boundary rule, because encoding a guess would reject real data — so
  `seconds/1` returns `:error` for all three, `aligned?/2` returns `true`, and
  `boundary/2` passes them through untouched. Callers read "no boundary rule" as
  "cannot check", never as "invalid".

  **`1y` joined `1w` and `1M` on 2026-09-06, found downstream rather than
  designed ahead of use.** `dp_exchange_webull`'s stock, option and futures bars
  endpoint genuinely serves a yearly bar alongside the weekly and monthly ones —
  `Rest.get_stock_bars/5`, tested against the venue's own `timespan` enum — and
  until this widened, `Capabilities.new/1` raised on `1y` the same way it used
  to raise on `1w` and `1M` before those were added: the exact under-declaration
  this module's own history already records twice. Webull carried
  `@core_unnameable_widths ~w(1y)`, subtracted from its declaration with a
  comment naming this exact gap, because the alternative was declaring a width
  it does not serve or omitting one it does. That workaround is now removable.

  **The distinction is load-bearing, and Core got it wrong twice before it was
  drawn.** `Capabilities.validate_history!/1` and the conformance suite both
  checked declarations against `known/0`, so a venue serving a real weekly candle
  could not declare it — leaving that venue two choices, under-declare what it
  serves or not ship. Validate declarations against `nameable/0`; reach for
  `known/0` only when you need the width in seconds. A width outside both, such
  as `3m`, is still refused.

  Found when Schwab's `/pricehistory` turned out to serve `1w`, `1M`, and a
  `10m` width that had simply been missing from `@seconds` — not neutral, since
  `aligned?/2` answers `true` for anything it cannot model, so every 10-minute
  candle had been passing the authenticity check unexamined.
  """

  @seconds %{
    "1m" => 60,
    "5m" => 300,
    "10m" => 600,
    "15m" => 900,
    "30m" => 1_800,
    "1h" => 3_600,
    "2h" => 7_200,
    "4h" => 14_400,
    "6h" => 21_600,
    "12h" => 43_200,
    "1d" => 86_400
  }

  @doc """
  Width of a timeframe in seconds, or `:error` for one we do not model.

  `:error` rather than a default: a wrong width silently mis-buckets every
  candle it touches, which is exactly the class of failure a fallback hides.
  """
  @spec seconds(String.t()) :: {:ok, pos_integer()} | :error
  def seconds(timeframe) when is_binary(timeframe), do: Map.fetch(@seconds, timeframe)
  def seconds(_other), do: :error

  @doc "Every timeframe with a known width, shortest first."
  @spec known() :: [String.t()]
  def known, do: @seconds |> Map.keys() |> Enum.sort_by(&Map.fetch!(@seconds, &1))

  # Widths Core can *name* but cannot *bucket*. A weekly bar's boundary depends on which
  # weekday the venue starts its week, a month is not a fixed number of seconds, and
  # neither is a year (365 or 366 days, depending which one) — so none of the three has
  # an entry in `@seconds`, and none ever will.
  #
  # They still need to be nameable. Schwab's `/pricehistory` serves the first two, and
  # `dp_exchange_webull`'s stock/option/futures bars serve all three (`1y` added
  # 2026-09-06, found downstream — see the moduledoc); a venue that genuinely serves one
  # of these has only two options if the vocabulary refuses the label: omit a real width
  # from its declaration, or not ship. Both are worse than carrying a width we can read
  # but not align.
  @unbucketable ~w(1w 1M 1y)

  @doc """
  Every timeframe Core can read as a label, shortest first, including the three it cannot
  bucket.

  This is deliberately wider than `known/0`, and the difference is the point. `known/0`
  answers "which widths can I align and bucket"; this answers "which widths can I store
  under a label something else can read back". A venue may serve `1w`; nothing in Core can
  tell you where a `1w` bucket starts, and that is a reason not to check alignment rather
  than a reason to reject the width.
  """
  @spec nameable() :: [String.t()]
  def nameable, do: known() ++ @unbucketable

  @doc """
  Whether Core recognises `timeframe` as a label at all.

  `false` means the string is outside the vocabulary entirely — not that its boundary is
  unknown. Use this to validate a declaration; use `seconds/1` when you need the width.
  """
  @spec nameable?(term()) :: boolean()
  def nameable?(timeframe) when is_binary(timeframe), do: timeframe in nameable()
  def nameable?(_other), do: false

  @doc """
  Whether `datetime` sits exactly on a `timeframe` bucket boundary.

  Unknown timeframes return `true` — "we have no rule" must not read as
  "invalid", or a venue serving a width we do not model would have all of its
  real data rejected.
  """
  @spec aligned?(DateTime.t(), String.t()) :: boolean()
  def aligned?(%DateTime{} = datetime, timeframe) do
    case seconds(timeframe) do
      {:ok, width} ->
        rem(DateTime.to_unix(datetime), width) == 0 and datetime.microsecond == {0, 0}

      :error ->
        true
    end
  end

  def aligned?(_other, _timeframe), do: false

  @doc "The start of the bucket `datetime` falls in, or the input when unknown."
  @spec boundary(DateTime.t(), String.t()) :: DateTime.t()
  def boundary(%DateTime{} = datetime, timeframe) do
    case seconds(timeframe) do
      {:ok, width} ->
        datetime |> DateTime.to_unix() |> div(width) |> Kernel.*(width) |> DateTime.from_unix!()

      :error ->
        datetime
    end
  end
end
