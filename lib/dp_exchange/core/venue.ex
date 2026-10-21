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

  ## "Optional" means two different things in this file

  Only four callbacks are in `@optional_callbacks`, and only those four may be left out of
  a venue module entirely: `c:list_instruments/1`, `c:quantization/1`,
  `c:coverage_by_kind/1` and `c:wanted/1`. `required_callbacks/0` is every other callback,
  and the compiler and the conformance suite insist the module defines each one.

  Many other callback docs below begin "Optional". Read that as **a venue may not serve
  this**: it declares the endpoint `:unsupported` in `c:capabilities/0` and its function
  still exists and answers `{:error, :not_supported}`. It does not mean the function may be
  missing.

  ## One reason for each situation

  A consumer that swaps venues behind the facade must get the same answer for the same fact.
  These are the reasons the family agrees on, from the real path and from every Fake. A
  caller matches the tag and never a venue's wording; no venue text and no credential rides
  in a reason (log it if it helps).

  ### Refusals (`{:refused, reason}`, permanent)

    * `{:refused, :not_listed}` — a **well-formed** symbol the venue does not list. Every
      single-symbol read (`c:get_price/2`, `c:get_top_of_book/2`, `c:get_order_book/2`,
      `c:get_historical_prices/4`, `c:get_trades/2`, `c:quantization/1`, instrument reads)
      answers it, real path and Fake alike. It is not `{:error, {:invalid_symbol, v}}` (that
      is a symbol that is not text or is blank) and it is never a retryable
      `{:error, _}`: a 4xx the venue gives for an unknown symbol is a refusal.
    * `{:refused, :no_quote}` — a **listed** symbol with no current quote or book (a venue
      that has not printed yet, or is closed with nothing resting). Not `:not_listed`, and
      not `{:error, _}`.
    * `{:refused, {:account_not_found, id}}` — the credential does not hold the account `id`.
      Retrying with the same credential cannot succeed, so it is a refusal and not an error.
    * An equity-only venue's refusal of a crypto pair keeps its own tag, for example
      `{:refused, {:not_an_equity_symbol, symbol}}`, and is also a refusal: it will never
      succeed on retry.

  ### Errors decided locally (`{:error, reason}`, the caller can fix and retry)

    * `{:error, {:invalid_credentials, venue}}` — a credential value with surrounding
      whitespace or control characters, refused **before signing**. `venue` is the venue's
      `c:runtime_id/0` atom. The value is never echoed, not even partly.
    * `{:error, {:insecure_url, venue}}` — a plaintext URL (`ws://`, `http://`) configured
      for a transport that carries credentials or signed requests. `venue` is the
      `c:runtime_id/0` atom; which option held the URL is the venue's business.
    * `{:error, {:invalid_range, range}}` — a malformed `:start`/`:end` range (not
      `DateTime`s, or `:start` not before `:end`). `range` is the argument as given, never a
      venue-specific shape.
    * `{:error, {:range_unavailable, timeframe, earliest: DateTime.t() | nil, requested:
      DateTime.t()}}` — a well-formed range that starts **before what the venue retains** for
      `timeframe`. `earliest` is the oldest bar the venue serves, or `nil` when the venue
      does not say. It sits beside `{:error, {:range_too_wide, count}}` (too many bars for one
      request) and `{:error, :history_truncated}` (the reply may be incomplete); the three
      are different facts and none stands in for another.

  ### Notices

  A poll route follows the same pairing a stream does. A `:link_down` emitted because a poll
  read did not answer or crashed is **closed by a `:link_up`**, emitted once (latched) on the
  first good poll afterwards, carrying the same `details.symbols` shape the venue's streaming
  `:link_up` uses. A consumer waiting for recovery must not wait forever. See
  `DpExchange.Core.Notice` for the kind rules (what is `:data_quality`, `:refusal`,
  `:degraded`, `:credentials_rejected`) and for `details.reason` (an atom or a tagged tuple)
  versus `details.message` (bounded free text).

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

  `:stream` deliberately does **not** say *socket*. Whether a pushed route is a WebSocket,
  an MQTT session or long-polling is package-internal, and a consumer branching on it would
  be branching on mechanism. What a consumer legitimately needs is whether the data is
  pushed or fetched, because only the second scales with catalogue size.

  ## Where this type came from

  Carried here from `Core.FeedBehaviour`, deleted in 0.3.0 as a contract with no adopters —
  its history is the reason this type exists and is worth more than the module was.

  Orchestration had accreted in a shared collection layer one venue at a time, until that
  layer held Webull's session count, Gemini's ten-pairs-per-socket limit, Coinbase's channel
  ordering, and a `case provider do` for which module speaks which protocol. Every one of
  those is knowledge only the venue has, and the cost was not tidiness — shared code was
  making transport decisions with information it could not have:

    * the poll set had to guess which pairs a subscription covered, because the only honest
      answer lives inside the venue;
    * Webull's documented ceiling of "3 messages per second per connection" was rationed by
      a module that could not see it, so 151 subscribed pairs delivered nothing and it read
      as a quiet market;
    * a venue with **no socket at all** was reported to the user in socket terms, because
      the layer describing it was inferring transport rather than being told.

  That third one is why `:stream` names a push and not a socket, and why `:internal_poll`
  exists as a first-class answer rather than an absence. A venue with no streaming API is
  still a feed: `dp_exchange_robinhood` polls REST internally and emits through the same
  path as a socket venue, so nothing above the facade branches on transport.
  """
  @type route :: :stream | :internal_poll | :not_covered

  @typedoc "Whether the venue is trading right now. Crypto venues answer `:open` always."
  @type market_status :: :open | :closed | :pre | :post

  @typedoc """
  A refusal is not an error.

  `{:refused, reason}` is the venue stating it does not carry this symbol at all — a
  permanent answer. `{:error, reason}` may be transient and is worth retrying. Collapsing
  the two makes a delisted symbol look like a network blip forever.

  **A write that may have reached the venue is neither.** It is
  `{:error, {:order_unconfirmed, id, reason}}` (`t:order_unconfirmed/0`, order writes) or
  `{:error, {:write_unconfirmed, key, reason}}` (`t:write_unconfirmed/0`, every other
  state-changing write). A bare `{:error, _}` invites a retry that doubles the write, and a
  `{:refused, _}` claims it never happened.
  """
  @type result(value) :: {:ok, value} | {:error, term()} | {:refused, term()}

  @typedoc """
  The refusals the family agrees on for a malformed argument, decided locally: before
  credentials are read and before anything is sent. The `value` is the argument as given.

    * `{:invalid_symbols, value}` — a symbol **list** that is not a proper list of non-blank
      strings (`c:subscribe/2`, `c:unsubscribe/2`, `c:update_symbols/2`).
    * `{:invalid_subscriber, value}` — a `:to` option that is not a pid or a non-boolean
      atom (`c:subscribe/2`, `c:subscribe_notices/1`).
    * `{:invalid_symbol, value}` — a single symbol that is `nil`, not a string, or blank
      after trimming (every single-symbol read, and an order request's `:symbol`).
    * `{:invalid_order_id, value}` — an order id that is `nil`, not a string, or blank after
      trimming (`c:get_order/3`, `c:cancel_order/3`, `c:replace_order/4`).
    * `{:invalid_argument, name}` — a positional argument that must be a list and is not a
      proper one, named by the argument: `{:invalid_argument, :requests}` for
      `c:place_orders/3`. (Symbol lists keep their own tag, `{:invalid_symbols, value}`; this
      is the tag for a list argument that has none.) The value is not echoed: a batch of
      requests can hold anything.

  A caller matches these tags and never a venue's own wording. They are `{:error, _}` and not
  `{:refused, _}`: the caller can fix the argument and retry.
  """
  @type invalid_argument ::
          {:invalid_symbols, term()}
          | {:invalid_subscriber, term()}
          | {:invalid_symbol, term()}
          | {:invalid_order_id, term()}
          | {:invalid_argument, atom()}

  @typedoc """
  The refusals `c:place_order/3` and `c:replace_order/4` give for a request decided wrong
  **before anything is sent**, in the order they are checked: request is a map
  (`:invalid_order_request`), no key the builder does not read (`:unsupported_order_field`),
  the symbol, the side, `:order_type` (`{:missing_field, :order_type}`), the time in force
  and the combination, the quantity, the price fields, `client_order_id`, the account
  option (`{:missing_option, key}`), and only then credentials.

  A field the order type does not use is `{:unexpected_field, key}` — never silently dropped.
  See `c:place_order/3`.
  """
  @type order_request_error ::
          {:invalid_order_request, term()}
          | {:unsupported_order_field, term()}
          | {:invalid_symbol, term()}
          | {:invalid_side, term()}
          | {:missing_field, atom()}
          | {:unexpected_field, atom()}
          | {:unsupported_order_type, term()}
          | {:unsupported_order_combination, term(), term()}
          | {:invalid_quantity, term()}
          | {:invalid_price, term()}
          | {:invalid_stop_price, term()}
          | {:invalid_client_order_id, term()}
          | {:missing_option, atom()}

  @typedoc """
  A write that **may have reached the venue** and whose success is not proven:
  `{:order_unconfirmed, client_order_id_or_nil, reason}`. Never a bare `{:error, _}`, and never
  `{:refused, _}`, for these outcomes. See `c:place_order/3`.

  The id is the `client_order_id` actually sent, so the caller can look the order up:

    * a `String.t()` for a single order;
    * a **list of ids** for a venue's batch placement (Webull's batch endpoint), where one
      request carries several client order ids and any of them may have been placed. The list
      holds every id actually sent, in request order, so the caller reconciles each;
    * `nil` when the venue has no client order id and none was generated.

  A caller matches on the shape: a binary is one order to look up, a list is several, and
  `nil` means there is nothing to look up by and the caller reconciles from `get_orders/2`.
  """
  @type order_unconfirmed :: {:order_unconfirmed, String.t() | [String.t()] | nil, term()}

  @typedoc """
  A **non-order write** that may have reached the venue and whose success is not proven:
  `{:error, {:write_unconfirmed, key_or_nil, reason}}`. The non-order twin of
  `t:order_unconfirmed/0`, for `withdraw/5`, `transfer_internal/4`, `convert/4`,
  `commit_conversion/2`, `stake/3`, `unstake/3`, approved-address changes,
  `add_payment_method/2`, watchlist and account writes, and `cancel_all_orders/2`.

  ## W1. What is unconfirmed

  A transport error or timeout after the request was sent, a 5xx, or a 2xx the venue accepted
  whose body cannot be read (undecodable, not an object, missing the id the result needs).
  `key` is the idempotency or correlation key **actually sent**, a generated one included, so
  the caller can retry safely with it or reconcile; `nil` when the venue has none. `reason`
  is bounded. It is never a bare `{:error, _}` (a caller retries those, and a retried
  withdrawal pays twice) and never `{:refused, _}`. A failure decided before sending
  (validation, credentials, our own rate limiter refusing, a signing failure) stays plain.

  ## W2. Retries

  A write is retried internally **only** when it carries an idempotency key the venue honours;
  otherwise it is sent once (`retry_attempts: 1`). A 4xx answered to an internal *retry* of a
  keyed write (a duplicate client transfer id) is `:write_unconfirmed`, not a refusal: the
  first attempt may have succeeded. `cancel_all_orders/2` is always sent once.

  ## W3. A confirming body that lacks optional fields

  `{:ok, struct}` with those fields `nil`. Only a body that cannot establish that the write
  happened is `:write_unconfirmed`.

  ## W4. Amounts and destinations

  A money amount is a `Decimal`, an integer or a numeric string. A float is
  `{:error, {:invalid_amount, value}}`; so are zero, a negative, NaN, infinity and an
  exponent beyond the bound the package states. Asset, currency and destination are validated
  before sending. A transfer whose source equals its destination is
  `{:error, {:invalid_transfer, :same_account}}`.

  ## W5. Return types

  A callback whose spec names a `Types.*` struct returns that struct, from the real path and
  from the Fake (`stake/3` and `unstake/3` return `Types.StakingTransaction`).

  ## W6. Fakes

  A Fake refuses exactly what the real path refuses, in the same order, through the same
  validators; issues a unique generated id per write; echoes only fields the real path
  returns; and answers an unknown id as the real path does (`{:refused, :not_found}`).

  ## W7. Reads

  An unreadable row refuses the whole reply: it is never silently dropped. A reply that may be
  truncated (a documented maximum reached with pages unwalked) is
  `{:error, :history_truncated}` or is walked to completion, never returned as complete. An
  option the read cannot honour (a portfolio scope, say) is honoured or refused, never
  ignored.

  ## What the conformance suite asserts of W1 to W7

  Four groups hold the parts checkable against a Fake. **Group 47 holds W4's amounts**: a
  float, zero, a negative, NaN and infinity as the amount of `stake/3`, `unstake/3`,
  `convert/4`, `withdraw/5` and `transfer_internal/4` (each when active) is
  `{:error, {:invalid_amount, value}}`, the value as given. **Group 48 holds W5's staking
  return**: `stake/3` and `unstake/3` answer a valid call with `Types.StakingTransaction`
  (group 5 holds the rest of W5, for every callback whose spec names a struct). **Group 49
  holds W6's unknown id**: `get_order/3` and `cancel_order/3` answer an id nobody placed
  `{:refused, :not_found}`. Group 43 also holds, for every endpoint including each write,
  that a key the call does not read is refused before anything is sent. **Group 52 holds the
  sizing and price of `c:place_order/3`** (the numbers W4 states for the other writes): a
  float, zero, a negative, NaN and infinity as `:quantity` or `:price` is
  `{:error, {:invalid_quantity, value}}` or `{:error, {:invalid_price, value}}`, the value as
  given.

  **Still not asserted, and why.** W1 (a possibly-sent write is `:write_unconfirmed`) and W2
  (retries) need a fault injected after the request is sent, which a Fake cannot produce;
  the opt-in `ambiguous_place_order:` seam (group 42) is the one place the suite does that,
  for `place_order/3` only. W3 and W7 are properties of the real path's decoding of a venue's
  body (a body missing optional fields, an unreadable row, a truncated reply), and the suite
  has no venue body to decode. W4's same-account transfer, asset and destination checks and
  the exponent bound need venue facts (which accounts and destinations exist, what bound the
  package states) the suite does not have; W6's "unique generated id per write" and "echoes
  only fields the real path returns" need a second write and the real path to compare with.
  Those parts are held by each venue's own tests.
  """
  @type write_unconfirmed :: {:write_unconfirmed, String.t() | nil, term()}

  @typedoc """
  `result/1` for the two order writes, `c:place_order/3` and `c:replace_order/4`: the same
  three answers, with the `{:error, _}` shapes this contract names written down.
  """
  @type order_write_result(value) ::
          {:ok, value}
          | {:error, order_request_error() | invalid_argument() | order_unconfirmed() | term()}
          | {:refused, term()}

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

  @doc """
  Which asset classes this venue trades — a subset of `[:crypto, :equity, :option, :future,
  :event_contract]`.

  **A statement about the package today, never a permanent scope boundary.** It widens as
  endpoints land, and a class a venue serves but does not declare is a class the host
  cannot route to.
  """
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

  @doc """
  The current price for `symbol`.

  ## A symbol that is not text is refused locally

  A `symbol` that is `nil`, not a string, or blank after `String.trim/1` answers
  `{:error, {:invalid_symbol, symbol}}`, decided **before credentials are read and before any
  request is built**. It never raises, and it never becomes a request with an empty path
  segment or parameter, which the venue would read as a different endpoint. The same holds
  for every single-symbol read: `get_top_of_book/2`, `get_order_book/2`,
  `get_historical_prices/4`, `get_trades/2`, `quantization/1` and the elements of a batch
  price call. A venue's refusal of a *well-formed* string it cannot serve (`{:refused,
  :not_listed}`, or an equity-only venue's `{:not_an_equity_symbol, symbol}`) is a different
  answer and stays.

  Conformance assertion 33 holds a venue's Fake to this for `get_price/2` and
  `get_top_of_book/2`.

  ## What the quote's price and times mean (MD6, MD7, MD8)

  `Quote.price` is a **traded** price. A traded price that is `0` or negative refuses the
  reply; it is never passed through. `Quote.venue_time` is the venue's stated time **of the
  last trade**, and `nil` when the venue states none. It is never an HTTP `Date` header, the
  time a message was sent or assembled, or the time of another event (a quote's time is not
  a trade's). `observed_at` is the package's own read time.

  `Quote.volume_window` is `:print` **only when every print is delivered**. A conflated
  stream (one that merges several trades into one update) reports the venue's cumulative
  volume as `:running_total`, exactly as its REST quote does. It never reports the last
  trade's size as `:print`, because summing those drops every trade the conflation skipped.
  """
  @callback get_price(symbol(), keyword()) :: result(Types.Quote.t())

  @doc """
  Historical candles for `symbol` at `timeframe`.

  The venue rejects a timeframe it does not serve rather than substituting the nearest
  one. A missing granularity silently becoming the closest one mislabels every candle it
  touches, and every value stays plausible.

  **Oldest first, ordered by each candle's own `opened_at`**, never by the order the venue's
  rows arrived in. Venues disagree on the order they send, and several do not document it at
  all. A series read in the wrong order still yields plausible returns and indicators, just
  wrong ones. A venue that has only one candle, or none, satisfies this trivially: conformance
  assertion 37 holds a Fake to this (strictly oldest first, on the width's grid) only when it
  answers with two or more candles.

  ## The still-forming bar is not returned (MD1)

  A bar is **in progress** when `opened_at + width > now`, where `now` is the venue's clock
  if it states one and `DateTime.utc_now/0` otherwise. An in-progress bar is **not returned**
  unless the caller passes `include_partial: true` (default `false`). A bar that is still
  forming has a close that is only the latest price and a volume that is still growing;
  stored as a finished bar it is a plausible, wrong value that is never corrected.

  `Types.Candle` has no flag marking a partial bar, so with `include_partial: true` the last
  bar is returned as-is and **may still change** on the next call. It is the only bar that
  can be partial, and it is always the last. (Webull's former `real_time:` option is now
  `include_partial:`.)

  ## The range (MD2)

  `opts[:start]` is **inclusive** and `opts[:end]` is **exclusive**, both on `opened_at`: a
  bar whose `opened_at` equals `:end` is not returned and one equal to `:start` is. An absent
  `:end` means *now*, and is never a venue default that ends earlier (a venue whose
  parameter defaults to some past date is sent `now` explicitly). A range the venue cannot
  return in one response is **walked to completion** or refused
  `{:error, {:range_too_wide, detail}}`; it is never returned short, because a series that
  silently stops early still looks like a series. A walk that stops at a bound the package
  keeps is `{:error, :history_truncated}`.

  ## `opened_at` is the bucket start (MD3)

  `opened_at` is the **start** of the bucket, aligned to the timeframe's width
  (`DpExchange.Core.Timeframe.aligned?/2`). A venue whose bar time is not provably the open
  time checks alignment when it decodes: a bar not aligned to its width refuses the whole
  reply, `{:error, {:unaligned_candle, time}}` (`time` is the venue's value as given). It does
  not round, shift or guess; a close-stamped series misread as open-stamped is off by one
  whole interval and every value in it still looks right. Which venues stamp their bars at
  the open is recorded as **unmeasured** in that venue's documentation until it has been
  checked against the live endpoint.

  The grid depends on the instrument. Crypto is strict on the UTC grid at every width. For a
  session-traded instrument (equities, options, futures, events) widths of 30 minutes and
  under stay strict, and a wider intraday width is session-anchored: it only needs 30-minute
  alignment, because US equity sessions open at 09:30 ET.

  Equity **daily and weekly** bars are stamped by the venue at exchange-local midnight (or
  another exchange-local instant). They are mapped to `00:00:00` UTC **of the same session
  date**: the session *date* is the fact the venue states, and the instant is an artefact of
  the zone it was written in. Converting the instant to UTC would move a New York bar onto the
  previous or next calendar day depending on the season.

  ## Limits and options a venue cannot honour (MD4, MD11)

  `opts[:limit]` is sent to the venue where it has such a parameter. Above the venue's
  documented maximum it is `{:error, {:invalid_option, :limit, value}}`; where the venue has
  no such parameter it is `{:error, {:unsupported_option, :limit}}`. It is never accepted and
  then ignored, and never applied to a page already fetched. The maximum a package declares in
  `c:capabilities/0` (`max_candles_per_request`) is labelled as **documented** when it comes
  from the vendor's page and **measured** only when it was probed.
  """
  @callback get_historical_prices(symbol(), String.t(), keyword(), keyword()) ::
              result([Types.Candle.t()])

  @doc "Every symbol the venue lists."
  @callback get_symbols(keyword()) :: result([symbol()])

  @doc """
  Best bid and ask for `symbol` — the top of the book, **not a traded price**.

  Returns `Types.TopOfBook`, which has no `price` field. A caller wanting what the
  instrument last traded at calls `get_price/2`; a caller wanting what it can currently
  trade at calls this. The two must never stand in for one another — see
  `Types.TopOfBook`'s moduledoc for the defect that rule was written from.

  Most venues publish a dedicated BBO endpoint that is cheaper than a full book, which is
  why this is not `get_order_book/2` with a depth of one. Several publish no timestamp with
  it and several publish no sizes; the type makes both optional rather than inventing them.

  A `nil`, non-string or blank `symbol` is `{:error, {:invalid_symbol, symbol}}`, before
  credentials: see `c:get_price/2`.

  ## Prices, sides and times (MD6, MD7)

  A bid or ask price of **`0` means no resting order on that side**: that side's price and
  size are `nil`, not `0`. A price that is **present but unreadable** (not a number, negative,
  NaN) refuses the reply; it is never turned into `nil`, which would claim an empty side.

  `TopOfBook.venue_time` is the venue's stated time **of that quote**, and `nil` when the
  venue states none. It is never an HTTP `Date` header, the time a message was assembled or
  sent, or a different event's time such as the last trade's. Callers needing a time read
  `observed_at`.
  """
  @callback get_top_of_book(symbol(), keyword()) :: result(Types.TopOfBook.t())

  @doc """
  Staking rates on offer, per asset and provider.

  **This is custodial staking** — the venue holds the asset and pays a rate. It is not
  on-chain staking: an endpoint that returns an *unsigned transaction* for a caller to sign
  and broadcast is a different capability and must never be reached through these callbacks.
  A caller believing it had staked when it holds an unsigned transaction nobody signed is
  the most expensive form of this family's recurring failure.
  """
  @callback get_staking_rates(keyword()) :: result([Types.StakingRate.t()])

  @doc "Staked positions, one per asset, with their liquidity states kept apart."
  @callback get_staking_balances(keyword()) :: result([Types.StakingBalance.t()])

  @doc "Rewards accrued over a period. The period is part of the value, not a filter."
  @callback get_staking_rewards(keyword()) :: result([Types.StakingReward.t()])

  @doc "Movements in and out of staked positions, redemptions included with their progress."
  @callback get_staking_history(keyword()) :: result([Types.StakingTransaction.t()])

  @doc """
  Stakes `amount` of `asset`.

  Returns the resulting transaction. **This moves funds**: a consumer calling it has decided
  to, and D2 puts that decision with the host rather than with this package.

  Returns a `Types.StakingTransaction` from the real path and the Fake (W5). An amount that
  is a float, zero, negative or NaN/infinite is `{:error, {:invalid_amount, value}}` before
  sending (W4); an outcome that may have reached the venue is `t:write_unconfirmed/0` (W1).
  """
  @callback stake(String.t(), Decimal.t(), keyword()) :: result(Types.StakingTransaction.t())

  @doc """
  Redeems `amount` of a staked `asset`.

  **Returns immediately; the redemption does not complete immediately.** The returned
  transaction carries `:amount_remaining`, which is non-zero for as long as the asset is
  unbonding. A caller that treats the return value as settled will spend an asset it does
  not have yet — see `Types.StakingTransaction`.

  The write rules of `stake/3` apply: the struct return (W5), `{:invalid_amount, value}` (W4)
  and `t:write_unconfirmed/0` (W1).
  """
  @callback unstake(String.t(), Decimal.t(), keyword()) :: result(Types.StakingTransaction.t())

  @doc """
  Open positions — exposure, not holdings.

  Distinct from `get_balances/1`: a balance says what the account holds, a position says
  what exposure it has taken and how far it is from liquidation. A spot-only venue declares
  this `:unsupported`; that is not the same as having none.
  """
  @callback get_positions(keyword()) :: result([Types.Position.t()])

  @doc """
  Funding for a perpetual — settled, projected, and when the next one lands.

  Returns `Types.Funding`, which keeps the settled amount and the venue's estimate apart. A
  venue that does not trade perpetuals declares this `:unsupported`.
  """
  @callback get_funding(symbol(), keyword()) :: result(Types.Funding.t())

  @doc """
  Risk statistics for a derivative — mark, index and open interest.

  Returns `Types.ContractStats`. Mark and index are separate prices with separate meanings,
  and neither is what the instrument last traded at.
  """
  @callback get_contract_stats(symbol(), keyword()) :: result(Types.ContractStats.t())

  @doc """
  Quotes a conversion of `amount` from one asset to another. **Nothing moves.**

  Returns a `Types.Conversion` with `status: :quoted` and, where the venue states one, an
  `:expires_at`. The rate is held only until then. Committing is a separate call —
  `commit_conversion/2` — and a caller that never commits has done nothing but ask.
  """
  @callback quote_conversion(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Types.Conversion.t())

  @doc """
  Commits a previously quoted conversion. **This moves funds.**

  A quote past its window may be refused, or filled at the current rate rather than the
  quoted one — which is the outcome to guard against, because it looks like success. D2 puts
  the decision to call this with the host.

  A commit whose request may have reached the venue and whose result is unproven is
  `{:error, {:write_unconfirmed, key_or_nil, reason}}`, with the quote id or idempotency key
  sent as `key` (W1). A caller reconciles with `get_conversion/2`; it does not commit again.
  """
  @callback commit_conversion(String.t(), keyword()) :: result(Types.Conversion.t())

  @doc "A conversion's current state, quoted or committed."
  @callback get_conversion(String.t(), keyword()) :: result(Types.Conversion.t())

  @doc """
  Converts `amount` of `from` into `to` in **one call**, with no quote to accept first.

  Optional, and deliberately separate from `quote_conversion/4` plus `commit_conversion/2`
  rather than a shorthand for them.

  **The difference is who carries the price risk, and it is not a detail.** The two-step
  form shows a rate and holds it: the caller sees the number before anything moves, and a
  stale quote is refused. This form executes at whatever the venue's price is when it
  arrives, and the caller learns the rate from the result. A venue offering only one of the
  two cannot be made to offer the other by a package wrapping it — quoting a rate this
  package computed and calling it held would be a promise the venue never made.

  So a venue declares each independently, and a caller that must see a price first uses
  `quote_conversion/4` or does without.

  Returns a `Conversion` already `:settled` — it has happened.

  Amount rules are W4 (`{:invalid_amount, value}`; a float is refused). An outcome that may
  have reached the venue is `{:error, {:write_unconfirmed, key_or_nil, reason}}` (W1), with
  the idempotency key actually sent. It is retried internally only under a key the venue
  honours (W2).
  """
  @callback convert(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Types.Conversion.t())

  @doc """
  The portfolios this credential can address.

  A portfolio is **where** you ask, not what you get back: balances, orders and positions
  are addressed to one with `portfolio: id` in `opts`. A venue with a single implicit
  context declares this `:unsupported` and ignores the option.

  **Where the option is omitted on a venue that has portfolios, the package uses the venue's
  default and does not invent one.** A caller needing determinism passes the id.
  """
  @callback list_portfolios(keyword()) :: result([Types.Portfolio.t()])

  @doc """
  A deposit address for `asset` on `network`.

  **The network is required and not defaulted.** The same asset exists on several chains and
  the addresses are not interchangeable; a package choosing a default network would be
  choosing where a caller's funds go.

  Read `Types.DepositAddress`'s `:memo_required` before sending. `nil` there means the venue
  did not say, which is not the same as `false`.
  """
  @callback get_deposit_address(String.t(), String.t(), keyword()) ::
              result(Types.DepositAddress.t())

  @doc """
  The blockchain networks an asset can move over, or the assets a network carries.

  Optional. **This is what `get_deposit_address/3` needs before it can be called**: that
  callback takes a network, and nothing else in the contract says which networks a venue
  will accept for a given asset. Guessing one produces an address on a chain the venue does
  not credit, and **funds sent to it are gone** — the single most expensive mistake in this
  family's surface.

  Two directions, because venues publish both and they answer different questions:

    * `list_networks("USDC", [])` — which networks carry this asset
    * `list_networks(nil, network: "ethereum")` — which assets this network carries

  Rows are the venue's own maps. Network naming is not standardised across venues — one
  venue's `ethereum` is another's `ERC20` — and normalising here would invent a vocabulary
  that no venue accepts back.
  """
  @callback list_networks(String.t() | nil, keyword()) :: result([map()])

  @doc """
  Symbols currently carrying a promotional fee.

  Optional, and **not `get_fees/2`**: that returns the schedule applying to a credential,
  and this is a public list of symbols where the venue is charging something other than its
  published schedule. A caller computing cost from the schedule alone is wrong for exactly
  the symbols on this list.
  """
  @callback list_fee_promos(keyword()) :: result([map()])

  @doc "Addresses on the withdrawal allow-list, with whether each is usable yet."
  @callback list_approved_addresses(keyword()) :: result([Types.ApprovedAddress.t()])

  @doc """
  Estimates the fee to withdraw `amount` of `asset` over `network`.

  Separate from `withdraw/5` because the venues expose it separately, and because the
  estimate can differ from the charge. Do not record an estimate as a fee.
  """
  @callback estimate_withdrawal_fee(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Decimal.t())

  @doc """
  Withdraws `amount` of `asset` over `network` to `address`.

  **This is the only operation in this contract that cannot be undone.** D2 places the
  decision to call it with the host, not with this package.

  Two failure modes are worth naming because neither is a package bug:

    * the address is not on the venue's allow-list, or is on it and **not yet active** —
      see `Types.ApprovedAddress`
    * the asset requires a memo and none was given, in which case the funds leave and are
      not credited to anyone

  A memo is passed as `memo:` in `opts`. A package must not synthesise one.

  ## Because it cannot be undone

  `amount` is a `Decimal`, an integer or a numeric string; a float, zero, a negative, NaN or
  infinity is `{:error, {:invalid_amount, value}}`, and asset, network and address are
  validated, all before anything is sent (W4). An outcome that may have reached the venue (a
  timeout after sending, a 5xx, a 2xx whose body does not carry the withdrawal id) is
  `{:error, {:write_unconfirmed, key_or_nil, reason}}`, where `key` is the client transfer id
  actually sent (W1). A withdrawal is retried internally only under such a key, and a 4xx to
  that retry is also unconfirmed (W2), because the first attempt may have left.
  """
  @callback withdraw(String.t(), String.t(), Decimal.t(), String.t(), keyword()) ::
              result(Types.Withdrawal.t())

  @doc """
  The funding sources this account can move fiat through.

  Optional. Rows are the venue's own maps: a bank account, a card and a balance are
  different things with different fields, and flattening them into one struct would drop
  whichever the caller needed.

  **A payment method being listed does not mean it is usable.** Venues hold new bank
  accounts pending verification, and the status lives in the row. A caller that filters on
  presence rather than status will pick one the venue will refuse.
  """
  @callback list_payment_methods(credentials(), keyword()) :: result([map()])

  @doc """
  Registers a funding source — typically a bank account.

  Optional, and **this is a write that a person usually has to complete**: venues verify a
  new bank account out of band, by micro-deposit or an open-banking flow, and the API call
  only starts that. A caller treating a successful response as a usable method will find
  the first transfer refused.

  `details` is the venue's own shape. Bank details differ by country — a US routing number,
  a Canadian transit and institution number, an IBAN — and a normalised struct would be
  wrong for every country but one.
  """
  @callback add_payment_method(map(), keyword()) :: result(map())

  @doc """
  One funding source by the venue's own identifier.

  Optional. Returns the venue's map, the same shape `list_payment_methods/2` returns rows
  in — not a normalised struct, for the reason given there.

  **This is the call that answers whether a method is still usable**, and the list is not.
  A method's verification state changes without the account doing anything: a bank can be
  closed, a card can expire, a venue can suspend a rail. A caller holding an identifier
  from an earlier listing and moving fiat against it without re-reading is acting on a
  status that may have been true an hour ago.

  A venue that has no such identifier — or no per-method read — returns
  `{:error, :not_supported}`. Selecting the matching row out of `list_payment_methods/2`
  is not this function: the list is a snapshot and this is a read.
  """
  @callback get_payment_method(credentials(), String.t(), keyword()) :: result(map())

  @doc """
  Every balance the account holds, each **also** valued in one notional currency.

  Optional, and **it is not `get_balances/2` in another unit**. The quantity of the asset
  is the venue's ledger; the notional figure beside it is the venue's *valuation* of that
  quantity at a rate the venue chose and does not have to publish. Two venues will disagree
  about the notional value of the same holding and both be right about the balance.

  Rows are the venue's own maps for that reason: flattening a quantity and a valuation into
  one struct invites a caller to read one as the other, and the notional figure is the one
  that is only ever an estimate.

  Callers reconciling a position use `get_balances/2`. This is for reporting.
  """
  @callback get_notional_balances(credentials(), String.t(), keyword()) :: result([map()])

  @doc """
  The fees a venue charged for *holding* assets, as opposed to trading them.

  Optional. Custody fees are periodic and are taken out of the balance directly, so they
  appear as a reduction with no trade behind it. A consumer reconciling balances against
  fills alone will find a gap it cannot explain, and this is what explains it.

  Rows are the venue's own maps. **An empty list means the venue charged nothing in the
  window asked for — it never means the venue does not charge.** A venue with no custody
  product at all returns `{:error, :not_supported}`, which is the answer that distinguishes
  the two.
  """
  @callback list_custody_fees(credentials(), keyword()) :: result([map()])

  @doc """
  Moves `amount` of `asset` between two accounts **held at the same venue**.

  Optional. **Not `withdraw/5`**: nothing leaves the venue, no chain is involved, and no
  address is required. Conflating the two is dangerous in both directions — a caller that
  reaches for `withdraw/5` for an internal move pays a network fee it did not need to, and
  one that reaches for this expecting an external transfer sends nothing anywhere.

  Which accounts a venue exposes and how they are named is the venue's own; `opts` carries
  its source and destination identifiers.

  A transfer whose source equals its destination is `{:error, {:invalid_transfer,
  :same_account}}`; amounts follow W4; an outcome that may have reached the venue is
  `{:error, {:write_unconfirmed, key_or_nil, reason}}` (W1), sent once unless it carries an
  idempotency key the venue honours (W2).
  """
  @callback transfer_internal(String.t(), Decimal.t(), keyword(), keyword()) :: result(map())

  @doc """
  Asks the venue to add `address` to the withdrawal allowlist for `network`.

  Optional, and **the most consequential write in this contract**: an address on the
  allowlist is one funds can be sent to. Venues therefore hold new entries under a time
  lock, and this call *requests* rather than grants — see
  `Types.ApprovedAddress.usable?/2`, which answers `nil` for an address whose lock has no
  stated end.

  A caller must not treat a successful response as permission to withdraw. The allowlist is
  read back with `list_approved_addresses/1`.
  """
  @callback request_approved_address(String.t(), String.t(), String.t() | nil, keyword()) ::
              result(map())

  @doc """
  Removes `address` from the withdrawal allowlist for `network`.

  Optional. Removal is generally immediate where addition is not, which is the asymmetry a
  caller should expect: the venue is slow to widen what funds may reach and quick to narrow
  it.
  """
  @callback remove_approved_address(String.t(), String.t(), keyword()) :: result(map())

  @doc """
  The account's transaction history — everything that moved, not only trades.

  Optional. **Wider than `get_trade_history/2` and wider than `get_transfers/2`**: it
  includes fees, interest, dividends, adjustments and credits alongside deposits and fills.
  Rows are the venue's own maps, because the kinds do not share a shape and a struct would
  be mostly `nil` for every one of them.

  **Summing this is not a balance.** A caller reconciling should use `get_balances/2` as the
  authority and this as the explanation.
  """
  @callback get_transactions(credentials(), keyword()) :: result([map()])

  @doc """
  The option chain for an underlying — expiry × strike, both sides.

  Returns `Types.OptionChain`. Two-dimensional deliberately: a flat list of contracts is
  lossless in data and answers none of the questions a chain is asked.
  """
  @callback get_option_chain(String.t(), keyword()) :: result(Types.OptionChain.t())

  @doc """
  The expiries listed on an underlying, without the strikes.

  Venues expose this separately because a full chain is large and a caller choosing an
  expiry does not need every strike to do it.
  """
  @callback get_option_expirations(String.t(), keyword()) :: result([Date.t()])

  @doc """
  Greeks and implied volatility for one contract.

  Returns `Types.OptionGreeks`. **Model output, not market data** — two venues quoting the
  same contract publish different numbers and neither is wrong.
  """
  @callback get_option_greeks(String.t(), keyword()) :: result(Types.OptionGreeks.t())

  @doc "Watchlists held at the venue. The venue's list, which may differ from the host's."
  @callback list_watchlists(keyword()) :: result([Types.Watchlist.t()])

  @doc "One watchlist including its membership."
  @callback get_watchlist(String.t(), keyword()) :: result(Types.Watchlist.t())

  @doc "Creates a watchlist at the venue."
  @callback create_watchlist(String.t(), [String.t()], keyword()) :: result(Types.Watchlist.t())

  @doc "Replaces a watchlist's name or membership."
  @callback update_watchlist(String.t(), keyword()) :: result(Types.Watchlist.t())

  @doc "Deletes a watchlist at the venue."
  @callback delete_watchlist(String.t(), keyword()) :: result(:ok)

  @doc """
  Financial statements for an issuer.

  `kind` selects balance sheet, income, cash flow or the venue's indicator set. Line items
  come back under the venue's own names — see `Types.FinancialStatement` for why they are
  not normalised into a fixed schema.
  """
  @callback get_financials(String.t(), atom(), keyword()) ::
              result([Types.FinancialStatement.t()])

  @doc "Dividends, earnings dates and splits. Each date is carried under its own name."
  @callback get_corporate_events(keyword()) :: result([Types.CorporateEvent.t()])

  @doc "Regulatory filings the venue indexes. This interface points at them; it never fetches one."
  @callback get_filings(String.t(), keyword()) :: result([Types.Filing.t()])

  @doc "News the venue publishes or relays, with its own tagging."
  @callback get_news(keyword()) :: result([Types.NewsItem.t()])

  @doc """
  A venue screener, mover list or ranking, by the venue's own identifier for it.

  Rows carry the venue's ranking and metrics. Two venues' lists under one name answer
  different questions; this interface does not merge or re-rank them.
  """
  @callback get_screener(String.t(), keyword()) :: result([Types.ScreenerResult.t()])

  @doc "Creates an account or sub-account at the venue."
  @callback create_account(keyword()) :: result(map())

  @doc "Renames an existing account at the venue."
  @callback rename_account(String.t(), String.t(), keyword()) :: result(map())

  @doc "The roles this credential holds, as the venue defines them."
  @callback get_roles(keyword()) :: result(map())

  @doc """
  The order book for `symbol`, best price first on both sides.

  ## `opts[:depth]` (MD5)

  The depth option is `:depth`, **levels per side**, on every venue. A venue whose own
  parameter has another name (Coinbase's `limit`) maps `:depth` onto it; its old `:limit`
  option is `{:error, {:unsupported_option, :limit}}`. A `:depth` above the venue's maximum
  is `{:error, {:invalid_option, :depth, value}}`.

  ## Levels that are unreadable, empty or invalid (MD5, MD6)

    * A level that cannot be read refuses the **whole book**, on REST and on a stream. It is
      never skipped, because a book with a level missing is a different book.
    * In a **snapshot**, a level with size `0` is dropped: it is no liquidity. (A *delta*
      still carries size `0`, which means remove that price; see `Types.OrderBookDelta`.)
    * A **negative** size, or a price `<= 0`, refuses the book. So a returned book has only
      levels with a price and a size above zero (conformance assertion 39).
    * A side that is present but is not a list refuses the book.

  `OrderBook.venue_time` is the venue's stated time of the book and `nil` when it states
  none, never a `Date` header or a send time (MD7).

  ## Stream gaps (MD9)

  A snapshot-then-delta stream that detects a gap in the venue's sequence resubscribes the
  affected symbols for a fresh snapshot, and emits a notice once. A frame whose sequence is
  less than or equal to the last one applied is dropped, never applied.
  """
  @callback get_order_book(symbol(), keyword()) :: result(Types.OrderBook.t())

  @doc """
  Recent public trades for `symbol` — the tape.

  Optional. **This is not `get_trade_history/2`**, which returns the credential's *own*
  fills. The tape is everyone's executions and has no order of yours behind it; a package
  answering one with the other would hand a caller a filtered view of the market and call
  it the market.

  **Broken trades are excluded unless `opts[:include_broken]` says otherwise.** An exchange
  that busts an erroneous print has said it did not stand, and leaving it in a series puts a
  phantom high or low into every range and volatility figure built on it — none of which
  will error. Venues with no concept of busts have nothing to exclude.

  `opts[:since]` and `opts[:limit]` narrow the window where a venue supports them, and go
  to the venue rather than being applied to the page it returned (MD4). Where the venue has
  no such parameter the option is `{:error, {:unsupported_option, key}}`, and above its
  documented maximum `:limit` is `{:error, {:invalid_option, :limit, value}}`: an option is
  honoured or refused, never ignored. A `:since` read that returns exactly `limit` rows may
  have a hole between `since` and the first row returned, and is
  `{:error, :history_truncated}` rather than a short answer.

  A trade's `:price` that is `<= 0` refuses that reply (MD6). `Trade.side` is the **taker's**
  side (MD10). Where the venue does not document what its side code means (Webull's `B` and
  `S`), `side` is `nil` if the type allows it; where a package keeps a mapping it records it
  as **unmeasured** in its docs and CHANGELOG.

  **Oldest first, by each trade's own `:timestamp`**, as `get_historical_prices` is, and
  for the same reason. Venues send the tape newest first, oldest first, or without saying,
  and `List.last/1` meaning "the latest print" on one venue and "the oldest" on another is
  a wrong answer that raises nothing. Trades with the same timestamp keep the venue's order.
  """
  @callback get_trades(symbol(), keyword()) :: result([Types.Trade.t()])

  @doc """
  A foreign-exchange reference rate for `pair` at `at`.

  Optional. **Not a rate the venue trades at** — a venue publishing this is relaying a
  third party's number for historical reference, which is why `Types.FxRate` carries the
  source and the benchmark alongside the rate.

  `at` is the instant the rate is for, not a window: the venue answers for that moment. A
  venue that serves only recent history says so by refusing, rather than returning its
  nearest available rate under the requested timestamp.
  """
  @callback get_fx_rate(String.t(), DateTime.t(), keyword()) :: result(Types.FxRate.t())

  @doc """
  The order imbalance published ahead of an opening or closing auction.

  Optional. `opts[:auction]` is `:opening` or `:closing` and is **required** — the two are
  different auctions with different windows, and a venue asked for neither has nothing to
  answer.

  **Returns a list**, newest first, because the venue publishes a series and not only a
  latest value: the imbalance updates every few seconds through the auction window and how
  it moved is the point. `opts[:history]` selects the published series where a venue serves
  the snapshot and the series separately — the same shape `get_orders/2` uses for resting
  versus closed orders.

  **A series entry may carry less than a snapshot.** Webull's NOII bars publish the three
  auction prices and the time and *not* the paired quantity, the imbalance quantity or the
  side; those come back `nil`, which means the venue did not publish them on that endpoint
  rather than that the imbalance was zero.

  **Not derivable from `get_order_book/2`.** During an auction the continuous book stops
  being the price: what matters is how much can be matched, how much cannot, and where the
  auction would clear. A caller reading a continuous quote at 15:59 is reading a book that
  is not where the close will happen.

  Published only inside the venue's auction windows; outside them a venue may answer with
  the last one it published, which is why `Types.AuctionImbalance` carries both the venue's
  own time and when it was observed.
  """
  @callback get_auction_imbalance(symbol(), keyword()) :: result([Types.AuctionImbalance.t()])

  @doc """
  Traded volume split by price and by side, one entry per interval.

  Optional. **Not a `Candle` with extra fields and not derivable from one**: a candle's
  single volume number cannot say that of 1,000 shares, 600 lifted the ask and 400 hit the
  bid, nor at which prices each happened. Neither can be reconstructed from the other, which
  is why `Types.VolumeProfile` is its own type.

  `timeframe` uses the same vocabulary `get_historical_prices/4` does, and a venue that does
  not serve a width returns an error rather than the nearest one it does.
  """
  @callback get_volume_profile(symbol(), String.t(), keyword()) ::
              result([Types.VolumeProfile.t()])

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

  @doc """
  Balances for the credentialed account.

  Account reads (this, `get_accounts/2`, `get_transfers/2`, `get_orders/2` and the other
  list reads) follow W7: a row that cannot be read refuses the whole reply rather than being
  dropped; a reply that may be truncated is `{:error, :history_truncated}` or walked to
  completion; an option the read cannot honour is honoured or refused, never ignored.
  """
  @callback get_balances(credentials(), keyword()) :: result([Types.Balance.t()])

  @doc """
  Accounts visible to the credential. A list read: see `c:get_balances/2` for W7.
  """
  @callback get_accounts(credentials(), keyword()) :: result([map()])

  @doc """
  The fee schedule that applies to this credential.

  `credentials()` is required by this callback's own shape, but not every venue's fee
  schedule actually varies by credential — some venues publish one flat rate for
  everyone, and answering it costs no venue call at all. Where that is true,
  `AdapterContract`'s assertion 17 (the credential gate) is satisfied by declaring the
  endpoint in `Capabilities.no_venue_contact` rather than by refusing without a
  credential this callback has nothing to check: see that field's own moduledoc, and
  `dp_exchange_webull`'s `get_fees/2` for the venue this was found on.
  """
  @callback get_fees(credentials(), keyword()) :: result(map())

  @doc """
  Deposit and withdrawal history — needed to compute cost basis for transferred-in assets.

  A history that may be incomplete is never returned as complete (W7): when the venue's
  documented maximum is reached with pages unwalked, the answer is exactly
  `{:error, :history_truncated}`, for every venue and every bound (row cap or page count).
  """
  @callback get_transfers(credentials(), keyword()) :: result([map()])

  @doc """
  Places an order. Irreplaceable by definition: this is the act.

  Every rule below exists so that a caller can never retry its way into a duplicate order,
  or receive a different order from the one it asked for. `{:refused, _}` is permanent and
  `{:error, _}` may be retried, so which of the two a failure is decides whether a second
  order gets placed.

  ## Checked locally, in this order, before anything is sent

  1. the request is a map: `{:error, {:invalid_order_request, request}}`. A non-map never
     raises `BadMapError`;
  2. no key the venue's builder does not read: `{:error, {:unsupported_order_field, key}}`.
     That includes `:client_order_id` on a venue with no idempotency key. **A key the builder
     does not read is refused whatever its value, `nil` included**: `%{stop_price: nil}` on a
     venue with no stop price is `{:unsupported_order_field, :stop_price}`. (An order request
     is not a forwarded option list: a `nil` there is a field the caller wrote, and dropping
     it would place an order other than the one described.) A key the builder does read, with
     a `nil` value, is judged by that key's own rule below;
  3. `:symbol`: `{:error, {:invalid_symbol, value}}` for `nil` or an absent key, a non-string
     or a blank one;
  4. `:side`: `{:error, {:missing_field, :side}}` when absent, otherwise
     `{:error, {:invalid_side, value}}`. `:buy`/`:sell` and `"buy"`/`"sell"` in any
     case are accepted; anything `capabilities/0` says the venue does not support (a short
     sale where `supports_short_selling` is `false`) is refused here too;
  5. `:order_type`: `{:error, {:missing_field, :order_type}}` when absent. **It is never
     defaulted, and a missing price does not make an order a market order.** A type the
     venue does not serve is `{:error, {:unsupported_order_type, type}}`;
  6. `:time_in_force`: `{:error, {:missing_field, :time_in_force}}` for a type whose venue
     request carries a duration, `{:error, {:unexpected_field, :time_in_force}}` for a type
     whose request carries none, `{:error, {:unsupported_order_combination, type, tif}}` for
     a pair `capabilities/0` does not serve (a duration the venue does not serve **for that
     order type** is this, not a venue-worded atom). A good-till-date order without its
     expiry key is `{:error, {:missing_field, key}}`, and that check belongs to this step: it
     is made with the time in force and **before** any price field;
  7. the sizing, `:quantity` or (where the venue takes it) `:quote_size`. Neither given is
     `{:error, {:missing_field, :quantity}}`. Both given is
     `{:error, {:unexpected_field, :quote_size}}`. A sizing the order type cannot take (a
     cash-sized stop order, say) is `{:error, {:unexpected_field, key}}` naming the sizing
     key given. These are tagged tuples; a bare atom (`:ambiguous_order_size`,
     `:missing_order_size`) is not a family answer. A sizing value that is present but
     unusable is `{:error, {:invalid_quantity, value}}`;
  8. the price fields: `{:error, {:missing_field, key}}` for one the type needs and the
     request lacks, otherwise `{:error, {:invalid_price, value}}` and
     `{:error, {:invalid_stop_price, value}}`. A field the order type does not use is
     `{:error, {:unexpected_field, key}}` (`:price` on a market order, `:stop_price` on a
     non-stop one): **it is never silently dropped**, because the order placed would not be
     the order asked for;
  9. `:client_order_id` against the venue's own format rule: `{:error,
     {:invalid_client_order_id, value}}`;
  10. the account option the venue needs: `{:error, {:missing_option, key}}`, never a bare
      atom;
  11. credentials: `{:error, {:missing_credentials, venue}}`.

  Quantities and prices accept a `Decimal`, an integer or a numeric string, and refuse a
  float (it has already lost digits), zero and negative values, and NaN and infinity.
  Nothing here raises, whatever it is handed.

  ## An outcome that may have reached the venue is `:order_unconfirmed`

  A transport error or timeout after the request was sent, a 5xx, a 2xx whose body cannot be
  read, a 2xx without the order id, or a duplicate-client-order-id answer after an internal
  retry is

      {:error, {:order_unconfirmed, client_order_id_or_nil, reason}}

  with `reason` bounded in size. The id is the `client_order_id` actually sent, including a
  package-generated one, so the caller can look the order up. It is never a bare `{:error, _}`
  (a caller retries those) and never `{:refused, _}` (a caller treats those as "no order
  exists"). A failure decided before sending (everything above, our own rate limiter
  refusing, a signing failure) stays a plain `{:error, reason}` and is **not** wrapped.

  A 2xx placement that carries **no readable order id** is `order_unconfirmed`, never
  `{:ok, %Order{id: nil}}`: an order struct without an id cannot be looked up, cancelled or
  reconciled. A 2xx body that confirms the order (it carries the id) but lacks other fields
  is still `{:ok, %Order{}}`.

  ## A 4xx is a refusal only on the first attempt (DV6)

  On **every** venue, a 4xx answered to the **first** (only) attempt is
  `{:refused, reason}`: the venue read the request and declined it, so no order exists. That
  includes 409, 415, 422 and any other 4xx the venue does not document. The one exception is
  **429**, which is a plain `{:error, reason}` (the venue did not look at the request, and
  retrying later is correct). A 4xx answered to an internal **retry** is
  `order_unconfirmed`, not a refusal: the first attempt may have been placed, and the retry's
  4xx (a duplicate `client_order_id`) is evidence of that, not of its absence. A package that
  sends once (`retry_attempts: 1`, or no idempotency key) has only a first attempt.
  `t:order_unconfirmed/0` documents the shape of the id, which is a list for a batch.

  Conformance assertion 34 holds a venue's Fake to items 1, 2, 5 and 8 above. Assertion 50
  holds `c:preview_order/3` to answering a request `place_order/3` refuses with the identical
  tuple, and `c:replace_order/4` to `{:invalid_order_request, value}` for an empty or non-map
  change map.
  """
  @callback place_order(credentials(), map(), keyword()) ::
              order_write_result(Types.Order.t())

  @doc """
  Places several orders in **one** request. **This moves funds.**

  Optional, and **it is not `place_order/3` in a loop.** A batch is one request the venue
  accepts or rejects as a unit; N calls are N partial outcomes a caller has to reconcile,
  and the reconciliation is exactly what goes wrong when the third of five fails. A venue
  that publishes a batch endpoint gives a consumer an atomicity it cannot build from the
  single-order call, which is why this is a callback rather than a helper.

  **A partial batch is the shape to expect, not the exception.** Venues validate per order
  and return per order, so the result is a list the same length as the request, each entry
  either an order or the venue's refusal of that one. A package must not collapse that into
  a single ok-or-error: a caller told "the batch failed" when four of five were placed has
  four positions it does not know about.

  `requests` that is not a proper list is `{:error, {:invalid_argument, :requests}}`, decided
  before anything is sent and before credentials; it never raises on a non-list.

  A batch that may have reached the venue is
  `{:error, {:order_unconfirmed, [client_order_id], reason}}`: the id is the **list** of
  every client order id sent, in request order (`t:order_unconfirmed/0`).

  Venues cap the size — Webull at 50 — and a request over the cap is refused by the venue,
  not split here. Splitting would turn one atomic request into several and quietly undo the
  only reason to call this.
  """
  @callback place_orders(credentials(), [map()], keyword()) :: result([map()])

  @doc """
  Cancels an order.

  `{:ok, %Order{}}` where the venue's cancel answer carries the order, and
  `{:ok, :cancelled}` where it does not: `dp_exchange_coinbase`'s batch-cancel-of-one,
  `dp_exchange_webull`'s and `dp_exchange_schwab`'s cancels answer success with no order
  data. This type said `Order.t()` only, which three of five venues never returned. A
  caller wanting the order after a `:cancelled` asks `get_order/3`; a package does not
  fabricate one from the request.

  ## Refusals and shapes

  The order id is checked first, locally: `nil`, a non-string or a blank one is
  `{:error, {:invalid_order_id, value}}`, **before the account option and before
  credentials** (a venue's format rule for a well-formed string keeps the same tag). A
  missing account option is then `{:error, {:missing_option, key}}`, before credentials.

  An order the venue has no record of is `{:refused, :not_found}`: a 404 is a permanent
  answer, not an `:exchange_error`. A transport failure keeps Core's
  `{:error, {:exchange_error, venue, message}}` tag.

  **A cancel is always sent once.** No venue retries it internally, whatever `:retry_attempts`
  the caller passes: a second cancel of an order that the first already cancelled would come
  back as a refusal that hides the success.
  """
  @callback cancel_order(credentials(), String.t(), keyword()) ::
              result(Types.Order.t() | :cancelled)

  @doc """
  Cancels open orders in bulk, at a scope the caller must state.

  Optional. **`opts[:scope]` is required and has no default** — `:session` cancels what
  this credential's session opened, `:account` cancels everything the account has open
  including orders placed by another key or by a person at the venue's own web interface.

  The two are not interchangeable and the wider one is destructive in a way a caller may
  not expect, so a missing scope is an error rather than a choice made here. Gemini's own
  documentation recommends the narrow one; that is guidance for the caller, not licence
  for this contract to pick.

  **This is not `get_orders/2` followed by `cancel_order/3` in a loop.** That is N requests
  with N partial outcomes, and it cannot cancel an order that appeared between the listing
  and the cancels. Only the venue closes the set it holds.

  Returns `%{cancelled: [id], rejected: [id]}`. **A non-empty `rejected` is not a failed
  call** — the venue answered and some orders were already gone. Returning an error there
  would tell a caller nothing was cancelled when most of it was.

  **Sent once** (W2): never retried internally. An outcome that may have reached the venue is
  `{:error, {:write_unconfirmed, nil, reason}}` (W1); the caller reconciles with
  `get_orders/2` and does not simply call again.
  """
  @callback cancel_all_orders(credentials(), keyword()) ::
              result(%{cancelled: [String.t()], rejected: [String.t()]})

  @doc """
  Validates an order **without placing it**, returning the venue's own estimate of what
  it would cost.

  Optional. Schwab and Coinbase serve it. It is the call that checks an
  order against the venue's rules before committing to it — which matters most exactly
  where order writes are rate-limited and reads are not.

  Declared through `supports_order_preview`, so a caller can tell "this venue has no
  preview" from "this package has not implemented one".

  The request is checked exactly as `c:place_order/3` checks it, in the same order. **A
  preview the venue rejects** (Schwab's non-empty `orderValidationResult.rejects`) is
  `{:refused, {:preview_rejected, rejects}}`: the venue answered, and the answer is that this
  order will not be accepted as written. A Fake models it.
  """
  @callback preview_order(credentials(), map(), keyword()) :: result(map())

  @doc """
  Replaces an open order **atomically**.

  Optional. Every crypto venue in the family cancels and re-places, and on a venue that
  supports replacement those two calls are **not equivalent**: cancel-then-place opens a
  window in which no order is live, and on a moving market that window is the risk.

  So this is a claim about risk rather than convenience, and it is declared through
  `supports_order_replace` rather than being inferred from the callback existing.

  The order id is checked as `c:cancel_order/3` checks it
  (`{:error, {:invalid_order_id, value}}`), then the change map.

  **The change map is partial by nature, and every field it carries is held to
  `c:place_order/3`'s rules for that field**, in the same order: a non-map or an **empty** map
  is `{:error, {:invalid_order_request, value}}` (a replace that changes nothing is not a
  replace); a key the venue's builder does not read is `{:unsupported_order_field, key}`; and
  each field that is present is judged as `place_order/3` judges it (`:symbol`, `:side`,
  `:order_type`, `:time_in_force`, `:quantity`, `:price`, `:stop_price`, `:client_order_id`),
  a present `nil` included, so `%{price: nil}` is `{:invalid_price, nil}`, not "no change".
  A field the map leaves out is not checked, and is not required: that is what makes it a
  change. `c:preview_replace/4` takes the same map under the same rules.

  ## An outcome that may have reached the venue

  As for `c:place_order/3`: a transport error after sending, a 5xx, or a 2xx with an
  unreadable body or no new order id is
  `{:error, {:order_unconfirmed, client_order_id_or_nil, reason}}`. Never a bare error and
  never a refusal. A 4xx answered to the first (only) attempt is `{:refused, reason}` except
  429, which is a plain `{:error, reason}`; a 4xx answered to an internal retry is
  unconfirmed (DV6, see `c:place_order/3`).

  **A replace the venue accepted whose read-back then failed** is
  `{:error, {:replace_accepted_unread, order_id, reason}}`. The amendment is in force; only
  the order's new state is unknown, and the caller reads it with `c:get_order/3`. A package
  does not fabricate an `Order` from the request to fill the gap.
  """
  @callback replace_order(credentials(), String.t(), map(), keyword()) ::
              order_write_result(Types.Order.t())

  @doc """
  Validates a *change* to an open order without making it, returning the venue's estimate
  of the amended order.

  Optional, and distinct from `preview_order/3` in the way that matters: `preview_order/3`
  asks what an order that does not exist would cost, and this asks what an order that
  **does** exist would cost after a change. A caller cannot get the second by asking the
  first — the venue prices an amendment against the resting order's own state, including
  whatever of it has already filled.

  The reason to have it at all is the same one behind `replace_order/4`. Amending is
  irreversible at the venue, and a caller who cannot price the amendment first is choosing
  between committing blind and cancel-then-place, which reopens the very window
  `replace_order/4` exists to close.

  The order id and the change map are checked as `c:replace_order/4` checks them: an id that
  is `nil`, not a string or blank is `{:invalid_order_id, value}`; a non-map or empty change
  map is `{:invalid_order_request, value}`; each field present is judged by
  `c:place_order/3`'s rule for it.

  Declared through `supports_order_preview`, alongside `preview_order/3`.
  """
  @callback preview_replace(credentials(), String.t(), map(), keyword()) :: result(map())

  @doc """
  Closes an open position on `symbol` by placing the order that flattens it.

  Optional. **This is an order, not a query** — the venue works out the side and the size
  from the position it holds and then places the order itself, which is why it returns an
  `Order` like `place_order/3` does.

  That is also why it is not replaceable by `get_positions/1` plus `place_order/3`: the
  size a caller computes is the size as of the caller's last read, and the venue's is the
  size now. On a position that moved in between, the caller's arithmetic leaves a residue
  or overshoots into a position the other way. Only the venue can flatten to exactly zero.

  A venue that does not carry positions has nothing to close, and says so through
  `capabilities/0` rather than through this returning an empty success.
  """
  @callback close_position(credentials(), symbol(), keyword()) :: result(Types.Order.t())

  @doc """
  One order's current state.

  The order id is checked first, locally: `nil`, a non-string or a blank one is
  `{:error, {:invalid_order_id, value}}`, before the account option and before credentials.
  A missing account option is `{:error, {:missing_option, key}}`, before credentials. An
  order the venue does not know is `{:refused, :not_found}`. See `c:cancel_order/3`.
  """
  @callback get_order(credentials(), String.t(), keyword()) :: result(Types.Order.t())

  @doc "Orders visible to the credential."
  @callback get_orders(credentials(), keyword()) :: result([Types.Order.t()])

  @doc """
  Past fills for the credential.

  **Oldest first, by each fill's own `:timestamp`**, as `get_trades/2` is.
  """
  @callback get_trade_history(credentials(), keyword()) :: result([Types.Fill.t()])

  @doc """
  The credential's own traded volume, as the venue aggregates it.

  Optional. **This is the account's volume, not the market's** — `get_market_overview/1`
  answers the second question and this one answers "what have I traded".

  It is not `get_trade_history/2` summed. The venue's aggregation is the one its own fee
  tiers are computed from, and reproducing it means fetching every fill over the reporting
  window — on a venue that requires a symbol per request, that is one request per symbol
  per period, and the result would still be this package's arithmetic rather than the
  venue's ledger. Where the two disagree, the venue's is the one that decides what a
  caller is charged.

  Shape is the venue's own, so `map()`: the fields differ enough between venues that a
  normalised struct would be mostly `nil` on all of them.
  """
  @callback get_trade_volume(credentials(), keyword()) :: result([map()])

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

  A venue pushing faster than its subscriber consumes drops beyond a stated bound and emits
  a `:degraded` notice saying so, and a second one when that subscriber catches up. Growing
  a mailbox silently until the node dies is the failure this avoids; dropping silently is
  the failure the notice avoids, and the pair of notices is what lets a consumer bracket
  exactly the window it has to reconcile from a pull endpoint.

  `DpExchange.Core.Fanout` implements this, and a venue delivers through it rather than
  writing its own `send/2` loop.

  **This paragraph used to say "drops oldest", and no package implemented any of it.** Both
  halves are worth recording. A sender cannot drop the oldest message in another process's
  mailbox — nothing in the BEAM lets one process remove a message another has already been
  sent — so as written the guarantee described something no implementation could have
  honoured. What a sender can do is decline to add to a queue already past its bound, which
  is also the better trade here: a quote that arrives while a consumer is thirty thousand
  messages behind is worthless by the time it would be read, and the frames it would push
  out are no fresher. Meanwhile all five venues fanned out with a bare `send/2` and had
  never looked at a subscriber's mailbox, so a consumer reading this section was told
  back-pressure was handled and declared when neither was true. An unimplementable sentence
  in a contract does not stay a wording problem; it becomes the reason a real guarantee is
  missing.

  ## Arguments are validated first, in this order, whether or not a feed runs

  Every streaming call (`subscribe/2`, `unsubscribe/2`, `update_symbols/2`, and
  `c:subscribe_notices/1` for its subscriber) checks its arguments **before** it looks for a
  feed, so bad input gets the same answer on a venue whose feed is up and on one whose feed
  is not:

  1. the symbol list. Anything but a proper list of strings that are non-blank after
     `String.trim/1` (not a list, an improper list, a `nil` or number element, a
     whitespace-only element) is `{:error, {:invalid_symbols, value}}`. A malformed argument
     is **never** `:ok`: `unsubscribe(nil)` refuses.
  2. the subscriber. A `:to` that is neither a pid nor an atom other than `nil`, `true` and
     `false` is `{:error, {:invalid_subscriber, value}}`. `to: nil` is not refused: it means
     "the caller", exactly as if the key were absent (see `DpExchange.Core.Config.opt/3`).
  3. only then `{:error, :feed_not_started}` when no feed is running.

  A `:to` atom that names no registered process is accepted and then skipped on delivery, as
  `DpExchange.Core.Fanout` skips it.

  **`subscribe([])` registers the subscriber and opens nothing**: no socket, route or
  connection is made for an empty set. A consumer that has not asked for a symbol must not
  find a connection open.

  Conformance assertion 32 holds a venue's Fake to 1 and 2, and its facade to 1 and 2 with no
  feed running.

  ## What the pushed values mean is what the pull endpoints mean

  The market-data rules of `c:get_price/2`, `c:get_top_of_book/2`, `c:get_order_book/2`,
  `c:get_trades/2` and `c:get_historical_prices/4` bind the stream as they bind REST, and the
  Fake as well:

    * `Quote.venue_time` and `TopOfBook.venue_time` are the venue's stated time of the trade
      or of the quote, `nil` when none is stated. A socket envelope's timestamp, a message
      assembly time and another event's time are not substitutes (MD7).
    * `Quote.volume_window` is `:print` only when **every** print is delivered. A conflated
      stream reports cumulative volume as `:running_total`, never the last size as `:print`
      (MD8).
    * A book level that cannot be read refuses the whole book; a snapshot level of size `0`
      is dropped; a negative size or a price `<= 0` refuses the book (MD5, MD6).
    * A delta stream that detects a sequence gap resubscribes the affected symbols for a fresh
      snapshot and emits a notice once; a frame whose sequence is `<=` the last applied is
      dropped, never applied (MD9).
    * A bar delivered while it is still forming is not a finished bar. Unless the caller
      passed `include_partial: true`, only closed bars are pushed (MD1).
    * A market-data option (`include_partial:`, `limit:`, `depth:`, `since:`) the stream cannot
      honour is `{:error, {:unsupported_option, key}}` or
      `{:error, {:invalid_option, key, value}}` from the call that was given it, never
      ignored (MD4). `:to` on `c:update_symbols/2` is the one documented exception: it is
      ignored by a feed that does not honour it.
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

  **It is feed-wide, not per subscriber.** Nothing in the call names a subscriber, so
  unsubscribing a symbol stops it for every process subscribed to it on this venue. Two
  consumers sharing one venue's feed must agree on its symbol set, or each run their own
  feed.

  Its `symbols` are validated as `c:subscribe/2` validates them: a malformed list is
  `{:error, {:invalid_symbols, value}}` and never `:ok`, and that answer does not depend on
  whether a feed is running.
  """
  @callback unsubscribe([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  Changes a live subscription's symbol set without tearing the venue's connections down.

  The set is **replaced**, where `c:subscribe/2` adds. `symbols` are validated as
  `c:subscribe/2` validates them (`{:error, {:invalid_symbols, value}}`, whether or not a feed
  runs), and a venue honours `:to` here only if its feed really does; one that does not
  ignores it rather than refusing.
  """
  @callback update_symbols([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  What is **observed arriving**, by which route — never what was subscribed.

  This is the strongest guarantee in the contract, and it exists because intent standing in
  for evidence is how a venue reported 325 symbols subscribed and confirmed while 174 were
  delivering. A venue that cannot observe delivery answers `:not_covered` rather than
  reporting success it cannot see.

  Symbols absent from the map are `:not_covered`.

  ## Observation is scoped to the current transport session

  Evidence from a connection that has since dropped is **not** evidence about now. On
  `:link_down`, a venue narrows `coverage/1` by the symbols that link was carrying, exactly
  the way it already narrows on the same socket's process death and on `unsubscribe/2`.
  They come back as frames arrive after the resubscribe.

  This was not always so, and the reason it is written here is that all four streaming
  venues got it wrong in the same way at once. Every one of their sockets returns
  `{:reconnect, state}` from `handle_disconnect/2` — the socket *process* survives a
  transport drop, so no `EXIT` fires, so none of the crash-keyed reset paths ran. Between a
  drop and a successful resubscribe, `coverage/1` answered `:stream` for symbols arriving
  from nowhere; and where the reconnect restored the socket but the venue silently failed
  to restore some symbols — the 325-subscribed/174-delivering shape exactly — those symbols
  answered `:stream` indefinitely, on the strength of frames seen before the disconnect.
  Stale evidence standing in for current evidence is the same substitution this callback
  exists to prevent, one level down.

  A consumer therefore sees a brief, truthful dip across a reconnect, bracketed by the
  `:link_down` / `:link_up` notice pair that exists for exactly that. Under-reporting for a
  few seconds is the direction the paragraph above already asks for; over-reporting
  indefinitely is the failure it was written against.

  ## A route may narrow further, and must say which

  `Core.PollingFeed` applies a staleness window — a symbol whose last successful poll is
  older than `interval_ms * @coverage_grace` drops out — because a poll that did not answer
  within its own interval is genuinely not delivering, and that is a bounded statement a
  polling route can make.

  **A streaming route deliberately does not.** An illiquid pair may honestly not print for
  hours, and on `dp_exchange_schwab` silence overnight and all weekend is the *correct*
  state, not a fault. A window there would report `:not_covered` for a healthy quiet market,
  which is a false alarm and its own harm. So on a stream, coverage means *observed at least
  once since this connection came up* — never "recently", and never "how stale".

  ## It answers a map in every state

  With no feed running, or with a `:feed` option naming a pid on **another node**, the answer
  is `%{}` and never an exit or a `Process.alive?/1` raise on a remote pid. A Fake reports
  only the symbols it actually delivered data for, as the real feed reports only what arrived.
  """
  @callback coverage(keyword()) :: %{symbol() => route()}

  @doc """
  What is arriving, per symbol, split by **which kind** of data it is.

  Optional — see `@optional_callbacks` below for why this is not required. It exists
  because `coverage/1` is truthful and was not enough.

  ## The incident this closes

  DpCryptoManagement's issue #22: Coinbase's `level2` channel delivered over 11,000
  frames for 406 symbols while `ticker` was dark for all but 5, and `coverage/1`
  answered `:stream` for all 406 — correctly, because it counts any payload for a
  symbol, a `Types.OrderBook` exactly as much as a `Types.Quote`. Verified by running it:
  `coverage after ONLY an OrderBook (no ticker quote): %{"XLM-USD" => :stream}`. The
  defect had stayed invisible across two issues because `coverage/1` collapses every
  data kind into one boolean, so "ticker dark, book healthy" is indistinguishable from
  "everything healthy". This callback exists to make that distinguishable.

  `Capabilities.data_kind()` is the existing vocabulary — the same one `streamable`
  already declares in. This does not invent a parallel one.

  ## What this is NOT

    * **Not a replacement for `coverage/1`.** A caller asking "is anything arriving for
      this symbol" still gets a straight answer without knowing a venue's channel
      vocabulary.
    * **Not a per-channel report.** A venue's own channel names — Coinbase's `level2`,
      `ticker` — must never cross this facade; the contract speaks `data_kind()`, never
      a venue's word for one.
    * **Not a freshness or latency API.** It reports the same observed-arrival fact
      `coverage/1` reports, split by kind — never when, never how stale.

  ## The invariant, if a venue implements this at all

      Map.keys(coverage(opts)) ==
        coverage_by_kind(opts) |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

  The conformance suite asserts this, and that every key here is a kind the same
  venue's own `capabilities().streamable` declares, **only when this callback is
  exported** — an absent implementation is a venue that has not adopted this yet, not a
  failure, and asserting nothing in that case is deliberate.
  """
  @callback coverage_by_kind(keyword()) :: %{Capabilities.data_kind() => %{symbol() => route()}}

  @doc """
  The symbols the consumer **asked to stream**: what `c:subscribe/2` and `c:update_symbols/2`
  have set and `c:unsubscribe/2` has not removed.

  Optional — see `@optional_callbacks`. A venue that does not export it has not adopted it,
  which is not a failure.

  ## Wanted is intent; `c:coverage/1` is evidence

  `c:coverage/1` is what is **observed delivering**, and it deliberately never reports
  intent. `wanted/1` is the opposite and is allowed to be: it is the consumer's own request,
  read back. The two together answer the question neither answers alone: a symbol in
  `wanted/1` and not in `c:coverage/1` is asked for and not arriving, which is the
  325-subscribed/174-delivering shape (see `c:coverage/1`) made visible without a consumer
  keeping its own copy of what it asked for.

  Returns a list of canonical symbols or a `MapSet` of them, never a route map, and never
  including a symbol the consumer did not ask for. With no feed running, or a `:feed` naming
  a pid on another node, the answer is empty, as `c:coverage/1`'s is. It never shows a
  venue's own channel or session vocabulary.

  The conformance suite asserts, **only when this callback is exported**, that after a
  `c:subscribe/2` the Fake's `wanted/1` holds every symbol subscribed and that every symbol
  `c:coverage/1` reports is also wanted.
  """
  @callback wanted(keyword()) :: [symbol()] | MapSet.t(symbol())

  @doc """
  Subscribes the caller to the package's notices — what it is doing and what is going
  wrong with it.

  Distinct from `c:subscribe/2`, which carries what the *venue* says about the *market*. A
  monitoring process that never touches market data still needs to know a credential was
  rejected.

  **A notice is a prompt to re-read, never the record.** Delivery is not guaranteed — see
  `DpExchange.Core.Notice`.

  A `:to` that is not a pid or a non-boolean atom is `{:error, {:invalid_subscriber, value}}`
  (`to: nil` means the caller), checked before `{:error, :feed_not_started}`. Registering for
  notices sends nothing unless the real feed sends something on registration: in particular a
  Fake sends no `:link_up` the real feed would not. See `c:subscribe/2`.
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

  ## "Crypto venues answer `:open`" is not a credential exemption by itself

  `AdapterContract`'s assertion 17 (the credential gate) skips a `:required` venue's
  `market_status/1` **only when that venue's own `asset_classes/0` is exactly
  `[:crypto]`** — crypto has no exchange-mandated trading session, so no credential can
  change what this call reports. That is narrower than it may look: `dp_exchange_schwab`
  serves equities and its real `market_status/1` calls an authenticated venue endpoint,
  so a venue that is not crypto-only stays gated and must either authenticate this call
  for real or declare it `:unsupported` — see "17. credential gate" in
  `DpExchange.Core.AdapterContract` for the full argument and why this is scoped to
  `asset_classes/0` rather than to the callback's name.
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
    quantization: 1,
    coverage_by_kind: 1,
    wanted: 1
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
        "not load-bearing — a consumer reaches every other endpoint without depth; " <>
          "irreplaceable where published, since a book is the venue's own",
      {:list_watchlists, 1} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does, since " <>
          "the venue's list is the venue's and can differ from any the host holds",
      {:get_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:create_watchlist, 3} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:update_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:delete_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:get_financials, 3} =>
        "replaceable — issuer statements are published by the issuer and carried by many " <>
          "data providers, so a venue is one source among several",
      {:get_corporate_events, 1} =>
        "replaceable — dividends, earnings dates and splits come from the issuer and are " <>
          "carried by many providers",
      {:get_filings, 2} =>
        "replaceable — filings live with the regulator; a venue indexing them is a pointer",
      {:get_news, 1} => "replaceable — a venue relaying news is one feed among many",
      {:get_screener, 2} =>
        "not load-bearing — a venue may publish no screeners; irreplaceable where it does, " <>
          "since the criteria are the venue's own and no other source reproduces its list",
      {:create_account, 1} =>
        "not load-bearing — a venue may not open accounts through its API; irreplaceable " <>
          "where it does, since only the venue creates accounts on the venue",
      {:rename_account, 3} =>
        "not load-bearing — a venue may not expose account administration; irreplaceable " <>
          "where it does",
      {:get_roles, 1} =>
        "not load-bearing — a venue may define no roles; irreplaceable where it does, since " <>
          "only the venue knows what this credential is permitted to reach",
      {:get_top_of_book, 2} =>
        "replaceable — the top level of get_order_book/2 answers the same question wherever " <>
          "a venue publishes depth",
      {:get_option_chain, 2} =>
        "not load-bearing — a venue may list no options at all, so a package without this " <>
          "is complete rather than lacking; irreplaceable where the venue does list them",
      {:get_option_expirations, 2} =>
        "replaceable — derivable from get_option_chain/2, at the cost of fetching every " <>
          "strike to learn the dates",
      {:get_option_greeks, 2} =>
        "replaceable — model output; any pricing library computes it from the contract and " <>
          "a volatility input, and two venues publish different numbers anyway",
      {:get_deposit_address, 3} =>
        "not load-bearing — a venue may accept no deposits through its API; irreplaceable " <>
          "where it does, since only the venue can say where its own custody receives",
      {:list_approved_addresses, 1} =>
        "not load-bearing — not every venue keeps an allow-list; irreplaceable where one exists",
      {:estimate_withdrawal_fee, 4} =>
        "replaceable — network fees are observable on the chain, though not to the venue's " <>
          "own precision",
      {:withdraw, 5} =>
        "not load-bearing — a venue may not permit withdrawal through its API; irreplaceable " <>
          "where it does, since nothing outside the venue moves the venue's custody",
      {:list_portfolios, 1} =>
        "not load-bearing — a venue may have one implicit context and nothing to name",
      {:quote_conversion, 4} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does, " <>
          "since only the venue quotes its own rate",
      {:commit_conversion, 2} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does",
      {:get_conversion, 2} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does, " <>
          "since only the venue holds the conversion's state",
      {:get_funding, 2} =>
        "not load-bearing — a venue may list no perpetuals; irreplaceable where it does, " <>
          "since funding is the venue's own and differs between venues on one contract",
      {:get_contract_stats, 2} =>
        "not load-bearing — a venue may list no derivatives; irreplaceable where it does, " <>
          "since a mark price is the venue's own valuation and nothing external reproduces it",
      {:get_positions, 1} =>
        "not load-bearing — a spot venue holds none; irreplaceable where they exist, since " <>
          "only the venue knows what it has you down for",
      {:get_staking_rates, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since the " <>
          "rate is the venue's own offer",
      {:get_staking_balances, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since only " <>
          "the venue knows what it holds staked",
      {:get_staking_rewards, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does",
      {:get_staking_history, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since only " <>
          "the venue holds its own record",
      {:stake, 3} => "not load-bearing — a venue may not stake; irreplaceable where it does",
      {:unstake, 3} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, and the " <>
          "only route back out of the venue's custody",
      {:list_instruments, 1} =>
        "not load-bearing — a richer get_symbols/1; absence costs detail, not function",
      {:get_market_overview, 1} => "not load-bearing — a bulk convenience over per-symbol calls",
      {:get_fees, 2} =>
        "not load-bearing — a consumer reaches every other endpoint without the schedule; " <>
          "irreplaceable where published, since a venue's fees are its own",
      {:get_trade_history, 2} => "not load-bearing — after-the-fact reconstruction",
      {:get_transfers, 2} =>
        "not load-bearing — a record of movements the venue has already made; " <>
          "irreplaceable, since only the venue holds its own ledger",
      {:get_accounts, 2} => "not load-bearing — balances are the sizing input",
      {:update_symbols, 2} =>
        "not load-bearing — an optimisation over unsubscribe/2 + subscribe/2, both core",
      {:market_status, 1} =>
        "not load-bearing — a venue that cannot say is treated as open, which is the crypto answer",
      {:place_orders, 3} =>
        "irreplaceable and not load-bearing — a consumer that places one order at a time " <>
          "is complete without it, and place_order/3 in a loop is NOT the same thing: a " <>
          "batch is one request the venue accepts or rejects as a unit, and N calls are N " <>
          "partial outcomes to reconcile",
      {:preview_order, 3} =>
        "not load-bearing — absence means placing without a dry run, which is how every " <>
          "other venue in the family works",
      {:replace_order, 4} =>
        "not load-bearing, but it is RISK-bearing — absence means cancel-then-place, " <>
          "which works and opens a window in which no order is live",
      {:preview_replace, 4} =>
        "not load-bearing — absence means amending without a dry run; the amendment " <>
          "itself is what bears risk, and that is replace_order/4's entry",
      {:convert, 4} =>
        "irreplaceable and not load-bearing — only the venue converts on the venue, and a " <>
          "consumer that never converts is complete without it; NOT a shorthand for " <>
          "quote_conversion/4 plus commit_conversion/2, which hold a rate this one does not",
      {:get_trade_volume, 2} =>
        "irreplaceable and not load-bearing — the venue's own aggregation is what its fee " <>
          "tiers are computed from, and summing get_trade_history/2 gives this package's " <>
          "arithmetic rather than the venue's ledger; a consumer that never reports on its " <>
          "own volume is complete without it",
      {:list_payment_methods, 2} =>
        "irreplaceable and not load-bearing — only the venue knows which funding sources " <>
          "it holds for this account, and a consumer that never moves fiat is complete " <>
          "without it",
      {:add_payment_method, 2} =>
        "not load-bearing — registering a bank account is usually completed by a person " <>
          "out of band, so a consumer doing it through the venue's own interface loses " <>
          "nothing; irreplaceable where the venue exposes it",
      {:get_payment_method, 3} =>
        "irreplaceable and not load-bearing — only the venue knows whether a funding " <>
          "source it holds is still usable, and picking the row out of " <>
          "list_payment_methods/2 reads a snapshot rather than the current status",
      {:get_notional_balances, 3} =>
        "replaceable and not load-bearing — a consumer holding a rate can value " <>
          "get_balances/2 itself, and will get a different number than the venue did; " <>
          "this is the venue's own valuation, which is what a venue statement reconciles " <>
          "against",
      {:list_custody_fees, 2} =>
        "irreplaceable and not load-bearing — only the venue records what it charged for " <>
          "custody, and a consumer that holds nothing in custody is complete without it; " <>
          "an empty list is 'nothing charged', never 'no such fee'",
      {:transfer_internal, 4} =>
        "irreplaceable and not load-bearing — only the venue moves funds between its own " <>
          "accounts, and it is NOT withdraw/5: nothing leaves the venue and no chain is " <>
          "involved",
      {:request_approved_address, 4} =>
        "irreplaceable and not load-bearing — only the venue holds its own allowlist, and " <>
          "a consumer withdrawing only to addresses added through the venue's interface " <>
          "never needs it; a successful response is NOT permission to withdraw",
      {:remove_approved_address, 3} =>
        "irreplaceable and not load-bearing — the inverse of the above, and generally " <>
          "immediate where addition is not",
      {:get_transactions, 2} =>
        "replaceable — a consumer that records its own activity has the same history, and " <>
          "wider than both get_trade_history/2 and get_transfers/2; summing it is not a " <>
          "balance",
      {:list_networks, 2} =>
        "irreplaceable and not load-bearing — only the venue says which chains it credits, " <>
          "and a caller that never moves funds is complete without it; a wrong network on " <>
          "get_deposit_address/3 sends funds to a chain the venue does not credit",
      {:list_fee_promos, 1} =>
        "not load-bearing — a venue running no promotions has an empty list, and a caller " <>
          "that pays the published schedule is merely over-estimating cost; irreplaceable " <>
          "where it does, since only the venue knows what it is currently discounting",
      {:get_fx_rate, 3} =>
        "replaceable — an FX reference rate is a third party's number that the venue is " <>
          "relaying, and the source publishes it directly; NOT the venue's own market, " <>
          "which is why Types.FxRate names the source separately from the provider",
      {:get_trades, 2} =>
        "replaceable — the public tape is carried by every market-data provider, and a " <>
          "consumer already reading one elsewhere does not need the venue's; NOT the same " <>
          "question as get_trade_history/2, which is the credential's own fills",
      {:get_auction_imbalance, 2} =>
        "irreplaceable and not load-bearing — only the exchange running the auction " <>
          "publishes its imbalance, and a consumer that never trades an auction is " <>
          "complete without it; NOT derivable from get_order_book/2, which describes the " <>
          "continuous market the auction replaces",
      {:get_volume_profile, 3} =>
        "irreplaceable and not load-bearing — the split of volume by price and side is the " <>
          "venue's own classification of its own prints, and a Candle's single volume " <>
          "number cannot be decomposed back into it",
      {:cancel_all_orders, 2} =>
        "irreplaceable and not load-bearing — get_orders/2 plus cancel_order/3 in a loop " <>
          "is N partial outcomes and cannot reach an order that appeared between the two, " <>
          "but a caller that never needs a bulk cancel is complete without it",
      {:close_position, 3} =>
        "irreplaceable and not load-bearing — get_positions/1 plus place_order/3 leaves a " <>
          "residue when the position moves between the read and the order, and only the " <>
          "venue flattens to exactly zero; a venue carrying no positions has nothing to close",
      {:subscribe_notices, 1} =>
        "not load-bearing — losing notices costs visibility into the stream, not the stream",
      {:wanted, 1} =>
        "not load-bearing — a consumer can keep its own copy of what it subscribed; " <>
          "irreplaceable only as the venue's own read-back of the set it is actually " <>
          "holding, to compare against coverage/1",
      {:coverage_by_kind, 1} =>
        "irreplaceable and not load-bearing — only the venue can say which kind of data is " <>
          "arriving per symbol, and a caller asking only 'is anything arriving' is complete " <>
          "with coverage/1 alone; where a venue does implement it, coverage/1's own symbol " <>
          "set must be exactly the union across every kind (DpCryptoManagement issue #22)"
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
