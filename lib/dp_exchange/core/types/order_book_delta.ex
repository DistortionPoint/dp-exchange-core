defmodule DpExchange.Core.Types.OrderBookDelta do
  @moduledoc """
  One incremental order book update, passed through **exactly as the venue sent it** — never
  accumulated into a book.

  ## Why this type exists

  `DpExchange.Core.Types.OrderBook` is a full snapshot with eager, sorted `bids`/`asks` lists.
  There was no incremental type anywhere in `Core.Types`, so a venue package streaming
  deltas had exactly one option: fold every delta into a book it held itself and hand the
  whole thing back on every update. `dp_exchange_coinbase`'s `Socket` did this — a full book
  per symbol, measured at ~22,800 bid and ~21,100 ask levels for `BTC-USD` on a consumer's
  live node, rebuilt on every `l2_data` frame. That is market state duplicated inside a
  socket process, while the host receiving it was already streaming the same data into its
  own store. Holding it there was never this package's job; it existed only because the
  contract gave the venue no other shape to hand back.

  This type is that other shape. A venue decodes a delta frame into an
  `%OrderBookDelta{}` and passes it straight to its subscribers — no accumulation, no book
  held anywhere inside the package.

  ## The incident this must not reintroduce

  `dp_exchange_coinbase`'s `Socket` moduledoc records why the book was built in the first
  place: a caller reading a single `l2_data` delta as though it were the whole book "would
  see a handful of prices and nothing else." That is a real failure and this type must not
  bring it back.

  The fix is **a distinct type, not accumulated state**. A caller cannot mistake an
  `%OrderBookDelta{}` for an `%OrderBook{}` — the struct name says which one it is holding,
  at compile time and at a glance. The original defect was a *snapshot-shaped value carrying
  delta content*; nothing here is snapshot-shaped, so there is nothing left to mistake it
  for. A consumer that wants a book builds one from a stream of these — that is genuinely the
  consumer's job now, not a trap the type sets for whoever forgets to check.

  ## A zero quantity means the level ceased to exist — it is not a price of zero

  This is the venue's own meaning, carried through **unchanged**. Resolving it — dropping the
  level, merging it into a maintained book, treating it as "no size" — is state-keeping, and
  state-keeping is exactly what this package no longer does. A consumer applying deltas to
  its own book removes a level when it sees `quantity` equal to zero; a consumer that only
  wants to observe deltas as they arrive sees the zero exactly as the venue sent it and
  decides what it means on its own side of the boundary.

  ## The level shape, and why it is not `OrderBook.level/0`

  `t:DpExchange.Core.Types.OrderBook.level/0` is `{price, quantity}` and says nothing about
  side, because a snapshot already keeps `bids` and `asks` apart in two lists. A delta
  carries one side's change per entry and the entries arrive **in the venue's own order**,
  which mixes both sides in a single message — reshaping that into two side-keyed lists
  would either drop the venue's ordering or invent one that was never sent. So `t:level/0`
  here extends the snapshot's `{price, quantity}` pair with the one thing a flat list needs
  to stay unambiguous: which side changed, as the first element of the tuple.

  ## `:sequence` is `nil` exactly where `OrderBook`'s is

  The venue's own book sequence number, where it publishes one — `nil` where it does not.
  Same convention as `OrderBook`, for the same reason: a missing sequence is not zero and
  must never be read as "the first update".

  ## Reconnect reconciliation is the host's job now, not this package's

  A dropped and resumed connection does not promise the deltas after it are contiguous with
  the deltas before it — a package holding no book has nothing to wipe on reconnect, and the
  gap that used to be silently absorbed by rebuilding state is now real and visible instead.
  `DpExchange.Core.Notice`'s `:link_down` / `:link_up` pair brackets exactly where that gap
  falls, and `:sequence` on both this type and `OrderBook` lets a consumer confirm whether
  what arrived after `:link_up` is actually contiguous with what it already holds. Consistent
  with `Notice`'s own convention — a notice is a prompt to re-read, never the record — the
  correct response to `:link_up` is to re-pull `get_order_book/2` (or wait for the venue's
  own fresh snapshot, where its protocol sends one on resubscribe) rather than to keep
  applying deltas across the gap and hope they still line up. See `usage-rules/feeds.md` for
  the full account of why the two signals together are sufficient.
  """

  alias DpExchange.Core.Types.Validate

  @typedoc "Which side of the book this level's change is on."
  @type side :: :bid | :ask

  @typedoc """
  One changed level: `t:DpExchange.Core.Types.OrderBook.level/0`'s `{price, quantity}` pair
  with the side that changed as the first element, so a flat list can carry both sides in
  the venue's own order.

  `quantity` of zero means the level at `price` ceased to exist — see the moduledoc.
  """
  @type level :: {side(), Decimal.t(), Decimal.t()}

  @enforce_keys [:symbol, :levels, :timestamp, :provider]
  defstruct [:symbol, :levels, :timestamp, :sequence, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          levels: [level()],
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
