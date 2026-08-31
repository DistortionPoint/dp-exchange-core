defmodule DpExchange.Core.Types.DepositAddress do
  @moduledoc """
  An address to deposit an asset to, on a specific network.

  ## `:memo` is not optional metadata — it is part of the address

  Some assets and some venues require a destination tag, memo or payment id alongside the
  address. A deposit sent to the right address **without** the required memo arrives at the
  venue's omnibus wallet and is not credited to anyone. Recovery is manual where it is
  possible at all, and often it is not.

  So `:memo_required` is carried separately from `:memo`, and the distinction matters:

    * `memo_required: true, memo: "12345"` — send it, and include the memo
    * `memo_required: false` — the network does not use one
    * **`memo_required: nil`** — the venue did not say, which is **not** the same as `false`

  A package must not default `:memo_required` to `false`. "Nobody said" and "not needed" are
  different facts, and the cost of confusing them is the deposit.

  ## `:network` is part of the identity

  The same asset exists on several chains and the addresses are not interchangeable. USDC
  sent to an Ethereum address over Tron is gone. An address without its network is not an
  address a caller can safely use, which is why `:network` is enforced rather than optional.
  """

  @enforce_keys [:asset, :network, :address, :provider]
  defstruct [
    :asset,
    :network,
    :address,
    :memo,
    :memo_required,
    :label,
    :created_at,
    :provider
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          network: String.t(),
          address: String.t(),
          memo: String.t() | nil,
          memo_required: boolean() | nil,
          label: String.t() | nil,
          created_at: DateTime.t() | nil,
          provider: atom()
        }
end
