# Order-Write Discipline and Stream Lifecycle - Design Document

**Date**: 2026-10-19
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AM)

## Project Overview

### Objectives

- [x] Every process module in Core and the five venues is read in full for lifecycle defects:
      timers, backoff, unbounded state, link_up/link_down pairing, frames that crash or vanish.
- [x] Every decoder and every Fake or test body agrees with the vendor schema committed under
      `docs/reference/`: field names, types, and no field the schema does not define.
- [x] Every refusal the real path makes before sending, the Fake makes too, with the same tuple
      in the same order.
- [x] `Core.Types` constructors enforce what their own docs say they refuse.
- [x] `replace_order/4` and `preview_order/3` judge their input as `place_order/3` does, and
      the conformance suite asserts it.

### Scope

**In Scope:** Core's `PollingFeed`, `DefaultRateLimiter`, `HttpClient` retry loop, `Fanout`,
`Notice`, `Telemetry`, `LinkSafetyCheck`, every `Core.Types` constructor, every
`AdapterContract` group; each venue's socket, feed, supervisor, auth, REST decoders, Fake and
the test bodies that stand in for the venue.

**Out of Scope:** behaviour no committed document states and no probe has measured (Webull
crypto bars' `real_time_required`; whether Coinbase ends a level2 subscription when its
two-minute token expires on a feed of more than 116 shards). Both are recorded where the code
depends on them.

## Decisions

1. **A change map is partial by nature.** `replace_order/4` refuses a non-map or an empty map
   as `{:invalid_order_request, v}`, an unread key as `{:unsupported_order_field, key}`, and
   judges each present field (a present `nil` included) by its `place_order/3` rule. A field the
   map leaves out is not required: a venue that needs both fields reads the order for the
   other (Coinbase). Group 50 holds the empty, nil, string and keyword-list cases, and
   `preview_order/3` answering exactly what `place_order/3` answers.
2. **Group 17: a stripped credential is refused, never served and never a crash.** A raise,
   exit or throw fails the group (`credential_gate_fault/1`).
3. **A refused call changes no state.** A subscribe, update or unsubscribe answered with an
   error leaves `wanted` as it was (Webull's `call_undo`).
4. **One `:link_down` per outage.** websockex calls `handle_disconnect/2` again for every
   failed reconnect; only the first after a session reports. A deliberate shard retire closes
   its telemetry link with reason `:retired` and sends no notice, since it is not an outage.
5. **`status/1` has one shape on every route.** A field whose type depended on the route told
   the consumer how data arrives (Schwab), which is the leak the facade exists to prevent.
6. **A field the vendor schema does not define is a substitute source.** Removed from the
   Gemini and Webull decoders unless a captured response in `docs/reference/` shows it.
7. **Non-list `place_orders/3` input** is `{:error, {:invalid_argument, :requests}}`.

## Checklist

- [x] Core lens F: timers past what `Process.send_after/3` can arm refused at start
      (`PollingFeed`); a `:retry_delay` that would crash `Process.sleep/1` mid-retry refused
      before sending (`HttpClient`); an unsleepable limiter wait is a timeout that spends
      nothing; `PollingFeed` reports unrequested symbols when some are wanted.
- [x] Core lens G: 28 type files read in full; constructors now enforce their documented
      refusals (book prices and sizes, candle coherence, blank identifiers, signs, dates).
- [x] Core lens H: group 22 had no teeth (fixed); group 17 accepted a raise (fixed); group 50
      added; the reference venue checks ranges, volume-profile input, preview and replace.
- [x] Coinbase: level2 gap repair resubscribed into a session that replays nothing; it now
      unsubscribes then subscribes (probe 3 in `level2-session-limit.md`). link_down pairing;
      unusable ticker/l2 events reported; Fake public reads check credentials;
      `resubscribe_interval_ms` validated; group 50.
- [x] Gemini: documented clearing, transfer and staking filters exposed; status-map crash on a
      refused subscribe; in-flight depth diff after unsubscribe dropped; decoders read only
      schema fields (withdraw `status`/`txHash`, stake progress removed); Fake bodies and
      trade history match the schema.
- [x] Webull: `sub_types` lost after the first request; Fake refuses bad `sub_types` and
      missing credentials where the real feed does; refused subscribes revert `wanted`;
      undocumented aliases removed; Display vs Non-Display limits labelled; group 50.
- [x] Robinhood: `:timestamp` validated before signing; Fake refuses a bad `base_url`; the
      poller's fetch timeout covers the bisection budget; one link_down per outage; an idle
      feed closes an outage; test bodies match the v2 schemas.
- [x] Schwab: link_down pairing; unreadable frames and unrecognised notifies reported; a
      refused SUBS is a `:refusal` naming its symbols; refresh checks `:now` before spending
      the token; mutual-fund and cash-equivalent orders refused (vendor: EQUITY and OPTION
      only); a normally stopped feed takes its socket; vendored websockex survives a
      handshake raise and a failed close-frame send; `status/1` one shape; group 50.

## Retrospective

**What worked.** Sending back every report that said "sampled", "partial" or "grep-checked".
Each second pass found real defects the first had walked past: the Gemini stake decoder, the
Webull `wanted` leak a test had been reordered to avoid, the Schwab route-dependent status type,
stale coverage-matrix text hidden behind a banner, and four Fake bodies with string ids where
the schema says integer.

**What went wrong.**
- An agent "fixed" a failing test by reordering its assertions around a state leak. The leak
  was the bug. A test reordered to pass is a finding, not a fix.
- An agent derived an error tuple instead of reading it, and the test it wrote pinned the
  derivation. The gate caught it.
- A test that filled a TCP send buffer to force a close-frame failure flaked about one run in
  nine on macOS. It was replaced by a peer reset, whose second send is deterministically
  `:enotconn`, and a deliberate break of the fixed branch was used to prove the test reaches it.
- Agents still prefixed read-only shell commands with `cd`; no file was touched that way.

**What to carry.** A probe or rule written into Core's docs binds the venues whether or not a
group asserts it yet. Read every venue's implementation before writing the group, so the
venue impact is known before Core ships.
