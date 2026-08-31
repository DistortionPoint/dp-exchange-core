# `dp_exchange_binance` and `dp_exchange_kraken`

**Date:** 2026-08-27
**Status:** Idea (deferred out of the extraction plan, 2026-08-27)
**Related:**
  - `docs/design/closed/2026-08-26_exchange-adapter-package-family.md` — D11 extraction order,
    D13 documentation-first, D15 experimental labelling. Both venues were in scope there
    until this doc took them out.
  - `docs/design/ideas/external-experimental-feedback.md` — the mechanism that would make
    either of these packages verifiable by someone who is not the architect. That doc's
    main use case is now *this* doc.

## Why these two are not in the extraction plan

The architect cannot hold an account on either venue from their jurisdiction. The host's
own architecture doc puts it plainly for one of them —
`docs/architecture/exchange-capabilities.md`, "Excluded Exchanges": *"Binance/Binance.US —
Not available to Texas residents. Regulatory issues in US."* Kraken's adapter records the
same conclusion from the other direction: *"No active strategy on Kraken. Nothing to
collect."*

That is not a labelling problem the plan could have solved. Under D15 a package graduates
out of EXPERIMENTAL when the host trades live on that venue and exercises the core set.
Neither of these can ever reach that, because the trading half is closed to us. Extracting
them would have meant owning, publishing, versioning and maintaining two packages that are
**permanently unverifiable above tier 2** — and one of them not even that, without a
manual step.

The plan already carried the machinery to describe that state honestly. It should not have
to carry the state itself. So both come out, and the family this plan ships is five venues
the host actually runs on plus greenfield Schwab, all of which can graduate.

**The names stay reserved** (D10's rule: reserve what is planned or lives in an idea doc —
this file is that idea doc). The empty `dp-exchange-binance` and `dp-exchange-kraken`
repos stay empty and stay ours.

## What each would take, and what makes them different

They are grouped here because the *reason* they are out is shared. The work is not.

### Kraken — the easy one, blocked only on an account

Kraken's public API answers directly, and the host has already measured it. From
`kraken/provider.ex`, 2026-08-05, `/0/public/AssetPairs`: 1,430 pairs, 1,410 `online`, 22
quote assets, with the legacy asset codes canonicalised in place (`ZUSD`/`ZEUR`/`ZGBP` are
the fiat forms, `XXBT` and `XETH` are BTC and ETH — the raw codes match nothing else in
the system, which is itself a `SymbolFormat` round-trip worth keeping).

So Kraken can be built, documented from Kraken's own docs (D13), faked (D7 tier 1) and
tier-2 verified against live public endpoints with no VPN and no manual step. It reaches
exactly the ceiling the plan's other venues reach before they graduate. **The only missing
piece is an account.** Whoever has one finishes it.

Host source when this is picked up: 3 files, ~2,002 LOC, `WebSockex` + `Logger`, frame
WebSocket. Under D20 it would carry its own transport and its own copy of the frame-send
guard — copied from `dp_exchange_coinbase`, moduledoc included.

### Binance — blocked on an account *and* on which venue it is

Binance is two problems stacked.

**Reachability.** `api.binance.com` is geo-blocked from here — every call returns
`{"code": 0, "msg": "Service unavailable from a restricted location..."}`. A VPN reaches
the public endpoints, but a VPN is a manual step, so tier-2 tests cannot run unattended.
Worse, Binance serves different catalogs, listings and fee schedules by region, and
nothing in a response says which region answered. **A VPN-taken measurement is not a
measurement of "Binance" — it is a measurement of Binance-as-seen-from-whatever exit node
was selected.** Any measurement taken this way has to record its exit region or it is
unusable.

**Identity.** There is no single venue called Binance:

| Endpoint | Answers from here? | What it is |
|---|---|---|
| `api.binance.com` | No — geo-blocked; VPN only | Binance global |
| `api.binance.us` | Yes | A **different legal entity** — 626 symbols, 265 trading (USDT 202, USD 54, BTC 5, USDC 4). Does not serve Texas residents |
| `data-api.binance.vision` | Yes | Read-only public mirror, 3,680 symbols. Market data only — can never trade |

The host's adapter is hard-wired to `api.binance.com` (`@base_url`, a module attribute)
and declares `default_quotes: []`, `supported_quotes: []`, `auto_collect: false` — it is a
registered provider that fetches nothing. Its `historical_timeframes` are declared from
Binance's published interval list and explicitly *not* measured, because no request ever
reaches the venue.

**The packaging position, if this is ever picked up: one package per entity, named for the
entity.** `api.binance.com` and `api.binance.us` are different companies with different
listings and different fee schedules. A package named `dp_exchange_binance` that talks to
Binance.US is mislabelled, and a configurable base URL just pushes the entity question
onto every consumer. The read-only mirror is not a venue at all — it is a data source that
can never satisfy D15, so it is at most a tier-2 fixture for a `.com` package, never a
package's target.

The line worth holding: **a separate package when it is a separate legal entity with its
own listings, fees and account** — not merely a separate hostname. Spot versus futures on
one account is a capability question inside one package; `.com` versus `.us` is not.

Host source when this is picked up: 3 files, 1,568 LOC, `WebSockex` + `Logger`. The
thinnest adapter in the family, and the least proven — 18 commits in 90 days against
almost no live exercise.

## What would change this

Any one of:

- **Someone else with accounts.** This is the concrete use case behind
  `external-experimental-feedback.md` — a stranger who can hold a Kraken or Binance
  account, run the tier-3 and tier-4 paths, and report back. Kraken is the better first
  target: everything except the account already works.
- **A jurisdiction change**, which would reopen Kraken immediately and Binance.US
  possibly.
- **A consumer who needs one.** These are public packages. If someone asks for Kraken and
  can verify it, the reserved name and the host's 2,002 LOC are the starting point, and
  D16's issue channel is how that conversation arrives.

## Not now, and not partially

The tempting middle path is to extract both anyway, publish them EXPERIMENTAL forever, and
let the label carry the honesty. Rejected: D18 says we own what we extract, and owning
code we can never verify past tier 2 is a maintenance liability with no counterweight —
two more packages to version, drift-check against a moving host (D19), and answer issues
about, with no route to ever proving any of it works.

Better to reserve the names, write down everything already known, and pick them up when
one of the three changes above happens.

---

## Note from Phase 8.1, 2026-08-31

Task 6.4 records a "name-holding publish" for both packages. **Neither name is on hexpm**
— `mix hex.info dp_exchange_binance` and `dp_exchange_kraken` both return *no package with
that name*. The repositories hold the reservation packages as described, and the local
commits exist, but no release was made and the repos were never pushed.

Recorded here rather than reopened in the plan: D21 put both out of scope, 8.1 no longer
gates on them, and nothing in scope depends on either name. Anyone picking this up should
know the names are **not** actually reserved on hexpm and could be taken by someone else.
