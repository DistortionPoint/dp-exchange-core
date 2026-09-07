defmodule DpExchange.Core.Types.StakingBalance do
  @moduledoc """
  A staked position in one asset, with the three liquidity states kept apart.

  ## Why three amounts and not one

  Staked value is not a single number, and collapsing it into one is the failure this type
  is shaped to avoid. A venue reports:

    * `:staked` — the total position
    * `:available_to_trade` — what can be traded **now**, without redeeming
    * `:available_for_withdrawal` — what can be redeemed back to the exchange account

  These routinely disagree. A real Gemini response carries `balance: 10`, `available: 0`,
  `availableForWithdrawal: 10` — the whole position is redeemable and **none** of it is
  tradable. A caller that read a single "available" would size an order against ten and
  place it against zero.

  **`nil` is not zero here either.** A venue that does not report one of these states has
  not said it is zero, and a caller must treat `nil` as unknown rather than as "none".

  ## `:by_provider` is an addressing dimension, not a detail

  The same asset can be staked with several providers at different rates, and an unstake is
  addressed to a provider. The breakdown is carried rather than summed away, because a
  caller redeeming from the wrong provider redeems at the wrong rate — and a total gives it
  no way to notice.

  Keys are the venue's provider identifiers, used as-is. Empty means the venue does not
  break the position down, **not** that there is one provider.

  ## `:by_provider` defaults to `%{}`, never `nil`

  The typespec below is a map, not `map() | nil` — "empty means no breakdown" (above) is
  only true if empty is actually reachable, and a bare `nil` is neither a map a caller can
  iterate nor the documented "no breakdown" signal. `new/1` defaults an absent key to `%{}`
  and normalises an explicit `by_provider: nil` (the shape a decode bug produces from a
  venue field that came back JSON `null`) to `%{}` as well, rather than let either produce a
  struct that violates its own typespec.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:asset, :staked, :provider]
  defstruct [
    :asset,
    :staked,
    :available_to_trade,
    :available_for_withdrawal,
    :venue_time,
    :provider,
    by_provider: %{}
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          staked: Decimal.t(),
          available_to_trade: Decimal.t() | nil,
          available_for_withdrawal: Decimal.t() | nil,
          by_provider: %{optional(String.t()) => Decimal.t()},
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`. Unlike
  the enforced fields, an explicit `by_provider: nil` is not an error: it is normalised to
  `%{}`, the struct's own default, per this module's "`:by_provider` defaults to `%{}`"
  section above — "the venue does not break the position down" is not a caller mistake to
  raise on.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.update(:by_provider, %{}, &(&1 || %{}))
    Validate.new!(__MODULE__, @enforce_keys, attrs)
  end
end
