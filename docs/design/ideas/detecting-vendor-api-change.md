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

---

## Material from Phase 5 (Coinbase), 2026-08-28

Fed by 5.14's retrospective, per that task.

**A documentation page that could not be located at all.** Coinbase's rate limits are not
findable from the API reference index or from `llms.txt`; three URL guesses returned 404.
So the venue package declares its ceilings at rank 3 of D13's hierarchy — inherited from a
prior implementation — and says so in `measured_against`. **The detector question this
raises**: how would anyone notice if a vendor's documentation *moved* rather than changed?
A link check catches a 404. Nothing catches a page that still resolves and no longer says
what it said.

**A host comment whose stated evidence the venue contradicts.** `coinbase/provider.ex`
justifies a fix with *"an unrecognised enum returns EMPTY"*; the venue returns an explicit
parse error. The conclusion held, the evidence did not. **This is the interesting shape**:
the code was right and its recorded reason was wrong, so nothing failed and nothing would
have. A test asserting the *venue's* behaviour rather than ours would have caught it, and
that is what a tier-2 assertion is.

**A capability declaration is a claim with a shelf life.** `measured_at` and
`measured_against` exist now, so a declaration carries its own age. Nothing yet *reads*
that age. The obvious next step is a check that fails, or at least warns, when a `:proven`
or measured claim is older than some window and the venue has not been probed since —
which turns provenance from documentation into a mechanism.

**What tier 2 caught that nothing else could.** Three findings, none available from
documentation: 350 candles is a refusal rather than a truncation; no rate-limit headers are
published at all; the public and authenticated tickers share one shape where the adapter
assumed two. **All three are venue behaviour that changed or was never documented** — which
is exactly the class this doc is about, found by the cheapest instrument available.

---

## From Phase 6.1 (Gemini), 2026-08-28

**The negative result is the finding: a well-maintained changelog told us nothing.**
Gemini publishes a dated revision history going back to 2022-06, updated the day before we
read it. Gemini also, at some point, stopped documenting the WebSocket market-data
endpoint the host's entire price feed runs on — `wss://api.gemini.com/v2/marketdata` — and
replaced it with a different API at a different host. Searching four years of that
changelog: `marketdata` **0 hits**, `l2_updates` **0**, `v2/marketdata` **0**, `sunset`
**0**, `breaking` **0**. The two `deprecat*` hits are about prediction-market ticker
formats.

So the entire notice given for replacing a venue's streaming API was **its absence from
the new documentation site**. A consumer diffing the changelog — the obvious mechanism,
and the one this document was reaching for — would have seen nothing at all.

**What would have caught it**: diffing the *documentation's own index*, not its changelog.
The endpoint did not change behaviour and did not start failing; it stopped being listed.
That suggests the cheap monitor is a stored list of the endpoint URLs a package depends on
plus a periodic check that each still appears in the vendor's current documentation — a
link-rot check, not a behaviour check. It is the only instrument in this list that would
have fired here, and it costs one fetch per venue.

**Documentation moving is itself a signal, and it is easy to miss because it works.**
`https://docs.gemini.com/rest-api/` — the URL the host adapter's moduledoc cites — now
301s to a different site. A 301 is invisible to `curl`, to a browser, and to a reader. The
old content is gone; the redirect makes it look like a rename. **A permanent redirect on a
documentation URL a package cites should be treated as a change notice**, because in this
case it was the only one issued.

**Documentation can be wrong about the thing it exists to specify.** Gemini's candles page
lists seven `time_frame` values in an enum block; the live endpoint rejects three of them
and names its real set in the error body. The page also contradicts *itself* — prose says
`1day`, the enum list says `1d`, and only the prose is right. This is not drift between a
package and a venue; it is drift between a venue and itself, and no amount of watching the
package would find it. **Cheap rule: any documented value that is a literal the venue will
accept or reject should be probed, because probing it costs one request and the failure
mode is silent.**

**A venue that names its accepted set in the error body is a gift.** Gemini's 400 carries
`time_frame expects one of the following: [1m, 5m, 15m, 30m, 1hr, 6hr, 1day]`. That single
response is a machine-readable capability declaration, more current than the documentation
and free to obtain. Where a venue does this, an assertion can be written against the
venue's *own* statement of its enum rather than against a list copied into our code —
which is the difference between a test that notices a change and a test that has to be
told about one.

**The reverse also happened, and it is the more comfortable failure.** The host adapter's
timeframe mapping is *more correct than the documentation that replaced the documentation
it was written from*. It maps `1h → 1hr` because someone measured it on 2026-08-06; the
current docs say `1h`, which fails. A pure documentation-follows-vendor rule would have
regressed working code. **Measurement outranks documentation for anything measurable** —
recorded as a refinement to D13 in the main plan, not a contradiction of it.
