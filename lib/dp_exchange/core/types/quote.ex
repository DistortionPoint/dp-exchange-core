defmodule DpExchange.Core.Types.Quote do
  @moduledoc """
  Normalised **trade** data for a symbol: what it last traded at, how much has traded, and
  when the venue says so.

  ## There is no bid and no ask here, deliberately

  This struct used to carry `:bid` and `:ask`, and every venue package in the family filled
  them in. **That was wrong.** A bid and an ask are the order book — resting orders, what
  someone is *willing* to trade at. A price is an execution — what someone *did* trade at.
  Putting both in one struct invites a caller to reach for whichever is populated, and
  invites a package to fill `price` from `ask` when the venue sends no price, which is
  exactly what one of them did.

  Book data lives in `Core.Types.TopOfBook` (best bid/ask) and `Core.Types.OrderBook`
  (depth). A caller that wants both makes two calls and gets two values that say what they
  are. **Nothing in this struct can stand in for a book, and nothing in a book can stand in
  for a price.**

  ## `:timestamp` is the venue's own

  Whatever it gave us, used as-is. Not normalised, not substituted, and never invented: a
  quote whose freshness we cannot state is a quote we must not return.

  This guarantee is why `TopOfBook` has a separate `:observed_at`. A best bid/ask is real
  time and many venues publish no timestamp with it, so the honest stamp is when the package
  read it — a different fact, in a differently named field, rather than a call time written
  into a field documented as the venue's.


  ## Known divergence, 2026-09-09 — two venues currently break the rule above

  Recorded here rather than only in a design document, because a reader of this contract
  deserves to know where it is not being kept:

  - `dp_exchange_schwab`'s `StreamerDecode.to_quote/3` puts the **frame's arrival time** in
    `:timestamp`. `LEVELONE_*` frames carry no venue time in the fields it reads, and its
    own moduledoc states the substitution plainly rather than hiding it.
  - `dp_exchange_gemini`'s `WsDecode.to_order_book/3` does the same for
    `Core.Types.OrderBook`, on partial-depth snapshots. The vendor's own AsyncAPI schema
    confirms the frame carries no event time: `OrderBookSnapshot` requires only
    `[lastUpdateId, bids, asks]`, where `BookTicker` requires `E`.

  Both are the failure this section names — a read time in a field documented as the
  venue's — and neither is a decoding mistake: the venues genuinely publish no time for
  those frames. **The gap is in this contract, not only in those packages.** `TopOfBook`
  can say "the venue did not stamp this" because it has `:venue_time` and `:observed_at`;
  `Quote` and `OrderBook` have one field and so cannot say it at all.

  Closing it means changing a published type, which is why it is a design document
  (`docs/design/2026-09-09_venue-time-and-observed-time.md`) and not an edit: the options
  differ in what they cost a live consumer, and the cheapest one for us is the most
  expensive one for them.
  ## `:volume` is `nil` when the venue publishes none

  Never `0`. A venue that reports no volume and a venue reporting a genuinely flat period
  are different facts, and `0` claims the second.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :price, :timestamp, :provider]
  defstruct [:symbol, :price, :volume, :timestamp, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          price: Decimal.t(),
          volume: Decimal.t() | nil,
          timestamp: DateTime.t(),
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
