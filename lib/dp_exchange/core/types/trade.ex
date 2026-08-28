defmodule DpExchange.Core.Types.Trade do
  @moduledoc """
  Normalised public trade — anyone's order match, from the venue's trade tape.

  Distinct from `DpExchange.Core.Types.Fill`, which is the caller's *own* match. The two
  are easy to conflate and must not be: a tape trade is public market data, a fill is an
  account event.

  `:timestamp` is the venue's own, used as-is.
  """

  @enforce_keys [:id, :symbol, :side, :price, :quantity, :timestamp, :provider]
  defstruct [:id, :symbol, :side, :price, :quantity, :timestamp, :provider]

  @type t :: %__MODULE__{
          id: String.t(),
          symbol: String.t(),
          side: :buy | :sell,
          price: Decimal.t(),
          quantity: Decimal.t(),
          timestamp: DateTime.t(),
          provider: atom() | String.t()
        }
end
