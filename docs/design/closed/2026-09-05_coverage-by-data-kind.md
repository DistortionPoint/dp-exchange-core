# Coverage by data kind

**Status:** Implemented
**Date:** 2026-09-05

## Context

`coverage/1` is described in the contract as **the strongest guarantee in the contract**:

> What is **observed arriving**, by which route — never what was subscribed. […] it exists
> because intent standing in for evidence is how a venue reported 325 symbols subscribed
> and confirmed while 174 were delivering.

It does that job correctly. It also cannot answer the question that has taken two issues and
several days to pin down, and the two facts are the same fact.

### What went wrong, precisely

DpCryptoManagement, chasing Coinbase issue #22, reported `coverage/1` returning 406 pairs
all `:stream` while only 5 pairs had ever produced a quote in 69 minutes, and concluded that
`coverage/1` was reporting subscriptions rather than arrivals.

**That conclusion was wrong, and checking it found the real defect.** `delivering` is written
in exactly one place, on an actual payload arrival, and `coverage/1` maps that and nothing
else. Verified by running it:

```
coverage after ONLY an OrderBook (no ticker quote): %{"XLM-USD" => :stream}
```

Their own report contains the explanation: `level2` was delivering **more than 11,000
frames** while `ticker` was dark. `coverage/1` counts any payload for a symbol — a
`Types.OrderBook` exactly as much as a `Types.Quote`. So 406/406 `:stream` was **truthful**.

The defect is that being truthful was not enough. `coverage/1` collapses every data kind
into one boolean, so **"ticker dark, level2 healthy" is indistinguishable from "everything
healthy"** — which is the exact state they were in, and the reason the failure stayed
invisible across #20 and #22 while both of us looked elsewhere. The consumer's instinct that
"the venue's own introspection agrees with the happy path" was right; the mechanism was one
level over from where they placed it.

This is the family's own defect class — *a nearby answer where there should be a precise
one* — in the function whose entire purpose is to prevent it.

### Why the consumer's own two proposals do not fix it

Both proposals in #22 split *subscribed* from *delivering* (`:subscribed_pending`, or a
companion `delivering/1`). **Neither would have surfaced anything here**, because these pairs
genuinely were delivering. The axis that matters is not subscribed-versus-delivering. It is
**which kind** is arriving. Recorded because it is the more instructive half: a plausible fix
aimed at the wrong axis would have closed the issue while leaving the blindness intact.

## 1. Objectives

- [x] Make "which data kind is arriving, per symbol" answerable through the facade
- [x] Break no existing consumer of `coverage/1`
- [x] Require no venue to ship simultaneously with Core — the cross-repo coupling that
      caused a premature-deploy incident once and delayed the `:gfw`/`:gfm` wiring again
- [x] Prove the new answer against real delivery, never against subscription state

## 2. Design

### The shape

```elixir
@callback coverage_by_kind(keyword()) :: %{data_kind() => %{symbol() => route()}}
```

`data_kind()` already exists in `Core.Capabilities` (`:quotes`, `:top_of_book`,
`:order_book`, `:trades`, `:candles`, …) and every venue already declares which kinds it
streams via `capabilities().streamable`. The contract already knows these are distinct; only
`coverage/1` throws the distinction away.

For Coinbase this answers the diagnostic directly:

```elixir
%{
  quotes:     %{"BTC-USDC" => :stream},                        # 5 symbols
  order_book: %{"BTC-USDC" => :stream, "XLM-USDC" => :stream}  # 406 symbols
}
```

The discrepancy between the two map sizes *is* the signal. A single number cannot express it,
which is what the consumer said in their own words about their own tracker.

### The invariant

`coverage/1` remains **exactly** what it is today, and is now definitionally the union:

    Map.keys(coverage(opts)) == coverage_by_kind(opts) |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

Asserted in the conformance suite so a venue cannot implement one without the other agreeing.
This is what keeps the addition honest rather than a second, drifting source of truth.

### Optional, deliberately

Declared in `@optional_callbacks`, which this behaviour already uses for `list_instruments/1`
and `quantization/1`.

A venue package depends on Core **from Hex**. A required callback would mean Core publishing
a version that every venue instantly fails to satisfy, with a window where the family does not
compile — precisely the cross-repo coupling that produced the premature-deploy incident, and
that delayed Robinhood's `:gfw`/`:gfm` wiring behind a Core release. Optional means Core ships
first and each venue adopts when it adopts, with nothing broken in between.

The conformance suite asserts the invariant **when the callback is exported**, and says
nothing when it is not — an absent optional callback is a venue that has not adopted yet, not
a failure.

### What this is not

- **Not a replacement for `coverage/1`.** A caller asking "is anything arriving for this
  symbol" still gets a straight answer without knowing a venue's channel vocabulary.
- **Not a per-channel report.** `level2` versus `ticker` is Coinbase's vocabulary; the facade
  speaks `data_kind()`. A consumer must not have to learn a venue's channel names — that is
  the boundary this whole family exists to hold.
- **Not a latency or freshness API.** It reports the same observed-arrival fact `coverage/1`
  reports, split by kind. Freshness is a separate question and is not smuggled in here.

## 3. Checklist

### Core (ships first)

- [x] `@callback coverage_by_kind(keyword()) :: %{data_kind() => %{symbol() => route()}}`,
      added to `@optional_callbacks`, documented with the #22 incident as the reason it
      exists — per the convention that a moduledoc explaining *why* a guard is there is the
      most valuable thing in the file.
      **Found:** the callback's moduledoc in `lib/dp_exchange/core/venue.ex` carries the full
      incident (the 11,000-frame `level2` vs. dark `ticker` split, the verified
      `coverage after ONLY an OrderBook` run) and states the three "is NOT" boundaries from
      §2 verbatim. Also added `{:coverage_by_kind, 1}` to `Venue.peripheral_endpoints/0`
      ("irreplaceable and not load-bearing") because `venue_test.exs` has an assertion that
      every callback is classified core-or-peripheral, and this one is neither trading nor
      irreplaceable-and-load-bearing — that test would have failed silently pointing at the
      wrong thing without this.
- [x] `AdapterContract` assertion: when exported, the union invariant holds, and every key is
      a `data_kind()` the venue declares in `capabilities().streamable`.
      **Found:** implemented as assertion group 15 in `lib/dp_exchange/core/adapter_contract.ex`,
      guarded by `Code.ensure_loaded?/1` then `function_exported?/3` per the design's own
      instruction (the former is what stops the latter reporting a false negative for a
      merely-unloaded module). Also found, while touching `assertions/0`: the moduledoc said
      "Thirteen groups" while the function already listed fourteen before this change — a
      pre-existing drift, corrected alongside the new fifteenth entry.
- [x] `required_callbacks/0` unchanged — this is not required.
      **Found:** true with no code change needed — it is derived as
      `behaviour_info(:callbacks) -- behaviour_info(:optional_callbacks)`, so adding the new
      callback to `@optional_callbacks` was sufficient; `venue_test.exs`'s
      `"required_callbacks/0 is derived, not hand-maintained"` test continued to pass
      unmodified.
- [x] `usage-rules/` documents it, including the "collapses to one boolean" failure it exists
      to make visible.
      **Found:** added to `usage-rules.md` (new "`coverage/1` alone cannot tell a half-dead
      feed from a healthy one" subsection) and to `usage-rules/feeds.md` (same failure, in
      the file a consumer actually reads for feed/coverage behaviour) — both lead with the
      Coinbase incident before the callback's shape, per the design's explicit ask.

**Also found, not itemised above:** the callback count cited in `README.md`,
`usage-rules.md`, `usage-rules/adapter.md` and `usage-rules/testing.md` ("87 callbacks") and
the assertion-group count in `usage-rules/testing.md` and
`docs/guides/building-an-exchange-package.md` ("14 assertion groups" / "fourteen") were both
correct *before* this change and both became stale *by* it — corrected to 88 and fifteen in
the same change that made them wrong, rather than left for the next drift-hunt to find.

**Regression tests added**, per the plan's own gate: `test/dp_exchange/core/contract_teeth_test.exs`
gained three fixtures (`Broken.CoverageByKind.Conforming`, `.UnionViolation`,
`.UndeclaredKind`) and a `describe` block replicating assertion 15's exact computation against
each — the same mimicry pattern already used there for assertions 1, 4 and 12, rather than
running the full generated `AdapterContract` suite a second time per fixture. The "absent
callback" branch is proven by the existing `AdapterContractTest` (run against `ReferenceVenue`,
which deliberately does not implement `coverage_by_kind/1`) continuing to pass unmodified with
the new assertion group added, plus an explicit `refute function_exported?(ReferenceVenue,
:coverage_by_kind, 1)` regression guard so a future addition of the callback to `ReferenceVenue`
is caught rather than silently invalidating what that green run was proving.

Gates run clean: `mix test` — 18 doctests, 532 tests, 0 failures. `mix quality` — format,
`credo --strict` (496 mods/funs, no issues), `dialyzer` (0 errors), `sobelow --config` (scan
complete, no findings) — all clean. `mix test --cover` — 93.75% total, unchanged from the
pre-change baseline (the new assertion group lives in macro-generating code that coverage
does not attribute the same way; verified by diffing coverage output before and after with
`git stash`). `mix docs` — zero documentation-reference warnings.

### Venues (after Core publishes)

- [x] **Coinbase** — `:quotes` from `Types.Quote`, `:order_book` from `Types.OrderBook`. The
      motivating case; its `Feed` already routes both through one `handle_info`, so the kind
      is available exactly where `delivering` is written.
      **Found:** as designed, no surprises. 597 tests, 91.45% coverage.
- [x] **Gemini** — `:quotes` and `:top_of_book`, per its `streamable`.
      **Found:** an asymmetry worth recording. `:top_of_book`-only is real and common (a
      quiet book with no recent trade) and is what the isolation test exercises. A
      `:quotes`-only state is **unreachable** on the real socket: a `Quote` is only ever
      emitted from a frame that has already produced a `TopOfBook`. Reported rather than
      papered over with a manufactured test for a direction the venue cannot produce.
      725 tests, 90.29% coverage.
- [x] **Webull** — `:quotes` **and `:top_of_book`**. The plan above said `:quotes` only, and
      the plan was wrong.
      **Found:** implementing this surfaced a separate, consumer-visible defect. The venue
      genuinely streams both — `socket.ex`'s `snapshot` topic builds `%Types.Quote{}` with a
      real price, its `quote` topic builds `%Types.TopOfBook{}`, and `Subscription` subscribes
      both unconditionally (`sub_types` defaults to `["SNAPSHOT", "QUOTE"]`) — while
      `capabilities().streamable` declared `[:quotes]` alone. So a consumer was never told to
      expect `%TopOfBook{}` structs on its subscriber.

      The `TopOfBook` emission is **not** the bug and must not be "fixed": `socket.ex`'s own
      comment records that this code previously built a `Quote` with `price: bid || ask`,
      "defended in a comment as 'a real quoted number, labelled as the bid too'. It is real,
      and it is not a price." Reverting to `Quote`-only delivery would reinstate exactly the
      substitution this family exists to refuse, and that same bug was found on two other
      venues here, one of which shipped it. The stale **declaration** was the defect.

      Fixed to `[:quotes, :top_of_book]`, justified in the declaration as a delivery-path
      fact read from source rather than dressed up as a fresh venue probe, and given its own
      `### Fixed` CHANGELOG entry separate from the `coverage_by_kind/1` addition — burying a
      consumer-visible correction inside a diagnostics change would hide it from anyone
      scanning for behaviour changes. 686 tests, 91.23% coverage.
- [x] **Schwab** — `:quotes` and `:order_book`; note its `PollingFeed` fallback route reports
      `:internal_poll`, so both a kind *and* a route can differ per symbol here.
      **Found:** the mixed kind-and-route case is real and is handled. 411 tests, 90.74%.
- [x] **Robinhood** — `:top_of_book` only, by poll. A single-key map is still the right shape;
      uniformity is the point.
      **Found:** as designed. 183 tests, 94.75% coverage.

## 4. Rejected alternatives

- **Change `coverage/1`'s value type** to carry kinds. Breaks every existing consumer for a
  diagnostic addition. Refused.
- **`:subscribed_pending` as a new route value** (the consumer's option 1). Wrong axis — see
  above — and it would weaken the one guarantee `coverage/1` currently makes absolutely.
- **A `delivering/1` companion** (the consumer's option 2). Same wrong axis, and it would
  duplicate `coverage/1` rather than refine it.
- **Report venue channel names** (`"level2"`, `"ticker"`). Leaks venue internals through the
  facade. A consumer would have to learn five vocabularies to ask one question.

## 5. Retrospective

Shipped: Core `0.1.48` first, then all five venues in one batch. 2,602 tests across the six
repos, every gate clean, coverage 90.29–94.75%.

### The plan was wrong about one venue, and finding out was the point

§3 listed Webull as `:quotes` only. That was taken from its own `capabilities().streamable`,
and `streamable` was stale — the venue has always also delivered `%Types.TopOfBook{}`. The
instruction that caught it was "STOP and report rather than bending the data to fit"; without
it the honest options were to declare a kind the venue does not stream, or to quietly drop
`TopOfBook` from the derivation and hide a real capability. Either would have produced a
green suite and a wrong answer.

**The near-miss worth recording:** the obvious "fix" for a package emitting an undeclared kind
is to stop emitting it. Here that would have reinstated a defect the code had already been
fixed for — `socket.ex` used to build a `Quote` with `price: bid || ask`, and its comment says
why that is wrong ("a bid is a resting order; a price is an execution"). The same substitution
was found on two other venues in this family, one of which shipped it. The declaration was the
defect; the delivery was the earlier fix working. Only reading the incident comment made that
obvious, which is the strongest argument yet for this codebase's convention that a moduledoc
recording *why* is the most valuable thing in the file.

### What the design got right, and what that cost

Making the callback optional was correct and cheap. Core published alone, nothing broke, and
each venue adopted without a synchronised release — the coupling that caused a premature-deploy
incident and delayed the `:gfw`/`:gfm` wiring did not recur.

The union invariant earned its place immediately: it is what forced Webull's contradiction into
the open instead of letting `coverage_by_kind/1` quietly disagree with `coverage/1`.

### An honest negative result

Gemini cannot produce a `:quotes`-only state at all — a `Quote` only ever arrives nested in a
frame that has already produced a `TopOfBook`. That was reported rather than covered by a
manufactured test for a direction the venue cannot reach. A test asserting an impossible state
proves nothing and would have to be deleted the first time anyone read it carefully.

### What this does not settle

Nothing here explains the original `"too many L2 streams requested in a single session"`
rejection in #22. It makes that failure *visible* — a consumer can now see ticker dark while
the book is healthy, instead of reading 406/406 and looking elsewhere for days — but visibility
is not a diagnosis. #22 stays open on its own evidence.
