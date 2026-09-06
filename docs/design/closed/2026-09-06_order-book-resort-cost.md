# The order book is fully re-sorted on every delta

**Status:** Implemented
**Date:** 2026-09-06

## Context

`dp_exchange_coinbase`'s `Socket` maintains a level2 book per symbol and delivers a
`Core.Types.OrderBook` on **every** `l2_data` frame — including an `update` that changes a
single price level. `deliver_book/3` builds that struct with:

```elixir
bids: sorted_levels(book.bids, :desc),
asks: sorted_levels(book.asks, :asc)

defp sorted_levels(levels, :desc),
  do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:desc, Decimal})
```

So each delta triggers a full comparison sort of both sides, with `Decimal` comparators,
over a map that is never pruned.

### Measured, not estimated

DpCryptoManagement reported their live `Socket` state carrying **~22,800 bid and ~21,100 ask
levels for `BTC-USD`** (issue #22). Benchmarked at that size on this machine:

```
one update frame, full re-sort of both sides : 91.5 ms
10 frames                                    : 766 ms
                                             -> ~13 book updates/sec, maximum, per socket
```

A shard carries up to `@pairs_per_socket` = **100 symbols**, and the socket process is
single-threaded. Thirteen updates per second is not a budget a live level2 stream fits in;
Coinbase streams continuous deltas and the same consumer measured **11,000+ frames** in one
window.

### This is very likely the mechanism behind issue #22

The open question in #22 is why `ticker` starves whenever `level2` is delivering broadly.
The established chain is: `level2` subscribes first, its snapshot burst keeps the
single-threaded socket busy, the `ticker` subscribe 8s later blows `FrameSender`'s 5-second
`:gen.call` window and returns `:send_timeout`.

That chain assumed the burst was **decode** cost. This measurement says a large part of it
is our own re-sorting, and unlike the initial snapshot it **never ends** — every subsequent
delta pays it again. It fits the consumer's inversion exactly:

| state | order_book | quotes | explanation under this defect |
|---|---|---|---|
| broken | ~406 symbols, 11k+ frames | ~5 | every frame re-sorts a large book; socket never idle; `ticker` subscribe cannot be serviced |
| healthy | 6 symbols | 400 | almost no sorting load; `ticker` subscribes land |

**Stated as a hypothesis, not a conclusion.** It is consistent with every measurement we
have and it is a real defect regardless, but the causal claim about #22 is only confirmed by
the fix changing behaviour on their node.

## 1. Objectives

- [x] Remove the per-delta full re-sort as the dominant cost of maintaining a book
- [x] Change nothing a consumer can observe: ordering, precision and depth stay exactly as
      they are
- [x] Keep the `Core.Types.OrderBook` contract's ordering guarantee provably intact

## 2. Design

### Keep the book ordered instead of ordering it on the way out

Replace the per-side `%{Decimal => Decimal}` map with a `:gb_trees` keyed by an **exactly
scaled integer** derived from the price, carrying the original `Decimal` as the value.
Delivery becomes an ordered traversal — no comparison sort at all.

Keying matters and is the one subtle part:

- **Not the `Decimal` struct.** `:gb_trees` uses Erlang term ordering, which compares
  `Decimal` structs field-by-field (`sign`, `coef`, `exp`) — that is not numeric order.
  `Decimal.new("1.50")` and `Decimal.new("1.5")` are numerically equal and structurally
  different, and would become two levels for one price.
- **Not a float.** Prices must stay exact; this family refuses lossy price handling
  everywhere else and will not introduce it in the hot path.
- **A scaled integer.** Exact, cheap under term ordering, and reversible — but the scale
  must be chosen so no venue price can lose precision or collide. Verify the scale against
  the smallest `quote_increment` Coinbase actually publishes rather than assuming one.

The original `Decimal` is carried as the value, so what a consumer receives is byte-identical
to today.

Measured on the same 22,800-level book:

```
current  full Enum.sort_by/Decimal : 44.3 ms  (bids only)
ordered  gb_trees traversal        : 7.0 ms  (bids only)
speedup                            : 6.3x
```

### What remains, and is deliberately out of scope

The residual ~7 ms is building a 22,800-element list every frame. That is inherent to
delivering the full book as a list per delta, and removing it means **delivering less than
the whole book** — a depth limit.

`Core.Types.OrderBook`'s moduledoc mandates ordering ("part of the contract, not a
convenience") but **never promises full depth**. So a configurable depth is contract-legal.
It is still not being done here, for two reasons: it changes what consumers receive, and
truncating silently would be this family's own cardinal defect — delivering less than was
asked for without saying so. If the sort fix proves insufficient, depth becomes its own
design document with a declaration attached, not a quiet default.

## 3. Checklist

- [x] Choose the integer scale from Coinbase's own published `quote_increment` values,
      recorded with the evidence

  **Found:** fetched `GET https://api.coinbase.com/api/v3/brokerage/market/products`
  live on 2026-09-06 (public, unauthenticated, 931 products returned). The smallest
  `quote_increment` across every one of them is `0.00000001` (8 decimal places — 45
  products, e.g. `PEPE-USD`, `SHIB-USD`, `BONK-USD`); no product's own `price` field
  carries more decimal digits than that either (max observed: 8). Chose `10^8` as the
  scale — exact for every real price on record. `price_key/1` does not trust that
  blindly on every call: it checks `Decimal.integer?/1` on the scaled result and
  refuses (reported, not rounded) if a price is ever more precise than the venue
  currently publishes. Evidence and the exact command are recorded in
  `DpExchange.Coinbase.Socket`'s moduledoc and in `price_key/1`'s own comment.

- [x] Replace both sides' storage with ordered structures; `apply_book_row/2`'s
      insert/update/remove semantics unchanged, including `new_quantity: "0"` removing a
      level rather than storing a zero

  **Found:** each side is now a `:gb_trees` tree keyed by `price_key/1`'s scaled
  integer, valued `{price :: Decimal.t(), quantity :: Decimal.t()}`. `new_quantity: "0"`
  still removes the level (`:gb_trees.delete_any/2`, a no-op if the key is already
  absent — same semantics as the old `Map.delete/2`); any other quantity still enters
  the tree via `:gb_trees.enter/3` (insert-or-update, same semantics as the old
  `Map.put/3`). An unparseable price or quantity, and now also a price that cannot be
  keyed exactly at the chosen scale, are all reported through the same
  `malformed_row/3` → `report_quality/2` path and drop the row rather than crashing or
  going silent.

- [x] `deliver_book/3` traverses in order; no `Enum.sort_by` remains in the frame path

  **Found:** `deliver_book/3` now calls `ordered_levels/2`, which is
  `:gb_trees.to_list/1` (already ascending by key) for asks and the same reversed for
  bids — no comparator invoked. `grep -rn "Enum.sort_by" lib/` returns nothing in
  `dp_exchange_coinbase`.

- [x] A test asserting output is **identical** to the current implementation for a
      non-trivial book — same order, same `Decimal` values, same count. This is a
      performance change and must be observably invisible.

  **Found:** `socket_test.exs`'s "order-book resort-cost fix — observably invisible"
  describe block reimplements the OLD map-keyed-by-`Decimal`,
  full-`Enum.sort_by/3` approach as a comparison oracle (`reference_book/2`,
  `reference_ordered/1`) and asserts the real `Socket.handle_frame/2` output against it
  for a 300-bid/300-ask-level snapshot built from a scrambled (non-monotonic) insertion
  order, then again after a delta frame that updates, removes and inserts levels on
  both sides. Both assert full list equality (order, `Decimal` values, count), plus an
  explicit check that the new best bid/ask lands in the right position after the delta.

- [x] A test that two numerically-equal, differently-scaled prices (`"1.5"` / `"1.50"`)
      remain ONE level, which the current map keyed by `Decimal` struct arguably gets wrong
      today — check and record which behaviour is correct before changing it

  **Found:** confirmed the current (pre-fix) behaviour is wrong, not merely arguable —
  `Map.put(%{}, Decimal.new("1.5"), ...) |> Map.put(Decimal.new("1.50"), ...)` produces
  a two-entry map (asserted directly in the new test), because `:gb_trees` and `Map`
  both use Erlang term ordering/equality, which compares `%Decimal{}` structs
  field-by-field rather than by `Decimal.equal?/2`. One numeric price becoming two
  book levels is wrong on its own terms — a level is identified by its numeric value.
  The fix's scaled-integer key collapses both onto the same integer, so this is fixed
  as a consequence of the keying change, not a separately-flagged special case; the new
  test (`"numerically-equal, differently-scaled prices are ONE level, last write wins"`)
  asserts both the new correct behaviour (one level, last update wins) and the old
  behaviour as a factual record, so the fix is not silently riding along unverified.

- [x] A benchmark in the repo recording before/after at a realistic book size, so the next
      person does not have to rediscover the number

  **Found:** added `bench/order_book_resort.exs` (`mix run bench/order_book_resort.exs`)
  to `dp_exchange_coinbase`, measuring both the isolated bids-only sort/traversal and a
  full one-update-frame cost (patch one row into the maintained structure, then produce
  the delivered list for both sides) at the same ~22,800/~21,100-level book size this
  design measured. Five repeated runs on the implementing machine: bids-only fell from
  49–83 ms to 0.5–6.2 ms; one full update frame fell from 62–110 ms (9–16 updates/sec
  maximum) to 0.9–2.9 ms (345–1075 updates/sec maximum). The multiplier varies more
  run-to-run than this design's own 6.3x figure — sometimes over 100x — most likely
  because `Enum.sort_by/3`'s `Decimal`-comparator cost dominates the "before" side far
  more than an O(n log n) sort alone would predict; both machines agree on the
  direction and rough magnitude, not on a single precise multiplier, and the benchmark
  script is left in the repo so this does not need re-litigating from memory.

## 4. Rejected alternatives

- **Sort only on delivery, cached between frames.** Every frame delivers, so the cache never
  hits.
- **Deliver top-N silently.** Contract-legal but a silent reduction in what a consumer
  receives. If depth is limited it must be declared and configurable.
- **Skip delivering on deltas that do not change the top of book.** Changes semantics — a
  consumer maintaining depth downstream would silently miss levels.
- **Float keys.** Fast and lossy. Refused on the same grounds as everywhere else in this
  family.

## 5. Retrospective

Implemented entirely in `dp_exchange_coinbase`; nothing here required a Core change,
which is itself worth noting — the fix stayed inside the one venue's own internal
`Socket` state, exactly as the facade boundary this family is built around says it
should.

### The scale evidence changed the plan in one small way

The design assumed a scale would need to be "verified" against Coinbase's own published
`quote_increment` values without saying what to do if the answer was awkward — a scale
that varied by product, say, or one deep enough to make `Decimal.to_integer/1` risk
overflow-adjacent coefficients. The live answer was clean: one global scale (`10^8`)
covers every product Coinbase publishes, with margin (max observed price precision was
also 8 digits, not more). `price_key/1` still checks `Decimal.integer?/1` on every call
rather than trusting that measurement forever, which is the cheap insurance against the
venue changing this out from under the package later without anyone here noticing.

### The equal-price edge case was not "arguably wrong" — it was wrong

The design hedged ("arguably gets wrong today"). Writing the test that constructs the
old map directly (`Map.put(%{}, Decimal.new("1.5"), ...) |> Map.put(Decimal.new("1.50"),
...)`) and asserting `map_size == 2` removed the hedge: two entries in a book for one
numeric price is a defect by the same standard `Core.Types.OrderBook`'s own moduledoc
sets — the ordering guarantee assumes one level per price, and a caller reading `hd/1`
as the best price would have been reading a duplicate-inflated book. The fix collapsing
this was a side effect of the scaled-integer key, not independent work, but it still
needed its own test and its own sentence in the changelog — "collapsed as a side effect
of an unrelated performance fix, and nobody noticed until a consumer's book had a
duplicate level" is exactly the kind of finding this family's own conventions exist to
prevent from happening silently.

### The benchmark disagreed with the design's own number, in the right direction

The design measured 6.3x on bids-only. Five runs on the implementing machine measured
anywhere from roughly 10x to over 100x on the same comparison, with the full-frame
before/after (62–110 ms → 0.9–2.9 ms) telling the same story more reliably than the
multiplier does. The most likely explanation is that `Enum.sort_by/3`'s per-comparison
cost with a `Decimal` comparator (a module-dispatched struct comparison) is far more
expensive relative to a raw integer comparison than an O(n log n) vs O(n) complexity
argument alone would suggest — BEAM's `:gb_trees` traversal has none of that dispatch
cost. Recorded rather than reconciled to a single number, because pretending two
machines agree to one decimal place would be less honest than the range.

### What this does not settle

Confirming or refuting the causal hypothesis about issue #22 — that this defect is why
`ticker` starves whenever `level2` is delivering broadly — needs the fix running against
the actual venue traffic that produced the original measurement. Nothing in this
retrospective is that evidence; it is still open on DpCryptoManagement's side.
