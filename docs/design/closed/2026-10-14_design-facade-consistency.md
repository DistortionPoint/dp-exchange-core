# Facade Consistency (tick AD) - Design Document

**Date**: 2026-10-14
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (decided by the orchestrating agent on the
unattended loop, from the family conventions already recorded; no open questions)

## Project Overview

A read-only audit of the five venue facades against Core 0.3.92 (2026-10-14) found ten places
where two venues answer the same situation differently, or where a venue contradicts Core's
contract. A consumer that swaps venues behind the facade gets a different answer for the same
fact, which is the failure this family exists to prevent. This document fixes one answer for
each, and the venues move to it.

### Objectives

- [x] One reason for each situation below, documented in `DpExchange.Core.Venue` /
      `DpExchange.Core.Notice` and the venues' `usage-rules.md`.
- [x] Every venue's real path AND Fake produce it.
- [x] Conformance assertions hold the Fakes to the ones a Fake can be driven into.

### Scope

**In scope:** the ten findings below, in every venue that diverges.

**Out of scope:** order-book depth option names and candle `limit` (recorded as venue-specific
on 2026-10-11 and unchanged).

## Decisions

### D1. A well-formed symbol the venue does not list - `{:refused, :not_listed}`

Every single-symbol read (`get_price/2`, `get_top_of_book/2`, `get_order_book/2`,
`get_historical_prices/4`, `get_trades/2`, `quantization/1`, instrument reads) answers
`{:refused, :not_listed}` when the venue says it does not list the symbol, real and Fake alike.
No venue text rides in the reason (it is not stable across venues; log it if useful).

- Coinbase, Schwab: already conform.
- Gemini: `{:invalid_symbol, msg}`, `:invalid_symbol` and a not-listed `:refused` become
  `:not_listed`. (`:invalid_symbol` also collided with Core's local `{:error, {:invalid_symbol,
  v}}` input tag.)
- Robinhood: `{:venue_error, 400, "Invalid symbol: X"}` becomes `:not_listed`.
- Webull: the 4xx `INVALID_SYMBOL` that surfaced as a RETRYABLE
  `{:error, {:exchange_error, :webull, "HTTP 417..."}}`, and the 404 `:not_found` on a
  single-symbol read, become `{:refused, :not_listed}`. The Fake already says `:not_listed`.

An equity-only venue's refusal of a crypto pair keeps its own reason (Core venue.ex already
names it) but is a REFUSAL: Schwab's `{:error, {:not_an_equity_symbol, s}}` becomes
`{:refused, {:not_an_equity_symbol, s}}` - it will never succeed on retry.

### D2. A listed symbol with no current quote or book - `{:refused, :no_quote}`

- Webull: already `{:refused, :no_quote}`.
- Schwab `get_top_of_book` with no book: `{:error, :no_top_of_book}` (its own doc already said
  "Refused") becomes `{:refused, :no_quote}`.
- ~~Gemini `get_price` "'X' does not have available data yet" (`{:unknown_reason, msg}`)
  becomes `{:refused, :no_quote}`.~~ **Corrected the same day:** that text was measured live
  (2026-09-06) for a symbol that does not exist, so it names an unlisted symbol and is
  `{:refused, :not_listed}` (D1). Shipped wrongly in Gemini 0.2.139; conformance group 41,
  once Gemini opted in, failed on it, and the next release corrects it.

### D3. A poll-route `:link_down` is closed by a `:link_up`

Core describes `:link_down`/`:link_up` as a pair. Robinhood's feed and Schwab's fallback poll
route emit `:link_down` when a poll read does not answer or crashes and never emit `:link_up`,
so a consumer waiting for recovery waits forever. Both emit `:link_up` (once, latched) on the
first good poll after a `:link_down`, with the same `details.symbols` shape the venue's
streaming `:link_up` uses.

### D4. Notice kinds

Per `Core.Notice`'s own definitions:

- A sequence gap or an undecodable depth/book update is `:data_quality` (Coinbase already;
  Gemini's `:degraded` sites move). `:degraded` stays for "a slower path is in use".
- A venue refusing a subscription is `:refusal` carrying `details.symbols` (a list) - Coinbase's
  `:degraded` for non-auth, non-rate error frames that name a subscription moves; Gemini's
  `:refusal` gains `details.symbols`.
- `details.reason` is an atom or a tagged tuple, never free text. Venue free text goes in
  `details.message`, bounded. Core documents this; Gemini, Schwab and Webull sites that put
  `Bound.reason`/text in `:reason` move the text to `:message` and give `:reason` an atom.

### D5. `:credentials_rejected` is emitted wherever a stream or poll is refused for auth

Robinhood's poll turns a 401/403 into a plain error and only narrows coverage. It emits
`:credentials_rejected` (latched per feed, cleared on the next good poll). Gemini emits it if
any of its feeds authenticates; if none does, its usage-rules says so.

### D6. An account the credential does not hold - `{:refused, {:account_not_found, id}}`

Robinhood's `{:error, {:account_not_found, a}}` (retryable by contract) becomes a refusal, as
Schwab's already is. Core names the case.

### D7. Malformed credentials - `{:error, {:invalid_credentials, venue}}`

A credential value with surrounding whitespace or control characters is refused before
signing as `{:error, {:invalid_credentials, venue}}`, never echoed. Webull, which only checked
for blank values and signed `"key\n"`, adds the check. Robinhood's
`{:invalid_api_key | :invalid_private_key, :surrounding_whitespace_or_control_characters}`
becomes `{:invalid_credentials, :robinhood}`. Core documents the shape.

### D8. Plaintext URL refusal - `{:error, {:insecure_url, venue}}`

Coinbase `:insecure_websocket_url`, Gemini `{:insecure_url, option}`, Webull
`{:insecure_url, :wss_required}` / `{:insecure_oauth_url, :https_required}`, Robinhood
`{:insecure_base_url, scheme}` all become `{:insecure_url, venue}` (Schwab already). Core
documents the shape.

### D9. Ranges

- Malformed range: `{:error, {:invalid_range, range}}` - the shape decided on 2026-10-11.
  Coinbase (`{:invalid_range, start:, end:}`) and Gemini (`{:invalid_range, :start|:end, v}`)
  drifted back to their own and return to it.
- A range that starts before what the venue retains:
  `{:error, {:range_unavailable, timeframe, earliest: DateTime.t() | nil, requested: DateTime.t()}}`
  (Gemini's shape). Schwab's `{:lookback_exceeds_venue, tf, days, max}` moves to it. Core names
  it beside `:range_too_wide` and `:history_truncated`. Webull's `{:range_too_wide, count}` is
  the too-many-bars case and already conforms.

### D10. `wanted/1`

Core adds `wanted/1` as an optional callback: the symbols the consumer asked to stream, as
opposed to `coverage/1`, what is observed delivering. Coinbase, Gemini and Webull implement it;
Robinhood's Fake gains it; Robinhood's moduledoc stops calling `coverage_by_kind` "required
family-wide" (Core lists it optional).

## Also in this tick (performance leftovers)

- Core `CanonicalPair.aliases/1` rebuilds and upcases the alias map on every call (per
  message in the venues). Cached or precomputed once per mapping.
- Core `FakeInjection.by_symbol` keeps an empty list per symbol after its last pop.
- Vendored websockex (Coinbase, and any venue with the same copy) re-joins the whole buffer
  on each TCP chunk of a large frame, quadratic in chunk count.
- Webull shard stagger: the background-shard open timers are all armed at plan time, so a
  feed busy past their deadlines receives them back to back and dials in a burst (seen in the
  full gate: 4 us apart). Opens enforce the spacing when handled.

## Implementation checklist

- [x] Core: Venue/Notice docs for D1-D10, `wanted/1` optional callback, conformance where a
      Fake can be driven; CanonicalPair cache; FakeInjection prune.
      Found: Core returns none of D1-D10 itself, so the change is documentation
      (`Venue` moduledoc "One reason for each situation", `Notice` "Which kind a situation
      is" / link pairing / reason-vs-message, `usage-rules.md`, `usage-rules/adapter.md` and
      `testing.md`) plus `wanted/1` (optional; 89 callbacks, 4 optional; peripheral entry
      added). The reference venue itself contradicted D1 (`:symbol_not_listed`); fixed, with
      the teeth test that pinned it. Conformance: group 40 (`wanted/1`, runs when the fake
      exports it) and group 41 (opt-in `unlisted_symbol:` / `padded_credentials:`, skipped by
      default so no venue run changes). Not assertable without venue fixtures: `:no_quote`,
      `:account_not_found`, `:insecure_url`, the range reasons and D3-D5 notices (listed in
      `docs/reference/core/assertion-coverage.md`). `CanonicalPair` alias map cached in a
      `:persistent_term` keyed by the raw alias map, capped at 64 (pure `cache_lookup/3`
      tested; bound tested over 128 mappings). `FakeInjection` prunes the emptied
      `by_symbol` entry (and refuses to create one for `[]`). Core's own `PollingFeed` emits a
      `:coverage_change` on recovery, not a `:link_down` notice, so D3 does not apply to it.
      Not run: no gate (agents never run tests); the orchestrator gates.
- [x] Coinbase: D4, D8, D9 (invalid_range), D10; websockex buffer join.
      Found: an error frame names no product, so the socket now tracks what it was asked to
      carry and a `:refusal` names that set (a superset of what was refused, documented).
      websockex joined the buffer per TCP chunk; it now queues chunks and joins once the
      header's declared length has arrived (400 x 1 KiB frame test).
- [x] Gemini: D1, D2, D4, D5, D8, D9 (invalid_range), D10; websockex buffer join if present.
      Found: no Gemini feed authenticates, so `:credentials_rejected` is never emitted
      (stated in usage-rules). `InvalidSymbol` on `place_order` is `:not_listed` too.
      websockex had the same per-chunk join; fixed the same way (2 MiB in 1 KiB writes).
- [x] Webull: D1, D4, D7, D8, D10; shard stagger.
      Found: D1 covers every single-symbol read (bars of every category, volume profile,
      auction imbalance, fundamentals, event trades/book). Shard opens now carry their own
      message (`:open_staggered`) and enforce the spacing when handled.
- [x] Robinhood: D1, D3, D5, D6, D7, D8, D10 (Fake + doc).
      Found: the stream's per-symbol refusal keeps the venue's own reason (only the
      single-symbol reads map to `:not_listed`).
- [x] Schwab: D1 (not_an_equity_symbol tag), D2, D3, D4, D9 (range_unavailable); websockex
      buffer join if present.
      Found: Schwab's websockex is already linear (parse on an incomplete frame matches the
      header only), so no change. `earliest` uses the documented 10-day minute retention,
      not probed.
- [x] usage-rules.md and CHANGELOG in every repo.

Released 2026-10-14: Core 0.3.93; every venue on it (see each CHANGELOG).

## Retrospective

**What drifted and why.** Two of the ten (D9's `invalid_range` arity on Coinbase and Gemini)
had been decided on 2026-10-11 and drifted back within three days, because the decision lived
in a memory file and a moduledoc, not in an assertion. The rest were never decided: each venue
answered a situation the contract did not name, and each answer was locally reasonable.

**What held.** A read-only cross-venue audit found all ten in one pass, citing file:line, and
the fix was mechanical once one answer was chosen. The new conformance groups (40, 41) turn the
two drivable decisions into assertions; the rest stay documentation, listed as not assertable
in `docs/reference/core/assertion-coverage.md`.

**For next time.** A family decision that only a doc holds will drift. Where a Fake can be
driven into the situation, the decision goes into the conformance suite the same tick.
