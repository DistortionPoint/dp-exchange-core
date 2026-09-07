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

  ## An explicit `broken: nil` is "said nothing", not a caller mistake

  `:broken` is not in `@enforce_keys` — a caller omitting it gets the struct's own default,
  `false`, exactly as documented above. But `@enforce_keys` guards presence, not `nil` (see
  `DpExchange.Core.Types.Validate`), and a PRESENT `broken: nil` — the shape a JSON decode
  produces from a venue field that came back `null` — bypassed the default entirely and
  built `%Trade{broken: nil}`, a value outside its own `boolean()` typespec that only
  happens to look safe because `nil` and `false` are both falsy in a bare `if`. A `case`
  matching `true` and `false` with no third clause does not get that courtesy, and this is
  exactly the field a phantom high or low rides in on. `new/1` normalises it to `false` —
  "the venue said nothing" is what `nil` already means here, by this module's own stated
  policy — rather than let it leak into a value nothing downstream expects.
  """

  alias DpExchange.Core.Types.Validate

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
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`. Unlike
  the enforced fields, an explicit `broken: nil` is not an error: it is normalised to
  `false`, per this module's "`broken: nil` is 'said nothing'" section above.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.update(:broken, false, &(&1 || false))
    Validate.new!(__MODULE__, @enforce_keys, attrs)
  end

  @doc """
  The trade's notional value — price times quantity.

  Provided so every package computes it the same way rather than each deciding whether to
  round. It does not round: `Decimal` multiplication is exact, and a caller that wants a
  currency's precision applies it knowing which currency.
  """
  @spec notional(t()) :: Decimal.t()
  def notional(%__MODULE__{price: price, quantity: quantity}), do: Decimal.mult(price, quantity)
end
