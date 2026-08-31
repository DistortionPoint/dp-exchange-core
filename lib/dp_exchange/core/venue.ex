defmodule DpExchange.Core.Venue do
  @moduledoc """
  **The facade. The single module a consumer touches, identical on every venue.**

      defmodule DpExchange.Coinbase do
        @behaviour DpExchange.Core.Venue
      end

  Nothing else in a venue package is public API. A venue's transport, rate limiting,
  signing, session handling and supervision are implementation detail behind this, and a
  consumer cannot reach them because there is nothing here that returns them.

  ## The one rule everything else follows from

  **The facade is one fixed set of functions, never extended per venue and never omitted.**
  What differs between venues is which of them are *active*, and that is declared — once,
  in `c:capabilities/0` — rather than expressed by a venue defining extra functions or
  leaving some out.

  This is what dissolves the "all the same, but some have extras" tension. A venue does not
  add functions; it declares which ones it answers. There is no second mechanism and no
  escape hatch, because an escape hatch is a way for a caller to need to know which venue
  it is holding, and that is the one thing this contract exists to prevent.

  ## What crosses, in full

  Anything not on this list is a design error, not an omission.

  **In**: credentials, symbols, order requests, options. That is the entire inbound
  surface. No modules, no functions, no callbacks, no sink — a consumer never hands a
  package a piece of itself.

  **Out**: `{:ok, value}` / `{:error, reason}` / `{:refused, reason}` from the pull
  endpoints; `DpExchange.Core.Types.*` structs pushed to subscribers; `DpExchange.Core.Notice`
  structs on the notices channel; telemetry under `[:dp_exchange, …]`.

  **Never out**: socket handles, connection pools, transport library state, MQTT sessions,
  rate-limit buckets, signing keys, retry timers, supervisor pids.

  ## Both endpoints always exist

  Every venue can be **pulled** and can be **subscribed**. There is no flag for it and
  nothing to branch on. A venue with no streaming API implements `c:subscribe/2` over its
  own polling and pushes the results; a consumer calling `c:subscribe/2` gets a stream
  whether the mechanism beneath it is a socket, an MQTT session or a loop.

  That is not a convenience. The moment a consumer can ask *how* the data arrives, it can
  branch on the answer, and every consumer above the package forks on transport.

  ## Maturity is per endpoint, and it is bidirectional

  `c:capabilities/0` reports `:proven | :experimental | :unsupported` for each function.
  The declaration and the behaviour may not disagree, in **either** direction:

    * `:proven` or `:experimental` means the function **works**. Neither may answer
      `{:error, :not_supported}` — maturity says how well a thing is known, never whether
      it runs.
    * `:unsupported` means the function **exists and returns `{:error, :not_supported}`**.
      It may not raise, may not be undefined, and may not quietly succeed with degraded
      data.

  Both halves are asserted by the conformance suite. Checking only the first lets a venue
  under-declare and hide working functionality; checking only the second lets it
  over-declare and fail in a caller's hands. Holding both is what lets a consumer branch on
  `c:capabilities/0` instead of on venue identity.

  `{:error, :not_supported}` is **the atom**. The source this contract was extracted from
  returned the string `"not_supported"` in some places and the atom in others — in one case
  both within a single module — so a caller matching the atom silently missed the string and
  treated a refusal as an unrecognised error.

  ## A library does not start itself

  `c:child_spec/1` exists so **you** supervise the venue. This package ships no aggregate
  supervisor and no start-everything entry point: it would have to know which venues exist,
  and it would take a decision that is yours — which venues run, under what restart
  strategy, with what names. A consumer that has not asked for a venue never finds a socket
  open.
  """

  alias DpExchange.Core.{Capabilities, Instrument, Notice, Types}

  @typedoc "Opaque to this contract. A venue package documents its own shape."
  @type credentials :: map()

  @typedoc "Canonical `BASE-QUOTE` for a pair; a bare symbol on an equity venue."
  @type symbol :: String.t()

  @typedoc """
  The three-state maturity of one endpoint.

  `:experimental` is the default and the only honest starting state. `:proven` is earned
  per endpoint by production use, never by careful implementation.
  """
  @type maturity :: :proven | :experimental | :unsupported

  @typedoc """
  How a symbol's data is reaching the caller right now, **as observed**.

  Never what was subscribed. A venue that cannot observe delivery answers `:not_covered`
  rather than assuming its subscription worked.
  """
  @type route :: :stream | :internal_poll | :not_covered

  @typedoc "Whether the venue is trading right now. Crypto venues answer `:open` always."
  @type market_status :: :open | :closed | :pre | :post

  @typedoc """
  A refusal is not an error.

  `{:refused, reason}` is the venue stating it does not carry this symbol at all — a
  permanent answer. `{:error, reason}` may be transient and is worth retrying. Collapsing
  the two makes a delisted symbol look like a network blip forever.
  """
  @type result(value) :: {:ok, value} | {:error, term()} | {:refused, term()}

  # --- Lifecycle ---------------------------------------------------------

  @doc """
  Starts the venue's whole tree — connections, limiter, session refresh, whatever it needs.

  A venue with no processes returns `:ignore`. **You** put this in your supervision tree
  and choose its restart strategy, shutdown order and name.
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Starts the venue directly. See `c:child_spec/1` — a venue with no processes returns `:ignore`."
  @callback start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}

  # --- Declaration -------------------------------------------------------
  #
  # Static, credential-free, and safe to call at boot. A consumer decides whether to use a
  # package at all from these four, so none of them may need a network or a key.

  @doc "The venue's display name."
  @callback provider_name() :: String.t()

  @doc "The venue's stable identifier, matching its package's namespace segment."
  @callback runtime_id() :: atom()

  @doc "Which asset classes this venue trades, e.g. `[:crypto]` or `[:crypto, :equity]`."
  @callback asset_classes() :: [atom()]

  @doc """
  The activation map: which functions are answerable, and how well each is known.

  Static and safe at boot. This is what a consumer branches on instead of venue identity.
  """
  @callback capabilities() :: Capabilities.t()

  # --- Market data -------------------------------------------------------
  #
  # Credentials are an INPUT to which upstream endpoint serves the caller best, never a
  # gate on whether one does. Several venues serve the same data publicly and
  # authenticated, with a materially higher ceiling on the authenticated path, and a
  # package holding credentials should be using it. Which endpoint was actually called is
  # mechanism and does not cross this boundary — the caller passes credentials or does
  # not, and reads the consequence from `c:capabilities/0`.

  @doc "The current price for `symbol`."
  @callback get_price(symbol(), keyword()) :: result(Types.Quote.t())

  @doc """
  Historical candles for `symbol` at `timeframe`.

  The venue rejects a timeframe it does not serve rather than substituting the nearest
  one. A missing granularity silently becoming the closest one mislabels every candle it
  touches, and every value stays plausible.
  """
  @callback get_historical_prices(symbol(), String.t(), keyword(), keyword()) ::
              result([Types.Quote.t()])

  @doc "Every symbol the venue lists."
  @callback get_symbols(keyword()) :: result([symbol()])

  @doc "The order book for `symbol`, best price first on both sides."
  @callback get_order_book(symbol(), keyword()) :: result(Types.OrderBook.t())

  @doc "A bulk snapshot across the venue's symbols, where it offers one."
  @callback get_market_overview(keyword()) :: result(map())

  @doc """
  The venue's listings with the fields `c:get_symbols/1` discards — base, quote,
  instrument type, trading status.

  Optional: single-quote venues derive base and quote trivially and have no non-spot
  instruments, so requiring an implementation there is ceremony.
  """
  @callback list_instruments(keyword()) :: result([Instrument.t()])

  # --- Account and trading -----------------------------------------------
  #
  # Credentials arrive as arguments. A package never reads them from a vault, an
  # environment variable or a consumer's config — it is handed what it needs, per call.

  @doc "Balances for the credentialed account."
  @callback get_balances(credentials(), keyword()) :: result([Types.Balance.t()])

  @doc "Accounts visible to the credential."
  @callback get_accounts(credentials(), keyword()) :: result([map()])

  @doc "The fee schedule that applies to this credential."
  @callback get_fees(credentials(), keyword()) :: result(map())

  @doc "Deposit and withdrawal history — needed to compute cost basis for transferred-in assets."
  @callback get_transfers(credentials(), keyword()) :: result([map()])

  @doc "Places an order. Irreplaceable by definition: this is the act."
  @callback place_order(credentials(), map(), keyword()) :: result(Types.Order.t())

  @doc "Cancels an order."
  @callback cancel_order(credentials(), String.t(), keyword()) :: result(Types.Order.t())

  @doc """
  Validates an order **without placing it**, returning the venue's own estimate of what
  it would cost.

  Optional, and only Schwab serves it. It is the one call in the family that checks an
  order against the venue's rules before committing to it — which matters most exactly
  where order writes are rate-limited and reads are not.

  Declared through `supports_order_preview`, so a caller can tell "this venue has no
  preview" from "this package has not implemented one".
  """
  @callback preview_order(credentials(), map(), keyword()) :: result(map())

  @doc """
  Replaces an open order **atomically**.

  Optional. Every crypto venue in the family cancels and re-places, and on a venue that
  supports replacement those two calls are **not equivalent**: cancel-then-place opens a
  window in which no order is live, and on a moving market that window is the risk.

  So this is a claim about risk rather than convenience, and it is declared through
  `supports_order_replace` rather than being inferred from the callback existing.
  """
  @callback replace_order(credentials(), String.t(), map(), keyword()) :: result(Types.Order.t())

  @doc "One order's current state."
  @callback get_order(credentials(), String.t(), keyword()) :: result(Types.Order.t())

  @doc "Orders visible to the credential."
  @callback get_orders(credentials(), keyword()) :: result([Types.Order.t()])

  @doc "Past fills for the credential."
  @callback get_trade_history(credentials(), keyword()) :: result([Types.Fill.t()])

  # --- Streaming ---------------------------------------------------------

  @doc """
  Subscribes the caller to `symbols`.

  **The venue decides everything about how.** Connections, sharding, pacing, protocol,
  whether it streams at all or polls and pushes the results — none of it crosses this
  boundary, and a caller cannot discover it.

  Events arrive as messages to the subscribing process, or to a pid given in `opts`,
  tagged so a process subscribed to several venues can tell them apart. The payload is a
  `DpExchange.Core.Types.*` struct — **the same value the pull endpoints return** — so one
  handler serves a price whether the caller asked for it or was sent it.

  ## Back-pressure is a bounded mailbox, and it is declared

  A venue pushing faster than its subscriber consumes drops oldest beyond a stated bound
  and emits a `:degraded` notice saying so. Growing a mailbox silently until the node dies
  is the failure this avoids; dropping silently is the failure the notice avoids.
  """
  @callback subscribe([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  Stops delivery for `symbols`.

  **Addressed by the thing itself, never by a handle.** Takes the same identifiers
  `c:subscribe/2` was given: on crypto the pair, on an equity venue the symbol. A caller
  already knows what it subscribed to, so a subscription reference would be pure overhead
  wrapping something it already holds — and one more thing to leak.

  A dead subscriber stops delivery too. A venue must not accumulate events for a process
  that no longer exists.
  """
  @callback unsubscribe([symbol()], keyword()) :: :ok | {:error, term()}

  @doc "Changes a live subscription's symbol set without tearing the venue's connections down."
  @callback update_symbols([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  What is **observed arriving**, by which route — never what was subscribed.

  This is the strongest guarantee in the contract, and it exists because intent standing in
  for evidence is how a venue reported 325 symbols subscribed and confirmed while 174 were
  delivering. A venue that cannot observe delivery answers `:not_covered` rather than
  reporting success it cannot see.

  Symbols absent from the map are `:not_covered`.
  """
  @callback coverage(keyword()) :: %{symbol() => route()}

  @doc """
  Subscribes the caller to the package's notices — what it is doing and what is going
  wrong with it.

  Distinct from `c:subscribe/2`, which carries what the *venue* says about the *market*. A
  monitoring process that never touches market data still needs to know a credential was
  rejected.

  **A notice is a prompt to re-read, never the record.** Delivery is not guaranteed — see
  `DpExchange.Core.Notice`.
  """
  @callback subscribe_notices(keyword()) :: :ok | {:error, term()}

  # --- Health ------------------------------------------------------------

  @doc "Whether the venue is reachable and the credential, if given, is accepted."
  @callback test_connection(credentials() | nil, keyword()) :: result(map())

  @doc "What the venue's ceiling currently is and how much of it is left."
  @callback get_rate_limit_status(credentials() | nil, keyword()) :: result(map())

  @doc """
  Whether the venue is trading right now.

  Crypto venues answer `:open`. An equity venue answers honestly, including pre- and
  post-market.

  **Not cosmetic.** A feed that delivers nothing warns loudly and keeps warning, so without
  this an equities package alarms every night and every weekend — and a real outage becomes
  indistinguishable from Saturday. The venue is the only thing that knows its own calendar;
  the *policy* — whether to trade in extended hours — stays with the consumer.
  """
  @callback market_status(keyword()) :: result(market_status())

  @doc """
  Rounds a price and quantity to what the venue will actually accept.

  Optional: when a venue does not implement it, a caller skips quantization and falls back
  to per-asset-class defaults.
  """
  @callback quantization(symbol()) :: result(map())

  @optional_callbacks [
    list_instruments: 1,
    quantization: 1
  ]

  @doc """
  Every callback a venue package must implement, as `{name, arity}`.

  The conformance suite drives its completeness assertion off this rather than a
  hand-maintained list, so a callback added here cannot be forgotten there.
  """
  @spec required_callbacks() :: [{atom(), arity()}]
  def required_callbacks do
    __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks)
  end

  @doc """
  The endpoints a package must prove before it can stop being EXPERIMENTAL.

  ## The rule matters more than the list

  The facade will grow, and someone will have to classify an endpoint this list does not
  contain. **An endpoint is core only if both hold:**

    1. **Irreplaceable** — only this venue can answer it. If a consumer can get the same
       answer elsewhere, the package failing is an inconvenience rather than a blocker.
    2. **Load-bearing** — the consumer's primary job *fails* without it rather than
       degrading. If the documented behaviour on absence is "the caller does without", it
       is not core.

  Reclassify by applying the two tests, never by amending a table.

  ## Two properties of the boundary

  **Core is per venue.** An endpoint the venue does not offer is `:unsupported` and drops
  out of that venue's core set; a market-data-only venue is not held to trading it does not
  have.

  **Trading is core exactly when it exists.** If `place_order/3` is active then the order
  group is core, and nothing but live trading proves it.
  """
  @spec core_endpoints() :: [{atom(), arity()}]
  def core_endpoints do
    [
      # Nothing else can tell a consumer whether to use the package at all.
      {:provider_name, 0},
      {:runtime_id, 0},
      {:asset_classes, 0},
      {:capabilities, 0},
      # Nothing works if the package cannot run.
      {:child_spec, 1},
      {:start_link, 1},
      # Only the venue knows what the venue lists, or what it costs.
      {:get_symbols, 1},
      {:get_price, 2},
      # The push half of the same job. `unsubscribe` because failing to stop is a leak,
      # and `coverage` because a stream you cannot verify is a stream you cannot trust.
      {:subscribe, 2},
      {:unsubscribe, 2},
      {:coverage, 1},
      # Only the venue knows your position on it; nothing can be sized without it.
      {:get_balances, 2},
      # Core when trading is active at all — irreplaceable by definition.
      {:place_order, 3},
      {:cancel_order, 3},
      {:get_order, 3},
      {:get_orders, 2},
      # Knowing you are blocked is part of working, and only the venue can say.
      {:test_connection, 2},
      {:get_rate_limit_status, 2}
    ]
  end

  @doc """
  The endpoints outside the core set, each with the test it fails.

  Recorded because it is what a future classifier reasons from, not as a list to append to.
  """
  @spec peripheral_endpoints() :: %{{atom(), arity()} => String.t()}
  def peripheral_endpoints do
    %{
      {:get_historical_prices, 4} =>
        "replaceable — historical prices are routinely sourced from a different provider entirely",
      {:quantization, 1} =>
        "not load-bearing — an unsupporting venue means the caller skips quantization",
      {:get_order_book, 2} =>
        "irreplaceable but not load-bearing — depth is unavailable, trading is not",
      {:list_instruments, 1} =>
        "not load-bearing — a richer get_symbols/1; absence costs detail, not function",
      {:get_market_overview, 1} => "not load-bearing — a bulk convenience over per-symbol calls",
      {:get_fees, 2} => "not load-bearing — affects P&L accuracy, not whether an order executes",
      {:get_trade_history, 2} => "not load-bearing — after-the-fact reconstruction",
      {:get_transfers, 2} => "not load-bearing — not the trading path",
      {:get_accounts, 2} => "not load-bearing — balances are the sizing input",
      {:update_symbols, 2} =>
        "not load-bearing — an optimisation over unsubscribe/2 + subscribe/2, both core",
      {:market_status, 1} =>
        "not load-bearing — a venue that cannot say is treated as open, which is the crypto answer",
      {:preview_order, 3} =>
        "not load-bearing — absence means placing without a dry run, which is how every " <>
          "other venue in the family works",
      {:replace_order, 4} =>
        "not load-bearing, but it is RISK-bearing — absence means cancel-then-place, " <>
          "which works and opens a window in which no order is live",
      {:subscribe_notices, 1} =>
        "not load-bearing — losing notices costs visibility, not the trading path"
    }
  end

  @doc """
  The refusal every unsupported endpoint returns.

  **The atom, never the string.** The source this was extracted from used both — in one
  module, both forms — so a caller matching the atom silently missed the string and treated
  a refusal as an unrecognised error.
  """
  @spec not_supported() :: {:error, :not_supported}
  def not_supported, do: {:error, :not_supported}

  @doc "Every notice kind a venue may emit. See `DpExchange.Core.Notice`."
  @spec notice_kinds() :: [Notice.kind()]
  def notice_kinds, do: Notice.kinds()
end
