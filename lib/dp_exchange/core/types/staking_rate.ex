defmodule DpExchange.Core.Types.StakingRate do
  @moduledoc """
  What one provider pays for staking one asset.

  ## Rates carry their unit, because venues do not agree on one

  Gemini publishes `rate` in **basis points**, `ratePct` as a percentage, and `apyPct` as an
  annualised percentage — three numbers for the same position, differing by a factor of a
  hundred and by compounding. A contract that carried "the rate" would be inviting a caller
  to be wrong by 100×, and the error would look plausible either way.

  So this carries **percentages only**, both named for what they are:

    * `:rate_pct` — the simple rate, as a percentage
    * `:apy_pct` — the annualised yield, as a percentage

  A venue publishing basis points converts on the way in. A venue publishing only one of the
  two leaves the other `nil` rather than deriving it: turning a simple rate into an APY needs
  a compounding frequency the venue did not state, and assuming one is inventing a number.

  ## `:deposit_limit_usd` is a real constraint

  Venues cap how much new notional can earn the advertised rate. A caller staking past the
  cap does not get an error — it gets a worse rate on the excess, silently. Carried where
  the venue publishes it.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:asset, :provider]
  defstruct [
    :asset,
    :provider_id,
    :rate_pct,
    :apy_pct,
    :deposit_limit_usd,
    :venue_time,
    :provider
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          provider_id: String.t() | nil,
          rate_pct: Decimal.t() | nil,
          apy_pct: Decimal.t() | nil,
          deposit_limit_usd: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  Converts a rate in basis points to a percentage.

  Provided here rather than left to each venue package, because it is the conversion most
  likely to be done inconsistently — and a rate wrong by 100× still looks like a rate.
  """
  @spec bps_to_pct(Decimal.t() | number() | String.t()) :: Decimal.t()
  def bps_to_pct(%Decimal{} = bps), do: Decimal.div(bps, 100)
  def bps_to_pct(bps) when is_integer(bps), do: bps |> Decimal.new() |> Decimal.div(100)
  def bps_to_pct(bps) when is_float(bps), do: bps |> Decimal.from_float() |> Decimal.div(100)
  def bps_to_pct(bps) when is_binary(bps), do: bps |> Decimal.new() |> Decimal.div(100)
end
