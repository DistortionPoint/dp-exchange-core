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

  `:timestamp` is the venue's own, used as-is. `:sequence` is the venue's book sequence
  number where it publishes one, for callers reconciling snapshots against a delta
  stream, and `nil` where it does not.

  ## Known divergence, 2026-09-09

  `dp_exchange_gemini`'s `WsDecode.to_order_book/3` sets `:timestamp` to the time the frame
  was **read**, not the venue's, on partial-depth snapshots. This is not a decoding mistake:
  the vendor's own AsyncAPI schema requires only `[lastUpdateId, bids, asks]` for
  `OrderBookSnapshot`, where `BookTicker` requires an `E` event time. The venue publishes no
  time for that frame, and this struct has no way to say so — `TopOfBook` can, because it
  carries `:venue_time` and `:observed_at` separately.

  `dp_exchange_schwab`'s Streamer book is the counter-example and shows the rule is
  keepable where the venue cooperates: it reads the venue's `snapshot_time` and fails closed
  when it is absent, rather than substituting.

  See `docs/design/2026-09-09_venue-time-and-observed-time.md`. Closing this means changing
  a published type, so it is a design decision rather than an edit.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :bids, :asks, :timestamp, :provider]
  defstruct [:symbol, :bids, :asks, :timestamp, :sequence, :provider]

  @type level :: {Decimal.t(), Decimal.t()}

  @type t :: %__MODULE__{
          symbol: String.t(),
          bids: [level()],
          asks: [level()],
          timestamp: DateTime.t(),
          sequence: integer() | nil,
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
