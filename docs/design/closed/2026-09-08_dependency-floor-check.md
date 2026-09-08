# Resolving to the declared dependency floor

**Status:** Implemented
**Date:** 2026-09-08

## Context

**A `mix.exs` constraint permits a minimum version the code would not actually run
against**, three times in two days, always the same shape:

- `dp_exchange_webull` declared `{:websockex, "~> 0.4"}` while calling
  `WebSockex.send_frame/3`, which exists only from 0.5.1. Reported by a consumer
  (DpCryptoManagement) who resolved 0.4.x and got `:undef`.
- `dp_exchange_webull` declared `{:dp_exchange_core, "~> 0.1.48"}` while `capabilities/0`
  declares `no_venue_contact`, a `Capabilities` field added in Core 0.1.68.
  `Capabilities.new/1` builds with `struct!/2`, so an older Core raised `KeyError` on
  **every** `capabilities/0` call.
- `dp_exchange_gemini` declared `~> 0.1.48` while calling
  `Types.OrderBookDelta.new/1`, added in Core 0.1.53.

Ordinary CI cannot catch this class of bug: `mix deps.get` always resolves the *newest*
version a requirement allows, so a floor that is too low compiles and passes silently.
Only a consumer who resolves an older, still-permitted version finds out — and finds out
as a crash in their own application. Per-API pinning tests (`function_exported?/3` after
`Code.ensure_loaded!/1`, a struct-field check) guard a floor against being lowered again;
they cannot catch a floor that was wrong when it was written, because a test like that
only knows what its author already thought to check.

The task: determine whether a "resolve every dependency to its floor and compile/test
against that" check can be built cleanly and reliably for this family, and build it only
if so.

## 1. Objectives

- [x] Determine whether Hex can be forced to resolve a set of dependencies at their
      declared floor, for both direct and transitive dependencies, and whether that
      resolution is stable enough to run unattended
- [x] Decide what scope of dependency (runtime vs. dev/test-only) the check should cover,
      with evidence rather than a guess
- [x] Decide what the check should actually run (compile only? the full suite? something
      narrower?), with evidence
- [x] Decide where it runs — per-push, scheduled, or by hand — weighed explicitly against
      blast radius: this family publishes on every merge to `main`
- [x] Verify all six repos are clean at their currently-declared floors before the check
      ships, so it starts green and any future red is a real regression
- [x] Leave every repo's quality gates green; no repo left with an experimental
      modification uncommitted

## 2. Checklist

- [x] **Prove Hex resolves an exact floor pin, for a real dependency tree.** In a scratch
      copy of `dp_exchange_webull` (never the real checkout — `rsync --exclude _build
      --exclude deps ...` into `tmp/`), rewrote every runtime `~> X.Y[.Z]` requirement to
      `== ` its own floor version (`dp_exchange_core == 0.1.68`, `websockex == 0.5.0`,
      `jason == 1.4.0`, `decimal == 2.0.0`) and ran `mix deps.get` with `mix.lock`
      deleted.
      **Found:** resolves cleanly, including every transitive dependency of the pinned
      set (`req`, `telemetry`, `finch`, `mint`, ...) — Hex has no trouble satisfying an
      exact-version requirement sitting inside an otherwise-normal dependency graph.
      Transitive packages this repo does not declare itself still float to whatever is
      newest today, since nothing pins them; that turned out to matter (see the scope
      finding below).
- [x] **Determine whether dev/test-only tooling belongs in the pin.** Extended the same
      pin to `credo`, `dialyxir`, `sobelow`, `ex_doc`, `usage_rules` at their declared
      floors (`credo == 1.7.0`, etc.) and ran `mix compile --warnings-as-errors`.
      **Found:** compilation fails outright — `credo` `1.7.0` does not compile under
      Elixir 1.18 at all (`Regex.CompileError` in `lib/credo/check/config_comment_finder.ex`,
      a bug in that seven-year-old release, unrelated to anything in this family). The
      real, currently-locked `credo` is `1.7.19`; nothing between `1.7.0` and `1.7.19` was
      tested, only the floor. This is decisive, not just directional: dev/test-only tools
      are excluded from the check entirely. They never reach a consumer's dependency tree
      (`only: :dev`/`:test`), so their floor is not a claim this family makes to anyone,
      and pinning one produces a permanently red result that has nothing to do with
      whether this package's own floor is honest.
- [x] **Determine what the check should run.** First pass ran the pinned package's full
      `mix test`. Reverting only the `websockex` pin on `dp_exchange_coinbase` between
      `== 0.4.0` and `== 0.5.1` (three repeated runs each way, deterministic both ways)
      showed three tests failing at `0.4.0` and none at `0.5.1` — `Feed`'s
      `update_symbols` tests, which open a **real** `WebSockex` connection to the live
      production endpoint (`wss://advanced-trade-ws.coinbase.com`; confirmed reachable
      and confirmed to answer from this environment). That is a genuine dependency on the
      live venue inside a file the rest of this family's testing tiers document as
      tier-1/unattended — a separate, pre-existing defect in that package's test suite,
      out of scope for this document, and not something the floor check should be made to
      route around or paper over.
      **Decision:** the check does not run a blanket `mix test`. It runs
      `mix compile --warnings-as-errors` (catches an undefined remote call — the
      `websockex` shape) plus the package's own `AdapterContract` conformance test only
      (catches a missing struct field or module — the other two shapes; it exercises
      `capabilities/0` under a fully offline `Fake` and one of its own assertions is
      titled "capabilities/0 needs no credentials and no network"). Verified this
      combination reproduces all three original incidents and misses none of them (see
      §3).
      **Filed, not fixed:** the coinbase live-network test dependency, as a note for a
      separate design doc — fixing it is a different, larger body of work (rebuilding
      `feed_test.exs`'s socket-opening tests against a local fake transport) than this
      document's scope.
- [x] **Decide where it runs.** Even scoped to compile + one conformance file, the check
      still freshly resolves whatever *this repo does not pin itself* — `req`, `finch`,
      `mint`, and the rest of each floor-pinned dependency's own transitive tree — to
      whatever is newest on Hex today. That set can change on its own, independent of any
      commit to this repo, which is exactly the instability this family was warned to
      watch for ("a check that breaks when an unrelated dependency republishes is worse
      than nothing"). **Decision:** a new, separate workflow
      (`.github/workflows/floor-check.yml`), triggered `schedule: cron '0 9 * * 1'`
      (weekly) plus `workflow_dispatch` — never `push`/`pull_request`, never in `ci.yml`'s
      `publish` job's `needs:` chain, never a required check. A red run here cannot block
      a merge or the auto-publish pipeline that runs on every merge to `main`. Weekly
      bounds how long a real regression can sit undiscovered without making a floating
      transitive dependency's own release schedule into the background color of every
      pull request — the exact failure mode this family already paid for once (the
      publish-step hardening recorded in `ci.yml`, for a run that went red on a success).
- [x] **Verify all six repos are clean at their declared floors today**, so the check
      starts green (`mix compile --warnings-as-errors` + the package's `AdapterContract`
      test, or the full suite for `dp_exchange_core` itself, which defines that suite
      rather than consuming it):
      - `dp_exchange_core` (floor: `req == 0.5.0`, `jason == 1.4.0`, `decimal == 2.0.0`,
        `telemetry == 1.0.0`) — clean.
      - `dp_exchange_coinbase` (floor: `dp_exchange_core == 0.1.53`,
        `websockex == 0.4.0`, `jason == 1.4.0`, `decimal == 2.0.0`) — clean.
      - `dp_exchange_gemini` (same shape, `dp_exchange_core == 0.1.53`,
        `websockex == 0.4.0`) — clean.
      - `dp_exchange_schwab` (floor: `dp_exchange_core == 0.1.50`,
        `websockex == 0.4.0`) — clean.
      - `dp_exchange_robinhood` (floor: `dp_exchange_core == 0.1.50`, no `websockex`) —
        clean.
      - `dp_exchange_webull` — **not clean as found.** See next item.
- [x] **`dp_exchange_webull`'s own `~> 0.5` websockex floor was still wrong.** This
      package had already been corrected once, mid-sweep, from `~> 0.4` to `~> 0.5`
      (commit `71789dd`'s sibling `websockex` fix, same reasoning as the `dp_exchange_core`
      bump), on the belief that the third `send_frame` argument "only exists from 0.5".
      Resolving that floor for real (rather than reasoning about it) found
      `WebSockex.send_frame/3 is undefined or private` against `0.5.0` itself.
      **Found, by direct source comparison of both resolved versions:**
      `deps/websockex/lib/websockex.ex` in `0.5.0` defines only `send_frame(client,
      frame)`; the same file in `0.5.1` defines `send_frame(client, frame, timeout \\
      5_000)`. `~> 0.5` permits `0.5.0`, which lacks the arity `Socket.disconnect/2`
      calls. **Fixed:** floor raised to `~> 0.5.1`, with the comment corrected to name the
      exact patch and to record that the first correction was itself unresolved. No
      `mix.lock` change was needed — the real repo already had `0.5.1` locked; only the
      stated floor was wrong. Re-ran the check after the fix: clean.
- [x] **Ship the check itself, identically shaped in all six repos** (matching this
      family's existing convention of duplicating `ci.yml` near-verbatim rather than a
      shared reusable workflow):
      - `script/check_dependency_floor.sh` — copies the repo into `tmp/floor_check`
        (repo-local, gitignored, never the system tmp), pins every dependency declared
        *without* `only:` to `==` its floor (three-part requirements keep their patch;
        two-part float to `.0`; scoped to lines opening a `{:name, ...` deps tuple so the
        unrelated `elixir: "~> 1.18"` project requirement is never touched), then runs
        `mix deps.get`, `mix compile --warnings-as-errors`, and the package's
        `AdapterContract` test (full suite for Core itself).
      - `.github/workflows/floor-check.yml` — `schedule` (weekly) + `workflow_dispatch`,
        `runs-on: ubuntu-latest`, matrix `otp: ['28.0']` / `elixir: ['1.18']` matching
        `ci.yml`, one step running the script.
      - `usage-rules/adapter.md` — new "Dependency floors are a claim exactly like a
        capability" section: the four incidents, why a per-API pinning test cannot catch
        this class, what the script does and does not run and why, and "raising
        `mix.lock` is never a substitute for raising the floor in `mix.exs`" stated
        plainly, for the next person editing any venue's `mix.exs`.
- [x] Gates, every repo touched: `mix test` (3 seeds) 0 failures; `mix quality` clean;
      `mix test --cover` ≥ 90; `mix docs` clean; `git status` clean of any experimental
      leftover before commit.

## 3. Verifying the check against the three known incidents

Replayed each incident's *shape* (not the historical `mix.exs`, which no longer exists in
this repo's history in a form worth resurrecting) against what `script/check_dependency_floor.sh`
actually runs:

- **`websockex`/`send_frame/3` (webull).** `mix compile --warnings-as-errors` against the
  pinned floor. Confirmed live during this work, twice — once against the *original*
  `~> 0.4` floor's permitted `0.4.0`, and again against the *first, still-wrong*
  correction's permitted `0.5.0`. Both produce `WebSockex.send_frame/3 is undefined or
  private`, which fails the build under `--warnings-as-errors`. **Caught.**
- **`capabilities/0`/`no_venue_contact` (webull).** Not a compile-time shape —
  `Capabilities.new/1` builds a struct from a runtime keyword list via `struct!/2`, so the
  compiler cannot see the missing field statically. Caught by the `AdapterContract`
  conformance test's own `assert %Capabilities{} = caps = @venue.capabilities()`
  (`adapter_contract.ex`, "2. capabilities" group) — this is exactly the call the
  historical bug crashed on every consumer's boot. **Caught**, and only by the test half
  of the check; compile alone would have missed it. This is why the check is
  "compile + conformance test", not "compile only".
- **`Types.OrderBookDelta.new/1` (gemini).** A compile-time shape again —
  `WsDecode.to_order_book_delta/2` calls a module Core's floor does not ship, which the
  compiler reports the same way as the `websockex` case. **Caught** by the compile step.

All three covered; two by compile, one requires the conformance test, none requires a
full `mix test`.

## 4. What was deliberately not built

- **A full `mix test` at floor.** Rejected on evidence, not a guess — see the coinbase
  live-network finding in §2. Running the whole suite would make the floor check's own
  reliability hostage to a different, pre-existing defect in one venue's test suite.
- **A committed, frozen "floor lockfile"** to make repeated runs fully deterministic
  regardless of what Hex publishes later. Considered and rejected: it drifts silently the
  moment someone raises a floor in `mix.exs` without regenerating it — the exact
  "`mix.lock` moved, `mix.exs` did not" shape this whole check exists to catch, one layer
  up, in the check's own supporting file. A fresh resolve every run, accepting the
  transitive-float risk the weekly (not per-push) schedule is chosen to absorb, does not
  have that failure mode.
- **Pinning dev/test-only tooling.** Excluded on direct, reproduced evidence (`credo
  1.7.0` vs. Elixir 1.18) rather than the general principle alone — see §2.
- **Fixing `dp_exchange_coinbase`'s live-network test dependency.** Real, filed here,
  deliberately not fixed in this document — different scope, different size of change.

## 5. Retrospective

**The check is practical, was buildable cleanly, and found a real, still-live defect the
moment it was pointed at the family** — `dp_exchange_webull`'s own *corrected* `websockex`
floor was still wrong, by exactly one patch version, because the correction was reasoned
about rather than resolved. That is the same lesson this family drew from the original
three incidents, recurring inside the fix for one of them, caught by the first real run of
the tool built to catch it.

**The scope decisions all came from evidence produced while building it, not from
following the task's own suggestions verbatim.** The task offered three open questions —
dev tooling, blast radius, what to run — and each was answered by something that broke
during the work: credo really does not compile under current Elixir at its floor; the
full test suite really does depend on a live venue for one package; a fresh resolve really
does float transitive dependencies out from under a fixed pin. None of the three scope
decisions in §2 were available to make correctly before running the experiments that
produced them.

**A design document explaining a check is not a substitute for resolving it.** Stated
directly because it is the same finding as the webull correction, one level up: this
document could have reasoned its way to "`~> 0.5` covers `send_frame/3`" and been wrong in
exactly the way the family's own `mix.exs` comment was. Every claim in §2 and §3 above is
backed by a command that was actually run, not by inference from reading source.
