# Webull Connection Sharding and Fake Failure Injection — Design Document

**Date**: 2026-09-04
**Status**: Implementing
**Version**: 1.1
**Author(s)**: Billy / Claude collaboration
**Repo**: `DistortionPoint/dp-exchange-core` (this doc); implementation lands in
`dp-exchange-webull` (Part A) and `dp-exchange-core` + all four venue packages (Part B)
**Filed as**: `dp-exchange-core` issues #13 and #14 — one batch, one review pass

## 0. Why one document

Both issues were filed together, in the same tracker, from the same migration push. They
don't share code — Part A is Webull's `Feed`, Part B is a shared `Core` seam applied
across four venues — but they're one set of work from a planning standpoint, and get one
review pass here rather than two. Implementation still lands as separate deploys per
repo when it lands (Part A in `dp-exchange-webull` alone; Part B in `dp-exchange-core`
first, then each venue's `Fake`), because that's a fact of five separate Hex packages,
not a reason to plan them separately.

## 1. Objectives

**Part A — Webull connection sharding — DONE, shipped `dp-exchange-webull@7c27169`:**
- [x] A `Feed` that accepts a symbol set larger than one session's subscription ceiling
      and covers all of it, without the consumer hand-rolling multiple `Supervisor`
      instances
- [x] Stay inside the venue's hard **5 connections per App Key** ceiling — a consumer
      must never be able to cause a sixth socket
- [x] One rate limiter governs every shard's HTTP subscribe/unsubscribe calls, not one
      per shard

**Part B — Fake failure injection and anonymous mode — mechanism shipped
(`dp-exchange-core@0b533d4`), Robinhood adopted (`dp-exchange-robinhood@a74b4e4`),
Coinbase/Gemini/Webull adoption in progress:**
- [ ] One shared mechanism, implemented once in `dp_exchange_core`, that all four venue
      `Fake`s adopt consistently — **mechanism: done. Adoption: 1 of 4 venues
      (Robinhood) shipped; Coinbase, Gemini, Webull in progress, not yet pushed.** This
      line does not check off until all four are done and pushed together as one batch —
      see §0's own "one set of work" framing, which applies to the push, not just the
      planning.
- [x] Deterministic failure injection — an exact, pre-declared sequence of outcomes,
      never real randomness — proven in `Core.FakeInjection`'s own tests and exercised
      end-to-end in Robinhood's `Fake`
- [x] A credential-free mode that is opt-in per test, never a change to any `Fake`'s
      default (venue-faithful) behaviour — same evidence
- [x] **Test isolation is first-class and non-negotiable**: two `async: true` tests
      configuring the same venue's `Fake` differently at the same time must never see
      each other's configuration. This is not an aspiration — it is this repo's own
      stated testing rule ("Tests must be `async: true`
      safe. Configuration seams resolve through a process-scoped lookup so two async
      tests can want the same fake to behave differently," `CLAUDE.md`), and `Core.Config`
      already exists specifically because a node-wide seam broke exactly this once
      (§3.6/§3.7 build on it for this reason, not by default choice). Verified directly:
      two venues' overrides never see each other, an override is invisible to an
      unrelated process and visible to a spawned `Task`.
- [x] **One symbol failing cannot fail the whole set.** A consumer injecting a failure
      for one symbol must see every other symbol's call succeed normally in the same
      test — the same isolation principle as the row above, applied within one test's own
      configuration rather than between tests. Whole-call-only injection cannot express
      this at all: it can only fail everything or nothing, which is not what "test how my
      code handles one bad symbol among many" needs. Verified directly in both
      `Core.FakeInjection`'s own tests and Robinhood's `Fake` wiring.

**Out of scope for both:** raising Webull's subscription ceiling itself; formalizing
`configure/1` as a `@callback` on `Core.Venue` (a test affordance, not a venue-shaped
operation).

## 2. Checklist

**Part A — Implemented, `dp-exchange-webull` (commit pending push):**
- [x] Shard partitioning: deterministic symbol→shard assignment (§3.1). **What was
      found**: sort-then-chunk alone (as originally sketched) isn't sufficient once
      rebalancing exists — a shard's effective capacity can shrink below
      `@pairs_per_socket` after a venue rejection, so the actual implementation chunks
      against a live `shard_capacity` map (default `@pairs_per_socket`, overridden per
      index once measured) rather than a single fixed constant. Re-derived from the full
      wanted set on every call, same as Coinbase, not maintained as separate mutable
      per-symbol state.
- [x] Per-shard `session_id` generation and MQTT connection lifecycle (§3.2)
- [x] Staggered shard opens (background/non-primary shards only; the call's primary
      shard is handled inline, matching Coinbase)
- [x] Reconnect/resubscribe unconditionally, per shard, on `:link_up` (no separate timer
      needed beyond the venue's own CONNACK-driven notice — see `on_link_up/2`)
- [x] Single shared rate limiter across all shards (§3.4) — unchanged from the
      pre-sharding design; sharding is internal to one `Supervisor`/`Feed` tree
- [x] Internal rebalancing on a shard-level venue rejection (§3.5). **What was found**:
      the original sketch called for dropping a shard's bookkeeping once it was no
      longer "wanted" by a given reshard pass (mirroring Coinbase). Combined with
      rebalancing, this actively broke the promise it was supposed to keep — a shard
      dropped in one pass because it wasn't yet needed could be needed again moments
      later by that same pass's own retry, or by a *different* shard's asynchronous
      rebalance, forcing a real multi-second reopen instead of reusing an
      already-connected socket. Fixed by never dropping shard bookkeeping at all — capped
      at five shards, the cost of an idle entry is trivial next to the correctness this
      buys. `dp-exchange-coinbase`'s own drop-eagerly behavior was not revisited, since
      it doesn't have this rebalancing interaction.
- [x] `coverage/1` aggregates across shards, observed not intended, unchanged semantics —
      `delivering`/`wanted` stayed global, unsharded state throughout
- [x] Tests: partitioning across shards, a shard's rejection moving its overflow to
      another shard invisibly to a synchronous caller (§3.5's own promise, verified
      directly), the same rebalance triggered asynchronously via a shard's own
      `:link_up`, capacity genuinely exhausted across all five shards refusing cleanly
      rather than silently dropping or oversubscribing
- [x] Moduledoc rewritten to record the incident this closes

**Part B — `Core.FakeInjection` implemented and shipped in `dp-exchange-core`; per-venue
adoption next:**
- [x] `Core.Config`-based shared helper (§3.6) — `DpExchange.Core.FakeInjection`, new
      module in `dp_exchange_core`
- [x] Deterministic failure queue semantics defined and tested, whole-call and per-symbol
- [x] Per-symbol targeting: a symbol-specific failure never affects any other symbol's
      call in the same test (§3.6.2) — verified directly, including that a
      symbol-specific queue is checked before the whole-call one
- [x] Anonymous/credential-bypass semantics defined and tested (§3.7)
- [x] Isolation verified directly: two venues' overrides never see each other, an
      override is invisible to an unrelated process and visible to a spawned `Task`
      (matching `Core.Config`'s own documented `$callers` behaviour). **What was found**:
      the original sketch (§3.6, §3.7) used `:"fake_injection_#{venue}"` — a per-venue
      Config key built by interpolating `venue` into a new atom at runtime. Flagged by
      `mix sobelow` (`DOS.BinToAtom`) even though `venue` is always a small,
      developer-supplied atom here, never user input — the pattern is unsafe on sight
      regardless of how bounded the actual input is in practice. Fixed by storing every
      venue's state under one static override key (`:fake_injection`), keyed by `venue`
      *inside* the stored map rather than in the Config key itself — no dynamic atom
      creation anywhere.
- [x] Applied to one `Fake` first (Robinhood — smallest surface) as the reference
      implementation, shipped `dp-exchange-robinhood@a74b4e4`
- [ ] Applied to the remaining three (Coinbase, Gemini, Webull) — in progress, not yet
      pushed; held until all three are done and reviewed together against Robinhood's
      reference for consistency, then pushed as one batch, not one at a time
- [ ] `usage-rules.md` documents the pattern for a consuming agent — drafted locally in
      `dp-exchange-core`, not yet committed (held for the same reason)

## 3. Design

### Part A — Webull connection sharding

`DpExchange.Webull.Feed` opens exactly one MQTT connection, ever — a deliberate deferral
recorded in its own moduledoc ("Sharding to raise the message ceiling is a change to make
when a measurement demands it"). DpCryptoManagement's migration is that measurement: a
~325-symbol collection scope hits the venue's own per-session subscription ceiling
(reported as `TOO_MANY_SYMBOLS_SUBSCRIPTION`, max 100, HTTP 417 — first-party from the
issue, not independently reproduced here since it needs live credentials).

**This is not new ground for the family.** `DpExchange.Coinbase.Feed` shards for the
identical reason — a per-session subscribe ceiling discovered in production — and its
design (`lib/dp_exchange/coinbase/feed.ex` in that repo) is the template this adapts, not
a fresh derivation.

#### 3.1 Partitioning

Coinbase's `shards/1` is `Enum.chunk_every(symbols, @pairs_per_socket)` over whatever
order the caller's list arrives in — simple, but re-chunks everything on every
`update_symbols/2` call, which on Coinbase is cheap (chunking is pure) but changes which
*shard* a symbol lives on across calls, which matters more here: Webull's shard identity
is also its MQTT `session_id`, and a symbol moving shards means an unsubscribe on the old
shard's session and a subscribe on the new one, not just a local bookkeeping change.

Proposed: sort `state.wanted` before chunking, so the assignment is stable for any symbol
whose position relative to its neighbors hasn't changed.

**`@pairs_per_socket` is exactly 100 — the venue's own stated ceiling, not a guessed
margin below it.** The number came up for reconsideration once, and the answer is that
there was never a real question: the issue's quoted venue error (`"Maximum number of
subscribe tickers:100"`) is first-party evidence of the actual limit, not something to
pad against out of caution. Declaring a number this package did not measure or the venue
did not state — "90, to be safe" — is exactly the unlabeled guess this family's own
convention (§Critical Development Principles, `dp_exchange_core/CLAUDE.md`) rules out:
declare what was measured, not what was assumed. §3.5's internal rebalancing is what
absorbs the case where 100 turns out to be wrong in practice (a venue change, an edge the
error text didn't capture) — that is what rebalancing is *for*, not a reason to build in
slack against a number that is already the venue's own word for it.

**5 connections × 100 symbols = 500 is this package's hard addressable ceiling** for one
App Key, both numbers the venue's own stated limits — worth stating explicitly in the
moduledoc so a consumer with a larger universe than that knows it needs a second App Key,
not a bigger number here.

#### 3.2 Connection lifecycle

Each shard gets its own generated `session_id` (this package's existing
`generate_session_id/0`, unique per shard rather than per `Feed`) and its own `Socket`
process, opened staggered rather than all at once — Coinbase's shard-spacing exists
because a connect burst gets answered with resets, and nothing about that is
Coinbase-specific.

Each shard's `Socket` needs the shared `app_key` (from the caller's `credentials`, per
the #8 fix already shipped) but its own `session_id` — the venue disconnects an older
connection presenting a **duplicate** `session_id`, so two shards must never collide, and
per-shard generation makes that structurally true rather than something to get right by
convention.

#### 3.3 Reconnect and resubscribe

Unchanged in kind from the current single-connection design, applied per shard: a
reconnect on shard N replays only shard N's `wanted` slice. The existing `:link_up`-gated
defer (issue #9's fix) applies per shard — a subscribe against a shard whose socket is
still connecting waits for that shard's own CONNACK, not the whole `Feed`'s.

#### 3.4 Rate limiter

`DpExchange.Webull.Supervisor` starts one `DefaultRateLimiter`, sized from
`capabilities().public_ceiling`, regardless of shard count — sharding is internal to one
`Feed` process tree, so there is exactly one limiter for every shard's subscribe/
unsubscribe calls to share, the same limiter that already governs every other REST call
this package makes. This is why building sharding into `Feed` (issue's option 2) is
preferred over documenting a hand-rolled multi-`Supervisor` pattern (option 1): the
latter reproduces the exact "N independent budgets" problem the issue reports,
structurally, regardless of documentation.

#### 3.5 Shard rebalancing — the package's own problem

**Decision: the module manages its own sharding end to end. The host knows nothing about
shards, session ceilings, or which connection a symbol landed on — same boundary this
whole family already draws everywhere else** (D12: "A consumer cannot tell from the
facade how data reaches the package, and must not be able to"). A shard is exactly the
kind of internal transport detail that principle exists to hide, so a rejection at the
shard level cannot become the host's problem to route around.

- **Options considered**: (a) surface the raw refusal on the notices channel and let the
  consumer decide what to do about it; (b) the package rebalances internally and only
  reports if it genuinely runs out of shards.
- **Selected**: (b).
- **Rationale**: (a) would mean a consumer has to understand `session_id`s, per-session
  ceilings and shard assignment to react correctly — exactly the internals D12 exists to
  keep off the facade. A host that has to know *why* a subscribe partially failed and
  *which* symbols to re-request differently is doing this package's own bookkeeping.
- **Mechanics**: when a shard's HTTP subscribe comes back with the venue's
  over-subscription refusal (`TOO_MANY_SYMBOLS_SUBSCRIPTION`/417, or the shard's own
  `error 105` MQTT connection-limit case), the affected symbols are moved to another
  shard with room — opening a new one if the existing shards are full and the 5-connection
  ceiling has not been reached — and the subscribe is retried there, all inside `Feed`.
  `coverage/1` simply reflects what ends up delivering, same "observed, never intended"
  convention already in place; the consumer never sees an intermediate rejection for a
  symbol that ends up covered a moment later.
  - **The one case that cannot be absorbed**: every shard full, `5 × @pairs_per_socket`
    already reached, and the venue still refuses. That is a genuine capacity ceiling this
    package cannot paper over — it surfaces as a real refusal (a capacity `Notice`, or the
    subscribe call's own `{:error, :capacity_exceeded}`-shaped result), not silently
    dropped coverage. The distinction is the same one this family draws everywhere:
    recoverable internal detail stays internal; a genuine "cannot be done" is reported,
    never guessed around.

### Part B — Fake failure injection and anonymous mode

DpCryptoManagement's own hand-rolled test double (`Mock.Provider`) supported two things
none of the four venue `Fake`s do, confirmed by grep across all four packages:

1. **Deterministic, dialable failure injection** — the old double's
   `configure(error_rate: 1.0, ...)`, used to exercise a consumer's own retry/circuit-
   breaker/alerting code against a `Venue` implementation without reaching a real venue.
2. **A credential-free wiring mode** — three of the four `Fake`s correctly refuse without
   credentials (`{:refused, :missing_credentials}`), which is venue-faithful and right by
   default, but leaves no way to test pure dispatch/decode logic without also
   constructing valid-looking credentials for every call.

Build on `DpExchange.Core.Config`'s existing process-scoped override machinery rather
than a new cross-process mechanism — it already solves the exact problem this needs
(process-scoped, `$callers`-aware, safe under `async: true`) and is already the family's
stated convention for "every seam a consumer's tests may need to vary."

#### 3.6 Failure injection

Proposed: a new `DpExchange.Core.FakeInjection` module, built directly on
`Core.Config.put_override/2` / `find_override/1`. Two axes, not one, and they answer two
different questions:

- **Which functions does one override reach** — every function, uniformly (§3.6.1).
- **Which symbol does one override reach, for a function that takes one** — the whole
  call, or one symbol without touching any other (§3.6.2). These compose: a global
  override still gates every function; a symbol-targeted one only ever affects calls for
  that symbol, on whichever function is called with it.

```elixir
# Test process — whole-call, every function:
FakeInjection.queue_failures(:webull, [{:error, :timeout}])

# Test process — this symbol only, every other symbol's calls are untouched:
FakeInjection.queue_failures(:webull, "AAPL", [{:refused, :not_listed}])

# Inside DpExchange.Webull.Fake's own functions, at entry:
FakeInjection.next_outcome(:webull, symbol) |> case do
  {:override, outcome} -> outcome
  :none -> # normal fake logic
end

# A function with no symbol argument (get_balances/2, list_instruments/1, …):
FakeInjection.next_outcome(:webull) |> case do
  {:override, outcome} -> outcome
  :none -> # normal fake logic
end
```

`next_outcome/2` checks the symbol-specific queue first; falling through to the global
queue only when no symbol-specific one is configured for that symbol. A symbol-targeted
override can therefore never be satisfied by, or interfere with, a call for a different
symbol — the isolation this exists for is structural, not a convention to remember.
`next_outcome/1` (no symbol) only ever consults the global queue, since there is no
symbol to target for those calls. Each queue pops one entry per matching call (or returns
`:none` once exhausted, resuming normal behaviour) — deterministic by construction, no
rate, no randomness. `fail_always(venue, outcome)` / `fail_always(venue, symbol, outcome)`
set an override that never pops, for the "every call fails" case the issue's own example
describes.

##### 3.6.1 Decision: every public function that takes a symbol consults `next_outcome/2`; every other public function consults `next_outcome/1` — uniformly, not per-function opt-in.

- **Options considered**: (a) every function gated the same way; (b) per-function
  targeting, e.g. `queue_failures(:webull, get_balances: outcomes)`.
- **Selected**: (a).
- **Rationale**: the issue's own request is a single global `error_rate`, with no
  per-function example or ask anywhere in it — (b) would be building speculative surface
  the filer never asked for, which this family's own conventions rule out on a bug fix
  and are no more justified here just because this is a design doc rather than code.
  (a) also matches the old double's own shape, which is the bar this is replacing, not
  improving on speculatively. Revisit only if a real, filed need for per-function
  targeting shows up later — not before.

##### 3.6.2 Decision: per-symbol targeting is in scope, not deferred.

- **Options considered**: (a) whole-call only — one override affects every symbol a test
  touches; (b) whole-call and per-symbol, composing as above.
- **Selected**: (b).
- **Rationale**: whole-call-only can express "everything fails" or "nothing fails" but
  not "this one symbol fails, the rest of the batch succeeds" — and a symbol failing
  cannot be allowed to fail the whole set it was tested alongside. That is not a
  refinement of (a), it is a case (a) cannot express at all, so it is not optional the
  way per-function targeting (§3.6.1) is.
- **Scope note**: this covers `Fake` functions that take a single symbol as an argument.
  A function that takes a *list* of symbols in one call (Webull's own subscribe, which
  names a batch at once) simulating one symbol within that batch failing while the rest
  of the batch succeeds is a harder question — it needs the fake response itself to carry
  partial success, not just pick which outcome one call returns — and is not resolved
  here; flag if a real near-term need for it shows up.

#### 3.7 Anonymous / credential-free mode

Proposed: `FakeInjection.bypass_credentials(venue)`, a process-scoped flag a `Fake`'s
credential check consults before its normal `{:refused, :missing_credentials}` path:

```elixir
defp authenticated(credentials) do
  if FakeInjection.credentials_bypassed?(:webull) do
    :ok
  else
    # existing venue-faithful check
  end
end
```

This keeps the venue-faithful refusal as the untouched default while giving a
wiring-only test a one-line way to skip past auth and exercise dispatch/decode logic.

## 4. Open Questions

None outstanding. Every question raised during review is recorded as a resolved decision
in §3, in place, rather than repeated here — see §3.1 (per-shard symbol count), §3.5
(shard rebalancing), §3.6.1 (injection function-granularity) and §3.6.2 (injection
per-symbol targeting).

## 5. Dependencies

- **Part A**: issues #8 and #9 (both fixed, `dp-exchange-webull@6093c94`) — per-shard
  credential threading and CONNACK-gated subscribing both build directly on those fixes.
  `DpExchange.Coinbase.Feed` as the structural template.
- **Part B**: `DpExchange.Core.Config` (existing, no changes needed) — the
  process-scoped override mechanism this design reuses rather than reinvents. Four
  venue packages' `Fake` modules, applied one at a time per the checklist, each a
  separate deploy per this family's normal cadence.
