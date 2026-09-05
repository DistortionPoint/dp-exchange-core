defmodule DpExchange.Core.Types.AuctionImbalance do
  @moduledoc """
  The order imbalance an exchange publishes ahead of an opening or closing auction.

  ## Why this is its own type and not a quote

  During an auction the continuous book stops being the price. What matters instead is how
  much can be matched, how much cannot, and at what price the auction would clear if it ran
  now — three numbers a `Quote` has nowhere to put and a `TopOfBook` describes a different
  market for.

  A caller reading a continuous-market quote at 15:59 and acting on it is reading a book
  that is not where the close will happen.

  ## `:side` is the venue's own value, unmapped

  Venues publish the imbalance direction as a code, and **the code tables differ**. Webull's
  NOII documents `imbalance_side` with the example `"2"` and does not say what 2 means.

  So this carries the venue's value **as it was sent** rather than an `:buy`/`:sell` atom
  guessed from a table nobody published. Getting that backwards would tell a caller there is
  unmatched buying pressure when there is selling — a wrong answer that looks entirely
  normal, and one that moves money in the wrong direction at the one moment of the day with
  the most volume behind it.

  A package that establishes a venue's table can map it and say where the table came from.
  Until then the raw value is the honest answer.

  ## The three prices are three different questions

  * `:reference_price` — what the auction is being measured against
  * `:near_price` — where it would clear on the orders in hand
  * `:far_price` — where it would clear in the extreme case

  They are not interchangeable and none of them is "the price". A venue publishing only
  some of them leaves the rest `nil`.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :auction, :observed_at, :provider]
  defstruct [
    :symbol,
    :auction,
    :paired_quantity,
    :imbalance_quantity,
    :side,
    :reference_price,
    :near_price,
    :far_price,
    :venue_time,
    :observed_at,
    :provider
  ]

  @typedoc "Which auction the imbalance belongs to."
  @type auction :: :opening | :closing

  @type t :: %__MODULE__{
          symbol: String.t(),
          auction: auction(),
          paired_quantity: Decimal.t() | nil,
          imbalance_quantity: Decimal.t() | nil,
          side: String.t() | nil,
          reference_price: Decimal.t() | nil,
          near_price: Decimal.t() | nil,
          far_price: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          observed_at: DateTime.t(),
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  Whether the imbalance is large relative to what can be paired, as a ratio.

  `nil` when either quantity is absent — **not zero**. An unknown imbalance is not a small
  one, and a caller treating a missing number as "balanced" is making the same mistake as
  reading a missing liquidation price as safety.

  Returns a `Decimal` so the caller decides what counts as large; this type has no opinion
  about a threshold and should not acquire one.
  """
  @spec imbalance_ratio(t()) :: Decimal.t() | nil
  def imbalance_ratio(%__MODULE__{paired_quantity: nil}), do: nil
  def imbalance_ratio(%__MODULE__{imbalance_quantity: nil}), do: nil

  def imbalance_ratio(%__MODULE__{paired_quantity: paired, imbalance_quantity: imbalance}) do
    if Decimal.equal?(paired, Decimal.new(0)) do
      # Nothing pairs, so the ratio is undefined rather than infinite. A venue reporting
      # zero paired shares has said the auction matches nothing yet.
      nil
    else
      Decimal.div(imbalance, paired)
    end
  end
end
