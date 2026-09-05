defmodule DpExchange.Core.Types.OptionContract do
  @moduledoc """
  One option contract — **what it is**, not what it is worth.

  ## Identity only, deliberately

  Venues return option chains as fat rows: strike and expiry sitting beside bid, ask, last,
  mark, volume, open interest and five Greeks. This type takes only the first group.

  That is the same decision as splitting `Types.Quote` from `Types.TopOfBook`, and for the
  same reason. A row carrying `lastPrice`, `bidPrice`, `askPrice`, `markPrice` and
  `theoreticalOptionValue` gives a caller five plausible numbers to reach for and no help
  choosing, and this family has already shipped one defect from exactly that. So:

    * **identity** — this type
    * **book** — `Types.TopOfBook`
    * **last trade** — `Types.Quote`
    * **Greeks, IV, open interest** — `Types.OptionGreeks`

  ## An option is not a symbol, and the contract does not pretend otherwise

  `SymbolNormalizer` speaks `BASE-QUOTE` and refuses to construct option symbols, which is
  correct: venue option symbology is positional and venue-specific. Schwab's is fixed-width
  — `XYZ   240315C00500000` is underlying, padded to six, then `YYMMDD`, then `C` or `P`,
  then an eight-digit strike in thousandths.

  **A package must not build one by string arithmetic on a canonical pair.** The four
  identity fields here are the contract; `:venue_symbol` carries whatever the venue calls
  it, produced by the venue package and never reconstructed elsewhere.

  ## `:multiplier` is load-bearing and is not always 100

  Contract size varies — mini contracts, index options, adjusted contracts after a corporate
  action. A caller computing notional as `price × quantity` and omitting the multiplier is
  wrong by a factor of a hundred on a standard contract, and by an unpredictable factor on
  an adjusted one. `nil` means the venue did not say; it does not mean 100.

  ## The flags are not decoration

  `:non_standard` marks a contract whose deliverable has been altered by a corporate action —
  its price will not track the underlying the way its strike suggests. `:index_option` marks
  cash settlement rather than delivery. A caller that treats either as an ordinary equity
  option will be wrong about what it holds, not merely about its price.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:underlying, :expiry, :strike, :right, :provider]
  defstruct [
    :underlying,
    :expiry,
    :strike,
    :right,
    :venue_symbol,
    :multiplier,
    :settlement_type,
    :expiration_type,
    :last_trading_day,
    :index_option,
    :mini,
    :non_standard,
    :provider
  ]

  @type right :: :call | :put

  @type t :: %__MODULE__{
          underlying: String.t(),
          expiry: Date.t(),
          strike: Decimal.t(),
          right: right(),
          venue_symbol: String.t() | nil,
          multiplier: Decimal.t() | nil,
          settlement_type: String.t() | nil,
          expiration_type: String.t() | nil,
          last_trading_day: Date.t() | nil,
          index_option: boolean() | nil,
          mini: boolean() | nil,
          non_standard: boolean() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  Whether the contract is in the money at `underlying_price`.

  Computed here rather than taken from the venue's `isInTheMoney` flag, because venues
  compute it against their own mark at their own time and a caller comparing contracts
  across venues would be comparing two different questions.

  A caller wanting the venue's own opinion should keep it; this answers the arithmetic one.
  """
  @spec in_the_money?(t(), Decimal.t()) :: boolean()
  def in_the_money?(%__MODULE__{right: :call, strike: strike}, underlying_price) do
    Decimal.compare(underlying_price, strike) == :gt
  end

  def in_the_money?(%__MODULE__{right: :put, strike: strike}, underlying_price) do
    Decimal.compare(underlying_price, strike) == :lt
  end
end
