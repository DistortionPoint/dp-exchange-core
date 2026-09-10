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
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
