defmodule DpExchange.Core.Types.TopOfBook do
  @moduledoc """
  Best bid and ask for a symbol — **the top of the order book, not a price**.

  ## Why this is not a `Quote`

  A `Quote` carries `price`: what the instrument last **traded** at. This carries `bid` and
  `ask`: what someone is currently **willing** to trade at. Those are different quantities.
  They coincide only at the moment a resting order fills, and the gap between them is
  widest exactly when the book is thin — which is when a caller can least afford to confuse
  them.

  This type exists because that confusion had already happened. A venue package in this
  family read `price || ask` from a best-bid/ask endpoint, so when the venue sent no traded
  price the quote's `price` was an ask. Every number in it was real and came from the venue;
  only the meaning was wrong, which is why nothing caught it — not review, and not the test
  suite, which asserted the behaviour as intended.

  **So there is no `price` field here, and there is no way to add one.** A caller that wants
  a traded price calls `get_price/2` and gets a `Quote`, or gets an error. A caller that
  wants the book calls this. Nothing silently stands in for the other.

  ## Two timestamps, because a BBO has two

  `:venue_time` is the venue's own, used as-is, and is `nil` where the venue publishes none.
  Several BBO endpoints publish none at all — Robinhood's documents exactly `symbol`, `bid`
  and `ask`.

  `:observed_at` is when **this package read it**, and is always present. A top-of-book is a
  real-time value: it describes the book at the instant of the call and is stale
  immediately. Recording when it was observed is not a substitute for a venue timestamp —
  it is a different, honest fact, and giving it its own field is what keeps it from being
  mistaken for one.

  **`Quote`'s `:timestamp` is the venue's own and nothing else.** That guarantee survives
  because observation time lives here, in a field that says what it is, rather than being
  written into a field documented as the venue's.

  ## Sizes are optional, and `nil` is not zero

  `:bid_size` and `:ask_size` are `nil` where the venue does not publish depth at the top —
  which is common, since a BBO endpoint is often deliberately cheaper than a book endpoint.
  **`nil` means "not published", never "none available".** A caller sizing an order against
  `nil` must treat it as unknown; a zero would say the level is empty, which is a different
  and much stronger claim.

  ## A one-sided book is real

  `:bid` or `:ask` may be `nil`. An illiquid instrument can genuinely have no resting bid,
  and a venue that says so is telling the truth. Refusing to represent that would force a
  package either to invent a level or to fail on a book that is merely thin.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :observed_at, :provider]
  defstruct [
    :symbol,
    :bid,
    :ask,
    :bid_size,
    :ask_size,
    :venue_time,
    :observed_at,
    :provider
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          bid: Decimal.t() | nil,
          ask: Decimal.t() | nil,
          bid_size: Decimal.t() | nil,
          ask_size: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          observed_at: DateTime.t(),
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  The mid price, or `nil` when either side is missing.

  **Deliberately a function and not a field.** A mid is derived, and a derived value stored
  beside its inputs is a value that can disagree with them. More importantly, a caller has
  to ask for it: `mid/1` at a call site reads as a choice, where a `:mid` field would read
  as data the venue supplied.

  A mid is **not** a traded price either. It is the midpoint of two resting orders and may
  be a price at which nothing has ever traded.
  """
  @spec mid(t()) :: Decimal.t() | nil
  def mid(%__MODULE__{bid: nil}), do: nil
  def mid(%__MODULE__{ask: nil}), do: nil

  def mid(%__MODULE__{bid: bid, ask: ask}) do
    bid |> Decimal.add(ask) |> Decimal.div(2)
  end

  @doc """
  The spread — `ask - bid` — or `nil` when either side is missing.
  """
  @spec spread(t()) :: Decimal.t() | nil
  def spread(%__MODULE__{bid: nil}), do: nil
  def spread(%__MODULE__{ask: nil}), do: nil
  def spread(%__MODULE__{bid: bid, ask: ask}), do: Decimal.sub(ask, bid)

  @doc """
  Whether the book is crossed — the bid is at or above the ask.

  A crossed book is usually a stale or partial read rather than a real market state, and a
  caller acting on one is acting on something that is probably wrong. This does not refuse
  to build a crossed struct: the venue said it, and discarding a venue's answer is not this
  layer's decision. It makes the condition **askable**.

  A one-sided book is not crossed — there is nothing to cross.
  """
  @spec crossed?(t()) :: boolean()
  def crossed?(%__MODULE__{bid: nil}), do: false
  def crossed?(%__MODULE__{ask: nil}), do: false
  def crossed?(%__MODULE__{bid: bid, ask: ask}), do: Decimal.compare(bid, ask) != :lt
end
