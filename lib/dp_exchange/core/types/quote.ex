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

  ## `:venue_time` is the venue's own; `:observed_at` is when we read it — BREAKING in 0.2.0

  These replace a single `:timestamp`, and the reason is the whole point of the split.

  `:timestamp` was documented as "the venue's own, never invented". Two venues could not
  keep that promise, because the frames they decode carry **no venue time at all**:
  `dp_exchange_schwab`'s `LEVELONE_*` quotes, and `dp_exchange_gemini`'s partial-depth
  books (the vendor's own AsyncAPI requires only `[lastUpdateId, bids, asks]` there, where
  `BookTicker` requires `E`). With one field their only options were to lie or to drop real
  data, and they lied — a read time in a field a consumer was told was the venue's.

  So:

  * **`:venue_time`** — whatever the venue gave us, used as-is. Not normalised, not
    substituted, and **`nil` where the venue published none**. A `nil` here is information,
    not an omission: it says the venue did not date this.
  * **`:observed_at`** — when this package read it. Always present, never `nil`.

  `TopOfBook` has had exactly this shape from the start, and its own doc already explained
  why. This is that decision finishing its journey to the other two payload types.

  ## Why `:observed_at` is mandatory and `:venue_time` is not

  Requested by the consumer who decided this design (dp-exchange-core issue #31), and it is
  the property that makes strict honesty affordable: **a consumer always has a usable time,
  so `:venue_time` can be left `nil` without anyone being forced to invent one.** Drop the
  guarantee and every caller needs a fallback, which is the substitution this whole change
  exists to remove, relocated into consumer code.

  What that buys, in their words: they store `:venue_time` as the point time where the venue
  dated the frame, and where it did not they store `:observed_at` **and record that they
  did** — so a mis-bucketed candle is attributable rather than invisible. With one field
  they could not make that decision at all, because they could not see which kind of time
  they had.

  ## What this is not

  It is **not** a licence to fill `:venue_time` from a local clock when the venue is quiet.
  The rule that field carries is unchanged and absolute: whatever the venue gave us, or
  `nil`. `dp_exchange_schwab`'s Streamer book is the model — it reads the venue's
  `snapshot_time` and fails closed when it is absent rather than substituting.

  ## `:volume` is `nil` when the venue publishes none

  Never `0`. A venue that reports no volume and a venue reporting a genuinely flat period
  are different facts, and `0` claims the second.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :price, :observed_at, :provider]
  defstruct [:symbol, :price, :volume, :venue_time, :observed_at, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          price: Decimal.t(),
          volume: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          observed_at: DateTime.t(),
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
