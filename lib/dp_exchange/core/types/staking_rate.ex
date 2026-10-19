defmodule DpExchange.Core.Types.StakingRate do
  @moduledoc """
  What one provider pays for staking one asset.

  ## Rates carry their unit, because venues do not agree on one

  Gemini publishes `rate` in **basis points**, `ratePct` as a percentage, and `apyPct` as an
  annualised percentage — three numbers for the same position, differing by a factor of a
  hundred and by compounding. A contract that carried "the rate" would be inviting a caller
  to be wrong by 100×, and the error would look plausible either way.

  So this carries **percentages only**, both named for what they are:

    * `:rate_pct` — the simple rate, as a percentage
    * `:apy_pct` — the annualised yield, as a percentage

  A venue publishing basis points converts on the way in. A venue publishing only one of the
  two leaves the other `nil` rather than deriving it: turning a simple rate into an APY needs
  a compounding frequency the venue did not state, and assuming one is inventing a number.

  ## `:deposit_limit_usd` is a real constraint

  Venues cap how much new notional can earn the advertised rate. A caller staking past the
  cap does not get an error — it gets a worse rate on the excess, silently. Carried where
  the venue publishes it.
  """

  alias DpExchange.Core.Types.Validate

  # 10^34: the first coefficient with more than the 34 digits Decimal 3.x parses.
  @max_parsed_coef 10_000_000_000_000_000_000_000_000_000_000_000

  @enforce_keys [:asset, :provider]
  defstruct [
    :asset,
    :provider_id,
    :rate_pct,
    :apy_pct,
    :deposit_limit_usd,
    :venue_time,
    :provider
  ]

  @type t :: %__MODULE__{
          asset: String.t(),
          provider_id: String.t() | nil,
          rate_pct: Decimal.t() | nil,
          apy_pct: Decimal.t() | nil,
          deposit_limit_usd: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    __MODULE__
    |> Validate.new!(@enforce_keys, attrs)
    |> Validate.decimals!([:rate_pct, :apy_pct, :deposit_limit_usd])
    |> Validate.non_negative!([:rate_pct, :apy_pct, :deposit_limit_usd])
  end

  @doc """
  Converts a rate in basis points to a percentage, or `nil` for a value it cannot read.

  Provided here rather than left to each venue package, because it is the conversion most
  likely to be done inconsistently — and a rate wrong by 100× still looks like a rate.

  ## What it refuses, and why it used to accept it

  A caller passes this whatever the venue sent, which is the entire reason it exists. It
  used to hand a binary straight to `Decimal.new/1`, and that is wrong in both directions:

    * **It raised.** `Decimal.new("")` and `Decimal.new("n/a")` raise `Decimal.Error`, so a
      venue omitting a rate, or naming it in words, crashed the caller rather than reporting
      an absent rate. `Decimal.new("  500  ")` raises too — padding is not a number this
      function should die on.

    * **It accepted `"NaN"` and `"Infinity"`.** Both parse, so both became a `Decimal` and
      then a rate. Every venue package in this family already refuses them, with the
      measurement recorded beside each copy: `Decimal.add(nan, 1)` is NaN and poisons a
      consumer's arithmetic silently, `Decimal.compare(nan, _)` raises in the consumer's own
      process naming Decimal rather than the venue, and an Infinity is quieter still — it
      compares greater than everything and never raises at all.

  So this now answers `nil` for anything it cannot read, which is exactly the convention
  every venue's own `decimal/1` follows. **The shared helper was less careful than the five
  copies it exists to replace.**

  `nil` is a rate the venue did not state. It is not zero, which is a rate.
  """
  @spec bps_to_pct(Decimal.t() | number() | String.t() | nil) :: Decimal.t() | nil
  def bps_to_pct(%Decimal{} = bps) do
    # An exponent outside `Validate.max_decimal_exponent/0` (`"1e5000"` parses in full) is
    # unreadable too: the rate it states is not one, and a `Decimal` that wide is refused by
    # every `Types.*` constructor, so returning one here only moved the failure downstream.
    cond do
      Decimal.nan?(bps) or Decimal.inf?(bps) -> nil
      abs(bps.exp) > Validate.max_decimal_exponent() -> nil
      true -> Decimal.div(bps, 100)
    end
  end

  def bps_to_pct(bps) when is_integer(bps), do: bps |> Decimal.new() |> Decimal.div(100)
  def bps_to_pct(bps) when is_float(bps), do: bps |> Decimal.from_float() |> Decimal.div(100)

  def bps_to_pct(bps) when is_binary(bps) do
    case bps |> String.trim() |> Decimal.parse() do
      # **Past 34 digits is unreadable at every Decimal version.** Decimal 3.x refuses to parse
      # it (`:error`, so `nil`); Decimal 2.x, which `mix.exs` admits, parsed it in full, so the
      # same text was a rate at the floor and no rate at the lock. A rate with more digits than
      # decimal128 holds is not one a venue states, and which answer it got depended on the
      # consumer's lockfile.
      {%Decimal{coef: coef}, ""} when is_integer(coef) and coef >= @max_parsed_coef -> nil
      {parsed, ""} -> bps_to_pct(parsed)
      _unreadable -> nil
    end
  end

  def bps_to_pct(_unreadable), do: nil
end
