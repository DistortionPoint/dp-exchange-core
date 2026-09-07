# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific
version needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version — pin three-part (`~> 0.1.0`). Coverage is uneven by design: fakes and
live public endpoints are well covered, order placement and authenticated flows are
not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
which venue, what was run against it, and when. "Marked proven" with no evidence is not
an acceptable changelog line.

## [Unreleased]

### Added

- **`AdapterContract` gains assertion 17, "credential gate" — on a venue declaring
  `credential_benefit: :required`, no active credentialed endpoint's `fake:` may answer
  `{:ok, _}` when called with credentials stripped.** Found independently in two venue
  packages the same week: `dp_exchange_robinhood`'s fake answered `{:ok, _}` from six
  credentialed functions (`get_balances/2`, `get_accounts/2`, `place_order/3`,
  `cancel_order/3`, `get_order/3`, `get_orders/2`) regardless of what credentials they
  were given, on a venue where **every request is signed and there is no anonymous
  endpoint** — the fake was lying about the most basic property of the venue. A separate
  fake/real error-shape divergence was found the same day in `dp_exchange_gemini`. Tier 1
  in-process fakes are the only tier that runs on every CI run and the only one most
  consumers ever exercise, so a fake more capable than the real venue silently certifies
  consumer code that forgot to supply credentials.

  Fake-only — it never dials the real venue, so it carries none of the risk a
  live-network assertion would — and gated strictly on `credential_benefit: :required`,
  not run unconditionally: a venue declaring `:no_difference` or `:higher_ceiling` may
  legitimately serve some of these endpoints without a credential, and asserting a
  refusal there would invent a rule the venue never claimed. `test_connection/2` and
  `get_rate_limit_status/2` are excluded from the gate on any venue, `:required` or not
  — both callbacks document `credentials() | nil` on purpose, and answering plain
  reachability with none at all is the documented behaviour, not the defect this
  assertion exists to catch.

  **Deliberately does not assert real/fake refusal-shape equality**
  (`call_on(@venue, stripped) == call_on(@fake, stripped)`), which was the second,
  stronger proposal and would also have caught Robinhood's `{:refused,
  :missing_credentials}` vs. the real venue's `{:error, {:missing_credentials,
  :robinhood}}`. That check is only safe while every venue's auth check fails locally
  before any HTTP dial-out — true today, but Core would be assuming an invariant about a
  venue it has not reviewed, and a conformance assertion that can make a live network
  call under some future venue's implementation is a worse failure mode than the gap it
  would close. Verified against the real generated assertion, not only a manual
  replica: temporarily setting `credential_benefit: :required` on `ReferenceVenue` (whose
  `get_balances/2` ignores its credentials argument, correctly, for its real
  `:higher_ceiling` declaration) makes assertion 17 fail with `{:get_trade_history, 2}
  answered {:ok, _} with credentials stripped`, confirming the check fires on real
  generated code before being reverted; `contract_teeth_test.exs` carries the permanent
  regression fixtures (`Broken.CredentialGate.NeverChecks` and `.Conforming`).

  **Assertion count is now seventeen.** `usage-rules/testing.md` and
  `docs/guides/building-an-exchange-package.md` updated; `usage-rules/adapter.md` gains a
  dedicated section next to assertion 16's.

  **Potentially breaking for any venue package declaring `credential_benefit: :required`
  whose fake does not already gate every credentialed endpoint on its `credentials`
  argument.** Of the five, this specifically means `dp_exchange_robinhood` (the venue
  this defect was found in) will exercise this assertion for real on its next Core bump;
  whether it still fails depends on whether that package's own fake fix has landed by
  then. The other four venues do not currently declare `credential_benefit: :required`
  (per this repo's own review of their `capabilities/0`), so this assertion is inert for
  them today and only bites if one of them adopts `:required` without also gating its
  fake.

### Fixed

- **`Timeframe.nameable/0` was missing `1y`, the same way it was once missing `1w` and
  `1M`.** `dp_exchange_webull`'s stock, option and futures bars genuinely serve a yearly
  candle alongside the weekly and monthly ones (`Rest.get_stock_bars/5`, tested against
  the venue's own `timespan` enum), but `Capabilities.new/1` raised on `1y` the way it
  used to raise on `1w`/`1M` before those were added — the exact under-declaration this
  module's own moduledoc already records twice over. Webull carried
  `@core_unnameable_widths ~w(1y)`, subtracted from its `historical_timeframes`
  declaration with a comment naming this exact gap as a Core limitation rather than an
  under-declaration on its own part.

  `@unbucketable` is now `~w(1w 1M 1y)` — a year is not a fixed number of seconds any
  more than a month is, and `seconds/1`/`aligned?/2`/`boundary/2` treat it exactly as
  they already treat the other two: no boundary rule, never rejected as invalid.
  `known/0` is unaffected; only `nameable/0` (and therefore what `Capabilities.new/1`
  will accept in `historical_timeframes`) widens.

  **Additive, not breaking**: every existing valid `historical_timeframes` declaration
  remains valid, since `nameable/0` only grew. **Unblocks `dp_exchange_webull`**
  declaring its eleventh width — its `@core_unnameable_widths` workaround and the
  subtraction using it are removable once it takes this version.

- **`AdapterContract`'s assertion 12 ("an active endpoint does not answer
  :not_supported") only checked endpoints EXPLICITLY present in `capabilities().endpoints`
  — an endpoint never mentioned there at all slipped past it, even though
  `Capabilities`'s own moduledoc makes an absent entry active too ("anything not named in
  the map is `:experimental` — the only honest default").** `Capabilities.endpoints_at/2`
  iterates only the map's explicit entries by design (its own `@doc` says "every endpoint
  DECLARED at maturity"), so `Capabilities.endpoints_at(caps, :proven) ++
  Capabilities.endpoints_at(caps, :experimental)` — the set the assertion used to check —
  never contained an endpoint a venue simply never declared. A venue implementing a stub
  that returns `{:error, :not_supported}` for, say, `get_fx_rate/3`, while never entering
  `{:get_fx_rate, 3}` into `endpoints` at all, is under-declaring by silence rather than by
  a wrong value — and passed the exact check built to catch under-declaring, because that
  check only ever looked at what was explicitly written down. `core_endpoints/0`'s own
  "every core endpoint carries an explicit maturity" test closes this for the ~16 endpoints
  named there; it does not touch the other ~70 a venue is free to leave undeclared.

  Fixed by enumerating `Venue.behaviour_info(:callbacks)` and asking
  `Capabilities.active?/2` directly, rather than enumerating `endpoints_at/2`'s two lists.
  `active?/2` already applies the documented undeclared-is-experimental default, so this
  closes the gap without changing what "active" means — it changes what gets CHECKED
  against that meaning. `DpExchange.Core.ReferenceVenue` declares every single callback
  explicitly (see `endpoint_maturities/0`), so Core's own conformance run is unaffected;
  `Broken.SilentlyUnsupported` in `contract_teeth_test.exs` reproduces the gap and proves
  the fix closes it.

  **Potentially breaking for all five venue packages** (`dp_exchange_coinbase`,
  `dp_exchange_gemini`, `dp_exchange_robinhood`, `dp_exchange_schwab`,
  `dp_exchange_webull`): any of them relying on the documented undeclared-default for a
  peripheral endpoint while that endpoint's implementation genuinely answers
  `{:error, :not_supported}` will now fail this assertion in their own CI, where it
  previously passed silently. That failure is correct — it is exactly the under-declaring
  defect assertion 12 exists to catch — and the fix is to declare the endpoint
  `:unsupported` explicitly, not to weaken the check.

- **`PollingFeed`'s `:fetch_all` path crashed the whole feed process on a `{:refused, _}`
  return — the one outcome `fetch_all_and_publish/1`'s case statement did not match —
  instead of recording one refused symbol.** `dp_exchange_robinhood`'s `Feed` moduledoc
  documented this exact gap as the reason it stayed on per-symbol `:fetch` rather than
  adopt this venue's own documented repeatable-query bulk endpoint (`?symbol=BTC-USD&
  symbol=ETH-USD` in one signed request): "a `{:refused, _}` returned from `:fetch_all`
  does not match either clause `fetch_all_and_publish/1` handles and would crash this
  feed's process instead of recording one refused symbol." Verified by reproducing it: a
  `fetch_all` returning `{:refused, _}` raised `CaseClauseError` inside `handle_info`,
  taking the GenServer down.

  `t:PollingFeed.fetch_all/0` — previously undocumented as a type at all — now names a
  third outcome, `{:refused, refusals}` where `refusals :: [{symbol, reason}]`, the batch
  analogue of `fetch`'s own `{:refused, reason}`: each named symbol is reported once
  through `on_refusal`, exactly as the per-symbol path already does, instead of being
  retried forever as an ordinary `{:error, reason}` would be.

- **`PollingFeed`'s `:fetch_all` path could deliver `{:ok, []}` forever without ever
  tripping the "delivered NOTHING" escalation.** `record_success(state, false)` — the
  clause a zero-event bulk response routed through — was a silent no-op: it never called
  `delivering_nothing?/2`, so a bulk venue answering successfully with an empty result set
  every cycle (a bad credential filtered to nothing server-side, for one) produced no log
  line and no `on_notice`, the exact silent-failure shape this module's moduledoc names as
  the reason the escalation exists at all. `{:ok, []}` now routes through
  `record_failure/3` with reason `:empty_response`, so it is counted, logged and escalated
  the same as any other empty cycle. `record_success/2`'s now-unreachable `false` clause is
  removed; every remaining call site always delivered something, so it is `record_success/1`.

- **`HttpClient`'s retry backoff hardcoded `4 - attempts_left`, assuming the default
  `retry_attempts` of 3.** `retry_attempts` is a documented, caller-configurable option;
  configuring it to 4 or more starts `attempts_left` above 4, so `4 - attempts_left` goes
  negative on the very first retry and `Process.sleep/1` raises `FunctionClauseError` — in
  the CALLING process, uncaught, since this library does not supervise its callers. The
  same failure shape this module's moduledoc already records for `retry_attempts: nil`
  (`4 - nil` via Erlang term ordering), reachable here for a valid, in-range, documented
  integer instead. No existing test used `retry_attempts` above the default, so nothing
  caught it. Fixed by scaling the backoff from attempts actually made
  (`retry_attempts - attempts_left + 1`) rather than a constant tied to the default — always
  `>= 1` regardless of configuration, and numerically identical to the old formula's own
  output at the default of 3.

- **`Notice.new/3` validated `kind` against the closed vocabulary but never validated
  `severity`**, despite `severity` being documented as equally closed ("not a log level — a
  call to action"). `Notice.new(:link_down, :v, severity: :critical)` silently built a
  `%Notice{severity: :critical}` outside its own `t:Notice.severity/0` typespec. `severity`
  is now checked against `[:info, :warning, :error]`, raising `ArgumentError` the same way
  an unknown `kind` already did.

- **`Notice.new/3` read `:severity`, `:at` and `:details` with `Keyword.get/3`, which does
  not substitute its default for a PRESENT-and-`nil` value — the same trap
  `DpExchange.Core.Config.opt/3`, `PollingFeed` and `HttpClient` have each paid for
  separately.** A caller forwarding its own options (or computing a value and getting
  `nil` back in an edge case) could produce `severity: nil` (a struct violating its own
  typespec, previously unvalidated besides), `at: nil` (violating `@enforce_keys`' own
  non-nil promise, the same way a `Core.Types.*` decode bug does — see `Types.Validate`),
  or `details: nil` (raising "must be a map, got nil" for what is, from a forwarding
  caller's side, simply an unset optional field). All three now read through
  `DpExchange.Core.Config.opt/3`: an explicit `nil` falls back to the same default an
  absent key already used.

- **`Core.Types.Trade.new/1` accepted an explicit `broken: nil`, bypassing the struct's own
  documented default (`false`) and typespec (`boolean()`, never `boolean() | nil`).**
  `:broken` is deliberately not `@enforce_keys`'d — an omitted value should default to
  `false`, and that part worked — but `@enforce_keys` guards presence, not `nil` (see
  `Types.Validate`), so a PRESENT `broken: nil` (the shape a JSON decode produces from a
  venue field that came back `null`) reached the struct unchanged. `nil` and `false` are
  both falsy in a bare `if`, which is exactly why nothing had noticed; a `case` matching
  `true` and `false` with no third clause does not get that courtesy, and `:broken` is the
  field a phantom high or low rides in on. `new/1` now normalises an explicit `nil` to
  `false` — this type's own moduledoc already says `false` means "the venue said not
  broken **or said nothing**," so this is the documented policy applied consistently
  rather than a new judgement call.

- **`Core.Types.StakingBalance`'s `:by_provider` defaulted to `nil` via a bare `defstruct`
  entry, though its typespec is a bare map (`%{optional(String.t()) => Decimal.t()}`, never
  `| nil`) and its own moduledoc states "empty means the venue does not break the position
  down" — a promise only true if `%{}` is what a caller actually gets.** Both an omitted
  `:by_provider` and an explicit `by_provider: nil` produced `%StakingBalance{by_provider:
  nil}`, a value nothing downstream could safely `Map.get/2` or iterate the way the
  typespec promises. `defstruct` now defaults `by_provider: %{}`, and `new/1` normalises an
  explicit `nil` to `%{}` the same way, consistent with `Trade.broken`'s fix above.

- **`DpExchange.Core.Config.resolve_snapshot/3` hardcoded
  `Application.get_env(:dp_exchange_core, key, default)` regardless of what a caller
  passed, despite its own moduledoc claiming it falls back to application env "exactly as
  `get/3` does" — and `get/3` takes `app` as an argument.** A venue package snapshotting
  one of its OWN seams (`DpExchange.Core.Config.snapshot/1`, which is app-agnostic —
  process-scoped overrides are keyed only by `key`) and resolving it inside its own
  GenServer would have had this function consult **Core's** application
  env instead of its own, silently never finding a value its consumer configured no
  matter how it was set. Found with no live caller yet — every known consumer
  (`dp_exchange_schwab`'s poller) reapplies a snapshot with `put_override/2` in a loop
  rather than calling this — so the mismatch between the documented behaviour and the
  hardcoded app went unnoticed. Fixed before a first caller could inherit it.

  **Breaking, in signature only:** `resolve_snapshot/3` is now `resolve_snapshot/4`,
  taking `app` as its second argument (`resolve_snapshot(snapshot, app, key, default)`),
  matching `get(app, key, default)`'s own order. No known caller in any of the five venue
  packages uses this function today, so the practical impact is expected to be zero, but
  a positional call written against the old three-argument form will not compile against
  this version.

- **`Core.Instrument.new/1` built its struct with plain `struct!/2` rather than
  `Types.Validate.new!/3`, so an explicit `symbol: nil` — `@enforce_keys` guards presence,
  not `nil` — built an `%Instrument{symbol: nil}` violating its own `symbol: String.t()`
  typespec, the one field this whole type exists to attach base/quote/status/type to.**
  Every `Core.Types.*` struct already routes its `new/1` through `Validate.new!/3`;
  `Instrument` (outside the `Core.Types.*` namespace, but carrying the identical
  `@enforce_keys`-guards-presence-not-nil shape) did not. Fixed to match the family
  convention.

### Added

- **`Core.AdapterContract` gains assertion 16, "internal wiring" — every internal
  export must have a caller inside the package's own `lib/`, catching the family's
  single most-repeated defect: a mechanism built, documented, and never wired.** Six
  instances in one week, every one shipped green because a test called the function
  directly and coverage stayed high: `rate_limit_blocking` plumbed through
  `Core.HttpClient` but never set by the caller (`dp_exchange_robinhood` issue #16,
  `dp_exchange_webull` issue #23 — three separate option allowlists, a fix stopping at
  the first still passed every test asserting the keyword was present —
  `dp_exchange_coinbase` issue #26); `FrameSender`'s retry path in
  `dp_exchange_coinbase`, reported but never retried (issue #22); `dp_exchange_schwab`'s
  `subscribe_notices/1` facade, discarding `opts[:to]` instead of reaching `Feed`'s
  notice registry; `dp_exchange_schwab`'s `Auth.refresh/2`, zero call sites in `lib/`
  while `Socket` held a token good for 30 minutes and `websockex` reconnected with no
  delay of its own.

  `DpExchange.Core.UnwiredCheck` is the engine: it reads `:xref`'s real call graph
  (`E`, the same OTP tool assertion 7's purity check already reads `imports` chunks
  through), not a grep — a captured `&Mod.fun/1` and a literal `apply(Mod, :fun, args)`
  both count as real usage. Excludes, without a hand-maintained allowlist: the facade
  and fake (`@venue`/`@fake`, already bound for every other assertion), every behaviour
  a module declares (read from its own `:attributes` chunk and that behaviour's own
  `behaviour_info(:callbacks)` — `GenServer`, `WebSockex`, `Supervisor`,
  `DpExchange.Core.Venue`, or any other), `child_spec/1`, `child_spec/2` and
  `start_link/1` on every module regardless of declared behaviour, and every
  compiler-injected export. A default-argument function (`def f(a, b \\ x)`, which
  compiles to both `f/1` and `f/2`) is treated as one unit named at its highest arity,
  wired the moment either arity has a caller from outside the pair — found necessary by
  running this check against real code: `dp_exchange_schwab`'s pre-fix
  `Feed.subscribe/2` and `Auth.headers/1` were each the unused lower-arity half of a
  function whose higher arity every real caller already used explicitly, and reporting
  each arity independently would have flagged both as noise.

  Verified against the real defect: reconstructing `dp_exchange_schwab` at the commit
  before both fixes landed (`c2f19b9`, parent of `09b8d1f` and `bf2e241`), the check
  flags `Auth.refresh/2`, `Auth.needs_refresh?/2` and `Feed.subscribe_notices/2` by
  name, with file and line — the exact mechanisms issue #16/#22's family and the
  Schwab incidents left unwired. Run against all five venue packages as they stand
  today, every one currently has at least one real finding — mostly `def`-exposed
  getters over a module attribute that production code reads directly instead
  (harmless but genuinely dead), plus a few worth a closer look:
  `dp_exchange_webull`'s `MqttPacket.disconnect/0` and `MqttPacket.subscribe/2`, and
  `dp_exchange_schwab`'s `Auth.needs_refresh?/2` and `StreamerProtocol.logout/2` —
  `needs_refresh?/2` remains unwired even after `bf2e241`, which wired `refresh/2` but
  not the function that was supposed to decide when to call it. Fixes are tracked
  separately, per venue.

  Documented in `usage-rules/adapter.md` next to the `rate_limit_blocking` section it
  follows the same shape as.

- **`PollingFeed` gains `:on_notice` — a feed that knows it has delivered nothing now
  says so on a channel a consumer can act on, not only in a log line, per
  DpCryptoManagement's issue #21.** `PollingFeed` already detected this condition and
  named it in its own words — `Logger.warning("... has delivered NOTHING in 154
  consecutive attempts ...")` — and stopped there. Issue #21 was found only because a
  human went grepping logs for that literal sentence; issue #22 took days for the same
  reason on a different venue. A `Logger.warning` is not a signal a supervising process
  can subscribe to.

  `:on_notice` is an injected function, the same shape `:on_refusal` already is, called
  with a `%Core.Notice{kind: :coverage_change}` the instant the feed crosses INTO the
  delivering-nothing state, and a `severity: :info` recovery notice the instant it
  crosses back OUT — a consumer that learns a feed died and never learns it recovered is
  only half-served. `:coverage_change` was chosen over inventing a new kind: it is the
  same kind `dp_exchange_coinbase` uses for the sibling case (a channel subscribe that
  exhausted its retries without ever becoming delivery), and "subscribed intent not
  becoming delivery" is exactly what a feed delivering nothing is. It fires once per
  transition, never once per failed tick and never once per sweep while an outage
  continues — the existing "delivered NOTHING" log line still repeats every sweep by
  design, so a consumer wanting only that repetition still has it; the notice channel is
  additive, not a replacement. `details` carries the feed's `label`, the consecutive
  failure count, and the last error — never a credential or a raw payload;
  `Core.Notice.new/3` refuses credential-shaped keys outright and would raise if it
  carried one.

  Defaults to a no-op, so every existing caller of `PollingFeed.start_link/1` is
  unaffected. Wiring Robinhood's and Schwab's own feeds to fan this out to their
  `subscribe_notices/1` subscribers is a follow-up once this ships — Core has to publish
  first, since both packages depend on it from Hex.

- **`coverage_by_kind/1` — the Core half of splitting `coverage/1` by data kind, per
  DpCryptoManagement's issue #22.** `coverage/1` is correct and unchanged: it counts any
  payload for a symbol as delivering, a `Types.OrderBook` exactly as much as a
  `Types.Quote`. That is why Coinbase's `level2` channel delivering over 11,000 frames for
  406 symbols while `ticker` was dark for all but 5 still reported `coverage/1` as `:stream`
  for all 406 — truthfully, and uselessly, because "one kind dark, another healthy" and
  "everything healthy" produce the identical map. Verified by running it: `coverage after
  ONLY an OrderBook (no ticker quote): %{"XLM-USD" => :stream}`. See
  `docs/design/2026-09-05_coverage-by-data-kind.md` for the fuller account, including why
  the consumer's own two proposed fixes (`:subscribed_pending`, a `delivering/1`
  companion) would not have caught this: both split subscribed from delivering, and this
  defect was never about that axis.

  `@callback coverage_by_kind(keyword()) :: %{Capabilities.data_kind() => %{symbol() =>
  route()}}` reuses the existing `data_kind()` vocabulary rather than inventing a parallel
  one, and is added to `Venue.@optional_callbacks` **required to be optional**: a venue
  package depends on Core from Hex, so a required callback here would mean every venue
  instantly failing completeness the moment this version publishes — the exact cross-repo
  coupling that caused a premature-deploy incident once already and delayed the
  `:gfw`/`:gfm` wiring behind a Core release before that. `required_callbacks/0` is
  unchanged; `peripheral_endpoints/0` classifies it irreplaceable and not load-bearing.

  `AdapterContract` gains assertion group 15, asserted **only** when a venue exports the
  callback (`Code.ensure_loaded?/1` then `function_exported?/3` — the former is what stops
  the latter spuriously reporting `false` for a merely-unloaded module): the union of
  symbols across every kind must equal `coverage/1`'s own key set exactly, and every kind
  key must be one the same venue's own `capabilities().streamable` declares. An absent
  callback asserts nothing — a venue that has not adopted yet is not a failure, and the
  moduledoc says so in the `if` guard's own comment so nobody "fixes" it into a hard
  requirement later. `ReferenceVenue` deliberately does not implement it, so Core's own
  conformance run (`AdapterContractTest`) is the regression proof that the suite stays
  green against a non-adopting venue; three fixtures in `contract_teeth_test.exs` replicate
  the assertion's exact computation against a conforming fake and two deliberately broken
  ones (a union that drops a symbol, a kind not declared in `streamable`), the same pattern
  assertions 1, 4 and 12 already use in that file.

  The moduledoc's own group count was wrong before this landed — it said "Thirteen groups"
  while `assertions/0` already listed fourteen, a drift caught while adding the fifteenth.
  Corrected alongside every other place in this repo that names a callback or assertion
  count (`README.md`, `usage-rules.md`, `usage-rules/adapter.md`, `usage-rules/testing.md`,
  `usage-rules/feeds.md`, `docs/guides/building-an-exchange-package.md`) — 87 callbacks
  became 88, fourteen assertion groups became fifteen.

  `usage-rules/feeds.md` and `usage-rules.md` both document the failure this callback
  exists to make visible, not only the callback's shape — a consuming agent reading either
  now learns that `coverage/1` alone cannot distinguish a half-dead feed from a healthy
  one, which is the whole reason this shipped.

  Venue adoption (Coinbase, Gemini, Webull, Schwab, Robinhood) is tracked separately in
  the design doc's checklist and is not part of this change — Core ships first, by design.

- **`Types.OrderBookDelta` — the Core half of "packages pass streamed data on; they do not
  maintain books", per `docs/design/2026-09-06_stop-maintaining-books-in-packages.md`.**
  `Types.OrderBook` is a full, sorted snapshot and Core had no incremental type at all, so a
  venue streaming deltas had exactly one option: fold every one into a book it held itself
  and hand the whole thing back. `dp_exchange_coinbase`'s `Socket` did this — a full book per
  symbol, measured at ~22,800 bid and ~21,100 ask levels for `BTC-USD` on a consumer's live
  node, rebuilt on every `l2_data` frame, inside a socket process that was starving its own
  `:send_timeout` because it was never idle. That was market state duplicated in the one
  place that could least afford it, while the host receiving it was already streaming the
  same data into its own store.

  `OrderBookDelta` carries `symbol`, `levels`, the venue's own `timestamp`, its `sequence`
  where it publishes one (`nil` where it does not, exactly as `OrderBook`'s does) and
  `provider`, with a validating `new/1` built on `Types.Validate` like every other type in
  the directory. `levels` is `[{side, price, quantity}]` — `OrderBook.level/0`'s
  `{price, quantity}` pair with the changed side prepended — kept as one flat list in the
  venue's own order rather than split into per-side lists, because a single delta frame
  changes both sides in one venue-ordered message and splitting it would either drop that
  order or invent one never sent. **A `quantity` of zero means the level ceased to exist, not
  a price of zero — carried through unchanged, never resolved here**, exactly the meaning
  already documented at Coinbase's own `apply_book_row/2`.

  This does not reintroduce the incident that made `Socket` build a book in the first place —
  a caller reading one `l2_data` delta as though it were the whole book "would see a handful
  of prices and nothing else." The fix is the distinct type, not accumulated state: a caller
  cannot mistake an `%OrderBookDelta{}` for an `%OrderBook{}`, because the struct name says
  which one it is holding.

  **`:order_book` stays the right `data_kind()` for a delta stream — no new kind was added.**
  `coverage_by_kind/1` answers "which kind of data is arriving", not "in what shape"; a host
  asking whether book data is arriving does not care whether the next message is a snapshot
  or a delta, and the struct type itself is what already tells a caller which shape it holds.
  Adding a kind is not free — it is a closed vocabulary every venue declares against — and
  this distinction was never what `coverage_by_kind/1` was built to make.

  **Reconnect reconciliation is now the host's job, documented rather than left inferred**
  (`usage-rules/feeds.md`, new "An order book stream delivers deltas, not a maintained book"
  section): a package holding no book has nothing to wipe on reconnect, so the fact that
  deltas after one are not contiguous with deltas before it is now visible instead of
  silently absorbed. The existing `:link_down`/`:link_up` notices bracket where the gap
  falls, and `:sequence` on both types lets a host confirm contiguity — consistent with this
  family's existing rule that a notice is a prompt to re-read, never the record: the correct
  response to `:link_up` is to re-pull `get_order_book/2` and resume from there, not to keep
  applying deltas across a gap nothing can fill back in.

  **This is additive to Core** — nothing existing changes shape. It exists to *enable* a
  breaking change in `dp_exchange_coinbase`, tracked separately: that package will stop
  building and delivering a full `OrderBook` per delta and start passing `OrderBookDelta`
  straight through, once it depends on this version.

### Fixed

- **Six false claims in shipped documentation, corrected against the code.** Nothing tests
  prose, and all six were the same shape: a statement about the family that was true when it
  was written and rotted silently.
  - `usage-rules/testing.md` and `docs/guides/building-an-exchange-package.md` both said the
    conformance suite has **fifteen** assertion groups. It has had **sixteen** since
    assertion 16 ("internal wiring") landed, as `assertions/0` and `AdapterContract`'s own
    moduledoc already said. The identical drift is recorded once before, at fourteen.
  - `usage-rules/feeds.md`'s per-venue table had three of five `streamable` rows wrong:
    Coinbase is `[:quotes, :order_book]` (not `[:quotes]`), Webull is
    `[:quotes, :top_of_book, :trades]` (not `[:quotes]`), and Robinhood is `[:top_of_book]`
    — deliberately **not** `[:quotes]`, because that venue publishes no last-trade data to
    poll for.
  - `usage-rules/money-movement.md` showed Coinbase as a blank row. `transfer_internal/4`
    is live there, and so are `list_payment_methods/2` and `get_payment_method/3`; only
    withdrawal and everything around it is `:unsupported`. "Gemini is the only venue that
    moves money through its API" is now stated as what is actually true — the only one whose
    API moves funds **off** the venue.
  - `Capabilities`' `supports_order_preview` comment said only Schwab declares it. Coinbase
    and Webull declare it too.
  - `docs/guides/building-an-exchange-package.md` said no venue checked so far has a working
    sandbox. Gemini's does, and `usage-rules/environments.md` has said so, measured, since
    2026-08-28.
  - `docs/reference/core/negative-claims.md` said Core makes no claim about what a venue
    serves. Four of its shipped tables do exactly that, unchecked by any test; the audit
    section now names them as the place a venue fact goes wrong in Core.

- **The `nil`-vs-absent `Keyword.get` trap, closed as a class rather than one incident at a
  time (C1).** `polling_feed.ex`'s `:start_delay_ms` already carried a fix and an incident
  comment; the same trap was open at every other default-bearing option in `PollingFeed`,
  `HttpClient` and `DefaultRateLimiter` — reachable because every venue forwards its own
  `opts` unchanged by family convention, so a key the caller never set arrives as `key: nil`
  rather than absent, and `Keyword.get(opts, key, default)` only substitutes `default` for
  an ABSENT key. `interval_ms: nil` crashed `Process.send_after/3` and restarted the feed
  straight into the same crash; `on_refusal: nil` raised `BadFunctionError`; `symbols: nil`
  raised inside `MapSet.new/1`. **`HttpClient`'s `retry_attempts: nil` was worst**: Erlang
  term ordering sorts `nil` above every integer, so `nil > 1` is `true`, and a forwarded
  `nil` silently entered the retry branch and died computing `4 - nil` — an `ArithmeticError`
  raised directly in the *calling* venue process, which this library does not supervise.
  Fixed with one shared helper, `DpExchange.Core.Config.opt/3`, applied at every reachable
  site across the three modules (not only the four originally named) — a present-and-`nil`
  value is now treated the same as an absent one everywhere a default applies, and an
  explicit `false` is still honoured, because `opt/3` deliberately does not use `||`.

- **`PollingFeed` — a hung fetch wedged the entire feed, silently (C2).** `fetch`/`fetch_all`
  ran synchronously inside `handle_info` with no timeout boundary; `safely/1` caught a raise
  or an `exit`, not a call that simply never returns. Verified with a fetcher doing
  `Process.sleep(:infinity)`: `status/1` and `coverage/1` never answered, every symbol went
  dark, and nothing was logged — which defeats this module's own headline design, since its
  moduledoc exists specifically to make a silently-broken feed loud. Every fetch now runs
  inside a bounded, disposable `Task` (`bounded_fetch/2`, `Task.async` + `Task.yield` +
  `Task.shutdown`), and a hang past `:fetch_timeout_ms` becomes an ordinary fetch failure —
  retried next tick, counted toward `failures_since_ok`, escalated by the existing "delivered
  NOTHING" warning. The default timeout is derived from the poll interval and clamped
  between 30s and 60s: a floor above `HttpClient`'s own 30s per-request default, so a short
  interval cannot self-sabotage an entirely ordinary retrying HTTP call, and a ceiling so a
  venue polled once an hour cannot wedge this feed for an hour.

- **`DefaultRateLimiter` — `timeout: nil` silently disabled the wait ceiling (C3).**
  `acquire/3` read `:timeout` with a plain `Keyword.get/3`, so a forwarded
  `timeout: nil` — reachable from `HttpClient`, whose `limiter_opts/1` forwards `:timeout`
  verbatim — produced `wait_ms > nil`, which Erlang term ordering makes **always false**.
  "Fail closed after N ms" silently became "wait however long it takes". Verified live
  against an exhausted bucket. Covered by the same `DpExchange.Core.Config.opt/3` fix as
  C1, and asserted with its own regression test: an exhausted bucket with `timeout: nil`
  now refuses near-instantly (the refusal is decided on the server, before any sleep)
  rather than sleeping out a near-minute wait in the caller.

- **`HttpClient` under-recorded real venue usage (C4).** `record/3` — the call that fills
  the bucket `acquire/3` and `check/3` measure against — was only reached from the
  `{:ok, response}` branch of the request pipeline. A retried 5xx and a venue 429 both
  genuinely reached the wire and genuinely consumed the venue's quota, and neither was
  recorded — the same mechanism as the incident already recorded in this module's own
  moduledoc ("395 calls per 60s against a documented 300, while the budget panel read
  83/240"): the missing calls there were exactly the retried and rate-limited ones this
  closes. Every outcome of a request that actually reaches `make_http_request/5` — success,
  retry, 429, or a permanent 4xx — is now recorded exactly once, right after the request is
  made and before the result is inspected; a request refused by the limiter itself, before
  anything left the process, is still not recorded.

- **`Types.*` — `@enforce_keys` guarded presence, not `nil` (C5).** `%Candle{open: nil, high:
  ..., low: ..., close: ..., ...}` built without complaint despite `open`'s typespec
  declaring `Decimal.t()`, never `Decimal.t() | nil` — exactly what a JSON decode bug on a
  renamed venue key produces, and the failure only surfaced later, deep inside `Decimal`,
  far from where the bad data entered. Every `Types.*` module now exposes a validating
  `new/1`, built on a new shared helper, `DpExchange.Core.Types.Validate`, that checks every
  field named in the module's own `@enforce_keys` for `nil` as well as presence and raises
  `ArgumentError` naming the offending field. `Types.Order` is the one deliberate exception:
  its own moduledoc documents that six of its seven enforced keys legitimately admit `nil`
  ("the venue's word, or nothing"), so its `new/1` narrows the check to `:provider` alone,
  the one field that was never meant to be `nil`. Struct literals (`%Candle{...}`) are
  unchanged and remain valid for internal and test use; `new/1` is the path a venue's own
  decoder should prefer.

- **`CanonicalPair` trusted caller-supplied quote ordering (C6).** The moduledoc requires a
  venue's `quotes` list to be given longest-first; nothing enforced it, and the module's own
  round-trip invariant does not catch a misordering — concatenation round-trips
  byte-for-byte regardless of where the cut landed. Verified: `quotes: ["USD", "BUSD"]`
  mis-split `"ETHBUSD"` into `"ETHB-USD"`. `quotes` is now sorted by length, descending,
  inside `CanonicalPair` itself before any suffix match is attempted, so a caller cannot get
  the ordering wrong any more, whatever order it hands in.

### Added

- **`time_in_force` vocabulary extended with `:gfw` and `:gfm` — "good for week" and "good
  for month" (C7).** Real Robinhood values, confirmed in the vendor's own OpenAPI schema
  (both the order request and response schemas, enum `["gtc","gfd","gfw","gfm"]`), with no
  slot in this contract's vocabulary before now. Purely additive: existing venues declaring
  a subset of `supported_time_in_force` are unaffected. Robinhood could not use the new
  values until this shipped to Hex, so wiring `Robinhood.to_order/1` and `order_config/2`
  was sequenced as a follow-up rather than done in the same batch — the cross-repo atom
  coupling is what caused a prior premature-deploy incident. That follow-up has since
  landed: `dp_exchange_core` 0.1.45 published these atoms, and `dp_exchange_robinhood`
  now decodes all four vendor values and raised its dependency floor to `~> 0.1.45` so it
  cannot compile against a Core lacking them.

- **`DpExchange.Core.FakeInjection` — deterministic failure injection and a
  credential-free wiring mode for a venue's `Fake` — DpCryptoManagement's issue #14.**
  None of the four venue `Fake`s exposed a `configure/1`-shaped seam for exercising a
  consumer's own retry/circuit-breaker code, or a way to skip a `Fake`'s venue-faithful
  credential check to test pure dispatch/decode logic. Built on `Core.Config`'s existing
  process-scoped override machinery rather than a new mechanism — the exact `async: true`
  isolation guarantee every other seam in this family already has.

  Deterministic by design: outcomes are queued explicitly and popped in order, never a
  probability. Per-symbol targeting composes with whole-call injection — a
  symbol-specific queue is checked first, and a symbol-targeted failure can never affect
  a different symbol's call, matching this family's established rule that one bad symbol
  must not fail a whole batch. Function-level targeting was deliberately left out: the
  feature this replaces asked for one global knob, and no filed need asked for more.

  This ships the shared mechanism only; the four `Fake`s adopt it one at a time in their
  own packages, starting with Robinhood. See
  `docs/design/2026-09-04_webull-sharding-and-fake-injection.md` §3.6/§3.7.

- **The conformance suite now asserts coverage rather than accepting it as a claim** (O4).
  Three new assertions, and the one worth naming exists because the drift it hunts had just
  happened: a venue package declared six streamable kinds while its socket was written,
  tested and **never called by the facade**. Four of the six reached no subscriber by any
  route, and every test passed for a release — the socket's own tests exercise its callbacks
  directly, and nothing asked what a consumer receives.

  - **Every absence has a recorded cause.** An endpoint named in `venue_does_not_serve/0`
    must actually be declared `:unsupported`. The mislabel goes both ways and both are
    defects: a venue's own absence filed as a backlog item invents work that cannot be done,
    and a backlog item filed as the venue's absence hides a capability a consumer could have
    had. **Robinhood shipped four of the first kind and no test failed** — nothing fails when
    a comment is wrong.
  - **`streamable` names only kinds this contract has a word for.** A structural check cannot
    prove delivery, but it can refuse a vocabulary the contract does not define, which is
    where over-declaration usually starts.
  - **A streamed kind is not contradicted by its own package.** A kind declared streamable
    while the same package's `venue_does_not_serve/0` says the venue has no such data at all
    is a contradiction that cannot be true in either direction.

  All five venue packages pass the three today; they were run against each before this
  landed.

### Fixed

- **`Notice.reject_credentials!/1` could exhaust the VM's atom table from venue-derived
  input (C8).** It normalised every `details` key with `String.to_atom/1` before comparing
  it against the credential vocabulary. Atoms are never garbage collected and the atom
  table is finite; `details` maps are built by venue packages from venue-supplied content
  (a channel name, a raw payload key, a symbol) with nothing in the contract bounding their
  keys, so a venue varying that content could walk the table to exhaustion and kill the
  whole node — through a guard whose entire purpose is to make notices safe. Fixed by
  deriving a string set from `@credential_keys` once, at compile time, and comparing every
  incoming key as a downcased string; no atom is ever created from caller input. Same
  `DOS.BinToAtom` class `Core.FakeInjection` was already built to avoid. The raised error
  still names the offending keys exactly as before.

- **`PollingFeed` crashed when a caller forwarded `start_delay_ms: nil`.** Robinhood's and
  Schwab's own `Feed` wrappers both build this option with
  `Keyword.get(opts, :start_delay_ms)` and no default of their own — a present key with a
  `nil` value whenever their caller never set one. `Keyword.get/3`'s own default only
  substitutes for an ABSENT key, not a present-and-nil one, so `state.start_delay_ms` ended
  up `nil` and crashed in `Process.send_after/3`. Fixed at this layer with `|| @default`,
  so every venue's `Feed` is covered rather than each patching its own pass-through.

- **A stray zero-byte `lib/dp_exchange/x.new` was shipping in the tarball.** It arrived as a
  redirect artefact in `cf03c21` and had been published in every release since. Found by
  doing what `mix.exs`'s own comment block says to do — inspecting `mix hex.build` output
  before publishing — which is the same check that caught the 4.4 MB PLT. Nothing warns about
  either; the only defence is reading the file list.

### Documentation

- **Three new guides, and the first is the one this plan most needed.**
  `usage-rules/auth.md` states the split once, plainly — **storage is the host's, *use* is
  the package's** — and then does the thing nothing in the family did: **a per-venue table**.
  Schwab is three-legged OAuth with a one-time-use refresh token on a seven-day sliding
  window; Gemini is HMAC *or* OAuth, sharing a refresh URL with the host's own code exchange
  and separated only by `grant_type`; Coinbase and Robinhood are Ed25519; Webull has two
  token systems, one of which returns `200` with a token that does not work until a person
  enters an SMS code.

  A host integrating two venues implements two different things, and until now nothing said
  so. It also carries the **restart-versus-refresh** decision table: a host that does not
  know that distinction loses sessions silently and has no operator action available.

- **`usage-rules/money-movement.md`** — the group where a defect moves funds, and the only
  one that can never be tested here. Preconditions in order, with the reason each is not
  style advice: the network is required and never defaulted because funds sent to a chain the
  venue does not credit are gone; `memo_required: nil` means the venue did not say, not that
  no memo is needed; a retry without an idempotency key withdraws twice, which is why this
  family always sends one rather than waiting to be asked.

- **`usage-rules/environments.md`** — running live and demo in one supervision tree, resolved
  **per process** rather than per node. Records what each venue actually offers: Gemini's demo
  is a full exchange with test funds, Webull's UAT has REST and **no broker at all**, and the
  other three have nothing.

- **The four existing guides are rewritten around the surface that shipped.** `feeds.md` now
  covers four pushing venues and one polling behind the same facade; `symbols.md` covers
  venues whose symbol is not a pair, where the work is refusal rather than transformation;
  `testing.md` states which of the four tiers each capability group can actually reach, and
  which cannot be reached at all; `adapter.md` covers the options surface, the two-list split
  for absences, and the negative-claim audit as a required artefact.

- **`docs/reference/core/negative-claims.md`** — Core's negatives are about the contract and
  the ecosystem rather than a venue, and they are audited the same way. Every one holds. The
  packaging claim needed correcting: 7.5 MB of saved Schwab portal HTML sat in `docs/guides/`,
  which **is** in `files:`, and would have published inside a package whose whole premise is
  that it ships nothing venue-specific.

- **`README.md` states what the contract covers** — 87 callbacks by group — and indexes the
  seven guides. `AGENTS.md` points at them.

### Added

- **`place_orders/3`** — several orders in one request, which closes OQ8.

  **It is not `place_order/3` in a loop.** A batch is one request the venue accepts or
  rejects as a unit; N calls are N partial outcomes a caller has to reconcile, and the
  reconciliation is exactly what goes wrong when the third of five fails. A venue that
  publishes a batch endpoint gives a consumer an atomicity it cannot build from the
  single-order call, which is why this is a callback rather than a helper a consumer writes.

  **A partial batch is the shape to expect, not the exception.** Venues validate per order
  and return per order, so the result is a list the same length as the request — each entry
  either an order or the venue's refusal of that one. Collapsing it into a single ok-or-error
  is the failure this callback is documented against: a caller told "the batch failed" when
  four of five were placed has four positions it does not know about.

  Venues cap the size — Webull at 50 — and a request over the cap is refused by the venue
  rather than split by a package. Splitting turns one atomic request into several and quietly
  undoes the only reason to call it.

### Changed

- **`Types.Order`'s `:symbol` and `:id` now admit `nil`**, joining the four that already
  did.

  Robinhood acknowledges a cancel request without describing the order it cancelled: there
  is an id and nothing else. Inventing a symbol to satisfy a type would put a guess where
  the venue was silent, which is the one thing this type's enforced-but-nullable keys exist
  to prevent. The keys stay enforced so a constructor must decide; the types admit `nil` so
  the decision can be "the venue did not say".

- **`asset_classes/0`'s vocabulary widened** from `[:crypto, :equity]` to
  `[:crypto, :equity, :option, :future, :event_contract]`, and the conformance suite's
  known-classes assertion with it.

  The narrower list was not a decision about scope — it was the set of classes any package
  had reached so far, frozen into an assertion. The first package to serve option endpoints
  could not declare it without failing conformance, and **a class a venue serves but cannot
  declare is a class the host cannot route to.** `asset_classes/0` is a statement about a
  package today; the contract now says so where it is declared.

### Added

- **`place_orders/3`** — several orders in one request, which closes OQ8.

  **It is not `place_order/3` in a loop.** A batch is one request the venue accepts or
  rejects as a unit; N calls are N partial outcomes a caller has to reconcile, and the
  reconciliation is exactly what goes wrong when the third of five fails. A venue that
  publishes a batch endpoint gives a consumer an atomicity it cannot build from the
  single-order call, which is why this is a callback rather than a helper a consumer writes.

  **A partial batch is the shape to expect, not the exception.** Venues validate per order
  and return per order, so the result is a list the same length as the request — each entry
  either an order or the venue's refusal of that one. Collapsing it into a single ok-or-error
  is the failure this callback is documented against: a caller told "the batch failed" when
  four of five were placed has four positions it does not know about.

  Venues cap the size — Webull at 50 — and a request over the cap is refused by the venue
  rather than split by a package. Splitting turns one atomic request into several and quietly
  undoes the only reason to call it.

- **Three more account-and-funding callbacks**: `get_payment_method/3`,
  `get_notional_balances/3` and `list_custody_fees/2`.

  **`get_payment_method/3` exists because a listing is a snapshot.** A funding source's
  verification state changes without the account doing anything — a bank closes, a card
  expires, a venue suspends a rail. Picking the row out of an earlier
  `list_payment_methods/2` result reads a status that may have been true an hour ago, and
  moving fiat against it is the failure that produces.

  **`get_notional_balances/3` is not `get_balances/2` in another unit.** The quantity is the
  venue's ledger; the notional figure beside it is the venue's *valuation* of that quantity
  at a rate the venue chose and does not have to publish. Two venues will disagree about the
  notional value of the same holding and both be right about the balance. Rows stay the
  venue's own maps so the two numbers cannot be read as one — the valuation is the one that
  is only ever an estimate. Reconcile positions with `get_balances/2`; this is for reporting.

  **`list_custody_fees/2` explains a balance reduction with no trade behind it.** Custody
  fees are periodic and come straight out of the balance, so a consumer reconciling against
  fills alone finds a gap it cannot account for. An empty list means the venue charged
  nothing in the window asked for — it never means the venue does not charge. A venue with
  no custody product returns `{:error, :not_supported}`, which is what tells the two apart.

- **Six money-movement callbacks**: `list_payment_methods/2`, `add_payment_method/2`,
  `transfer_internal/4`, `request_approved_address/4`, `remove_approved_address/3` and
  `get_transactions/2`.

  **`transfer_internal/4` is not `withdraw/5`.** Nothing leaves the venue, no chain is
  involved and no address is required. Conflating them is dangerous **in both directions**:
  a caller reaching for `withdraw/5` for an internal move pays a network fee it did not need
  to, and one reaching for this expecting an external transfer sends nothing anywhere.

  **`request_approved_address/4` is the most consequential write in this contract** — an
  address on the allowlist is one funds can be sent to. It *requests* rather than grants:
  venues hold new entries under a time lock, and **a successful response is not permission
  to withdraw**. Removal is separate and generally immediate, which is the asymmetry to
  expect — a venue is slow to widen what funds may reach and quick to narrow it.

  **A payment method being listed does not mean it is usable**, and a newly added one is
  pending: venues verify a bank account out of band and the API call only starts that.
  `details` stays the venue's own shape, because bank details differ by country and a
  normalised struct would be wrong for every country but one.

  **`get_transactions/2` is wider than both `get_trade_history/2` and `get_transfers/2`** —
  fees, interest, dividends and adjustments alongside deposits and fills. Summing it is not
  a balance; `get_balances/2` is the authority and this is the explanation.


- **`list_networks/2` and `list_fee_promos/1`.**

  **`list_networks/2` is what `get_deposit_address/3` needs before it can be called.** That
  callback takes a network, and nothing else in the contract said which networks a venue
  accepts for an asset. **Guessing one produces an address on a chain the venue does not
  credit, and funds sent there are gone** — the single most expensive mistake available in
  this surface. It answers both directions, because venues publish both and they are
  different questions: which networks carry an asset, and which assets a network carries.

  Rows stay the venue's own maps. **Network naming is not standardised** — one venue's
  `ethereum` is another's `ERC20` — and normalising here would invent a vocabulary no venue
  accepts back.

  **`list_fee_promos/1` is not `get_fees/2`.** That returns the schedule applying to a
  credential; this is a public list of symbols where the venue charges something other than
  its published schedule. A caller computing cost from the schedule alone is wrong for
  exactly the symbols on this list.


- **`get_fx_rate/3` and `Types.FxRate`.** Gemini publishes `GET /v2/fxrate/{pair}/{ts}` and
  the family had no shape for it.

  **It is not a rate the venue trades at.** Gemini's own documentation says it *"does not
  offer foreign exchange services"* and that the endpoint is *"for historical reference
  only"*; the number comes from a third party the venue names. So `:source` and `:benchmark`
  are carried alongside the rate, and `:provider` — the venue relaying it — is a **separate
  field**. Collapsing them would make a Gemini-relayed BCB rate indistinguishable from one
  Gemini computed itself, and only the second would be the venue's own claim. **Two venues
  relaying the same pair at the same instant can legitimately disagree**, and a caller
  reconciling them needs to know it is comparing sources rather than finding a bug.

  `:as_of` is the instant asked for, echoed by the venue. A rate without it is a number with
  no time attached, which is not a rate.


- **`get_trades/2` — the public tape.** `Types.Trade` already existed and nothing could
  return it; two venues publish the tape and the family had no callback for it.

  **It is not `get_trade_history/2`**, which returns the credential's own fills. The tape is
  everyone's executions and has no order of yours behind it — answering one with the other
  hands a caller a filtered view of the market and calls it the market.

- **`Types.Trade` gains `:broken`, defaulting to `false`.** Exchanges bust erroneous prints,
  and **a broken trade did not stand**: its price is not a price the market traded at.
  Leaving one in a series puts a phantom high or low into every range, breakout and
  volatility figure built on it, and none of them will error. `get_trades/2` excludes them
  unless `opts[:include_broken]` says otherwise — hiding them entirely would conceal that
  the exchange made a correction.

  The moduledoc now also records what `:side` means: venues report **the taker's** side, so
  Gemini's `buy` means an ask was removed by an incoming buy order. A package mapping that
  to "the maker was selling" inverts every entry while every number stays real.

- **`get_auction_imbalance/2` and `get_volume_profile/3`, with `Types.AuctionImbalance` and
  `Types.VolumeProfile`.** Two equity-microstructure capabilities Webull publishes that the
  family had no facade or shape for.

  **An auction imbalance is not a quote or a book.** During an auction the continuous book
  stops being the price; what matters is how much can be matched, how much cannot, and
  where it would clear — three numbers a `Quote` has nowhere to put. A caller reading a
  continuous quote at 15:59 is reading a book that is not where the close will happen.
  `opts[:auction]` is required, because the opening and closing auctions are different
  auctions with different windows.

  **The imbalance side is carried as the venue sent it, unmapped.** Venues publish the
  direction as a code and the tables differ — Webull documents `imbalance_side` with the
  example `"2"` and does not say what 2 means. Guessing it backwards tells a caller there
  is unmatched buying when there is selling: wrong, entirely plausible, and at the one
  moment of the day with the most volume behind it.

  **A volume profile is not a candle with extra fields.** A candle's single volume number
  cannot say that of 1,000 shares 600 lifted the ask and 400 hit the bid, nor at which
  prices each happened, and neither type is derivable from the other. `:delta` is the
  venue's own figure and is **not** recomputed from the totals: a venue that classifies
  some prints as neither aggressive buy nor sell reports numbers that do not reconcile, and
  that gap is information about its classifier rather than a fault to paper over.

  **`get_auction_imbalance/2` returns a list**, newest first, because the venue publishes a
  *series*: the imbalance updates every few seconds through the auction window, and how it
  moved is the point. `opts[:history]` selects the published series where a venue serves
  the snapshot and the series separately — the same shape `get_orders/2` uses for resting
  versus closed orders. **A series entry may carry less than a snapshot**: Webull's NOII
  bars publish the three prices and the time and *not* the quantities or the side, which
  come back `nil` — the venue did not publish them there, rather than the imbalance being
  zero.


- **`:event_contract` in the instrument-type vocabulary.** Webull lists event contracts as a
  tradable instrument type and the vocabulary had no term for one, so a package serving them
  had to declare something untrue.

  **It is not an option and not a future.** There is no strike, no underlying to deliver,
  and the payoff is a step at 0 or 1 rather than a curve — declaring one as `:option` would
  hand a caller a Greeks-shaped hole where the instrument has no Greeks.

- **`convert/4` and `get_trade_volume/2` on `Venue`.** Two more Gemini endpoints with no
  facade.

  **`convert/4` is not a shorthand for `quote_conversion/4` plus `commit_conversion/2`,
  and the difference is who carries the price risk.** The two-step form shows a rate and
  holds it: the caller sees the number before anything moves. `convert/4` executes at
  whatever the venue's price is on arrival and the caller learns the rate from the result.
  A package cannot manufacture the first from the second — quoting a rate it computed
  itself and calling it held would be a promise the venue never made — so a venue declares
  each independently. Gemini's `/v1/wrap/{symbol}` is the one-step form.

  **`get_trade_volume/2` is the account's own volume, not the market's**, and not
  `get_trade_history/2` summed. The venue's aggregation is what its fee tiers are computed
  from; reproducing it means every fill over the reporting window — one request per symbol
  on a venue that requires one — and the result would still be this package's arithmetic
  rather than the venue's ledger. Where they disagree, the venue's decides what a caller
  is charged.

- **`cancel_all_orders/2` on `Venue`.** Gemini publishes two bulk cancels and the family had
  no facade for either.

  **`opts[:scope]` is required and has no default.** `:session` cancels what this
  credential's session opened; `:account` cancels everything the account has open,
  including orders placed by another key or by a person at the venue's own web interface.
  A default would make the wider, destructive reading the answer to a question nobody
  asked, and the narrower one would silently leave orders running. The caller states it.

  It is not `get_orders/2` plus `cancel_order/3` in a loop: that is N requests with N
  partial outcomes and cannot reach an order that appeared between the listing and the
  cancels.

  Returns `%{cancelled: [id], rejected: [id]}`. **A non-empty `rejected` is not a failed
  call** — the venue answered and some orders were already gone.

- **`preview_replace/4` and `close_position/3` on `Venue`.** Both are Coinbase endpoints
  the family had no facade for, and both are the kind that cannot be assembled from the
  calls that already exist.

  **`preview_replace/4` is not `preview_order/3` with an order id.** The venue prices an
  amendment against the resting order's own state, including whatever of it has already
  filled. A caller who asks what a fresh order would cost is asking a different question
  and getting a different number. Without it the choice is committing to an irreversible
  amendment blind, or cancel-then-place — which reopens the window `replace_order/4`
  exists to close.

  **`close_position/3` is not `get_positions/1` plus `place_order/3`.** The size a caller
  computes is the size as of the caller's last read; the venue's is the size now. On a
  position that moved in between, the caller's arithmetic leaves a residue or overshoots
  into a position the other way. Only the venue flattens to exactly zero, which is why it
  returns an `Order` — it *is* an order, placed on the caller's behalf with a side and size
  the caller never states.

  Both are peripheral, both record which of the two tests they fail, and every venue that
  does not serve them returns `not_supported()` as before.

### Changed





- **`Types.Order`'s `side`, `order_type`, `quantity` and `status` admit `nil` in the
  typespec.** They always could in practice — a venue sending a status this package does
  not recognise has produced `nil` since the beginning — and the typespec said otherwise,
  which meant dialyzer accepted the wrong thing and rejected the right one.

  Coinbase's `close_position/3` is where it surfaced: the venue never states the side of a
  closing order, and the type left no way to say so. The keys stay enforced, so a
  constructor must still decide; the types now allow that decision to be "the venue did not
  say".

- **BREAKING: `Core.Types.Quote` no longer carries `:bid` and `:ask`.** They are order book
  data — resting orders — and `Quote` is trade data. Every venue package in the family was
  filling them, and one read `price || ask` from a best-bid/ask endpoint, producing a quote
  whose `price` was a resting order. Every value was real; only the meaning was wrong.

  A caller wanting the top of the book calls `get_top_of_book/2`. A caller wanting what
  traded calls `get_price/2`. Neither can stand in for the other.

- `Core.Types.Quote`'s `:timestamp` guarantee is unchanged and now load-bearing: **the
  venue's own, used as-is**. Observation time lives on `TopOfBook.observed_at`, in a field
  that says what it is.

### Added
- **Options.** `Types.OptionContract` (identity only — no prices), `Types.OptionGreeks`
  (model output, with the theoretical value named `:model_price` because it is the field
  most easily mistaken for a price), `Types.OptionChain` (**two-dimensional**, expiry →
  strike → `{call, put}`, a one-sided strike keeping `nil` rather than a missing key), and
  `Types.OrderLeg`. Callbacks `get_option_chain/2`, `get_option_expirations/2`,
  `get_option_greeks/2`.

  A chain row carrying bid, ask, last, mark and theoretical value offers five plausible
  prices and no help choosing, so it is split three ways: identity here, book on
  `TopOfBook`, last trade on `Quote`. **`:multiplier` of `nil` does not mean 100.** A venue
  that cannot trade multi-leg must **refuse**, never decompose — a caller left holding one
  filled leg has naked risk it never chose.

- **BREAKING: `get_historical_prices/4` returns `[Types.Candle.t()]`**, not
  `[Types.Quote.t()]`. It declared quotes, and the venue packages returned **bare untyped
  maps** with their own key sets — so the declared type was false and nothing compared one
  venue's candles to another's.

  `Types.Candle` names its time field **`:opened_at`**, because venues disagree about
  whether a bar is stamped at its open or its close and the difference is one whole
  interval — a series joined across both conventions is misaligned by a day with every
  value correct. `coherent?/1` catches a malformed bar at the boundary. `:volume` is `nil`
  when unpublished, never `0`.

- **`Types.Order` gains `:time_in_force` and `:legs`.** `Capabilities.supported_time_in_force`
  declared what a venue accepts while the order type had no field for it, so a caller
  reading an order back could not tell an IOC that expired from a GTC still working.
- **Derivatives.** `Types.Funding` (settled `:amount` kept apart from `:estimated_amount` —
  a real response has them 40% apart) and `Types.ContractStats` (mark and index are separate
  prices, and neither is a traded price), with `get_funding/2` and `get_contract_stats/2`.
- **Conversions.** `Types.Conversion` plus `quote_conversion/4`, `commit_conversion/2` and
  `get_conversion/2` — the facade's only two-step write. `:expires_at` is the point:
  committing an expired quote can fill at the *current* rate, which looks like success.
  `expired?/2` returns `nil` when no expiry was stated — unknown, not valid.
- **Portfolios.** `Types.Portfolio` and `list_portfolios/1`. A portfolio is an **address**,
  not a value; balances, orders and positions are addressed with `portfolio: id` in `opts`
  rather than by adding a parameter to forty signatures.
- **Money movement, write side.** `Types.DepositAddress`, `Types.ApprovedAddress`,
  `Types.Withdrawal`, and `get_deposit_address/3`, `list_approved_addresses/1`,
  `estimate_withdrawal_fee/4`, `withdraw/5`.

  **`withdraw/5` is the only operation in this contract that cannot be undone.** The
  allow-list is first-class: `ApprovedAddress.usable?/2` returns `nil` for a pending address
  with no stated activation, because venues delay first use precisely so a stolen account
  cannot add an address and drain it. `DepositAddress.memo_required` is **tri-state** — a
  deposit missing a required memo is credited to nobody, so `nil` must never be defaulted to
  `false`. `:network` is enforced on both.
- **`Core.Types.Position`** and **`get_positions/1`** — exposure, distinct from a balance and
  not derivable from one. `:side` is explicit and `:quantity` always positive, because
  venues disagree about how to say "short" and a guessed sign convention yields a position
  that is exactly backwards while every number stays plausible. Realised and unrealised P&L
  are separate and never summed. **`:liquidation_price` of `nil` means the venue did not
  say, not that the position is safe.**
- **`data_kind` gains `:top_of_book`, `:candles` and `:positions`.** Measured against
  Gemini's AsyncAPI and Schwab's Streamer service list: all three are streamed by a venue in
  the family and had no kind. `:top_of_book` is deliberately not `:order_book` — venues
  stream them on separate channels because one carries a level and the other a book.
  `t:data_kind/0` records the full channel-to-kind mapping so it can be checked rather than
  trusted.
- **Custodial staking.** Six callbacks — `get_staking_rates/1`, `get_staking_balances/1`,
  `get_staking_rewards/1`, `get_staking_history/1`, `stake/3`, `unstake/3` — and a
  `has_staking` capability flag, which earlier notes recorded as shipped and which did not
  exist.

  **Custodial only.** A venue that returns an *unsigned transaction* for the caller to sign
  and broadcast is doing something else, and one venue publishes both. A caller believing it
  had staked when it holds an unsigned transaction nobody signed is the most expensive form
  of this family's recurring failure.

  Four types, shaped by the venues' published schemas:
  - `Types.StakingBalance` — keeps `staked`, `available_to_trade` and
    `available_for_withdrawal` **apart**; a real response has the whole position redeemable
    and none of it tradable. `by_provider` is carried, not summed: a redemption is addressed
    to a provider.
  - `Types.StakingRate` — percentages only, `rate_pct` and `apy_pct` both named. One venue
    publishes basis points, a simple percentage and an APY for the same position;
    `bps_to_pct/1` lives here so the 100× conversion is done once.
  - `Types.StakingReward` — carries its accrual period and the rate *at accrual*.
  - `Types.StakingTransaction` — carries the unbonding progression `amount` /
    `amount_paid_so_far` / `amount_remaining`. **`settled?/1` returns `nil` when the venue
    reports no progress** — unknown, not complete.
- **`Core.Types.TopOfBook`** — best bid and ask, with **no `price` field**. `bid_size` and
  `ask_size` are optional (`nil` means *not published*, never zero); `venue_time` is the
  venue's own or `nil`, since several BBO endpoints publish none; `observed_at` is required.
  `mid/1`, `spread/1` and `crossed?/1` are functions, not fields — a mid is derived, and a
  caller has to ask for it rather than find it sitting there looking like venue data.
- **`get_top_of_book/2`** on the `Venue` behaviour, registered in `peripheral_endpoints/0`.
- **Conformance assertion 14, "top of book is not a price"** — asserts the returned struct
  is a `TopOfBook`, that `observed_at` is set, that `venue_time` is the venue's or `nil`,
  and that `TopOfBook` has no `price` field and cannot grow one.

### Changed
- **`preview_order/3` and `replace_order/4` are now `Venue` callbacks**, and required
  rather than optional. §6.1's rule is that the facade is one fixed set, never extended
  per venue, and optionality is reserved for callbacks where requiring them would be pure
  ceremony. These two are not: whether a venue can preview an order, and whether it can
  amend one atomically, are things a consumer routes on — and `replace_order/4` is a claim
  about **risk**, since its absence means cancel-then-place, which opens a window in which
  no order is live.

  **Not a breaking change, because there is nothing to break yet.** No consumer implements
  this behaviour outside the family, and all five venue packages were updated in the same
  change. A venue that serves neither returns `Venue.not_supported()` and declares
  `supports_order_preview: false` / `supports_order_replace: false`. Once the host adopts
  these packages, adding a required callback *would* be breaking and would take the
  `0.2.0` seed §7.2 describes — that signal is deliberately not spent here.

### Added
- **Five capability fields and two facade callbacks**, closing every contract gap Schwab
  found. Each existed because a venue could not say something true about itself.
  - `ceiling` gained an optional **`:scope`** (`:credential | :account | :application`),
    and `:limit` became `non_neg_integer`. Both matter: a limiter keyed by credential
    **silently over-permits** a venue that counts per account, and a registration granted
    zero throughput is legal and is **not** `:unsupported` — the endpoint exists and the
    venue serves it; that application cannot use it, and the remedies differ.
  - **`supported_sessions`** — which trading session an order may name. `[]` is the
    continuous-market case and stays the default. `[:regular]` alone **raises**: it says
    nothing, and a consumer would build a session selector with one option.
  - **`supports_order_preview`**, **`supports_order_replace`**, **`supports_multi_leg_orders`**
    — all raise if claimed while `place_order/3` is `:unsupported`.
  - **`catalog_access`** (`:enumerable | :query_only`) — whether the catalogue can be
    listed at all. `:query_only` raises if `get_symbols/1` is `:unsupported`, because
    "searchable only" and "not served at all" are different facts.
  - **`preview_order/3`** and **`replace_order/4`** as **required** facade callbacks.
    Required rather than optional: the facade is one fixed set, and optionality is for
    ceremony. Both are peripheral, and `replace_order/4`'s reason states the risk —
    absence means cancel-then-place, which works and opens a window with no order live.
- **Four order types**: `:trailing_stop`, `:trailing_stop_limit`, `:market_on_close`,
  `:limit_on_close`. Real types Schwab accepts that Core had no word for, so a venue
  serving them had to under-declare — the safe direction, and still a lie.
- **Eight instrument types**: `:option`, `:future`, `:future_option`, `:index`,
  `:mutual_fund`, `:bond`, `:forex`, `:cash_equivalent`. `[:spot, :perp]` was the whole
  vocabulary while every venue was crypto; an option is not a spot instrument, so an
  equities broker declared `[:spot]` plus a comment saying that understated it. **A
  declaration that needs a comment to be true is what this struct exists to prevent.**
- Two conformance assertions: the order-shape claims must match what the facade answers,
  and `catalog_access` must match how `get_symbols/1` behaves without a query.

### Documentation

- **`usage-rules/adapter.md` never mentioned `DpExchange.Core.Config.opt/3`,
  `Types.<T>.new/1` or the `:gfw`/`:gfm` addition to `supported_time_in_force` — all
  three shipped in this same
  `[Unreleased]` section (C1, C5, C7 above), and a package author reading only the guide
  that ships in the Hex tarball would never learn any of them exist.** Fixed by adding: a
  "domain vocabularies are closed lists" section naming the full current
  `supported_order_types` and `supported_time_in_force` vocabularies, including `:gfw`/
  `:gfm` and why they were added; a "prefer `Types.<T>.new/1`" section carrying the same
  `@enforce_keys`-guards-presence-not-`nil` explanation the code's own moduledoc gives,
  plus the `Types.Order` exception; and a section on the forwarded-`opts`
  `nil`-vs-absent trap naming `DpExchange.Core.Config.opt/3` as the fix, next to the
  existing "opts is the
  venue's own vocabulary" discussion it extends. Found by auditing this package's own
  consumer docs the same way the family-wide sweep audited the other five packages'.

- **`README.md`'s family table said five of six packages were "not yet published."** All
  six are live on Hex — checked against Hex's package API 2026-09-05, every one of
  `dp_exchange_core`, `dp_exchange_coinbase`, `dp_exchange_gemini`, `dp_exchange_webull`,
  `dp_exchange_robinhood` and `dp_exchange_schwab` returns `200`. Corrected to "published,
  experimental," with a line stating that publication is not proof of maturity — read
  `capabilities/0` for that, not this table.

- **Two stale assertion-count claims.** `usage-rules/testing.md` said "Thirteen assertion
  groups"; `docs/guides/building-an-exchange-package.md` said "28 assertions." Neither
  matches `DpExchange.Core.AdapterContract.assertions/0`, the canonical list the suite's own
  moduledoc points readers to, which currently names 14 groups. Both corrected to cite that
  count and the function that defines it, rather than a number that drifts every time a
  group grows.

## [0.1.11] - 2026-08-31

### Fixed
- **The conformance suite refused `1w` and `1M` too.** `Capabilities.validate_history!/1`
  was fixed in 0.1.10 to check `Timeframe.nameable/0`, but `AdapterContract`'s assertion 2
  still checked `known/0` — so a venue serving weekly or monthly candles built its
  declaration successfully and then **failed Core's own conformance suite**. That is the
  worse of the two failures: the package looks correct right up until the suite it exists
  to satisfy rejects it. Second site of one defect; found running the suite against Schwab.

## [0.1.10] - 2026-08-31

### Added
- `Timeframe.nameable/0` and `Timeframe.nameable?/1` — the widths Core can read as a
  **label**, which is deliberately wider than `known/0`, the widths it can **bucket**.
  `1w` and `1M` are nameable and have no boundary rule, and never will: a weekly bar's
  start depends on which weekday the venue begins its week, and a month is not a fixed
  number of seconds.
- `max_leverage` accepts **`:per_account`** — a positive statement that the venue margins
  and the ceiling belongs to the account rather than to the venue. Reg-T forced it: a
  Schwab margin account carries five different buying powers that are not multiples of one
  another, and a cash account at the same venue carries none of them, so no scalar is true.
  `nil` with `supports_margin: true` still raises, because `nil` means "nobody said" — and
  the error now names `:per_account`, so a venue author discovers the option instead of
  inventing a number. Without it the only ways to ship were to declare
  `supports_margin: false`, which is false, or to invent a multiplier.

### Fixed
- `Capabilities` no longer refuses a venue that serves weekly or monthly candles.
  `validate_history!/1` checked `historical_timeframes` against `Timeframe.known()`,
  which is the set Core can *bucket* — so declaring `1w` raised, even though
  `Timeframe` already documents both as deliberately unbucketable and instructs callers
  to read "no boundary rule" as "cannot check" rather than "invalid". Core contradicted
  itself: `aligned?/2` tolerates an unmodelled width, `boundary/2` passes it through,
  and `Capabilities` rejected it outright. A venue serving a real weekly candle had two
  options, under-declare or not ship. It now checks `Timeframe.nameable/0`; a width Core
  cannot name at all, such as `3m`, is still refused. Found deriving Schwab's
  declaration.
- `Timeframe` now models `10m` (600 seconds). Its absence was **not** neutral:
  `aligned?/2` returns `true` for a width it cannot model — "no rule" must not read as
  "invalid" — so every 10-minute candle passed the authenticity check unexamined, and
  `boundary/2` was a no-op on it. Found deriving Schwab's declaration, where
  `/pricehistory` serves 1, 5, 10, 15 and 30-minute widths. Unlike `1w` and `1M`, which
  are deliberately absent because their boundaries are not fixed, 600 seconds is not
  ambiguous and there was no reason to leave it unmodelled.

## [0.1.9] - 2026-08-28

### Fixed
- `HttpClient.request/5`'s spec no longer advertises `{:error, :rate_limited,
  retry_after: seconds}`. **It never returned it.** Both rate-limit paths convert to a
  two-element error before returning, each deliberately and for a recorded reason — a
  venue 429 because a three-element tuple reaching a two-element `case` crashed 152
  collector tasks in one night, and our own limiter's refusal because the two used to
  share wording and a self-inflicted throttle was read as a flaky venue for weeks. The
  spec was corrected rather than the behaviour. This is the fourth wrong-spec defect
  found by a venue package, and it does the same damage as the others: dialyzer reports
  a caller's correct handling of the advertised shape as unreachable dead code.

### Added
- `HttpClient` accepts `raw_status: true`, returning `{:ok, response}` for a 4xx instead
  of flattening status and body into a message string. The contract makes
  `{:refused, reason}` permanent and `{:error, reason}` possibly transient, and a venue
  states which in its 4xx body — Gemini names `InvalidSymbol`, `InvalidParameterValue`.
  Without this a venue package has to recover the distinction by string-matching, and
  `String.contains?(message, "404")` also matches a body that happens to contain "404".
  Opt-in, because the string form is what existing callers match on. 5xx is unaffected: a
  server error is not a venue's considered answer.
- `Capabilities` ceilings may now carry an optional `:burst` — the depth a venue lets a
  caller run ahead of its rate before queueing. Found by the Gemini extraction: a GCRA
  limiter takes three parameters and this type carried two, so a venue that **publishes**
  its burst depth had nowhere to declare it and the package had to hardcode the number
  beside the declaration — the exact drift the struct exists to prevent. Gemini is the
  first venue in the family to publish one ("a burst rate of five additional requests
  that are queued"). Optional rather than required, because a venue that publishes no
  burst must not be made to invent one, and absence is distinguishable from a declared
  value. A present `:burst` must be a positive integer; zero is a limiter that never
  lets anything through.
- Repo foundation: toolchain pin, `.gitignore`, formatter, credo, license, `mix.exs`,
  config layout, CI workflow, design-docs scaffolding.
