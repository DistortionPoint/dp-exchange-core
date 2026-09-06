# Packages pass streamed data on; they do not maintain books

**Status:** Implemented
**Date:** 2026-09-06

## Context

A venue package's job is to **get the data and keep the connections up**. Decoding a venue's
frames into the contract's types is that job. Holding market state is not.

`dp_exchange_coinbase`'s `Socket` currently holds `books: %{}` — a full order book per
symbol, measured at **~22,800 bid and ~21,100 ask levels for `BTC-USD`** on a consumer's live
node — and maintains it across every `l2_data` delta through `apply_book_event/3`,
`apply_book_row/2`, `update_level/4`, `remove_level/3` and `deliver_book/3`.

That is a parallel in-memory copy of market state, inside a socket process, **while the host
is already streaming the same data into InfluxDB**. It is duplicated state in the wrong
place, and what the host does with the data is the host's decision, not this package's.

It is also expensive in a way that damages the one job the package does have. Every delta
rebuilt and re-delivered the whole book; before the ordered-structure fix that cost 65–110 ms
per frame, capping one socket at ~9–16 book updates per second across the 100 symbols it
carries. A socket process that is never idle cannot service `WebSockex.send_frame/2`, which
is the `:send_timeout` that starves the `ticker` subscribe in issue #22. **Maintaining state
we were not supposed to hold is what broke the connections we were supposed to keep.**

### Scope

Checked across the family: **only Coinbase does this.** Gemini, Webull and Schwab decode each
frame and pass it on. Gemini's socket moduledoc even records the incident that produced the
rule. So this is one package returning to the boundary the others already hold.

## 1. Objectives

All four met — see §3 for what each item found, and §5 for what the work turned up that this
section did not anticipate.

- [x] `Socket` holds no market state — connection state only
- [x] What the venue streamed is what the host receives, decoded into contract types
- [x] A caller still cannot mistake one delta for a whole book — the reason the maintenance
      was added in the first place
- [x] The change is declared, not silent: consumers receive a different shape

## 2. Design

### The contract has no way to say "one level changed"

`Core.Types.OrderBook` is a full snapshot with eager sorted `bids`/`asks` lists. There is no
incremental type anywhere in `Core.Types`. That absence is what pulls book-building into the
package: given only a snapshot type, a venue streaming deltas has no choice but to accumulate
them into a book.

Telling detail: `OrderBook` already carries `:sequence`, documented as being "for callers
reconciling snapshots against a delta stream". The contract anticipated delta streams and
never provided the type for one.

**Add `DpExchange.Core.Types.OrderBookDelta`** — symbol, the changed levels, the venue's
timestamp, the venue's sequence where it publishes one, provider. A level whose new quantity
is zero is the level ceasing to exist, not a price of zero; that meaning is the venue's and
is carried through unchanged rather than resolved here.

### Why this does not reintroduce the incident that created the maintenance

`Socket`'s moduledoc records a real failure: a caller reading a single `l2_data` delta as if
it were the whole book "would see a handful of prices and nothing else". That is exactly what
must not happen, and it is why the book was built.

A distinct type is the answer, not accumulated state. A caller cannot mistake an
`%OrderBookDelta{}` for an `%OrderBook{}` — the struct names the thing. The incident came
from a *snapshot-shaped value carrying delta content*; giving deltas their own type removes
that possibility at the type level rather than by hiding deltas behind maintained state.

Carry that incident text forward into both the new type's moduledoc and Coinbase's — per the
convention that a moduledoc explaining why a guard exists is the most valuable thing in the
file.

### Coinbase after the change

- `snapshot` frame → `Types.OrderBook`, as the venue sent it. Sorting once per subscribe is
  decode work, not maintenance.
- `update` frame → `Types.OrderBookDelta`, passed straight through.
- `books`, `apply_book_event/3`, `apply_book_row/2`, `update_level/4`, `remove_level/3`,
  `deliver_book/3` and `price_key/1` all go.
- `handle_disconnect/2` no longer has books to wipe — but the fact that deltas after a
  reconnect are **not contiguous** with those before it is real and now matters to the host
  instead. The existing `:link_down`/`:link_up` notices plus the venue's `sequence` are what
  a host reconciles against; say so explicitly rather than leaving it inferred.

### This is a breaking change, and is declared as one

A consumer receiving a full `OrderBook` on every update will now receive an `OrderBookDelta`
instead, and must build state itself if it wants a book. That is the intended division of
labour, and it must be stated plainly in the CHANGELOG, the moduledoc, and `usage-rules.md`,
which ships in the Hex tarball. It is not presented as a performance improvement.

## 3. Checklist

### Core (ships first)

- [x] `Types.OrderBookDelta` with a validating `new/1`, per the `Types.Validate` convention
      **Found:** added `lib/dp_exchange/core/types/order_book_delta.ex`. Fields are
      `symbol`, `levels`, `timestamp`, `sequence` (nilable, same convention as `OrderBook`'s)
      and `provider`; `new/1` is `Validate.new!(__MODULE__, @enforce_keys, attrs)` like every
      other type. `levels` is `[{side, price, quantity}]` — `OrderBook.level/0`'s
      `{price, quantity}` pair with the changed side prepended, kept as **one flat list in
      the venue's own order** rather than split into `bid_levels`/`ask_levels`, because a
      single delta frame changes both sides in one venue-ordered message and a per-side split
      would either drop that order or invent one the venue never sent. The incident text from
      `dp_exchange_coinbase`'s `Socket` moduledoc is carried into this type's own moduledoc
      verbatim, per the design's explicit ask. Tests: `test/dp_exchange/core/types/
      order_book_delta_test.exs` (validation, the `nil`-vs-absent convention, a zero-quantity
      level surviving `new/1` completely unchanged including a mixed live/vanished delta,
      `:sequence` defaulting to `nil`, and that the struct carries no `:bids`/`:asks` keys so
      it cannot be mistaken for `OrderBook`) plus a matching `describe` block added to
      `validate_test.exs` alongside every other type there.
- [x] Decide whether `:order_book` remains the right `data_kind()` for a delta stream, or
      whether `coverage_by_kind/1` needs to distinguish them — and justify either way
      **Found:** `:order_book` stays, and no new kind was added. `coverage_by_kind/1` answers
      "which *kind* of data is arriving" (quotes dark, book healthy), not "in what *shape*" —
      a host checking whether book data is arriving for a symbol does not care whether the
      next message is a full snapshot or an incremental delta, and the struct type itself
      (`%OrderBook{}` vs `%OrderBookDelta{}`) already tells a caller which shape it holds.
      Adding a kind is not free — `Capabilities.data_kind/0` is a closed vocabulary every
      venue declares against in `streamable` — and this distinction was never the one
      `coverage_by_kind/1` was built to make; it exists to catch "ticker dark, book healthy"
      looking identical to "everything healthy" (DpCryptoManagement issue #22), which is
      orthogonal to whether the book arrives as a snapshot or a delta. No code change was
      needed to reach this conclusion — reasoning recorded here and in `OrderBookDelta`'s own
      moduledoc and in `usage-rules/feeds.md`.
- [x] `usage-rules/` documents the type, the zero-quantity meaning, and that reconciling a
      delta stream across a reconnect is the host's job, with `sequence` and the link
      notices as the tools
      **Found:** added to `usage-rules/feeds.md`, new section "An order book stream delivers
      deltas, not a maintained book" — covers the type itself, the flat venue-ordered `levels`
      shape, the zero-quantity meaning, why the incident cannot recur (distinct struct, not
      accumulated state), the `:order_book` `data_kind()` reasoning above, and reconnect
      reconciliation. On the reconciliation question the design doc asked to be answered
      honestly rather than assumed: **the two signals are sufficient, but only because a third
      thing already exists and is documented separately** — `get_order_book/2` is unaffected
      by this change and remains the pull-based resync point. `:link_down`/`:link_up` mark
      *when* a gap may have opened; `:sequence` on both `OrderBook` and `OrderBookDelta` lets
      a host confirm *whether* what arrives after `:link_up` is contiguous with what it
      already holds; neither one reconstructs a missing delta, and nothing does — a gap in a
      delta stream is lost, not recoverable. The correct response, consistent with this
      family's existing "a notice is a prompt to re-read, never the record" rule, is to
      re-pull `get_order_book/2` (or accept the venue's own fresh snapshot on resubscribe)
      rather than trust continuity across the gap. This is not a new mechanism — it is the
      family's existing reconnect idiom (`usage-rules/feeds.md`'s pre-existing "Reconnection
      is the package's problem, and the notice is yours" section) applied to the one new type
      that needed it spelled out explicitly.
- [x] `usage-rules/adapter.md` states the general state boundary — market data passes
      through; a package may hold only state describing what it is doing and whether it is
      fulfilling what the host asked for — with the concrete hold/do-not-hold list, not only
      the `OrderBookDelta`-specific account in `feeds.md`. Added mid-implementation on the
      architect's explicit instruction, because this rule is what `OrderBookDelta` exists to
      make followable and belongs next to it rather than only implied by the type's own
      moduledoc.
      **Found:** added new section "Your job is to get the data and keep the connections up —
      not to process it" to `usage-rules/adapter.md`, placed right after "Do not add functions
      to the facade" — early, because it is foundational to what a package's job even is,
      before the how-to sections that follow it. States the rule in the architect's own words
      (quoted), then makes it concrete: **hold** — shard/pair assignment, `coverage/1` and
      `coverage_by_kind/1`'s own delivery tracking, and the venue catalogue/alias map needed
      to attribute a frame to its symbol, none of which is market data, all of which is
      bookkeeping about the package's own job; **do not hold** — an order book (what
      `OrderBookDelta` exists to make unnecessary), a running last price, an accumulating
      candle, or any other rebuild of venue state from a stream of updates. States why: the
      host is already streaming this data into its own time-series store, so a package-side
      copy is duplicated state in the one place that can least afford it, and holding it
      costs the job the package actually has — `dp_exchange_coinbase`'s `Socket` cost 65–110
      ms per frame rebuilding a book, starving its own `WebSockex.send_frame/2` on the same
      process and producing the `:send_timeout` in issue #22. Notes explicitly that the other
      four venue packages already follow this convention; Coinbase was the one exception, not
      a fifth interpretation to invent.

### Coinbase (after Core publishes)

- [x] Delete the book state and every function that maintains it
      **Found:** `dp_exchange_core` bumped to `~> 0.1.53` (was `~> 0.1.48`). `Socket`'s
      `books` state key and `apply_book_event/3`, `apply_book_row/2`, `update_level/4`,
      `remove_level/3`, `deliver_book/3` and `price_key/1` are all gone, along with the
      `:gb_trees`/exact-scaled-integer machinery `price_key/1` existed to support.
      `handle_disconnect/2` no longer wipes anything — there is nothing left to wipe.
      Two side effects of the deleted machinery were deliberately NOT carried forward,
      decided rather than defaulted: the precision refusal (>8 decimal digits) existed
      only to guard the `:gb_trees` integer key, so a price at any precision now passes
      through unchanged like every other decimal field this module decodes; and the
      last-write-wins fold of numerically-equal, differently-scaled prices (`"1.5"` vs
      `"1.50"`) was an accident of the old map's own key (`%Decimal{}` structs compare
      unequal for equal numbers), never a documented venue behaviour, so both rows now
      survive a snapshot rather than one silently winning. Both are recorded in the
      CHANGELOG, not just this checklist.
- [x] Snapshot → `OrderBook`; update → `OrderBookDelta`
      **Found:** a `snapshot` decodes into `Types.OrderBook`, sorted once via
      `Decimal.compare/2` — decode work, not maintenance, exactly as designed. An
      `update` decodes into `Types.OrderBookDelta`, `levels` built by preserving the
      venue's own row order (cons-and-reverse, same technique used for the snapshot's
      per-side lists so a stable sort's tie-break also lands in venue order) and never
      split by side beyond the tuple's own leading `:bid | :ask`. A zero `new_quantity`
      is left exactly as the venue sent it in both the row-decode step and the delta —
      nothing resolves it. Malformed rows are dropped and reported through the same
      `:data_quality` path for both frame types, one bad row no longer blocking its
      valid siblings in the same frame.

      This surfaced one consequence the checklist's own wording didn't name:
      `Feed.payload_kind/1` pattern-matched only `Types.Quote` and `Types.OrderBook`
      with no catch-all, by design ("failing loudly beats silently mis-tagging its
      coverage"). Left alone, the first real `Types.OrderBookDelta` a `level2` `update`
      produced would have crashed `Feed` outright. Added the missing clause, mapping
      `%Types.OrderBookDelta{}` to `:order_book` — the same kind `%Types.OrderBook{}`
      gets, per Core's own checklist item 2 above (`coverage_by_kind/1` answers "is
      book data arriving", not "in what shape"). Covered by new `Feed` tests, not only
      `Socket` ones, since `Socket`-level tests can't reach this dispatch path.
- [x] Tests proving no market state survives a frame, that a delta carries exactly the
      venue's own rows, and that a reconnect needs no state wipe because none is held
      **Found:** all three added to `socket_test.exs` — "no market state survives a
      frame" asserts the socket's own state keyset is unchanged (and never gains a
      `:books`-shaped key) across a snapshot and an update; "a reconnect needs no state
      wipe" asserts `handle_disconnect/2`'s output state is `==` its input, not merely
      absent a book; a dedicated delta test asserts `delta.levels` matches the frame's
      rows exactly, in order, including a zero-quantity row surviving unresolved and
      interleaved with a live one on the other side. Rewrote or deleted every test that
      asserted on the accumulated book (the "PATCHES the maintained book" and "a
      reconnect clears the maintained book" tests no longer describe anything that
      exists) after reading each one individually — two were judged to pin a real
      finding rather than the accumulation and were kept, adapted: the duplicate-price
      test (now asserting both rows survive, not one) and the too-precise-price test
      (now asserting pass-through, not refusal) — both explained inline and in the
      CHANGELOG rather than silently dropped. The big "matches the map+sort reference
      exactly" oracle test was deleted outright, per this checklist's own instruction —
      its update leg no longer has anything to compare against, and its snapshot leg's
      sorting claim is covered more directly by a new, much smaller scrambled-input
      test. One bug caught by the new duplicate-price test before it shipped: the first
      draft of the per-side split reversed row order via `cons` without reversing back,
      so a stable sort broke ties in the wrong direction — fixed in `split_sides/1`.
- [x] Remove `bench/order_book_resort.exs` — it benchmarks work that no longer exists
      **Found:** deleted; nothing else referenced it (`mix.exs` had no alias pointing at
      it).

## 4. Rejected alternatives

- **Coalescing deliveries.** Bounding how often the host sees data is delivery policy, and
  that is the host's decision. It also silently drops points for a host writing every message
  into a time-series store — a regression dressed as an optimisation.
- **Capping depth.** Same objection: deciding for the host what it needs.
- **Keeping the book but making it cheaper.** The ordered-structure change did that, and it
  was treating the symptom. The state should not be here at all.

## 5. Retrospective

Shipped: Core `0.1.53` first (already recorded in §3 above), then `dp_exchange_coinbase`
alone — this was always a one-venue fix; §Scope confirmed at design time that Coinbase was
the only package holding a book, so there was no batch to coordinate. Coinbase's own version
was hand-set to `0.2.0` in `mix.exs` to signal the break per this package's documented
convention (a hand-edited `0.2.0` is how a breaking change is declared); CI computes the next
patch from `max(mix.exs, Hex latest)`, so this actually publishes as `0.2.1`, not `0.2.0` —
stated here so the number in the CHANGELOG isn't read as a promise CI will keep literally.
629 tests, 0 failures; `mix quality` (format, `credo --strict`, `dialyzer`, `sobelow`) clean;
coverage 92.23% (threshold 90); `mix docs` zero warnings.

### The wiring gap this design's own text didn't name

§2's "Coinbase after the change" bullet list is entirely about `Socket`. It says nothing
about `Feed`, and `Feed.payload_kind/1` was written, deliberately, with no catch-all clause
for exactly the reason its own comment gives: "an unrecognised struct here means a new
payload kind was wired into `Socket` without being taught to this function, and failing
loudly beats silently mis-tagging its coverage." That guard did its job on the first payload
that could have tripped it — a real `level2` `update` frame would have crashed `Feed`
outright the moment this shipped, not degraded gracefully. The design was correct that
`Socket` is where the change lives; it undersold that `Socket`'s output type is also part of
`Feed`'s own exhaustive match, and changing one without the other is a compile-clean,
test-passing, production-crashing gap. Nothing in `mix test`, `mix dialyzer`, or `mix credo`
would have caught it either, because `Feed`'s existing tests construct `OrderBookDelta`
values directly rather than routing through `Socket`'s real dispatch — the crash only
happens on the wire. Caught by re-reading `Feed`'s own moduledoc and grepping for every
place `Socket.books`/`apply_book_event`/`deliver_book` were named in prose, which is what
surfaced the `payload_kind/1` clause list as one of those places.

### Two decisions the checklist asked for by name, both made the same direction

The design anticipated needing judgment calls on the duplicate-price and precision-refusal
tests ("decide deliberately and say which you did and why") without prescribing an answer.
Both landed the same way: drop the behaviour, because both existed as *side effects* of
`price_key/1`'s `:gb_trees` integer key rather than as independent rules anyone had decided
on their own merits. The duplicate-price fold had no "measured live" citation anywhere in
the codebase — unlike the 8-decimal `quote_increment` finding a few lines above it in the
same moduledoc, which does — and folding two rows into one, silently picking a winner, is
itself the shape of substitution this family's own "fail closed; never substitute" rule
argues against. Once framed that way the decision stopped being a coin flip.

### The bug the new tests found before anyone else did

Building `OrderBookDelta.levels` in venue order required reusing the cons-and-reverse
pattern for the snapshot's own per-side lists — but the first draft only reversed the combined
list, not each side's accumulator, in `split_sides/1`. It compiled, every existing assertion
still passed (row order didn't matter to any of them), and it was invisible until the
duplicate-price test — written to prove two rows now survive rather than one — asserted their
*relative* order and got the reverse of what the venue sent. A stable sort over equal keys
inherits the accumulator's order, so this needed a tie to surface at all. That's the argument
for writing tests that assert order on a "just pass it through" change: nothing about
`Enum.sort_by/3`'s correctness would have caught it, because sorting non-equal keys was
never wrong.

### What this does not settle

Reconnect reconciliation is now documented as the host's job — `:link_down`/`:link_up`
bracket the gap, `:sequence` (always `nil` on Coinbase's `l2_data`, confirmed against its own
reference docs) is the other half where a venue publishes one, and `get_order_book/2` is the
correct resync point. None of that is exercised end-to-end against a real reconnect here; it
is exactly what the design said it would be — a documented contract, not a tested one, since
testing it would mean simulating a real venue's gap behaviour this package has no way to
observe.
