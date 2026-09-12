# What the conformance suite does — and does not — check

**Audited 2026-09-08. Revised 2026-09-11 and 2026-09-12 — see "Second axis", "The sweep
completed", and the two closures below.**
`Core.AdapterContract`'s 19 assertion groups (now **24** — see "Gaps closed" below) have
each caught real, shipped defects within minutes of existing. Nobody had asked the inverse
question: which parts of `Core.Venue`, `Core.Capabilities`, `Core.Notice` and
`Core.PollingFeed` have **no** assertion touching them at all. This is that map, done once
so the next audit starts from it instead of from zero.

> **Read "Second axis — an assertion that exists is not an assertion that runs" before
> trusting any **covered** below.** Every status in this file answers "does an assertion
> exist?". Three venues were later found passing assertions that never executed on them, so
> "covered" and "covered everywhere" are different claims and this file only ever made the
> first.

Status per item is one of:

- **covered** — a real assertion exercises this, behaviourally where a fake makes that
  safe, structurally otherwise.
- **partial** — something checks it, but narrower than the full claim (named below).
- **none** — nothing in the suite touches this at all. Not automatically a gap: several
  of these are deliberate (see "Gaps considered and declined").

## `Core.Venue` callbacks

Grouped by shared treatment rather than one row per callback — most of the 88 share an
identical pattern, and `Venue.peripheral_endpoints/0` already documents per-callback
detail the conformance suite doesn't need to repeat.

### Lifecycle — `child_spec/1`, `start_link/1`

**covered.** Assertion 1 (completeness) requires both exported; assertion 11
(self-sufficiency) checks `child_spec/1` specifically. Neither is "answerable" by calling
it (`child_spec/1` returns a spec, `start_link/1` starts something), so they are exempt
from the agreement checks (12) by design — `answerable?/1` names the exemption.

### Declaration — `provider_name/0`, `runtime_id/0`, `asset_classes/0`, `capabilities/0`

**covered**, with one **partial**. Assertion 3 checks `provider_name/0` is a non-empty
string, `runtime_id/0` is an atom, and `asset_classes/0` is a non-empty subset of the
known classes. `capabilities/0` is exercised hard — see the `Capabilities` section below.

**Partial:** `runtime_id/0`'s own doc says "matching the namespace segment", and the
suite only checks `is_atom/1`. Deliberately not strengthened: checking the match would
require Core to know a venue's package-naming convention, which is exactly the kind of
convention-dependent check `Core.FeedBehaviour` (zero adopters) and the old
`@credentialed` list are the family's own cautionary tales against.

### Market data pull endpoints (the ~45 `result(...)`-returning callbacks)

**covered** for structure, **none** for return-value correctness beyond one callback
(see "return types" below). Every one of these gets:

- assertion 1 — exported if required, present-or-absent-never-half if optional
- assertion 12 — if declared active (or undeclared, which defaults to active), the FAKE
  must not answer `{:error, :not_supported}`; if declared `:unsupported`, the REAL venue
  must answer exactly that atom, never raise
- assertion 17 — on a `credential_benefit: :required` venue, gated ones must refuse the
  fake with credentials stripped (conditional — see its own group)

**Two now have a dedicated behavioural check that nothing else in this family checks
for the rest:**

- `get_top_of_book/2` — assertion 14 checks the fake's `:ok` result is a real
  `Types.TopOfBook` with a `DateTime` `observed_at` and no `price` field
- `get_historical_prices/4` — **new assertion 21** (see "Gaps closed")

### `Core.Types.*` return-value correctness generally — assertion 5

**partial.** `assertions/0` lists "return types — `Core.Types.*` with `Decimal`
numerics and `DateTime` timestamps" as its own numbered claim, and it has no dedicated
describe block. What actually enforces it:

- `Types.Validate.new!/3`, which every `Core.Types.*` constructor routes through,
  enforces field *presence* and (where declared) rejects a `nil` on an
  `@enforce_keys`-guarded field — but this runs when a VENUE calls the constructor, not
  when the SUITE inspects a returned value, so it only protects a venue that used the
  constructor in the first place.
- assertion 14, narrowly, for `get_top_of_book/2` alone
- **new assertion 20**, for `subscribe/2`'s pushed payload alone (any
  `DpExchange.Core.Types.*` struct, not a specific one)

**Considered and declined: a comprehensive endpoint → expected-struct check.** Building
one generically would need a hand-maintained map from every struct-returning callback to
its expected module — the exact shape `@credentialed` was, and the exact shape this
family has already had to replace once because a hand-maintained list rots invisibly.
Deriving it from typespecs was considered and rejected as more machinery than the payoff
justifies for a family this size. `Types.Validate` already closes the highest-value part
of this (presence and `nil`-guarding) at construction time; what remains uncovered is
"did the venue use the constructor at all", which assertion 20 now answers for the one
endpoint where the answer is cheapest to get for free (a fake push, not a fetch).

### `subscribe/2`, `unsubscribe/2`, `update_symbols/2`, `coverage/1`

**covered**, plus **new assertion 20** for `subscribe/2`'s push shape. Assertion 8
("both endpoints answer") requires `subscribe/2` always active — no flag, no exception —
and checks `coverage/1`'s values are one of the three observed-route atoms. Assertion 1
covers presence for all four. Nothing previously checked the SHAPE of what `subscribe/2`
actually delivers — see "Gaps closed".

### `coverage_by_kind/1`

**covered**, and deliberately optional. Assertion 15 runs only when the callback is
exported (it is in `@optional_callbacks`) and checks its symbol union matches
`coverage/1` exactly, and that every kind it reports is one `capabilities().streamable`
actually declares.

### `subscribe_notices/1`

**partial**, and the gap is **declined** — see "Gaps considered and declined" below for
why nothing was added.

### Health — `test_connection/2`, `get_rate_limit_status/2`, `market_status/1`

**covered.** Presence (1), agreement (12), and a scoped credential-gate treatment (17):
`test_connection/2` and `get_rate_limit_status/2` are the ONLY two name-based exemptions
from the gate (their own callback doc types the credential `| nil`), and `market_status/1`
is exempt only on an `asset_classes/0 == [:crypto]` venue — both scoped exactly, with the
full argument recorded in assertion 17's own comment and `usage-rules/adapter.md`.

### `quantization/1`

**covered.** Optional; presence-or-absence-never-half (1), agreement (12) when present.

## `Core.Capabilities` fields

| field | validated by `new/1`? | exercised by `AdapterContract`? |
|---|---|---|
| `endpoints` | shape + maturity vocabulary | 2, 12, 17, 20, 21 |
| `no_venue_contact` | shape + not-also-`:unsupported` | 17 |
| `supported_quotes` | — | 4 (symbol round-trip, generated over this list) |
| `supported_order_types`/`time_in_force`/`instrument_types` | subset of the known vocabulary | none behaviourally — see below |
| `supports_short_selling` / `supports_fractional_shares` | — | none |
| `supports_margin` / `max_leverage` | `validate_margin!/1` — both halves must agree | none behaviourally (no live order to check against) |
| `has_staking` | **new: `validate_staking!/1`** | 2 (re-runs `new/1`) |
| `supported_sessions` | subset + `[:regular]` alone refused | none |
| `supports_order_preview`/`replace`/`multi_leg` | `validate_orders!/1` — true only if `place_order/3` active | 12 ("order-shape claims match") |
| `streamable` / `authenticated_streamable` | subset + superset relationship | 8 (vocabulary + no self-contradiction), 15 (optional cross-check) |
| `historical_timeframes` | `validate_history!/1` — nonempty if history claimed, nameable vocabulary | **new: 21** |
| `credential_benefit` | vocabulary | 17 (drives the whole gate) |
| `public_ceiling` / `authenticated_ceiling` | shape, and `:higher_ceiling` needs both | none behaviourally (would need a live rate probe) |
| `max_candles_per_request` | — | none |
| `reports_trade_volume` | — | none — **not** a claim about `get_trade_volume/2`'s activation (see note) |
| `catalog_size` | vocabulary | none (informational) |
| `catalog_access` | `validate_catalog!/1` — `:query_only` needs `get_symbols/1` active | 12 ("catalog_access matches...") |
| `measured_at` / `measured_against` | — | none (provenance, informational) |

**Note on `reports_trade_volume`:** this was checked as a candidate gap and declined
after reading it wrong once. It reads, from the name, like it should agree with
`{:get_trade_volume, 2}`'s maturity the way `has_staking` agrees with the six staking
endpoints — and `dp_exchange_schwab` declares `reports_trade_volume: true` while
`get_trade_volume/2` is `:unsupported`, which looked at first like the same class of bug
`has_staking` turned out to have on Coinbase. It is not: `dp_exchange_webull`'s own
moduledoc (2026-09-06) confirms the field is about whether **candles and quotes carry a
real venue-reported volume figure**, unrelated to whether the account's own aggregated
`get_trade_volume/2` endpoint is implemented. No assertion was added. The field itself
carries no doc comment in `capabilities.ex` explaining this — worth a documentation fix,
separately from a conformance assertion, so the next person auditing this does not have
to re-derive the same distinction from a venue's moduledoc.

**Fields with no per-field validation and no behavioural check** (`supports_short_selling`,
`supports_fractional_shares`, `max_candles_per_request`, `catalog_size`,
`measured_at`/`measured_against`) are informational Kind-2/Kind-3 declarations with no
paired endpoint to cross-check against, and no defect evidence naming any of them. Left
alone — see "Gaps considered and declined".

## `Core.Notice`

**covered** at construction, **none** behaviourally except one venue's own fixture.
`Notice.new/3` — the only sanctioned constructor — raises on an unknown `kind`, an
unknown `severity`, and any credential-shaped key in `details`. Nothing in
`AdapterContract` calls `subscribe_notices/1` and inspects what arrives; the one place
that happens at all is `ContractTeethTest`'s "it emits notices on its own channel" test,
which runs only against `ReferenceVenue` and is not part of the reusable suite every
venue runs. See "Gaps considered and declined" for why this was not closed.

**Also unchecked, and considered:** nothing stops a venue building a raw `%Notice{kind:
:whatever, ...}` struct literal, bypassing `Notice.new/3`'s validation entirely — the
same class of gap `CredentialRedactionCheck` and `LinkSafetyCheck` close for other
structural properties via static analysis over compiled beams. No incident names this as
having actually happened. Declined for now; revisit if one does — see "Gaps considered
and declined".

## `Core.PollingFeed`

**Out of scope by design**, not a gap. `PollingFeed` is not a `@behaviour` the facade
conformance suite governs — it is an internal GenServer a venue MAY compose into its own
feed, with typed function VALUES (`fetch`, `fetch_all`, `notice_handler`) passed as
`start_link/1` options, not callbacks a venue implements and `AdapterContract` can
enumerate. A venue with its own transport (a socket, an MQTT client) never touches it. It
carries its own direct unit-test suite (`test/dp_exchange/core/polling_feed_test.exs`) at
the Core level, which is the right place for its invariants — the escalating-warning
behaviour, the bounded-fetch timeout, the once-per-transition notice — none of which are
facade-shaped claims a venue package's own conformance run should be re-proving.

## Gaps closed

Three additions, each proven against a fixture in Core's own tests and verified safe
against all five real venues by reading their source directly (see "Five-venue
verification" below) — never by modifying a venue repo.

### `Capabilities.validate_staking!/1` (strengthens assertion 2)

`has_staking` is redundant with six staking endpoints by construction, and a redundant
field that disagrees with what it summarises is worse than none — the same "Kind 2 field
must agree with the endpoints it summarises" rule `validate_orders!/1` already applies
elsewhere. **Found live on `dp_exchange_coinbase` during this audit**: `has_staking` is
never declared (defaulting to `false`) while `stake/3` and `unstake/3` are real, active
calls against Coinbase Prime. Reported for that package's own review; not fixed here.
Keyed on an EXPLICIT `:proven`/`:experimental` entry in `endpoints`, never on
`active?/2`'s undeclared-is-experimental default — the same reason `validate_history!/1`
reads `claims_history?` explicitly — so a declaration with nothing to do with staking
(most fixtures in this family) is unaffected. Proven against a broken fixture in
`test/dp_exchange/core/capabilities_test.exs`.

### Assertion 20 — subscribed push shape

`subscribe/2`'s own doc makes an unconditional claim — the payload is a
`DpExchange.Core.Types.*` struct, tagged with `runtime_id/0` — that nothing checked.
Assertion 16 (internal wiring) catches a decoder with no caller, but a decoder that IS
wired and simply never runs before the raw response reaches the sink passes every other
assertion. Fake-only: every fake in this family pushes synchronously inside the call that
returns `:ok`, so nothing dials out. Proven against `Broken.Subscribe.RawPayload` and
`Broken.Subscribe.WrongTag` in `test/dp_exchange/core/contract_teeth_test.exs`.

### Assertion 21 — historical timeframe discipline

This family's own named recurring failure mode, verbatim from this package's own
`CLAUDE.md` ("a missing granularity becoming the closest one"), and stated as a rule in
`get_historical_prices/4`'s own doc that nothing enforced. Picks a width from
`Timeframe.nameable/0` the venue's own `historical_timeframes` does not name and asks the
fake for it; the answer must not be `{:ok, _}`. Proven against
`Broken.HistoricalPrices.Substitutes` in `contract_teeth_test.exs`.

## Gaps considered and declined

Recorded so the next audit does not re-litigate the same ground.

- **`subscribe_notices/1` pushing an actual `Notice`.** Considered the same shape as
  assertion 20's subscribe check. Declined: `Core.Notice`'s own moduledoc states
  "delivery is not guaranteed and a consumer's correctness must not depend on it" as
  the contract, not a caveat — unlike `subscribe/2`, which promises delivery.
  `dp_exchange_robinhood`'s own fake legitimately answers `:ok` with nothing pushed by
  default ("this fake has no feed of its own to be down"), and an assertion requiring a
  push would flag a venue for correctly implementing the documented behaviour. This is
  exactly "an assertion that cannot fail [correctly] is worse than none, because it
  certifies" run in the other direction — it would certify a false rule.
- **`%Notice{}` struct-literal bypass of `Notice.new/3`'s validation.** Technically
  feasible via the same static-analysis pattern `LinkSafetyCheck`/`CredentialRedactionCheck`
  already use, but no incident names it as having happened. Manufacturing coverage
  without a demonstrated failure mode is the thing this audit was asked not to do.
- **Comprehensive per-endpoint return-type checking (assertion 5, in full).** Would
  require a hand-maintained endpoint → struct-type map, the exact shape `@credentialed`
  was before it had to be replaced, and `Core.FeedBehaviour` (zero adopters) is the
  family's own cautionary tale for inventing a convention nothing requires.
- **`runtime_id/0` matching the package's namespace segment.** Would require Core to
  know a venue's naming convention it does not and should not own.
- **"10. facade completeness and exclusivity" — the "only the facade is public" half.**
  The completeness half is covered (assertion 1). The exclusivity half — the original
  design doc's "assert the negative as a module scan: no other module in the package is
  reachable API" — was never built, and building it generically (without inventing a
  `@moduledoc false`-on-everything-internal convention this contract does not require)
  is genuinely hard in a language with no first-class "private module". Left as a named,
  honest gap rather than a manufactured partial check.
- **`supports_order_types`/`time_in_force`/`instrument_types` against live order
  placement.** Checking these behaviourally would mean asserting a fake accepts every
  declared value on `place_order/3` — which tests the fake's own permissiveness, not a
  real venue invariant, and a fake written to satisfy the assertion would tell a
  consumer nothing new. No live-network route exists that would be safe per D7.
- **`reports_trade_volume` vs `get_trade_volume/2`.** A genuine near-miss — see the note
  under the `Capabilities` table. Verified NOT to be the same class of bug as
  `has_staking` before writing any code, and no assertion was added.
- **`max_candles_per_request`, `catalog_size`, `measured_at`/`measured_against`,
  `supports_short_selling`, `supports_fractional_shares`.** Informational fields with no
  paired endpoint to cross-check and no defect evidence. Coverage for its own sake was
  explicitly out of scope for this audit.
- **"9. fake fidelity" as a literal second suite run.** `assertions/0` describes this as
  "the fake satisfies this same suite," but in practice only assertion 12's
  active-endpoint check and assertion 17's credential gate actually run AGAINST the fake
  — the rest (purity, wiring, link safety, credential redaction) examine the package's
  own compiled `lib/`, which is identical whether `venue:` or `fake:` is passed. Every
  venue's contract test passes `fake:` alongside `venue:`, once, rather than running the
  whole suite twice with `venue: Fake`. This is the existing, working design — a second
  full run would mostly re-check facts about the same compiled code — not a gap, but
  worth recording since the `assertions/0` prose reads more literally than the
  implementation.

## Five-venue verification

Each of the five real venue packages had its `mix.exs` pointed at this local Core with a
`path:` dependency, ran its own `*_contract_test.exs` (the full `AdapterContract` suite,
including the three additions), and had `mix.exs` reverted before moving to the next —
`git status --short` confirmed clean before and after each. No `path:` dependency was
committed anywhere.

| venue | result | notes |
|---|---|---|
| `dp_exchange_coinbase` | **23 of 42 tests fail** | single root cause — `Capabilities.new/1` raises `has_staking is false but [stake: 3, unstake: 3] are declared active` inside `capabilities/0`, so every test that calls it cascades. Reported for that package's own review; not fixed here. |
| `dp_exchange_gemini` | 42/42 pass | |
| `dp_exchange_robinhood` | 42/42 pass | assertion 21 is a no-op here — `get_historical_prices/4` is `:unsupported` |
| `dp_exchange_schwab` | 42/42 pass | |
| `dp_exchange_webull` | 42/42 pass | |

**The one real finding: `dp_exchange_coinbase`'s `has_staking` declaration.** Precisely:
add `has_staking: true` to its `capabilities/0` call in `lib/dp_exchange/coinbase.ex` — a
one-line fix, not attempted here per this audit's own instruction to report rather than
rush a venue fix.

> **CLOSED, verified 2026-09-11.** `lib/dp_exchange/coinbase.ex` now carries
> `has_staking: true` and that package's contract suite passes in full. The table above is
> kept as it was written — it is the record of what the audit found on the day, not a status
> board — but nothing in it is outstanding any more. Current counts, all five venues,
> 2026-09-11: **47 tests, 0 failures each.**

**Incidental finding, pre-existing and out of scope for this audit:** running each suite
surfaced real `Logger.debug` lines showing live HTTP calls to the venue's own public API
— `GET https://api.gemini.com/v1/pubticker/btcusd` and `.../v1/symbols` on Gemini,
`GET https://trading.robinhood.com/api/v2/crypto/trading/trading_pairs/` on Robinhood,
`GET https://api.webull.com/trading/instruments/crypto/profiles/list` on Webull —
during an ordinary `mix test` run that every venue's own `test_helper.exs` configures to
`exclude: [:tier2]` specifically so live calls do NOT happen on every CI run. The two
`AdapterContract` tests responsible predate this audit and were not touched by it:
assertion 14 ("get_top_of_book/2 returns a TopOfBook...") and part of assertion 12
("catalog_access matches how get_symbols/1 behaves...") both call `@venue` — the REAL
module — directly, rather than `@fake`, for any venue where the corresponding endpoint is
active and unauthenticated. This does not affect the three additions in this audit (all
three are fake-only, verified above), but it means "tier 1 is the only tier that runs on
every CI run and never dials out" is not quite true today for these two pre-existing
checks. Reported here because it was found in the course of the verification this task
requires; not fixed here — it is a change to two existing assertions, not a gap this
audit was scoped to close.

> **CLOSED, verified 2026-09-11.** Both now drive `@fake`. Assertion 12's catalog_access
> check carries the incident in its own comment — *"calling it for real would make every
> ordinary `mix test` run dial the live API — reproduced live against
> `api.gemini.com/v1/symbols` before this was fixed"* — and both assert `@fake` is present
> rather than silently falling back to the real module. Re-checked in source and by running
> all five contract suites: no venue hostname appears in any of them. Tier 1 dials out
> nowhere.

## Gap closed 2026-09-10 — assertion 23

The `Core.Types.*` row above records assertion 5 as **partial**, and deliberately declines a
comprehensive endpoint → expected-struct map. That reasoning stands. This is the narrow case
it does not cover, created by Core 0.2.0's own change.

Splitting `Quote`/`OrderBook`'s `:timestamp` into `:venue_time` and `:observed_at` is only
worth having if `:venue_time` stays honest — and nothing checked it. Assertion 14 already
made exactly this check for `TopOfBook`, which carried both fields from the start; assertion
23 extends it to the two types that just gained them.

**Why this is not the declined map.** Two named callbacks whose return type the contract
already fixes, with no hand-maintained list to rot. `get_price/2` returns a `Quote`,
`get_order_book/2` returns an `OrderBook`, and both gate on `Capabilities.active?/2` so a
venue declaring them `:unsupported` is skipped rather than failed.

**What it catches**: a decode bug with a plausible shape — a raw epoch integer, a
`NaiveDateTime`, or an unparsed venue string sitting in `:venue_time`.

**What it cannot catch, stated rather than implied**: a venue putting its own local clock in
`:venue_time`. No assertion can — a `DateTime` from `DateTime.utc_now/0` is indistinguishable
from one the venue sent. That is held by the type's documentation and by review. Claiming
otherwise would make this row worse than useless, which is the failure this whole file exists
to prevent.

A third test is structural rather than behavioural: neither type may regrow a `:timestamp`
field. Same reasoning as `TopOfBook has no price field` — a field with no defined meaning
gets filled from whichever value is nearest to hand, which is the ambiguity the split removed.

## Gap closed 2026-09-11 — assertion 24

`Types.Balance` enforces `:currency` and its `new/1` refuses a `nil` there. **No venue
decoder in this family calls `new/1`** — every one builds the struct literally, which
`Types.Validate`'s own moduledoc explicitly permits — so that check had never run anywhere,
and four of the five packages read `currency` straight out of the venue's JSON by key with
nothing between. A renamed or absent key produced `%Balance{currency: nil}`: an amount
attributable to no asset, returned inside `{:ok, balances}`, which a consumer cannot size,
book or reconcile against.

All four were fixed in their own packages. Assertion 24 is the ratchet, per this suite's own
rule — *"Every gap found becomes a new assertion here. A gap fixed only in one venue's fake
is a gap the next venue will reintroduce."* Four separate fixes with no shared assertion
behind them is exactly that shape.

**What it does not check, deliberately: `:balance`.** `Types.Balance` states that field may
honestly be `nil` while `:currency` may not — `dp_exchange_coinbase` derives its total from
the venue's available and hold figures and carries `nil` when either is missing, rather than
claiming a total it cannot compute. An assertion covering both would force that venue to
discard a real `available_balance` in order to report an absence honestly.

## Second axis — an assertion that exists is not an assertion that runs

**Found 2026-09-11, while verifying assertion 24 rather than while writing it.** Every status
in this file answers one question: *does an assertion exist for this?* That is not the same
question as *does it execute on every venue?*, and the difference had been hiding real
absence behind green runs.

The method that found it is the one worth keeping: **break the thing on purpose and require
the suite to go red.** Niling each venue's fake balance currency failed two packages and left
three green. Those three — `dp_exchange_webull`, `dp_exchange_robinhood`,
`dp_exchange_schwab` — are account-scoped: several fake-driven assertions call an active
endpoint with `opts: []`, and every account-scoped call was refused for the missing account
(`:account_id`, `:account_number`, `:account_hash` respectively) before reaching the
behaviour under test. The suite took that refusal as a legitimate answer and skipped.

**It was never confined to assertion 24.** Assertion 17 — the credential gate — had been
passing for the wrong reason on those same three venues since it was written: it strips the
credential and expects a failure, and the failure it got was the absent account, not the
stripped credential. Assertion 12's endpoint sweep was calling those endpoints without ever
reaching them.

Closed by `endpoint_opts:` on `use DpExchange.Core.AdapterContract` (Core 0.3.7), a
`%{{name, arity} => keyword()}` each venue declares for its own endpoints. **The key stays
the venue's**: a table of `:account_id` / `:account_number` / `:account_hash` inside Core
would be exactly the venue-specific knowledge this contract exists to keep out of it.
Assertion 17's stripped-credential args carry those same opts alongside the emptied
credential, so the only thing missing from that call is the one thing it tests.

**For the next audit.** A **covered** row above means an assertion exists. Before relying on
one, break what it checks and confirm the suite fails — on every venue, not on the first.
Two of the five would have told you nothing.

### Second axis, applied 2026-09-12 — assertions 14 and 23

The section above told the next auditor to break what an assertion checks and require the
suite to go red **on every venue rather than on the first**. Doing that to assertions 14 and
23 found them inert on four packages out of five.

Both build a call to the venue's fake for a PUBLIC-shaped endpoint — `get_top_of_book/2`,
`get_price/2`, `get_order_book/2` — whose argument shape carries no credential position, so
the only place a credential can travel is `opts`. Both passed a hand-built `[symbol, []]`.
Every venue declaring `credential_benefit: :required` answered
`{:error, {:missing_credentials, _}}`, and the `_refused_or_unsupported -> :ok` clause took
it for an answer. Only `dp_exchange_gemini`, needing no credential, ever ran them.

**The measurement.** Set a fake's `observed_at` to `nil` — the precise defect assertion 14
exists to catch — and run `dp_exchange_schwab`'s contract suite:

| Core | result |
|---|---|
| published 0.3.8 | **0 failures** — the assertion is inert |
| this change | 2 failures — `get_top_of_book/2` and `get_price/2`, exactly the two that venue declares active |

Across all five, with the same break: 3 failures each for the venues serving all three
endpoints, 2 for `dp_exchange_schwab` (no order book), 1 for `dp_exchange_robinhood` (no
`get_price/2`, no order book). Those counts match each venue's own `capabilities/0` exactly,
which is what "runs where it should and nowhere else" looks like when you can see it.

**Two things this cost, worth naming.** The `_refused_or_unsupported -> :ok` clause was
closed in assertion 24 one day earlier and left open in 14 and 23 — a fix applied where it
was found rather than where it applied, committed inside the suite whose job is to stop
exactly that. And `endpoint_opts:`, added the same day, was not reached by either assertion,
because both bypassed `endpoint_args/2` and built their arguments by hand. A mechanism is
only as wired as its call sites.

`endpoint_symbols:` was added for the one case that survived: `dp_exchange_webull` serves an
order book for US stocks and ETFs and refuses one for a crypto pair, and all its sample pairs
are crypto. Naming a symbol the endpoint actually serves makes the assertion run rather than
skip — which, throughout this file, is the whole difference.

### The sweep completed 2026-09-12 — every fake-driven assertion, every venue

The two sections above each found an assertion inert by breaking what it checks. This is
that method carried across **all seven fake-driven assertions on all five venues**, so the
next reader does not repeat thirty experiments to learn the same thing.

Each row is a deliberate break of the exact property the assertion claims, run against every
venue the assertion applies to. Every one produced a failure; **nothing was found still
inert.**

| assertion | break applied | venues it applies to | result |
|---|---|---|---|
| 12 agreement | `get_symbols/1` returns `{:error, :not_supported}` while `capabilities/0` declares it active | all 5 | 5/5 fail |
| 14 top of book | fake's `observed_at` set to `nil` | all 5 | 5/5 fail |
| 17 credential gate | `FakeInjection.credentials_bypassed?/1` forced `true`, so every gate opens | 3 — `webull`, `robinhood`, `schwab` | 3/3 fail |
| 20 subscribed push | fake pushes a raw map instead of a `Core.Types.*` struct | all 5 | 5/5 fail |
| 21 timeframe discipline | fake's width guard disabled, so it serves any width | 4 — `robinhood` declares the endpoint unsupported | 4/4 fail |
| 23 venue/observed time | fake's `observed_at` set to `nil` | all 5 | failures per venue: 3, 3, 3, 2, 1 |
| 24 balance attribution | fake's `Balance.currency` set to `nil` | all 5 | 5/5 fail |

**Assertion 23's uneven counts are the point, not a blemish.** Three failures on the venues
serving `get_top_of_book/2`, `get_price/2` and `get_order_book/2`; two on `dp_exchange_schwab`
(no order book); one on `dp_exchange_robinhood` (no `get_price/2`, no order book). Those match
each venue's own `capabilities/0` exactly, which is what "runs where it should and nowhere
else" looks like when you can actually see it.

**Two legitimate skips remain, and both are declared rather than inferred.** A venue that
declares an endpoint `:unsupported` is skipped, which is the honest reason to skip; and
assertion 21 skips a venue declaring the entire nameable timeframe vocabulary, since no width
is left that would prove it refuses one. Neither is a refusal being mistaken for an answer —
that clause is gone from all three assertions that had it.

**One consolidation came out of this.** Assertions 12 and 21 still hand-built their fake
argument lists. Both happened to carry `credentials:`, so neither was among the inert ones —
but hand-building is exactly what made 14 and 23 inert, so every fake call in the suite now
goes through `endpoint_args/2`. A venue's `endpoint_opts` and `endpoint_symbols` reach all of
them, and no call site can drift back out of the mechanism.
