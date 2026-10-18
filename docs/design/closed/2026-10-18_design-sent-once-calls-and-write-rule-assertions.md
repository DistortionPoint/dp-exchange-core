# Sent-Once Calls and Write-Rule Assertions - Design Document

**Date**: 2026-10-18
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AL)

## Project Overview

### Objectives

- [x] A call that is always sent exactly once, whatever the caller passes, does not accept
      `:retry_attempts` or `:retry_delay`. A caller passing either, at any value (0 and 1
      included), gets `{:error, {:unknown_option, key}}` before anything is sent, from the
      real path and from the Fake.
- [x] Conformance group 43 (unknown options are refused) covers every endpoint the suite can
      call on a Fake, not five reads.
- [x] The venue write rules W1 to W7 (`DpExchange.Core.Venue`) are asserted on the Fake where
      a Fake can show them: W4 amounts, W5 return types, W6 unknown ids.
- [x] HTTP error mapping in `Core.HttpClient` and in each venue handles Retry-After, error
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

- [x] Core: group 43 extended; groups for W4, W5 and W6; reference venue passes; teeth tests;
      usage-rules/testing.md; venue.ex W-rule sentence; CHANGELOG.
      Found:
      - Group 43 now probes every active callback the Fake defines. The five original reads are
        judged on the probe alone. Every other endpoint is judged only when the same call
        without the probe succeeds, because a Fake refusing generated args never reached its
        options. Exclusions are listed with reasons in `unknown_option_exclusions/0`.
      - New groups: 47 (W4 amounts), 48 (W5 staking returns) and 49 (W6 unknown order id).
        Group 49 needed a new `unknown_order_id:` option, because Gemini and Schwab ids are
        numeric and a malformed id is rightly `:invalid_order_id`.
      - W1, W2, W3 and W7 stay unasserted. They need a fault injected after the send, or a venue
        body to decode. `Venue` now says so.
      - The reference venue checked no options on most calls, and its W6 answers were wrong.
        Both are fixed.
- [x] Core: HttpClient Retry-After and error-body review.
      Found:
      - Retry-After parsing was correct. Tests now pin garbage, empty, negative, huge and
        year-9999 values.
      - A non-UTF-8 error body put invalid text in the error tuple. It is now inspected.
      - A non-2xx body labelled JSON that did not decode lost its HTTP status: Req replaced the
        response with a decode error. So a 429 lost its Retry-After and bucket hold and was
        retried, and a 4xx was retried. Non-2xx bodies are now held back from Req's decoder and
        decoded leniently afterwards.
- [x] Coinbase: sent-once tables; error mapping; hot paths; vacuous tests; REST vs vendor spec.
      Found:
      - Retry keys:
        - Eight sent-once calls accepted the retry keys and then overwrote them. They now
          refuse them.
        - The first fix checked `get_conversion` against `commit_conversion`'s table, which
          made the read refuse its own retry keys. The gate caught it.
      - Group 49: an unknown cancel answered `{:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}`. The
        spec titles that reason "Internal error", so mapping it straight to `:not_found` would
        have been a guess. The real path now confirms with one `get_order` read, and only a
        `:not_found` read answers `:not_found`.
      - REST vs spec:
        - `TRADE_STATUS_EXPIRED` and `TRADE_STATUS_FAILED` were mapped though the spec's
          `TradeStatus` has neither. They are now refused as unknown statuses.
        - Prime staking metadata accepted any map. The spec defines only `external_id`.
        - Validator paging went unchecked against the 1000 maximum and the `ASC`/`DESC` enum.
        - Wallet staking documents a repeated idempotency key as failing, but the docs said it
          returned the original.
      - Tests: `refute_receive` windows of 0 to 100 ms were raised to 500 ms.
- [x] Gemini: same.
      Found:
      - Retry keys: `:retry_delay` was still accepted on sent-once calls and on the OAuth
        refresh.
      - `get_transactions` `:since`: an integer was read as nanoseconds, where every other
        `:since` is milliseconds. A millisecond value silently fetched the whole history. It is
        now milliseconds.
      - W4: amount failures used `{:non_positive_amount, …}` and `{:invalid_decimal, …}`. They
        are now `{:invalid_amount, value}`.
      - `transfer_internal`:
        - It checked the accounts before the amount. The amount now comes first.
        - The Fake refused `:credentials` in the terms argument.
      - Tests: five assertions tightened from `{:error, _}` to exact shapes.
- [x] Webull: same, with the first full REST read against the vendor spec.
      Found:
      - Retry keys: twelve sent-once calls overwrote the caller's value.
      - 4xx answers:
        - Every 4xx on a write was reported as unconfirmed, so a declined order read as
          possibly live.
        - A 4xx on a read was retried.
        - Both are now refusals.
      - The venue's 429 on a write was wrapped as unconfirmed. The docs say there is no
        partial processing, so it is now a plain error.
      - Refusals dropped the documented `error_code`. They now keep it.
      - REST vs spec:
        - `trailing_type` was never sent, so the venue chose between a dollar step and a
          percentage step. It is now required.
        - The capital-flow `count` range 1 to 5 was unchecked.
        - The watchlist category and the futures replace-direction rules were unchecked.
        - `x-version` pins v2 while the vendor default is v3. This is recorded as unmeasured.
      - Tests: `refute_receive` windows raised to 500 ms.
- [x] Robinhood: same.
      Found:
      - Retry keys: `cancel_order` overwrote them.
      - Options: `market_status/1` checked no options at all.
      - Two quadratic paths, `ids -- Enum.uniq(ids)` and the feed's `acc ++` per chunk.
      - Tests: request-path and order-type tests asserted with `refute =~` only. They now
        assert exact values.
      - REST vs spec: every enum matched.
- [x] Schwab: same, removing the 0-or-1 allowance.
      Found:
      - Retry keys:
        - Order writes accepted 0 or 1.
        - The read-back after an accepted write fell to Core's default backoff once callers
          could no longer pass 0. It is now a single attempt.
      - Venue values were quoted unbounded into error tuples.
      - Tests: ten facade tests that asserted only `{:ok, _}` now assert the request path and
        the result shape.
      - REST vs spec: everything matched.
- [x] Every venue passes the new Core groups after `deps.update dp_exchange_core`.
      Found: all five pass on Core 0.3.107. The `mix.exs` floor was raised to `~> 0.3.107`
      for the `HttpClient` status fix.

## Retrospective

**What worked.** The audit predicted which fakes would fail each new group, with
`file:line` evidence, before anything ran, and every prediction was confirmed or answered.
Running each repo through the gate as soon as its agent finished caught three regressions
before they could be pushed:
- a compile error from mixing keyword and `=>` map syntax;
- a read checked against a write's key table;
- an unused default argument left after an edit.

**What did not.**
- **First reports were incomplete.** Four of the six agents first reported their lenses
  "done" after sampling. Each had to be sent back for the full read, and the full read found
  real bugs every time:
  - Gemini: the `:since` unit;
  - Schwab: unbounded venue echoes;
  - Coinbase: invented statuses and Prime metadata;
  - Webull: `trailing_type`.

  "Sampled" is not done.
- **Two wrong orchestrator instructions.** One told an agent to map a vendor reason to
  `:not_found`, which is a substitution. The other told Schwab to check options before
  positional arguments, which contradicts Core's documented order. The agents pushed back on
  both, rightly.

**Carry forward.**
- A vendor reason code is mapped to a family tag only when the vendor's text says what it
  means. Otherwise the tag is confirmed by a read, or the reason is kept.
- When an agent's report says "partial", "sampled" or "not audited", that is a finding
  against the brief, not a result.
