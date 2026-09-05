# Coverage by data kind

**Status:** Implementing — Core's checklist (§3) is complete; venue adoption is tracked
there and not yet started
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

- [ ] Make "which data kind is arriving, per symbol" answerable through the facade
- [ ] Break no existing consumer of `coverage/1`
- [ ] Require no venue to ship simultaneously with Core — the cross-repo coupling that
      caused a premature-deploy incident once and delayed the `:gfw`/`:gfm` wiring again
- [ ] Prove the new answer against real delivery, never against subscription state

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

- [ ] **Coinbase** — `:quotes` from `Types.Quote`, `:order_book` from `Types.OrderBook`. The
      motivating case; its `Feed` already routes both through one `handle_info`, so the kind
      is available exactly where `delivering` is written.
- [ ] **Gemini** — `:quotes` and `:top_of_book`, per its `streamable`
- [ ] **Webull** — `:quotes`
- [ ] **Schwab** — `:quotes` and `:order_book`; note its `PollingFeed` fallback route reports
      `:internal_poll`, so both a kind *and* a route can differ per symbol here
- [ ] **Robinhood** — `:top_of_book` only, by poll. A single-key map is still the right shape;
      uniformity is the point.

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

_To be appended on completion._
