# Hot Paths, Process Identity and Secret Hygiene - Design Document

**Date**: 2026-10-20
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AO)

## Project Overview

### Objectives

- [x] No per-frame or per-row path does avoidable work, creates atoms from foreign text, or keeps
      a large document alive through a small slice of it.
- [x] Two instances of a venue run in one VM by naming only the tree; a feed process that
      crashes resumes what it had accepted, and says so.
- [x] No credential reaches a log, an error tuple, an exception message, telemetry metadata or
      a crash report, and the conformance suite proves it for running processes.

## Decisions

1. **Conformance group 51** (opt-in via `process_probe:`): the venue starts its long-lived
   processes with canary credentials, and `:sys.get_status/2` of each must not print one. All
   five venues wire it.
2. **A feed's accepted intent outlives the feed.** Each venue's tree starts a per-tree ledger
   before the feed; the feed writes it on every accepted change (never a refused one) and a
   restarted feed reads it in `handle_continue`, re-monitors its subscribers and resubscribes.
   Subscribers get `:coverage_change` with `details.reason: :feed_restarted` (documented in
   `Notice`).
3. **A tree named `name:` derives its children's names** (`<name>.Feed`, `.RateLimiter`, the
   ledger, Schwab's `.OrderLimit`). The default tree keeps its fixed names; an explicit name wins.
   Every facade call that addresses a process reads `:name`.
4. **Stopping a feed stops its sockets.** websockex never traps exits, so a `:normal` stop of the
   linked feed left sockets connected and reconnecting forever (Coinbase, Gemini, Webull).
5. **Refusals and errors never echo a credential.** `Options.check/2`, HttpClient error text
   (values a 401 body, transport error or query echoes back), `Notice`, venue option checks and
   bad-start paths now redact or name the kind only. Sent-frame telemetry no longer carries the
   Coinbase JWT; Gemini's `ssl_options` no longer print in reports or telemetry; Schwab's Streamer
   token is never cast or held bare; Schwab's refresh guard name is an HMAC, not an md5.
6. **Error text is bounded.** `Types.*` constructors, `AdapterContract` failure messages,
   `Telemetry.link_down` reasons and venue echoes are cut at a stated size (a 20,000-digit
   `Decimal` defeats `inspect`'s `printable_limit`, so the rendering is clipped too).
7. **Only a slice of 64 bytes or more can pin its document** (OTP 27+ copies shorter ones);
   long venue text kept past a call is copied, and retention tests use values over 64 bytes.

## Checklist

- [x] Core: group 51 with teeth; HttpClient scrubs echoed secrets; `Options`/`Notice` refusals
      redact; bounded messages; `child_spec` ids from `:name`; improper-list refusal (0.3.114).
- [x] Coinbase: JWT out of telemetry and crash-report mailboxes; FeedLedger; terminate stops
      sockets; derived names; bounded venue echoes; trade ids copied.
- [x] Gemini: Ledger; terminate stops the socket; `ssl_options` wrapped; depth frames O(1);
      derived names; redacted `invalid_options`.
- [x] Webull: WebSocket frame and fragment bound (4 MiB); terminate on `:normal`; Ledger; derived
      names; protobuf length checked.
- [x] Robinhood: credentials out of `invalid_options`; refused symbols probed singly instead of
      re-bisected (O(M) per cycle); derived names; Ledger.
- [x] Schwab: token wrapped and judged before LOGIN; expiry and refresh HMAC; long text copied;
      derived names; Ledger.

## Retrospective

**What worked.** Sending back every "reported, not fixed" item. The feed-restart loss was
named by one agent as "a redesign"; asking each of the other four to check found it in all five.
Running venue suites against the new Core before releasing them found a Core regression
(`Enum.map/2` over an improper list in the new redaction) that Core's own suite missed.

**What went wrong.**
- Retention tests asserted that a 10- to 21-byte slice pinned its document. On OTP 27+ it cannot,
  so the controls failed and several tests could never have caught the bug they named.
- A forwarded `name: nil` was made "the default name" on `Feed.start_link/1`, where it is the
  documented "start unnamed" seam; 116 tests failed until it was reverted there.
- `Module.concat(name, Feed)` with `Feed` aliased in scope expands to the full module name; the
  derived names use a string last segment.
- One venue chose a different notice for the restart; the family shape is now written in Core.

**What to carry.** A dependency's runtime behaviour (sub-binary copying, `inspect` limits that a
struct's own `Inspect` ignores) is part of the contract a test relies on; check it before
writing the control.
