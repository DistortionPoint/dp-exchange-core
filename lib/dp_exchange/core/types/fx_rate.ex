defmodule DpExchange.Core.Types.FxRate do
  @moduledoc """
  A foreign-exchange reference rate a venue publishes for a past instant.

  ## This is not a price the venue traded at

  Every other rate in this contract is the venue's own market. This one is not: Gemini's
  documentation says plainly that it *"does not offer foreign exchange services"* and that
  the endpoint is *"for historical reference only"*. The number comes from a third-party
  source the venue names, and the venue is relaying it.

  So `:source` and `:benchmark` are carried and are not decoration. `%{source: "bcb",
  benchmark: "Spot"}` says which institution published the rate and which of its series it
  came from. **Two venues relaying the same pair at the same instant can legitimately
  disagree**, and a caller reconciling them needs to know it is comparing two sources rather
  than finding a bug.

  ## `:as_of` is the rate's instant, not when it was fetched

  The endpoint takes a timestamp and answers for it. `:as_of` is that instant, echoed by the
  venue, and it is the whole content of the request — a rate without it is a number with no
  time attached, which is not a rate.

  ## `:provider` is the venue; `:source` is whoever computed the rate

  Two different facts that both look like "where this came from". Collapsing them would make
  a Gemini-relayed BCB rate indistinguishable from one Gemini computed itself, and only the
  second would be the venue's own claim.
  """

  @enforce_keys [:pair, :rate, :as_of, :provider]
  defstruct [:pair, :rate, :as_of, :source, :benchmark, :provider]

  @type t :: %__MODULE__{
          pair: String.t(),
          rate: Decimal.t(),
          as_of: DateTime.t(),
          source: String.t() | nil,
          benchmark: String.t() | nil,
          provider: atom() | String.t()
        }

  @doc """
  Converts `amount` at this rate.

  Straight multiplication, unrounded: `Decimal` is exact and the currency's precision is the
  caller's to apply, knowing which currency it holds.

  **This does not check the pair.** A caller converting AUD with a `GBPUSD` rate gets a
  number, and no type can tell it that was wrong without knowing which side of the pair the
  amount is in — which the venue's `fxPair` string alone does not say.
  """
  @spec convert(t(), Decimal.t()) :: Decimal.t()
  def convert(%__MODULE__{rate: rate}, amount), do: Decimal.mult(amount, rate)
end
