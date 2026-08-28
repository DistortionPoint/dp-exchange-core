defmodule DpExchange.Core.Types.Fill do
  @moduledoc """
  Normalised order fill — a partial or complete execution of the caller's own order.

  One fill is a single match against the book; **a single order may produce many fills**,
  so a caller reconstructing an order's economics sums its fills rather than reading any
  one of them.

  Distinct from `DpExchange.Core.Types.Trade`, which is the public tape.

  `:timestamp` is the venue's own, used as-is.
  """

  @enforce_keys [:order_id, :symbol, :side, :quantity, :price, :timestamp, :provider]
  defstruct [
    :order_id,
    :trade_id,
    :symbol,
    :side,
    :quantity,
    :price,
    :fee,
    :fee_currency,
    :timestamp,
    :liquidity,
    :provider
  ]

  @type liquidity :: :maker | :taker | nil

  @type t :: %__MODULE__{
          order_id: String.t(),
          trade_id: String.t() | nil,
          symbol: String.t(),
          side: :buy | :sell,
          quantity: Decimal.t(),
          price: Decimal.t(),
          fee: Decimal.t() | nil,
          fee_currency: String.t() | nil,
          timestamp: DateTime.t(),
          liquidity: liquidity(),
          provider: atom() | String.t()
        }
end
