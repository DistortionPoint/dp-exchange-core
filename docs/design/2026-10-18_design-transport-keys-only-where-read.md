# Transport Keys Only Where Read - Design Document

**Date**: 2026-10-18
**Status**: Implementing
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AK)

## Project Overview

### Objectives

- [ ] A shared transport key (`DpExchange.Core.Options.transport_options/0`) is accepted by a
      facade call only when that call reads it. A key the call cannot honour is refused.
- [ ] Every transport key a call accepts actually reaches `Core.HttpClient` (or the seam that
      reads it), and a test proves it.
- [ ] A call that sends no HTTP request (the streaming and plain-value calls) accepts no
      transport key at all.
- [ ] A conformance assertion holds the no-request half on every venue's Fake.

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

- [ ] **Core**: `Options` moduledoc and `transport_options/0` doc state the rule; group 46;
      CHANGELOG; `usage-rules/adapter.md`.
- [ ] **Coinbase**: key table and forwarding audited; no-request calls take no transport key.
- [ ] **Gemini**: same.
- [ ] **Webull**: same.
- [ ] **Robinhood**: same (forwarding and `:environment` done in tick AK's first pass).
- [ ] **Schwab**: same (forwarding, `:environment` and `:base_url` done in tick AK's first
      pass).
- [ ] Retrospective appended; moved to `docs/design/closed/`.
