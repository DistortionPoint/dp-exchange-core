defmodule DpExchange.Core.Types.Withdrawal do
  @moduledoc """
  A withdrawal of an asset to an external address.

  **This is the only operation in the contract that cannot be undone.** An order can be
  cancelled, a position closed, a stake redeemed. A withdrawal that leaves the venue is gone,
  and every field here is shaped by that.

  ## The fee is quoted separately and may not be the fee charged

  Venues expose a fee estimate as its own call. The estimate and the charge can differ —
  network conditions move between the two — so `:fee` is what the venue **charged** where it
  has said, and `nil` where it has not yet. An estimate does not belong in this field: a
  caller reconciling against an estimate as though it were the charge will be short by the
  difference, every time, in the same direction.

  ## `:amount` is what was requested, not necessarily what arrives

  Where a venue deducts the fee from the amount rather than in addition to it, the recipient
  receives less than `:amount`. Venues differ, and this layer does not reinterpret. A caller
  that must know what lands asks the venue, or reads `:fee` and its own venue's convention —
  it does not assume.

  ## `:status` never means "arrived"

  The venue can say it broadcast a transaction. It cannot say the recipient has it, and no
  status here should be read as confirmation of receipt:

    * `:requested` — accepted by the venue, nothing on chain
    * `:pending` — being processed, possibly awaiting a manual review
    * `:broadcast` — a transaction exists; `:tx_id` is set
    * `:completed` — the venue considers it done
    * `:cancelled` / `:failed` — it did not happen

  `:completed` is the venue's opinion, and it is the strongest claim available here.
  """

  @enforce_keys [:id, :status, :asset, :amount, :provider]
  defstruct [
    :id,
    :status,
    :asset,
    :amount,
    :network,
    :address,
    :memo,
    :fee,
    :tx_id,
    :requested_at,
    :provider
  ]

  @type status :: :requested | :pending | :broadcast | :completed | :cancelled | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          asset: String.t(),
          amount: Decimal.t(),
          network: String.t() | nil,
          address: String.t() | nil,
          memo: String.t() | nil,
          fee: Decimal.t() | nil,
          tx_id: String.t() | nil,
          requested_at: DateTime.t() | nil,
          provider: atom()
        }
end
