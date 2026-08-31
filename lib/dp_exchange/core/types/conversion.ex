defmodule DpExchange.Core.Types.Conversion do
  @moduledoc """
  A conversion between two assets — quoted first, committed second.

  ## This is the facade's only two-step operation, and the gap between the steps is the risk

  Every other write in this contract is one call: place an order, cancel it, stake. A
  conversion is two. The venue quotes a rate, hands back an identifier, and holds that rate
  for a short window; the caller then commits against the identifier or lets it lapse.

  **`:expires_at` is the whole reason this type exists.** A caller that commits an expired
  quote does not get the rate it was shown. Depending on the venue it gets an error — or a
  fill at the current rate, which is the dangerous case, because the operation appears to
  have succeeded and the numbers are all real. The window is typically seconds.

  `nil` means the venue did not state an expiry, **not** that the quote is open-ended. A
  caller treating an unstated expiry as unlimited is making the same mistake as reading a
  missing liquidation price as safety.

  ## `:status` distinguishes a quote from a trade

  The same identifier addresses both stages, so the struct carries which stage it is in:

    * `:quoted` — a rate is held; nothing has moved
    * `:committed` — the caller accepted; the venue is executing
    * `:settled` — the assets have moved
    * `:expired` — the window closed unaccepted
    * `:failed` — the venue rejected or could not complete it

  **`:quoted` is not a conversion that happened.** A package that reported a quote as
  complete would be reporting an intention as a fact.
  """

  @enforce_keys [:id, :status, :from_asset, :to_asset, :provider]
  defstruct [
    :id,
    :status,
    :from_asset,
    :to_asset,
    :from_amount,
    :to_amount,
    :rate,
    :fee,
    :expires_at,
    :venue_time,
    :provider
  ]

  @type status :: :quoted | :committed | :settled | :expired | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          from_asset: String.t(),
          to_asset: String.t(),
          from_amount: Decimal.t() | nil,
          to_amount: Decimal.t() | nil,
          rate: Decimal.t() | nil,
          fee: Decimal.t() | nil,
          expires_at: DateTime.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Whether a quote has passed its stated expiry, as at `now`.

  Returns `nil` when the venue stated no expiry — **unknown, not "still valid"**. A caller
  that cannot establish the window should re-quote rather than assume it has one.

  This is advisory. The venue decides whether a commit succeeds, and a quote can be refused
  inside its stated window; asking here is how a caller avoids the round trip, not how it
  learns the outcome.
  """
  @spec expired?(t(), DateTime.t()) :: boolean() | nil
  def expired?(%__MODULE__{expires_at: nil}, _now), do: nil

  def expired?(%__MODULE__{expires_at: expires_at}, now) do
    DateTime.compare(now, expires_at) == :gt
  end
end
