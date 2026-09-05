defmodule DpExchange.Core.Types.ContractStats do
  @moduledoc """
  Risk statistics for a derivative contract.

  ## Mark and index are not the same price, and neither is the last trade

  `:mark_price` is the venue's own valuation — what it marks positions and computes
  liquidations against. `:index_price` is the external reference it is derived from. They
  diverge, sometimes sharply, and the divergence is the point: a venue marking away from the
  index is why a position can be liquidated at a price the market never printed.

  Neither is a traded price. `Types.Quote` carries that. Three prices for one instrument,
  each meaning something different, is exactly the situation in which a single "price" field
  produces a confident wrong answer.

  ## Open interest in contracts and in notional

  `:open_interest` counts contracts; `:open_interest_notional` values them. A venue publishes
  both because neither substitutes for the other across instruments with different contract
  sizes.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :provider]
  defstruct [
    :symbol,
    :product_type,
    :mark_price,
    :index_price,
    :open_interest,
    :open_interest_notional,
    :venue_time,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          product_type: String.t() | nil,
          mark_price: Decimal.t() | nil,
          index_price: Decimal.t() | nil,
          open_interest: Decimal.t() | nil,
          open_interest_notional: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
