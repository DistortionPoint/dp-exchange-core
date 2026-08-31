# CLAUDE.md

Guidance for Claude Code working in this repository.

**ABSOLUTE RULES**:
***THIS IS ELIXIR. It is Functional, Parallel, and Concurrent. You CAN NOT treat this like Python, Ruby, or Javascript.
1. ALL operations MUST be concurrent/parallel in a single message
2. Prefer Agents over MCPs
3. **NEVER save working files, text/mds and tests to the root folder**
4. ALWAYS organize files in appropriate subdirectories
5. ALWAYS do CI Checks before COMMIT
6. NEVER COMMIT OR PUSH without confirmation
7. MANAGE YOUR CONTEXT
8. ALL TESTS MUST PASS — 0 failures allowed
9. ALL Credo issues must pass. Not just some, not just critical, ALL
10. NEVER USE PERL or PYTHON
11. NEVER USE the SYSTEM TMP. NEVER MEANS NEVER. DO NOT EVER DO THIS
12. NEVER REWRITE SHARED GIT HISTORY — no force-push, no rewriting a branch that has
    been pushed, no `git reset --hard` over work you did not create. Ordinary git IS
    allowed and expected: `status`, `diff`, `log`, `add`, `commit`, `rebase` onto
    `origin`, `push`. Rule 6 is the gate on commit and push, and it is the only gate.
    This rule was previously written as "NEVER USE GIT", which was wrong: publishing is
    a merge to `main`, so that reading made the package pipeline unrunnable and turned a
    self-imposed rule into a fake blocker handed back to the architect.
13. NEVER USE KILL/PKILL UNSCOPED, only scoped to your specific things. NEVER MEANS NEVER. DO NOT EVER DO THIS

**THIS REPO IS PUBLIC.** Every commit is a public commit, and git history is not
retractable. Verify `.gitignore` covers `.env*` (except `.env.sample`) and `.mcp.json`
before anything is staged. A leaked credential is not fixed by a later commit.

## Project Overview

`dp_exchange_core` is the shared contract for the **DpExchange** family of exchange
adapter packages. It defines what a venue package *is* — the facade every one exposes,
the value types they return, the canonical-pair normaliser, and the conformance suite
that proves an implementation conforms.

This package talks to no exchange itself. Each venue lives in its own repo and its own
Hex package, depends on this one, and shares the `DpExchange.*` namespace that this
package owns.

**Status: EXPERIMENTAL.** It has not run in production. Maturity is declared per
endpoint through `capabilities/0`, not per package.

## Essential Commands

### Development
```bash
mix deps.get            # Fetch dependencies
mix compile             # Compile the library
iex -S mix              # Interactive shell with the library loaded
```

### Testing & Quality
```bash
mix test                            # Run tests
mix test --cover                    # With coverage (threshold: 90)
mix format                          # Format
mix quality                         # format --check-formatted + credo --strict + dialyzer + sobelow
```

### Publishing
Publishing is automatic. Every merge to `main` runs CI and publishes the next patch
version. Do not run `mix hex.publish` by hand.

## Architecture

### The facade is the boundary

Every venue package exposes the **same** facade and nothing crosses it. Transport
(websocket, MQTT, polling), rate limiting, credential handling and session lifecycle are
venue-internal. A consumer cannot tell from the facade how data reaches the package, and
must not be able to.

This is the load-bearing decision of the whole family. When a change would make the host
or a consumer aware of *how* a venue works, that change is wrong.

### What Core ships, and what it deliberately does not

Core ships the contract: behaviours, `Core.Types.*`, canonical-pair normalisation, HTTP
primitives, a telemetry spec, a polling feed and the conformance suite.

Core ships **no venue-specific dependency**. There is no `websockex` here at any
strength — not a hard dep, not `optional: true`. A venue that speaks WebSocket ships
what it needs to speak it. The only thing every package must depend on is the contract.

### A library does not start itself

No `Application` module that starts processes on load. Packages expose `child_spec/1`
and are supervised by the consumer. A consumer who has not asked for a venue must not
find a socket open.

## Configuration

**`config/runtime.exs` is the only file that may call `System.get_env/1`.**
`config.exs`, `dev.exs`, `test.exs` and `prod.exs` are static and MUST NOT read the
environment. Every runtime read carries a dev/test fallback literal.

Prefer `Application.get_env/3` over `Application.compile_env/3`. In a library
`compile_env` freezes whatever the *consumer's* config said at dependency-compile time,
so anything a consumer is meant to configure must be read at call time.

`config/` is not shipped — it is absent from `mix.exs`'s `files:` and governs this
package's own dev and test only.

### Secrets

Secrets live in `.env` files and nowhere else. `.env.sample` is the only committed one.
There is no `config/*.secret.exs` and no Vault layer.

Adding a var is a five-step lifecycle, all five or none: the `runtime.exs` read with a
fallback; a placeholder in `.env.sample`; the real value in your local `.env.*`; tell
CI; tell the deploy platform.

## Testing Strategy

Four tiers, and only the first two ever run unattended:

1. **In-process fakes** — every CI run. The default.
2. **Live public endpoints** — per venue, by hand, during its extraction. Never on a
   schedule: a venue that sees a package polling it on a timer will rate-limit or block.
3. **Authenticated, read-only** — needs credentials this repo must never hold.
4. **Money-moving** — never a test. It is answered in production by a consumer trading
   live, which is what moves an endpoint to `:proven`.

Tests must be `async: true` safe. Configuration seams resolve through a process-scoped
lookup so two async tests can want the same fake to behave differently.

## Code Quality Requirements

- Coverage threshold 90, enforced by `mix test --cover`
- `mix credo --strict` clean — ALL issues, not just critical
- `mix dialyzer` clean
- `@moduledoc` and `@doc` on everything public; `@spec` on every public function
- Formatted at `line_length: 98`

### When a moduledoc records an incident

Some code exists because something failed in production. Where a moduledoc explains
*why* a guard is there, that explanation is the most valuable thing in the file. Carry
it when the code moves or is copied. Do not compress it away.

## Critical Development Principles

### Fail closed; never substitute

The recurring failure mode in this family is **a nearby substitute where there should be
an error**: a missing granularity becoming the closest one, a missing endpoint becoming
synthetic data, an unknown source counting as evidence. Every value stays plausible and
only the meaning is wrong, which is why it does not surface as a failure.

Return `:error`. Raise. Refuse. Do not guess a value that looks right.

### Declare what you measured, not what you assume

A capability declaration is a claim about a real venue. If it was measured, say when and
against what. If it was read from documentation and never probed, say that too. An
unlabelled number is worse than a missing one.

### Definition of "Done"

- Tests written and passing, 0 failures
- `mix quality` clean
- Coverage at or above threshold
- Public functions documented with `@doc` and `@spec`
- CHANGELOG entry where behaviour changed
- The design doc's checklist item marked, with what was found

## Document Driven Design (DDD)

Design documents come before implementation. The plan is written, reviewed and approved
first; the work then follows its checklist and the checklist is kept current as work
lands — a task marked done records **what was found**, not just that it finished.

## Documentation Standards

### Structure
```
docs/design/            # Active design documents
docs/design/closed/     # Completed, with a retrospective appended
docs/design/ideas/      # Non-blocking discoveries; no date prefix
docs/design/templates/  # Document templates
docs/design/workflow/   # Collaboration and naming conventions
docs/reference/         # Venue API documentation, committed verbatim
```

Design docs are `YYYY-MM-DD_design-topic-name.md`. Status is one of
`Draft → In Review → Approved → Implementing → Implemented`. On `Implemented` — all
checklist items done *and* a retrospective appended — move the document to
`docs/design/closed/`.

Point at `docs/design/` as a directory. Do not reference individual design documents or
work items from this file.

### Consumer documentation

`usage-rules.md` ships inside the Hex tarball and is what a consuming agent reads. It is
not optional and it is not the README.
