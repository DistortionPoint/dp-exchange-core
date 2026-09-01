defmodule DpExchange.Core.Types.Trade do
  @moduledoc """
  Normalised public trade — anyone's order match, from the venue's trade tape.

  Distinct from `DpExchange.Core.Types.Fill`, which is the caller's *own* match. The two
  are easy to conflate and must not be: a tape trade is public market data, a fill is an
  account event.

  `:timestamp` is the venue's own, used as-is.

  ## `:side` is who removed liquidity, not who owned it

  Venues report the taker's side. Gemini says `buy` means an ask was removed by an incoming
  buy order — a statement about pressure, and the *opposite* of the resting order's side. A
  package mapping it to "the maker was selling" inverts every entry while every number
  stays real.

  ## `:broken` — a trade the exchange cancelled

  Exchanges bust erroneous prints, and a broken trade **did not stand**: its price is not a
  price the market traded at. Leaving one in a series puts a phantom high or low into every
  range, breakout and volatility figure built on it, and none of them will error.

  Defaults to `false`, and `get_trades/2` excludes broken trades unless asked. **`false`
  means the venue said not broken or said nothing** — a venue with no concept of busts
  reports `false` because nothing was busted, which is the same answer.
  """

  @enforce_keys [:id, :symbol, :side, :price, :quantity, :timestamp, :provider]
  defstruct [:id, :symbol, :side, :price, :quantity, :timestamp, :provider, broken: false]

  @type t :: %__MODULE__{
          id: String.t(),
          symbol: String.t(),
          side: :buy | :sell,
          price: Decimal.t(),
          quantity: Decimal.t(),
          timestamp: DateTime.t(),
          broken: boolean(),
          provider: atom() | String.t()
        }

  @doc """
  The trade's notional value — price times quantity.

  Provided so every package computes it the same way rather than each deciding whether to
  round. It does not round: `Decimal` multiplication is exact, and a caller that wants a
  currency's precision applies it knowing which currency.
  """
  @spec notional(t()) :: Decimal.t()
  def notional(%__MODULE__{price: price, quantity: quantity}), do: Decimal.mult(price, quantity)
end
