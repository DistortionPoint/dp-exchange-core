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
  """
  @type data_kind :: :quotes | :order_book | :trades | :orders | :fills | :balances

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
  """
  @type ceiling ::
          %{
            required(:limit) => pos_integer(),
            required(:per_ms) => pos_integer(),
            optional(:burst) => pos_integer()
          }
          | nil

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
            max_leverage: nil,
            supports_fractional_shares: false,
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
          max_leverage: Decimal.t() | nil,
          supports_fractional_shares: boolean(),
          streamable: [data_kind()],
          authenticated_streamable: [data_kind()],
          historical_timeframes: [String.t()],
          credential_benefit: credential_benefit(),
          public_ceiling: ceiling(),
          authenticated_ceiling: ceiling(),
          max_candles_per_request: pos_integer() | nil,
          reports_trade_volume: boolean(),
          catalog_size: catalog_size(),
          measured_at: Date.t() | nil,
          measured_against: String.t() | nil
        }

  @maturities [:proven, :experimental, :unsupported]
  @data_kinds [:quotes, :order_book, :trades, :orders, :fills, :balances]
  @order_types [:market, :limit, :stop, :stop_limit, :post_only, :ioc, :fok]
  @time_in_force [:gtc, :ioc, :fok, :gtd, :day]
  @instrument_types [:spot, :perp]
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

    :ok
  end

  # A venue claiming history but naming no width means a backfill that iterates an empty
  # list and reports success having written nothing — which reads identically to "already
  # backfilled". And a width outside the shared vocabulary would be requested, come back as
  # something, and be stored under a label nothing else can read.
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

    case declaration.historical_timeframes -- Timeframe.known() do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "historical_timeframes #{inspect(unknown)} are not known timeframes — a width " <>
                "the vocabulary does not model would be stored under a label nothing can read"
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
      unless match?(%{limit: l, per_ms: p} when is_integer(l) and is_integer(p), ceiling) do
        raise ArgumentError,
              "#{name} must be %{limit: pos_integer, per_ms: pos_integer}, got #{inspect(ceiling)}"
      end

      # `:burst` is optional, but a present one must be a real depth. A burst of zero
      # would be a limiter that never lets anything through, and a string here would
      # reach the limiter's arithmetic before anyone noticed.
      case ceiling do
        %{burst: burst} when not (is_integer(burst) and burst > 0) ->
          raise ArgumentError,
                "#{name} :burst must be a pos_integer when present, got #{inspect(burst)}"

        _no_burst_or_valid ->
          :ok
      end
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
            "exceeds what the venue will accept"
  end

  defp validate_margin!(_declaration), do: :ok

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
