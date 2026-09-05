defmodule DpExchange.Core.Types.StakingReward do
  @moduledoc """
  Rewards accrued on a staked position over a period.

  ## A reward is an aggregate, and the period is part of the value

  Venues accrue staking rewards on their own schedule — Gemini typically once daily — and
  report them aggregated over a window the caller asked for. `:amount` alone is therefore
  meaningless: the same number is a good day or a poor quarter depending on the window.

  So `:period_start` and `:period_end` are carried, and `:accrual_count` says how many
  individual accruals the aggregate covers. A caller comparing venues has to compare over
  the same window, and cannot do that unless the window travels with the number.

  ## The rate is the rate *at accrual*, not now

  `:apy_pct` is what the position was earning while these rewards accrued, which is not
  necessarily what `Types.StakingRate` reports today. Carrying it here is what lets a caller
  reconcile a reward against the rate that produced it rather than against the current one.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:asset, :amount, :provider]
  defstruct [
    :asset,
    :amount,
    :provider_id,
    :apy_pct,
    :accrual_count,
    :period_start,
    :period_end,
    :provider
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          amount: Decimal.t(),
          provider_id: String.t() | nil,
          apy_pct: Decimal.t() | nil,
          accrual_count: non_neg_integer() | nil,
          period_start: DateTime.t() | nil,
          period_end: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
