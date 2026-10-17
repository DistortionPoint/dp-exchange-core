# Unknown Option Refusal - Design Document

**Date**: 2026-10-17
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AJ)

## Project Overview

### Objectives

- [x] A facade call given an option it does not read answers `{:error, {:unknown_option, key}}`
      instead of silently ignoring it.
- [x] One shared helper in Core, so the five venues cannot drift on the tag or the check.
- [x] A conformance group that proves every venue's Fake does it.

### Scope

**In Scope:** every public facade function of every venue that takes a keyword `opts`
argument, and its `Fake` twin; Core's helper, conformance group and docs.

**Out of Scope:** `child_spec/1` / `start_link/1` supervision options (venue supervisors
validate their own start options already); internal modules called only by the facade.

### Why

Tick AJ found misspelled options silently ignored in Gemini (`too:` on `subscribe`), the
same shape in Core (`use AdapterContract` options, `DefaultRateLimiter.start_link(limit:)`,
both fixed in 0.3.100). A misspelled `limt:` or `sinse:` returns a plausible answer to a
different question than the caller asked — exactly the "nearby substitute" CLAUDE.md names
as the family's recurring failure. Fail closed.

## Subtask Checklist and Progress Tracking

- [x] **Core**: `DpExchange.Core.Options` — `transport_options/0` (keys every facade call may
      carry: credentials, test seams, retry/timeout/limiter knobs), `check/2`
      (`opts, allowed` → `:ok | {:error, {:unknown_option, key}} | {:error, {:invalid_options, opts}}`
      for a non-keyword list). `@doc`/`@spec`, tests, CHANGELOG, `usage-rules/adapter.md`.
      *Found:* `transport_options/0` is the union of what the five venues' `request_opts/1`
      `Keyword.take` lists forward (limiter, timeout, retry_attempts, retry_delay, log_requests,
      plug, req_adapter, rate_limit_blocking) plus `Core.HttpClient`'s documented caller knobs
      (weight, max_retry_after_s, max_body_bytes) and credentials, environment, base_url,
      adapter. `provider`, `rate_limit_key`, `raw_status`, `decode_body` are set by the venue
      itself and are not caller options, so they are out. `ssl_options` is socket-only
      (`start_link`), out of scope. `adapter.md` previously said unknown options are ignored;
      that bullet was replaced.
- [x] **Core**: conformance group 43 — supported reads on the Fake (`get_price`,
      `get_top_of_book`, `get_symbols`, `get_order_book`, `get_trades`, with the venue's
      `endpoint_opts`) given `[dp_contract_unknown_option: true]` answer
      `{:error, {:unknown_option, :dp_contract_unknown_option}}`; `{:error, :not_supported}`
      stays legal for an unserved endpoint. Documented in `usage-rules/testing.md`.
      *Found:* decision is the public `AdapterContract.unknown_option_fault/1` (teeth-tested);
      the group runs on the Fake only and passes vacuously for a venue that declares all five
      reads unsupported. Core's `ReferenceVenue` now refuses on the five reads. Releasing this
      makes every venue's Fake fail group 43 until it adopts `Options.check/2`.
- [x] **Coinbase / Gemini / Webull / Robinhood / Schwab**: every facade function with opts
      calls `Options.check(opts, transport ++ <its own keys>)` at the facade boundary (before
      any internal key such as `:limiter` is added); Fake identical (parity); usage-rules
      lists each function's options; CHANGELOG (breaking: a caller passing a stray key now
      gets an error); floor `~> 0.3.101`.
      *Found:* each venue now keeps one per-function key table (`OptionKeys` in Coinbase and
      Gemini, `Options` in Webull and Schwab, `Rest.function_options/1` in Robinhood) shared by
      facade and Fake. Coinbase, Robinhood and Schwab had grown local checks earlier the same
      tick; all three were folded onto `Core.Options`. Plain-value reads with no error channel
      (`coverage/1`, `wanted/1`, `coverage_by_kind/1`, `status/1`, `live?/1`) raise
      `ArgumentError`. Two traps surfaced at the gate: a family option the contract names
      (`:limit` on `get_order_book/2`) must stay in the allowed list so its specific
      `{:unsupported_option, :limit}` answer fires (group 38), and group 31 reuses the placed
      order's options for `cancel_order/3` unless `endpoint_opts:` declares cancel's own.
      About a dozen existing tests passed keys their call never read (`account_id`, `to:` on
      `update_symbols`, the whole feed start list to streaming calls); those tests were
      corrected, never the allow-lists widened.

## Design

**Check order.** Positional arguments first (subscriber, symbols, symbol, range — the order
in the family error conventions), then options, then credentials. An option error is a
caller error decided before anything is sent, so it is plain `{:error, _}`, never
`:order_unconfirmed`.

**Unserved endpoints.** A function that answers `Venue.not_supported()` keeps doing so
regardless of options: the endpoint's absence is the more useful answer.

**Pass-through options.** Where a facade forwards a sub-map of options (e.g. HTTP knobs to
`Core.HttpClient`), the forwarded keys are part of that function's allowed list — the venue
names them, Core supplies the shared ones through `transport_options/0`.

**Breaking change.** Callers that relied on a stray key being ignored now get an error. That
is the intent; each venue's CHANGELOG says so.

## Retrospective (2026-10-17)

Shipped in one tick: Core 0.3.101 (`Options`, group 43) and all five venues on it. What
worked: putting the check in Core first, with a conformance group, turned five independent
judgement calls into one rule a gate could hold. What did not: the first per-venue passes each
invented their own tag for a non-keyword list (`{:invalid_option, :opts, v}` in two venues)
before the design was written — the design doc should come before the first venue edit, not
after, which is what DDD says. Agents' instinct under a failing test was to widen an
allow-list; the brief's explicit "fix the test, never widen to pass" was needed and held.
Gap left open by design: group 43 only probes five reads on the Fake; each venue's own
table-driven `unknown_option_test.exs` covers the rest of its facade.
