defmodule DpExchange.Core.Types.Funding do
  @moduledoc """
  A perpetual's funding: what was paid, what is projected, and when the next one lands.

  ## Settled and estimated are different facts

  `:amount` is funding that has **happened** — a payment between longs and shorts at a
  funding time that has passed. `:estimated_amount` is the venue's projection for the *next*
  one, and it moves continuously until the moment it settles.

  They are separate fields for the same reason realised and unrealised P&L are on
  `Types.Position`: one is a fact and the other is an opinion, and a caller that books an
  estimate has booked a number that had not happened. A venue's own response carries both —
  `fundingAmount: -1.50991` beside `estimatedFundingAmount: -2.10595`, differing by 40% —
  which is precisely how wrong a caller reading "the funding" would be.

  ## Sign is the venue's, and it means direction

  Funding is a payment between sides. A negative amount means one side paid the other, and
  which is which is a venue convention this layer does not reinterpret. **The sign is
  carried through unchanged**; a package that normalised it would be asserting a convention
  the venue did not state.

  ## `:next_funding_at` is a scheduling fact

  A caller holding a perpetual across a funding time pays or receives at that instant.
  Knowing when it is, is the difference between choosing to hold the position and
  discovering the payment afterwards.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :provider]
  defstruct [
    :symbol,
    :amount,
    :estimated_amount,
    :funded_at,
    :next_funding_at,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          amount: Decimal.t() | nil,
          estimated_amount: Decimal.t() | nil,
          funded_at: DateTime.t() | nil,
          next_funding_at: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
