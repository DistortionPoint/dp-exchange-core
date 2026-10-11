defmodule DpExchange.Core.Types.OrderLeg do
  @moduledoc """
  One leg of a multi-leg order.

  ## A spread is one instruction, and the venue treats it as one

  A vertical, a straddle, an iron condor: the exchange accepts each as a single order and
  fills it as a unit or not at all. That is a fact about the venue's semantics, and this
  interface's job is to carry it across unchanged.

  So legs are a field of an order rather than orders of their own, and
  `supports_multi_leg_orders` on `Capabilities` says whether a venue accepts them at all. A
  venue that does not must **refuse** rather than decompose: submitting the legs separately
  sends the exchange something the caller never asked for, and reports back as though it
  had. That is the substitution this contract exists to prevent — the interface would be
  describing an operation the venue never performed.

  ## `:ratio` is not quantity

  A leg's size is the order's quantity times this leg's ratio. A 1×2 ratio spread is two legs
  with ratios 1 and 2, submitted once with a single quantity. Carrying absolute quantities
  per leg would let them drift out of proportion, which for a spread means it stops being
  the strategy it was.

  ## `:position_effect` is not derivable from `:side`

  Buying can open a long or close a short, and the venue needs to know which — some require
  it, and some price or margin the two differently. `nil` means the caller did not say and
  the venue will apply its own default, **not** that the effect is "open".
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :side, :ratio]
  defstruct [:symbol, :side, :ratio, :position_effect, :instrument_type]

  @type side :: :buy | :sell
  @type position_effect :: :open | :close

  @type t :: %__MODULE__{
          symbol: String.t(),
          side: side(),
          ratio: pos_integer(),
          position_effect: position_effect() | nil,
          instrument_type: atom() | nil
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.

  Also raises on a `:ratio` that is not a positive integer (a `0` leg, a fractional one, or
  a `Decimal` that a venue would round), a `:side` that is not `:buy` or `:sell`, and a
  `:position_effect` that is not `:open`, `:close` or `nil`. A spread with one leg
  mis-sided or at ratio `0` is a different trade that still validates as a spread.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@enforce_keys, attrs)
    |> Validate.positive_integer!(:ratio)
    |> Validate.one_of!(:side, [:buy, :sell])
    |> Validate.one_of!(:position_effect, [:open, :close, nil])
  end
end
