# Time, Races and Truthful Docs - Design Document

**Date**: 2026-10-20
**Status**: Implemented
**Version**: 1.0
**Author(s)**: User/Claude Collaboration (unattended loop, tick AP)

## Project Overview

No GitHub issues were open at the start of tick AP, so the tick audits the family through three
lenses that earlier ticks did not cover in full.

### Objectives

- [x] **P. Time, clocks and timers.** Intervals and deadlines use monotonic time. Venue timestamps
      are parsed in the unit their spec states, and out-of-range values are refused. No stale timer
      acts on state it was not armed for. Signatures, nonces and JWTs are minted at send time.
- [x] **Q. Concurrency races and timeout layering.** A caller's call timeout never expires while
      the work it waits on is still going out. Messages from an old connection or generation are
      ignored. One subscriber's `:DOWN` never removes another subscriber.
- [x] **R. Documentation and test truthfulness.** Every claim in the README, `usage-rules.md`, the
      moduledocs and `capabilities/0` matches the code. Every test can fail against the bug it names.

## Decisions

1. **A unit is read as the vendor's page states it.** Where a page states milliseconds (Webull
   ticks and snapshots, Schwab quotes and charts), a seconds-sized number is refused, not guessed.
   The magnitude guess stays only where the page states no unit or allows both (Gemini staking:
   seconds or ms inside the 2015 to 2099 window of either). Robinhood documents ISO 8601 only, so
   it reads nothing else. An epoch value from before 2015 is refused.
2. **Every interval and deadline is monotonic.** Delivery stamps and rotation and quiet decisions
   (Gemini, Schwab, Webull) moved off `System.system_time`. A test that fakes a deadline sets it
   relative to `System.monotonic_time/1`, never `0`: the BEAM's monotonic clock is often negative.
3. **A credential is judged with a margin, from when it was sent.** Coinbase back-dates `nbf`
   5 s, and its window stays exactly 120 s. Schwab refuses a token within 5 s of expiry (the Fake
   too), dates a refreshed token from before the send, and warns subscribers with
   `:credentials_expiring` and `:credentials_expired` notices. A Robinhood retry re-signs with the
   clock even when the first attempt was pinned.
4. **A tick from a replaced timer or worker does nothing.** Core's bulk `PollingFeed` tick
   carries a token, Robinhood's poller reports carry a generation, and Webull's CONNACK deadline
   is per caller.
5. **A held call cannot outlive its caller.** Gemini refuses a call held behind a dial with
   `:dial_deadline_exceeded` once its caller's deadline has passed, and its resubscribe runs off
   the feed's call path.
6. **Conformance groups that could not fail now can.** Group 39 counts a success only if it
   holds something to inspect. Group 37 judges a bar's timeframe label. Group 42 requires the sent
   `client_order_id` on `:order_unconfirmed`. Group 19 checks all 37 secret names `Notice` knows.
7. **Default receive windows** are 5 s for `assert_receive` and 500 ms for `refute_receive` in
   every venue's `test_helper.exs`.

## Checklist

- [x] **Core:**
  - `PollingFeed` bulk tick tokens.
  - `penalize/3` and `:max_retry_after_s` bounded to the BEAM timer maximum.
  - `StakingReward` periods are `DateTime`s.
  - `Conversion.expired?/2` counts the instant of expiry as expired.
  - Telemetry `:start` always closes.
  - Conformance groups 19, 37, 39 and 42 have teeth.
  - Usage rules and guides match the code.
- [x] **Coinbase:**
  - JWT `nbf` back-dated 5 s.
  - Candle span counted by ceiling.
  - Sub-second `:since` filtered client-side.
  - A GTD `end_time` must be ISO 8601 with a zone.
  - The suite-wide pass-anything assertions are pinned. One of them (`response_shape_test`) only
    ever passed on an unknown-option refusal.
- [x] **Gemini:**
  - The nonce was already sound.
  - Resubscribe runs in a worker.
  - Dial replay is bounded by deadline.
  - Time units judged exactly.
  - The liveness docs match the reference, with boundary tests at 89 s and 90 s.
- [x] **Webull:**
  - Per-caller CONNACK deadline.
  - Millisecond-stated times read as ms.
  - Monotonic feed clock.
  - Jittered reopen.
  - `Auth` clock seam, with a retry carrying a fresh stamp and nonce.
- [x] **Robinhood:**
  - A pinned timestamp signs the first attempt only.
  - Poller generation.
  - ISO 8601 only.
- [x] **Schwab:**
  - Expiry skew.
  - Refresh dated from the send.
  - Streamer expiry notices.
  - Unfenced refutes fixed.
- [x] **Family:** venues pass against the new Core, the floor check and the full suite at the
      floor, and the batch is released (Core 0.3.116; every venue requires `~> 0.3.116`).

## Retrospective

**What worked.**
- Every venue suite ran against the unreleased Core before Core was released. This tick it
  found nothing, and that is the point: the release went out already known to pass.
- Sending back every partial report found more than the first passes did. Re-reading every
  test file in full found tests that could not fail in all six repos.
  - In Coinbase, a test asserted that a null list is refused on every endpoint. It passed only
    because its options carried account keys from other venues, so every call was refused as an
    unknown option before a body was read.
  - Pinning the exact answer made the test fail. Removing the stray keys made it pass for the
    right reason.

**What went wrong.**
- A deadline test set `expires_at` to `0`. The BEAM's monotonic clock is often negative, so
  `0` lay in the future and the "expired" caller was replayed. Fake a deadline relative to
  `System.monotonic_time/1`. The same fact is why Webull's "never delivered" sentinel is the
  minimum integer, not `0`.
- Two tests compared a parsed millisecond time with `==` against a literal without one.
  `DateTime` equality includes precision (`.000`), so compare instants with
  `DateTime.compare/2`.
- Agents wrote code they could not compile:
  - clauses split by a new function, so the compile failed with `--warnings-as-errors`;
  - a `when` guard inside `refute_received`;
  - lines of 99 columns;
  - bare `_` patterns.
  
  Each was a one-line gate fix. None would have reached a release, because the gate runs
  before every commit.
- An agent's moduledoc claim ("eleven of thirteen, six loud and three silent") did not add up
  and had no recorded source. It is now stated without numbers.

**What to carry.**
- Check what the BEAM's clocks and types actually do before writing the test's control. The
  monotonic clock's sign and `DateTime`'s precision are part of the contract a test relies on,
  just as sub-binary copying was in tick AO.
