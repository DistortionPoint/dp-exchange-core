defmodule DpExchange.Core.Types.StakingTransaction do
  @moduledoc """
  One movement in or out of a staked position — and, for a redemption, how far it has got.

  ## Unstaking is a process, not an event

  This is the field this type exists for. A redemption does not complete when it is
  accepted: the asset unbonds on the chain's schedule, which can be days, and the venue pays
  it out in parts. Gemini reports `amount`, `amountPaidSoFar` and `amountRemaining` on a
  withdrawal precisely because the three differ for most of the operation's life.

  **The unbonding constraint is observable, not documentary.** A package that recorded only
  the requested `:amount` would report a redemption of ten as if ten had arrived, and the
  caller would find out by spending money it does not have yet. So:

    * `:amount` — what was requested
    * `:amount_paid_so_far` — what has actually arrived
    * `:amount_remaining` — what is still pending

  `nil` on the last two means the venue does not report progress, **not** that the operation
  is complete. `settled?/1` says so explicitly rather than leaving a caller to infer it.

  ## `:type` is normalised, `:venue_type` is kept

  Venues name these differently — Gemini's `transactionType` is one of `Deposit`, `Redeem`,
  `Interest` and others. `:type` is the normalised atom a caller branches on; `:venue_type`
  is the venue's own string, kept because a normalisation that loses the original cannot be
  audited when it turns out to be wrong.
  """

  @enforce_keys [:id, :type, :asset, :amount, :provider]
  defstruct [
    :id,
    :type,
    :venue_type,
    :asset,
    :amount,
    :amount_paid_so_far,
    :amount_remaining,
    :provider_id,
    :venue_time,
    :provider
  ]

  @type transaction_type :: :stake | :unstake | :reward | :other

  @type t :: %__MODULE__{
          id: String.t(),
          type: transaction_type(),
          venue_type: String.t() | nil,
          asset: String.t(),
          amount: Decimal.t(),
          amount_paid_so_far: Decimal.t() | nil,
          amount_remaining: Decimal.t() | nil,
          provider_id: String.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Whether a redemption has fully paid out.

  `nil` when the venue reports no progress — **unknown, not complete**. A caller must not
  read a missing `:amount_remaining` as "finished"; that is the substitution this whole
  contract is written against.
  """
  @spec settled?(t()) :: boolean() | nil
  def settled?(%__MODULE__{amount_remaining: nil}), do: nil

  def settled?(%__MODULE__{amount_remaining: remaining}) do
    Decimal.compare(remaining, Decimal.new(0)) == :eq
  end
end
