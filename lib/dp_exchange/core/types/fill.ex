defmodule DpExchange.Core.Types.Fill do
  @moduledoc """
  Normalised order fill — a partial or complete execution of the caller's own order.

  One fill is a single match against the book; **a single order may produce many fills**,
  so a caller reconstructing an order's economics sums its fills rather than reading any
  one of them.

  Distinct from `DpExchange.Core.Types.Trade`, which is the public tape.

  `:timestamp` is the venue's own, used as-is.
  """

  alias DpExchange.Core.Types.Validate

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

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.

  Also raises on a `:side` that is not `:buy` or `:sell`, and on a `:liquidity` that is not
  `:maker`, `:taker` or `nil`: `side: :long` on a fill reads as no side to a consumer
  matching the two the type states, and a `"maker"` string matches neither.

  A `:price` of zero or less raises, as a public trade's does (`Types.Trade`): a match
  happened at a price above zero, and a `0` is a decode bug (an absent price read as a number)
  that would zero the order's average price in whoever sums the fills. A negative `:fee` stays
  legal, since a maker rebate is a fee the venue paid.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@enforce_keys, attrs)
    |> Validate.text!([:order_id])
    |> Validate.decimals!([:quantity, :price, :fee])
    |> Validate.positive!([:price])
    |> Validate.non_negative!([:quantity])
    |> Validate.one_of!(:side, [:buy, :sell])
    |> Validate.one_of!(:liquidity, [:maker, :taker, nil])
  end
end
