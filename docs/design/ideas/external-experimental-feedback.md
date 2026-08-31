# External feedback on experimental packages

**Date:** 2026-08-27
**Status:** Idea (not worked out — architect has directions in mind)
**Related:**
  - `docs/design/closed/2026-08-26_exchange-adapter-package-family.md` (D7 tier 3, D15) — the plan
    that surfaces the need and deliberately does not solve it
  - `../dp_crypto_management/docs/bugs/fixed/` — 13 hand-written reports the host filed
    against `influx_elixir`'s `Client.Local`; the informal version of this loop, and proof
    it works when the reporter is internal

## Concept

The exchange packages publish to public hexpm marked EXPERIMENTAL (D15), and graduate only
when a real consumer trades live on that venue and exercises the whole API. For most venues
that consumer is `dp_crypto_management`.

For two it cannot be. The architect cannot hold accounts on **Binance** or **Kraken** from
their jurisdiction, and Binance's public API is geo-blocked from there as well. No amount
of host work graduates those packages. The only route to authenticated coverage is
**somebody else** — a user who already holds an account on that venue, running the
package's authenticated tests against their own credentials and telling us what broke.

That is a real need, and making it *easy and safe* is a design problem in its own right.
This doc is a placeholder for that work, not a solution to it.

## What the plan already fixes

D7 sketches the shape of an authenticated test tier and constrains it, and those
constraints hold regardless of how the rest is designed:

- **Inert by default.** Never on `mix test`, never in CI, never as a side effect.
- **Credentials from the environment**, never a fixture, and **redacted from every line of
  output**. A leaked API key in a public issue is worse than every bug it could find.
- **The reporter files, not the suite.** No automatic posting from a stranger's machine to
  a public repo — it invites credential leaks and spam, and removes the one human who can
  tell a venue outage from a package bug.
- **Money-moving stays out.** Reading balances and fees is one thing; placing orders with
  someone else's funds is not something to ask of a volunteer.

## What is not worked out

Nearly everything else, and the architect has directions in mind that this doc does not
capture yet. Open at minimum:

- **What makes a stranger willing to do this at all?** Running an unfamiliar test suite
  against live API keys is a large ask. What reduces it — a container, a dry-run mode, a
  read-only key scope, a clear statement of exactly which endpoints get called?
- **What does a useful report contain**, and how much can be gathered automatically without
  ever touching a secret?
- **Where does it live?** Shared scaffolding in Core, per-venue, or a separate tool
  entirely. (The plan briefly had this as an open question inside Core; it is not a Core
  question until the shape is known.)
- **How does a report become a fix?** The influx-elixir loop worked because reporter and
  maintainer were the same team. Across that boundary, triage, reproduction and trust all
  get harder.
- **Is testing even the right frame?** A user simply *running* an experimental package and
  reporting what went wrong may be worth more than any suite they execute deliberately.

## Why it is not in the plan

The extraction plan's job is to produce eight packages behind one facade. This is about
what happens to them afterwards, it needs design work that has not happened, and nothing in
Phases 0–8 blocks on it. Binance and Kraken staying experimental indefinitely is an
acceptable outcome of that plan; it is this doc's job to eventually make it unnecessary.

Delete this file when the work lands.

## One constraint worth knowing before designing this

**No venue in the family has a working sandbox** (plan D7, OQ16, answered 2026-08-27).
Some advertise one that does not function. So there is no safe rehearsal environment to
point a contributor at: anything authenticated runs against their real account, which
raises the ask considerably and shapes every option above.
