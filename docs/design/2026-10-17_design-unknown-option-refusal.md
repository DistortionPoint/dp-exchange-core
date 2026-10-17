# Unknown Option Refusal - Design Document

**Date**: 2026-10-17
**Status**: Implementing
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AJ)

## Project Overview

### Objectives

- [ ] A facade call given an option it does not read answers `{:error, {:unknown_option, key}}`
      instead of silently ignoring it.
- [ ] One shared helper in Core, so the five venues cannot drift on the tag or the check.
- [ ] A conformance group that proves every venue's Fake does it.

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
- [ ] **Coinbase / Gemini / Webull / Robinhood / Schwab**: every facade function with opts
      calls `Options.check(opts, transport ++ <its own keys>)` at the facade boundary (before
      any internal key such as `:limiter` is added); Fake identical (parity); usage-rules
      lists each function's options; CHANGELOG (breaking: a caller passing a stray key now
      gets an error); floor `~> 0.3.101`.

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
