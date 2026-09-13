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

  ## `:id` and `:side` are enforced as KEYS, and may still be `nil`

  `@required_non_nil` is narrower than `@enforce_keys` here, the same split
  `DpExchange.Core.Types.Balance` makes and for the reason it states: **state what is true
  rather than a stricter rule the packages then quietly violate.**

  Both fields were in the non-nil set, and two venues could not keep it:

  * **`:id`.** `dp_exchange_webull`'s `tick` topic publishes no per-print identifier, on the
    socket or on its REST tape, and its usage rules say so. Its decoder records that
    `Trade.new/1` "is deliberately not used here: it would raise on the very absence this
    comment and the moduledoc both document as real rather than accidental".
  * **`:side`.** `dp_exchange_gemini`: "Absent means the venue did not say which side lifted,
    and neither answer is honest." `dp_exchange_webull` matches only the venue's documented
    `"B"`/`"S"` and answers `nil` otherwise — "a real trade with an unknown aggressor, rather
    than a guess that would put volume on the wrong side of a delta".

  The packages' response was to bypass this constructor entirely, which is worse than the
  rule being wrong: skipping `new/1` skips the checks that ARE right — a `nil` price,
  quantity, timestamp or symbol — so one unkeepable requirement cost the other four. The
  typespec was lying too: `id: String.t()` while a shipped venue returns `nil` there.

  `@enforce_keys` still lists both, so a decoder that forgets the key entirely is caught.
  What is allowed is stating the absence.

  A consumer must therefore treat `:id` and `:side` as optional and check them. `:price`,
  `:quantity`, `:timestamp` and `:symbol` it need not: no venue has an honest `nil` for
  those, and `new/1` refuses them.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:id, :symbol, :side, :price, :quantity, :timestamp, :provider]
  defstruct [:id, :symbol, :side, :price, :quantity, :timestamp, :provider, broken: false]

  # Narrower than `@enforce_keys` on purpose — see the moduledoc section above.
  @required_non_nil [:symbol, :price, :quantity, :timestamp, :provider]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t(),
          side: :buy | :sell | nil,
          price: Decimal.t(),
          quantity: Decimal.t(),
          timestamp: DateTime.t(),
          broken: boolean(),
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`. The
  fields checked here are narrower than `@enforce_keys` on purpose: `:id` and `:side` may
  honestly be `nil`, and the moduledoc says which venues and why.

  An explicit `broken: nil` is likewise not an error: it is normalised to `false`, per this
  module's "`broken: nil` is 'said nothing'" section above.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = attrs |> Map.new() |> Map.update(:broken, false, &(&1 || false))
    Validate.new!(__MODULE__, @required_non_nil, attrs)
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
