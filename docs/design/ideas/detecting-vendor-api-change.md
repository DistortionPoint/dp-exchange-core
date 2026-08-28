# Detecting and absorbing vendor API change

**Date:** 2026-08-27
**Status:** Idea (placeholder — the material comes from doing the work)
**Related:**
  - `docs/design/2026-08-26_exchange-adapter-package-family.md` — D7 tier 2, D13, D14
    notices, §5.0 capabilities. Several pieces of a change-detector exist there for other
    reasons; nothing assembles them.
  - `docs/design/ideas/external-experimental-feedback.md` — the other half of the same
    problem: change detected by someone who is not us.

## Concept

Venues change. Endpoints move, intervals appear and disappear, symbols delist, auth
schemes rotate, rate ceilings shift. Today that is discovered by something breaking, and
usually breaking quietly.

Across a family of seven packages the problem is worse than it was inside one host app:
the knowledge about a venue now lives in a published artifact with its own release cycle,
and a consumer three versions behind has no way to know their `Capabilities` declaration
stopped matching reality. **This doc is for the question the extraction plan raises but
does not answer: how does a vendor change get noticed, and how does the fix reach the
people running the old version?**

It is deliberately being started empty-ish. The plan will surface real instances — it
already has, before a line of code is written — and those are worth more than anything
designed up front.

## What already exists in the plan, for other reasons

Nothing here was built as a change detector, but each is one:

- **Tier-2 tests** (D7) — tagged tests against live public endpoints, cadence unresolved
  (OQ17). If a venue changes what it serves, these are what fail. This is the closest
  thing to a detector the plan contains, and it is currently justified as fidelity
  checking rather than change watching.
- **Committed vendor documentation** (D13) — required for provenance, so a stranger can
  see what a package was built against. But a committed snapshot is also **diffable**: the
  next time the docs are fetched, what changed is computable. That was not the reason for
  the rule and is a free consequence of it.
- **Catalog-change notices** (D14) — pairs added, removed, delisted, pushed rather than
  polled. Already a change signal, scoped to the catalog.
- **`coverage/1`** (D6) — observed-not-intended delivery. Detects a stream degrading,
  which is often the first symptom of a venue-side change.
- **Capabilities as declarations** (§5.0) — every venue states what it can do. A
  declaration is checkable against reality; nothing currently checks it on a schedule.

## Known instances, already

Two before implementation even starts, both from the host:

- **Coinbase `FOUR_HOUR`** — the venue served a candle width the adapter did not declare,
  silently substituting 1h. Found by probing on 2026-08-06. A caller asking two venues for
  "4h" got real 4h from one and mislabelled 1h from the other.
- **Webull's broker host** — three different values over time, the first two from a
  third-party write-up and a reverse-engineered SDK. The vendor's own page had it right the
  whole time.

Neither was detected by a system. Both were found by someone looking.

## Questions worth carrying into the work

- Which of the pieces above, wired together, would have caught `FOUR_HOUR` without anyone
  looking? Is that a scheduled tier-2 run, a docs diff, or a capability audit against a
  live endpoint?
- **Docs diffing**: is fetching and diffing a vendor documentation site tractable, or does
  it drown in noise? Does a vendor changelog exist and is it honest?
- **Propagation** is the half nobody has thought about. A venue change becomes a patch in
  one package. The host pins `~> 0.1`. What tells a consumer their pinned version now
  disagrees with the venue — and is that a notice (D14), a release note, or something that
  does not exist yet?
- **Cross-venue**: when one venue changes something structural, do the others follow? Is
  there value in noticing that two venues moved the same way?
- What is the honest **latency target**? Detecting a delisting within a day is a different
  system from detecting it within a month, and only one of them is worth building.

## How this doc gets filled in

Not by design work now. By the plan's own retrospectives — Phase 5.14 after Coinbase and
Phase 8.3 at close both ask what was learned, and anything about noticing vendor change
lands here rather than in the plan. Six extractions against six vendors' documentation is
a good sample, and it is being gathered anyway.

Delete this file when the work lands.
