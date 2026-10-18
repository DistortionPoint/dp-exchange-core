# Sent-Once Calls and Write-Rule Assertions - Design Document

**Date**: 2026-10-18
**Status**: Implementing
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AL)

## Project Overview

### Objectives

- [ ] A call that is always sent exactly once, whatever the caller passes, does not accept
      `:retry_attempts` or `:retry_delay`. A caller passing either, at any value (0 and 1
      included), gets `{:error, {:unknown_option, key}}` before anything is sent, from the
      real path and from the Fake.
- [ ] Conformance group 43 (unknown options are refused) covers every endpoint the suite can
      call on a Fake, not five reads.
- [ ] The venue write rules W1 to W7 (`DpExchange.Core.Venue`) are asserted on the Fake where
      a Fake can show them: W4 amounts, W5 return types, W6 unknown ids.
- [ ] HTTP error mapping in `Core.HttpClient` and in each venue handles Retry-After, error
      bodies and 5xx-on-write as documented.

### Scope

**In Scope:** the per-venue key tables of the sent-once calls in all five venues and their
Fakes; `Core.AdapterContract` groups 43 and new groups from 47; `Core.Venue` W-rule text;
`Core.HttpClient` error paths; the docs that describe each.

**Out of Scope:** retries of writes that carry an idempotency key the venue honours. They
keep both keys.

### Why

Tick AK made the family rule "a call accepts a transport key only if it reads it". Writes were
left inconsistent:

- Schwab accepted `retry_attempts:` 0 or 1 on order writes, and refused higher values.
- Gemini refused the key outright.
- Coinbase and Robinhood accepted it on some sent-once paths, then overwrote it with
  `Keyword.put(opts, :retry_attempts, 1)`.

The overwrite is the silent-ignore bug from tick AK, applied to retry keys. A caller who passes
`retry_attempts: 3` to `cancel_order/3` thinks they asked for retries and got none. Refusing
any value is the only reading that matches "only where read". `0` or `1` on a call that is
already sent once asks for nothing.

Before this tick, group 43 probed `get_price`, `get_top_of_book`, `get_symbols`,
`get_order_book` and `get_trades`, so a write or a credentialed read could still ignore a
misspelt key. The W rules said "not part of the conformance suite yet", so only each venue's
own tests held them.

## Decisions

1. **The refusal is `{:unknown_option, key}`, not `{:unsupported_option, key}`.** The key is
   absent from the call's table, which is exactly what `Core.Options.check/2` reports.
   `:unsupported_option` stays for a key that is in the family vocabulary, that the call
   reads, and that has a value the venue cannot honour (for example a Robinhood
   `:environment`).
2. **Internal `Keyword.put(opts, :retry_attempts, 1)` stays.** It is what makes the call
   sent once whatever `Core.HttpClient` defaults to. Only the caller's ability to pass the
   key changes.
3. **The W groups run on the Fake only.** W6 says a Fake refuses what the real path refuses,
   through the same validators, so a Fake assertion is evidence about the real path's
   validation. It is not evidence about transport.

## Checklist

- [ ] Core: group 43 extended; groups for W4, W5 and W6; reference venue passes; teeth tests;
      usage-rules/testing.md; venue.ex W-rule sentence; CHANGELOG.
- [ ] Core: HttpClient Retry-After and error-body review.
- [ ] Coinbase: sent-once tables; error mapping; hot paths; vacuous tests; REST vs vendor spec.
- [ ] Gemini: same.
- [ ] Webull: same, with the first full REST read against the vendor spec.
- [ ] Robinhood: same.
- [ ] Schwab: same, removing the 0-or-1 allowance.
- [ ] Every venue passes the new Core groups after `deps.update dp_exchange_core`.
