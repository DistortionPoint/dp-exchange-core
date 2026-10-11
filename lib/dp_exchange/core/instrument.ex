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
    # `:unknown`, not `:tradable`: an instrument nobody reported a status for is not evidence
    # it can be traded. See `new/1`.
    status: :unknown
  ]

  @type instrument_type :: :spot | :perp | :future | :unknown
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
  Build an instrument from already-normalised fields.

  This does **not** normalise anything: pass the venue's own strings through
  `instrument_from/1` and `status_from/1` first. Those two are conservative, so an
  unrecognised product type is `:unknown` (excluded from collection and surfaced for
  review), NOT `:spot`, and a venue that invents a new contract type is not silently
  admitted into a spot-only fleet.

  A field you leave out takes the struct default, and both defaults are `:unknown`. **`status`
  used to default to `:tradable`**, so an instrument built without one — a venue path that
  forgot to pass it — was reported tradable on no evidence at all, the substitution
  `status_from/1` exists to refuse. Pass `status:` whenever the venue states one.

  Raises `ArgumentError` if `:symbol` is absent OR `nil` — see this module's
  "`@enforce_keys` guards presence, not `nil`" section. It also raises for an `:instrument`
  or `:status` outside the closed vocabularies in `t:instrument_type/0` and `t:status/0`
  (a raw venue string such as `"online"`, or `:tradeable`, is a plausible value with no
  meaning to a consumer matching the atoms); pass the venue's string through
  `instrument_from/1` and `status_from/1` first.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    __MODULE__
    |> Validate.new!(@enforce_keys, fields)
    |> Validate.one_of!(:instrument, [:spot, :perp, :future, :unknown])
    |> Validate.one_of!(:status, [:tradable, :delisted, :unknown])
  end

  @doc """
  Normalise a venue's product-type string.

  Recognises the forms the four venues actually publish. Anything else is
  `:unknown` — the whole point is that an unrecognised type is visible. That includes a
  bare `"future"`, which may be dated or perpetual: use `instrument_from/2` with the
  venue's expiry kind.
  """
  @spec instrument_from(String.t() | nil) :: instrument_type()
  def instrument_from(type) when is_binary(type) do
    case String.downcase(type) do
      "spot" -> :spot
      # Gemini publishes `swap` for its 13 perpetuals.
      "swap" -> :perp
      "perp" -> :perp
      "perpetual" -> :perp
      # NOT `:perp`. A bare `future` is a dated contract on some venues and a perpetual
      # on others (Coinbase's `product_type: "FUTURE"` covers both, told apart only by
      # `future_product_details.contract_expiry_type`). The string alone cannot say which,
      # so it is `:unknown` — visible — until `instrument_from/2` is given the expiry kind.
      _unrecognised -> :unknown
    end
  end

  def instrument_from(_other), do: :unknown

  @doc """
  Normalise a venue's product-type string together with the venue's own statement of
  whether the contract expires.

  `expiry_kind` is the venue's word, case-insensitive: `"perpetual"` gives `:perp` and
  `"expiring"` gives `:future`, whatever `type` says, provided `type` is itself a
  derivative (`"future"`, `"perp"`, `"perpetual"`, `"swap"`). Anything else, including `nil`,
  falls back to `instrument_from/1`, so `"future"` with no readable expiry kind is
  `:unknown`, never a guess. A `"spot"` or unrecognised `type` is never turned into a
  derivative by an expiry kind.
  """
  @spec instrument_from(String.t() | nil, String.t() | nil) :: instrument_type()
  def instrument_from(type, expiry_kind) when is_binary(type) and is_binary(expiry_kind) do
    derivative? = String.downcase(type) in ["future", "perp", "perpetual", "swap"]

    case {derivative?, String.downcase(expiry_kind)} do
      {true, "perpetual"} -> :perp
      {true, "expiring"} -> :future
      _other -> instrument_from(type)
    end
  end

  def instrument_from(type, _expiry_kind), do: instrument_from(type)

  @doc """
  Normalise a venue's listing-status string.

  `limit_only` counts as tradable: the venue still matches orders, and treating
  it as delisted would silently drop live books. `closed` / `delisted` / `offline` are the
  terminal states. Anything else, `trading_disabled` included, is `:unknown`: a disabled
  market may come back, and reading it as delisted would be a guess.
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
