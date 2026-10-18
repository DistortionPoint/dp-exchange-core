# Transport Keys Only Where Read - Design Document

**Date**: 2026-10-18
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AK)

## Project Overview

### Objectives

- [x] A shared transport key (`DpExchange.Core.Options.transport_options/0`) is accepted by a
      facade call only when that call reads it. A key the call cannot honour is refused.
- [x] Every transport key a call accepts actually reaches `Core.HttpClient` (or the seam that
      reads it), and a test proves it.
- [x] A call that sends no HTTP request (the streaming and plain-value calls) accepts no
      transport key at all.
- [x] A conformance assertion holds the no-request half on every venue's Fake.

### Scope

**In Scope:** the per-venue key tables of all five venues and their Fakes, every
`request_opts/1`-style forwarding list, `Core.Options` docs, and one conformance group.

**Out of Scope:** supervisor and `start_link/1` options; internal modules not called through
the facade.

### Why

The unknown-option design (closed, 2026-10-17) allowed `transport_options() ++ own_keys` on
every call, on the stated premise that "every venue forwards them to `Core.HttpClient`". The
tick AK audit measured that premise false in three venues:

- Robinhood accepted `environment: :sandbox` and sent the call, `place_order/3` included, to
  production; the venue has no sandbox. `:adapter`, `:weight`, `:max_retry_after_s` and
  `:max_body_bytes` were accepted and never forwarded, so `max_body_bytes: 1_024` bounded
  nothing.
- Schwab dropped `:adapter`, `:weight`, `:retry_delay`, `:max_retry_after_s` and
  `:max_body_bytes` on every REST call, and a forwarded `max_body_bytes: nil` removed the
  1 MiB token-response cap. `:environment` and `:base_url` were accepted and read by nothing:
  a `base_url:` sent a live token to production while the caller believed the call was
  redirected.
- Feed calls everywhere (`subscribe/2`, `coverage/1`, ...) accepted `:timeout`, `:plug` and
  the rest of the HTTP keys and could not read them.

An accepted key that does nothing is the "nearby substitute" again: the caller asked for a
cap, a host or a test environment and got the default. The allow-list is a claim about what a
call reads, and it has to be true.

## Design

1. `Options.transport_options/0` stays the vocabulary: the names and meanings of the shared
   keys. It is no longer stated as what every call accepts.
2. A call that sends an HTTP request allows `transport_options() -- not_read`, where
   `not_read` names each key the venue cannot honour on that call, with the reason
   (Schwab: `:environment`, `:base_url`). A key with a value the venue cannot honour (Robinhood
   `environment: :sandbox`) is `{:error, {:unsupported_option, key}}`.
3. A call that sends no request allows only its own keys (`:feed`, `:to`, ...) plus
   `:credentials`. Any other transport key there is `{:error, {:unknown_option, key}}`.
   `:credentials` is exempt, a decision made while writing group 46: the conformance harness
   (`arg_value(:opts, _)`) and consumers alike hand one credential set to every call, and a
   credential a call does not need changes no answer, so refusing it would buy breakage and no
   meaning.
4. Each accepted transport key is forwarded. The per-venue test proves it for at least
   `:weight` (the limiter sees it) and `:max_body_bytes` (an oversized body is refused).
5. Conformance group 46: `subscribe_notices(to: self(), timeout: 5_000)` on the Fake answers
   `{:error, {:unknown_option, :timeout}}`.

## Subtask Checklist and Progress Tracking

- [x] **Core**: `Options` moduledoc and `transport_options/0` doc state the rule; group 46;
      CHANGELOG; `usage-rules/adapter.md`. *Found:* Core's own `ReferenceVenue` accepted
      `timeout:` on `subscribe/2` and `subscribe_notices/1`, and group 46 failed it on the
      first run, so the group bites. Released in 0.3.104. *Corrected in 0.3.105:* group 46 also
      probed `subscribe/2`, and Webull's subscribe sends the venue's subscription request and
      reads the HTTP keys. It now probes `subscribe_notices/1` only, which sends nothing on any
      venue.
- [x] **Coinbase** (0.3.139): `:adapter`, `:req_adapter`, `:max_retry_after_s`,
      `:max_body_bytes` and `:log_requests` were dropped by all three forwarding lists, which
      are now a single `OptionKeys.forwarded/0`. `:environment` and `:base_url` are refused
      (the hosts are constants). The eight no-request calls take their own keys plus
      `:credentials`.
- [x] **Gemini** (0.2.150): five keys forwarded. The sent-once writes and the token refresh
      refuse `:retry_attempts` (it was forced to one attempt). The refresh also refuses
      `:environment` and `:base_url`, because it posts to `:auth_url`. Feed calls keep
      `:environment`, which selects the feed. *Found by the gate:* forwarding `:retry_delay`
      made a 1 ms retry land in the same epoch second, so the "fresh nonce" test saw two equal
      time-based nonces. That is legal in that mode, so the test now uses `:incremental`.
- [x] **Webull** (0.4.162): five keys forwarded on REST and on `Subscription`. `:base_url` is
      refused everywhere. `subscribe/2`, `unsubscribe/2` and `update_symbols/2` count as
      request calls. *Found:* a subscribe made before the shard connected stored only some
      keys for the replay, so the deferred request ran on Core's defaults; the replay now
      carries every key. `oauth_token/3` refuses `:credentials`, since the client id and secret
      are arguments.
- [x] **Robinhood** (0.3.110): every request call reads every shared key (forwarding was
      fixed in the first pass). Feed and local calls take their own keys plus `:credentials`,
      and the dead `{:unsupported_option, _}` raise branches were removed.
- [x] **Schwab** (0.2.142): no-request calls are now their own keys plus `:credentials`
      (`update_credentials/2` and `status/1` included). Order writes refuse `:retry_delay`.
      The refresh refuses `:retry_attempts` and `:retry_delay`. `:max_retry_after_s` is
      forwarded on the writes and the refresh, because Core reads it on a 429 even without a
      retry.
- [x] Retrospective appended; moved to `docs/design/closed/`.

## Retrospective

**What worked.** The rule was stated once, in Core, and each venue then made its key table
true by tracing what its own code reads. Every venue found keys it had dropped by mistake, and
those were forwarded rather than refused. Refusal was used only for keys a call can never
honour.

**What it cost.** Group 46 was wrong in its first release. It assumed `subscribe/2` sends no
request, which was true of four venues but not Webull. I wrote the probe from the four venues
I remembered rather than from all five, and 0.3.105 corrected it the same day. A conformance
probe has to be written against every venue's code, not a sample.

**Decided along the way.** `:credentials` stays allowed on every call. The harness and
consumers pass one credential set everywhere, and an unneeded credential changes no answer.
The venues differ on `retry_attempts: 0` for a write sent once: Schwab accepts `0` and `nil`,
and Gemini refuses the key outright. Both fail closed. The difference is recorded here and has
not been unified.

**The premise that broke.** The 2026-10-17 design said every venue forwards every transport
key, without having measured it. It was false in all five. That claim cost two design cycles
because it went unmeasured, which is the "declare what you measured" rule.
