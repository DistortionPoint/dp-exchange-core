defmodule DpExchange.Core.Capabilities do
  @moduledoc """
  A venue's capability declaration — the return of `c:DpExchange.Core.Venue.capabilities/0`,
  and the thing a consumer branches on instead of on venue identity.

  ## Three kinds, and conflating them is the easy mistake

  **Kind 1 — activation and maturity.** *Is this function answerable, and is it proven?*
  One map from facade function to `:proven | :experimental | :unsupported`. This is the
  only kind that turns anything on or off.

  **Kind 2 — domain.** *For an active function, which arguments are valid?* Which order
  types the venue takes, which quotes it lists, which candle widths it serves. These
  constrain a call; they do not gate one.

  **Kind 3 — parameters.** *Limits and shapes of an active function.* Page sizes, rate
  ceilings, whether volume is reported. These tune behaviour and gate nothing.

  ## Kind 1 is a map, not a field per endpoint

  Three states cannot fit in a boolean, and a field per endpoint drifts the moment the
  facade grows: the field gets added, some venue forgets it, and the default decides. One
  map cannot fall out of step with the facade, and the conformance suite drives its
  bidirectional assertion straight off it.

  Anything not named in the map is `:experimental` — **the only honest default**. Not
  `:unsupported`, which would claim a refusal the venue never made, and certainly not
  `:proven`, which is earned by production use rather than by careful implementation.

  ## What is never declared: transport

  There is no `has_websocket`, no `websocket_module`, no `stream_channels` and no
  `pairs_per_socket`, and their absence is deliberate. **Both endpoints exist on every
  venue** — every venue can be pulled and can be subscribed — so there is nothing to
  declare and nothing for a consumer to branch on.

  Those four fields existed because a host was starting and sharding the venue's
  connections and needed to be told how. It no longer is. What a caller legitimately needs
  is *which kinds of data* stream, not which channels carry them: `"level2"` is one venue's
  word, `:order_book` is everyone's. See `t:data_kind/0`.

  ## What is not here because it is not the venue's call

  `auto_collect`, `default_quotes` and `overview_suits_collection` were in the declaration
  and are not any more. They are **consumer collection policy**: which quote asset to
  collect and what that costs in storage is a business decision, and no venue package ever
  read them.

  The split is clean. **A venue declares what it *can* serve** — `supported_quotes`, and a
  `catalog_size` class so a consumer knows one venue lists thousands and another millions.
  **A consumer decides what it *will* collect.**
  """

  alias DpExchange.Core.Timeframe

  @typedoc """
  How well one endpoint is known.

  `:experimental` is the default and the only honest starting state. `:proven` is earned
  per endpoint by production use.
  """
  @type maturity :: :proven | :experimental | :unsupported

  @typedoc """
  A kind of data a subscription can deliver — normalised, so a consumer never learns a
  venue's channel vocabulary.

  ## `:top_of_book` is not `:order_book`

  Venues stream these on separate channels because they are separate things: a best-bid/ask
  feed carries one level and a depth feed carries many, and the first is deliberately
  cheaper. They are kept apart here for the same reason `Types.TopOfBook` is not
  `Types.OrderBook` — a consumer subscribing to depth and receiving a single level would be
  told it has a book when it has a quote.

  ## What these were measured against

  Gemini's AsyncAPI document and Schwab's Streamer service list, read 2026-08-31:

      bookTicker                          -> :top_of_book
      depth, depth5/10/20 (+Fast)         -> :order_book
      trade                               -> :trades
      ordersAccount, ordersSession        -> :orders
      balancesAccount (+Snapshot)         -> :balances
      positionsAccount (+Snapshot)        -> :positions
      LEVELONE_*                          -> :quotes
      NYSE_BOOK, NASDAQ_BOOK, OPTIONS_BOOK -> :order_book
      CHART_EQUITY, CHART_FUTURES         -> :candles
      ACCT_ACTIVITY                       -> :orders and :fills

  **Three streamed channels have no kind here yet, deliberately**: Gemini's
  `settlementsAccount` and `contractStatus` are prediction-market lifecycle events, and its
  `requestForQuote*` family is an RFQ surface. None has a facade home, and inventing a kind
  before the shape is decided would put a name on the contract that nothing can deliver.
  """
  @type data_kind ::
          :quotes
          | :top_of_book
          | :order_book
          | :trades
          | :candles
          | :orders
          | :fills
          | :balances
          | :positions

  @typedoc """
  What credentials **buy** on this venue.

  A boolean could not say this. The old field answered "does this venue reject public
  calls without credentials", which has two states, while the real question has three —
  and the middle one is the common case:

    * `:no_difference` — public data is served, and credentials change nothing about it.
    * `:higher_ceiling` — public data is served, but the authenticated path has a
      materially higher rate limit. **A package holding credentials should be using it.**
    * `:required` — public data is not served at all without credentials.
  """
  @type credential_benefit :: :no_difference | :higher_ceiling | :required

  @typedoc """
  Requests per interval, as the venue publishes it.

  There are **two** of these on a venue with a better authenticated path, and which
  applies depends on what the caller supplied. Carrying one number means a package holding
  credentials meters itself against the public limit and leaves most of its budget unused.

  ## `:burst` is optional because most venues do not publish one

  A GCRA limiter takes three parameters — rate, interval, and how far a caller may run
  ahead of the rate before being made to wait. This type carried only the first two, so a
  venue that **publishes its burst depth** had nowhere to declare it and the package had
  to hardcode the number beside the declaration, which is precisely the drift this struct
  exists to prevent.

  Gemini publishes one: *"we offer a burst rate of five additional requests that are
  queued"*. It is the first venue in the family to do so, and it found this gap.

  Optional, not required, because a venue that does not publish a burst depth must not be
  made to invent one — and `nil` here means "not published", which a consumer can tell
  apart from a declared burst of zero.

  ## `max_leverage: :per_account`, for venues that margin without a single ceiling

  `max_leverage` began as `Decimal.t() | nil`, on the reasonable-looking assumption that a
  venue which margins has *a* leverage. Schwab does not, and the assumption cost more than
  it looked: `nil` with `supports_margin: true` raises, so the only ways to ship were to
  declare `supports_margin: false`, which is false, or to invent a multiplier — the
  substitution this whole family exists to refuse.

  A Schwab `MarginAccount` carries five different buying powers — overall, non-marginable,
  day-trading, option and stock — which are not multiples of one another, so no one of them
  is "the" leverage. A `CashAccount` at the same venue carries none of them, so any number
  reported for one would be invented. The Reg-T fields, `regTCall` and `sma`, are call and
  credit *amounts* rather than ratios. Equities margin is not crypto margin, and Kraken's
  5x does not carry over.

  So `:per_account` is a **positive statement**: the venue margins, and the ceiling belongs
  to the account rather than to the venue — read it from the balance response. `nil` still
  raises when `supports_margin: true`, because `nil` means "nobody said", and the error
  names `:per_account` so a venue author discovers the option instead of inventing a number.
  """
  @type ceiling ::
          %{
            required(:limit) => non_neg_integer(),
            required(:per_ms) => pos_integer(),
            optional(:burst) => pos_integer(),
            optional(:scope) => ceiling_scope()
          }
          | nil

  @typedoc """
  What a ceiling is counted against.

  `:credential` is the default and was the only case while every venue was crypto: one
  key, one budget. The others exist because Schwab's is neither.

  - `:credential` — per API key. One key, one bucket.
  - `:account` — per **account**, so a host running several accounts through one
    registration shares nothing between them and cannot infer one budget from another.
  - `:application` — per registered application, shared across every credential and
    account it issues. A ceiling a host cannot raise by adding keys.

  This changes what a *caller* must do, which is why it is declared rather than left
  implicit: a limiter keyed by credential silently over-permits a venue that counts by
  account.
  """
  @type ceiling_scope :: :credential | :account | :application

  @typedoc """
  Roughly how many instruments the venue lists.

  A class rather than a count, because the count changes daily and the decision it informs
  does not. It exists so a consumer can tell that re-pulling one venue's catalogue on a
  timer is fine and another's is not — the difference between a thousand instruments and
  millions is a different strategy, not a different number.
  """
  @type catalog_size :: :small | :large | :vast | :unknown

  @enforce_keys [:endpoints, :supported_quotes]
  defstruct endpoints: %{},
            supported_quotes: [],
            # --- Kind 2: domain -------------------------------------------------
            supported_order_types: [],
            supported_time_in_force: [],
            supported_instrument_types: [:spot],
            supports_short_selling: false,
            supports_margin: false,
            # `Decimal` when the venue has one ceiling, `:per_account` when it margins but
            # the ceiling belongs to the account rather than the venue (Reg-T equities —
            # see `validate_margin!/1`), `nil` only when it does not margin at all.
            max_leverage: nil,
            supports_fractional_shares: false,
            # Custodial staking only — the venue holds the asset and pays a rate. **Not**
            # on-chain staking, where the venue hands back an unsigned transaction for the
            # caller to sign and broadcast. Those are different capabilities and one venue
            # publishes both, so a flag that meant "stakes, somehow" would be useless
            # exactly where it matters.
            has_staking: false,
            # Which trading sessions an order may name. `[]` for a venue that trades
            # continuously — every crypto venue — and non-empty only where the market
            # closes, which is why nothing needed it until an equities broker arrived.
            supported_sessions: [],
            # Whether the venue can validate an order *without placing it*, returning
            # estimated cost. Only Schwab does, and it is the only way in the family to
            # check an order against the venue's own rules before committing.
            supports_order_preview: false,
            # Whether an order can be amended atomically. `false` means a caller must
            # cancel and re-place, which has a window in which no order is live — so this
            # is a claim about risk, not convenience.
            supports_order_replace: false,
            # Whether `place_order/3` can express more than one leg. `false` on every
            # venue in the family today; a venue with spreads declares `true` and the
            # request grows a `:legs` key.
            supports_multi_leg_orders: false,
            streamable: [],
            authenticated_streamable: [],
            historical_timeframes: [],
            # --- Kind 3: parameters ---------------------------------------------
            credential_benefit: :no_difference,
            public_ceiling: nil,
            authenticated_ceiling: nil,
            max_candles_per_request: nil,
            reports_trade_volume: false,
            catalog_size: :unknown,
            # How the catalogue can be reached. `:enumerable` — `get_symbols/1` returns
            # everything, which is the crypto shape and the one the contract used to
            # assume. `:query_only` — every lookup is a search and there is no
            # list-everything call, so `get_symbols/1` requires a term.
            catalog_access: :enumerable,
            # --- provenance ------------------------------------------------------
            measured_at: nil,
            measured_against: nil

  @type t :: %__MODULE__{
          endpoints: %{optional({atom(), arity()}) => maturity()},
          supported_quotes: [String.t()],
          supported_order_types: [atom()],
          supported_time_in_force: [atom()],
          supported_instrument_types: [atom()],
          supports_short_selling: boolean(),
          supports_margin: boolean(),
          max_leverage: Decimal.t() | :per_account | nil,
          supports_fractional_shares: boolean(),
          has_staking: boolean(),
          supported_sessions: [session()],
          supports_order_preview: boolean(),
          supports_order_replace: boolean(),
          supports_multi_leg_orders: boolean(),
          streamable: [data_kind()],
          authenticated_streamable: [data_kind()],
          historical_timeframes: [String.t()],
          credential_benefit: credential_benefit(),
          public_ceiling: ceiling(),
          authenticated_ceiling: ceiling(),
          max_candles_per_request: pos_integer() | nil,
          reports_trade_volume: boolean(),
          catalog_size: catalog_size(),
          catalog_access: catalog_access(),
          measured_at: Date.t() | nil,
          measured_against: String.t() | nil
        }

  @typedoc "Which trading session an order names, on a venue whose market closes."
  @type session :: :pre_market | :regular | :post_market | :extended

  @typedoc """
  How the venue's catalogue can be reached.

  `:enumerable` — `get_symbols/1` returns the whole list. `:query_only` — there is no
  list-everything call and `get_symbols/1` requires a search term.
  """
  @type catalog_access :: :enumerable | :query_only

  @maturities [:proven, :experimental, :unsupported]
  @data_kinds [
    :quotes,
    :top_of_book,
    :order_book,
    :trades,
    :candles,
    :orders,
    :fills,
    :balances,
    :positions
  ]

  # `:market` through `:fok` are the original seven, written for crypto venues. The four
  # that follow are real order types Schwab accepts and Core had no word for, so a venue
  # serving them had to under-declare — which is the safe direction and still a lie about
  # the venue.
  #
  # `:trailing_stop` and `:trailing_stop_limit` need offset fields no crypto venue has
  # (`stopPriceLinkBasis`, `stopPriceLinkType`, `stopPriceOffset` on Schwab). Declaring
  # them says the venue accepts the type; it does not promise Core can express every
  # parameter, which is what `place_order/3`'s request map is for.
  @order_types [
    :market,
    :limit,
    :stop,
    :stop_limit,
    :post_only,
    :ioc,
    :fok,
    :trailing_stop,
    :trailing_stop_limit,
    :market_on_close,
    :limit_on_close
  ]

  @time_in_force [:gtc, :ioc, :fok, :gtd, :day]

  # `:spot` and `:perp` were the whole vocabulary while every venue was crypto. An
  # equities broker trades none of the rest of this list as "spot" in any meaningful
  # sense — an option is not a spot instrument — so a venue serving them had to declare
  # `[:spot]` and add a comment saying the declaration understated it. A declaration that
  # needs a comment to be true is the thing this struct exists to prevent.
  @instrument_types [
    :spot,
    :perp,
    :option,
    :future,
    :future_option,
    :index,
    :mutual_fund,
    :bond,
    :forex,
    :cash_equivalent,
    # A binary contract on an outcome — Webull lists these as EVENT and settles them at 0
    # or 1. **Not an option and not a future**: there is no strike, no underlying to
    # deliver, and the payoff is a step rather than a curve. Declaring one as `:option`
    # would hand a caller a Greeks-shaped hole where the instrument has no Greeks.
    :event_contract
  ]

  # Which trading session an order is for. Empty for a venue that trades continuously,
  # which is every crypto venue and is why this did not exist until an equities broker
  # arrived. `:regular` is the session a person placing an order by hand would get.
  @sessions [:pre_market, :regular, :post_market, :extended]

  @ceiling_scopes [:credential, :account, :application]
  @catalog_accesses [:enumerable, :query_only]
  @credential_benefits [:no_difference, :higher_ceiling, :required]
  @catalog_sizes [:small, :large, :vast, :unknown]

  @doc """
  Builds a declaration, validating what a struct alone cannot express.

  Raises rather than returning an error tuple: this runs at venue-package definition time,
  where a wrong value is a programming error rather than a runtime condition — and a
  declaration that is wrong is worse than one that is missing, because a consumer will act
  on it.

  ## Examples

      iex> caps = DpExchange.Core.Capabilities.new(
      ...>   endpoints: %{{:get_price, 2} => :proven},
      ...>   supported_quotes: ~w(USD)
      ...> )
      iex> DpExchange.Core.Capabilities.maturity(caps, {:get_price, 2})
      :proven

      iex> DpExchange.Core.Capabilities.new(
      ...>   endpoints: %{{:get_price, 2} => :probably_fine},
      ...>   supported_quotes: ~w(USD)
      ...> )
      ** (ArgumentError) endpoint {:get_price, 2} declares unknown maturity :probably_fine — must be one of [:proven, :experimental, :unsupported]
  """
  @spec new(keyword() | map()) :: t()
  def new(fields) do
    declaration = struct!(__MODULE__, fields)

    validate_endpoints!(declaration)
    validate_vocabulary!(declaration)
    validate_history!(declaration)
    validate_streaming!(declaration)
    validate_ceilings!(declaration)
    validate_margin!(declaration)
    validate_orders!(declaration)
    validate_catalog!(declaration)

    declaration
  end

  @doc """
  The maturity of one endpoint.

  Anything undeclared is `:experimental` — a venue that forgot to mention an endpoint has
  not thereby claimed it is proven, nor refused it.

  ## Examples

      iex> caps = DpExchange.Core.Capabilities.new(endpoints: %{}, supported_quotes: [])
      iex> DpExchange.Core.Capabilities.maturity(caps, {:never_declared, 1})
      :experimental
  """
  @spec maturity(t(), {atom(), arity()}) :: maturity()
  def maturity(%__MODULE__{endpoints: endpoints}, endpoint) do
    Map.get(endpoints, endpoint, :experimental)
  end

  @doc """
  Whether an endpoint is answerable at all.

  `:proven` and `:experimental` both mean **it works** — maturity says how well a thing is
  known, never whether it runs.

  ## Examples

      iex> caps = DpExchange.Core.Capabilities.new(
      ...>   endpoints: %{{:place_order, 3} => :unsupported},
      ...>   supported_quotes: []
      ...> )
      iex> DpExchange.Core.Capabilities.active?(caps, {:place_order, 3})
      false
  """
  @spec active?(t(), {atom(), arity()}) :: boolean()
  def active?(declaration, endpoint), do: maturity(declaration, endpoint) != :unsupported

  @doc "Every endpoint declared at `maturity`."
  @spec endpoints_at(t(), maturity()) :: [{atom(), arity()}]
  def endpoints_at(%__MODULE__{endpoints: endpoints}, maturity) do
    for {endpoint, ^maturity} <- endpoints, do: endpoint
  end

  @doc "The maturity vocabulary."
  @spec maturities() :: [maturity()]
  def maturities, do: @maturities

  @doc "The normalised data kinds a subscription can deliver."
  @spec data_kinds() :: [data_kind()]
  def data_kinds, do: @data_kinds

  # --- validations -------------------------------------------------------

  defp validate_endpoints!(%__MODULE__{endpoints: endpoints}) when is_map(endpoints) do
    for {endpoint, maturity} <- endpoints do
      unless maturity in @maturities do
        raise ArgumentError,
              "endpoint #{inspect(endpoint)} declares unknown maturity #{inspect(maturity)} — " <>
                "must be one of #{inspect(@maturities)}"
      end

      unless match?({name, arity} when is_atom(name) and is_integer(arity), endpoint) do
        raise ArgumentError,
              "endpoint keys must be {function, arity}, got #{inspect(endpoint)} — " <>
                "a bare name cannot distinguish two arities of the same function"
      end
    end

    :ok
  end

  defp validate_endpoints!(%__MODULE__{endpoints: other}) do
    raise ArgumentError, "endpoints must be a map, got #{inspect(other)}"
  end

  defp validate_vocabulary!(declaration) do
    check_subset!(declaration.supported_order_types, @order_types, "supported_order_types")
    check_subset!(declaration.supported_time_in_force, @time_in_force, "supported_time_in_force")

    check_subset!(
      declaration.supported_instrument_types,
      @instrument_types,
      "supported_instrument_types"
    )

    unless declaration.credential_benefit in @credential_benefits do
      raise ArgumentError,
            "credential_benefit #{inspect(declaration.credential_benefit)} must be one of " <>
              "#{inspect(@credential_benefits)}"
    end

    unless declaration.catalog_size in @catalog_sizes do
      raise ArgumentError,
            "catalog_size #{inspect(declaration.catalog_size)} must be one of " <>
              "#{inspect(@catalog_sizes)}"
    end

    unless declaration.catalog_access in @catalog_accesses do
      raise ArgumentError,
            "catalog_access #{inspect(declaration.catalog_access)} must be one of " <>
              "#{inspect(@catalog_accesses)}"
    end

    check_subset!(declaration.supported_sessions, @sessions, "supported_sessions")

    # A venue that names sessions must be able to trade outside the regular one, or the
    # field says nothing. `[:regular]` alone is the continuous-market case dressed up as
    # a choice, and a consumer would build a session selector that has one option.
    if declaration.supported_sessions == [:regular] do
      raise ArgumentError,
            "supported_sessions [:regular] says nothing — a venue with only one session " <>
              "declares [] and a caller never names one. Declare the extended sessions " <>
              "too, or declare none"
    end

    :ok
  end

  # A venue claiming history but naming no width means a backfill that iterates an empty
  # list and reports success having written nothing — which reads identically to "already
  # backfilled". And a width outside the shared vocabulary would be requested, come back as
  # something, and be stored under a label nothing else can read.
  # The order-shape fields are only worth declaring if they agree with the endpoint map.
  # A venue that cannot place an order at all cannot preview, replace or leg one.
  defp validate_orders!(declaration) do
    places? = active?(declaration, {:place_order, 3})

    for {field, value} <- [
          supports_order_preview: declaration.supports_order_preview,
          supports_order_replace: declaration.supports_order_replace,
          supports_multi_leg_orders: declaration.supports_multi_leg_orders
        ],
        value and not places? do
      raise ArgumentError,
            "#{field} is true but place_order/3 is :unsupported — a venue that cannot " <>
              "place an order cannot preview, replace or leg one"
    end

    :ok
  end

  # `:query_only` is a claim about `get_symbols/1`, so it means nothing if that endpoint
  # is not active — and `:enumerable` on a venue that cannot enumerate is the default
  # quietly asserting something false, which is exactly what the field was added to stop.
  defp validate_catalog!(declaration) do
    query_only? = declaration.catalog_access == :query_only

    if query_only? and not active?(declaration, {:get_symbols, 1}) do
      raise ArgumentError,
            "catalog_access is :query_only but get_symbols/1 is :unsupported — " <>
              "'searchable only' and 'not served at all' are different facts, and a " <>
              "caller acts differently on each"
    end

    :ok
  end

  defp validate_history!(declaration) do
    # Keyed on an EXPLICIT declaration, not on `active?/2`. Undeclared endpoints default
    # to `:experimental`, so `active?` would read silence as a claim of history and
    # demand widths from every venue — including ones that serve none. Silence is not a
    # claim; the conformance suite is what checks a declaration against real behaviour.
    claims_history? =
      Map.get(declaration.endpoints, {:get_historical_prices, 4}) in [:proven, :experimental]

    if claims_history? and declaration.historical_timeframes == [] do
      raise ArgumentError,
            "get_historical_prices/4 is active but historical_timeframes is empty — the " <>
              "backfill would iterate nothing and report success. Measure the venue's " <>
              "endpoint and declare the widths it actually serves"
    end

    case declaration.historical_timeframes -- Timeframe.nameable() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "historical_timeframes #{inspect(unknown)} are outside the timeframe vocabulary — " <>
                "a width Core cannot name would be stored under a label nothing can read back. " <>
                "Note this checks nameability, not bucketing: 1w and 1M are nameable and " <>
                "deliberately have no boundary rule"
    end
  end

  defp validate_streaming!(declaration) do
    check_subset!(declaration.streamable, @data_kinds, "streamable")
    check_subset!(declaration.authenticated_streamable, @data_kinds, "authenticated_streamable")

    # Requiring credentials for a kind the venue cannot stream at all is a declaration
    # that can never be true, and a consumer would go looking for the credential.
    case declaration.authenticated_streamable -- declaration.streamable do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "authenticated_streamable #{inspect(missing)} are not in streamable " <>
                "#{inspect(declaration.streamable)} — a kind that needs credentials must " <>
                "first be a kind the venue streams"
    end
  end

  # The mirror of the incident where a ceiling bound nothing: here the risk is a package
  # holding credentials metering itself against the public limit and leaving most of its
  # budget unused.
  defp validate_ceilings!(declaration) do
    for {name, ceiling} <- [
          {"public_ceiling", declaration.public_ceiling},
          {"authenticated_ceiling", declaration.authenticated_ceiling}
        ],
        not is_nil(ceiling) do
      validate_one_ceiling!(name, ceiling)
    end

    if declaration.credential_benefit == :higher_ceiling and
         is_nil(declaration.authenticated_ceiling) do
      raise ArgumentError,
            "credential_benefit is :higher_ceiling but authenticated_ceiling is nil — the " <>
              "whole point of that value is that there are two ceilings and a caller needs " <>
              "the second one"
    end

    :ok
  end

  #  is `non_neg_integer` rather than `pos_integer`, and the zero is deliberate.
  # Schwab registers applications with an order throughput anywhere in `0..120` per
  # minute, and **zero is a legal registration**. It is not the same as `:unsupported`:
  # the endpoint exists and the venue serves it — this application cannot use it. A
  # consumer must be able to tell "the venue has no such endpoint" from "your
  # registration was granted none of it", because the remedies differ entirely.
  defp validate_one_ceiling!(name, ceiling) do
    unless match?(
             %{limit: l, per_ms: p} when is_integer(l) and l >= 0 and is_integer(p) and p > 0,
             ceiling
           ) do
      raise ArgumentError,
            "#{name} must be %{limit: non_neg_integer, per_ms: pos_integer}, " <>
              "got #{inspect(ceiling)}"
    end

    case ceiling do
      %{scope: scope} when scope not in @ceiling_scopes ->
        raise ArgumentError,
              "#{name} :scope must be one of #{inspect(@ceiling_scopes)}, got #{inspect(scope)}"

      _no_scope_or_valid ->
        :ok
    end

    # `:burst` is optional, but a present one must be a real depth. A burst of zero would
    # be a limiter that never lets anything through, and a string here would reach the
    # limiter's arithmetic before anyone noticed.
    case ceiling do
      %{burst: burst} when not (is_integer(burst) and burst > 0) ->
        raise ArgumentError,
              "#{name} :burst must be a pos_integer when present, got #{inspect(burst)}"

      _no_burst_or_valid ->
        :ok
    end
  end

  defp validate_margin!(%__MODULE__{supports_margin: false, max_leverage: nil}), do: :ok

  defp validate_margin!(%__MODULE__{supports_margin: false, max_leverage: leverage}) do
    raise ArgumentError,
          "max_leverage #{inspect(leverage)} is declared but supports_margin is false — " <>
            "a leverage a caller cannot use reads as capability the venue does not have"
  end

  defp validate_margin!(%__MODULE__{supports_margin: true, max_leverage: nil}) do
    raise ArgumentError,
          "supports_margin is true but max_leverage is nil — a caller sizing a leveraged " <>
            "order has no ceiling to size against, and guessing one is how a position " <>
            "exceeds what the venue will accept. If the venue margins but the ceiling belongs " <>
            "to the account rather than to the venue, declare :per_account — that is a " <>
            "statement where nil is a silence"
  end

  # A venue that margins but has no single ceiling. Reg-T is the case that forced this:
  # a Schwab margin account carries five different buying powers — overall,
  # non-marginable, day-trading, option and stock — which are not multiples of one
  # another, and a cash account at the same venue carries none of them. There is no
  # number that is true, and `nil` would read as "nobody stated it" rather than as "the
  # venue does not have one". `:per_account` says the second thing out loud and points a
  # caller at the balance response, which is where the answer actually lives.
  defp validate_margin!(%__MODULE__{supports_margin: true, max_leverage: :per_account}), do: :ok

  defp validate_margin!(%__MODULE__{supports_margin: true, max_leverage: %Decimal{}}), do: :ok

  defp validate_margin!(%__MODULE__{max_leverage: leverage}) do
    raise ArgumentError,
          "max_leverage #{inspect(leverage)} is neither a Decimal nor :per_account — a " <>
            "leverage a caller must parse by guessing its type is a leverage it will get wrong"
  end

  defp check_subset!(values, allowed, name) when is_list(values) do
    case values -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "#{name} #{inspect(unknown)} not in #{inspect(allowed)}"
    end
  end

  defp check_subset!(values, _allowed, name) do
    raise ArgumentError, "#{name} must be a list, got #{inspect(values)}"
  end
end
