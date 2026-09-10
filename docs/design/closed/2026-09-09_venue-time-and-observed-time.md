# Venue time and observed time: `Quote` and `OrderBook` cannot tell them apart

**Date:** 2026-09-09
**Status:** Implemented 2026-09-10 — option B, with the consumer's requested shape. Announced
as issue #31, answered by the consumer the same day, landed as `0.2.0` across the family.
Retrospective appended.
**Related:**
  - `lib/dp_exchange/core/types/quote.ex` — "`:timestamp` is the venue's own"
  - `lib/dp_exchange/core/types/order_book.ex` — same claim
  - `lib/dp_exchange/core/types/top_of_book.ex` — the type that already solved this

## What was found

`Core.Types.Quote`'s moduledoc states the rule this family lives by:

> `:timestamp` is the venue's own. Whatever it gave us, used as-is. Not normalised, not
> substituted, and **never invented: a quote whose freshness we cannot state is a quote we
> must not return.**

Two venue packages break it, and neither is a decoding mistake:

| site | what lands in `:timestamp` | why |
|---|---|---|
| `dp_exchange_schwab` `StreamerDecode.to_quote/3` | the frame's **arrival time** | `LEVELONE_*` frames carry no venue time in the fields it reads. Its own moduledoc says so plainly |
| `dp_exchange_gemini` `WsDecode.to_order_book/3` | the **local clock** | partial-depth snapshots carry no event time. The vendor's AsyncAPI requires only `[lastUpdateId, bids, asks]` for `OrderBookSnapshot`, where `BookTicker` requires `E` |

`dp_exchange_schwab`'s Streamer *book* is the counter-example, and it matters: it reads the
venue's `snapshot_time` and fails closed when absent. So the rule is keepable where the
venue cooperates, and unkeepable where it does not.

**The gap is in the contract, not only in those two packages.** `TopOfBook` carries
`:venue_time` (the venue's own, `nil` where it publishes none) *and* `:observed_at` (when
this package read it, always present), and its own doc says that separation exists for
exactly this reason. `Quote` and `OrderBook` have a single `:timestamp`, so a venue that
publishes no time has no way to say so — its only options are to lie or to drop the data.

## Why it matters, stated honestly

On a socket, arrival time and venue time differ by network latency — milliseconds, and
nobody is hurt. The case that hurts is the one this family already fears: **a venue lagging
behind reality.** If the venue is delivering data that is minutes old, arrival time reports
it as fresh, and a consumer measuring staleness from `:timestamp` sees a healthy feed. That
is the "silent half-dead feed" shape, one field lower down.

It has not been observed in production. It is a real hazard rather than a live incident,
and this document should not pretend otherwise.

## Why this is a design document and not a commit

Both honest fixes change a **published type** that a live consumer decodes at every call
site, delivered automatically by the release pipeline on merge. The blast radius measured
2026-09-09: 19 `lib/` files and 27 test files across six repositories, 69 `timestamp:`
construction sites.

That is precisely the shape this repository's own rules reserve for a written plan. It is
also a decision where the cheapest option for this family is the most expensive one for the
consumer, which is the kind of trade nobody should make silently on someone else's behalf.

## The options

### A. Refuse the data — keep the contract exactly as written

A `Quote` with no venue time is not returned. Schwab's `LEVELONE` quote path disappears;
its `TopOfBook` (already honest, with `venue_time: nil`) remains. Gemini's partial-depth
`OrderBook` disappears.

- **For:** no type changes at all, and the contract already says this is the answer.
- **Against:** deletes real data a consumer is using today — the last traded price on
  Schwab's stream has no other source in this package. Refusing to report a fact because we
  cannot date it is not obviously more honest than reporting it with the date we do have,
  clearly labelled.

### B. Give `Quote` and `OrderBook` what `TopOfBook` already has

Replace `:timestamp` with `:venue_time` (nullable) plus `:observed_at` (always present).

- **For:** one consistent shape across all four payload types; the family already decided
  this was right once, and this is only propagating it. Nothing can be silently wrong
  afterwards.
- **Against:** a hard breaking change on every consumer call site reading `.timestamp`, on
  a package whose releases publish automatically. Needs a coordinated version bump and a
  consumer migration.

### C. Add `:venue_time` alongside `:timestamp`, non-breaking

`:timestamp` stays required and keeps its current value; a new nullable `:venue_time` says
whether that value came from the venue. Honest sites set both; the two divergent sites set
`venue_time: nil`.

- **For:** consumers keep working untouched. The lie becomes machine-readable immediately.
- **Against:** two fields carrying the same value on most venues, which is the kind of
  redundancy that rots — a future venue will set one and forget the other. It also leaves
  `:timestamp`'s documentation permanently hedged.

## Recommendation

**B, sequenced deliberately** — it is the shape the family already chose for `TopOfBook`,
and C's redundancy is a defect generator rather than a fix. But B is not something to land
unannounced on a consumer who is presently running these packages in production and has
spent two days verifying other fixes. The sequence should be: agree the shape, tell the
consumer what will change and when, then land it across the family in one batch with the
major-version signal a breaking change deserves.

Until then the divergence is recorded in both type moduledocs, so nobody reads the contract
and believes something the implementations do not do.

## Open questions

- **OQ1** Does any consumer actually measure staleness from `Quote.timestamp` today, or is
  it only carried? That decides whether A's data loss is theoretical or real.
- **OQ2** Should `:observed_at` be mandatory on every payload type, including `Candle`?
  A bar has a venue-stated period; the moment we read it is still a different fact.
- **OQ3 — answered 2026-09-09, no.** Every `Candle` and `Trade` construction in all five
  venue packages derives its time from a venue field (`opened_at` from the venue's bar time,
  `timestamp` from the venue's trade time); none reaches for the local clock, and the only
  `DateTime.utc_now()` calls near them are `observed_at`/`asked_at`, which are correctly
  local by definition. Fakes use a fixed literal, which is what a fake should do. So the
  substitution is confined to the two sites named above rather than being a family-wide
  habit — which also means option A's data loss is narrow, and B's migration is bounded.

---

# Implemented, 2026-09-10 — retrospective

**Option B, with one change the consumer asked for and was right about.**

## The consumer's answer changed the argument, not the conclusion

They answered OQ1 with evidence rather than an impression: **nothing on their side measures
staleness from `Quote.timestamp`.** Every liveness judgement runs off their own receipt
clock — `TickFreshness.record/3` does not even accept a timestamp argument. So the
silent-half-dead-feed hazard this document led with **cannot reach their monitoring through
this field**, and I had weighted it too heavily.

What they found instead is worse and was not in this document: `Quote.timestamp` becomes the
**InfluxDB point time**, and candle aggregation buckets off that column, which feeds
indicators, which feed strategy evaluation. It is not carried and ignored — it is *the time
axis the analytical side is computed on*. A venue lagging by minutes with a read time
substituted places ticks in the wrong candle, and nothing flags it, because their freshness
checks are deliberately looking somewhere else.

**Monitoring hazard: absent. Bucketing hazard: present.** Same fix, different reason, and a
better one than the one this document argued.

## Their argument for B, which is stronger than this document's

Not elegance. **They could not make the fallback decision, because they could not see it.**
With one `:timestamp` there was no way to know whether what they had just stored as a point
time was the venue's word or someone's local clock — so no policy was expressible. With the
split they store `:venue_time` where the venue dated the frame, and where it did not they
store `:observed_at` *and record that they did*, so a mis-bucketed candle is attributable
rather than invisible.

They also noted that neither offending path reaches them today: they take no Schwab
dependency at all, and since `dp_exchange_coinbase` 0.2.34 gave them `:channels`, Gemini
receives `[:quotes, :top_of_book]` and never `:order_book`. They said so **to weight their
own vote down**, which is worth recording.

## The shape change they requested

**`:observed_at` is non-nullable on both types**, as `TopOfBook` already had it. This is the
property that makes a strictly-honest nullable `:venue_time` affordable: a consumer always
has a usable time, so `nil` can mean "the venue did not date this" without forcing anyone to
invent a fallback. Drop the guarantee and every caller needs one — which is the substitution
this whole change removes, relocated into consumer code.

## What was decided against, and why it stays decided

- **A (refuse undated data)** is not viable as a general answer, but the consumer noted it is
  the right answer *per field* — which is exactly what `:venue_time` now is: nullable and
  honest, never substituted. `dp_exchange_schwab`'s Streamer book already behaved this way
  with `snapshot_time`.
- **C (add `:venue_time` alongside `:timestamp`)** was rejected by both sides for the same
  reason, and the consumer put it best: *"We would be the repo that reads `:timestamp` for
  three years and never notices `:venue_time` disagreeing with it on one venue."*

## Deliberately out of scope

`Trade`, `Fill`, `Balance` and `OrderBookDelta` keep a single `:timestamp`. A 2026-09-09
sweep confirmed every `Candle` and `Trade` construction in all five venues derives its time
from a venue field, and `OrderBookDelta`'s decoders fail closed without the venue's `E`.
There is no divergence to fix there, and widening a breaking change past the defect it
exists for is how a migration becomes unaffordable.

## Cost, measured rather than estimated

19 construction sites across four venue packages — `dp_exchange_robinhood` has none, since it
produces only `TopOfBook`, which already had this shape. The consumer reported their own as
8 `lib/` files and 5 test files.
