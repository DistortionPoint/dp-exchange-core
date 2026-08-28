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
  """

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
end
