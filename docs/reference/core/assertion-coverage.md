# What the conformance suite does — and does not — check

**Audited 2026-09-08.** `Core.AdapterContract`'s 19 assertion groups (now 21 — see
"Gaps closed" below) have each caught real, shipped defects within minutes of existing.
Nobody had asked the inverse question: which parts of `Core.Venue`, `Core.Capabilities`,
`Core.Notice` and `Core.PollingFeed` have **no** assertion touching them at all. This is
that map, done once so the next audit starts from it instead of from zero.

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
