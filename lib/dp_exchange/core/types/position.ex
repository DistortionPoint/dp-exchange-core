defmodule DpExchange.Core.Types.Position do
  @moduledoc """
  An open position in a derivative — distinct from a balance, and not derivable from one.

  ## A position is not a balance

  A balance says how much of an asset an account holds. A position says what exposure it has
  taken, at what price, financed how, and how far it is from being liquidated. A spot venue
  has balances and no positions; a perpetuals venue has both, and they answer different
  questions. Collapsing them would leave a caller unable to ask the only question that
  matters on a leveraged book: how much room is left.

  ## `:side` is explicit, and `:quantity` is always positive

  Venues disagree about how to say "short". Some send a negative quantity, some a side
  field, some both — and a package that guessed would produce a position that is exactly
  backwards while every number in it stays plausible. **A sign convention is not a fact
  about the market; it is a fact about one venue's JSON**, and it does not belong in the
  contract.

  So `:quantity` is the size, always positive, and `:side` is `:long` or `:short`. A venue
  sending `-0.2` converts on the way in and says which it meant.

  ## Realised and unrealised are never added together

  `:realised_pnl` has happened; `:unrealised_pnl` is a mark-to-market opinion that changes
  with the next tick and may never be realised. A single "pnl" field would invite a caller
  to book profit it does not have.

  ## `:liquidation_price` being `nil` does not mean safe

  It means **the venue did not say**. On a leveraged position that is the single most
  consequential unknown in this struct, and reading `nil` as "no liquidation risk" is the
  substitution this contract is written against. A caller that needs the number and finds
  `nil` must treat the position as un-assessed, not as safe.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :side, :quantity, :provider]
  defstruct [
    :symbol,
    :side,
    :quantity,
    :instrument_type,
    :average_cost,
    :mark_price,
    :notional_value,
    :realised_pnl,
    :unrealised_pnl,
    :liquidation_price,
    :leverage,
    :venue_time,
    :provider
  ]

  @type side :: :long | :short

  @type t :: %__MODULE__{
          symbol: String.t(),
          side: side(),
          quantity: Decimal.t(),
          instrument_type: atom() | nil,
          average_cost: Decimal.t() | nil,
          mark_price: Decimal.t() | nil,
          notional_value: Decimal.t() | nil,
          realised_pnl: Decimal.t() | nil,
          unrealised_pnl: Decimal.t() | nil,
          liquidation_price: Decimal.t() | nil,
          leverage: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  Normalises a venue's signed quantity into `{side, positive_quantity}`.

  Provided here so the convention is applied identically everywhere. A venue that sends a
  side field of its own should use that instead and ignore this — **this is for venues whose
  only statement of direction is the sign**, and it exists because getting it wrong produces
  a position that is exactly backwards and looks entirely normal.

  Zero is `:long` by convention, and a zero-quantity position should generally not be built
  at all: a closed position is not an open one.
  """
  @spec from_signed_quantity(Decimal.t()) :: {side(), Decimal.t()}
  def from_signed_quantity(%Decimal{} = quantity) do
    case Decimal.negative?(quantity) do
      true -> {:short, Decimal.abs(quantity)}
      false -> {:long, quantity}
    end
  end
end
