defmodule DpExchange.Core.Types.OrderBook do
  @moduledoc """
  Normalised order book snapshot, returned by every venue package.

  `bids` and `asks` are sorted by price, **best price first**:

    * `bids` descending — highest bid first
    * `asks` ascending — lowest ask first

  Each level is a `{price, quantity}` tuple. The ordering is part of the contract, not a
  convenience: a caller reading `hd(bids)` as the best bid is reading it correctly, and a
  venue package that returns venue-order without re-sorting has broken the contract even
  though every value in it is true.

  `:venue_time` is the venue's own, used as-is, and **`nil` where the venue publishes none**
  — a `nil` there says the venue did not date this book, which is information rather than an
  omission. `:observed_at` is when this package read it, and is always present.

  These replaced a single `:timestamp` in 0.2.0. See `DpExchange.Core.Types.Quote`'s own
  moduledoc for the full reasoning, and `docs/design/2026-09-09_venue-time-and-observed-time.md`
  for the decision: the short version is that a venue publishing no time for a frame — which
  Gemini's partial-depth snapshot genuinely does not — had to either lie in a field
  documented as the venue's or drop real data, and one field could not tell a consumer which
  had happened.

  `dp_exchange_schwab`'s Streamer book is the model for `:venue_time`: it reads the venue's
  `snapshot_time` and fails closed when absent, rather than substituting.

  ## Sizes and prices

  In a snapshot a level whose size is `0` is **dropped** by the package's decoder: it is no
  liquidity and does not belong in the book, so `new/1` refuses one that reaches it rather than
  keep it. A **negative** size, or a price `<= 0`, refuses the whole book, and so
  does a level that cannot be read, or a side that is present but not a list. An unreadable
  level is never skipped, because a book missing a level is a different book. (A delta,
  `Types.OrderBookDelta`, is different: size `0` there means "remove this price".) The depth a
  caller asks for is the `:depth` option, in levels per side, on every venue.

  ## Sequence

  `:sequence` is the venue's book sequence number where it publishes one, for callers
  reconciling snapshots against a delta stream, and `nil` where it does not.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :bids, :asks, :observed_at, :provider]
  defstruct [:symbol, :bids, :asks, :venue_time, :observed_at, :sequence, :provider]

  @type level :: {Decimal.t(), Decimal.t()}

  @type t :: %__MODULE__{
          symbol: String.t(),
          bids: [level()],
          asks: [level()],
          venue_time: DateTime.t() | nil,
          observed_at: DateTime.t(),
          sequence: integer() | nil,
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.

  Also raises `ArgumentError` when `bids` or `asks` is not a list of `{price, quantity}`
  pairs, or when the moduledoc's ordering is broken: `bids` must not rise and `asks` must
  not fall from one level to the next, so `hd/1` is the best price. A venue-order book that
  was never re-sorted is true in every value and wrong in meaning. A level whose price is
  `<= 0` or whose size is `<= 0` raises too (see "Sizes and prices" above), and so does a
  `:sequence` that is neither an integer nor `nil`: a `"7"` compared with `>` against the
  integer a consumer last held sorts above it by Erlang term order, and a stale book would read
  as the newest.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    built =
      __MODULE__
      |> Validate.new!(@enforce_keys, attrs)
      |> Validate.integers!([:sequence])

    check_levels!(built, :bids, [:gt, :eq])
    check_levels!(built, :asks, [:lt, :eq])
    built
  end

  defp check_levels!(built, field, allowed) do
    levels = Map.fetch!(built, field)

    if not (is_list(levels) and Enum.all?(levels, &level?/1)) do
      raise ArgumentError,
            "OrderBook.new/1: field #{inspect(field)} must be a list of {price, quantity} " <>
              "pairs of Decimals, got #{Validate.show(levels)}"
    end

    Enum.each(levels, &check_positive!(field, &1))
    check_sorted!(levels, field, allowed)
  end

  # The moduledoc's "Sizes and prices", held at the constructor: a price at or below zero, a
  # negative size and a size of zero (a vanished level is dropped from a snapshot, never kept)
  # are a decode bug, and a book carrying one is a different book with every other value
  # still plausible.
  defp check_positive!(field, {price, quantity} = level) do
    if Decimal.compare(price, 0) != :gt or Decimal.compare(quantity, 0) != :gt do
      raise ArgumentError,
            "OrderBook.new/1: field #{inspect(field)} holds the level #{Validate.show(level)} — a " <>
              "snapshot level has a price and a size above zero (a size of 0 is dropped, a " <>
              "negative size or a price <= 0 refuses the book)"
    end
  end

  # One walk over adjacent levels. This was `Enum.map` of the prices, `Enum.chunk_every(2, 1)`
  # and `Enum.each`: three passes and a list of two-element lists per side, on every book a
  # venue builds, which is every snapshot message.
  defp check_sorted!([{better, _qty} | [{worse, _next_qty} | _rest] = tail], field, allowed) do
    if Decimal.compare(better, worse) not in allowed do
      raise ArgumentError,
            "OrderBook.new/1: field #{inspect(field)} is not sorted best price first " <>
              "(#{Validate.show(better)} before #{Validate.show(worse)})"
    end

    check_sorted!(tail, field, allowed)
  end

  defp check_sorted!(_fewer_than_two_levels, _field, _allowed), do: :ok

  defp level?({price, quantity}), do: number?(price) and number?(quantity)
  defp level?(_other), do: false

  defp number?(%Decimal{}), do: true
  defp number?(value), do: is_integer(value)
end
