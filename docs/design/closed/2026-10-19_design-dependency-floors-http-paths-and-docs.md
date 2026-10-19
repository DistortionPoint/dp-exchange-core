# Dependency Floors, HTTP Error Paths and Consumer Docs - Design Document

**Date**: 2026-10-19
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AN)

## Project Overview

### Objectives

- [x] Every runtime dependency call in Core and the five venues works at its declared floor
      (Elixir 1.18, OTP 28, decimal 2.0.0 and 3.x, jason 1.4.0, req 0.7.0, telemetry 1.0,
      websockex 0.5.1) as well as at the locked version, with the same answer.
- [x] Every HTTP call site reaches a documented error tuple for every response class, never a
      crash and never `{:ok, garbage}`; a possibly-sent write is unconfirmed.
- [x] `usage-rules.md`, README and guides name only functions, tuples and options that exist.

### Trigger

The scheduled dependency-floor check failed on Coinbase on 2026-10-19: `Decimal.lte?/2` was
added in decimal 2.2, and `mix.exs` admits `~> 2.0`. The package did not compile at its floor.

## Decisions

1. **A number reads the same under decimal 2.x and 3.x.** Decimal 3 refuses to parse a
   coefficient over 34 digits; 2.x accepts any. Every venue-read number is now bounded to 34
   digits and an exponent of ±1000 before it is used, so both versions answer alike.
2. **A GET never carries a body** (`Core.HttpClient`): Req 0.7.0-0.7.2 turned a GET with a body
   into a POST, retried as a read. Raised as `ArgumentError` before anything is sent.
3. **URL userinfo is a credential**: refused over plain http like a credential header.
4. **A wrong-kind 2xx is a shape error.** A JSON number where an object belongs (with
   `floats: :decimals` a `%Decimal{}` is a struct, so `is_map/1` held) is refused, not raised.
5. **A refused call restores everything it stored**: Webull's replay options, not only
   `wanted` (tick AM rule 3 extended). A call whose credentials cannot sign never replaces the
   stored ones.
6. **An expired access token is not sent** (Schwab), by the real path and the Fake alike; two
   overlapping refreshes of one refresh token are refused locally (`refresh_in_progress`).
7. **The floor is proven by the full suite, not only the conformance group.** The weekly
   script runs the contract test; this tick ran every venue's full suite at the floor once.

## Checklist

- [x] Coinbase: `Decimal.lte?` replaced (`not_above?/2`); a preview without `errs`/`errors` is
      `:unexpected_response_shape`; JWT minted per attempt and bound to method and path (tests).
- [x] Core: GET-with-body refused; userinfo over http refused; volume-profile keys and
      staking-rate text bounded across decimal versions; group 25 names a NaN level.
- [x] Gemini: 35-digit coefficients refused at both versions; fractional numbers in object
      positions refused (about 25 sites); object and row-list endpoints shape-checked;
      `get_deposit_address`, `create_account`, `rename_account` unconfirmed after a send; Fake
      refuses an unknown `nonce_mode`.
- [x] Webull: the long-unexplained `missing_required_field app_key` traced to a call with
      unusable credentials overwriting the replay credentials; fixed, and a refused call restores
      its replay options; `oauth_token` possibly-sent failures are `write_unconfirmed`.
- [x] Robinhood: every test file read; signature tests now verify the Ed25519 signature over
      path, query and exact body bytes; HTTP error classes covered.
- [x] Schwab: expired token refused before sending (real and Fake); refresh single-flight;
      Fake refresh dated from the real clock; vendored websockex diffed against 0.5.1.
- [x] Every venue requires Core `~> 0.3.111`; each venue's full suite passed at the floor.

## Retrospective

**What worked.** Reading the floor dependency's own CHANGELOG instead of recalling its API:
the Req GET-to-POST change and the decimal 3 parse limit were both found that way and both
confirmed against `deps/`. Probing a failing test's actual answer before deciding whether the
code or the test was wrong (Webull: the call answered `connack_timeout`, so reverting its
options was the rule working, and the test had asserted the old leak).

**What went wrong.**
- The floor check only runs the conformance suite, so a version-specific assertion elsewhere
  was never floor-gated. Two Gemini tests asserted a refusal only decimal 3 produces.
- A Webull fix restored the previous options before re-planning, so the cleanup unsubscribe
  went out without the caller's seam. Order of restoration is part of the fix.
- Schwab's new expiry refusal skipped the Fake, and the Fake's own refresh minted a credential
  already expired against its fixed clock. Fake parity has to be checked on every new refusal.

**What to carry.** When a dependency range spans a major version, the code must be written to
the intersection of both, and a test that pins one version's answer is a finding.
