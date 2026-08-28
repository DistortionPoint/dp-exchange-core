defmodule DpExchange.Core.Types.Order do
  @moduledoc """
  Normalised order, returned by every venue package.

  `:created_at` and `:updated_at` are **the venue's own** values where it supplies them
  and `nil` where it does not. `nil` is the honest answer; a substituted local clock
  would be a plausible value with the wrong meaning.

  Not every venue supports every `t:order_type/0` or reports every `t:status/0`. The
  union here is what the contract can *express*; what a given venue can actually accept
  is declared by that package's `capabilities/0`, and asking for one it does not support
  is an error rather than a silent downgrade to the nearest available type.
  """

  @enforce_keys [:id, :symbol, :side, :order_type, :quantity, :status, :provider]
  defstruct [
    :id,
    :symbol,
    :side,
    :order_type,
    :quantity,
    :price,
    :stop_price,
    :status,
    :filled_quantity,
    :average_price,
    :fee,
    :fee_currency,
    :created_at,
    :updated_at,
    :provider
  ]

  @type side :: :buy | :sell

  @type order_type :: :market | :limit | :stop | :stop_limit | :post_only | :ioc | :fok

  @type status ::
          :pending
          | :open
          | :partially_filled
          | :filled
          | :cancelled
          | :rejected
          | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          symbol: String.t(),
          side: side(),
          order_type: order_type(),
          quantity: Decimal.t(),
          price: Decimal.t() | nil,
          stop_price: Decimal.t() | nil,
          status: status(),
          filled_quantity: Decimal.t() | nil,
          average_price: Decimal.t() | nil,
          fee: Decimal.t() | nil,
          fee_currency: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          provider: atom() | String.t()
        }
end
