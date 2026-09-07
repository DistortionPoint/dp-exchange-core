defmodule DpExchange.Core.Instrument do
  @moduledoc """
  One listing as the VENUE describes it: canonical symbol, base, quote,
  instrument type and trading status.

  ## Why this exists

  `get_symbols/1` returns `[String.t()]`. A venue adapter fetches the venue's rich
  listing payload and then throws away everything except the symbol — Coinbase
  discards `base_currency_id`, `quote_currency_id`, `product_type` and `status`
  on the line that maps `& &1["product_id"]`.

  The pair catalog needs exactly those discarded fields. Recovering them by
  parsing the symbol string back apart is what this design explicitly rejects:
  an earlier draft proposed regex-matching a `PERP` suffix and got Gemini's
  quote distribution measurably wrong, missing its GBP, EUR, SOL and FIL quotes
  entirely. Gemini is the sharp case — its symbols have no separator, so
  `BTCUSDCPERP` cannot be split into base and quote at all without the venue's
  own fields.

  So this is a separate callback rather than a change to `get_symbols/1`, whose
  callers only want names and shouldn't pay for the extra requests (Gemini's
  details are per-symbol: 347 calls).

  ## Optional by design

  `list_instruments/1` is an OPTIONAL callback. Webull and Robinhood publish
  single-quote `-USD` catalogs where base and quote are trivially derivable and
  no non-spot instruments exist, so requiring an implementation there would be
  ceremony. A consumer building a catalogue falls back to `get_symbols/1` plus its
  own derivation for those, and marks anything it cannot resolve `:unknown` —
  surfaced for review, never guessed.

  ## `@enforce_keys` guards presence, not `nil`

  Same trap as every `Core.Types.*` struct — see `DpExchange.Core.Types.Validate`. A
  `symbol: nil` is PRESENT, so `struct!/2` alone would build it without complaint even
  though the typespec below declares `symbol: String.t()`, never `String.t() | nil` — the
  one field this whole module exists to attach base/quote/status/type to. `new/1` runs
  through `Validate.new!/3`, the same constructor every `Core.Types.*` module uses, so an
  explicit `nil` fails exactly the way an absent key already did.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol]
  defstruct [
    :symbol,
    :base,
    :quote,
    instrument: :unknown,
    status: :tradable
  ]

  @type instrument_type :: :spot | :perp | :unknown
  @type status :: :tradable | :delisted | :unknown

  @type t :: %__MODULE__{
          # Canonical `BASE-QUOTE`, matching what the rest of the platform uses.
          symbol: String.t(),
          base: String.t() | nil,
          quote: String.t() | nil,
          instrument: instrument_type(),
          status: status()
        }

  @doc """
  Build an instrument, normalising the venue's own type and status strings.

  Both default to the conservative reading rather than the flattering one:
  an unrecognised product type is `:unknown` (excluded from collection and
  surfaced for review), NOT `:spot`. A venue that invents a new contract type
  must not have it silently admitted into a spot-only fleet.

  Raises `ArgumentError` if `:symbol` is absent OR `nil` — see this module's
  "`@enforce_keys` guards presence, not `nil`" section.
  """
  @spec new(keyword()) :: t()
  def new(fields), do: Validate.new!(__MODULE__, @enforce_keys, fields)

  @doc """
  Normalise a venue's product-type string.

  Recognises the forms the four venues actually publish. Anything else is
  `:unknown` — the whole point is that an unrecognised type is visible.
  """
  @spec instrument_from(String.t() | nil) :: instrument_type()
  def instrument_from(type) when is_binary(type) do
    case String.downcase(type) do
      "spot" -> :spot
      # Gemini publishes `swap` for its 13 perpetuals; Coinbase uses
      # `future` / `perpetual` on its derivatives venue.
      "swap" -> :perp
      "perp" -> :perp
      "perpetual" -> :perp
      "future" -> :perp
      _unrecognised -> :unknown
    end
  end

  def instrument_from(_other), do: :unknown

  @doc """
  Normalise a venue's listing-status string.

  `limit_only` counts as tradable: the venue still matches orders, and treating
  it as delisted would silently drop live books. `closed` / `delisted` /
  `trading_disabled` are the terminal states.
  """
  @spec status_from(String.t() | nil) :: status()
  def status_from(status) when is_binary(status) do
    case String.downcase(status) do
      "online" -> :tradable
      "open" -> :tradable
      "active" -> :tradable
      "limit_only" -> :tradable
      "closed" -> :delisted
      "delisted" -> :delisted
      "offline" -> :delisted
      _unrecognised -> :unknown
    end
  end

  def status_from(_other), do: :unknown
end
