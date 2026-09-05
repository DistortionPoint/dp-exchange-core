defmodule DpExchange.Core.Types.OptionGreeks do
  @moduledoc """
  Risk sensitivities and implied volatility for one option contract.

  ## These are model output, not market data

  Every field here is computed, not observed. A venue picks a pricing model, feeds it its own
  mark, its own volatility surface, its own rate and its own clock, and publishes the result.
  Two venues quoting the same contract will publish different Greeks, and neither is wrong.

  That is why they are separated from `Types.OptionContract`, which is fact, and from
  `Types.Quote` and `Types.TopOfBook`, which are observations. **A caller comparing deltas
  across venues is comparing two models, and nothing in this struct tells it so** — this
  moduledoc is where that is said.

  `:model_price` is the venue's theoretical value. It is the number most easily mistaken for
  a price: it is what the venue's model says the contract is worth, not what anyone paid or
  offered. It is deliberately not named `price`.

  ## `:implied_volatility` is a percentage

  Venues publish it as a percentage or as a decimal fraction, and the two differ by 100×.
  Normalised to a percentage on the way in — `30.0` means 30%, not 3000%.

  ## `:open_interest` is a count and it is stale

  Open interest is published once a day by the clearing house, after settlement. A caller
  reading it intraday is reading yesterday's number, and `:as_of` says which day where the
  venue states it. Volume, by contrast, is live — and lives on `Types.Quote`.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:provider]
  defstruct [
    :delta,
    :gamma,
    :theta,
    :vega,
    :rho,
    :implied_volatility,
    :model_price,
    :underlying_price,
    :open_interest,
    :as_of,
    :provider
  ]

  @type t :: %__MODULE__{
          delta: Decimal.t() | nil,
          gamma: Decimal.t() | nil,
          theta: Decimal.t() | nil,
          vega: Decimal.t() | nil,
          rho: Decimal.t() | nil,
          implied_volatility: Decimal.t() | nil,
          model_price: Decimal.t() | nil,
          underlying_price: Decimal.t() | nil,
          open_interest: Decimal.t() | nil,
          as_of: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
