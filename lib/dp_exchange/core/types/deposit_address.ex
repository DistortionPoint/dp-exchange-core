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

  alias DpExchange.Core.Types.Validate

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

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.

  Also raises on a blank `:asset`, `:network` or `:address`, and on a `:memo_required` that is
  not `true`, `false` or `nil` (`nil` is "the venue did not say", never `false`).
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@enforce_keys, attrs)
    |> Validate.text!([:asset, :network, :address])
    |> Validate.one_of!(:memo_required, [true, false, nil])
  end
end
