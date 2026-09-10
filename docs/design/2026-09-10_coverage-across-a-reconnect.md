# `coverage/1` Across a Transport Reconnect - Design Document

**Date**: 2026-09-10
**Status**: Approved
**Version**: 1.0
**Author(s)**: Claude, unattended sweep

## Project Overview

`Core.Venue.coverage/1` is documented as *"what is **observed arriving**, by which route —
never what was subscribed"*, and the `@doc` calls it **the strongest guarantee in the
contract**. It exists because intent standing in for evidence is how a venue reported 325
symbols subscribed and confirmed while 174 were delivering.

All four streaming venues currently let **stale evidence** stand in for current evidence
across a transport-level reconnect. That is the same substitution one level down, and it
hides the post-reconnect twin of the incident the callback was written for.

### The finding, measured

Every one of the four streaming sockets returns `{:reconnect, state}` from
`handle_disconnect/2`, so the socket **process survives** a transport drop. No `EXIT`
fires, and every existing reset path is keyed on a process death:

| Package | `handle_disconnect/2` | Clears delivery records on | Clears on `:link_down`? |
|---|---|---|---|
| `dp_exchange_coinbase` | `{:reconnect, state}` | shard **crash** (`drop_kind/3`) | **No** |
| `dp_exchange_gemini` | `{:reconnect, state}` | socket **crash** (`isolate_crashed_socket/2`) | **No** |
| `dp_exchange_webull` | `{:reconnect, …}` | shard **crash/removal** (`Map.drop`) | **No** — only flips `shard.connected?` |
| `dp_exchange_schwab` | `{:reconnect, …}` after backoff | socket **death** | **No** |

So between a drop and a successful resubscribe, `coverage/1` answers `:stream` for symbols
that are, at that instant, arriving from nowhere. And if the reconnect restores the socket
but the venue silently fails to restore *some* symbols — the 325/174 shape exactly — those
symbols keep answering `:stream` **indefinitely**, on the strength of frames observed
before the disconnect.

### The one written rationale for the current behaviour does not hold

`dp_exchange_coinbase`'s `socket.ex` is the only place that argues for it:

> `delivering` is left alone: a symbol that was streaming is reasonably still "was covered
> a moment ago" until the coordinator's resubscribe timer either revives it or its own
> staleness ages it out of whatever freshness a caller applies downstream.

The load-bearing clause is the last one, and it is false. `coverage/1` returns
`%{symbol() => route()}`. There is **no timestamp in the facade**, so there is no freshness
a caller can apply downstream. The comment defers to a mechanism that does not exist.

The other three packages wrote the opposite reasoning for their crash paths, and
`dp_exchange_webull`'s says it plainly: *"`coverage/1`/`coverage_by_kind/1` must not keep
answering `:stream` for a shard that just crashed … until this, `coverage/1` itself kept
lying in the meantime."* A transport drop is the same fact about the same symbols; only the
trigger differs.

### Objectives

- [x] Establish, per venue, what actually happens to delivery records on a transport drop
- [x] State in the contract what `coverage/1` means across a reconnect, so a consumer is
      not left inferring it from four implementations that disagree
- [ ] Make all four streaming venues honour it
- [x] Establish whether the rule can be carried by a conformance assertion (it cannot — see
      Phase 1, and the reason is recorded there rather than left as an open item)

### Scope

**In Scope:**

- `Core.Venue`'s `coverage/1` and `coverage_by_kind/1` documentation
- `Core.AdapterContract` — a new assertion group
- The `:link_down` handler in each of the four streaming feeds

**Out of Scope:**

- **A staleness window on streaming coverage.** Rejected deliberately. An illiquid pair may
  legitimately not print for hours, and Schwab's overnight silence is *correct* — a window
  would report `:not_covered` for healthy quiet markets, which is a false alarm and its own
  harm. Coverage stays "observed since this connection came up", full stop.
- `Core.PollingFeed`'s own window (`interval_ms * @coverage_grace`), which is right as it
  stands: a poll that did not answer within its own interval is genuinely not delivering,
  and that is a bounded, venue-independent statement a polling route can make and a
  streaming route cannot.
- The `delivering` map's clock source. Those timestamps are written and never compared in
  any of the four venues, so their clock source decides nothing. Left alone rather than
  changed for tidiness.

### Success Criteria

1. `coverage/1` answers `:not_covered` for a symbol whose link is down, in all four venues.
2. A reconnect that silently fails to restore a symbol is visible through `coverage/1`
   within one resubscribe interval, instead of never.
3. The rule is stated once in the contract's own `@doc`, so a fifth venue reading the
   callback documentation finds it before shipping.
4. `mix quality` clean and 0 test failures in all five affected repos, coverage at or above
   threshold.

## Subtask Checklist and Progress Tracking

### Phase 1: The contract

- [x] **`Core.Venue.coverage/1` `@doc`**: states that observation is scoped to the current
      transport session, records what all four venues were doing and why the crash-keyed
      resets never fired, and separates a polling route's staleness window from a streaming
      route's deliberate absence of one.
- [x] **`Core.AdapterContract`**: **not implementable, and not deferred — ruled out.** The
      suite is fake-driven, and a fake has no socket and therefore no `:link_down` to
      inject. Driving a venue's real tree is the approach assertion 18 already tried and
      rejected in writing: starting a venue's non-fake tree is not reliably network-free,
      and the only way around that is a venue-specific injection option name this suite is
      expressly forbidden from knowing. A static check over the compiled module was
      considered too — the `LinkSafetyCheck` precedent — and declined, because it would have
      to guess at each venue's own state-field and handler names to find anything, and a
      check that guesses is the substitution this family keeps writing rules against. The
      rule is therefore carried by the contract's `@doc` plus one behavioural test per
      venue, and this line exists so the next person does not re-derive the same dead end.
- [ ] **CHANGELOG** entry in Core

### Phase 2: The venues

- [ ] **`dp_exchange_coinbase`**: drop the link's delivery records on `:link_down`; replace
      the `socket.ex` rationale with what was actually found
- [ ] **`dp_exchange_gemini`**: same, on the single socket's `:link_down`
- [ ] **`dp_exchange_webull`**: same, per shard, keyed on the `:link_down` notice's
      `session_id` — the handler that already flips `shard.connected?`
- [ ] **`dp_exchange_schwab`**: same
- [ ] Each with its own test proving `coverage/1` narrows, and a CHANGELOG entry

### Phase 3: Batch

- [ ] All five repos gated, then pushed as one batch — a venue asserting the new rule
      against a Core that has not shipped it would fail its own conformance run

## Detailed Design

### What changes

On receiving its own socket's `:link_down` notice, a feed drops the delivery records for
the symbols that link was carrying — exactly the way each already drops them when the same
socket's *process* dies, and exactly the way `unsubscribe/2` drops a departing symbol's.
Nothing else moves: `wanted` is untouched, the resubscribe timer is untouched, the notice
still fans out to subscribers.

For a sharded venue this is per-shard: only the symbols on the shard whose session dropped.
A four-shard Webull feed losing one shard narrows coverage by that shard's symbols, not by
everything.

### What a consumer sees

A brief, truthful dip. `coverage/1` narrows at `:link_down` and refills as frames arrive
after the resubscribe — seconds, in a live market. The dip is already bracketed by the
`:link_down` / `:link_up` notice pair, which is what that pair is for.

This direction is the contract's stated preference, not a judgement call:

> A venue that cannot observe delivery answers `:not_covered` rather than reporting success
> it cannot see.

Under-reporting for a few seconds is the failure the contract asks for. Over-reporting
indefinitely is the one it was written to prevent.

### Why not drop at `:link_up` instead

Considered, and it is the narrower window — evidence from the old connection only stops
counting once the new one exists. Rejected because it reports `:stream` for the whole
duration of an outage, which is the plainly false answer in the plainly worst case: a
venue that is down for ten minutes would show full coverage for ten minutes. The point of
the callback is to make an outage visible.

## Retrospective

<!-- Appended on Implemented, before this document moves to docs/design/closed/. -->
