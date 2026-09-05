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
