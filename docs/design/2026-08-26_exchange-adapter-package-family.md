# Exchange Adapter Package Family — Design Document

**Date**: 2026-08-26
**Status**: Implementing — approved by the architect 2026-08-27, Phase 0 underway
**Version**: 1.80
**Author(s)**: Billy / Claude collaboration
**Repo**: `DistortionPoint/dp-exchange-core` (`/Volumes/Dev/development/dp-exchange-core`)

---

## 0. Read This First — Session Bootstrap

This document is the **complete context handoff**. It was written from a session that
had read the whole source tree; that session ends when this file is saved. Everything
needed to start work is below or reachable from the paths below.

### Where you are

```
/Volumes/Dev/development/            <- NOT a git repo; just the parent dir
├── dp_crypto_management/            <- THE HOST APP. Source of everything being extracted.
├── influx-elixir/                   <- THE REFERENCE REPO. Copy its shape, CI, conventions.
├── dp-exchange-core/                <- YOU ARE HERE. Empty (0 commits, branch `main`).
├── dp-exchange-binance/             <- empty, 0 commits
├── dp-exchange-coinbase/            <- empty, 0 commits
├── dp-exchange-gemini/              <- empty, 0 commits
├── dp-exchange-kraken/              <- empty, 0 commits
├── dp-exchange-robinhood/           <- empty, 0 commits
├── dp-exchange-schwab/              <- empty, 0 commits
└── dp-exchange-webull/              <- empty, 0 commits
```

All eight repos are `git@github.com:DistortionPoint/<name>.git`, default branch `main`,
zero commits — **verified 2026-08-27 with `git ls-remote`, which exits 0 for all eight**.
They are empty **deliberately**; nothing is scaffolded until this plan is `Approved`.

A note for anyone probing this: the `gh` CLI's token here is a fine-grained PAT that
cannot see these repositories, so `gh repo view` answers 404 for a repository that plainly
exists. Ask the remote directly (D-F).

**Two of the eight stay empty past that.** `dp-exchange-binance` and `dp-exchange-kraken`
are **out of scope for this plan** (D21) — the architect can hold an account on neither, so
neither could ever graduate (D15). The repos and the hexpm names stay reserved; the work is
written up in `docs/design/ideas/binance-and-kraken-packages.md`. **Six packages ship here:**
core, coinbase, gemini, webull, robinhood, schwab.

### What this project is

Extract the exchange-connector code out of `dp_crypto_management` into a family of
standalone Elixir Hex packages: one shared `dp_exchange_core`, plus one package per
venue. Published to public hexpm; each repo is made public by the architect immediately
before its first publish. Never published privately — see D4.

**You are building the packages. Migrating the host app to consume them is explicitly
NOT part of this work** and not your concern. Do not edit `dp_crypto_management`
except to read from it.

### The five sources to read before writing code

1. This file, entirely.
2. `../influx-elixir/` — the proven DistortionPoint Elixir library repo. Specifically
   `mix.exs`, `.github/workflows/ci.yml`, `.credo.exs`, `.formatter.exs`,
   `.tool-versions`, `CLAUDE.md`, `usage-rules.md`, `usage-rules/`, and
   `test/support/client_contract.ex`.
3. `../dp_crypto_management/lib/dp_crypto_management/connectors/exchanges/core/` — the
   source being extracted. Appendix A lists every file.
4. **The venue's own web API documentation** — the vendor's documentation site, for every
   venue package, not only Schwab. See **D13**, which is explicit that third-party SDKs,
   GitHub client libraries and community write-ups do **not** count. Most venues'
   documentation is public; a few are private and the architect supplies those. Committed
   to `docs/reference/<venue>/` in the venue repo, and the ground truth the host's adapter
   is checked *against*.
5. `../dp_crypto_management/docs/` — roughly 130 documents accumulated over a long
   development. 57 closed design docs, 20 ideas, 15 development notes, 11 architecture
   docs, 13 fixed-bug reports. Appendix C inventories what is worth reading and why.
   **Mine it for reasoning, not for current state** — `architecture/exchange-capabilities.md`
   still lists Kraken and Robinhood as "planned" and Binance as "excluded" while all three
   ship today. The arguments age better than the facts.

### Tooling: the host's MCP and API surfaces

`dp_crypto_management` exposes ~94 MCP tools and an HTTP API. Several answer questions this
work asks repeatedly, and reading them beats reading source or guessing.

**Useful now, during extraction:**

- **`describe_exchange`** — *"what an exchange supports and what we collect from it"*, and
  crucially *"every value comes from the adapter's `capabilities/0`"*. That is D13's
  reconciliation input on one side of the diff, without opening `provider.ex`.
- **`get_pair_catalog`** — a venue's listed pairs, quotes and classification. The other
  side of the same diff, and the thing to check a symbol round-trip against (§6.1.4).
- **`get_collection_scope`** — what is collected on a venue and *why not*, when nothing is.
  Relevant to §6.0's split of collection policy: the venue declares what it can serve, the
  host decides what it will collect.

**Useful later, once the host adopts the packages — and this is the stronger case.** D15
graduates endpoints on evidence of production use, and §5.2 notes the evidence arrives as
`request.stop` telemetry. Telemetry is the raw signal; the MCP surface is where a human or
an agent can actually *ask*:

- **`get_execution_orders` / `tail_execution_orders`** — orders that actually went to a
  venue. That is tier-4 evidence (D7), which no test suite can produce.
- **`get_balance_ledger`**, **`get_backfill_status`** — the account and history paths
  exercised in earnest.
- **`describe_exchange` again** — it reads `capabilities/0` today, so once that becomes
  three-state (D15) the same tool answers *"which endpoints on this venue are proven?"*
  with no new surface built. Worth knowing before designing anything that duplicates it.

**How it is wired**: `.mcp.json` at the repo root, written during scaffolding alongside
`CLAUDE.md` and the agents and picked up on the same restart (§7.1, Phase 0.11). It is
**gitignored from the first commit** — the host's own copy carries a bearer token, and
these repos go public (D4).

None of this is a dependency — the packages must not know the host exists (D12), and
nothing in Phases 0–8 blocks on it. It is a reason to look something up rather than
reverse-engineer it, which is the same instinct D13 is built on. It also needs the host
running to answer, so a session without it is inconvenienced, not blocked.

### Absolute rules in force

From the org's canonical rule set (`first-principles--org_conventions`, category
`absolute_rules`, source `rules:elixir`). Pull the authoritative list from that MCP tool
when writing `CLAUDE.md` — do **not** copy `influx-elixir/CLAUDE.md`'s block, which has
drifted (11 entries vs. the canonical 13, and softer wording on commit/push).

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
11. NEVER USE the SYSTEM TMP (use `tmp/`)
12. NEVER USE GIT (without confirmation — see rule 6)
13. NEVER USE KILL/PKILL UNSCOPED

Plus, from the host app's `CLAUDE.md` and the project memory in
`influx-elixir/.claude/projects/*/memory/`:

- **NO MOCKING.** Never Mox, never Bypass. Test against real fixtures or a real
  in-process fake (see D7).
- **Document Driven Design.** Implementation is preceded by an approved design doc.
- **There is no such thing as a pre-existing test failure.**

### How to read the host app

**The host is the thing being corrected, not the reference implementation.** Read
`dp_crypto_management` for facts — what a venue's API does, what an incident cost, what a
moduledoc learned the hard way. Do not read it for authority on where a boundary belongs.

The host keeps crossing lines that need to be harder to cross, and this project exists
because of it. Several of the artifacts that look most like a specification are in fact
the symptom: `HostRateLimiter` (D-E) was written so adapters bypassing `Core.HttpClient`
would still meter; `websocket/supervisor.ex`'s `["coinbase","gemini"]` whitelist and
`provider_limiter.ex`'s `@provider_configs` are venue knowledge that leaked into shared
code (D12); the `case provider do "coinbase" -> …` codec table had Gemini's socket
speaking Coinbase's protocol for as long as it stood.

So: where the host and the contract disagree, **the contract wins**. Where the host's
implementation is newer than the contract, that is a reason for more suspicion, not less —
a recent workaround has had less time to be found wrong. When a defect is found, record it
here and report it to the host team; fixing it there is out of scope (§1).

**And after extraction this hardens.** During the work the host is a source to be read
sceptically; afterwards it is a **consumer**, with no authority over the packages at all
(D18). The direction of that relationship is worth holding in mind from the first commit,
because it is what makes "the contract wins" a standing rule rather than a temporary
convenience of the extraction.

---

## 1. Project Overview

### Why this exists

**The goal is to take a whole class of concern off `dp_crypto_management`'s plate.**

The host juggles a great deal — trading, positions, collection, scoping, credentials,
events, presentation. Exchange connectivity is one of the largest of those concerns and,
unlike most of the others, it is **completely separable**. Nothing about maintaining a
WebSocket to Coinbase, signing a Webull request, or paging Kraken's candles is specific to
this application. It is only there because it had to live somewhere.

So the host should not know that a venue exists in any way beyond naming it. Today it
knows far more than that — six provider tables (D12), a codec whitelist, a rate-limit
config map — and every one of those is a place the host has to be re-taught each time a
venue is added or changes. Removing that is worth more than the code it deletes: it
removes a category of thing the host has to be correct about.

**Every exchange does the same handful of things.** Get prices. Get balances. List
symbols. Fetch candles. Stream quotes. Place, cancel and read orders. That set is *core to
every venue* — it is what an exchange is. What differs is entirely in the how: Coinbase
signs with a CDP JWT and Webull with its own scheme; Coinbase pools frame WebSockets 100
pairs at a time while Webull speaks MQTT and Robinhood polls REST; Kraken allows 1 request
per second and Binance 10. Some venues additionally offer things others do not.

That shape — **identical core, divergent implementation, occasional extras** — is exactly
what a facade is for. It is also why D12 puts the whole strategy inside the venue package:
the differences are real and large, so hiding them behind one surface is the entire value,
and leaking any of them back out defeats it.

**And none of this is specific to us.** Any application connecting to several exchanges
needs precisely this, and today each one writes it again. That is the reason these are
public packages (D4) rather than an internal library: the problem is general, the solution
is general, and `dp_crypto_management` is the first consumer rather than the purpose. The
host's own migration is deliberately somebody else's work (§1 Out of scope) partly to keep
that honest — a package designed around one caller's convenience is not a library.

### Objectives

- [ ] **O0** — **Remove exchange connectivity from the host's list of concerns.** The
      measure of success is not lines moved but knowledge removed: when this is done the
      host names venues and calls one uniform interface, and knows nothing about how any

- [ ] **O1** — Publish `dp_exchange_core`: the shared contract every venue package
      compiles against (behaviours, value types, canonical-pair normalizer, HTTP
      primitives, telemetry spec, polling feed, conformance test suite).
- [ ] **O2** — Sever Core's two remaining dependencies on the host application so the
      package genuinely stands alone.
- [ ] **O3** — Make "the pattern" **executable** rather than prose: a conformance suite
      shipped in Core that every venue package runs in its own CI, so the five venue repos
      cannot drift.
- [ ] **O4** — Establish a single repo standard (skeleton, CI, quality gates, agent set,
      docs workflow) applied identically to the six repos in scope. The two reserved repos
      (D21) get a `README` pointing at the idea doc and nothing else.
- [ ] **O5** — Extract four venue packages from existing host code, and build one
      (`schwab`) greenfield against the finished contract. Binance and kraken are reserved,
      not built (D21).

### Scope

**In scope**

- The `dp-exchange-core` repo: full package, docs, CI, conformance suite, usage-rules.
- The repo standard, and its application to the five venue repos in scope.
- Extraction of `coinbase`, `gemini`, `webull`, `robinhood`.
- Greenfield `schwab`.
- Per-venue in-process fakes ("mock variants") owned by each venue package.
- **The venue API documentation** each package is built against, committed to
  `docs/reference/<venue>/` (D13), and the reconciliation of the host's adapter against
  it. Public docs for the four extracted venues; the architect supplies Schwab's.
- **The venue's whole connection strategy** — socket transport, subscription lifecycle,
  rate-limit enforcement, credential/session handling and its own supervision tree. Per
  **D12** these live inside the venue package, behind the §6.0 facade. Coinbase and Gemini
  must absorb the socket lifecycle they currently borrow from the host; the other four
  already own theirs.

**Out of scope**

- **Any change to `dp_crypto_management`.** The host app's migration onto these
  packages is separate work, by someone else, later. Read from it; never write to it.
  Out of scope includes deleting the host's now-redundant `websocket/` and
  `rate_limiting/` trees once the packages land — that deletion is the point of the
  exercise, but it is not this plan's work. What **is** in scope is the hand-off: the
  adoption issue filed on the host's repo once Core and Coinbase publish (D16, Phase 5.13).
- **`binance` and `kraken`** — no account is possible from the architect's jurisdiction, so
  neither could ever graduate out of EXPERIMENTAL (D15). Names and repos stay reserved;
  everything known is in `docs/design/ideas/binance-and-kraken-packages.md`. See **D21**.
- `coingecko` — not an exchange. See D10.
- Local path deps. Packages are consumed from Hex only. See D3.
- The host's `connectors/credentials/` — credential **storage** (vault CRUD,
  `exchange_management.ex`, 1,296 LOC) is host-side and never leaves. Credential **use**
  (signing, session refresh, token rotation) is venue strategy and crosses into the
  package per D12; credentials themselves arrive as function arguments (invariant #2).
- Host-side account/user scoping of rate limits. The packages meter by **venue** only
  (D5); a host that wants per-key or per-account limits builds them on its own side, and a
  host that wants more throughput clusters.

### Success Criteria

1. `dp_exchange_core` compiles, tests, and publishes with **zero** references to
   `DpCryptoManagement.*`, `Phoenix.*`, `Ash.*`, `Cloak.*`.
2. Each venue package's CI runs Core's conformance suite and passes it.
3. `mix quality` (format + credo --strict + dialyzer + sobelow) is clean in every repo.
4. Test coverage threshold met per repo (see D9).
5. A new venue can be added by implementing the `DpExchange.Core.Venue` facade (§6.0),
   with **zero** edits to Core, to any other venue package, **or to the host app** — the
   last clause is what D12 makes true and what six host provider tables make false today.
6. Every package documents itself to consumers via `usage-rules.md` shipped inside the
   Hex tarball.
7. **The O0 test** — a consumer can drive every venue through `DpExchange.Core.Venue`
   alone, with no venue-specific branch anywhere in its own code, and no knowledge of any
   venue's transport, limiter, signing or session handling. Demonstrated in Phase 4.5's
   scratch project against Core's reference fake, and again in Phase 5 against a real
   venue. This is the criterion the other five serve.

---

## 2. Subtask Checklist and Progress Tracking

The working checklist, and the place progress is recorded. **Rationale for every item lives
below** — §3 is what the host code does today (measured), §4 the decisions each task
implements, §5–§7 the specifications they build against. Nothing here should need to
restate a decision; it cites one.

**77 tasks across 9 phases.** Mark items `- [x] ~~struck~~ — **done YYYY-MM-DD**` with what
was found, not just that it finished; a task that only says "done" throws away the reason
the next phase might need.

| Phase | What it produces | Tasks | Gate at the end | Status |
|---|---|---:|---|---|
| **0** | `dp-exchange-core` repo foundation | 15 | 2 architect restart gates (§7.1) | ✅ **15/15 done** |
| **1** | Core: mechanical moves | 10 | `mix quality` clean | ✅ **10/10 done** |
| **2** | Core: the reworks — the two host dependencies severed | 11 | O2 satisfied | ✅ **11/11 done** |
| **3** | Core: the contract + reference fake | 7 | conformance suite runs | ✅ **7/7 done** |
| **4** | **Publish Core `0.1.x`** | 6 | 🛑 architect: repo public + `HEX_API_KEY` (D4) | ✅ **6/6 done — 0.1.2 live** |
| **5** | **Coinbase** — the reference extraction | 15 | 🛑 architect gate + retrospective 5.14 (D11) | ☐ not started |
| **6** | gemini → webull → robinhood; binance/kraken closed out | 4 | 🛑 architect gate per venue | ☐ not started |
| **7** | **Schwab**, greenfield | 5 | blocked until the architect supplies the docs (§10) | ☐ not started |
| **8** | Close | 4 | this doc moves to `docs/design/closed/` | ☐ not started |

**The three hard stops**, so they are not discovered mid-phase:

1. **Phase 0 and Phase 5.1 each contain two session restarts** — `.tool-versions`, then
   `CLAUDE.md` + agents. Neither takes effect in the session that wrote it, and the
   architect is needed at both (§7.1). Twelve restarts across the six in-scope repos.
2. **Every first publish needs the architect** to make the repo public and add the org
   `HEX_API_KEY` — once per repo, before that package ever ships (D4).
3. **Phase 7 cannot start until the Schwab API documentation arrives.** It is private, the
   architect supplies it, and there is no host adapter to derive the venue from (D10, §10).

### Phase 0 — Repo foundation (Core only)

**Two session restarts are built into this phase, and the architect is needed at both**
(§7.1). They are ordered deliberately: `.tool-versions` first and alone, because everything
downstream compiles against whatever toolchain is live; `CLAUDE.md` and the agents last
before the build, because neither takes effect in the session that wrote them.

- [x] ~~**0.1** `.tool-versions` — elixir 1.18.4-otp-28 / erlang 28.0.2 / nodejs 22.17.1.
      Written **alone and first**.~~ — **done 2026-08-27.** Byte-identical to
      influx-elixir's (D9) and to the host's, so all three repos resolve the same
      toolchain. Written alone: the repo now contains `.tool-versions` and `docs/` and
      nothing else. Confirmed the gate is real, not ceremonial — `elixir` was **not on
      `PATH` at all** in this session before the file existed, so nothing here has yet
      compiled against anything.
- [x] ~~**0.2** 🛑 **RESTART GATE — architect.** The session's toolchain was resolved at
      start; mise activates the new one only for a new session. Restart, then confirm
      `elixir --version` and `erl -eval ...` report what `.tool-versions` asks for. Do not
      proceed on a mismatch — everything after this compiles against it.~~ — **passed
      2026-08-27.** Restarted; `mise current` now resolves from this repo's file. Measured:
      Elixir **1.18.4** compiled with OTP 28, `erlang:system_info(otp_release)` = **28**
      with **erts-16.0.2** (the ERTS of OTP 28.0.2), node **v22.17.1**. All three match.
      Before the restart `elixir` was not on `PATH` at all, so the gate was load-bearing
      rather than ceremonial.
- [x] ~~**0.3** `.gitignore` — influx-elixir's as the baseline, plus `.mcp.json` and the
      `.env*` / `!.env.sample` pair (§7.7, D17). Written before anything else is committed,
      because these repos go public and history is not retractable.~~ — **done 2026-08-27.**
      influx-elixir's file with exactly three deltas: the Hex artifact glob renamed to
      `dp_exchange_core-*.tar`; influx's `.env` + `.env.*` replaced by the `.env*` /
      `!.env.sample` pair (influx has no negation, so its `.env.sample` would be ignored —
      ours must not be); and `.mcp.json` added. **The negation was verified, not assumed**
      (D17): with touched files in place, `git status --ignored=matching` reports
      `?? .env.sample` against `!! .env`, `!! .env.local`, `!! .mcp.json`.
- [x] ~~**0.4** `.formatter.exs`, `.credo.exs`, `LICENSE` (MIT / DistortionPoint)~~ —
      **done 2026-08-27.** All three copied byte-identical from influx-elixir (D9);
      `.credo.exs` was checked for project-specific references first and has none, so it
      transfers as-is — 93 checks, `strict: true`. `LICENSE` already reads
      *Copyright (c) 2026 DistortionPoint*. `.formatter.exs` is `line_length: 98`.
- [x] ~~**0.5** `mix.exs` per §7.2 at `@version "0.1.0"`~~ — **done 2026-08-27.**
      influx-elixir's structure with the §7.2 deltas: `app: :dp_exchange_core`,
      **no `mod:`** (a library does not start itself — §7.7), deps `req`/`jason`/
      `decimal`/`telemetry` with **no `websockex` at any strength** (D20), `description:`
      prefixed `EXPERIMENTAL —` (D15), and `test/support` in `files:` so the conformance
      suite ships (D8). `main: "readme"` for now, flipping to `DpExchange` at Phase 1.1.
      **Found and fixed a self-inflicted bug while writing it**: the comment explaining the
      CI bump script quoted the version-attribute literal verbatim, which would have made
      the script rewrite the comment line instead of the attribute. The comment now
      describes the form without reproducing it, and says why. Validated: Mix loads the
      project and stops only at missing deps, which is 0.14's job.
- [x] ~~**0.6** `config/{config,dev,prod,test,runtime}.exs` + `.env.sample` (§7.7).
      **`runtime.exs` is the only file that may call `System.get_env/1`**; the other four
      are static. Every read carries a dev fallback literal.~~ — **done 2026-08-27.**
      All five plus `.env.sample`. Verified by grep: zero `System.get_env` outside
      `runtime.exs`. **Note influx-elixir has no `runtime.exs` at all** — this is the gap
      §7.7 identified in the standard, so this is the one Phase 0 file with no upstream to
      copy. It currently reads **nothing**, and says why: Core is a contract library that
      opens no sockets and holds no credentials, and its one configurable seam
      (`:rate_limit_module`, D5) is read from the *consumer's* application environment at
      call time. The five-step add-a-var lifecycle is written into the file so the next
      person to need one follows it. `.env.sample` documents `HEX_API_KEY` — the only
      secret this repo touches — and states that venue credentials arrive as function
      arguments rather than env reads (invariant #2).
- [x] ~~**0.7** `.github/workflows/ci.yml` per §7.3~~ — **done 2026-08-27.**
      influx-elixir's workflow verbatim except one comment block, which now explains why
      there is no live-venue job: tier-1 fakes are every CI run, tier-2 runs per venue by
      hand during its extraction, never on a schedule (D7). Both jobs, both guards
      (`[skip ci]`, `concurrency` + `cancel-in-progress`), three caches, six quality
      commands.
      **Confirmed the 0.5 bug would have been fatal**, not cosmetic: the real bump script
      is `grep '@version "' mix.exs | sed ...` with **no `head -1`**, so a second matching
      line would have fed a two-line string into
      `IFS='.' read -r major minor patch` and produced a garbage version. Re-checked
      against the finished `mix.exs`: exactly one match, extracting `0.1.0`.
      **Open item for 1.10**: `mix quality` runs `sobelow --config`, and influx-elixir ships
      no `.sobelow-conf`. Whether that command can pass without one is unverified — checked
      at 0.14, when deps exist.
- [x] ~~**0.8** `docs/design/{README.md,templates/,workflow/}` from the host app, plus
      `docs/design/ideas/`~~ — **done 2026-08-27.** Six files copied, plus
      `docs/design/closed/.gitkeep` so Phase 8.4 has somewhere to `git mv` to (git does not
      track empty directories). `ideas/` already held its three.
      **The copies needed adapting, not just copying** — these repos are public (D4), and
      four of the six described a different application by name and credited an assistant
      the host stopped using. Project name corrected in four intros, and 11 references to
      `Roo` replaced with `Claude`.
      **Also found a contract mismatch**: the imported template offers
      `Draft | In Review | Approved | Implemented`, four states, while §7.6 of this plan
      defines five — it adds **`Implementing`**. Template corrected to match. This document
      is the first to use it and moved `Approved` → `Implementing` on the same edit.
- [x] ~~**0.9** `README.md` + `CHANGELOG.md`, both carrying the **EXPERIMENTAL** status per
      D15: what it means, what is thinly covered (D7 tiers 3–4), and where to report
      divergences. Written once here and copied into every venue repo.~~ — **done
      2026-08-27.** README opens on the banner as a blockquote above everything —
      **markers 1 and 4 of D15's five** are now in place (2 landed with `mix.exs` at 0.5;
      3 and 5 need code and land in Phase 1). The banner says the four things D15 requires
      it to say — API may change without a major version, never run in production, tiers
      3–4 thin, per-endpoint maturity in `capabilities/0` — and points at the issue
      tracker. It also tells the reader **not to trust the banner** and to read
      `capabilities/0` instead, since that is the marker that survives someone not reading
      READMEs. CHANGELOG states status at the top rather than per-release, and makes the
      evidence rule explicit: an entry moving an endpoint to `:proven` names the venue,
      what was run, and when.
      README also carries the family table, with binance and kraken listed as **reserved,
      unimplemented** and linked to their idea doc (D21) — a public reader should not have
      to guess why two of the eight names have no package.
- [x] ~~**0.10** `CLAUDE.md` per §7.4 (canonical ABSOLUTE RULES)~~ — **done 2026-08-27.**
      192 lines on influx-elixir's structure. **§7.4's correction was necessary, and
      measurably so**: `first-principles--org_conventions` returns **13** rules for
      `rules:elixir`, influx-elixir's `CLAUDE.md` carries **11**, and the host's carries
      another variant. Canonical is stricter on three points the copies had lost — rule 10
      is *"NEVER USE PERL or PYTHON"* where both copies say PERL only; rule 12
      *"NEVER USE GIT"* is absent from both; and rule 6 is *"NEVER COMMIT OR PUSH"* rather
      than push alone. This file carries the canonical 13 verbatim.
      Also carries the public-repo warning above everything, the `runtime.exs`-only env
      rule (§7.7), `get_env` over `compile_env` and why a library must, the four
      verification tiers, and *fail closed; never substitute* as the family's named failure
      mode. **No references to individual design docs** — recorded preference.
- [x] ~~**0.11** `.claude/agents/` via `agent-normalization--import_canonical`~~ — **done
      2026-08-27, but not with that tool.** `import_canonical` is an operator bootstrap for
      the orchestrator's *own registry* — it "refuses to run over an already-populated
      registry unless force: true" — and that registry already holds 18 agents. Calling it
      risked clobbering the org registry and would not have written one file here.
      **The task named the wrong tool; the work itself is unchanged.** Used
      `resolve_profile` (returns `{language: elixir, capabilities: [], frameworks: []}`)
      and `list_canonical_agents` instead.
      **Nine agents written**: influx-elixir's nine profile-appropriate files with each
      `ABSOLUTE RULES` block replaced by the canonical 13. influx's agent copies carry
      **12** and are missing *"ALL Credo issues must pass"* outright — not a rule to be
      missing in a repo whose CI runs `credo --strict`. Splice verified: +2 lines per file,
      content after the block intact, all nine carrying the Credo and PYTHON rules.
      **Two canonical agents deliberately excluded**, matching influx: `api-developer`
      (`applies_when: ["api"]`; we consume venue APIs rather than build one) and
      `deployment-cicd` (Docker / ECS / blue-green / auto-scaling — the Blueleaf deploy
      model §7.3 explicitly rules out for these repos). Flagged rather than silent.
- [x] ~~**0.12** `.mcp.json` — the host's MCP server, for the reasons in §0. **Gitignored
      from the first commit**, never committed: the host's own `.mcp.json` carries a bearer
      token and is ignored at `dp_crypto_management/.gitignore:256`. These repos go public
      (D4), and git history is not retractable. Each developer writes their own.~~ —
      **done 2026-08-27.** Confirmed the host's file at `.gitignore:256` and read its
      *structure only*, redacting the token at the pipe rather than pulling it into
      context. Wrote `.mcp.json` (ignored) plus a committed **`.mcp.json.sample`**, so the
      next developer gets the shape without needing to see anyone's token.
      **The local file carries the host's real token, and must** (architect, 2026-08-27).
      It points at the same server on `:4001`; a placeholder there does not authenticate,
      so the MCP tools §0 depends on simply do not work. `.mcp.json` here is now byte-
      identical to `dp_crypto_management/.mcp.json`. **This is safe because the file is
      gitignored, and only because of that** — verified with `git check-ignore`, and it
      reports `!!` rather than `??` in a status listing.
      **"Each developer writes their own" governs the committed sample, not the working
      file.** The distinction is the whole point of the pair: `.mcp.json.sample` is
      committed and carries `<your-token-here>`; `.mcp.json` is ignored and carries a real
      credential. Getting that backwards breaks the tooling in one direction and leaks a
      token in the other.
      **Two findings from running the audit rather than assuming it:**
      (a) `.claude/settings.local.json` and `.claude/projects/` are local state that
      influx-elixir commits — inherited drift, not a convention to keep. Both added to
      `.gitignore`; `.claude/agents/` stays committed, which is the part that is shared.
      (b) The sample's first placeholder, `REPLACE_WITH_YOUR_OWN_TOKEN`, **was itself
      token-shaped** — 27 characters inside a secret scanner's charset — and a local scan
      flagged it. Now `<your-token-here>`, whose angle brackets cannot match. Worth
      catching before 0.15 enables GitHub push protection, which would otherwise block the
      first push over a value that was never a secret.
- [x] ~~**0.13** 🛑 **RESTART GATE — architect.** `CLAUDE.md`, `.claude/agents/` and
      `.mcp.json` are all read at session start. The session that wrote them is not
      governed by them and cannot use them — it will cheerfully violate rules it cannot
      see, and cannot call the MCP tools it just configured. Restart before any work those
      rules are meant to constrain, which is all of it.~~ — **passed 2026-08-27.** Restarted;
      all three took effect, and the gate proved load-bearing on every one. The nine
      `.claude/agents/` files are now offered as agent types; `CLAUDE.md` loads as project
      instructions; and the **dp-crypto MCP server connected with 94 tools** — both §0's
      estimate confirmed and proof the real token from 0.12 was the right call, since a
      placeholder would have failed authentication silently.
- [x] ~~**0.14** `mix deps.get && mix compile --warnings-as-errors` green on an empty lib~~ —
      **done 2026-08-27.** 31 deps resolved, compile clean, `mix format --check-formatted`
      clean, `mix credo --strict` clean (0 files, as expected).
      **Answers the `sobelow --config` question parked at 0.7, and it needed a fix.** The
      command runs without a `.sobelow-conf` and exits **0**, so it never blocked
      `mix quality` — but it prints `Config.HTTPS: HTTPS Not Enabled — High Confidence`
      against `config/prod.exs` on every run. That is a **Phoenix endpoint check applied to
      a library that has no endpoint and no router**, and sobelow says so itself: *Sobelow
      cannot find the router.* **influx-elixir prints the identical false positive on every
      one of its own runs** — measured directly, so this is inherited noise rather than a
      convention. A check that is always red teaches everyone to stop reading the output.
      Wrote `.sobelow-conf` ignoring `Config.HTTPS`, with the reasoning in the file. Also
      set **`exit: :high`**, a deliberate deviation: sobelow's default is to exit 0 whatever
      it finds, so `mix quality` would report clean over a real vulnerability in a public
      package. Flagged rather than silent — overrule if unwanted.
      **`mix dialyzer` cannot pass yet, and that is correct.** It built and cached the PLT
      (4.4 MB, `priv/plts/dialyzer.plt`) and then exited **1** with *"No .beam files to
      analyze"* — `lib/` is empty. So `mix quality` as a whole fails at Phase 0 by
      construction; **1.10 is the first task that can honestly require it**, which is where
      the plan already puts it. The expensive half is now warm, so 1.10 pays seconds rather
      than minutes.
- [x] ~~**0.15** **Before the first commit (D17).** `git status --ignored` and confirm
      `.mcp.json` and every `.env*` except `.env.sample` are on the ignored side, and that
      `.env.sample` contains placeholders only. Enable GitHub
      secret scanning with push protection now, while the repo is still private — it is the
      layer that catches what `.gitignore` missed (D9, D17).~~
      **Local audit half: done 2026-08-27, re-run 2026-08-28, CLEAN.** 39 files would be committed. On the
      ignored side: `.mcp.json`, `.env` / `.env.local` / `.env.test` / `.env.dev`,
      `.claude/settings.local.json`, `_build/`, `deps/`, `priv/plts/`, `tmp/`.
      `.env.sample` is tracked and holds one placeholder line. A content scan of all 39
      files for bearer tokens, API-key assignments, private-key headers and Slack/GitHub
      token shapes returned two hits, **both verified placeholders**
      (`your-hex-api-key-here`, `your_api_key_here`). The `.claude/settings.local.json`
      ignore added at 0.12 has already earned itself — this session created that file.
      **GitHub half: attempted 2026-08-28, refused by the token.** `PATCH
      /repos/…` with `secret_scanning` and `secret_scanning_push_protection` returns
      **403 Resource not accessible by personal access token**, as does reading Actions
      secrets. The fine-grained PAT can read the repository now that it is public but
      cannot change its settings. **Architect action**: Settings → Code security →
      enable *Secret scanning* and *Push protection*. Free on a public repository.
      **The timing note in this task is now moot, and in the good direction.** It said
      to enable protection *while the repo is still private*, because flipping to public
      exposes every commit ever made. The repository went public on **2026-08-28 with
      zero commits**, so there was no history to expose. Push protection before the
      *first push* is still the right sequencing and is still available.
      **Two more token-shaped placeholders removed** — `your-hex-api-key-here` in
      `.env.sample` and `your_api_key_here` in a copied template. Same class as the
      `.mcp.json` one caught at 0.12: long enough to sit inside a scanner's charset, so
      push protection would block the first push over values that were never secrets.
      Now `<your-hex-api-key>` and `<your-api-key>`, whose angle brackets cannot match.
      **Final audit, 2026-08-28**: 90 files would be committed; `.mcp.json`, all `.env*`
      except the sample, `.claude/settings.local.json`, `_build`, `deps`, `cover`, `doc`,
      `priv/plts` and `tmp` all on the ignored side; and a credential-shape scan across
      every tracked file now returns **nothing at all**.

### Phase 1 — Core: mechanical moves

Namespace `DpCryptoManagement.Connectors.Exchanges.` → `DpExchange.`. Preserve moduledocs;
strip host-repo cross-references.

- [x] ~~**1.1** `DpExchange` — the namespace root (D1). Moduledoc for the family: what the
      facade guarantees, what it deliberately does not (§6.0), which venue packages exist,
      and the **EXPERIMENTAL** status (D15) — this is the HexDocs landing page.
      This is the first page a public consumer reads.~~ — **done 2026-08-27.**
      `lib/dp_exchange.ex`. Carries **D15 marker 3** (the moduledoc banner) alongside the
      guarantees, the non-guarantees, the family table with binance/kraken marked reserved,
      and "a library does not start itself".
      **Also implements D1's registry**, `venue/1`, which was not called out as a task but
      is the whole point of Core owning the namespace. `Module.safe_concat/2` +
      `Code.ensure_loaded?/1`, no registry to maintain.
      **It needed a guard the plan did not anticipate.** D1 describes resolution as
      `"coinbase"` → `DpExchange.Coinbase`, but `DpExchange.Core` is *also* a real module
      under this namespace, so a name-existence check alone resolves `venue("core")` to
      Core itself — fail-open, and exactly the "plausible value, wrong meaning" shape §0
      names. `venue/1` therefore also requires the module to export `capabilities/0`.
      **Tighten this at Phase 3** to a `DpExchange.Core.Venue` behaviour check once that
      module exists; `capabilities/0` is the strongest signal available before then.
      Ten tests, including one asserting the atom table does not grow across 200 hostile
      names — the concrete hazard `safe_concat` exists to prevent, and the one the host
      worked around with a hardcoded whitelist at `connection_pool.ex:893`.
- [x] ~~**1.2** `Core.Types.{Quote,Balance,Order,Fill,OrderBook,Trade}` + tests. **Add
      `:timestamp` to `Balance`** — the moment we asked, which is a balance's only
      meaningful freshness (§5.2). Every other type keeps the venue's own value as-is.~~ —
      **done 2026-08-27.** All six moved, namespaced, and their moduledocs carried across
      with the "part of the future dp_exchange_core package" line dropped — it is that
      package now.
      **`Balance` gained `:timestamp` and it is `@enforce_keys`, not optional.** Every
      other type already enforces its timestamp; leaving this one optional would have made
      the field advisory, and an unset freshness reads as "now" to whoever looks next. A
      consumer sizing a trade against a balance it believes is current is precisely the
      failure this family exists to refuse.
      Moduledocs now say *why* rather than only what: `Trade` vs `Fill` (public tape vs the
      caller's own match, easy to conflate), `OrderBook`'s best-price-first ordering as
      **contract rather than convenience**, and `Order`'s union of types being what the
      contract can express against what a venue's `capabilities/0` will actually accept.
      18 tests. They test the part that can refuse — `@enforce_keys` — plus that a stale
      timestamp survives untouched and that an `Order` with no venue-supplied times keeps
      `nil` rather than a substituted clock.
- [x] ~~**1.3** `Core.Timeframe`, `Core.CanonicalPair`, `Core.SymbolNormalizer`, `Core.Instrument` + tests~~ —
      **done 2026-08-27.** All four moved; 35 tests here, 55 in the suite, credo clean.
      **The moduledocs were the valuable part and they came across whole.** Five host
      cross-references were stripped without losing a sentence of reasoning:
      `CandleAggregation` and `Data.Storage.CandleStore` in `Timeframe`,
      `Data.Catalog.Refresh` in `Instrument`, and a design-doc path in each of
      `CanonicalPair` and `SymbolNormalizer`.
      One rewording is a real boundary change rather than a rename. `Timeframe` used to
      say alignment *"is enforced on the write path"* — true of the host, false of Core,
      which owns no storage. It now says Core owns the **test** and a consumer owns the
      enforcement. Claiming an enforcement we cannot perform would be its own substitution.
      Tests target what can refuse, and the 2026-08-06 fabricated-candle incident is now a
      test rather than only a paragraph: the real bar `2026-08-06T00:00:00Z` passes
      `aligned?/2` and the synthesised `2026-08-04T16:01:33.654710Z` fails it, which is the
      one property a fabricated bar cannot fake without also being right. `1w` and `1M`
      still return `true` — no rule must not read as invalid, or a venue serving a width we
      do not model has all of its real data rejected.
      `CanonicalPair`'s round-trip invariant is asserted across all three real mapping
      shapes, including that longest-quote-first ordering makes `BTCUSDC` parse as
      `BTC-USDC` rather than `BTC-USD` with a stray character.
- [x] ~~**1.4** `Core.Capabilities` (+ its raising validations) + tests~~ — **done
      2026-08-27.** Moved intact, **deliberately including the parts D12 forbids on a
      public facade**: `websocket_module`, `feed_module`, `stream_channels` and
      `pairs_per_socket` are still here, and activation is still boolean where the
      contract needs three states. Reshaping them is **2.7**, and doing it now would have
      meant rewriting the reasoning before it had been carried across. The moduledoc says
      so in an admonition, so nobody reads the ported shape as the intended one.
      Four host references stripped, none of them load-bearing to the reasoning. One
      rewrite mattered: the "registry holds eight adapters" paragraph named the host's
      specific venue set to justify why an empty `default_quotes` is legal. Generalised to
      the rule underneath — not every venue a consumer registers is one it trades on — so
      the argument survives without depending on that host's registry.
      13 tests against the validations, which are the part that can refuse: both quote
      invariants, both history invariants, and that `auto_collect` defaults to `false` so
      a forgotten flag collects nothing rather than sweeping a large catalogue.
- [x] ~~**1.5** `Core.DataProvider`, `Core.FeedBehaviour`, `Core.RateLimitBehaviour` (drop `use Boundary`)~~ —
      **done 2026-08-27.** 776 lines across the three; 24 callbacks on `DataProvider`
      (5 optional), 3 each on the other two, none optional. Namespace rewritten, all host
      references gone, `boundary` absent from `mix.exs` as §7.2 requires.
      **`use Boundary` was dropped, and the reasoning behind it was worth keeping rather
      than deleting with it.** The host needed `deps: [], top_level?: true` because a pure
      contract sat on the far side of a dependency arrow: the implementer had to reference
      it for the compile-time check, while its namespace said it belonged to the other
      side. Here that is structural — the contract ships in its own package and the
      implementer depends on the package — so there is no cycle to break and no boundary
      tool to convince. The moduledoc now records that the property is the same one, held
      by a different mechanism, rather than dropping the paragraph as host scaffolding.
      7 tests assert the contracts themselves: which callbacks exist, which may be
      omitted, and — reading the BEAM `imports` chunk — that `RateLimitBehaviour` still
      calls into nothing, which is the property `use Boundary` used to assert.
      `FeedBehaviour` keeps its `@type socket` for now; **2.8 removes it**, since the
      venue opens its own sockets and there is no host plumbing left to inject.
- [x] ~~**1.6** **No transport task (D20).** `WebSocketProviderBehaviour` and `FrameSender`
      do not move to Core. Confirm `mix.exs` names no `websockex` at any strength, and
      that `frame_sender.ex`'s incident text is queued for Phase 5 to carry into
      `dp_exchange_coinbase` — the module is discarded, the reason it existed is not.~~ —
      **verified 2026-08-27.** No `{:websockex, ...}` entry in `mix.exs`, nothing in
      `mix.lock`, and none of the 31 resolved deps is a transport library. `lib/` contains
      no transport module. **The one grep hit is prose** — the `mix.exs` comment recording
      *why* it is absent — which is the right kind of hit and the reason the check greps
      for the dependency form rather than the word.
      Incident queued to **5.6a**, and reading `frame_sender.ex` in full to do so turned up
      the half that matters most and that 5.6a did not yet carry: **why five seconds is not
      enough.** A book-channel subscribe makes the venue reply with a full snapshot —
      Gemini's opening `l2` frame measured **39,804 bytes**, and a 50-symbol batch is fifty
      of those. The socket process is single-threaded, so while it decodes that burst it
      cannot service the next `send_frame`, which then times out and exits. Observed
      2026-08-10, and self-reinforcing: the timeout kills the socket, and the next send
      fails `:noproc`. 5.6a now carries the cause and not only the symptom — a guard
      copied without it looks like defensive padding rather than a measured necessity.
- [x] ~~**1.7** `Core.Telemetry` + tests.~~ — **done 2026-08-27.** Moved; the event names
      already carried the `:dp_exchange` prefix, so nothing had to be renamed for the move
      itself. Moduledoc now states what telemetry *is* in D14's split — the metrics
      channel, high-frequency and lossy — so a reader does not reach for it to carry a
      condition a consumer must act on.
      **The `[:dp_exchange, :ws, …]` names are marked non-final in an admonition**, with
      the reason: `:ws` names a transport, and under D12 a venue streaming over MQTT or
      long-poll has no "ws" to report. **2.5** renames them to `:link`. Flagging it in the
      file rather than only in this plan, because the file is what the next reader opens
      and D4 makes the names permanent at first publish.
      6 tests, including one that reads the module's own docs and asserts every prefix in
      `event_prefixes/0` is documented — an emitted name nobody documented is a name no
      consumer can discover.
- [x] ~~**1.8** `Core.PollingFeed` + tests~~ — **done 2026-08-27.** 381 lines, the largest
      module in this phase, and the one carrying the most production incident. Six host
      references stripped without losing an argument: the `Data.Collection` siting
      rationale became the package-boundary one it is now, `StreamBootstrap` went from the
      boot-delay comment, and two incidents were generalised away from naming the host's
      venues while keeping what happened.
      16 tests, all against real GenServers, real timers and ordinary functions — nothing
      mocked, because there is nothing here that needs to be. They pin the behaviours that
      exist *because* something failed:
      **coverage is what came back, not what was asked for** — a bulk fetch answering for
      one of two symbols covers one, since marking the other would be the feed asserting a
      delivery that never happened;
      **a failed fetch is retried, never dropped** — this module cannot tell a delisting
      from a network blip, so it must not decide;
      **a raising fetch is contained** rather than taking the feed down;
      **`update_symbols/2` does not reschedule existing symbols**, which would stack a
      second timer per symbol and double the venue's request rate every time scope changed;
      and **the boot delay actually delays**, which is what stopped a crash loop that would
      have taken a supervision tree down at `max_restarts`.
      Log output is captured at the module: the "delivered NOTHING" warning is the feature
      under test, so a passing run stays silent without the warning being weakened.
- [x] ~~**1.9** **Mine the host's `docs/` (Appendix C).** Read `bugs/fixed/` in full before
      Phase 3.2's reference fake — it is 13 reports on exactly D7's pattern. Then the six
      load-bearing docs. Findings land in a moduledoc, a `usage-rules/` entry, or an OQ;
      anything fitting none of the three is interesting, not useful.~~ — **done
      2026-08-27.** 825 lines across the 13 reports. Four findings, each with a home.

      **Finding 1 — the fake-drift taxonomy, and only half of it is dangerous.** Eleven of
      the thirteen are `Client.Local`, influx-elixir's in-process fake, diverging from the
      real HTTP client. They fall in two groups that need different treatment:
      *Loud* — the fake **rejects what the real thing accepts**: `COUNT(*)`, `DATE_BIN`,
      explicit column lists, `SELECT DISTINCT`, `first`/`last`. Six of the eleven. These
      cost time and cost nothing else; the test fails and someone fixes the fake.
      *Silent* — the fake **answers plausibly and wrongly**: an aggregate with a time
      `WHERE` returns `{:ok, []}` rather than erroring; an `IN (...)` clause is dropped
      unparsed and the query returns the wrong rows; `write/3` **discards the caller's
      timestamp** and substitutes `System.os_time`, so points written 900 seconds apart
      land microseconds apart. Three of the eleven, and every one is §0's named failure
      mode — a nearby substitute where there should be an error.
      **The split is the design input for 3.2**, recorded there: a fake may be less capable
      than the real venue, but it must never be *differently* capable. Where it cannot
      answer, it errors. It never returns empty for unsupported, and it never rewrites a
      value the caller supplied. The timestamp case is the sharpest, and it is the same
      decision `Balance` just made at 1.2 from the other direction.

      **Finding 2 — a number that settles "measured, not assumed".** From
      `architecture/symbol-lifecycle.md`: the state-transition table is *"derived from a
      month of the fleet's own paper-trail history rather than drafted. The drafted version
      was wrong in 7 of 21 pairs."* A third of a carefully-drafted table, written by people
      who knew the system, was wrong. That is the strongest available argument for D13 and
      for labelling every capability with whether it was measured or read from
      documentation — carried into the 3.1 guidance rather than left as a principle.

      **Finding 3 — an incident that constrains the notices channel (D14, 2.5).** The same
      document: three cached copies of a symbol's status were kept in step by fire-and-
      forget `GenServer.cast`, and **a cast to a dead or restarting process returns `:ok`
      and is dropped**. Two symbols suspended at 03:14 and 03:27 UTC opened fresh positions
      at 21:46. §6.0 already calls notices lossy-safe; this is what lossy costs when a
      consumer treats a notice as the only path for a state change. **2.5 must say so
      outwardly** — a notice is a prompt to re-read, never the record itself.

      **Finding 4 — `design/ideas/exchange-mcps.md` does not conflict; it corroborates.**
      Appendix C flagged it to check before Phase 2 settles the facade. It proposes venue
      MCP servers as *"a transport plugged into the same `dp_exchange_core` behaviour"* and
      concludes *"if `dp_exchange_core` exists, adding `dp_gemini_mcp` is trivial; without
      it, MCP and REST diverge."* That is D12 and D2 arrived at independently. No plan
      change. One caution for the idea doc rather than here: a venue package whose transport
      is a third party's MCP server has availability and supply-chain properties REST does
      not, and D12 correctly makes that the venue package's problem.
- [x] ~~**1.10** `mix quality` clean~~ — **done 2026-08-27, exit 0.** All four stages:
      `format --check-formatted`, `credo --strict` (86 mods/funs, no issues), `dialyzer`
      (0 errors, and fast now the PLT was warmed at 0.14), `sobelow --config` (clean, with
      the Phoenix-only false positive suppressed at 0.14).
      **Coverage 95.24%**, threshold 90. 96 tests and 2 doctests, 0 failures. Every module
      is at 100% except `PollingFeed` at 92% — a GenServer with timer-driven branches — and
      `CanonicalPair` at 95.24%.
      **`mix test --cover` failed at first, and the test was wrong rather than the code.**
      One of 1.5's tests asserted `RateLimitBehaviour` depends on nothing by reading the
      BEAM `imports` chunk. Cover instrumentation rewrites imports, so the test passed
      under `mix test` and failed under `mix test --cover` — deterministically, five runs
      out of five — while nothing was actually wrong. **This is the check CI runs**, so a
      green `mix quality` would have hidden it until the first push.
      Rewritten to assert the property through the module's **export list** — a pure
      contract defines no functions of its own — which is stable across both compilation
      modes. `module_info`, `behaviour_info` and `__info__` are compiler-generated and
      excluded by name. The lesson is 1.9's finding 1 pointed the other way: a test that
      breaks where nothing is wrong is the loud failure, and it was still nearly missed
      because the gate it broke was not the gate being watched. **Run both `mix quality`
      and `mix test --cover`; neither implies the other.**
      **Phase 1 is complete.** Core compiles, tests and passes quality standing alone, with
      no reference to the host application anywhere in `lib/`; 2.10's purity check should
      therefore be a confirmation rather than a repair.

### Phase 2 — Core: the reworks

- [x] ~~**2.1** `Core.Config` — the process-scoped resolver (§7.8): process dictionary,
      then the `$callers` walk, then `Application.get_env/3`. Every configurable seam in
      the family goes through it. Model on `rate_limiting/config_reader.ex`, which is the
      host's working implementation, and carry the snapshot-into-the-message rule for
      anything crossing a `GenServer` boundary.~~ — **done 2026-08-27.** All three lookup
      steps plus `snapshot/1` / `resolve_snapshot/3` for the boundary crossing. 16 tests,
      the file `async: true` because that is the property under test rather than a
      convenience.
      **Two deliberate departures from the host's version, both to fix a limit rather than
      a bug.** The host's reader resolves one fixed key; this one is **per seam**, because
      the family has several (fake selection, `rate_limit_module`, anything later) and a
      single shared key would make every seam collide. And `find_override/1` returns
      `{:ok, value} | :none` rather than `value | nil`, because **an override whose value
      is `nil` is an override** — collapsing the two would make `nil` unconfigurable, and
      `nil` is a legitimate value for a seam meaning "no module injected".
      `resolve_snapshot/3` deliberately does **not** consult the server's own process
      dictionary. A long-lived server's dictionary is not scoped to any one caller, so
      honouring it would leak one caller's configuration into another's request — tested,
      along with the fact that a plain `Agent.get` cannot see the caller's override at all,
      which is the trap the snapshot exists for.
- [x] ~~**2.2** `Core.DefaultRateLimiter` — new in-process token bucket (D-A). **Written
      from the contract, not ported from `HostRateLimiter`** (D-E). Must: take `weight` as
      one atomic reservation rather than a loop (D-E.1); honour `weight` in `check/3`
      (D-E.2); fail closed on an unknown answer across `acquire` and `check`
      (D-E.3); validate `weight` at the boundary rather than trusting `pos_integer()`
      (D-E.4). Property test it against the four defects directly — each one is a test
      case that the host module would fail.~~ — **done 2026-08-27.** 20 tests, and each of
      the four defects is a named test that the host module fails:
      **D-E.1** — a weight-N acquire is one addition to a virtual-scheduling clock (GCRA),
      not N calls. Tested three ways: weight-10 spends a 10-burst; ten concurrent weight-2
      acquires against 20 burst all succeed with none observing a partial reservation; and
      **a reservation that cannot be honoured within the timeout is not committed**, so a
      failed acquire leaks no capacity — the half of the loop defect that had nothing to
      release it.
      **D-E.2** — `check(:venue, 10)` is rate-limited where `check(:venue, 1)` is `:ok`.
      **D-E.3** — needed a **contract change, not just an implementation**, exactly as D-E
      predicted. `check/3`'s return was `:ok | {:rate_limited, ms}`, which gave an
      implementation no way to say *I could not tell*, so the host's chose `:ok` — fail
      open — while `acquire` beside it failed closed on the same condition. The callback
      now admits `{:error, term()}` and its `@doc` states that a caller must treat it as
      "do not proceed". Both entry points return `{:error, :not_started}` on an
      unreachable limiter, and a test asserts they agree.
      **D-E.4** — weight is validated at the boundary, since `pos_integer()` in a typespec
      is a promise rather than a check. A test **pins the runtime behaviour itself** —
      `Enum.to_list(1..0//-1) == [1, 0]` — so if a future Elixir changes it, the guard's
      moduledoc stops describing a live hazard and starts describing history.
      **2.9's check is asserted rather than eyeballed**: a test greps the module's own
      source for all eight venue names and fails if any appears. Limits are a map the
      consumer supplies at `start_link/1`; there is no venue table and there must never be.
      One design decision worth recording: **`acquire/3` sleeps in the caller, not the
      server**, so a caller waiting out a reservation cannot stall the limiter for anyone
      else. Tested by checking a second provider still answers while the first waits.
      And **not-started is an error, never "no limit"** — failing open would meter nothing
      while reporting success, which is the Webull incident's exact shape.
- [x] ~~**2.3** `Core.HttpClient` — swap `RateLimiter` for injected `rate_limit_module` (§5.3)~~ —
      **done 2026-08-27.** Resolved through `Core.Config` at call time, never
      `compile_env`. The account/user branching collapsed: per **D5** the ceiling is
      **per venue**, so `account_id`, `user_id` and `operation` are carried through in
      `opts` for an implementation that wants them, while the limit itself is the venue's.
      Scoping per key would let N keys multiply one venue's published ceiling by N and get
      every one of them throttled.
      **Both directions now fail closed**, with `normalise_acquire/1` and
      `normalise_check/1` side by side so the asymmetry cannot come back unnoticed — the
      implementation this replaced propagated the error from `acquire` and mapped the
      identical condition to `:ok` in `check`. Rate-limit waits are converted to seconds
      **rounded up**: rounding a 1500ms wait down to one second retries while still limited.
- [x] ~~**2.4** `Core.HttpClient` — strip Coinbase/Gemini branches, add generic hooks (§5.5)~~ —
      **done 2026-08-27.** 132 lines removed: the Coinbase CDP JWT builder, its public
      `coinbase_cdp_jwt/2`, the base64 key decoder, and both venue rate-limit header
      parsers. In their place two generic hooks.
      `build_auth_headers/5` keeps `:hmac_sha256` / `:basic` / `:bearer` and otherwise
      **takes a function**: a venue with its own scheme passes a builder rather than adding
      a branch. `parse_rate_limit_headers/2` became **`/1`** — losing the provider argument
      is the point, since the argument existed only to dispatch on venue — and reads only
      the conventional `x-ratelimit-*` trio. `nil` is documented as *this response did not
      say*, never *there is no limit*.
      A test asserts no venue name appears **in dispatch position** (`"coinbase" ->`,
      `:gemini ->`) rather than merely absent, so the moduledoc can keep explaining why the
      table was removed without the check tripping over its own explanation.
      **Two real defects surfaced by writing the tests, both invisible until the pipeline
      was actually exercised:**
      (a) **every `Retry-After` a venue sent was being discarded.** `Req` returns headers
      as `%{"name" => ["value"]}` and the parser handled only `[{name, value}]` pairs with
      binary values, so `Integer.parse/1` raised inside the rescue and the 429 path always
      fell back to its five-second floor. Both shapes are normalised now. The host has this
      bug too — it is in the code as moved.
      (b) **a venue's 429 does not carry `retry_after` to the caller.** Our *own* limiter's
      rate-limit surfaces the seconds in the message; a venue's surfaces as a bare
      `{:error, "Rate limited"}` with the interval only reaching a log line. Asymmetric, and
      the caller is the one who has to decide when to try again. **Left for 2.7**, which is
      where return shapes are settled and after which D2 forbids moving them.
      Also added `:plug` / `:adapter` pass-through to `Req`, which is how the request
      pipeline is tested without a network. Not a test-only escape hatch: a consumer or
      venue with its own transport requirements uses the same seam. `{:plug, only: :test}`,
      so it never ships. HttpClient coverage went 46.7% → 88.7%, total 91.39%.
- [x] ~~**2.5** `Core.EventSink` — **inverted, not dropped** (§5.4, D6). The six
      `defdelegate`s into the host's `Events.*` do not extract. In their place build
      **`Core.Notice` + `subscribe_notices/1`** (D14): link up/down, credentials rejected,
      sustained pressure, coverage change, catalog change (pair added/removed/delisted),
      degradation — host subscribes, package holds no host function, never carries
      credentials, lossy-safe. Remove the sink type from `FeedBehaviour`.
      **Say outwardly that a notice is a prompt to re-read, never the record** (finding 3
      at 1.9). The host kept three cached copies of a symbol's status in step with
      fire-and-forget `GenServer.cast`, and a cast to a dead or restarting process returns
      `:ok` and is dropped: two symbols suspended at 03:14 and 03:27 UTC opened fresh
      positions at 21:46. "Lossy-safe" has to mean the consumer's correctness does not
      depend on delivery, and `usage-rules/` must state it — a consumer that treats a
      catalog-change notice as the only signal a pair was delisted has built that same bug.
      Apply D14's
      telemetry split and the `[:dp_exchange, :ws, …]` → `[:dp_exchange, :link, …]`
      renames, and the bounded-mailbox back-pressure policy (§6.0); all of it is facade
      surface and D2 forbids moving it later.~~ — **done 2026-08-27.** `Core.Notice` with
      all thirteen kinds across the six groups, `new/3`, and 22 tests.
      **Three things are enforced rather than documented**, because a convention an
      implementer must remember is one an implementer will forget:
      (a) **the kind vocabulary is closed and an unknown kind raises.** A typo would
      otherwise become a notice no consumer matches on, which nobody ever sees;
      (b) **credential-shaped keys in `details` are refused, not redacted.** Redaction
      implies someone chose what to hide and got it right. Refusing means the value never
      reaches a struct a consumer might log. A test asserts it across six key names, both
      atom and string, case-insensitively — and asserts that naming *which* credential
      failed is still allowed, since that is the useful half;
      (c) **a test asserts no kind names a transport.** `:link_down` is the fact;
      WebSocket, MQTT or poll loop is not a consumer's concern.
      **The dropped-cast incident from 1.9 is written into the moduledoc**, with the rule
      it implies stated outright: *a notice is a prompt to re-read, never the record*.
      Treat one as a nudge and a dropped message degrades to latency; treat it as the
      record and a dropped message is silent, wrong state.
      **`FeedBehaviour`'s two injected types are gone** — `sink` and `socket` — and the
      comment replacing them says why each existed and why neither can now: the venue owns
      its transport (D12, D20), so there is no host plumbing left to pass in, and a sink
      would hand the package a decision that is the consumer's (D6). **That completes 2.8
      as well.** The half that always mattered survives: the venue keeps the policy.
      **`route`'s `:socket` became `:stream`.** It was the last place a transport name
      reached a consumer-visible value. What a consumer legitimately needs is whether data
      is pushed or fetched, since only the second scales with catalogue size.
      **Telemetry renamed `:ws` → `:link`** with `:connect`/`:disconnect`/`:message`
      becoming `:up`/`:down`/`:event`, and `endpoint` metadata dropped — a URL is transport
      and a venue with none would have to invent one. A test now asserts no event category
      names a transport, so the rename cannot quietly regress before publish.
- [x] ~~**2.6** **D12 — the facade.** Define `DpExchange.Core.Venue` per §6.0: lifecycle,
      declaration, market data, account/trading, streaming, health.
      This is the load-bearing artifact of the whole plan — everything else is judged
      against it, and per D2 it cannot move after venue #1 ships.~~ — **done 2026-08-27.**
      26 callbacks across the five groups, **two optional** (`list_instruments/1`,
      `quantization/1`) and both for the same reason: requiring them is ceremony, not that
      they are hard. 20 tests.
      **The classification is executable, not prose.** `core_endpoints/0` and
      `peripheral_endpoints/0` are functions, and a test asserts **every callback is in
      exactly one of them** — an unclassified endpoint is one nobody decided about, which
      is how something load-bearing quietly ends up outside the graduation bar. Another
      asserts each peripheral entry names *which of the two tests it fails*, since that is
      what a future classifier reasons from. `required_callbacks/0` is derived from
      `behaviour_info/1` rather than hand-listed, so the conformance suite cannot fall out
      of step with the behaviour.
      **A test asserts no callback names a transport**, matched per underscore-separated
      segment. That detail is the finding: a substring check reported `asset_classes` as
      naming `sse` and `test_connection` as exposing a connection — **two false positives
      in the check meant to protect the boundary**, and a check that cries wolf gets muted
      rather than fixed. Segment matching is exact and still catches a real `socket` or
      `mqtt`.
      `not_supported/0` returns the **atom**, with the reason in its doc: the source used
      the string in some places and the atom in others, once both in a single module, so a
      caller matching the atom silently missed the string.
      **Two flaky tests found and fixed by running the suite ten times**, both mine, both
      the kind that would have failed in CI rather than locally:
      (a) `function_exported?/3` answers `false` for a module that is merely **not loaded
      yet**, so the assertion meant "does not exist" and tested "not loaded". Failed one
      run in six. Fixed with `Code.ensure_loaded!/1`.
      (b) a `PollingFeed` retry test asserted "nothing is covered" after `Process.sleep(30)`
      — racing the very retry it was waiting for. Rewritten to synchronise on the fetch
      itself: the failing fetch messages the test, which then checks coverage at the instant
      the failure happened. **Neither was fixed by widening a sleep**, which converts a
      visible flake into a slow one.

- [x] ~~**2.7** **The activation map (§6.0).** Three-state per endpoint — `:proven` /
      `:experimental` / `:unsupported` (D15) — with `:experimental` the default for
      anything new. Build the capability→function table assertion
      12 drives off. Close the Kind-1 gaps (`has_market_overview`,
      `has_instrument_catalog`, `has_quantization`, `has_transfers`, `supports_trading`,
      `has_private_accounts`, `has_authenticated_stream`) as a function→state map, and add the
      Kind-2 constraints that today have no declaration at all — `supported_order_types`,
      `supported_time_in_force`, `supported_instrument_types`, `supports_margin` /
      `max_leverage`, `supports_fractional_shares`. Re-file `supports_short_selling` as Kind 2.
      **Delete `has_websocket` outright** — do not rename it. Both endpoints exist on
      every venue with no flag (§6.0), so there is nothing to declare. Replace
      `stream_channels` / `authenticated_channels` with `streamable` /
      `authenticated_streamable` in normalised data kinds, and drop `websocket_module`,
      `feed_module`, `stream_channels`, `pairs_per_socket` from the public declaration:
      they exist only because the host currently starts and shards the venue's sockets.
      Reshape `requires_credentials_for_public_data` into the three-way answer and the
      rate-limit ceiling into the pair it actually is (§6.0, D5).
      Add `has_staking` and `market_status/1` (§6.0) here — both change the
      facade and D2 forbids moving it later. Normalise `{:error, :not_supported}` to the
      **atom** everywhere: `webull/provider.ex:733` and `coingecko/provider.ex` return the
      string, which a caller matching the atom silently misses.~~ — **done 2026-08-27.**
      `Capabilities` rewritten rather than amended; 29 tests.
      **Kind 1 is one `endpoints` map** of `{function, arity}` → three-state, not a field
      per endpoint. Arity is part of the key on purpose: a bare name cannot distinguish two
      arities, and a declaration that cannot be precise invites a wrong one. Undeclared
      means `:experimental` — not `:unsupported`, which would claim a refusal the venue
      never made, and not `:proven`, which is earned rather than assumed.
      **`has_websocket` deleted outright, not renamed**, along with `websocket_module`,
      `feed_module`, `stream_channels`, `pairs_per_socket` and `authenticated_channels`. A
      test asserts each is absent *as a struct field*, so a future addition fails rather
      than being noticed in review. `stream_channels` became `streamable` in normalised
      data kinds — a test refuses `:level2`, because that is one venue's word while
      `:order_book` is everyone's.
      **`auto_collect`, `default_quotes` and `overview_suits_collection` are gone** — a
      test asserts their absence too. Replaced by `catalog_size`, a **class rather than a
      count**: the count changes daily and the decision it informs does not, and what a
      consumer needs to know is that re-pulling one venue's catalogue on a timer is fine
      and another's is not.
      **`requires_credentials_for_public_data` became `credential_benefit`**, three-way,
      and `:higher_ceiling` **cannot be declared without `authenticated_ceiling`** — the
      whole point of that value is that there are two ceilings and a caller needs the
      second one.
      **Kind 2 gaps closed**: `supported_order_types`, `supported_time_in_force`,
      `supported_instrument_types`, `supports_fractional_shares`, and `supports_margin` /
      `max_leverage` — where the two halves must agree in both directions, because a
      leverage a caller cannot use reads as capability the venue lacks, and margin without
      a ceiling leaves a caller guessing how large a position the venue will accept.
      **Added `measured_at` / `measured_against`**, from 1.9's finding: a drafted state
      table was wrong in 7 of 21 rows, so a declaration should be able to say whether it
      was measured and against what. Optional, and `nil` says *not measured* rather than
      pretending.
      **One design bug of my own, caught by the tests.** Validation asked `active?/2`
      whether the venue served history — and since undeclared defaults to `:experimental`,
      that read **silence as a claim**, demanding candle widths from every venue including
      ones serving none. Now keyed on an explicit declaration: silence is not a claim, and
      checking a declaration against real behaviour is the conformance suite's job.
- [x] ~~**2.8** **D12 — remove `FeedBehaviour`'s `@type socket`.** The venue opens its own
      sockets; there is no host plumbing left to inject (D6). Confirm nothing in Core
      still assumes a host-supplied connection.~~ — **done 2026-08-27, with 2.5.** Both
      injected types removed together, since the argument for dropping one is the argument
      for dropping the other. Confirmed nothing in `lib/` assumes a supplied connection:
      `PollingFeed` keeps its own `:sink` option, which is **not** the same thing — that is
      a venue package wiring its own feed to its own subscribers, internal to the package,
      not a consumer injecting a decision across the facade.
- [x] ~~**2.9** Verify `Core.DefaultRateLimiter` (2.2) carries no venue table of its own —
      the D12 defect must not be reproduced inside Core. Cross-check against
      `host_rate_limiter.ex` and `provider_limiter.ex`'s `@provider_configs`, the data
      being replaced.~~ — **done 2026-08-27, and widened.** The check was specified for one
      module and applies to all of them, so it is now a test over **every file in `lib/`**:
      no dispatch on a venue name, no map keyed by one, for all eight venues.
      **It strips docs and comments before checking**, which is the part worth recording.
      Several moduledocs quote the exact pattern being removed — `case provider do
      "webull" ->` — because explaining why something is absent is the most valuable thing
      in those files. A check that cannot tell code from the prose describing it forces a
      choice between deleting the explanation and muting the check, and both are worse than
      the check being precise.

- [x] ~~**2.10** Purity check: no `DpCryptoManagement.*` / `Phoenix.*` / `Ash.*` / `Cloak.*` anywhere in `lib/`~~ —
      **done 2026-08-27, in two forms.** The specified source check passes, and a second
      test asserts the stronger property: **what the compiled BEAM actually links
      against.** Source greps miss a transitive reference nobody noticed; the `imports`
      chunk does not.
      Result: stdlib, `Logger`, `Jason`, `Req`, `crypto`, and Core's own modules. Nothing
      else. **O2 is satisfied** — this package compiles, tests and passes quality standing
      completely alone.
      Two more properties folded into the same file because they can only regress silently:
      **no transport library at any strength** (D20 — checked in `mix.exs` *and* in
      resolved `deps/`), and **no `Application` callback module**, so a consumer that has
      not asked for a venue never finds a socket open.

- [x] ~~**2.11** `mix quality` clean, coverage at threshold~~ — **done 2026-08-27.**
      `mix test`, `mix test --cover` and `mix quality` all exit 0; **six consecutive clean
      runs**, which after this phase's three flaky tests is the check that actually means
      something. 226 tests + 14 doctests, coverage **91.54%** against a threshold of 90.
      Thirteen of twenty modules at 100%; the floor is `DefaultRateLimiter` at 85.1%.
      **Phase 2 is complete, and the two host dependencies are severed.**


### Phase 3 — Core: the contract

- [x] ~~**3.1** `test/support/adapter_contract.ex` — `DpExchange.Core.AdapterContract`, all 13 assertions (§6.1)~~ —
      **done 2026-08-27.** A `use`-able ExUnit case generating **28 tests** per venue,
      built as one quoted block per assertion group rather than one long one — credo
      objected, and it was right: a 400-line `quote` is a block nobody reads before adding
      the 401st line.
      The load-bearing group is **12, both directions**: an `:unsupported` endpoint must
      return the atom and must not raise; an active one must not answer `:not_supported`.
      **Maturity is asserted for presence, not truth** — every core endpoint must carry an
      explicit value, because absence is the failure this prevents, while whether a
      `:proven` claim is *true* is not machine-checkable and the suite does not pretend
      otherwise.
      Assertion 4 generates pairs **over the venue's own declared quotes** rather than only
      the samples: the samples are the pairs someone thought of, and the bug lives in the
      ones they did not.
      Argument shapes for the generic endpoint caller are a **data table** rather than a
      clause per arity — ten clauses is ten places to be inconsistent.

- [x] ~~**3.2** A reference fake in `test/support/` proving the suite passes something.~~ —
      **done 2026-08-27.** `Core.ReferenceVenue`, a complete facade implementation, passes
      all 28 assertions.
      **The plan's hostile mapping was the wrong hostile mapping, and the tests found it.**
      §6.1.4 specified `sep: ""` with overlapping `USD`/`USDT`/`USDC`. Those three
      **round-trip correctly in either order** — none is a suffix of another, so
      `BTCUSDC` never matches `USD` first. A fixture built on them looks like it tests the
      longest-first rule while testing nothing.
      The real collision is a quote that **contains** a shorter quote: `BUSD` ends with
      `USD`, so `BTCBUSD` splits as `BTCB-USD` — a pair that does not exist, carrying
      values that all look plausible. The reference mapping is now
      `~w(BUSD USDC USDT USD EUR BTC ETH)` and a companion test proves the misordered
      version fails on exactly that input.
      **The fake refuses two endpoints for real** (`get_transfers/2`, `quantization/1`,
      both returning the atom), because a fake where everything works proves only half of
      assertion 12. It also distinguishes `{:refused, _}` from `{:error, _}` — a symbol the
      venue does not carry is permanent, an unsupported timeframe is a caller mistake, and
      collapsing them makes a delisting look like a retryable blip forever.
      A separate **"does the suite have teeth"** file builds four deliberately-broken
      venues — one over-declaring, one under-declaring, one returning the string
      `"not_supported"`, one with a misordered quote list — and asserts each is detectable.
      A conformance suite that passes everything proves nothing.

      **Two rules for the fake, from the 13 host bug reports read at 1.9** — eleven of
      which are exactly this module's failure mode:
      (a) **it may be less capable than a real venue, never differently capable.** Where it
      cannot answer, it returns an error. It must never return an empty success for
      something unsupported — the host's fake answered `{:ok, []}` to an aggregate with a
      time `WHERE`, and silently dropped `IN (...)` clauses, so callers got plausible wrong
      answers rather than a failure;
      (b) **it never rewrites a value the caller supplied.** The host's fake discarded the
      caller's timestamp and substituted `System.os_time`, landing points 900 seconds apart
      microseconds apart. That is the same decision `Balance` made at 1.2, from the other
      side.
      The six *loud* divergences in that corpus — the fake rejecting what the real venue
      accepts — are cheap and self-announcing. Budget the fake's care for the silent three.
- [x] ~~**3.3** `usage-rules.md` + `usage-rules/{adapter,symbols,feeds,testing}.md` (§6.2)~~ —
      **done 2026-08-27.** 492 lines across five files, written as *what a consumer or
      implementer must not get wrong* with the incident behind each rule — the API itself
      is in the moduledocs and HexDocs renders those already.
      `symbols.md` corrects the folklore version of the longest-first rule: the collision
      is a quote that **contains** a shorter one (`BUSD` ends with `USD`), and
      `USD`/`USDT`/`USDC` round-trip in either order — so the usual example demonstrates
      nothing. `testing.md` carries the isolation seam in full, including the
      snapshot-across-a-process-boundary step and the three determinism traps this phase
      actually hit.
- [x] ~~**3.4** `{:usage_rules, "~> 1.2", only: :dev}` + `mix usage_rules.sync` → `AGENTS.md`~~ —
      **done 2026-08-27.** 135 lines generated. The task takes its configuration from
      `mix.exs` and rejects file arguments, so `mix usage_rules.sync AGENTS.md` fails —
      `mix usage_rules.sync --yes` is the invocation.
- [x] ~~**3.5** `docs/guides/building-an-exchange-package.md` — the per-repo checklist~~ —
      **done 2026-08-27.** Eight sections, each item carrying what skipping it has cost.
      Sequenced so the two session restarts and the documentation-first rule come *before*
      any code: both are cheap to honour in order and expensive to discover late.
- [x] ~~**3.6** Add `"test/support"` to `mix.exs` `files:` so the suite ships~~ — **done
      2026-08-27, and it was not shipping.** Inspecting `mix hex.build` rather than
      trusting the declaration found three defects at once.
      **`files:` was at the project level, where Hex ignores it** — it is a `package/0`
      option, and nothing warns. The tarball therefore shipped Hex's defaults instead:
      **`priv/plts/dialyzer.plt`, 4.4 MB of build artifact**, and shipped neither
      `test/support` nor `usage-rules.md`. So **D8 was broken outright** — a venue package
      could not have run the conformance suite it is required to pass — and §6.2's
      "highest-leverage artifact in the project" was not in the package at all.
      Moved into `package/0` with the reason in a comment. The tarball now carries `lib`,
      `test/support`, the usage rules, `AGENTS.md` and the venue guide, and carries no
      `priv`, no `config/`, no `.env`, no `.mcp.json`.
      **influx-elixir has the identical bug**, measured directly: its tarballs ship
      `priv/plts/dialyzer.plt` and do not ship its `usage-rules/` directory, while its
      `mix.exs` carries a comment saying *"Include usage-rules files in hex package"*.
      Worth telling the architect — that is a live package with real download volume.
      Fixing it is out of scope (§1).
      Six tests now assert the tarball's contents: what must ship, what must not, and that
      the project level does not also declare a `files:` to mislead the next reader.
- [x] ~~**3.7** `mix docs` clean; `mix hex.build` inspected for contents~~ — **done
      2026-08-27.** `mix docs` had three warnings, all README links that resolve in the
      repo and 404 on HexDocs, which renders the README standalone — now absolute URLs so
      they work in both. Also flipped `main:` from `"readme"` to **`DpExchange`**, the
      1.1 item left pending: the namespace root is what a public reader lands on, and D1
      is explicit that "this is a bare namespace, look elsewhere" is a poor first page.
      All gates exit 0 across six consecutive runs; 274 tests + 14 doctests, coverage
      **91.83%**. **Phase 3 complete** — Core ships a contract, a suite that proves it, a
      reference implementation that passes it, five guides, and a tarball that actually
      contains all of it.

### Phase 4 — Publish Core `0.1.x`

- [x] ~~**4.1** CI green on `main`~~ — **done 2026-08-28.** Green on both runs, both
      jobs, `quality` and `publish`.
      **I branched first and should not have.** The convention is to branch off a
      default branch, and I wanted CI proven before an irreversible publish. But this
      was the *first commit in an empty repository*: there was no `main` to protect,
      nothing to review against, and 4.1 says *CI green on `main`* in as many words.
      Worse, pushing a branch to an empty repo made **that branch the default**, which
      then had to be undone. Caution that costs a step and creates a defect is not
      caution.
      Superseded by the record below. Original text:
      ~~CI cannot run
      until something is pushed, and **the repository has zero commits**: 22 paths are
      staged-in-waiting and nothing has ever been committed.
      Two things must happen first, both the architect's:
      **(a) permission to commit.** ABSOLUTE RULE 6 is *never commit or push without
      confirmation*, and rule 12 is *never use git*. I have used git read-only for the
      D17 audits, which 0.15 explicitly requires, and have committed nothing. The two
      rules cannot both be literal, and which reading applies is not mine to choose.
      **(b) secret scanning with push protection**, per 0.15 — the API refuses this
      token with 403, so it is one click in Settings → Code security. Not strictly a
      blocker, but it belongs before the first push rather than after it.
      **4.3's first half is done**: the repository went public 2026-08-28, with zero
      commits, so D17's "flipping public exposes every commit ever made" had nothing to
      expose. **`HEX_API_KEY` is an organization key that already exists and already
      works** — influx-elixir publishes with it today (D4) — so there is nothing to
      obtain, only the existing org secret to be visible to this repo. Whether it is
      cannot be checked from here: reading Actions secrets is also 403.
      Everything checkable without a remote has been checked: 274 tests, `mix quality`
      clean, coverage 91.83%, the tarball audited by extraction (4.2).~~
- [x] ~~**4.2** `mix hex.build` — inspect the tarball contents. This is the **last
      reversible moment**: the next step is a permanent public artifact under a permanently
      claimed package name (D4). Verify no `DpCryptoManagement.*`, correct `files:` list,
      LICENSE and usage-rules present, no secrets (D17), and the **EXPERIMENTAL** markers
      in place (D15):
      README banner, `description:` prefix, `DpExchange` moduledoc, CHANGELOG, and every
      endpoint in `capabilities/0` declaring `:proven` or `:experimental`.~~ — **done
      2026-08-27, tarball extracted and read rather than listed.** 36 files.
      **All five D15 markers verified in the built artifact**, not in the repo: README
      banner as the first thing above everything, `description:` prefixed, the
      `DpExchange` moduledoc admonition, the CHANGELOG status section, and per-endpoint
      maturity in `capabilities/0`.
      `files:` correct after 3.6's fix. No `priv`, no `config/`, no `.env`, no
      `.mcp.json`. No credential-shaped string anywhere in the contents.
      **One host reference in the tarball, and it is the right one**: the shipped
      conformance suite's purity assertion names `"DpCryptoManagement."` because that is
      the string it forbids. A check for a string necessarily contains it. Annotated in
      place so the next tarball audit does not chase it.
      This was the last reversible moment and it is now spent correctly: everything after
      4.3 is permanent.
- [x] ~~**4.3** **ARCHITECT GATE (D4).** Architect makes
      `DistortionPoint/dp-exchange-core` **public** and adds the org `HEX_API_KEY` secret. Manual,
      human, once. Must precede the publish so `source_url` and `package.links` resolve.
      Do not attempt from the pipeline.
      **Check the history for secrets first (D17)** — flipping the repo public exposes
      every commit ever made, not just the current tree.~~ — **done 2026-08-28.** The
      repository went public **with zero commits**, so D17's history exposure had
      nothing to expose — the best possible ordering, arrived at by accident rather
      than design. `HEX_API_KEY` is the existing organisation key (D4); nothing needed
      obtaining, and the publish proved it reaches this repo.
- [x] ~~**4.4** First publish of `dp_exchange_core` to **public hexpm** — which lands as
      `0.1.1`, not `0.1.0`: CI increments the seed in `mix.exs` before publishing (§7.3)~~ —
      **done 2026-08-28. `dp_exchange_core 0.1.1` is live on public hexpm**, exactly as
      §7.3 predicted: the seed said `0.1.0`, CI incremented, the release is `0.1.1`. Tag
      `v0.1.1`, GitHub release generated, `Release v0.1.1 [skip ci]` pushed back by the
      bot. The offset is real and behaved as documented.
      **`0.1.2` followed the same day** with 4.5's fix.
- [x] ~~**4.5** Verify a scratch project can `mix deps.get` it and `use DpExchange.Core.AdapterContract`~~ —
      **done 2026-08-28, and it found that D8 was still broken.** This is the task's
      whole reason for existing and it earned itself on the first run.
      `use DpExchange.Core.AdapterContract` failed with **"module is not loaded and
      could not be found"**. The suite shipped inside the tarball — 3.6 fixed that — but
      was **never compiled into the consumer**: `elixirc_paths(:test)` governs this
      package's own build, and a dependency is not compiled in the `:test` environment.
      The file arrived on disk and never reached the code path. **Shipping a file is not
      shipping a module**, and 3.6's check could not tell the difference because it
      asserted the tarball's contents rather than a consumer's outcome.
      Moved to `lib/dp_exchange/core/adapter_contract.ex`, where a public testing API
      belongs — `Ecto.Adapters.SQL.Sandbox` and `Phoenix.ConnTest` live there for the
      same reason. `use ExUnit.Case` appears only inside the generated block, so nothing
      needs ExUnit at compile time. `test/support` stopped shipping; what is left in it
      is Core's own reference venue, of no use to a consumer.
      **Assertion 7 was rewritten in the move, and is now better than specified.** §6.1.7
      asked for a source scan against a list of forbidden namespaces — which meant a
      package shipping this suite failed its own check, since the literals *are* the
      check. It now reads the loaded module's beam path: a module from `deps/<name>/`
      came from dependency `<name>`, anything else is OTP, the standard library or the
      package itself. Simpler, and strictly stronger — **it catches a dependency nobody
      declared**, which a name list never could, because a list only forbids what someone
      thought to write down.
      **Verified twice.** Against a path dep before publishing: 29 conformance tests
      green on a conformant venue, 14 failures on a sloppy one — so the suite has teeth
      from the consumer side too. Then against **`~> 0.1.2` from Hex** in a clean
      project: the contract loads as a compiled module, the facade and its supporting
      modules load, the usage rules are present, and the reference venue correctly does
      **not** ship.
- [x] ~~**4.6** Confirm `publish` CI is armed — from here every merge to `main` releases a

      patch unattended (§7.3), by design~~ — **confirmed 2026-08-28 by two live releases.**
      `0.1.1` on the first push and `0.1.2` on the second, each unattended: version bumped,
      published, committed back, tagged, GitHub release created. It is armed and it works.
      **Plan branches accordingly from here** — every merge to `main` is a release.
### Phase 5 — Coinbase, the reference extraction

Coinbase is venue #1 (D11). It is the only venue that calls the §5.5 auth hooks, and it
exercises `FeedBehaviour`, `feed/coordinator.ex`, `pairs_per_socket` and
`authenticated_channels` — so the contract is tested against nearly its whole surface on
the first attempt rather than the smallest one.

**D12 makes this bigger than its line count suggests.** Coinbase is one of only two venues
genuinely using the host's `Connection` / `ConnectionPool` / `SubscriptionManager`, so the
package must absorb a socket lifecycle it does not have today — connect, reconnect with
backoff, pool across `pairs_per_socket: 100`, and track subscriptions. That work is not in
the 3,109 LOC being ported. Budget for it explicitly; it is the price of the facade, and
Coinbase pays it first precisely so the shape is known before Gemini repeats it.

- [ ] **5.1** Scaffold `dp-exchange-coinbase` from the §7 standard — **two restart gates,
      architect at both** (§7.1). Commit Coinbase's Advanced Trade API documentation —
      **from the vendor's own docs site, not an SDK** (D13) — to `docs/reference/coinbase/`.
- [ ] **5.2** **Pin the extraction (D19).** Record the host SHA **and the working-tree
      state** in `docs/reference/coinbase/`; if the subtree is dirty, save `git diff` too —
      on 2026-08-27 four of Coinbase's five files were modified and uncommitted. Ask the
      host team to commit first if they can: a clean tree makes the SHA sufficient.
      Coinbase took 32 commits in the 90 days to 2026-08-27, so the source moves under you.
- [ ] **5.3** **Reconcile the adapter against the documentation (D13).** The host's
      `describe_exchange` and `get_pair_catalog` MCP tools give the declared side without
      reading source (§0). Derive
      `Capabilities` from what Coinbase documents, then diff against what
      `coinbase/provider.ex` declares. Coinbase is the venue where this already paid out —
      `FOUR_HOUR` was real, served, and missing from the adapter's enum map, silently
      substituting 1h. Record every divergence here; report host-side ones per §0.
- [ ] **5.4** Port `provider.ex` (1,501), `symbol_format.ex` (33),
      `websocket_provider.ex` (1,263), `feed.ex` (126), `feed/coordinator.ex` (186)
- [ ] **5.5** Port the CDP JWT + rate-limit-header code out of Core per §5.5 — this
      package owns `coinbase_cdp_jwt/2`, the `:coinbase_cdp_jwt` auth type (9 call sites
      in `provider.ex`, 1 in `websocket_provider.ex:769`) and the `"coinbase"` branch of
      `parse_rate_limit_headers/2` (called at `provider.ex:622`)
- [ ] **5.6** **Own the socket lifecycle (D12, D20).** Absorb connect /
      reconnect-with-backoff / pool / subscription tracking into the package, and declare
      `websockex` in *this* package's `mix.exs` — Core does not have it. Take what is
      useful from the host's `Connection` (1,002) and `ConnectionPool` (1,099) — but only
      what Coinbase needs, not the generic abstraction. The host keeps its copy until
      migration deletes it.
- [ ] **5.6a** **Write the frame-send guard here first, incident included (D20).** Port
      `frame_sender.ex`'s 83 lines into `dp_exchange_coinbase` and **carry the moduledoc**:
      `WebSockex.send_frame/2` is `:gen.call` with a hard 5000ms timeout that *exits*
      rather than returning, killing the calling connection process; subscribes are
      idempotent so a duplicate is harmless where a lost connection is not.
      **Carry the cause, not only the symptom** (found at 1.6, reading the source): five
      seconds is not an arbitrary ceiling. A book-channel subscribe makes the venue reply
      with a full snapshot — Gemini's opening `l2` frame measured **39,804 bytes**, and a
      50-symbol batch is fifty of those. The socket process is single-threaded, so while it
      decodes that burst it cannot service the next `send_frame`, which times out and
      exits, killing the connection; the next send then fails `:noproc`. Observed
      2026-08-10. Without that paragraph the guard reads as defensive padding, and the next
      person to tidy the code deletes it.
      Gemini copies this module and this moduledoc at 6.1 — it is the copy it copies, so it
      has to be the good one.
- [ ] **5.7** **Port the host's Coinbase tests as a behavioural baseline** — 11 files,
      4,582 LOC (Appendix A). They are not just material to port: they encode how the
      adapter behaves today, so every one that fails against the package is either a port
      bug or a **deliberate behaviour change**. Triage each failure into one of those two
      and fix the first. Add the in-process fake (D7), process-scoped per §7.8.
- [ ] **5.8** Add **tier-2** tests: tagged, excluded from CI, hitting Coinbase's public
      endpoints with no credentials — prices, symbols, order book, candles, public stream
      channels, symbol round-trip. Where a `FOUR_HOUR`-class divergence surfaces, and it
      costs nothing to run.
- [ ] **5.9** **Record the behaviour deltas.** Every deliberate change from 5.7 goes in a
      running list: the facade replacing direct provider calls, `subscribe/2` replacing
      host-managed sockets, `{:error, :not_supported}` becoming an atom (Phase 2.6),
      `check/3`'s return type (D5), `acquire/3` atomic rather than looped (D-E.1),
      capability fields renamed or removed (§6.0), and anything else the port turns up.
      This list is what the adoption issue is made of (D16, Phase 5.13) — writing it during
      the work costs nothing and reconstructing it afterwards costs a lot.
- [ ] **5.10** **Drift check before publishing (D19).** Against both: `git log
      <pinned-sha>..HEAD -- <subtree>` for what was committed since, and `git diff --
      <subtree>` for what is uncommitted now. Triage every entry — already reflected, or a
      gap. A host fix is evidence about the venue, not an instruction about the remedy (D18).
- [ ] **5.11** `use DpExchange.Core.AdapterContract` — green
- [ ] **5.12** `mix quality` + coverage; `mix hex.build` inspected. **ARCHITECT GATE (D4)**:
      architect makes `dp-exchange-coinbase` **public** and adds the org `HEX_API_KEY` secret, then
      publish to public hexpm — landing as `0.1.1`, since CI increments the seed (§7.3).
- [ ] **5.13** **File the adoption issue on `dp_crypto_management` (D16).** Core and
      Coinbase are published; this is the hand-off. Contents per D16, including **5.8's
      behaviour deltas** — the host's tests are the thing those changes will break, so the
      list is the most actionable part of the issue. Writing it is in scope; acting on it
      is not (§1), and it is what starts D15's clock.
- [ ] **5.14** **Retrospective in this doc.** What did the contract miss? Fix Core, then
      continue. Anything learned about **noticing vendor change** — a doc that had moved, a
      capability that no longer matched, a divergence tier 2 would or would not have caught
      — goes to `docs/design/ideas/detecting-vendor-api-change.md`, not here.

Do not start Phase 6 until 5.14 is written. The host app's own retrospective on the
four-area reorganization predicts the shape: *"the first one took ~30 minutes of design
judgment; the next four were 5-minute mechanical replays."* The value of going first is
finding the Core gaps while only one repo has to change.

### Phase 6 — The remaining three

Order per **D11**: gemini, webull, robinhood — the rest of the four the host actually runs
on. Binance and kraken were 6.4 and 6.5 until **D21** took them out of the plan.
"Mechanical replay" is the hope, not the promise — 6.1 is where that claim first gets
tested, and 6.2 (webull) is where it is most likely to break.

Every venue scaffolds from the §7 standard, which carries **two restart gates with the
architect at both** (§7.1). Then, as in Phase 5.1–5.2 (**D13**): commit the venue's API
documentation — **the vendor's own docs site, not a GitHub SDK or a write-up** — to
`docs/reference/<venue>/`, derive `Capabilities` from it, then reconcile against the host
adapter and record the divergences. All four have public documentation; Schwab (Phase 7) is
the one the architect supplies.

Each also ships tier-2 tests against its public endpoints (D7) — no credentials, no money,
and the cheapest place a venue's real behaviour contradicts its adapter. **All three reach
tier 2 directly** — no VPN, no manual step, nothing to label. That is a property of D21's
scope cut, not a coincidence.

Each also ports that venue's host tests as a **behavioural baseline** and records the
deltas (Phase 5.7, 5.9) — those feed the venue's own adoption issue (D16). The corpus is
uneven: gemini has 4,423 LOC of tests, robinhood 332 (Appendix A), so 6.3 gets far less
help from it than 6.1 does.

Each is also **pinned to a host SHA and drift-checked before publishing** (D19, Phase 5.2
and 5.10). Webull is the sharp case: 78 commits in 90 days, the highest in the family, and
it sits at 6.2 — so its diff will be the longest and its 879 LOC of tests the thinnest
safety net. Cutting Phase 6 from six venues to three also shortens every remaining drift
window, because the whole phase finishes sooner.

Each venue's first publish carries the same **architect gate (D4)** as Phase 4.3 — the
architect makes the repo public and adds the org `HEX_API_KEY` secret, once per repo, before the
package ships. Everything goes to public hexpm; nothing is ever published privately.

**The four the host runs on** — `auto_collect: true` today; these are what make the
packages match real usage (O0) and the only ones that can graduate (D15):

- [ ] **6.1** `gemini` (6 files) — closes §5.5 by owning the `"gemini"` branch of
      `parse_rate_limit_headers/2`; second venue to absorb a socket lifecycle per D12,
      with Coinbase 5.5 setting the shape; `l2_book.ex`; 10-pairs-per-socket sharding.
      Also the first real test of §6.1.4: `sep: ""` plus `String.downcase/1` is a harder
      round-trip than Coinbase's identity mapping (D11).
- [ ] **6.2** `webull` (11 files) — MQTT over WebSocket, protobuf, session plan. The
      hardest of the four extracted from host source, and the one that most exercises
      whether the facade truly hides
      transport (§6.0): it owns its whole client and never touched the host's.
- [ ] **6.3** `robinhood` (4 files) — no venue socket at all; `subscribe/2` is served by
      polling internally (§6.0). The test of whether "both endpoints always exist" holds
      for a venue that natively offers only one. `signing.ex`.

**The two that cannot graduate** (D15) — extracted for completeness, not for proof:

- [ ] **6.4** **Close out binance and kraken (D21).** No extraction. Confirm both repos are
      still empty and still ours, reserve both hexpm names with a placeholder publish, and
      point each repo's `README` at
      `docs/design/ideas/binance-and-kraken-packages.md`. Note in the host's adoption issue
      (D16) that the host keeps its own binance and kraken adapters — we never took
      ownership of code we did not extract (D18).
### Phase 7 — Schwab, greenfield

Schwab is **not** the only venue built from API documentation — every venue is (D13).
What makes Schwab different is two things, and only two: its documentation is **private**,
so the architect supplies it rather than it being fetched; and there is **no host adapter**
to reconcile against (D10), so the documentation is the sole input rather than the
tie-breaker. That is what makes it the contract's real test.

Phase 7 does not start until the documentation lands. There is nothing to implement
against, and it will not be started on a guess or on scraped public pages.

What the host already knows about Schwab, and the package must respect: it is the
**millions-of-instruments venue**. Three host modules were written against its arrival —
`data/collection/quote_scope.ex:68`, `exchange_collection_scope.ex:22`, and
`collection_set.ex:31` — and all three say the same thing: a very large catalog must
never be swept into full-catalog collection by an omission, so Schwab ships
`auto_collect: false` and *what* it collects is a host-side decision taken at
implementation time, not a package concern. Note this is a capability declaration, not a
migration task — deciding the host's collection strategy remains out of scope (§1).

- [ ] **7.1** Receive the Schwab API documentation from the architect. Commit the
      relevant extracts to `docs/reference/schwab/` in `dp-exchange-schwab` so the
      implementation is reproducible and reviewable against a fixed source, rather than
      against a link that may move or a chat message. If the docs describe a sandbox,
      **verify it actually works** before relying on it — none of the other four has one
      that does (D7) — and record the answer alongside the docs.
- [ ] **7.2** Derive the `Capabilities` declaration from the documentation *before*
      writing the provider: `asset_classes`, `has_rest_historical_candles` +
      `historical_timeframes` + `max_candles_per_request`, `has_rest_order_book`,
      `supports_short_selling`, `reports_trade_volume`, `default_quotes` /
      `supported_quotes`, `auto_collect: false` (above), `overview_suits_collection`, and
      what `coverage/1` will honestly report — per §6.1.8 there is no streaming flag to
      set; what matters is what `coverage/1` reports as observed arriving, not what was
      subscribed.
      **`supports_margin` / `max_leverage` are also decided here.** Schwab margins, and
      after D21 it is the only in-scope venue that does — so the slot exists because of
      Schwab and its shape comes from Schwab's documentation, not from the crypto venues
      that first motivated it (§6.0, "Functional groups the facade does not have
      at all"). Equities margin is not crypto margin:
      whether `max_leverage` is even the right shape for a Reg-T account is a question for
      7.1's documentation, not an assumption to carry over from Kraken's 5x.
- [ ] **7.3** Scaffold `dp-exchange-schwab` from the §7 standard (**two restart gates**,
      §7.1); implement against the
      contract with no host source
- [ ] **7.4** Catalog size is the contract's real stress test here. `list_instruments/1`
      is an optional `DataProvider` callback and `get_symbols/1` is required; confirm
      both have a defined answer at millions of instruments (paging? streaming? refusal?)
      rather than assuming the crypto-venue shape, where a full catalog is a single
      cheap call. If the contract cannot express it, that is a Core gap — record it here.
- [ ] **7.5** Whatever else Schwab needs that the contract cannot express is a Core gap —
      record it here. (Equities are *not* new ground: Webull already declares
      `asset_classes: [:crypto, :equity]` and lands in Phase 6.2, before this.)

### Phase 8 — Close

- [ ] **8.1** All six in-scope repos green, published, `mix quality` clean; D21's two
      reserved repos carry a `README` and a name-holding publish, nothing more
- [ ] **8.2** **The EXPERIMENTAL markers stay** (D15). Phase 8 closes the extraction, not
      the experiment: a package graduates only when the host trades live on that venue and
      exercises its whole core set (§6.0), which is host-migration work and out of scope (§1).
      Packages graduate independently, and one the host never trades on may never graduate.
      Confirm all five markers are still in place in all six in-scope repos, and that no endpoint
      has drifted to `:proven` without a CHANGELOG entry saying on what evidence.
- [ ] **8.3** Retrospective appended. Sweep the five venues for what they taught about
      detecting vendor API change and append it to
      `docs/design/ideas/detecting-vendor-api-change.md` — **four** reconciliations of a host
      adapter against the vendor's own documentation (D13), plus Schwab built from
      documentation alone, is the sample. Smaller than the six this task originally
      assumed (D21), and worth saying so where the sample size is the argument.
- [ ] **8.4** `git mv` this doc to `docs/design/closed/`

---

## 3. Current State — Audit of 2026-08-26

### 3.1 The good news: the adapters are already clean

The host app already enforces an OSS-readiness invariant. `connectors.ex` declares it,
a custom Credo check (`test/credo/no_app_deps_in_exchanges.ex`) enforces it for new
adapters, and `docs/design/closed/2026-05-20_four-area-architecture-reorganization.md`
§"Connectors OSS-readiness invariants" is its origin.

Every `exchanges/<name>/` subtree was grepped for `DpCryptoManagement.*`, `Phoenix.*`,
`Ash.*`, `Cloak.*`, excluding the permitted `...Exchanges.Core.*` carve-out. Result:

| Adapter | Files | LOC | Non-self app refs | External deps |
|---|---:|---:|---|---|
| binance | 3 | 1,568 | **none** | `WebSockex`, `Logger` |
| coinbase | 5 | 3,109 | **none** | `WebSockex`, `Logger`, `GenServer`, `Supervisor` |
| gemini | 6 | 3,228 | **none** | `WebSockex`, `Logger`, `GenServer`, `Supervisor` |
| kraken | 3 | 2,002 | **none** | `WebSockex`, `Logger` |
| robinhood | 4 | 1,124 | **none** | `Logger` |
| webull | 11 | 4,330 | **none** | `WebSockex`, `Logger`, `GenServer`, `Supervisor`, `Bitwise` |
| mock | 2 | 1,211 | **none** | `Logger`, `Money` |
| **core** | **19** | **2,795** | **3 — see 2.2** | `Boundary`, `GenServer`, `Logger`, `Req` |

The venue subtrees really are close to a `git mv`. The work is in Core.

**Every number in this section is a working-tree reading, not a commit** (D19). Measured
2026-08-26/27 with 12 files in `exchanges/` modified and uncommitted — 867 insertions, 129
deletions, four of them Coinbase's. They describe what the host is *running*, which is the
right thing to extract from, and they will not match any SHA.

### 3.2 Core's app references — the actual blocker

```
core/http_client.ex:15   alias DpCryptoManagement.RateLimiting.RateLimiter
core/event_sink.ex:19    alias DpCryptoManagement.Events.{BalanceEvent, PriceEvent,
                                                          Publisher, WebSocketEventRouter}
```

Every venue package depends on Core, so nothing can leave until these are resolved.
`HttpClient`'s limiter reference is severed (§5.3). `EventSink` is not severed but
**inverted** — it stops carrying market data and becomes the package's notices channel
(§5.4, D14).

### 3.3 Five more Core defects found in the audit

These are not blockers but must be fixed as part of extraction, because they are exactly
the kind of thing that becomes permanent once published:

- **D-F: ~~the `dp-exchange-*` GitHub repositories do not exist~~ — WITHDRAWN 2026-08-27,
  same day. They all exist. This entry was wrong, and how it was wrong is worth keeping.**
  I concluded "does not exist" from `gh repo view` returning *"Could not resolve to a
  Repository"* and `gh repo list DistortionPoint` listing three repositories with no
  `dp-exchange-*`. I then explicitly ruled out a permissions artefact on the grounds that
  the same token reads `influx-elixir` fine.
  **That reasoning was wrong.** The token is a *fine-grained* PAT, scoped to a specific
  list of repositories. Reading one proves access to that one and nothing else — precisely
  the inference a fine-grained token exists to defeat. A 404 from it means *not in scope*,
  which through that API is indistinguishable from *does not exist*.
  **`git ls-remote` settles it directly and exits 0 for all eight**, each with zero refs —
  exactly what §0 said. The architect checked and said so.
  **The lesson is this plan's own rule turned on me.** §0 ranks live measurement first,
  and `ls-remote` is the live measurement: it asks the thing itself, over the credential
  that actually matters. `gh` was a proxy answering a different question through a
  differently-scoped credential, and I treated its silence as evidence — *an unknown
  source counting as evidence*, which §0 names as this family's recurring failure and
  which I had by then written into four other files.
  **Nothing was ever blocked.**
- **D-A: `Core.DefaultRateLimiter` does not exist.** `core/rate_limit_behaviour.ex`'s
  moduledoc states *"A default in-process bucket implementation ships in
  `Core.DefaultRateLimiter`"*. There is no such file. Core must actually ship it.
- **D-B: `WebSocketProviderBehaviour` is misfiled — and D20 removes its reason to
  exist.** The module is named
  `DpCryptoManagement.Connectors.Exchanges.Core.WebSocketProviderBehaviour` but its file
  lives at `connectors/websocket/provider_behaviour.ex`, outside the `core/` directory.
  13 callbacks, 1 optional. It was written as the contract between the host's `Connection`
  and a venue's codec, and D12 deletes the host's `Connection` from this picture. Under
  **D20 it does not move to Core at all.** A venue that wants the shape copies it inward,
  keeps the callbacks it actually implements, and is then free to change them without
  asking four other packages. The misfiling gets fixed by the file not being extracted.
- **D-C: `HttpClient` carries venue-specific knowledge.** Three branches that are venue
  facts living in shared code:
  - `build_auth_headers/5` has a `:coinbase_cdp_jwt` auth type
  - `coinbase_cdp_jwt/2` is a public Coinbase-specific function (line ~378)
  - `parse_rate_limit_headers/2` cases on `"coinbase"` / `"gemini"`
  This is the same anti-pattern `Capabilities` was created to kill (`case provider do`
  tables in shared code). Each venue must own its own auth and rate-limit-header
  parsing. See §5.5.
- **D-D: `HttpClient`'s rate-limit calls don't match `RateLimitBehaviour` — partly already
  fixed host-side.** The behaviour declares `acquire/3`, `check/3`, `record/3` keyed on
  `(provider, weight, opts)`; `HttpClient` still calls the host's `RateLimiter.acquire/4`,
  `check_rate_limit/4`, `record_request/4` keyed on `(provider, account_id, user_id,
  operation)`. **However**, the host has since built
  `rate_limiting/host_rate_limiter.ex` (81 LOC, Task #688, 2026-07-13): it
  `@behaviour`-implements `RateLimitBehaviour` at the correct 3-arity, unpacks
  `account_id` / `user_id` / `operation` out of `opts`, and delegates to `RateLimiter` —
  the resolution D5 proposes. `config/config.exs:593` already wires
  `config :dp_exchange_core, rate_limit_module: DpCryptoManagement.RateLimiting.HostRateLimiter`,
  naming the unpublished package. So the 3-arity **shape** is validated by a working
  implementation — but that implementation is itself defective; see **D-E**. The remaining
  work is rewriting `HttpClient`'s call sites (§5.3) and reimplementing, not porting.
- **D-E: `HostRateLimiter` is evidence, NOT the specification. It has four defects.**
  It is new (Task #688, 2026-07-13) and it exists *because* the host reached across a
  boundary it should not have — Webull and Robinhood bypassed `Core.HttpClient`, so a shim
  was added on the host side rather than the adapters being made self-sufficient. It is a
  symptom of the problem this project exists to fix, so it validates the *shape*
  (`acquire/3`, `check/3`, `record/3` with the extra dimensions in `opts`) and nothing
  more. Core reimplements; it does not port. The defects, all verified 2026-08-26:

  1. **`acquire/3` ignores the limiter's native `:cost`.** `RateLimiter.acquire/5` accepts
     `cost:` in opts (`rate_limiter.ex:123`). `HostRateLimiter` instead loops
     `Enum.reduce_while(1..weight, ...)`, calling `RateLimiter.acquire/4` once per token
     (`host_rate_limiter.ex:31-37`). So: N sequential `GenServer.call`s where one would do;
     each carrying `RateLimiter`'s 30s default timeout, making a weight-10 acquire block up
     to ~300s where the design intends 30; the group is not atomic, so two concurrent
     weight-N acquires interleave; and a failure partway has already consumed tokens for a
     request that never happens, which nothing releases.
  2. **`check/3` discards `weight`** (`host_rate_limiter.ex:65`, `_weight`). It cannot do
     otherwise — `RateLimiter.check_rate_limit/4` hardcodes cost 1
     (`rate_limiter.ex:162`: `do_check(provider, account_id, user_id, operation, 1)`). So
     `check(provider, 10, opts)` answers `:ok` when there is room for exactly one. The
     contract says it answers for `weight`. The defect is in the host stack, not only the
     shim.
  3. **`acquire/3` and `check/3` have opposite failure policies, undocumented.** `acquire`
     propagates `{:error, _reason}` — fails closed. `check` maps `{:error, _reason} -> :ok`
     — fails open. This one is partly the *contract's* fault: `check/3`'s declared return
     is `:ok | {:rate_limited, ms}`, which gives an implementation no way to say "I could
     not tell." Core should fix the contract, not copy the workaround.
  4. **`1..weight` is a descending range when `weight` is 0.** Verified on the target
     runtime, Elixir 1.18.4: `Enum.to_list(1..0) == [1, 0]`. So `record(provider, 0, opts)`
     records **two** requests and `acquire(provider, 0, opts)` acquires twice.
     `@type weight :: pos_integer()` makes 0 a caller error, but the failure is silent and
     inflates the exact meter `record/3` exists to keep honest — the Webull incident in its
     own moduledoc. The compile-time warning (`1..0 has a default step of -1`) does not fire
     because the bound is a variable.

  Report these to the host team as findings; fixing them there is out of scope (§1).


### 3.4 Host-app facts you will need

- Elixir `~> 1.14` in the host; **`1.18.4-otp-28`** in influx-elixir via `.tool-versions`
  (Mise, not asdf). Target 1.18 for the new packages.
- Host uses the `boundary` compiler. `RateLimitBehaviour` carries
  `use Boundary, deps: [], exports: :all, top_level?: true` — that declaration is a
  host-app concern and **drops out** in the extracted package (no `boundary` dep).
- Host consumes `{:influx_elixir, "~> 0.1.0"}` from public hexpm — the proven pattern.
- The host's grandfather list in `test/credo/no_app_deps_in_exchanges.ex` is
  `~w(coinbase gemini kraken binance mock core)`. Whoever migrates the host later removes
  names from it as venues leave. Not your job; noted so you understand the mechanism.

---

## 4. Design Decisions

| | Decision | Settles |
|---|---|---|
| D1 | Package names (hexpm) and module namespace (`DpExchange.*`) — separate axes | |
| D2 | Core published first, hard dependency | Contract frozen before venue #1 |
| D3 | Hex only, never path deps | |
| D4 | Public hexpm; architect makes each repo public first | Per-repo gate |
| D5 | Rate limiting: venue-owned, contract reimplemented | D-D, D-E |
| D6 | Nothing injected; venue owns sockets, emits events | |
| D7 | Every venue owns its fake; drift accepted, four test tiers | |
| D8 | Contract enforced by a shipped conformance suite | |
| D9 | Repo standard cloned from influx-elixir: CI workflow only, coverage 90 | |
| D10 | coingecko, mock, schwab | |
| D11 | Extraction order: coinbase, gemini, webull, robinhood, schwab | OQ9; binance + kraken removed by D21 |
| D12 | **The facade is the boundary; the venue owns its whole strategy** | The load-bearing one |
| D13 | Every package built against the venue's own **web** API docs; third-party SDKs are not a source | |
| D14 | Three outbound channels: data, notices, telemetry | |
| D15 | Published EXPERIMENTAL until the host trades live on that venue | Answers D7 tier 4; every package in scope can now graduate (D21) |
| D16 | The two repos coordinate through GitHub issues, both directions | Makes "migration out of scope" a hand-off, not a shrug |
| D17 | Every commit is a public commit; verify `.gitignore` before committing | D4 means private-now is public-later, with full history |
| D18 | We own the code; the host becomes a consumer | Authority flips at extraction |
| D19 | The source moves, including uncommitted; pin each extraction to a SHA *and* tree state | 141 commits/90 days; 12 files dirty right now |
| D20 | Core ships no venue-specific dependency; each venue ships its own transport | Resolves D-B; no `websockex` in Core at any strength; no ninth repo |
| D21 | Binance and Kraken are out of scope; names reserved, work deferred to an idea doc | No account is possible, so neither can ever graduate; closes OQ26 |

### D1 — Package names and module namespace (two separate axes)

- **Selected**: Hex packages `dp_exchange_core`, `dp_exchange_binance`, …; root module
  namespace `DpExchange`, with `DpExchange.Core.*` and `DpExchange.<Venue>.*`.
- **Options considered**: (a) `DpExchangeCore.*` / `DpExchangeBinance.*` — one root per
  package, mirroring `InfluxElixir`; (b) shared `DpExchange.*` root.
- **Rationale**: (b) makes extraction a mechanical namespace rename — the current tree is
  already `…Connectors.Exchanges.{Core,Binance}`, so `DpCryptoManagement.Connectors.Exchanges.`
  → `DpExchange.` is a single sed per file. It also reads correctly at the call site
  (`DpExchange.Binance.Provider`). Sharing a root namespace across Hex packages is normal
  in Elixir. The telemetry spec already commits to this: event names are
  `[:dp_exchange, :request, :start]` etc., written before any extraction.
  Choosing per-package roots would leave module names and telemetry event names
  disagreeing — which settles it: the code already committed to the shared root before this
  plan existed.

**Two axes, and they are independent.** The *package* names are `dp_exchange_core`,
`dp_exchange_binance` … under either option — Hex forbids hyphens and the repo names map
straight through (§0). Only the *module* root is in question. Nothing about hexpm argues
for or against a shared root, and the two should not be used as evidence for each other.
- **Core owns the namespace.** Not merely a prefix everyone shares — `DpExchange` is a
  real module, defined in Core, and Core is where the family is anchored. Three concrete
  consequences:
  1. **`DpExchange` is Core's documentation home.** It carries the moduledoc explaining
     what the family is, which venue packages exist, what the facade guarantees and what
     it deliberately does not (§6.0). For a public package that is the first page anyone
     reads, and "this is a bare namespace, look elsewhere" is a poor first page.
  2. **Core's account claims the *package* names** — a hexpm matter, not a namespace one,
     but Core is where it belongs because Core is the family's anchor. Names on public hexpm
     are first-come and permanent (D4), and nothing stops a stranger publishing
     `dp_exchange_<venue>` that looks official. Core's account claims all eight names this
     plan touches — the six it ships plus binance and kraken, which it reserves without
     building (D21) — plus `dp_exchange_fidelity`, which the host's idea docs name as an expected
     equity venue. It does **not** claim speculatively: squatting names the org has no plan
     to fill is poor citizenship on a public registry, and `kucoin` and `bybit` are in
     fact *excluded* by `architecture/exchange-capabilities.md`. `etoro` appears only in
     that document's stale *Planned* section and in no idea doc, so it is not claimed.
  3. **Core is the single source of the contract version.** Every venue declares
     `{:dp_exchange_core, "~> x.y"}` and the conformance suite ships from Core (D8), so
     the namespace owner and the contract owner are the same thing. That is the property
     that makes the venue repos one family rather than a set of similarly-named packages.
  4. **The namespace is the registry.** `"coinbase"` → `DpExchange.Coinbase` is a pure
     convention, so Core resolves a venue name with `Module.safe_concat(DpExchange,
     Macro.camelize(name))` plus `Code.ensure_loaded?/1` — and needs no list of installed
     packages, no boot-time registration and no `Application.loaded_applications/0` scan.
     `safe_concat` raises rather than creating an atom from caller input, which is exactly
     the hazard the host worked around with a hardcoded whitelist
     (`connection_pool.ex:893`, *"avoids `String.to_atom` on caller-supplied provider
     name"*) and with `provider_registry.ex`'s `@default_providers` map. Both are provider
     tables (D12) that the convention removes outright. Core resolves; it does not
     enumerate — a consumer wanting the list of venues it has already has one, in its own
     `mix.exs`.
- **Trade-off**: Core becomes load-bearing for more than the contract — a namespace, a
  documentation root and a name claim. Accepted; it is already the hard dependency (D2),
  so this concentrates responsibility where it already sits rather than adding a new place
  for the family to be inconsistent.

### D2 — Core is published first and is a hard dependency

Adapters declare `{:dp_exchange_core, "~> 0.1.0"}` — the three-part form, which is
`>= 0.1.0 and < 0.2.0`. **Not `~> 0.1`**, which in Hex means `< 1.0.0` and would let a venue
silently accept a deliberately breaking release (D18). Core must be published and stable
before venue package #1 ships. Corollary: **the contract must be settled in Core before
any venue work begins**, because a Core change after the fact means bumping and
re-releasing every venue package.

### D3 — Hex only, never path deps

Explicit user decision. No `path:` or `github:` deps between these repos at any point,
including during development. Each repo builds and tests against a published Core.

Consequence: Core's first publish happens early and Core's version will move fast during
the first venue extraction. That is acceptable and expected — it is why Core is `0.x`.

### D4 — Public on Hex from the first publish; the architect makes each repo public first

**These are public because the problem is general** (§1): any application connecting to
several exchanges needs this, and today each one writes it again. **There is no private
Hex organization and no private publishing step. Nothing in this
family is ever published privately.** Every package goes to public hexpm, and the
architect makes the corresponding GitHub repo public immediately before its first publish.

**`HEX_API_KEY` is an organization key and is already proven.** influx-elixir publishes
with it today — `.github/workflows/ci.yml:102-104` runs `mix hex.publish --yes` against
`secrets.HEX_API_KEY` — so provisioning is a matter of adding the existing secret to each
new repo, not obtaining one.

The order, per repo, exactly once:

1. Repo is private while the package is being built. Nothing is published.
2. **Architect makes the repo public.** Manual, human, deliberate.
3. First publish to public hexpm.
4. From then on §7.3's `publish` job releases a patch on every merge to `main`,
   unattended.

**Consequences, and they are not soft:**

- **The first publish is the public debut.** There is no private staging round to shake
  out a bad README, a leaked host-app name, or a wrong `files:` list. Whatever ships is
  what the world sees, on a package name that is then claimed permanently on hexpm. Hex
  allows reverting a release only inside a short window after publish; past that a release
  can be retired but not removed.
- **"Written as if public from day one" is not a style preference — it is the only mode.**
  LICENSE, README, usage-rules, zero internal references, zero host-app names, no
  `DpCryptoManagement.*` anywhere in the tarball. The purity assertion (§6.1.7) and the
  `mix hex.build` inspection (Phase 4.3) are the two checks standing between a mistake and
  a permanent public artifact.
- **Repo public *before* publish, never after.** `mix.exs` sets `@source_url` and
  `package: [links: %{"GitHub" => @source_url}]` (§7.2). Publishing while the repo is
  still private ships a package whose source link 404s for every consumer and for HexDocs.
- **The gate is per-repo and one-time, not per-release.** Eight repos, eight flips — six
  that ship packages, plus D21's two reserved names, whose placeholder publish needs the
  same gate. The
  architect is in the middle of each package's first publish and deliberately not in the
  middle of the patches after it. Rule 6 ("NEVER COMMIT OR PUSH without confirmation")
  governs local pushes, not CI's own release commit — that automation is authorised once,
  by the repo going public and the org `HEX_API_KEY` secret being added.

Sequencing: the flip belongs immediately before the first publish of each package —
Phase 4.3 for Core, Phase 5.12 for Coinbase, and the corresponding step in each Phase 6
venue — per repo, never batched.



### D5 — Rate limiting: inject, and reconcile the arity mismatch

- Core ships `DpExchange.Core.RateLimitBehaviour` with `acquire/3`, `check/3`, `record/3`
  keyed on `(provider, weight, opts)` — the existing contract, kept.
- **The package scopes by venue. Full stop.** One bucket per venue per node, metering the
  traffic the package itself sends. It does **not** scope by API key, account or user:
  a package cannot know how many keys a host holds, and a limiter that guesses is worse
  than one that is simply conservative. Under-using a venue's capacity is the safe error;
  over-using it is the one that gets an account banned.
- **`opts` stays open, and Core's implementation ignores most of it.** The contract keeps
  `(provider, weight, opts)`, so a host that plugs in its own `rate_limit_module` may carry
  `account_id`, `user_id` or anything else and act on it. `DefaultRateLimiter` reads none of
  them. That is the host's business, and this is the seam for it.
- **A host that needs more throughput clusters.** Multiple collection nodes, each with its
  own buckets — that is the host's scaling decision and it is a long way outside what a
  venue package should be reasoning about. The package's job is to not exceed the venue's
  ceiling from where it is running.
- Core ships `DpExchange.Core.DefaultRateLimiter` — a real in-process token bucket
  implementing the behaviour (fixing D-A). This is what a third-party consumer gets for
  free.
- Resolution goes through Core's **process-scoped seam** (§7.8), not `Application.get_env/3`
  directly: process dictionary, then `$callers`, then Application env, defaulting to
  `DpExchange.Core.DefaultRateLimiter`. A host test must be able to swap the limiter for
  its own process tree without breaking every other `async: true` test on the node — which
  is exactly the incident §7.8 records. The host has **already** written its side:
  `HostRateLimiter` exists and `config/config.exs:593` already points
  `:dp_exchange_core, :rate_limit_module` at it, against a package that has not shipped
  yet. **That does not make it the specification.** `HostRateLimiter` is new, was written
  to paper over adapters bypassing `Core.HttpClient`, and carries four defects — see
  **D-E**. It validates the 3-arity *shape* and nothing else. Core reimplements the
  behaviour from the contract, then checks the host module against it; where they differ,
  the contract wins and the difference is reported to the host team as a finding.
- **The venue enforces its own ceiling** (D12). `ProviderLimiter`'s `@provider_configs`
  is venue knowledge in host code, and Robinhood and Webull are already missing from it.
  Under D12 each venue package owns its limiter outright. `RateLimitBehaviour` stays the
  contract Core publishes and `DefaultRateLimiter` stays the implementation a package uses
  unless it needs its own — but neither is a host table any more. Scope is the venue, never
  the key or the account (above).
- **A venue may have two ceilings, not one.** Where the same data is served publicly and
  authenticated with a higher authenticated limit, the package should use the authenticated
  path when it holds credentials (§6.0) — and must meter against the ceiling that actually
  applies. Declaring one number means either throttling a credentialed caller to the public
  limit or metering an uncredentialed one against a budget it does not have.
- **`check/3` gains an explicit error case and fails closed** (D-E.3). Declared as
  `:ok | {:rate_limited, non_neg_integer()}`, it gives an implementation no way to say "I
  could not tell" — which is why `HostRateLimiter` silently maps limiter errors to `:ok`
  and fails open while `acquire/3` fails closed. Core adds `{:error, term()}` and states
  the policy once: **an unknown answer is not permission.** §0's rule decides it — a nearby
  substitute where there should be an error *is* the bug, and it is what had Gemini's socket
  speaking Coinbase's protocol for as long as it stood.
- **`check/3` must honour `weight`** (D-E.2). The host's cannot — `check_rate_limit/4`
  hardcodes cost 1 — so `DefaultRateLimiter` is where the contract is first met honestly.
- **`acquire/3` must be atomic in `weight`, not a loop** (D-E.1). Acquiring N tokens by
  calling a 1-token acquire N times is not the same operation: it is not atomic, it
  multiplies the timeout by N, and a failure partway leaves consumed tokens nothing
  releases. `DefaultRateLimiter` takes `weight` as a single reservation.
- **Guard `weight` at the boundary** (D-E.4). `@type weight :: pos_integer()` is not
  enforced at runtime, and `1..weight` silently does the wrong thing at 0 — verified on
  Elixir 1.18.4, `Enum.to_list(1..0) == [1, 0]`. Core validates rather than trusting the
  type, because the failure is silent and inflates the meter.
- `record/3` "deliberately cannot fail" — preserve that. Its moduledoc records a real
  incident (Webull acquiring without recording, 395 requests/60s against a documented
  300, budget panel reading 83/240). Keep that rationale in the extracted moduledoc.

### D6 — Nothing is injected. The venue owns its sockets and emits its events

**The facade's entire inbound surface is credentials and options** (§6.0). The host injects
nothing: not a socket, not a sink, not a module. What the package needs, it owns; what it
has to say, it emits.

- **`Core.EventSink` does not carry market data, in any form.** The host's current module
  is a bundle of `defdelegate`s into `DpCryptoManagement.Events.*`, and that stays in the
  host. Wiring a venue's *data* stream to an event sink is the **host's** job: the package
  emits to whoever subscribed and holds no function that decides what happens next.
- **A notices channel does ship, and it is not the same thing** (§6.0, D14). A venue
  package reports on **itself** — connection state, credentials rejected, sustained rate
  limiting, coverage dropping, catalog changes (a pair added, removed or delisted),
  degradation — on a channel the host subscribes to independently of market data.
  Emit-not-inject, never carrying credentials, and lossy-safe: reporting on the work must
  never become the reason the work does not happen. `Core.Notice`, `subscribe_notices/1` —
  deliberately not `EventSink`, since the host's `EventSink` means the data conduit and the
  two get read side by side during migration (D14).
  `EventSink` means the data conduit and the two get read side by side during migration.
- **`@type sink :: (map() -> any())` is removed** from `FeedBehaviour`. An injected sink is
  host code running inside the package's processes, at moments the package picks, and its
  *shape* is the host's event vocabulary — so the package would end up knowing what the
  host does with data. That is the coupling O0 exists to remove, arriving through the one
  door left open.
- **`@type socket` is removed** (D12). It described `%{open: …, subscribe: …}` — host-owned
  connection plumbing handed to the venue. This is what already made Webull
  unrepresentable: an MQTT session cannot be expressed as `open` + `subscribe`, so it
  bypassed the type and ran `WebSockex.start_link` itself. Removing it makes Webull
  ordinary rather than exceptional.
- **What replaces both**: `subscribe/2` registers the caller and the venue **sends** events
  to it (§6.0). The host receives messages and connects them to whatever it likes.
- The design principle **survives, strengthened**: *the venue keeps the policy* — how many
  connections, which channels, how many symbols each carries, in what order, with what
  pacing. It now keeps the plumbing too, so there is no seam where the platform's idea of a
  connection and the venue's can disagree. `websocket/supervisor.ex` accepting only
  `["coinbase","gemini"]` was that seam.
- `coverage/1` reports what has been **observed** arriving, never what was subscribed.
  A feed that cannot observe delivery answers `:not_covered`. This is load-bearing —
  Webull subscribed 325 symbols and confirmed them while 174 delivered.

**The `:source` tagging rules mostly dissolve, and that needs saying explicitly** because
they encode three real outages (§5.4). They existed so the host's `PollSet` could tell a
streamed tick from a polled one and take a pair off the REST poll set accordingly. Under
this facade the host does not poll these venues at all — it subscribes and receives — so
`:stream` versus `:feed` is a distinction it can no longer act on and no longer needs.
What survives is the *reason* behind rule 3 ("a REST-backed feed must never claim
`:stream`"): **never let intent stand in for evidence.** That now lives entirely in
`coverage/1` reporting observed delivery. Where the host still needs to know provenance,
it tags **on receipt** — it knows which venue it subscribed to, so the package need not
tell it.

### D7 — Every venue package owns its own fake; no mocking libraries

Explicit user decision, and it matches `feedback_no_mocking` in the influx-elixir project
memory. The pattern to follow is influx-elixir's `LocalClient`:

- A **real in-process fake** shipped inside the package (`InfluxElixir.Client.Local`,
  ETS-backed, responds like the real server).
- Selected by config in `config/test.exs` — one line:
  `config :influx_elixir, :client, InfluxElixir.Client.Local`.
- Validated against the real thing by a **shared contract module**
  (`test/support/client_contract.ex`) that both the local and integration suites run,
  so the fake's fidelity is proven rather than assumed.
- Integration tests are tagged and excluded from CI; CI runs entirely against the fake.

**The org has already run this experiment, and it worked at real scale.** influx-elixir is the exact
peer of what these packages will be: a DistortionPoint library on public hexpm, consumed
by `dp_crypto_management`. `../dp_crypto_management/docs/bugs/fixed/` holds **13 bug
reports the host filed against `influx_elixir`'s `Client.Local`** — the very fake this
decision copies — across v0.1.1 to v0.1.5. Eleven are fidelity gaps: the fake accepted the
call and answered differently from the real server, and most failed **silently**:

- `resolve_params` mishandled atom keys — *"ALL parameterized queries silently return
  wrong results"*, `$param` placeholders left as literals
- aggregate queries ignored `WHERE time >= …` — every windowed query returned empty
- `SELECT * FROM "measurement"` returned empty because quotes were not stripped
- writes ignored supplied timestamps and auto-assigned their own
- the facade path failed connection resolution — *"writes silently fail"*

The rest were unsupported features simply absent: `COUNT(*)`, `DATE_BIN`, `SELECT
DISTINCT`, `first()`/`last()`, the `IN` operator, explicit column lists.

**Read the outcome, not the count.** Thirteen gaps existed; thirteen were found by the
first consumer doing real work; thirteen were fixed upstream in point releases — the commit
two days after the filings is named *"Big fix for Influx syntax, and LocalClient
verification"* — and each became a permanent case, which is how `client_contract.ex`
reached 1,359 lines covering `DATE_BIN`, `COUNT`, `DISTINCT`, `first`/`last` and `IN`.

**And the package is not quiet.** influx-elixir ran **2,000+ hexpm downloads in the 30 days
to 2026-08-27** with **zero externally reported bugs** — architect's figures. So this is not
the weak version of the claim, where nothing escaped because nobody was looking. There is
real external usage, and the gaps still surfaced where they could be fixed rather than in
someone else's production.

That is the loop functioning as designed. The contract suite's job is not to *anticipate*
every divergence — no test suite for anything meets that bar. Its job is to be a
**ratchet**: once a gap is found it can never come back. Finding is done by a real consumer
exercising the fake against real work, which is a designed part of the system rather than a
hole in it, and which `dp_crypto_management` will occupy for these packages exactly as it
did for influx-elixir.

Tiers 2 and 3 below are therefore **cheap insurance on a working process**, not
compensation for a broken one — worth having because a venue behaviour the host never
exercises is one nobody is positioned to find, and because silent wrong answers are the
class least likely to be reported by anyone.

**The drift risk is accepted, deliberately, because every alternative is worse.**
Architect's decision, 2026-08-26.

There is no clean way to eliminate it. Fully exercising most of these APIs requires **real
keys and real trades**, and that risk is larger by a wide margin: order placement moves
real money, is irreversible, and cannot be made idempotent by any amount of test
scaffolding. A suite that places orders to prove it can place orders is a liability, not a
safety net — and it would run on every contributor's machine, in five venue repos, on
packages that are public (D4). The 13 `Client.Local` reports above are the *cheap* failure mode.

So the fake is chosen on the understanding that **it is an asset that appreciates**. Every
gap found becomes a permanent case in the suite; influx-elixir's went from nothing to
1,359 lines exactly that way, and each of those thirteen bugs is now a thing that cannot
recur. A maintained fake gets monotonically better. Real-money integration testing gets no
safer with age.

**What makes the risk bounded rather than open-ended is tiering it.** Four levels, split
by what they cost to run and who can run them at all:

| Tier | Runs | Credentials | Covers |
|---|---|---|---|
| **1 — fake** | **Every test run, in CI. The only tier that does.** | none | The whole facade, fast, free, deterministic |
| **2 — live public** | Tagged, excluded from CI. Per venue during extraction, and by hand when a venue is in question | none | `get_price`, `get_symbols`, `get_order_book`, `get_historical_prices`, `get_market_overview`, public stream channels, symbol round-trip against real payloads. Runs on the **unauthenticated** ceiling, which on some venues is much lower (§6.0) — pace it accordingly |
| **3 — authenticated, read-only** | **Out of scope — see the idea doc** | real keys | Balances, accounts, fees, authenticated stream channels |
| **4 — money-moving** | **Unsolved. Deliberately.** | real keys + funds | `place_order/3`, `cancel_order/3`, and anything else that transacts |

**Tier 1 is the only tier in CI.** Nothing else runs on every commit, in any repo. A
contributor cloning a venue package and running `mix test` must reach a green suite with no
credentials, no network and no cost. That is not a convenience — it is what makes these
publishable at all (D4).

**What a green CI run does not prove**, stated plainly so no badge implies otherwise:
order placement and cancellation semantics (tier 4), authenticated stream channels and
funded-account balance shapes (tier 3), real rate-limit responses under load — a genuine
`429` and its `Retry-After` — and live fee schedules. Tier 1 proves the facade's *shape*
against a fake the package authors wrote. It cannot prove the venue agrees.

**Tier 2 runs per venue and by hand, never on a schedule from CI.** It needs no credentials
and risks no money, so it is tempting to automate — but it hits a third party's public API
from whatever machine runs it, and a venue that sees a package polling it on a timer will
rate-limit or block. So: once per venue during its extraction (Phases 5.7 and 6), and again
whenever a venue's behaviour is in question. Under **D21** every venue left in scope
reaches tier 2 directly, so this is a deliberate choice rather than a limitation — the one
venue that would have forced it (binance, via VPN) is no longer in the plan.

**Tier 3 is out of scope for this plan.** Authenticated verification needs credentials the
package cannot hold and CI must never have, so it can only run where the keys already are —
a consumer who has them and opts in. That is a design problem of its own (what makes a
stranger willing, what a report contains, how it reaches a fix) and it is not solved here.
See `docs/design/ideas/external-experimental-feedback.md`.

What this plan does commit to is naming the gap rather than papering over it: tier 3 is
**uncovered** for now, `usage-rules/testing.md` says so to consumers, and D15's
EXPERIMENTAL label is the standing acknowledgement.

**Tier 4 is not scheduled, and the plan should not pretend otherwise.** Verifying order
placement means placing orders: real money, irreversible, on a venue that does not
distinguish a test from a trade. Even a consumer with keys cannot be asked to run it
casually. The options that remain are thin — no venue in the family has a working sandbox
(below) — leaving the smallest legal order size, immediate cancellation, and a dedicated
funded account with a hard cap; every one carries real risk and real cost. So
order-lifecycle correctness rests on tier 1's shape checks, the venue's documentation
(D13), and production use by the host. That is a known, stated gap, not an oversight, and
`usage-rules/testing.md` says so to consumers rather than letting a green badge imply
otherwise. **D15 is where tier 4 is actually answered**: a package stays EXPERIMENTAL until
the host trades live on that venue and exercises the whole of its API, which is tier-4
coverage arriving as production use rather than as a test suite.

**There is no sandbox to fall back on.** None of the six current venues offers a **working**
sandbox or testnet — architect's finding, 2026-08-27. That is not the same as none existing:
some are advertised and do not function, which is worse than absence, because it costs
whoever tries the time to discover it. Schwab is unknown until its documentation arrives
(Phase 7).

This removes the middle ground entirely. There is no safe place to exercise authenticated
or order-placing behaviour: it is production or nothing, on every venue in the family. Two
consequences follow, and both are already load-bearing elsewhere in this plan — D15's
insistence that graduation requires live trading is not a preference but the only
mechanism available, and the idea doc's premise (that external help is the only route for
venues the architect cannot access) is correspondingly harder, since a contributor cannot
be pointed at a sandbox either.


Each `dp-exchange-<venue>` ships its own venue fake on this model. Core ships the
transport-level scaffolding and the contract harness. The host app's existing
`exchanges/mock/` (2 files, 1,211 lines) is a host-side test double and does **not**
become a package — see D10.

**The fake must be process-scoped, not globally selected** (§7.8). influx-elixir's
`config :influx_elixir, :client, …` is a node-wide switch, which is fine for one library
and wrong for a family of five venues: a host will want venue A faked while venue B is real, and
two async tests wanting the same fake to behave differently — one returning `429`, one
succeeding. Selection *and* behaviour resolve through Core's process-scoped seam, falling
back to Application env for the ordinary case.

### D8 — The contract is enforced by a shipped conformance suite

This is the core mechanism of O3 and the answer to "they ALL follow the exact same
pattern". See §6.1 for the specification.

### D9 — Repo standard cloned from influx-elixir, not invented

See §7. **Coverage threshold is 90**, enforced by `test_coverage: [threshold: 90]` in
`mix.exs`. influx-elixir's prose says 95% (`CLAUDE.md:113`, `:118`) while its code says 90
— the code is what runs, so 90 is the number and the prose is what was wrong. Each
package's CLAUDE.md states 90 and nothing states 95.

**Governance is whatever influx-elixir has, which is very little.** Its `.github/` contains
one file — `workflows/ci.yml`. No `CODEOWNERS`, no `dependabot.yml`, no issue or PR
templates, no `CONTRIBUTING.md`, no `SECURITY.md`. The org's Blueleaf `library`
repo-governance checklist is not the standard here; the proven DistortionPoint library
pattern is a CI workflow and nothing else, and inventing more would be inventing.

This plan adds exactly two things influx-elixir lacks, each for a reason of its own rather
than because a checklist asked:

- **`.github/ISSUE_TEMPLATE/`** (D16) — these packages have a defined inbound bug flow from
  the host, which influx-elixir never had; its 13 reports were markdown files in the host's
  own `docs/bugs/fixed/`.
- **Secret scanning with push protection** (D17) — a GitHub setting rather than a file, and
  required here because these repos carry `.mcp.json` and go public. influx-elixir has no
  `.mcp.json` and so never faced it.

### D10 — coingecko, mock, and schwab

- **coingecko** — NOT part of this family, and it is deliberately not an exchange. It is
  wired into the host as a historical-price reference: `connectors.ex:496` sets
  `@historical_price_providers [Coingecko.Provider]`,
  `trading/positions/position_discovery.ex` uses it for cost-basis lookups, and
  `config/config.exs:570` already reserves `config :dp_coingecko, finch_pool: ...`. The
  host's own test states it outright — `capabilities_declaration_test.exs:231`:
  *"coingecko is a price reference, not a venue"*. If it is ever extracted it becomes a
  separate `dp_coingecko`, on its own schedule. **No repo, no work here.**
- **mock** — no `dp-exchange-mock` package. Per D7, each venue owns its fake.
- **schwab** — greenfield. There is **no** `exchanges/schwab/` in the host app; Schwab
  appears only in `data/collection/` scope code and design docs. Build it **last**, as
  the proof that the contract is correct without existing code to lean on. Its input is
  API documentation supplied by the architect at Phase 7 — private, unlike the other four
  (D13) — see §2 Phase 7 and §10.

### D11 — Extraction order: Coinbase first, then by what each venue proves

- **Selected**: `coinbase` is venue #1.
- **Options considered**: (a) `binance` first — smallest package (3 files, 1,568 lines,
  `WebSockex` + `Logger` only), fastest to a green pipeline; (b) `coinbase` first. **D21
  has since removed binance from the plan entirely**, which retires option (a) on grounds
  the original argument never used; the reasoning below is kept because it is what settles
  venue #1 among the venues that remain.
- **Rationale**: the reference extraction's job is to find Core's gaps while only one
  repo has to change, so it should exercise as much of the contract as possible, not as
  little. Binance touches `DataProvider` and `SymbolNormalizer` and nothing else — under
  D20 its WebSocket work is entirely package-internal, so it exercises even less of Core
  than this option assumed. Coinbase additionally exercises
  `FeedBehaviour` (`feed.ex`), multi-socket sharding (`feed/coordinator.ex`,
  100 pairs per socket), authenticated streams, and — decisively — it is the only
  venue that calls the auth hooks §5.5 introduces. Under (a) those hooks are designed in
  Phase 2.4 with no caller and are not proven until venue #4; under (b) they get a real
  caller in Phase 5, in the same window where fixing Core is still cheap.
- **Trade-offs**: two costs, both accepted. First, venue #1 is now 3,109 lines across 5
  files rather than 1,568 across 3, so the "5-minute mechanical replay" claim is not
  tested until venue #2 — Phase 6.1 (gemini) is where that gets proven. Second, Coinbase's
  `SymbolFormat` is effectively identity (`sep: "-"`; its native `product_id` is already
  canonical `BASE-QUOTE`), so contract assertion §6.1.4 is only weakly exercised by the
  reference venue. Mitigated at **Phase 3.2**: Core's reference fake carries a deliberately
  hostile symbol mapping, so §6.1.4 has real teeth before any venue relies on it.


**The full order, and the principle behind it** (architect, 2026-08-27):

> **coinbase → gemini → webull → robinhood → schwab**

Two groups, ordered by how much each proves:

1. **The four the host actually runs on** — coinbase, gemini, webull, robinhood. These are
   exactly the venues declaring `auto_collect: true` in the host today. Finishing these
   four is what makes the packages match `dp_crypto_management`'s real usage, which is the
   point of the whole exercise (O0) and the only route to graduating anything (D15).
2. **The greenfield one** — schwab. No host source at all, private documentation, and the
   contract's real test (D10, Phase 7). Last, deliberately.

**Binance and Kraken were the third group and are no longer in the order at all** — see
**D21**. They are the two venues declaring `auto_collect: false`, and the two the
architect cannot hold an account on.

Two properties of this order are worth noting because they were previously open questions:

- **Gemini second closes §5.5 early.** It owns the other half of the venue-specific
  rate-limit-header code, so the Core hooks added in Phase 2.4 have both their callers by
  venue #2 rather than venue #4.
- **Gemini second also fixes the round-trip gap.** Coinbase's `SymbolFormat` is effectively
  identity, so assertion §6.1.4 is barely exercised by the reference venue. Gemini's is
  the opposite: `sep: ""` *and* a `String.downcase/1` on the way out — no separator plus a
  case transform. The invariant gets real teeth at venue #2, which under D21 is the only
  place left to get it.

### D12 — The facade is the boundary; the venue owns its whole strategy

**Supersedes the "inject the mechanism" reading of D5 and D6.** Architect's decision,
2026-08-26.

The rule: **every venue package exposes the exact same facade, and nothing crosses that
facade.** Websockets, rate limiting, credential handling and session lifecycle are venue
strategy, executed inside the venue package. The host app manages none of them.

Duplication is only a cost when the mechanism is genuinely the same. It is not.

**What the audit actually found.** The host's `connectors/websocket/` tree is not shared
mechanism; it is Coinbase's and Gemini's mechanism carrying a generic name:

| Venue | Socket strategy | Uses host `WebSocket.Connection`? |
|---|---|---|
| coinbase | frame WS, pooled, 100 pairs/socket | yes |
| gemini | frame WS, pooled, 10 pairs/socket, L2 book | yes |
| binance | frame WS, own provider | **no** — absent from `websocket/supervisor.ex:258` whitelist |
| kraken | frame WS, own provider | **no** — same |
| robinhood | none; REST `PollingFeed` | **no** |
| webull | MQTT-over-WebSocket, own `use WebSockex` client, own packet buffering, own session handshake | **no** — `webull/mqtt_ws.ex` |

Four of six venues already route around the "shared" layer, and Webull went furthest:
`mqtt_ws.ex` calls `WebSockex.start_link` directly because WebSocket frame boundaries do
not align with MQTT packet boundaries, so it must own its own buffering loop. Forcing that
through a frame abstraction "would invent frames and lose QoS semantics" — `connection.ex`
says so itself. That is not a venue failing to reuse a mechanism. That is proof the
mechanism was never shared.

Rate limiting is the same shape: `provider_limiter.ex:23` tables four venues at
hand-entered ceilings and omits Robinhood and Webull entirely, so they fall into
`get_default_config()`. Credentials are already correct — every `DataProvider` callback
takes `credentials()` as an argument, and venue session logic already lives in the venue
(`webull/session_plan.ex`, `webull/signing.ex`, `robinhood/signing.ex`).

**And venue *resolution* is a sixth table.** `provider_registry.ex` maps name→module with a
hardcoded `@default_providers`, plus a second `"coinbase"`/`"gemini"` socket map at `:45`.
D1's shared namespace removes the need for both: `"coinbase"` → `DpExchange.Coinbase` is a
convention resolved with `Module.safe_concat/2`, so a new venue arrives without editing
anything host-side.

- **Selected**: the venue package owns its socket transport, its rate-limit enforcement,
  its credential/session handling, and its own supervision tree. The host sees one module
  per venue — `DpExchange.<Venue>` — with an identical surface across all five. See §6.0.
- **Options considered**: (a) host owns the transport and limiter, venues plug in;
  (b) host owns the mechanism, venues declare only the facts; (c) the venue owns
  the whole strategy behind an identical facade.
- **Rationale**: (a) and (b) both leave the host executing venue policy, which is why the
  host has six provider tables and why four venues had to route around them. Under (c)
  there is nothing for a host table to be wrong about: a venue that speaks MQTT, frame
  WebSocket, long-poll or gRPC is indistinguishable at the facade. It is the only option
  under which Success Criterion 5 — *a new venue with zero edits outside its own repo* —
  is actually true rather than aspirational. It also makes the conformance suite (§6.1)
  strictly more valuable, because the facade is the whole contract.
- **Trade-offs**, all accepted but none free:
  - **Coinbase's and Gemini's extraction gets materially bigger.** They are the two
    venues genuinely using the host's `Connection`/`ConnectionPool`, so their packages
    must absorb a socket lifecycle they do not have today. Phase 5's line count no longer
    describes Phase 5's work — see §2.
  - **The host's 5,139 lines of transport do not simply move.** Coinbase and Gemini each
    take what they need; the rest is deleted by whoever migrates the host. That deletion
    is out of scope here (§1), but it is the point of the exercise and should not be lost.
  - **Rate limiting scopes by venue, not by key**, so a host with many keys on one node
    under-uses each venue's capacity. Accepted (D5): the conservative error is the safe
    one, and a host that needs more throughput clusters.
  - Per-venue transports mean a bug fixed in one package is not fixed in the others. That
    is the honest cost of the position, and it is smaller than it looks: only Coinbase and
    Gemini would have shared the code anyway.

### D13 — Every venue package is built against the venue's own API documentation

Architect's decision, 2026-08-26. Generalises what D10 said only about Schwab.

**Every exchange in this family publishes real web API documentation**, and that — the
vendor's own documentation site — is what "the venue's documentation" means here. Most is
public; a few venues' is private (Schwab certainly) and the architect supplies those. No
venue package is ever built from the host's adapter alone.

**What does NOT count, and this is the specific trap.** Not a third-party SDK. Not a
client library on GitHub. Not a community write-up or a blog post. Not reverse-engineering
someone else's client. These tell you what *their author* concluded, which is a weaker
source than the host's own adapter — the adapter at least runs in production against the
venue. A third-party client can be stale, incomplete, aimed at a different region or
entity, or simply wrong, and nothing in it tells you which.

**The host paid for this lesson and wrote the receipt.**
`webull/websocket_provider.ex:113` records that its broker host constant was wrong twice
before it was right:

> *"This is the THIRD host these constants have held, and the first that came from the
> vendor's own streaming page. The previous two came from a third-party write-up
> (`push.webullbroker.com`) and from reverse-engineering their GitHub SDK
> (`usquotes-api.webullfintech.com`, which is the gRPC gateway — a different product).
> Both cost real time. The documentation states all of this plainly and should have been
> the first thing read."*

Note the sharpest part: reverse-engineering the SDK produced an endpoint for **a different
product entirely**, and there was no way to tell from the code itself. That is the failure
mode, not a slow lookup.

**Source hierarchy**, when two disagree:

1. **Live measurement** — what the venue does right now. Beats everything, and under
   **D21** every venue in scope is reachable directly, so rank 1 is always available.
2. **The venue's official web documentation** — what the venue says it does. The
   specification, and the only source for what exists but has not been probed.
3. **The host's adapter** — a prior reading of 1 and 2, valuable for production-learned
   behaviour that no document contains (why `FrameSender` exists, why `coverage/1` reports
   observed rather than intended).
4. **Third-party code and write-ups** — not a source. If something is only knowable this
   way, it is not yet known.

This follows directly from §0's "How to read the host app". If the host's adapter is the
only source, the package inherits whatever that adapter misunderstood about the venue, and
it inherits it permanently, into a public artifact.

**That is not hypothetical here.** `coinbase/provider.ex`'s own capabilities moduledoc
records probing the live endpoint on 2026-08-06 and finding `FOUR_HOUR` genuinely served
and *missing from the adapter's own enum map*, which had been silently substituting 1h —
so a caller asking Coinbase and Gemini for "4h" got real 4h from one and mislabelled 1h
from the other. The adapter was wrong about the venue; only the venue could say so.

- **Selected**: each venue repo carries `docs/reference/<venue>/` holding the API
  documentation it was built against, committed. Capabilities are derived from that
  documentation, then reconciled against the host adapter's behaviour, and every
  divergence is resolved explicitly rather than silently inheriting one side.
- **Options considered**: (a) port the host adapter and trust it, consulting docs only
  when something breaks — cheapest, and it is how the `FOUR_HOUR` bug survived; (b) build
  from documentation alone, ignoring the host — throws away real production knowledge that
  no API document contains (rate-limit behaviour under load, undocumented refusals, the
  incidents recorded in moduledocs); (c) both, with documentation as the tie-breaker.
- **Rationale**: (c). The host adapter and the venue's documentation each know something
  the other does not. The adapter carries measured production behaviour — the reason
  `FrameSender` exists, why `coverage/1` reports observed rather than intended. The
  documentation carries what the venue actually offers, including what the adapter never
  implemented or got wrong. Neither is sufficient; where they conflict the venue wins,
  because the venue is the thing being talked about.
- **Trade-offs**: every venue phase gains a reconciliation step, and it is real work rather
  than a formality — reading a venue's full API surface against an existing adapter is
  where the `FOUR_HOUR` class of finding turns up. That is the point, not the cost.
  Divergences found are recorded here and reported to the host team; fixing the host's
  adapter is out of scope (§1).
- **Committed, not linked**: a URL moves, a chat message is unsearchable, and neither
  survives into a public repo's history. What the package was built against must be
  readable by a stranger reviewing the package a year from now — including the architect,
  who will not remember which version of a venue's docs was current in August 2026.

### D14 — Three outbound channels: data, notices, telemetry

**Approved by the architect, 2026-08-27.** Naming and the telemetry boundary were
delegated to implementation; this records what was chosen so the contract is settled
before Phase 2 freezes it (D2).

**The facade has three outbound channels and no others:**

| Channel | Carries | Subscribe with |
|---|---|---|
| **Data** | `Core.Types.*` — what the venue says about the market | `subscribe/2` |
| **Notices** | What the **package** says about **itself**: link up/down, credentials rejected, sustained pressure, coverage change, catalog change, degradation | `subscribe_notices/1` |
| **Telemetry** | Measurement, under `[:dp_exchange, …]` | `:telemetry.attach/4` |

Module: `DpExchange.Core.Notice` for the struct and the vocabulary. Not `EventSink` — the
host's `EventSink` means the market-data conduit, and the two will be read side by side
through the whole migration; reusing the word for the opposite thing is how a reviewer
misreads both. Not `Events` for the same reason. "Notice" says what it is: something you
are told, which may need acting on.

**Why notices and telemetry are separate, and it is not taste.** Two mechanical reasons:

1. **`:telemetry` handlers execute in the emitting process.** A slow or raising handler runs
   inside the venue's request path, and `:telemetry` answers a raise by *detaching the
   handler* — a buggy metrics handler silently stops reporting. That is the right trade for
   a duration histogram. It is the wrong trade for "your API key was rejected", which is the
   one message that must never be quietly lost.
2. **Volume differs by orders of magnitude.** `request.start` / `request.stop` fire on every
   HTTP call, thousands a minute. `credentials_rejected` fires approximately never. On one
   stream the rare important thing lives inside the firehose, and no one builds a reliable
   alert on that.

**The rule for which is which**: *telemetry is measurement you aggregate; a notice is a
condition you act on.* Applied to the existing nine (§5.2):

| Today | Becomes |
|---|---|
| `request.{start,stop,exception}` | telemetry, unchanged |
| `rate_limit.acquire` | telemetry, unchanged |
| `rate_limit.hit` | **both** — each event is a metric; sustained limiting is a notice. The venue sets its own threshold for "sustained", because only it knows its ceiling (D5) |
| `ws.{connect,disconnect,reconnect_attempt}` | **notices**, renamed `[:dp_exchange, :link, …]` |
| `ws.message` | telemetry, renamed `link.event` — or dropped in favour of coverage reporting |

The `ws.*` renames are not cosmetic: those four names announce the transport, which §6.0
forbids, and Robinhood (polls) and Webull (MQTT) **cannot honestly emit them at all**, so
the spec as written is unimplementable for two of six venues.

- **Trade-offs**: three channels is more surface than two, and the overlap at
  `rate_limit.hit` is real rather than tidy. Accepted, because collapsing notices into
  telemetry puts a must-not-lose message on a lossy path, and collapsing telemetry into
  notices forces every metrics consumer through a subscription it does not want.
- **Contract, not implementation**: this fixes what a *consumer* sees. Core may perfectly
  well emit notices on top of `:telemetry` internally and ship a bridge that forwards to a
  subscriber — `send/2` is cheap and non-blocking, so the handler-in-process objection
  disappears when the handler only forwards. Whether it does is Core's business and does


### D15 — Published experimental, and it says so everywhere

These go to public hexpm from the first publish (D4), long before anything has been
battle-tested. **Every package is marked EXPERIMENTAL until it earns otherwise**, in a way
a stranger cannot miss.

This is the honest cost of D2 and D3: Core must be published before venue #1 can build
against it, and no path deps means published-or-nothing. So the packages become public at
their least mature. The choice is between publishing quietly and letting people discover
the maturity for themselves, or publishing loudly and saying what they are. This plan says
what they are.

**Where the label goes.** Version alone is not enough — `0.x` is widely ignored, and D4's
auto-publish means the patch number climbs on every merge, so `0.4.17` reads as progress
rather than immaturity. Five places, all of them:

1. **README, first line, above everything.** A blockquote, not a footnote.
2. **The Hex `description:`** — prefixed `EXPERIMENTAL —`. This is what shows in hexpm
   search results and on the package page, which is where most people meet it and where
   many stop.
3. **The `DpExchange` moduledoc** (D1) and each venue's facade moduledoc — these are the
   HexDocs landing pages.
4. **`CHANGELOG.md`**, stating the status at the top rather than only per-release, and
   carrying the evidence whenever an endpoint moves to `:proven`.
5. **`capabilities/0` itself** — machine-readable, per endpoint, so a consumer can branch
   on the specific call it depends on rather than on the package banner. This is the one
   that keeps working after someone stops reading READMEs.

**What the label must actually say**, because "experimental" alone is a mood rather than
information. It states: the API may change without a major version while `0.x`; it has not
run in production anywhere; the conformance suite passes against a fake the authors wrote
and against public endpoints (D7 tiers 1–2), but order placement and authenticated flows
are thinly covered (tiers 3–4); and it points at the issue template for reporting
divergences. **A consumer should be able to decide against using it from the README alone.**

**Maturity is per endpoint, not per package.** A package-wide flag is too coarse in both
directions. Some endpoints stay unproven long after the venue is trading live — the host
may never call `get_transfers/2` on a venue it trades on daily. And a venue that adds
functionality later (staking, options, a new order type) gets a *new* unproven
endpoint inside an otherwise proven package. A single flag cannot say either thing.

So maturity extends `capabilities/0`, which already declares which endpoints are active
(§6.0). The activation map becomes three-state rather than two:

| State | Meaning | Facade behaviour |
|---|---|---|
| `:proven` | Exercised in production by a real consumer against the live venue | Works |
| `:experimental` | Implemented, passes the contract suite, never proven in production | Works, and says it does not know |
| `:unsupported` | The venue does not offer it | `{:error, :not_supported}` |

**`:experimental` is the default.** Nothing is `:proven` because someone implemented it
carefully; it is proven because it ran. Anything new — a new package, a new endpoint in an
old package, an endpoint whose venue changed underneath it — starts back at
`:experimental` and earns its way out individually.

This makes the package-level label a **derived** value rather than a second thing to
maintain: the package is experimental while any endpoint in its **core set** (§6.0) is —
the endpoints that are both irreplaceable and load-bearing. Peripheral endpoints carry
their own marks and never block. It also gives a consumer something better than a banner —
they can ask `capabilities/0` whether the specific call they depend on is proven, and
branch on the answer rather than the package's overall mood. That is the same principle as
O0: decide from the declaration, not from what you happen to know about the venue.

**Who sets `:proven`, and on what evidence.** The package maintainer, on evidence of
production use, recorded in the `CHANGELOG` entry that makes the change. It is a claim, not
a measurement, and the plan should not pretend otherwise — but it is an auditable claim
with a date and a reason attached, which is the most this can honestly be. What it must
never be is a default, or a blanket flip applied to reduce noise.

**The evidence is already being emitted.** `[:dp_exchange, :request, :stop]` carries
`endpoint:` in its metadata (§5.2), so a consumer running in production is continuously
producing the exact list of endpoints it has actually exercised. Graduation does not depend
on anyone remembering what they called — it depends on reading it back. Core's obligation
here is small but real: keep `endpoint:` in that metadata precise enough to map onto facade
functions, because the telemetry spec freezes at Phase 2 (D2) and this is one of the things
it is quietly for.

The host also already has the surface to *ask*: `get_execution_orders` for what actually
traded, and `describe_exchange`, which reads `capabilities/0` and so answers "which
endpoints are proven?" for free once that field is three-state (§0).

**This adds a maintenance surface, and that is accepted.** Every endpoint carries a state
someone has to move. Three things make it bearable:

- **It is front-loaded and then rare.** The first live venue graduates a large batch at
  once; after that, changes are occasional — a new endpoint, a venue that changed, a
  package that regressed.
- **Graduation is naturally batched, and batched is not the same as blanket.** When the
  host goes live on a venue it exercises many endpoints in one event, and marking all of
  them proven from one body of evidence is exactly right. What the rule above forbids is
  flipping states with *no* evidence — not flipping many with one.
- **The cost is remembering, not doing.** The edit is one declaration and one CHANGELOG
  line. Pairing it with the telemetry read above is what turns it from a thing to remember
  into a thing to look up.

**The package-level exit criterion, per venue.** A package stops being experimental when
`dp_crypto_management` has, on that venue, **exercised its whole core set (§6.0) in
production** — which, for any venue where `supports_trading` is active, necessarily
includes **live trading**, since `place_order/3` and its group are core and nothing but
trading proves them. That is why the criterion is one requirement rather than two: live
trading is not an extra hurdle, it is what proving the core set means on a venue that
trades. Peripheral endpoints keep their own marks indefinitely and never block — that is
the honest answer rather than a gap.

**This is D7's tier 4, arriving by the only route that was ever open to it.** D7 records
that verifying order placement means placing orders — real money, irreversible, on venues
that do not distinguish a test from a trade — and leaves tier 4 deliberately unsolved as a
*testing* problem. It is solved as a *production* problem instead: the host trades live,
and that is the coverage. "Battle-tested" has never meant anything else.

**No package in scope is known-ungraduatable.** This used to be false: binance and kraken
were both in the family and neither could ever reach tier 3 or 4, because the architect can
hold an account on neither. **D21 removes both from the plan** rather than shipping two
packages whose EXPERIMENTAL label could never come off. Everything that remains — coinbase,
gemini, webull, robinhood, schwab — is a venue the host can trade on, so every package here
has a route out of EXPERIMENTAL and D15's rule is a schedule rather than a permanent state.

What that removes from this plan, beyond two packages: the VPN-measurement trap (a
measurement taken through a VPN is a measurement of Binance-as-seen-from-whatever-region
that VPN exits, and nothing in the response says which), the unresolved question of which
Binance entity a package named `dp_exchange_binance` even *is*, and the dependency on
finding an outside party before anything could graduate. All three are written up in
`docs/design/ideas/binance-and-kraken-packages.md`, which is where they get solved if these
venues are ever picked up.

`docs/design/ideas/external-experimental-feedback.md` survives that removal and gets
sharper: it is no longer a prerequisite for this plan finishing, it is the mechanism by
which a deferred venue could come back.

Three further consequences worth stating rather than discovering:

- **Packages graduate independently and at different times.** Whichever venue the host
  trades on first graduates first. That is correct — the evidence is per venue, so the
  label is too.
- **Graduation is evidence, not age.** A package that has existed for a year without anyone
  trading through it is exactly as unproven as one published yesterday, and the label
  should say so.
- **The label outlives this plan.** The host migration is out of scope (§1), so Phase 8
  closes the extraction, not the experiment, and must not quietly drop the marker.
  Removing it is a separate, deliberate act by whoever owns the package once the host is
  live and fully exercising it.

- **Trade-offs**: a loud EXPERIMENTAL banner costs adoption, and adoption is what produces
  the external reports that make a package good. Accepted, and it is the right way round —
  an early user who was told plainly and chose to try it is a collaborator; one who assumed
  maturity and got bitten is a bug report the org never receives and a reputation it does
  not recover. Note this is a claim about honesty, not caution: the packages should still


### D16 — The two repos talk through GitHub issues

Architect's decision, 2026-08-27. The host migration is out of scope (§1), which is only
honest if there is a defined hand-off rather than a shrug. There is: **GitHub issues, in
both directions.**

**Outbound — the adoption issue.** Once Core and Coinbase are published and green (end of
Phase 5), an issue goes on `DistortionPoint/dp_crypto_management` describing how to adopt
them. That issue is this project's deliverable *to* the host, and writing it is in scope
even though acting on it is not. It should carry:

- what the host replaces — `connectors/exchanges/{core,coinbase}/`, and which of the six
  provider tables (D12) stop being needed;
- what the host must build: the glue that receives from `subscribe/2` and publishes to its
  own `Events.*` (§5.4), and a subscriber for the notices channel (D14);
- what it must *stop* doing: starting venue sockets, sharding pairs, holding venue
  rate-limit config;
- the facade's whole surface (§6.0), so the work can be scoped without reading the package;
- **the host SHA the extraction was pinned to** (D19), so the host team can say what landed
  in that subtree after it.
- **the behaviour deltas** (Phase 5.9) — every way the package differs from the adapter it
  replaces, gathered while porting the host's own tests against it. This is the section the
  host will actually work from: its 4,582 LOC of Coinbase tests are precisely what those
  changes break, so the list doubles as the migration's task list.

**It is input to *their* plan, not a substitute for one.** The host runs Document Driven
Design (§0) and will write its own design doc for the replacement, working it as the
primary task at the time. So the issue's job is to give that doc everything it needs to be
written — scope, surface, deltas, what stops being needed — and then get out of the way.
Sequencing, phasing and rollout are theirs to decide, not ours to prescribe.


**Inbound — bug issues.** When the host finds a problem it opens an issue on the package
repo. This is the influx-elixir loop formalised: those 13 `Client.Local` reports (D7) were
markdown files inside the host's own `docs/bugs/fixed/`, which worked because reporter and
maintainer were the same person, and was invisible to anyone else. Issues on the package
repo are discoverable, and once these are public they are the same channel a third party
would use.

**An issue is a report, not an instruction** (D18). We own the code, so triage decides
whether it is a package defect — which we fix — or a consumer using the facade wrongly,
which we answer with documentation or a `usage-rules/` change. Both are useful outcomes.
What the flow must not become is the host dictating behaviour to a package it no longer
owns.

**Which repo gets the issue**, because guessing wastes a round trip:

| Symptom | Repo |
|---|---|
| The contract is wrong, missing, or ambiguous; the conformance suite is | `dp-exchange-core` |
| A venue's behaviour, signing, symbols, catalog, capability declaration | that venue's repo |
| Unclear which | Core, and move it — Core owns the contract (D1) and is the better default |

**Two properties worth stating:**

- **This is what starts D15's clock.** A package graduates on production use, and the host
  cannot produce production use until it adopts. The adoption issue is not administrative
  tidying — it is the first step of the only path any package has out of experimental.
- **It is a different case from the idea doc.** `external-experimental-feedback.md` is
  about a stranger with venue accounts we do not have. This is the host team, on venues
  they already run, with credentials they already hold. It needs no design work — it needs
  an issue.

A bug-report template in each repo's `.github/` is worth having for the shape (package
version, facade call, expected vs actual, redacted), and is the light version of what the


### D17 — Every commit is a public commit

Architect's decision, 2026-08-27. **`.gitignore` is verified before any commit that
introduces a new kind of file, and the working tree is checked for secrets before every
commit.** Not before publishing — before committing.

**The reason is D4.** These repos are private now and public later, and the architect flips
them one at a time before each first publish. Making a repo public exposes its **entire
history**: a credential committed in week one and removed in week two is still there, in a
repo anyone can clone, forever. So the private period offers no protection at all — it only
delays discovery. Every commit made while private is a commit made to a future public repo,
and the only workable posture is to treat it that way from commit #1.

**The surfaces that actually matter here**, rather than generic advice. The convention
itself is §7.7:

| Surface | Why it is live for *these* packages |
|---|---|
| `.mcp.json` | Carries a bearer token. The host ignores its own at `.gitignore:256`; ours must too, from the first commit (§7.1) |
| `.env*` | **The only place any secret lives** (§7.7). `.gitignore` is `.env*` with `!.env.sample` — the sample is the one committed file and carries placeholders only |
| `config/*.exs` | Not a secrets surface at all, and must never become one. No literal secret goes in any committed source file (§7.7) |
| **Recorded fixtures** | The sharpest risk and the least obvious. Tier-2 and tier-3 runs hit real venues; anything captured from them can carry auth headers, account identifiers, order IDs and balances. A fixture is not safe merely because the test that made it passed |
| `docs/reference/<venue>/` | D13 commits vendor documentation. Vendor docs contain example keys — usually fake, occasionally not. Read before committing, per D13's "read the complete file" instinct |
| `.claude/settings.local.json` | Local paths and configuration; the reference repos keep it out of the tracked set |

**Defence is layered, because any single layer will eventually be bypassed:**

1. **`.gitignore`, correct from commit #1** — influx-elixir's baseline plus `.mcp.json`,
   and the `.env*` / `!.env.sample` pair from §7.7. Not
   `config/*.secret.exs` — that is host-gitignore legacy, not the convention.
2. **GitHub secret scanning with push protection** — the layer that catches what
   `.gitignore` missed. It is one of only two governance additions this family makes beyond
   influx-elixir (D9). Enable it *before* the repo goes public, not after.
3. **`mix hex.build` inspection** (Phase 4.2) — catches what reaches the tarball, which is
   a different set from what reaches the repo.
4. **Absolute rule 6** — never commit or push without confirmation. That confirmation is
   the moment to look, and D17 is what to look at.

**If a secret does land in history, the repo does not go public.** Rotate the credential
first, then decide whether to rewrite history or abandon the repo and re-create it. Neither
is cheap, which is the point of the four layers above.


### D18 — We own this code; the host becomes a consumer

Architect's decision, 2026-08-27. Stated because the plan has been carrying it implicitly
and the implication is larger than it looks.

**After extraction, authority over this code moves.** These packages are not a copy of the
host's adapters kept in sync with them — they are the code, and `dp_crypto_management` is a
consumer of it, alongside whatever third parties arrive later (D4). The package decides how
it works. The consumer conforms.

**What follows from that, concretely:**

- **When we find a bug, we fix it.** Not "fix it if the host agrees" and not "preserve the
  behaviour the host relies on." The correct behaviour is the package's to define — the
  four `HostRateLimiter` defects (D-E) are the model: the host's implementation is evidence
  about what a venue does, never authority about what the contract *should* be.
- **A consumer may have to adjust.** The facade exists to minimise that (D12) and it will
  minimise it a great deal — mechanism changes behind it are invisible. But it cannot
  reduce it to zero: fixing a wrong return type, a wrong ceiling, a silently-swallowed
  error changes what a caller sees, and that is the point of fixing it.
- **The host's tests do not constrain us.** They are a behavioural baseline (Appendix A)
  and an excellent one, but a test asserting today's wrong behaviour is a test that changes.
  Phase 5.9's delta list exists precisely to make those visible rather than surprising.
- **Disagreement resolves in the package's favour.** A consumer who dislikes a decision can
  pin an old version, open an issue (D16), or fork. What they cannot do is require the
  package to keep a defect.

**This is not licence to break things casually**, and the reverse obligation is real: we
own the consequences too. Every behaviour change is written down (Phase 5.9), lands in a
`CHANGELOG` entry, and reaches the host as an issue (D16). Ownership means deciding, and
then doing the work of telling people.

**The versioning consequence, and how it is handled.** If we can change behaviour,
consumers need a signal. Two mechanisms, both settled:

1. **Consumers pin at the minor** — `{:dp_exchange_core, "~> 0.1.0"}`, which is
   `>= 0.1.0 and < 0.2.0`. **Not `~> 0.1`**, which in Hex means `< 1.0.0` and would let a
   venue silently accept any 0.x, including a deliberately breaking one. The host's own
   precedent is the tighter form: it pins `{:influx_elixir, "~> 0.1.0"}`.
2. **A breaking change is signalled by hand-editing `@version`** in the commit that makes
   it. CI increments the last segment of whatever it finds in `mix.exs`, so setting
   `0.2.0` makes the next release `0.2.1` regardless of what was published before (§7.3).
   No CI change was needed — the capability already existed and was undocumented.

Together those mean a break is both **announced** and **opted into**: we move the minor,
and the consumer does not receive it until they edit their own `mix.exs`.


### D19 — The source is a moving target; pin every extraction to a commit

Architect's decision, 2026-08-27. `dp_crypto_management` is in active development. It is
not *working on* exchange code, but it finds bugs there and fixes them — in its own way, on
its own schedule, while the extraction is in flight.

**This is not a theoretical risk. Measured 2026-08-27, over the preceding 90 days:**

| Subtree | Commits | Last touched |
|---|---:|---|
| webull | 78 | 2026-08-20 |
| gemini | 44 | 2026-08-20 |
| core | 38 | 2026-08-20 |
| coinbase | 32 | 2026-08-24 |
| robinhood | 24 | 2026-08-12 |
| kraken | 20 | 2026-08-24 |
| binance | 18 | 2026-08-24 |
| **`exchanges/` total** | **141** | **3 days ago** |

Roughly 1.5 commits a day into the exact tree being extracted, and not cosmetic ones:
*"fix(webull): renew subscriptions on a timer — coverage 47 → ~200 symbols"*,
*"fix(websocket): close_connection closed nothing and logged that it succeeded"*,
*"fix(webull): retry a subscribe the venue rejects as INVALID_SESSION"*. Extracting Webull
two weeks before that first one lands ships a package that streams 47 symbols where the
host streams 200 — a defect we introduced by copying at the wrong moment, invisible to
every test we would have ported alongside it.

**And the on-disk source is ahead of the commits.** The host directory is live development:
what is on disk is what the host is running, committed or not. Measured at the same moment
as the table above — **12 modified files in `exchanges/`, 867 insertions and 129 deletions
uncommitted**, including **four of Coinbase's five**. `coinbase/provider.ex` is 1,508 lines
on disk against 1,482 at `HEAD`.

Two consequences, and the second is the one that bites:

- **Every measurement in this plan describes a working tree, not a commit.** The file counts
  and LOC in §3.1 and Appendix A, the call-site counts in §5.5, the capability values —
  all read from disk on 2026-08-26/27 with those changes present. They are accurate about
  what the host is running and do not correspond to any SHA.
- **A commit-only diff would miss exactly the changes already in front of you.** Pin at
  `HEAD`, copy from a dirty tree, and `git log <sha>..HEAD` later shows the uncommitted work
  as though it arrived after the extraction — when in fact it was already captured. The
  reverse is worse: uncommitted work that is later reverted or reworked leaves the package
  carrying code that never existed in the host's history at all.

**So each extraction is pinned to a commit *and* a tree state:**

- **Record the host SHA and whether the subtree was dirty**, in `docs/reference/<venue>/`
  alongside the vendor documentation (D13) — already the place that answers "what was this
  built against". If dirty, save the diff too: `git diff -- <subtree>` is a few hundred
  lines and is the only record of what was actually copied.
- **The host will commit before extraction starts**, and its replacement will run as its
  own plan (§0's Document Driven Design), as the primary thing it is working on at the
  time. So a clean tree is the expected case and the SHA is usually sufficient; the diff
  capture above is the fallback for extracting mid-flight, not the norm.
- **Diff before publishing**, against both: `git log <sha>..HEAD -- <subtree>` for what was
  committed since, and `git diff` for what is uncommitted now. Triage every entry — already
  reflected, or a gap. This is a Phase 5/6 step, not a nicety.
- **State the SHA and the tree state in the adoption issue** (D16). The host team then knows
  exactly what was captured, including that it may not match any commit they can check out.

**A host-side fix is evidence, not an instruction** (§0, D18). It tells us the venue does
something we had wrong — which is valuable and often definitive. It does not tell us how
the package should fix it: the host may have patched around its own architecture in a way
the facade makes unnecessary. Read the fix, take the finding, decide the remedy.

**The exposure window is bounded but uneven.** Drift on a subtree effectively stops when
the host **starts its replacement plan** for that venue — not when adoption finishes. From
that point it is changing the code to *use* the package rather than to patch the adapter,
so the old subtree stops accumulating fixes we would have to chase. The risk lives in the
gap between our extraction and their plan starting, which is exactly the gap the adoption
issue (D16) exists to close.

That gap is longest for the venues extracted last. Webull is the sharpest case: highest
churn in the family at 78 commits, adopted second-to-last under D11's order, and the
thinnest baseline to catch a miss with (Appendix A, 879 LOC of tests). Budget for that
rather than discovering it.

### D20 — Core ships no venue-specific dependency; transport lives in the venue

- **Selected**: Core ships neither `FrameSender` nor `WebSocketProviderBehaviour`, and
  `websockex` appears in no Core dependency list — not as a hard dep, not as
  `optional: true`. **Each venue package that speaks WebSocket ships what it needs to
  speak it**, including its own `websockex`.
- **Options considered**: (a) as selected; (b) Core ships both as optional helpers with
  `{:websockex, "~> 0.4", optional: true}`; (c) a companion `dp_exchange_websocket`
  package for the four frame-WS venues.
- **Rationale**: the rule is more general than transport. **Core ships nothing that drags
  in a venue-specific dependency.** `websockex` is a venue's choice of wire library, not
  a family-wide fact: Robinhood polls and never opens a socket, Schwab's transport is
  unknown until §10's documentation arrives, and Webull uses `websockex` for MQTT packet
  framing that shares nothing with the other four but the dependency's name (D12's
  transport table). That is four users of a genuinely-common mechanism, two non-users,
  and one coincidence.
  Option (b) fails on the same ground D12 rests on: an `optional: true` dep still puts
  transport in Core's `mix.exs` and its published docs, which is the one message the
  facade exists to prevent Core from sending. Option (c) is rejected on maintenance, not
  on aesthetics or on the amount of duplication — see the next point, which is the
  load-bearing one.
- **`FrameSender`'s incident becomes a moduledoc, not a module.** The reason that file
  exists is a measured fact — `WebSockex.send_frame/2` is `:gen.call` with a hard 5000ms
  timeout that **exits** rather than returning, killing the calling connection process,
  and subscribes are idempotent on every venue so a duplicate is harmless where a lost
  connection is not. Under D20 that fact is preserved by writing it down where it will be
  read. **Coinbase is venue #1 (D11) and writes the guard first**, with the incident
  recorded in full in its moduledoc. **Gemini copies the module *and its moduledoc***, and
  under **D21** that is the whole list — coinbase and gemini are the only frame-WebSocket
  venues left in scope. Copying is the intended outcome, not the compromise: D12 already
  accepted duplication where the mechanism is only accidentally the same, and two venues
  that each own their guard can each change it without a cross-package negotiation.
- **A shared transport package is not deferred — it is refused, permanently, and the
  duplication count is not why** (architect, 2026-08-27). There will never be enough
  venues *we* maintain for the duplication to matter. Third parties may well add venues,
  and that is the point of publishing — but **a third party writing `dp_exchange_foo` gets
  worse off under option (c), and so do we.** They inherit a dependency they did not
  choose, on a module they cannot change, whose release cycle is ours. And we acquire a
  package that every future venue in the family — including ones we did not write and
  cannot test — depends on, which means we can no longer change it, and every one of their
  bugs arrives at our issue tracker first.

  That inverts the usual argument for centralising. Normally more consumers justify a
  shared module; here more consumers make it strictly worse, because the maintainer is one
  person and the consumers are strangers. **The only thing we own that anyone else has to
  depend on is the contract**, which is what `dp_exchange_core` *is* (D8, §6.0). A second
  shared package would be a second thing we owe everybody, bought with a mechanism that is
  83 lines long.

  So: no reconsider-trigger, no threshold, no fifth-venue rule. **`dp_exchange_websocket`
  is not on the table now or later.** If a fix to one venue's guard is worth having in
  another, someone copies it across — the same way the venue got it in the first place.

- **What the copies actually risk, and what bounds it**: two copies can drift, and a fix
  found in one does not reach the other by itself. The incident travels *with* the copy, so
  the next reader of either learns why the guard is there — which is the failure mode that
  actually bites. Divergent line counts are not a failure mode.
- **Consequences**: no ninth repo. `websockex` leaves §7.2's Core list at every strength.
  §5.1 loses two rows. D-B is resolved by non-extraction. Phase 1.6 and 1.7 are unblocked,
  and Phase 1 no longer has a transport task at all. `provider_behaviour.ex`'s ~300 LOC
  and `frame_sender.ex`'s 83 LOC drop out of Core's extraction budget and into venue
  budgets, where the coverage threshold (D3) applies to them just the same.

### D21 — Binance and Kraken are out of scope; the names stay reserved

- **Selected**: neither venue is extracted by this plan. The `dp-exchange-binance` and
  `dp-exchange-kraken` repos stay empty and stay ours, the hexpm names stay reserved, and
  everything already known about both is written up in
  `docs/design/ideas/binance-and-kraken-packages.md`. **The family this plan ships is six
  packages**: core, coinbase, gemini, webull, robinhood, schwab.
- **Options considered**: (a) as selected; (b) extract both anyway and publish them
  EXPERIMENTAL indefinitely, letting the label carry the honesty; (c) extract kraken only,
  since its public API is directly reachable, and defer binance.
- **Rationale**: **the architect can hold an account on neither venue**, so under D15
  neither can ever graduate — not "has not yet", *cannot*. The host's own architecture doc
  says so for one of them (`exchange-capabilities.md`, "Excluded Exchanges": *"Binance /
  Binance.US — Not available to Texas residents"*), and both adapters declare
  `auto_collect: false` where the other four declare `true`. Option (b) was the tempting
  one and fails on D18: we own what we extract, and owning two packages we can never verify
  past tier 2 is a maintenance liability with no counterweight — two more versions to
  coordinate, two more drift-checks against a moving host (D19), two more sets of issues to
  answer, and no route to ever proving any of it works. Option (c) is genuinely closer —
  Kraken's public API answers directly and the host has already measured it (1,430 pairs,
  1,410 online, 22 quotes, `/0/public/AssetPairs`, 2026-08-05) — but it buys one package
  that still stops at tier 2, in exchange for keeping a venue in the plan that no one is
  going to trade on. The deferral is not a judgement about the code; it is that neither
  venue can be *finished*.
- **The names stay reserved.** Reserving what is planned or lives in an idea doc is the
  existing rule (D10); the idea doc is what makes these qualify. Reserving costs one
  placeholder publish each and stops someone else taking `dp_exchange_kraken` in a family
  where every other name is ours.
- **If either is picked up later, package identity is the legal entity, not the brand.**
  `api.binance.com` and `api.binance.us` are different companies with different listings
  and fee schedules, so they are different packages with different names — a package called
  `dp_exchange_binance` that talks to Binance.US is mislabelled, and a configurable base URL
  just pushes the entity question onto every consumer. The line: **a separate package when
  it is a separate legal entity with its own listings, fees and account**, not merely a
  separate hostname. Spot versus futures on one account is a capability question inside one
  package. Recorded in the idea doc, not decided here.
- **Consequences**: D11's order loses its third group and drops to five venues. Phase 6
  goes from six venues to three. **OQ26 closes without being answered** — it asked which
  Binance entity the package targets, and there is no package. D15 stops having permanent
  exceptions. Of the venues left, only coinbase and gemini speak frame WebSocket, which
  makes D20's rejection of a shared transport package stronger, not weaker. The host keeps
  its own binance and kraken adapters; under D18 we never take ownership of code we do not
  extract, and D16's issue channel is where that gets said out loud.

---

## 5. `dp_exchange_core` — Package Specification

### 5.1 Module inventory

Source: `../dp_crypto_management/lib/dp_crypto_management/connectors/exchanges/core/`
(19 files, 2,795 LOC) plus one misfiled module (D-B).

| Source file | LOC | New module | Action |
|---|---:|---|---|
| `data_provider.ex` | 574 | `DpExchange.Core.DataProvider` | rename only |
| `capabilities.ex` | 285 | `DpExchange.Core.Capabilities` | rename only |
| `http_client.ex` | 615 | `DpExchange.Core.HttpClient` | **rework** — §5.3, §5.5 |
| `event_sink.ex` | 90 | `DpExchange.Core.Notice` (D14) | **inverted** — does not carry market data; becomes the package's notices channel. §5.4, D6 |
| `polling_feed.ex` | 351 | `DpExchange.Core.PollingFeed` | rename only |
| `feed_behaviour.ex` | 124 | `DpExchange.Core.FeedBehaviour` | rename only |
| `instrument.ex` | 113 | `DpExchange.Core.Instrument` | rename only |
| `canonical_pair.ex` | 104 | `DpExchange.Core.CanonicalPair` | rename only |
| `timeframe.ex` | 97 | `DpExchange.Core.Timeframe` | rename only |
| `frame_sender.ex` | 83 | — | **does not move (D20).** Venue-owned; coinbase writes it first (D11) and carries the incident moduledoc |
| `rate_limit_behaviour.ex` | 78 | `DpExchange.Core.RateLimitBehaviour` | drop `use Boundary` |
| `telemetry.ex` | 61 | `DpExchange.Core.Telemetry` | rename only |
| `symbol_normalizer.ex` | 31 | `DpExchange.Core.SymbolNormalizer` | rename only |
| `types/order.ex` | 62 | `DpExchange.Core.Types.Order` | rename only |
| `types/fill.ex` | 40 | `DpExchange.Core.Types.Fill` | rename only |
| `types/order_book.ex` | 27 | `DpExchange.Core.Types.OrderBook` | rename only |
| `types/quote.ex` | 21 | `DpExchange.Core.Types.Quote` | rename only |
| `types/trade.ex` | 21 | `DpExchange.Core.Types.Trade` | rename only |
| `types/balance.ex` | 18 | `DpExchange.Core.Types.Balance` | rename only |
| `../websocket/provider_behaviour.ex` | ~300 | — | **does not move (D20).** Written for the host's `Connection`, which D12 deletes; venues copy the shape inward |
| — | — | `DpExchange.Core.DefaultRateLimiter` | **NEW** (D-A) |
| — | — | `DpExchange.Core.AdapterContract` | **NEW** (§6.1) |
| — | — | `DpExchange.Core.Notice` | **NEW** (§5.4, D14) — the notices channel |
| — | — | `DpExchange` | **NEW** (D1) — the namespace root Core owns: family documentation, the venue list |
| — | — | `DpExchange.Core.Config` | **NEW** (§7.8) — the process-scoped resolver every configurable seam goes through |

"Rename only" means the namespace sed plus whatever `alias` lines follow from it. The
moduledocs on these modules are unusually valuable — several encode measured production
incidents (`Timeframe`'s fabricated-candle bug of 2026-08-06, `FrameSender`'s 5s
`:gen.call` exit, `PollingFeed`'s ciphertext-credential silent failure, `Capabilities`'
Gemini/Coinbase channel mis-routing). **Preserve them.** Strip only host-specific
cross-references (e.g. links to `docs/design/2026-06-30_...` in the host repo) and
replace with the equivalent statement of fact.

### 5.2 The public surface, as it stands today

**`Core.DataProvider`** — the one provider contract. Required callbacks:
`get_price/2`, `get_historical_prices/4`, `get_balances/2`, `get_symbols/1`,
`test_connection/2`, `get_rate_limit_status/2`, `provider_name/0`, `runtime_id/0`,
`asset_classes/0`, `supported_features/0`, `capabilities/0`, `place_order/3`,
`cancel_order/3`, `get_order/3`, `get_orders/2`, `get_order_book/2`,
`get_trade_history/2`, `get_accounts/2`, `get_fees/2`.
Optional: `get_transfers/2`, `list_instruments/1`, `get_historical_price/4`,
`quantization/1`, `get_market_overview/1`.
Types: `price_data`, `balance_data`, `credentials`, `rate_limit_info`, `order_data`,
`order_request`, `quantization`, `market_overview_entry`, `asset_class :: :crypto | :equity`.

**`Core.Capabilities`** — `@enforce_keys` struct + `new/1` with raising validation.
Enforced: `requires_credentials_for_public_data`, `has_rest_order_book`,
`has_rest_historical_candles`, `supports_short_selling`, `reports_trade_volume`,
`default_quotes`, `supported_quotes`.
Defaulted: `has_historical_price: false`, `auto_collect: false`, `historical_timeframes: []`,
`max_candles_per_request: nil`, `has_websocket: false`, `websocket_module: nil`,
`authenticated_channels: []`, `stream_channels: []`, `pairs_per_socket: nil`,
`feed_module: nil`, `overview_suits_collection: true`.
Validations that **raise** at definition time: `auto_collect: true` requires non-empty
`default_quotes`; `default_quotes` must be a subset of `supported_quotes`;
`has_rest_historical_candles: true` requires non-empty `historical_timeframes`; every
declared timeframe must be in `Timeframe.known/0`.

**`Core.SymbolNormalizer`** — 2 callbacks, `to_canonical_symbol/1` and
`to_exchange_symbol/1`. Both total, never raise; malformed inbound degrades to `"UNKNOWN"`.

**`Core.CanonicalPair`** — `to_canonical/2` and `to_exchange/2` over a per-venue
`mapping :: %{sep: String.t(), quotes: [String.t()], asset_aliases: %{String.t() => String.t()}}`.
Canonical form is `BASE-QUOTE`, uppercase, dash. `quotes` must be **longest-first**.
Invariant: `to_canonical(m, to_exchange(m, p)) == p` for every pair.

**`Core.Timeframe`** — vocabulary `1m 5m 15m 30m 1h 2h 4h 6h 12h 1d`. `seconds/1`
returns `{:ok, n} | :error` (never a default — a wrong width mis-buckets silently).
`known/0`, `aligned?/2`, `boundary/2`. Unknown timeframes are `aligned?/2 == true`
("no rule" must not read as "invalid").

**`Core.Instrument`** — `%Instrument{symbol, base, quote, instrument, status}`.
`instrument_type :: :spot | :perp | :unknown`, `status :: :tradable | :delisted | :unknown`.
`new/1`, `instrument_from/1`, `status_from/1`. Unrecognised input is `:unknown`, never
`:spot` — a new contract type must never be silently admitted to a spot-only fleet.

**`Core.Types.*`** — 6 `@enforce_keys` structs. All use `Decimal` for numbers, `DateTime`
for times, `atom() | String.t()` for `:provider`. Only stdlib + `Decimal`.

**Timestamps are whatever the venue gives.** `Quote`, `Trade`, `Fill` and `OrderBook`
already enforce `:timestamp`; `Order` carries `:created_at`/`:updated_at`. The value is the
venue's own, used as-is — no normalisation, no substitution, no inventing a semantic the
venue did not supply. Where a venue gives none, it is our observation time, and that is the
honest best answer to "when was this true".

**`Balance` gains a timestamp, meaning "when we asked".** It is the only one of the six
without one today. A balance has no venue event time — it is a snapshot — so its timestamp
is the moment we requested it, and that *is* its freshness. This is what lets a caller
reason about staleness on the one type where the answer is otherwise unknowable.

**`Core.Telemetry`** — `event_prefixes/0` returning 9 documented names under
`[:dp_exchange, …]`: `request.{start,stop,exception}`, `rate_limit.{hit,acquire}`,
`ws.{connect,disconnect,message,reconnect_attempt}`.

`request.stop`'s `endpoint:` metadata has a second job beyond metrics: it is the evidence
a consumer uses to graduate endpoints from `:experimental` to `:proven` (D15). Keep it
precise enough to map onto facade functions — the spec freezes at Phase 2 (D2).

**Four of those nine leak transport and must be renamed** (§6.0). A consumer attaching to
`[:dp_exchange, :ws, :connect]` learns the venue speaks WebSocket, which is exactly the
knowledge the facade exists to withhold — and worse, Robinhood (polls) and Webull (MQTT)
cannot honestly emit them at all, so the spec is unimplementable for two of six venues as
written. The category is the venue **link**, not the wire under it:
`[:dp_exchange, :link, :up | :down | :reconnect_attempt]`, with `:message` becoming a
transport-neutral `[:dp_exchange, :link, :event]` or dropping in favour of the operational
channel's coverage reporting. The names are cheap to fix now and permanent after Phase 4
(D4). Settled in D14.

**`FrameSender` is not a Core module (D20)** — but the fact it encodes must survive the
move. `send/3` catches `WebSockex.send_frame/2`'s exit and returns `{:error,
:send_timeout}`, because `WebSockex.send_frame/2` is `:gen.call` with a hard 5000ms
timeout that **exits** rather than returning, killing the calling connection process;
subscribes are idempotent on every venue, so a duplicate is harmless where a lost
connection is not. Coinbase carries this into `dp_exchange_coinbase` first, incident
moduledoc included, and the other three frame-WS venues copy both.

**`Core.PollingFeed`** — `GenServer`. `start_link/1`, `coverage/1`, `status/1`,
`update_symbols/2`. Fetch callbacks return `{:ok, event} | {:error, reason} | {:refused, reason}`;
the third is the venue explicitly stating it does not carry the symbol. `:fetch_all` for
venues with a bulk endpoint, `:fetch` per-symbol otherwise with start times spread across
the interval. A feed delivering nothing at all warns loudly and keeps warning.

**`Core.HttpClient`** — `request/5`, `get/3`, `build_auth_headers/5`,
`parse_rate_limit_headers/2`, `coinbase_cdp_jwt/2`. Uses `Req`. Reworked per §5.3/§5.5.

**`Core.FeedBehaviour`**, **`Core.RateLimitBehaviour`** — see D5 and D6.
**`Core.Notice`** — the notices channel (§5.4, D14), replacing what `event_sink.ex` was.
**`WebSocketProviderBehaviour` is not a Core module either (D20)** — under D12 transport
is package-internal, so Core has no socket to open and nothing to constrain. Its 13
callbacks were the contract with the host's `Connection`, which this plan deletes.

### 5.3 Severing the rate-limiter dependency

**Today** (`http_client.ex`):
```elixir
alias DpCryptoManagement.RateLimiting.RateLimiter    # line 15
# ...
RateLimiter.acquire(provider, account_id, user_id, operation)          # line 545
RateLimiter.check_rate_limit(provider, account_id, user_id, operation) # line 549
RateLimiter.record_request(provider, account_id, user_id, operation)   # lines 568/572/576
```

**Target**:
```elixir
defp limiter, do: DpExchange.Core.Config.resolve(:rate_limit_module,
                                                 DpExchange.Core.DefaultRateLimiter)

limiter().acquire(provider, weight, account_id: account_id,
                                    user_id: user_id,
                                    operation: operation)
```

Notes:
- Resolve through `Core.Config.resolve/2` (§7.8): process dictionary, then `$callers`,
  then Application env. Not `Application.get_env/3` directly — a host test that swaps the
  limiter must not affect every other `async: true` test on the node.
- Resolve the module at **call time**, not compile time — a compile-time
  `@limiter Application.compile_env(...)` would bake the host's choice into the published
  artifact and make the config unusable by third parties.
- `DefaultRateLimiter` is a straightforward in-process token bucket (ETS or GenServer).
  It must honour `record/3`'s "deliberately cannot fail" contract — metering must never be
  the reason a market-data call does not happen.
- Preserve the incident rationale in the moduledoc: neither `acquire/3` nor `check/3`
  fills the bucket; something must report what actually left, or the bucket stays empty
  and every check passes.

### 5.4 Severing the events dependency

**Today** (`event_sink.ex`, 90 LOC) — a bundle of `defdelegate`s into
`DpCryptoManagement.Events.{BalanceEvent, PriceEvent, Publisher, WebSocketEventRouter}`,
exposing `route_ws_event/3`, `price_updated/1`, `feed_sink/0`, `balance_updated/1`,
`publish_price_event/1`, `publish_balance_event/1`.

**Target — the module survives, inverted, and stops carrying market data.** Per D6, wiring
a venue's *data* stream to an event sink is the host's concern: the package emits
`Core.Types.*` structs to whoever subscribed and holds no function that decides what
happens next. So the six `defdelegate`s do not extract, and the host keeps its own
`Events.*` modules unchanged plus a small amount of glue that receives from `subscribe/2`
and publishes — host-migration work, out of scope (§1).

**What the module becomes** is the package's **notices channel** (§6.0, D14): connection
state, credentials rejected, sustained rate limiting, coverage change, degradation. Same
inversion — the host subscribes, the package never holds a host function. Never carries
credentials, and lossy-safe. `Core.Notice` / `subscribe_notices/1` per D14.

**What happens to the `:source` tagging rules.** They are load-bearing and each was learned
from an outage, so they cannot simply be dropped without saying where they went:

- `price_updated/1` stamping `source: :stream` let the host's `PollSet` take a pair off the
  REST poll set. Untagged, a poll's own tick counted as proof the subscription worked, the
  pair left the poll set, went silent and came back — oscillation measured live on
  2026-08-06, cadence falling from 30s to ~2.5 minutes.
- `feed_sink/0` stamping `source: :feed` excluded a feed's events from the collection task;
  untagged, the publisher stored nothing — Robinhood's feed published 87 symbols to the
  freshness table, charts and page while InfluxDB writes went 1271-in-two-hours to zero.
- A REST-backed feed must **never** claim `:stream`.

The first two are about a host mechanism — the poll set and the collection task — that this
facade removes: the host stops polling these venues and starts subscribing, so it has no
poll set to add or remove pairs from and nothing to distinguish `:stream` from `:feed`
*for*. Under §6.0 it also cannot be told, since mechanism stops at the facade. **The host
tags on receipt**: it knows which venue it subscribed to and by what call, so it can stamp
provenance itself without the package telling it anything.

The third rule is the one with lasting force, and its content is not really about tagging:
**never let intent stand in for evidence.** That survives intact in `coverage/1`, which
reports what was observed arriving and never what was subscribed (D6) — and it is
stronger there, because it is a value the caller reads rather than a convention an
implementer must remember. Document it in `usage-rules/feeds.md`.
Nothing else in the host's collection layer depends on the package tagging: the two rules
that did describe a mechanism this facade removes.

### 5.5 Removing venue knowledge from `HttpClient` (D-C)

Three venue-specific branches must move out of Core and into their venue packages:

| Today, in Core | Moves to |
|---|---|
| `build_auth_headers/5` case `:coinbase_cdp_jwt` | `dp_exchange_coinbase` |
| `coinbase_cdp_jwt/2` (public fn, ~line 378) | `dp_exchange_coinbase` |
| `parse_rate_limit_headers/2` case `"coinbase"` | `dp_exchange_coinbase` |
| `parse_rate_limit_headers/2` case `"gemini"` | `dp_exchange_gemini` |

Core keeps the **generic** primitives: `:hmac_sha256`, `:basic`, `:bearer`, the request
pipeline, query-string building, response parsing, retry, and a `parse_rate_limit_headers/2`
that handles only standard `X-RateLimit-*` shapes.

This is the same principle `Capabilities` was built to enforce — `websocket_module` and
`stream_channels` became adapter-declared precisely because a `case provider do` table in
shared code is a second place that can be wrong about a venue, and was: every provider
except Coinbase once fell through to Coinbase's module, so Gemini's socket spoke
Coinbase's protocol at Gemini's endpoint and delivered nothing.

**Sequencing note**: Coinbase is venue #1 (D11), so the generic hooks added in Phase 2.4
acquire their first real caller in Phase 5 rather than sitting uncalled until venue #4.
Do the Core-side removal in the same release that adds the generic hooks, and keep the
venue-specific code in the venue package from its first commit. Gemini's
`parse_rate_limit_headers/2` branch is the remaining half, and it lands at venue #2 (D11).

---

## 6. The Adapter Contract — What Makes All Five Identical

### 6.0 `DpExchange.Core.Venue` — the facade (D12)

The single module a consumer touches. Identical across all five venue packages; **nothing else
in a venue package is public API.** A venue's transport, limiter, signing, session
handling and supervision are implementation detail behind this.

```elixir
defmodule DpExchange.Coinbase do
  @behaviour DpExchange.Core.Venue
end
```

**Lifecycle** — the venue owns its processes; **starting them is the host's job, not the
package's and not Core's.**

- `child_spec/1`, `start_link/1` — starts the venue's whole tree: sockets, limiter,
  session refresh, whatever it needs. A venue with no processes returns `:ignore`.

The host puts whichever venues it wants into its own supervision tree, individually, and
decides restart strategy, shutdown order and naming. **Core ships no aggregate supervisor**
and no "start everything" entry point: it would have to know which venues exist (D1 — it
does not), and it would take from the host a decision that is the host's (§7.7 — a library
does not start itself).


**Declaration** — static, no credentials, safe to call at boot.

- `provider_name/0`, `runtime_id/0`, `asset_classes/0`, `capabilities/0`

**Market data** — the package uses whichever upstream endpoint serves the caller best with
what it was given. Credentials are an *input to that choice*, not a gate on it: several
venues serve the same data publicly and authenticated, with a materially higher ceiling on
the authenticated path, and a package holding credentials should be using it. Which
endpoint was actually called is mechanism and never crosses the facade (D12) — the caller
passes credentials or does not, and reads the consequence from `capabilities/0`.

- `get_price/2`, `get_historical_prices/4`, `get_symbols/1`, `get_order_book/2`,
  `get_market_overview/1`, `list_instruments/1`

**Account and trading** — credentials passed in, never read from a vault (invariant #2).

- `get_balances/2`, `get_accounts/2`, `get_fees/2`, `get_transfers/2`,
  `place_order/3`, `cancel_order/3`, `get_order/3`, `get_orders/2`,
  `get_trade_history/2`

**Streaming** — this is where D12 bites. The facade says *what*, never *how*.

- `subscribe/2` — `(symbols, opts)`; the venue decides sockets, sharding, pacing,
  protocol. The host never learns whether this opened one WebSocket, twelve, or an MQTT
  session.
- `unsubscribe/2`, `update_symbols/2`
- `coverage/1` — what is **observed** arriving, never what was subscribed (D6). A venue
  that cannot observe delivery answers `:not_covered`.

**Subscriptions are addressed by the thing itself, never by a handle.** `unsubscribe/2`
takes the same identifiers `subscribe/2` was given; there is no subscription reference to
mint, hold, or leak. On crypto that identifier is the **pair** — a caller knows about pairs
and nothing else, so a reference would be pure overhead wrapping something the caller
already has. Schwab will address by single symbol rather than pair, which is the same
pattern with a different vocabulary: whatever `SymbolNormalizer` canonicalises for that
venue is what you subscribe and unsubscribe with. `coverage/1` reports against the same
identifiers, so all three functions speak one language.


**Health**

- `test_connection/2`, `get_rate_limit_status/2`, `market_status/1` (§6.0 market hours)

##### Core and peripheral — what a package must prove to graduate

D15 says a package is experimental while any endpoint in its **core set** is. Here is that
set, and the rule that generates it — the rule matters more than the list, because the
facade will grow and someone will have to classify an endpoint this list does not contain.

**An endpoint is core only if both hold:**

1. **Irreplaceable** — only this venue can answer it. If a consumer can get the same
   answer from somewhere else, the package failing is an inconvenience, not a blocker.
2. **Load-bearing** — the consumer's primary job *fails* without it, rather than
   degrading. If the documented behaviour on absence is "the caller does without", it is
   not core.

**Core:**

| Endpoint | Why |
|---|---|
| `capabilities/0`, `provider_name/0`, `runtime_id/0`, `asset_classes/0` | A consumer cannot decide whether to use the package at all without these, and nothing else can tell it |
| `child_spec/1` / `start_link/1` | Nothing else works if the package cannot run |
| `get_symbols/1` | Only the venue knows what the venue lists |
| `get_price/2` | Only the venue knows the venue's price |
| `subscribe/2`, `unsubscribe/2`, `coverage/1` | The push half of the same job (§6.0 requires both endpoints); `unsubscribe/2` because failing to stop is a leak, and `coverage/1` because a stream you cannot verify is a stream you cannot trust |
| `get_balances/2` | Only the venue knows your position on it; nothing can be sized without it |
| `place_order/3`, `cancel_order/3`, `get_order/3`, `get_orders/2` | **When `supports_trading` is active.** Irreplaceable by definition — this is the act |
| `test_connection/2`, `get_rate_limit_status/2` | Knowing you are blocked is part of working, and only the venue can say |

**Peripheral** — each fails at least one test, and the reason is worth recording because
it is what a future classifier will reason from:

| Endpoint | Fails which test |
|---|---|
| `get_historical_prices/4`, `get_historical_price/4` | **Replaceable**, demonstrably: the host sources historical prices from a *different provider entirely* — `connectors.ex:496`, `@historical_price_providers [Coingecko.Provider]` |
| `quantization/1` | **Not load-bearing**, by the contract's own words: when unsupported *"the caller skips quantization"* and implementations *"fall back to sensible per-asset-class defaults"* |
| `get_order_book/2` | Irreplaceable but **not load-bearing** — depth is unavailable, trading on last price is not |
| `list_instruments/1` | **Not load-bearing** — a richer `get_symbols/1`, which is core; absence costs detail, not function |
| `get_market_overview/1` | **Not load-bearing** — a bulk convenience over per-symbol calls |
| `get_fees/2` | **Not load-bearing** — affects P&L accuracy, not whether an order executes |
| `get_trade_history/2` | **Not load-bearing** — after-the-fact reconstruction |
| `get_transfers/2` | **Not load-bearing** — deposits and withdrawals are not the trading path |
| `update_symbols/2` | **Not load-bearing** — an optimisation over `unsubscribe/2` + `subscribe/2`, both core |

Two properties of the boundary:

- **Core is per venue.** An endpoint the venue does not offer is `:unsupported` and drops
  out of that venue's core set. A market-data-only venue is not held to trading it does
  not have.
- **Trading is core exactly when it exists**, which is why D15's exit criterion is one
  requirement and not two: if `supports_trading` is active then the order group is core,
  and nothing but live trading proves it.
**This list moves with the facade.** §6.0 has already proposed endpoints that today have no
flag at all, and the staking group arrives as peripheral under the rule above.
already proposed endpoints that today have no flag at all, and the
staking group would arrive as peripheral under the rule above. Reclassify by applying the
two tests, not by amending the table.

**What crosses the facade — the complete list.** Anything not here is a design error:

1. **In**: credentials, symbols, order requests, options. **That is the whole inbound
   surface.** No modules, no functions, no callbacks, no sink.
2. **Out**: `{:ok, Core.Types.*}` / `{:error, reason}` / `{:refused, reason}` tuples from
   the pull endpoints.
3. **Out**: **pushed events** — `Core.Types.*` structs delivered to the subscriber as they
   arrive. See below.
4. **Out**: **notices** — what the package is doing and what is going wrong
   with it: `Core.Notice` via `subscribe_notices/1` (D14). See below.
5. **Out**: telemetry under `[:dp_exchange, …]` (§5.2).

Explicitly **not** crossing: socket handles, connection pools, `WebSockex` state, MQTT
sessions, rate-limit buckets, signing keys, retry timers, supervisor pids. The host cannot
reach them and has no reason to.

#### Data out: the package emits, the host connects

**Connecting a venue's data stream to an event sink is the host's concern**, not something
the host hands the package permission to do on its behalf.

An injected sink means host code executing inside the package's processes, at times the
package chooses, with the package's failure modes. It also drags the host's event
vocabulary across the boundary: the sink's shape *is* the host's `Events.*` contract, so
the package ends up knowing what the host does with data — the exact coupling O0 removes.

Inverted: `subscribe/2` registers the caller, and the venue **sends** events to it. The
host receives them like any other message and does whatever it likes — publish to its own
`EventSink`, broadcast, drop, buffer, fan out to three places. The package neither knows
nor can know.

- Events arrive as messages to the subscribing process (or a pid named in `opts`), tagged
  so a process subscribed to several venues can tell them apart.
- The payload is a `Core.Types.*` struct — the same value the pull endpoints return, so a
  caller writes one handler for a price whether it asked for it or was sent it.
- `unsubscribe/2` stops delivery. A dead subscriber stops delivery too; the venue must not
  accumulate events for a process that no longer exists.
- **Back-pressure is a bounded mailbox, declared.** A venue pushing faster than its
  subscriber consumes drops oldest beyond a stated bound and emits a notice (D14) saying so.
  Growing a mailbox silently until the node dies is the failure this avoids; dropping
  silently is the failure the notice avoids. A `GenStage` producer would give real
  back-pressure instead, at the cost of a dependency every consumer inherits —
  reconsidered only if a real consumer needs it.

#### Notices out: the package reporting on *itself* (D14)

A venue package needs a channel for reporting on **itself** — distinct from the data
channel, and never carrying market data on it. That is `Core.Notice`, subscribed with
`subscribe_notices/1` (D14), and like everything else the host *subscribes to* it rather
than injecting anything.

The distinction is the payload's subject:

| Channel | Subject | Example |
|---|---|---|
| `subscribe/2` | What the **venue** says about the **market** | `%Types.Quote{symbol: "BTC-USD", …}` |
| notices | What the **package** says about **itself** | `%Core.Notice{kind: :credentials_rejected, …}` |

A host may want the second without the first — a monitoring process that never touches
market data still needs to know a venue's credentials expired.

**What flows on it**, all things a host may need to *act* on rather than merely count:

- **Connection state** — connected, lost, reconnecting with attempt and backoff, recovered.
  Stated without naming the transport (§6.0): "the venue link is down" is the fact;
  whether that link is a WebSocket, an MQTT session or a poll loop is not.
- **Credentials** — rejected, expiring, session refresh failed. This one is close to
  load-bearing: a host that cannot learn its keys stopped working finds out from the
  absence of data, which is the slowest possible signal.
- **Pressure** — sustained rate limiting, backing off, a venue returning `429` past the
  point where retry is working.
- **Coverage change** — this is what makes `coverage/1` **pushable rather than pollable**,
  and it is the Webull incident directly: 325 symbols subscribed and confirmed, 174
  delivering. A drop from 325 to 174 is an event, not a number to be discovered by asking.
- **Catalog change** — a pair added, a pair removed, a pair's `Instrument.status` moving
  `:tradable` → `:delisted`. It is the
  one item on this channel that originates *at the venue* rather than in the package, but
  it belongs here rather than on `subscribe/2`, because it is not market data. A price is
  what the market says; a delisting is a change in the venue's own shape, and a consumer
  that never subscribes to a single quote still needs to know a pair it holds has stopped
  trading. It also makes the catalog **pushable rather than diffable**, which matters most
  exactly where diffing is worst: Schwab is the millions-of-instruments venue (§2 Phase 7),
  and re-pulling `list_instruments/1` on a timer to spot a delisting does not scale.
  Two honesty constraints carry over unchanged. Most venues do not *announce* a delisting —
  the pair simply stops appearing — so the package often learns it by diffing internally and
  must say so: the event is **observed**, not announced, exactly as `coverage/1` reports
  observed delivery. And `Instrument` already models this — `:tradable | :delisted |
  :unknown` — with unrecognised input resolving to `:unknown`, never to `:tradable`:
  a vanished pair is not evidence of a delisting, and the two must not be conflated. See
  `architecture/symbol-lifecycle.md` (Appendix C) for the states and the override rules.
- **Refusals and data quality** — a symbol the venue will not carry, a payload that did not
  parse.
- **Degradation** — the venue is answering, but from a slower path than usual. Freshness
  itself is not modelled: per §5.2 a timestamp is whatever the venue gave.

**Three constraints, all of which follow from decisions already made:**

1. **Emit, do not inject.** The host subscribes; the package holds no host function. Same
   rule as the data channel, same reason (D6).
2. **It must never carry credentials.** Same hard requirement as the tier-3 fidelity
   report (D7), and for the same reason: these packages are public and an operational
   event is exactly the sort of thing that gets pasted into an issue.
3. **It must be lossy-safe.** A dropped operational event must never stall or fail the
   venue. This is `record/3`'s "deliberately cannot fail" rule (D5) applied one level out:
   *reporting on the work must never become the reason the work does not happen.*

**Where the line with telemetry falls.** Core already specifies telemetry (§5.2) and the
two overlap, so the boundary needs stating rather than discovering: **telemetry is
measurement you aggregate; a notice is a condition you act on.** `request.stop`
with a duration is a metric. "Your API key was rejected" is not, and it should not be
delivered by a mechanism whose handlers run inside the emitting process and whose delivery
is legitimately lossy. The split, the names and the `:ws` → `:link` renames are settled in
**D14**.

Note what is *absent* versus today's host layer: no `Manager`, no `ConnectionPool`, no
`SubscriptionManager` on the host side, and therefore no provider whitelist to omit a
venue from. Webull is not a special case under this facade — it is just a venue whose
`subscribe/2` happens to speak MQTT.

#### Both endpoints always exist — this is not a capability

**Every venue exposes a pull endpoint and a push endpoint, always, with no flag.** Whether
the venue's own API offers a socket is not a question the host may ask, because it is not
a question the host can act on — it is mechanism, and mechanism stops at the facade (D12).

- **Pull** — `get_price/2`, `get_order_book/2`, `get_historical_prices/4`, … Ask, receive
  an answer.
- **Push** — `subscribe/2` / `unsubscribe/2` / `update_symbols/2`. Ask once, receive data
  as it arrives, delivered to the subscribing process (D6).

**The package bridges whatever the venue lacks natively.** A venue with only REST
endpoints implements `subscribe/2` by polling internally and emitting each result to the
subscriber; the caller sees a stream and never learns otherwise. A venue that only pushes
implements the pull side by answering from the latest pushed value. Neither direction is
optional, and neither is declared.

This is not speculative: **`Core.PollingFeed` already is that bridge**, and Robinhood
already ships on it. Robinhood has no socket at all and is nonetheless a streaming venue
from the host's side — REST polling on a `GenServer` with fetch callbacks, results pushed
to the subscriber. The one thing missing was the *rule*: today Robinhood is treated as
the exception that had to be special-cased into a feed, and under this facade it is simply
a venue whose push implementation happens to poll.

So `has_websocket` is deleted rather than renamed. There is no `has_streaming` and no
`has_polling`, because the answer is always yes to both. What a caller may legitimately
ask is *which data kinds* it can get and *how fresh* they are — see `streamable` in Kind 2
and §5.2 on freshness.

**Capabilities come in three kinds**, and conflating them is the easy mistake: only the
first kind gates a function; the other two constrain or parameterise a function that is
already active.

#### `capabilities/0` is the facade's activation map

The facade is **one fixed set of functions, identical on every venue** — never extended
per venue, never omitted. What differs is which of them are *active*, and that is declared,
once, by `capabilities/0`.

This is the structure that dissolves the "all the same but some have extras" tension.
There is no second mechanism and no escape hatch: a venue does not add functions, it
declares which ones it answers.

**Each entry is three-state, not a boolean** (D15). `:proven` / `:experimental` /
`:unsupported` — whether the endpoint works, *and* whether anyone has run it in anger.
`:experimental` is the default and the only honest starting state; `:proven` is earned per
endpoint by production use, not by careful implementation. A consumer can therefore ask
about the specific call it depends on rather than reading the package's overall banner.

**The invariant is bidirectional, and both halves are asserted (§6.1):**

- `:proven` or `:experimental` means the facade function **works**. Neither may answer
  `{:error, :not_supported}` — maturity says how well it is known, never whether it runs.
- `:unsupported` means the function **exists and returns `{:error, :not_supported}`**. It
  may not raise, may not be undefined, and may not quietly succeed with degraded data.

Both directions matter. Only checking the first lets a venue under-declare and hide working
functionality; only checking the second lets it over-declare and fail at runtime in the
caller's hands. The declaration and the behaviour cannot disagree, which is what lets a
consumer branch on `capabilities/0` instead of on venue identity — the whole of O0.

##### Kind 1 — activation and maturity: is this function answerable, and is it proven?

Each row's value is `:proven` / `:experimental` / `:unsupported` (D15), not a boolean. The
"Status" column below is the *plan's* status — whether the flag exists yet — not the venue's.

**That settles the encoding.** A boolean per slot cannot carry three states, so the
declaration is a single map of facade function → state — one field that cannot drift out of
sync as slots are added, and the table assertion 12 drives off. Kind 2 and Kind 3 stay as
named fields: they are not states and they gate nothing.

| Capability | Activates | Status |
|---|---|---|
| `has_rest_order_book` | `get_order_book/2` | exists |
| `has_rest_historical_candles` | `get_historical_prices/4` | exists |
| `has_historical_price` | `get_historical_price/4` | exists |
| `has_market_overview` | `get_market_overview/1` | **missing** |
| `has_instrument_catalog` | `list_instruments/1` | **missing** |
| `has_quantization` | `quantization/1` | **missing** |
| `has_transfers` | `get_transfers/2` | **missing** |
| `supports_trading` | `place_order/3`, `cancel_order/3`, `get_order/3`, `get_orders/2`, `get_trade_history/2` | **missing** — assumed universal |
| `has_private_accounts` | `get_balances/2`, `get_accounts/2`, `get_fees/2` | **missing** — assumed universal; false for a public-data-only integration or a read-only key |
| `has_authenticated_stream` | private channels (order updates, fills, balance pushes) | partially — inferable from `authenticated_channels: []`, but inference is not declaration |

##### Kind 2 — domain: for an active function, which arguments are valid?

| Capability | Constrains | Status |
|---|---|---|
| `supports_short_selling` | `side` on `place_order/3` | exists — **this is the one that was mis-filed as "data semantics"** |
| `supported_order_types` | `order_type` — the contract admits `market`, `limit`, `stop`, `stop_limit`, `post_only`, `ioc`, `fok` and **no venue declares which it takes** | **missing** |
| `supported_time_in_force` | `time_in_force` — `GTC`, `IOC`, `FOK` declared in the type, undeclared per venue | **missing** |
| `supported_instrument_types` | which of `Instrument`'s `:spot` / `:perp` the venue serves | **missing** |
| `streamable` | which *kinds* of data `subscribe/2` delivers — `:quotes`, `:order_book`, `:trades`, `:orders`, `:fills`, `:balances` | **missing** — replaces `stream_channels`, which carried venue vocabulary (`"level2"`) instead of meaning |
| `authenticated_streamable` | which of those need credentials — replaces `authenticated_channels` | **missing** |
| `supports_margin`, `max_leverage` | leveraged orders — **Schwab supports margin** (equities margin, in scope at Phase 7); Kraken 5x and Binance isolated+cross are out of scope (D21) | **missing — and needed.** The in-scope caller is Schwab, so the shape comes from Schwab's documentation (§10, D13), not from the crypto venues that first motivated the slot |
| `supports_fractional_shares` | `quantity` on equity venues — Webull, Robinhood, Schwab | **missing** |
| `supported_quotes`, `default_quotes` | `symbol` | exists |
| `historical_timeframes` | `timeframe` on `get_historical_prices/4` | exists |
| `asset_classes/0` | `:crypto` vs `:equity` — already a facade callback, not a `Capabilities` field | exists, sited differently |

##### Kind 3 — parameters: limits and shapes of an active function

`max_candles_per_request`, `reports_trade_volume` — these tune behaviour; none turns
anything on or off.

**Two that need reshaping, both because credentials change the answer:**

- **`requires_credentials_for_public_data` is a boolean and cannot say what matters.** It
  answers *"does this venue reject public calls without credentials"* — and the contract
  itself calls it *"informational for diagnostics + admin UI hints"*. The question a caller
  actually has is what credentials **buy**, and there are three answers, not two: public
  data is served with no meaningful difference; public data is served but the authenticated
  path has a materially higher ceiling; public data requires credentials outright. Only the
  first and third are expressible today, and the middle one is the common case.
- **The rate-limit ceiling is not one number.** D5 and D12 put the ceiling in the venue
  package, but on a venue with a better authenticated path there are *two* ceilings, and
  which applies depends on what the caller supplied. The declaration has to carry both, or
  a package holding credentials will meter itself against the public limit and leave most
  of its budget unused — the mirror image of the Webull incident, where a ceiling bound
  nothing because nothing recorded against it.

**And three that leave Kind 3 entirely: `auto_collect`, `default_quotes` and
`overview_suits_collection` are host collection policy, not venue capability.** No adapter
reads them — every venue declares them and only the host consults them
(`quote_scope.ex:68`, `exchange_collection_scope.ex:22`, `collection_set.ex:31`), and
`Capabilities`' own moduledoc calls `auto_collect` *"a business decision — which quote coin
a venue collects, and so what it costs in storage"*. Under O0 the split is clean: **the
venue declares what it *can* serve** — `supported_quotes`, and a catalog size class so a
consumer knows Schwab is millions and Kraken is 1,430 — **and the host decides what it
*will* collect.** Schwab's `auto_collect: false` (D10) becomes a host decision informed by
that size class rather than a value the package carries.

What must not survive Phase 2 is a boolean standing in for a three-way answer, or a single
ceiling standing in for two.

##### What is never declared: transport

**That a socket exists is not the host's concern.** What the host needs to know is whether
the venue can be **streamed** and whether it can be **polled**. How data reaches the
package — frame WebSocket, MQTT, SSE, long-poll, carrier pigeon — is package-internal
under D12, and naming it in a public declaration is the same leak as the six host provider
tables.

So four fields do **not** survive into the package's public capabilities:

| Field | Read today by | Why it goes |
|---|---|---|
| `websocket_module` | `feed_supervisor.ex:282`, `stream_bootstrap.ex:302` | Names a transport module so the host can start it. Under D12 the venue starts its own. |
| `feed_module` | `feed_supervisor.ex:64,103,158,185` | Same, for the polling-feed path |
| `stream_channels` | `stream_bootstrap.ex:313,714` | Venue channel vocabulary (`"level2"`, `"ticker"`) so the host can build a subscription plan. The venue builds its own. |
| `pairs_per_socket` | `stream_bootstrap.ex:714` | Sharding arithmetic — meaningless once the host does not own the sockets |

Every one of them exists because the host is currently doing the venue's job, and the host
says so: `feed_supervisor.ex:14` — *"The old shape needed a thousand lines because it was
doing five venues' jobs with none of their knowledge."* That migration is already half
finished. `feed_module` is not a capability at all but a **migration marker**: a venue
that declares one is excluded from the shared bootstrap and poll set, and a venue that has
not is still collected the old way, both paths coexisting on purpose. D12 finishes the
move, and the marker has nothing left to mark.

What a caller legitimately needs is *what kinds of data* stream, not which channels carry
them — see `streamable` in Kind 2. `"level2"` is Coinbase's word; `:order_book` is
everyone's.

of them turn anything on or off.

##### Functional groups the facade does not have at all

`docs/design/ideas/alternative-trading-types.md` (2026-05-12) surveys every venue in this
family and is the input here. It predates **D21**, so it still counts Kraken and Binance —
which matters for one row below and not the others. Beyond spot, the venues offer:

| Group | Who | Facade status |
|---|---|---|
| **Staking** | Coinbase (9 assets), Gemini (ETH/MATIC/SOL/DOT), Kraken (17+), Binance | **No facade slot — but partly built already.** `Gemini.Provider.get_staking_balances/2` exists today as a public venue function outside `DataProvider` |
| **Earn / lending** | Coinbase, Kraken, Binance, Gemini (status TBC) | none |
| **Margin** | **Schwab** (equities margin — in scope, Phase 7), Kraken (5x), Binance (isolated + cross) | none — Kind 2 above. D21 removes the two crypto venues but **not the requirement**: Schwab is in scope and margins, so the slot has a real caller. Its shape is a Phase 7 question, because Schwab's documentation is the only in-scope source for it (§10) |
| **Futures / perps** | Coinbase (BTC/ETH), Kraken (separate platform + auth), Binance (USD-M, COIN-M), Webull | partial — `Instrument` has `:perp`, nothing else |
| **Options** | Binance, Webull | none. Needs strike/expiry/Greeks; a parallel framework, not a facade slot (idea doc §C) |
| **Recurring buys / DCA** | Coinbase, Robinhood | none |
| **Dividends / corporate actions** | Webull, Schwab, Robinhood equities | none |

**`Gemini.Provider.get_staking_balances/2` is a live counterexample, and it does not
survive.** It is exactly the venue-specific public function this rule forbids: a caller must
know it is holding Gemini to call it. So it **does not cross the facade**, and the host
loses that call at migration — recorded as a behaviour delta (Phase 5.9) rather than
discovered in Phase 6.1. What ships now is the *declaration*: `has_staking` as a Kind-1
entry, so four of six venues can say they offer it. The functions themselves
(`get_staking_positions/2`, `stake/3`, `unstake/3`, `get_staking_rewards/2`) wait for a
deliberate Core release with more than one venue's implementation in hand — and must carry
the unbonding constraint the idea doc raises, since a 7–28 day lock is a fact a caller needs
*before* staking, not after.

**Market hours is a venue fact, and the venue declares it.** `platform/market_hours.ex`
(195 LOC) is host-side and asset-class-aware — crypto `:always`, US equities NYSE RTH with
optional extended hours, DST, 2026 holidays hardcoded. Under O0 the venue is the only thing
that knows its own calendar, so the facade gains `market_status/1` returning
`:open | :closed | :pre | :post` — every crypto venue answers `:open` trivially and an
equity venue answers honestly. The host keeps the *policy*: whether to trade in extended
hours is a strategy decision, not a venue fact. This is not cosmetic — `PollingFeed` "warns
loudly and keeps warning" when a feed delivers nothing (§5.2), so without it an equities
package alarms every night and every weekend, and a real outage is indistinguishable from
Saturday. Schwab (Phase 7) is where that stops being theoretical.
**One more defect, orthogonal to the taxonomy but fatal to it.** `{:error, :not_supported}`
is not used consistently in the source being extracted: `webull/provider.ex:733` returns
the **string** `{:error, "not_supported"}` while `webull/provider.ex:819` returns the atom,
and `coingecko/provider.ex` uses both forms in the same module. A caller pattern-matching
the atom silently misses the string and treats a refusal as an unrecognised error. Core
normalises the form on extraction and §6.1.6 asserts the atom — otherwise the activation
map is unreadable at the call site no matter how complete the flags are.

**No escape hatch, and Gemini is the test of it.** A generic `call/3` or a venue-specific public function would let host
code branch on which venue it is holding — the exact knowledge O0 removes. A venue feature
that no facade slot covers waits for Core to grow an optional slot, declared like every
other. That is the correct trade: an unreachable feature is a scheduling problem, a
venue-shaped branch in the host is the problem this project exists to solve.

### 6.1 `DpExchange.Core.AdapterContract` — the conformance suite

**This is the mechanism.** Prose in six CLAUDE.md files will drift; a suite that runs in
five venue CI pipelines cannot.

Model it on `influx-elixir/test/support/client_contract.ex`, which is compiled into the
package via `elixirc_paths(:test)` and driven by three contract test files
(`contract_local_v2_test.exs`, `contract_local_v3_core_test.exs`,
`contract_local_v3_enterprise_test.exs`).

Core ships a `use`-able ExUnit case:

```elixir
defmodule DpExchange.CoinbaseTest.Contract do
  use DpExchange.Core.AdapterContract,
    provider: DpExchange.Coinbase.Provider,
    symbol_format: DpExchange.Coinbase.SymbolFormat,
    fake: DpExchange.Coinbase.Fake,
    sample_pairs: ~w(BTC-USDC ETH-USDC)
end
```

It must assert, at minimum:

1. **Behaviour completeness** — `Provider` implements every required `DataProvider`
   callback; optional callbacks either implemented or absent (never half).
2. **Capabilities** — `capabilities/0` returns a `%Capabilities{}`; construction goes
   through `Capabilities.new/1` so the raising validations run; `historical_timeframes`
   ⊆ `Timeframe.known/0`; `default_quotes` ⊆ `supported_quotes`; `auto_collect` implies
   non-empty `default_quotes`.
3. **Identity** — `provider_name/0` is a non-empty `String.t()`; `runtime_id/0` is an
   atom; `asset_classes/0` is a non-empty list drawn from `[:crypto, :equity]`.
4. **Symbol round-trip** — `SymbolFormat` implements `SymbolNormalizer`; and the property
   `to_canonical_symbol(to_exchange_symbol(p)) == p` holds for `sample_pairs` **and** for
   generated pairs over the venue's declared `supported_quotes`. This is `CanonicalPair`'s
   stated invariant and it is where the Binance `USD`→`USDT` bug lived.
5. **Return types** — every implemented data callback returns the declared
   `Core.Types.*` struct (or the documented map shape), with `Decimal` numerics and
   `DateTime` timestamps — never floats, never strings-where-Decimal-is-declared.
6. **Error discipline** — unsupported optional callbacks return `{:error, :not_supported}`
   and never raise. Failures are tagged tuples, never bare values.
7. **Purity** — the compiled package contains no reference to `DpCryptoManagement.*`,
   `Phoenix.*`, `Ash.*`, `Cloak.*`. Implement as a source scan over the package's own
   `lib/`, i.e. the inverse of the host's `NoAppDepsInExchanges` Credo check
   (`../dp_crypto_management/test/credo/no_app_deps_in_exchanges.ex` — read it, the
   moduledoc explains the whole invariant).
8. **Both endpoints answer — no flag, no exceptions.** *Not* "websocket coherence", and
   not a check on whether the venue can stream: it always can (§6.0). Assert that
   `subscribe/2` accepts symbols and delivers events to the subscriber, **and** that the pull endpoints
   answer, on every venue without exception. Neither may return `{:error, :not_supported}`.
   A venue whose upstream API is REST-only passes this by polling internally and pushing
   the results — that is the package's job, not the caller's problem. Assert further that
   `coverage/1` reports what was **observed arriving**, never what was subscribed (D6), so
   a caller can judge delivery without learning mechanism. No assertion may name a socket,
   a channel string, a transport module, or a polling interval — if one does, mechanism has
   leaked through the facade and the assertion is the bug.
   (Webull stops being a special case entirely. Its complete MQTT client and the fact that
   no reachable broker answers it are now the same kind of fact as Robinhood having no
   socket: internal. Both venues expose both endpoints; what differs is what `coverage/1`
   honestly reports.)
9. **Fake fidelity — the ratchet.** The venue's fake satisfies the same suite as the real
   adapter. The suite's job is not to anticipate every divergence but to make each
   discovered one permanent: influx-elixir's went from nothing to 1,359 lines by absorbing
   thirteen gaps its first consumer found, and **none reached an external user across
   2,000+ downloads in 30 days** (D7). So this assertion is paired with the thing that
   actually finds gaps — a real consumer exercising the fake against real work, backed by
   tier-2 and tier-3 tests — and with the rule that **every gap found becomes a new case
   here**. Phase 5.14's retrospective is where the first batch lands.
10. **Facade completeness and exclusivity (D12, §6.0)** — the package exposes every
    `DpExchange.Core.Venue` callback, and **only** the facade is public. Assert the
    negative as a module scan: no other module in the package is reachable API, no socket
    handle / pool / bucket / signing key appears in any facade return value, and the
    package declares its own supervision entry point. This is the assertion that makes
    "nothing crosses the facade" enforceable rather than aspirational, and it is the one
    that would have caught `websocket/supervisor.ex` accepting only two of six venues.
11. **Self-sufficiency** — the package starts, subscribes, and serves data with **nothing
    injected but credentials and options**. No sink, no socket, no pool, no limiter, no
    host module of any kind. A venue that needs any of those to function fails this.
    Robinhood (no venue socket, polls internally) and Webull (own MQTT client) must both
    pass unmodified. Assert the inbound surface directly: the facade's arguments are data,
    never functions or modules — a callback in an argument list is an injected sink
    wearing a different name.
12. **Capabilities/facade agreement, both directions (§6.0)** — the load-bearing
    assertion. For every capability-gated facade function: if it declares `:proven` or
    `:experimental`, calling it must NOT return `{:error, :not_supported}`; if it declares
    `:unsupported`, it MUST return exactly that — the atom, never the string
    `"not_supported"`, never a raise, never an undefined function, never degraded data.
    Drive it off a table in Core mapping capability → function, so adding a facade slot
    without a capability is a compile-or-test failure rather than an omission nobody
    notices. Over-declaring fails in the caller's hands at runtime; under-declaring hides
    working functionality — this assertion is what makes `capabilities/0` trustworthy
    enough for a consumer to branch on instead of branching on venue identity (O0).
    **Maturity is asserted for presence, not for truth**: every active endpoint must
    declare `:proven` or `:experimental`, because an absent value is the failure this
    prevents. Whether a `:proven` claim is *true* is not machine-checkable and the suite
    should not pretend it is — that is D15's auditable-claim problem, not a test.
13. **Process-scoped isolation (§7.8)** — the assertion that makes the package usable in a
    consumer's `async: true` suite. Two halves, both driven from the suite itself:
    **selection** — set the fake in the test's own process, assert the facade uses it, and
    assert a *sibling* process with no override still gets the default; **behaviour** —
    two concurrently running processes configure the same fake differently (one refusing,
    one succeeding) and each sees only its own. Assert the `$callers` walk explicitly by
    spawning a `Task` inside the override and checking it inherits, since that is the step
    most likely to be skipped. No test here may call `Application.put_env/3` — a suite that
    needs a global to prove isolation has disproved it.

### 6.2 `usage-rules.md` — the contract as consumer documentation

influx-elixir ships `usage-rules.md` plus `usage-rules/{query,write,testing}.md` inside
the Hex tarball via `mix.exs`'s `files:` list, and declares:

```elixir
defp usage_rules do
  [file: "AGENTS.md", usage_rules: [:usage_rules]]
end
```

with `{:usage_rules, "~> 1.2", only: :dev}` as a dep. `AGENTS.md` is **generated** by
`mix usage_rules.sync` — do not hand-edit it.

Core ships `usage-rules.md` plus:
- `usage-rules/adapter.md` — implementing `DataProvider` + `Capabilities`
- `usage-rules/symbols.md` — `CanonicalPair` mapping, longest-first quotes, the
  round-trip invariant
- `usage-rules/feeds.md` — `subscribe/2`, delivery to the subscriber, the notices channel,
  observed-not-intended coverage
- `usage-rules/testing.md` — the conformance suite, the no-mocking rule, the fake pattern,
  the four verification tiers, **how to isolate the fake per process** (§7.8), what a green
  CI run does not prove, and the EXPERIMENTAL
  status (D15)

This is the highest-leverage artifact in the project: it is how the contract reaches
every future consumer's Claude session automatically, including the host app's, including
third parties once these go public.

### 6.3 Required venue package file layout

Derived from the six existing adapters. Required in every venue package:
```
lib/dp_exchange/<venue>.ex    # THE FACADE — @behaviour DpExchange.Core.Venue   REQUIRED
lib/dp_exchange/<venue>/      # everything below is package-internal; the host sees none of it
├── provider.ex           # market data + trading                       REQUIRED
├── symbol_format.ex      # @behaviour DpExchange.Core.SymbolNormalizer REQUIRED
├── supervisor.ex         # the venue's own process tree                if it runs processes
├── push/…                # how `subscribe/2` is actually served — frame WS, MQTT, SSE, or
│                         #   a REST poll loop. Sharding, reconnect. The venue's business.
├── pull/…                # how the request/response reads are served
└── signing.ex            # venue auth                                  if venue requires
test/support/fake.ex      # in-process venue fake                       REQUIRED (D7)
test/contract_test.exs    # use DpExchange.Core.AdapterContract         REQUIRED
```

**The layout below the facade is advisory, not required.** The contract asserts the facade
and the capability declaration, never the file tree (§6.1). Webull needs `mqtt_packet.ex`,
`mqtt_ws.ex`, `quote_proto.ex` and `session_plan.ex`, and is not thereby irregular.

Host source per venue, as a size guide for the extraction — **not** a layout the packages
must reproduce:

Binance and kraken are listed for completeness — they are host source, but **not in this
plan's scope** (D21).

| Venue | files | notable | push path today |
|---|---:|---|---|
| binance | 3 | — | *out of scope (D21)* |
| kraken | 3 | — | *out of scope (D21)* |
| coinbase | 5 | feed + coordinator, 100 pairs/socket | frame WebSocket, pooled |
| gemini | 6 | `l2_book.ex`, 10 pairs/socket | frame WebSocket, pooled |
| robinhood | 4 | `signing.ex` | REST polling — no socket |
| webull | 11 | `mqtt_packet`, `mqtt_ws`, `quote_proto`, `session_plan`, `signing` | MQTT over WebSocket, own client |

`coinbase` is the reference extraction (D11): 5 files, 3,109 lines, 10 host test files.
Extract it first. Of the venues in scope, `robinhood` is now the simplest shape (4 files,
no socket at all) — binance held that role until D21.

**Reference example** — `binance/symbol_format.ex` is the canonical `SymbolFormat` shape,
and stays the teaching example even though binance is out of scope (D21): it is host source
we can read, and the shape is what matters. Deliberately not Coinbase's, even though
Coinbase is venue #1: Coinbase's mapping is identity and teaches the pattern badly
(Phase 3.2).
`@mapping %{sep: "", quotes: ~w(USDT USDC USD EUR BTC ETH BNB)}`, a public `mapping/0`,
`to_native/1` + `to_standard/1` convenience wrappers, and the two `@impl true` callbacks
delegating to them. Note its moduledoc records the bug it fixed: the old
`ensure_usdt_pair` substituted `USD`→`USDT`, collapsing both `-USD` and `-USDT` into one
native form so it could not round-trip and silently mis-tagged the market.

---

## 7. Repo Standard

Clone influx-elixir's shape. Every one of the six in-scope repos gets the same skeleton.

### 7.1 Files

```
.claude/agents/*.md                  # provisioned, not hand-copied — §7.5
.claude/settings.local.json
.credo.exs                           # strict: true, MaxLineLength max_length: 98
.formatter.exs                       # line_length: 98
.github/workflows/ci.yml             # §7.3
.github/ISSUE_TEMPLATE/              # bug-report shape for host↔package issues — D16
.env.sample                          # the ONLY committed env file — §7.7
.gitignore                           # `.env*`, `!.env.sample`, `.mcp.json` — from commit #1
.mcp.json                            # host MCP server — **gitignored**, never committed
.tool-versions                       # elixir 1.18.4-otp-28 / erlang 28.0.2 / nodejs 22.17.1
AGENTS.md                            # GENERATED by mix usage_rules.sync — never hand-edit
CHANGELOG.md
CLAUDE.md                            # §7.4
LICENSE                              # MIT, "Copyright (c) 2026 DistortionPoint"
README.md                            # first line is the EXPERIMENTAL banner — D15
config/{config,dev,prod,test,runtime}.exs  # runtime.exs is the ONLY env reader — §7.7
docs/design/{README.md,templates/,workflow/}   # copy from host app — §7.6
docs/reference/<venue>/              # the venue's API docs, committed — D13 (venue repos)
docs/guides/
lib/dp_exchange/...
priv/plts/                           # dialyzer PLT cache location
test/support/
usage-rules.md + usage-rules/
```

Runtime versions are managed with **Mise**, not asdf.

**Scaffolding any repo needs two session restarts, and the architect at both.** This is a
property of the tooling, not of this plan, and it repeats for all six in-scope repos — Phase 0 for
Core, then Phase 5.1, each Phase 6 venue, and Phase 7.3:

1. **After `.tool-versions`.** Mise resolves the toolchain when a session starts, so the
   session that writes the file is still running whatever was live before it. Restart, then
   verify the versions actually reported match the ones asked for. Everything downstream
   compiles against this.
2. **After `CLAUDE.md`, `.claude/agents/` and `.mcp.json`.** All three are read at session
   start. The session that writes them is neither governed by them nor able to use them —
   it will cheerfully violate rules it cannot see, including the absolute rules in §0, and
   cannot call the MCP tools it just configured. Restart before doing the work those rules
   exist to constrain.

Write `.tool-versions` alone and first; write `CLAUDE.md`, the agents and `.mcp.json` last,
immediately before the restart. Bundling any of them with neighbouring files is what makes
the restart easy to forget.

**`.mcp.json` is gitignored from commit #1, and this is not a preference.** The host's own
copy carries a bearer token and is ignored at `dp_crypto_management/.gitignore:256`. These
repos go **public** (D4), and making a repo public exposes its whole history — a credential
committed once and removed later is still there. Each developer writes their own file; it
is a development-time convenience and never a package artifact, so it also stays out of
`mix.exs`'s `files:` list (§7.2).

### 7.2 `mix.exs` shape

Copy influx-elixir's structure exactly:

- `@version "0.1.0"` and `@source_url "https://github.com/DistortionPoint/dp-exchange-core"`
  as module attributes. **The CI bump script greps the literal `@version "` — keep that
  exact form.**
  It is a **seed, not a release**: CI increments the last segment of whatever it finds, so
  `0.1.0` here publishes as `0.1.1`, and hand-editing it to `0.2.0` is how a breaking
  change is signalled (§7.3, D18).
  The published version is therefore always one ahead of the file — deliberate, not an
  off-by-one; see §7.3 before changing it.
- `elixir: "~> 1.18"`, `elixirc_paths(:test)` → `["lib", "test/support"]`
- `test_coverage: [threshold: 90, ignore_modules: [...]]`
- `name:`, `description:`, `package:`, `source_url:`, `docs:`. **`description:` is prefixed
  `EXPERIMENTAL — ` while the package is unproven (D15)** — it is what hexpm search and the
  package page show, and for many readers it is the only text they see.
- `usage_rules: [file: "AGENTS.md", usage_rules: [:usage_rules]]`
- `files: ["lib", "mix.exs", "README.md", "LICENSE", "CHANGELOG.md", "usage-rules.md",
  "usage-rules/**/*"]` — plus `"test/support"` for Core, so the conformance suite ships
- `aliases: [quality: ["format --check-formatted", "credo --strict", "dialyzer",
  "sobelow --config"]]`, `preferred_cli_env: [quality: :test]`
- `dialyzer: [plt_add_apps: [:mix, :ex_unit], plt_file: {:no_warn, "priv/plts/dialyzer.plt"}]`
- `package: [licenses: ["MIT"], links: %{"GitHub" => @source_url}, maintainers: ["bcatherall"]]`

Core's deps (minimum): `{:req, "~> 0.5"}`, `{:jason, "~> 1.4"}`, `{:decimal, "~> 2.0"}`,
`{:telemetry, "~> 1.0"}`. **`websockex` is absent at every strength** (D20) — not a hard
dep, not `optional: true`. Under D12 transport is venue-owned, so Core has no socket to
open, and an optional dep would still advertise transport in Core's published docs. Plus
dev/test
`{:usage_rules, "~> 1.2", only: :dev}`, `{:ex_doc, "~> 0.34", only: :dev, runtime: false}`,
`{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`,
`{:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}`,
`{:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}`.

**`Decimal` is the only numeric dependency in the family.** `ex_money` appears once in the
host, in `mock/provider.ex`, and `mock` does not become a package (D10) — so no venue
package needs it. `Core.Types.*` are already Decimal-only by contract (§5.2).

Venue deps: `{:dp_exchange_core, "~> 0.1.0"}` — three-part, per D2 and D18 — plus whatever
the venue genuinely needs, **which is where every transport dependency now lives** (D20):
`websockex` for the five with sockets, declared package by package, and nothing at all for
Robinhood, which polls. `Bitwise` is stdlib.

**No `boundary` dep.** The `use Boundary` in `rate_limit_behaviour.ex` is a host-app
construct and is dropped.

### 7.3 CI

Copy `influx-elixir/.github/workflows/ci.yml`. Two jobs:

**`quality`** — matrix `otp: ['28.0']`, `elixir: ['1.18']`; `actions/checkout@v4`;
`erlef/setup-beam@v1`; three `actions/cache@v4` blocks (`deps`, `_build`, `priv/plts`)
keyed on `${{ hashFiles('mix.lock') }}`; then:
```
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test --cover
```
Guarded by `if: "!contains(github.event.head_commit.message, '[skip ci]')"` and a
`concurrency` group with `cancel-in-progress: true`.

**`publish`** — `needs: quality`, `if: github.ref == 'refs/heads/main' && github.event_name == 'push'`.
Auto-increments the patch in `mix.exs` via sed, `mix hex.publish --yes` with
`HEX_API_KEY`, commits `Release vX.Y.Z [skip ci]` as `github-actions[bot]`, tags `vX.Y.Z`,
pushes with tags, then `gh release create "vX.Y.Z" --generate-notes`.

**Every merge to `main` publishes a new patch version.** Plan branches accordingly.

**Signalling a breaking change: edit the version by hand.** The bump script reads
`@version` out of `mix.exs` and increments the **last segment of whatever it finds** — it
does not consult what was last published. So the file is the lever:

- Leave it alone and releases walk `0.1.4 → 0.1.5 → 0.1.6`.
- Set it to `0.2.0` in the commit that makes a breaking change, and the next publish is
  `0.2.1` — even if the last release was `0.1.999`. The counter resets to the new minor.

No marker syntax, no CI logic, and it composes with D18's `~> 0.1.0` pin: a consumer pinned
at `< 0.2.0` will not pick up the new minor without editing their own `mix.exs`. The break
is signalled and opted into, both deliberately.

**The published version is always one ahead of the file, and that is deliberate.**
`@version "0.1.0"` at Phase 0.5 publishes as `0.1.1`; while developing against a release,
the number in `mix.exs` is one behind the one on hexpm. That offset is the accepted cost of
not having to remember anything: the common case — a patch — takes zero thought, and only a
break costs a deliberate edit. The alternative is bumping by hand before every merge, which
fails the way manual steps always fail, and fails at the worst moment: a forgotten bump is
a rejected publish on a release you thought had shipped.

**Do not "fix" the offset.** It looks like an off-by-one and is not. Removing it means
re-introducing the manual bump for every release in six repos.

**The `publish` job is armed by a one-time architect action, not by this plan** — the repo
being made public plus the org `HEX_API_KEY` secret (D4). Until that happens for a repo it
cannot publish, which is the intended safety: a package cannot escape early by accident.
After it happens, releases are unattended by design.

**Do not use the orchestrator's `ci-assistant` MCP for these repos.** It generates
workflows against `Blueleaf/bl-sre-actions` for the `etl_escript` / `phoenix_api` /
`otp_app` archetypes — that is the Blueleaf deploy-to-AWS model. `app-knowledge` tracks
only `Blueleaf` and `UpliftWealth` repos; neither `dp_crypto_management` nor
`influx-elixir` is registered. Likewise `repo-governance--get_repo_standards(library)`
requires `master` + `production` branches — a Blueleaf deploy convention that does not
apply to a Hex library on `main`. **These repos follow influx-elixir**, which carries a CI
workflow and no other governance file at all (D9) — not CODEOWNERS, not Dependabot, not an
issue template. Do not import the Blueleaf checklist because it is there.

### 7.4 `CLAUDE.md`

Base it on `influx-elixir/CLAUDE.md` (190 lines) — Project Overview, ABSOLUTE RULES,
Essential Commands, Architecture, Module Organization, Key Patterns, Dependencies,
Testing Strategy, Code Quality Requirements, Critical Development Principles, Definition
of Done, DDD Philosophy, Documentation Standards.

Two corrections when you write it:

- Pull the ABSOLUTE RULES from `first-principles--org_conventions` (canonical), **not**
  from influx-elixir's copy. See §0.
- Carry the **`runtime.exs` reads env, the others are static** rule (§7.7). It is a
  CLAUDE.md rule in the host and the packages inherit it.
- Do **not** reference individual design docs or work items from `CLAUDE.md` — that is a
  recorded user preference (`feedback_no_single_work_refs` in influx-elixir's project
  memory). Point at `docs/design/` as a directory, never at this file by name.

### 7.5 Agents

Do not hand-copy `.claude/agents/`. The two existing repos have already drifted —
influx-elixir carries 10, `dp_crypto_management` carries 18. Use the orchestrator's
`agent-normalization` server:

- `resolve_profile` with `{manifest: "mix", deps: [...]}` → `{language: "elixir", capabilities: [], frameworks: []}`
- `import_canonical` to provision the slots from the 18 active canonical templates
- `report_agents`, `agent_drift_report`, `diff_app_agents` to keep six repos aligned later
- `review_claude_md` / `check_claude_md` to validate §7.4's output

The elixir-relevant canonical agents: `elixir-backend-dev`, `elixir-test-writer`,
`backend-architect`, `code-reviewer`, `code-refactor`, `code-debugger`, `code-documenter`,
`code-security-auditor`, `code-standards-enforcer`, `api-developer`.

### 7.6 Docs and planning workflow

Copy `docs/design/{README.md, templates/, workflow/}` from
`../dp_crypto_management/docs/design/` into Core, then into each venue repo.

- Naming: `YYYY-MM-DD_design-topic-name.md`, kebab-case, with a matching
  `YYYY-MM-DD_design-topic-name/` directory for code samples when needed.
- Template: `docs/design/templates/design-document-template.md`.
- Status header, one of: `Draft` → `In Review` → `Approved` → `Implementing` →
  `Implemented`.
- On reaching `Implemented` (all checklist items done **and** a retrospective appended),
  `git mv` the doc and its samples dir into `docs/design/closed/`. `docs/design/` should
  always show only open work.
- `docs/design/ideas/<topic>.md` — no date prefix, for non-blocking discoveries. Deleted
  when the work lands.
  Two exist already, both carrying work this plan deliberately does not do:
  `external-experimental-feedback.md` (how a stranger with venue accounts helps a package
  graduate) and `detecting-vendor-api-change.md` (how a venue changing gets noticed and
  the fix reaches consumers). Phases 5.14 and 8.3 feed the second.
- Workflow docs: `collaboration-process.md`, `naming-conventions.md`, `iteration-cycles.md`.

### 7.7 Configuration and secrets

The org convention, documented in `../dp_crypto_management/docs/development/secrets.md`.
Copy it exactly; it is not a place to improvise.

**Secrets live in `.env` files. Nowhere else.**

| File | Committed | Purpose |
|---|---|---|
| `.env.sample` | **Yes** — the only one | Every supported var with a placeholder and a one-line comment: purpose, allowed values, which environments need it |
| `.env`, `.env.dev`, `.env.test`, `.env.local`, … | No | Real values, per developer, sourced into the shell before `mix` |

`.gitignore` carries exactly:

```
.env*
!.env.sample
```

There are **no per-environment templates** (`.env.dev.example` and friends) and **no
`config/*.secret.exs`** — the host's `.gitignore` still lists the latter, which is legacy
rather than convention. There is no Vault layer either; the orchestrator's `config` MCP
describes Blueleaf's `EnvRegistry`, which §7.3 already rules out for these repos.

**The orchestrator's config guidance does not apply here, and this is worth knowing before
looking.** `config--*` describes Blueleaf's `BlEtlConfig.EnvRegistry` (Vault-first
resolution, `secret`/`config`/`local_only` tiers), and
`library-assistant--get_setup_guide` returns an `application.ex` that starts
`:bl_etl_config` before the app, a `Config` wrapper resolving through a
process-dictionary context, and a four-step `test_helper.exs`. All of it is correct for a
Blueleaf ETL or Phoenix app and wrong for these packages: §7.3 already rules the Blueleaf
model out, `secrets.md` says there is no Vault layer, and a public Hex package cannot take
an internal library as a dependency (invariant #4). Use it as a reference for *how* an OTP
app is wired, never as the pattern to copy.

**The startup rule, and it is absolute:**

- **`config/runtime.exs` is the only file that may call `System.get_env/1`**, and every read
  carries a dev/test fallback literal:
  `some_key: System.get_env("SOME_KEY") || "dev-only-some-key"`.
- **`config.exs`, `dev.exs`, `test.exs`, `prod.exs` MUST NOT read env.** They are static.
  This is a CLAUDE.md rule in the host and belongs in each package's CLAUDE.md (§7.4).

**Adding a var** is a five-step lifecycle, all five or none: add the `runtime.exs` read
with a fallback; add a placeholder line to `.env.sample`; put the real value in your local
`.env.*`; tell CI to set it; tell the deploy platform to set it.

#### Compile time vs runtime — the part that gets got wrong

Stated explicitly because it is a repeated failure mode, and because for a *library* the
consequences differ from an application's.

**When each file runs:**

| File | Evaluated | May read env? |
|---|---|---|
| `config/config.exs` and everything it imports — `dev.exs`, `test.exs`, `prod.exs` | **Build time**, during `mix compile` / `mix release`. The values are baked into the artifact | **No** |
| `config/runtime.exs` | **Runtime**, on every boot, after compilation | **Yes** — this is the only one |

**`compile_env` vs `get_env`, and why a library must prefer `get_env`:**

- `Application.compile_env/3` reads at compile time and freezes the value into the compiled
  module. Elixir tracks it and raises at boot if the runtime value has since diverged.
- `Application.get_env/3` reads from the application environment at call time.
- In a **library** this is not a stylistic choice. A dependency is compiled into the
  consumer's `_build`, so `compile_env` freezes whatever the consumer's config said *at
  dependency-compile time*. A consumer who later changes that setting must recompile the
  dependency, and if they do not, they get a boot-time mismatch error rather than the new
  value. Anything a consumer is meant to configure is read with `get_env` at call time.

D5 already applies this correctly and says why: `rate_limit_module` resolves at call time
because *"a compile-time `@limiter Application.compile_env(...)` would bake the host's
choice into the published artifact and make the config unusable by third parties."* That is
the rule; §7.7 generalises it.

**Startup: a library does not start itself.**

The packages expose `child_spec/1` / `start_link/1` on the facade (§6.0) and are supervised
**by the consumer**. They must not ship an `Application` module that starts processes on
load — a consumer that has not asked for a venue should not find a socket open, and one
that has cannot control restart strategy, shutdown order or naming if the package started
things behind it. Either no `Application` callback module at all, or one whose supervision
tree is empty. Same principle as D12: the venue owns its processes, the host decides when
they run.

**And `config/` is not shipped at all.** It is absent from `mix.exs`'s `files:` (§7.2), so
it governs the package's own dev and test only. A consumer configures the package from
*its* config, which is how `:dp_exchange_core, :rate_limit_module` reaches Core (D5). The
env reads a package genuinely needs are therefore narrow — credentials for the tier-2 and
tier-3 test runs (D7) — and they still go through `runtime.exs` like everything else.

### 7.8 Test isolation — the process-scoped config seam

**This is a hard requirement on every package, and it is the one thing here most likely to
be got wrong.** A consumer runs `async: true`. `Application.put_env/3` is node-wide. Any
seam a consumer's tests need to vary — which implementation is in play, what a fake
returns, which limiter is active — must therefore be resolvable **per process**, or the
packages are unusable in an async suite.

**The host has already paid for this.** `rate_limiter_acquire_test.exs` records it:

> *"Seven tests here used `Application.put_env(:dp_crypto_management, :rate_limiting,
> enabled: true, …)` instead. That flag is node-wide, so for the duration of each of those
> tests EVERY other `async: true` test on the node was suddenly rate-limited against a
> 1-request bucket — which is how `WebSocket.ManagerTest`'s `connect/5` came back
> `{:error, {:rate_limited, 1}}` while asserting on connection errors (2026-08-05, seed
> 5150)."*

An unrelated test file failed because a different file set global config. That is the
failure mode, and it is silent, intermittent and seed-dependent — the worst combination.

**The mechanism**, from `rate_limiting/config_reader.ex`. Production code never calls
`Application.get_env/3` directly for anything a test may vary; it goes through a reader
with this lookup order:

1. `Process.get(@key)` — an override in the calling process.
2. Failing that, walk `Process.get(:"$callers", [])` and read each ancestor's process
   dictionary. **This step is the one people omit.** ExUnit propagates `$callers` to
   spawned `Task`s, so without the walk any work the test spawns loses the override.
3. Failing that, `Application.get_env/3` — the global default, which is what production
   uses and what a consumer configures normally.

**Crossing a process boundary needs one more step.** A `GenServer` runs in its own process
and will not find the caller's dictionary at all. The host's `RateLimiter.acquire/5`
handles this by **snapshotting the override into the call message** before the
`GenServer.call`. Any package process that honours a configurable seam must do the same;
resolving inside the server is too late.

**What Core ships**: one resolver, so five venue packages cannot each invent a variant of this.
Every configurable seam in the family — the fake selection (D7), `rate_limit_module` (D5),
anything added later — resolves through it.

**What this means for the fakes specifically (D7).** influx-elixir selects its fake with
`config :influx_elixir, :client, InfluxElixir.Client.Local` — a global. That is adequate
for one library with one fake, and inadequate here: a host holds up to five venue
packages, and its tests will want venue A faked while venue B is real, or two tests wanting
the *same* fake to behave differently — one simulating a `429`, one succeeding. Fakes are
ETS-backed and stateful (D7), so shared state across async tests is a race as well as a
config problem. **A venue fake must support per-process selection and per-process
behaviour**, or the host cannot test with it at any useful granularity.

### 7.9 Project memory — a gotcha

influx-elixir commits `.claude/projects/-Users-bcatherall-development-influx-elixir/memory/`
with 5 memory files (`MEMORY.md`, `feedback_no_mocking`, `feedback_no_single_work_refs`,
`project_influx_elixir_design`, `reference_github_repo`, `user_tooling`).

**The convention is kept, with the corrected slug.** The slug derives from the absolute
project path, so on this machine — dev root `/Volumes/Dev/development`, not
`/Users/bcatherall/development` — it must be `-Volumes-Dev-development-<repo>`. That is
already demonstrated working for this repo: memories written during this plan's review load
from `.claude/projects/-Volumes-Dev-development-dp-exchange-core/memory/`. Copy the
directory, fix the slug, do not move the facts into `usage-rules/` — those two have
different audiences. `usage-rules/` is for *consumers* of the package; project memory is
for whoever works *on* it.

---

## 8. Risk Assessment

| Risk | Impact | Prob. | Mitigation |
|---|---|---|---|
| Core contract wrong; discovered at venue #4 | High | Medium | Coinbase-first (D11) exercises auth, feed, coordinator and sharding on venue #1 + mandatory Phase 5.14 retrospective before any replay |
| Every merge auto-publishes a patch; Core churns during venue work | Medium | High | Branch and batch; only merge to `main` at a real release point |
| A breaking Core change reaches venues or the host silently | High | Medium | D18 tightens the pin to `~> 0.1.0` (`< 0.2.0`), so a breaking release is an explicit edit rather than an automatic pickup — `~> 0.1` would have accepted any 0.x. A break is signalled by hand-editing the version seed, which resets the counter CI increments from (§7.3). The contract suite in every venue's CI still fails fast on a real break |
| Venue fakes drift from real venue behaviour | High | Low | **Accepted, and the loop is proven at scale** (D7): influx-elixir's fake had 13 gaps, all found by its first consumer, all fixed upstream, **none reaching an external user across 2,000+ downloads/30d**. The suite is a ratchet — each gap found becomes permanent. Four tiers bound it further. |
| A green CI run mistaken for a verified adapter | Medium | Medium | D7 states plainly what tier 1 cannot prove: order lifecycle, authenticated channels, real 429s, fee schedules, funded-account payload shapes |
| A consumer adopts an unproven package believing it is production-ready | Medium | Medium | D15 marks every package EXPERIMENTAL in four places — README first line, hexpm `description:`, HexDocs landing moduledoc, CHANGELOG — stating plainly what is thinly covered and that nothing has run in production; the marker survives Phase 8 |
| A shipped package can never leave EXPERIMENTAL | ~~Medium~~ **Retired** | — | **Removed by D21, not mitigated.** Binance and Kraken were the two packages this described — no account is possible from the architect's jurisdiction, so neither could ever reach D15's bar. Both are now out of scope and deferred to `docs/design/ideas/binance-and-kraken-packages.md`. Every package this plan ships has a route out of EXPERIMENTAL |
| Order-lifecycle correctness never verified against a real venue (tier 4) | Medium | High | Accepted and stated (D7): rests on tier-1 shape checks, the venue's own documentation (D13) and the host's production use; `usage-rules/testing.md` tells consumers so explicitly |
| Moduledoc rationale lost in the namespace sed | Medium | Medium | Explicit instruction in Phase 1; these encode measured outages (§5.1) |
| Host fixes a venue bug mid-extraction; the package ships without it | High | **High** | Measured: 141 commits to `exchanges/` in 90 days (webull 78), **plus 12 files dirty on disk right now** — the source is live development, so committed state is not the whole picture (D19). Each extraction pins a SHA *and* the tree state, and diffs both before publishing (Phase 5.2, 5.10) |
| Coinbase/Gemini extraction blocked on the §5.5 Core change | Medium | Medium | Land the generic hooks in Phase 2.4, before Phase 6 |
| Webull's MQTT stack does not fit the contract | Low | Low | Dissolved by §6.0: both endpoints exist on every venue with no flag, and the layout below the facade is advisory. Webull is an ordinary venue whose push path is MQTT — same shape as Robinhood, whose push path is a poll loop. Still extracted last of the six |
| Publishing a package with a host-app reference | High | Low | Purity assertion in the contract suite (§6.1.7) + `mix hex.build` inspection before first publish |
| Host artifacts copied as if they were the spec, importing their defects | High | Medium | "How to read the host app" (§0) states the contract wins; D-E documents four verified `HostRateLimiter` defects; Phase 2.2 requires reimplementation with each defect as a test case |
| Package published before the repo is public; `source_url` and HexDocs links 404 | Medium | Medium | D4 makes "repo public" an explicit architect gate at each first publish (Phase 4.3, 5.12, per venue), ordered before publish; Phase 4.2 `mix hex.build` inspection is the last reversible moment |
| A secret committed while the repo is private, exposed when it goes public | **Critical** | Low | D17: every commit treated as public from #1. Four layers — `.gitignore` correct at commit #1 (Phase 0.3), GitHub secret scanning with push protection enabled while still private (Phase 0.15), `mix hex.build` inspection (Phase 4.2), and absolute rule 6's confirmation. Recorded test fixtures are the least obvious surface |
| Venue facts left in host tables; a new venue still needs a host edit | High | Medium | D12 moves the whole strategy behind the facade; `AdapterContract` assertions 10–11 (§6.1) fail any package that is not self-sufficient |
| Coinbase/Gemini must absorb a socket lifecycle they borrow today; Phase 5 underestimated | Medium | High | Called out in Phase 5 preamble and task 5.4; Coinbase pays it first so Gemini replays a known shape |
| Facade too narrow — a venue needs something it cannot express | High | Medium | Phase 5.14 retrospective is the gate; Schwab (Phase 7) is the second, greenfield test |
| Host loses the `:source` provenance its collection layer relies on | Medium | Medium | §5.4 traces each of the three rules: two describe a host mechanism the facade removes, the third survives in `coverage/1`; the host tags on receipt |
| Delistings discovered late, or a vanished pair mistaken for a delisting | Medium | Medium | Catalog change is an operational event (§6.0), pushed not diffed — critical at Schwab's catalog size; `Instrument.status` resolves unrecognised input to `:unknown`, never `:tradable`, so absence is not treated as evidence |
| Capability set too thin; venues differ in ways it cannot express | High | Medium | §6.0 now splits capabilities into activation / domain / parameters and enumerates the gaps; `alternative-trading-types.md` surveys every venue's non-spot offerings as the input |
| Equity venues alarm every night and weekend; a real outage looks like Saturday | Medium | High | §6.0 — market hours become a venue declaration via `market_status/1`; `PollingFeed`'s silence warning is the surface that misfires |
| Adapter's misreading of a venue inherited into a permanent public package | High | Medium | D13 makes the venue's own API documentation a required input for every package and the tie-breaker on conflict; Coinbase's undeclared `FOUR_HOUR` is the precedent |
| A venue's behaviour inferred from a third-party SDK rather than its docs | Medium | **High** | D13 rules third-party code out as a source entirely and ranks the alternatives. The host has already paid for this: Webull's broker host was wrong twice, once from reverse-engineering the vendor's GitHub SDK, which pointed at a different product (`webull/websocket_provider.ex:113`) |

---

## 9. Outstanding Questions

**0 open.** Answered questions do not live here — they become decisions, and the decision
carries the reasoning. Retired numbers are not reused:

| Was | Landed in |
|---|---|
| OQ1 | D1 — shared `DpExchange.*` root; the telemetry spec had already committed to it |
| OQ2 | D1 + D4 — nine names to claim; the org `HEX_API_KEY` is proven by influx-elixir |
| OQ3 | D9 — governance is whatever influx-elixir has, which is one CI workflow |
| OQ4 | D9 — coverage is 90, the code's number rather than the prose's |
| OQ5 | §7.9 — keep the memory convention, correct the slug |
| OQ6 | D1 — the namespace *is* the registry; `Module.safe_concat`, no package list needed |
| OQ7 | §7.2 — `Decimal` only; `ex_money` is mock-only and mock does not extract |
| OQ8 | D11 — extraction order |
| OQ9 | Phase 3.2 — yes, the reference fake carries a hostile symbol mapping |
| OQ10 | §6.0 — subscriptions addressed by pair (symbol for equities), no handle; venue startup is the host's |
| OQ11 | D5 — the package scopes by venue only; a host needing more throughput clusters |
| OQ12 | D4 — the flip is per repo, immediately before that package's first publish; batching was never the plan's design |
| OQ13 | D5 — `check/3` gains an explicit error case and fails closed; §0's rule is that a nearby substitute where there should be an error *is* the bug |
| OQ14 | D15 — three-state maturity kills the per-slot boolean outright; the map is function → `:proven` / `:experimental` / `:unsupported` |
| OQ15 | §6.0 — the venue declares what it *can* serve, the host decides what it *will* collect (O0). No adapter reads these today |
| OQ16 | D7 — no venue has a working sandbox |
| OQ17 | D7 — tier 2 runs per venue in Phases 5.7/6 and by hand when a venue is in question; no scheduled job hits a third party from CI |
| OQ19 | §6.0 — no escape hatch, so `get_staking_balances/2` does not cross the facade; `has_staking` is declared now and the functions wait for a deliberate Core release |
| OQ20 | §6.0 — the venue knows its own calendar and says so; the host decides what to do about it |
| OQ21 | §5.2 — the timestamp is whatever the venue gives; `Balance` gains one meaning "when we asked" |
| OQ22 | §6.0 — events are messages to the subscribing process, already the stated design |
| OQ23 | §5.4 — the host tags on receipt; the surviving rule lives in `coverage/1` |
| OQ24 | D14 — the rule already splits it: a `429` is a metric, sustained limiting is a condition |
| OQ27 | §7.3 + D18 — signalling a breaking change |
| OQ25 | **D20** — Core ships no venue-specific dependency; each venue ships its own transport |
| OQ26 | **D21** — *dissolved*, not answered: binance is out of scope, so there is no package whose entity to pick |
| OQ18 | *withdrawn* to `docs/design/ideas/external-experimental-feedback.md` |

**Nothing in Phases 0–6 is blocked.** The one remaining prerequisite is not a question
this plan can answer:

- **Blocking Phase 7**: Schwab API documentation, which the architect supplies (§10, D13).

---

## 10. Dependencies and Prerequisites

**Technical**: Elixir 1.18.4-otp-28 / Erlang 28.0.2 via Mise. Hex account with publish
rights on the DistortionPoint org. `gh` CLI for releases.

**Prerequisites before Phase 1**: this doc at `Approved`. No open question blocks it.
**Architect presence during scaffolding**: two session restarts per repo, twelve across
the six in scope (§7.1; D21's two reserved repos are not scaffolded) — after `.tool-versions`, and after `CLAUDE.md` + `.claude/agents/`.
Neither takes effect in the session that wrote it. Cheap individually; worth knowing they
are scheduled rather than surprises.


**Prerequisites before each first publish (Phase 4.3, 5.12, and each Phase 6 venue)**:
architect makes the GitHub repo **public** and adds the org `HEX_API_KEY` secret. Everything goes
to public hexpm; nothing is ever published privately.
Manual, per repo, one-time. See D4.

**Prerequisites before each venue phase (D13)**: the venue's API documentation committed
to `docs/reference/<venue>/` in that venue's repo. Public for coinbase, gemini, robinhood
and webull — fetch it. **Private for Schwab** — the architect supplies
it, and Phase 7 is blocked until it arrives, because unlike the other five there is no host
adapter to derive the venue from (D10). It is also the only source for the family's
**margin** capability — Schwab is the one in-scope venue that margins (D21 removed the
other two), so `supports_margin` / `max_leverage` cannot be shaped before it lands.

**Blocking**: none for Phase 0–6. Core Phase 0–3 depends on nothing outside this repo and
`../dp_crypto_management` (read-only).

---

## Appendix A — Source Inventory

Host app root: `/Volumes/Dev/development/dp_crypto_management`

**Core source** — `lib/dp_crypto_management/connectors/exchanges/core/`:
```
canonical_pair.ex  capabilities.ex  data_provider.ex  event_sink.ex
feed_behaviour.ex  frame_sender.ex  http_client.ex  instrument.ex
polling_feed.ex  rate_limit_behaviour.ex  symbol_normalizer.ex
telemetry.ex  timeframe.ex
types/{balance,fill,order,order_book,quote,trade}.ex
```
Plus `lib/dp_crypto_management/connectors/websocket/provider_behaviour.ex` (D-B).

**Core tests** — `test/dp_crypto_management/connectors/exchanges/core/`:
```
canonical_pair_test.exs  capabilities_declaration_test.exs  capabilities_test.exs
frame_sender_test.exs  http_client_additional_test.exs  http_client_coverage_test.exs
instrument_test.exs  polling_feed_test.exs  timeframe_test.exs
websocket_provider_behaviour_coverage_test.exs
```

**Venue sources** — `lib/dp_crypto_management/connectors/exchanges/<venue>/`
(see §6.3 for the per-venue file table).

**The host's exchange test corpus** — `test/dp_crypto_management/connectors/exchanges/`.
60 files, ~19,800 LOC — of which **46 files / ~13,400 LOC are in scope**, since D21 leaves
kraken's 8 and binance's 6 where they are. This is the **behavioural baseline** for the
extraction (Phase 5.7), not just material to port:

| Subtree | Files | LOC | Note |
|---|---:|---:|---|
| core | 10 | 2,107 | Moves with Core |
| coinbase | 11 | 4,582 | Venue #1 |
| gemini | 14 | 4,423 | Best-covered venue |
| kraken | 8 | 3,448 | *not ported — out of scope (D21)* |
| binance | 6 | 2,937 | *not ported — out of scope (D21)* |
| webull | 7 | 879 | **Thin** — 11 source files, 4,330 LOC |
| robinhood | 2 | 332 | **Thinnest** — 4 source files, 1,124 LOC |
| mock | 2 | 1,094 | Host-side double; does not move (D10) |

**The coverage is inversely correlated with the strangeness of the code**, which is worth
knowing before relying on it. Webull is the most unusual venue in the family — MQTT,
protobuf, a session plan — and carries 879 LOC of tests against 4,330 of source. Robinhood
is thinner still. So the baseline is weakest exactly where behaviour is least obvious, and
Phase 6.2 and 6.3 get less help from it than the numbers suggest.

Adjacent, and **not** part of the extraction (D12 keeps the mechanism host-side):
`connectors/rate_limiting/` 9 files / 4,024 LOC, `connectors/websocket/` 22 files /
10,741 LOC.

**Coinbase tests** — `test/dp_crypto_management/connectors/exchanges/coinbase/`
(10 files, 4,478 LOC):
```
coinbase_provider_test.exs  coinbase_provider_v2_test.exs
coinbase_provider_additional_test.exs  coinbase_provider_boost_test.exs
coinbase_provider_coverage_test.exs
coinbase_websocket_provider_test.exs
coinbase_websocket_provider_comprehensive_test.exs
coinbase_websocket_provider_coverage_test.exs
coinbase_websocket_provider_extra_test.exs  coinbase_ws_boost_test.exs
```
Note `test/dp_crypto_management/trading/execution/adapters/coinbase_test.exs` (52 LOC)
is a **host-side** execution adapter test, not a connector test. It does not move.

**Binance tests** — `test/dp_crypto_management/connectors/exchanges/binance/`:
```
binance_provider_test.exs  binance_provider_coverage_test.exs
binance_websocket_provider_comprehensive_test.exs
binance_websocket_provider_coverage_test.exs
binance_websocket_provider_extra_test.exs  binance_ws_boost_test.exs
```
```

**Host source worth reading** (the `docs/` corpus is inventoried in **Appendix C**):
- `lib/dp_crypto_management/connectors.ex` — the facade moduledoc; states the
  OSS-readiness invariant and names the future packages
- `test/credo/no_app_deps_in_exchanges.ex` — the invariant as an enforced check
- `lib/dp_crypto_management/rate_limiting/host_rate_limiter.ex` — read alongside D-E; the
  shape is right and the implementation is not

## Appendix B — The OSS-Readiness Invariants

Invariants 1–6 come from the host's closed four-area plan and predate this document;
**#7 is added by this plan** (D12). Together they are the acceptance criteria the packages
are judged against:

1. Adapters **emit events**, they don't broadcast. The host broadcasts. **And they emit to
   whoever subscribed, not into a sink the host handed them** (D6) — the original wording
   allowed an injected sink, which is the same coupling one level down.
2. Adapters **accept credentials** as function args or `start_link` opts. They don't read
   from a vault.
3. Adapters **call a rate-limit behaviour**, they don't depend on our rate-limit module.
4. Adapters use **only declared Hex deps**, no app modules.
5. Adapter return types are **`Core.Types.*`**, not Ash resources.
6. Adapter tests use **record-replay fixtures / in-process fakes**, not host test
   infrastructure — and per D7, never a mocking library.

**D12 adds a seventh, and sharpens the third.** Invariant 3 said adapters *call* a
rate-limit behaviour rather than depending on the host's module — true, but it still
assumed the enforcement happened somewhere outside the adapter. Under D12 it does not.

7. A venue package is **self-sufficient behind an identical facade**: it owns its
   transport, its limiter, its credential/session handling and its supervision tree, and
   the host reaches none of them. The only things crossing are credentials and options in,
   `Core.Types.*` results, pushed `Core.Types.*` events, `Core.Notice`s about the
   package itself, and telemetry out (§6.0). Nothing is injected — the package emits on
   every channel and the host connects (D6).

## Appendix C — Mining the host's `docs/` (source 5)

`../dp_crypto_management/docs/` holds roughly 130 documents from a long development.
Ranked by what it gives *this* project. **Read for reasoning, not current state** — the
arguments age well, the facts drift.

### Highest value: `bugs/fixed/` — 13 reports, and they are about D7's pattern

Every one is a bug the host filed against `influx_elixir`, and eleven are `Client.Local`
**fidelity gaps** — the shipped in-process fake this plan copies (D7). This is the closest
thing to an experimental result the org has on whether that pattern holds — and the result
is positive: thirteen found by the first consumer, thirteen fixed, none reaching an
external user across 2,000+ downloads in 30 days (D7). Read all thirteen before writing
Core's reference fake (Phase 3.2) or any venue fake — they are a catalogue of how an
in-process fake drifts. The silent ones matter most:
`…-resolve-params-atom-keys` (all parameterised queries silently wrong),
`…-aggregate-time-where` (every windowed query empty),
`…-quoted-measurement`, `…-ignores-write-timestamp`, `…-facade-integration`.

### Directly load-bearing

| Doc | Why |
|---|---|
| `design/closed/2026-05-20_four-area-architecture-reorganization.md` | Origin of invariants 1–6 of Appendix B (#7 is this plan's, from D12); the "shim" concept |
| `design/closed/2026-06-30_boundary-violation-audit-and-refactor.md` | Where `EventSink` came from; boundary reasoning that D12 extends |
| `design/closed/2026-06-03_webull-robinhood-providers.md` | Decision 6 deferred this extraction; the two venues that broke the shared-mechanism assumption |
| `design/2026-08-05_exchange-quote-currencies-and-decoupled-data-collection.md` | `Instrument`, collection-scope capability fields, and why they are host policy (§6.0) |
| `development/secrets.md` (124) | **The config and secrets convention, verbatim** — `.env.sample`, the `.env*` gitignore pair, and the `runtime.exs`-only env rule. §7.7 is a summary; this is the source |
| `architecture/symbol-lifecycle.md` (170) | States, enforcement, the override, "reverted forces are a defect report" — feeds `Instrument` and `CanonicalPair` |
| `architecture/integration-patterns.md` (897) | The largest single account of how venues are integrated |

### Worth reading with care

| Doc | Caveat |
|---|---|
| `design/closed/2025-06-05_coinbase-gemini-api-integration-planning.md` | By far the densest on venues (520 hits) but the oldest — the original integration reasoning, much of it since superseded |
| `architecture/exchange-capabilities.md` (272) | Selection criteria and the feature-compatibility matrix are useful; **its venue list is stale** — Kraken and Robinhood listed "planned", Binance "excluded", all three ship today |
| `design/closed/2026-04-23_small-capital-trade-economics.md` | Fee/quantization reasoning behind `quantization/1` |
| `design/ideas/exchange-mcps.md` | An unbuilt idea in this space; check it does not conflict before Phase 2 settles the facade |
| `design/ideas/alternative-trading-types.md` | Per-venue survey of staking, margin, futures, options, earn, recurring buys — the input to §6.0's capability taxonomy and the staking decision |

### Method

Mining is a Phase 1 activity, not a prerequisite — Core's mechanical moves do not wait on
it. Findings land in three places and nowhere else: a moduledoc (if it explains why code is
shaped as it is), a `usage-rules/` entry (if a consumer needs it), or an OQ (if it is
undecided). A finding that fits none of those is interesting, not useful; leave it.


---

   `Core.Types.*` results, pushed `Core.Types.*` events, `Core.Notice`s about the
   package itself, and telemetry out (§6.0). Nothing
   is injected — the package emits on every channel and the host connects (D6).

---

**Document Status**: Draft — awaiting architect review. Next step: move to `Approved` and
begin Phase 0. No open question blocks Phase 1.
## 11. Retrospective

*Written at Phase 8.3, not before. Empty is the correct state until the work is done —
these headings are the questions to answer, taken from what the host's own plans found
worth recording.*

**Outcome.** What actually shipped, measured rather than asserted: which packages published,
at what versions, what the host adopted and when. State the numbers.

**What this plan produced that was not in its scope.** The host's quote-currency plan found
fabricated OHLC in the candle store while measuring venues for a capability field — a bug
worth more than the plan's stated deliverable. Extraction reads six adapters against six
vendors' documentation (D13); record what that reconciliation turned up that nobody was
looking for.

**The recurring failure mode, stated once.** The host's plans each found one shape of bug
that repeated. This plan already carries a candidate — *a nearby substitute where there
should be an error* (§0, and D-E's `1..0` producing `[1, 0]`) — but that is a hypothesis
inherited from the host, not a finding. Say what this work's actual repeated shape was, and
where the countermeasure now lives in code.

**What the plan itself got wrong, corrected by doing it.** The specific decisions that did
not survive contact — with what replaced them and what the evidence was. D5, D6 and D12
already record one reversal apiece before implementation started; expect more from Phase
5.14's retrospective and each Phase 6 venue.

**What the gates were worth.** Phase 4 holds Core's publish; Phase 5.14 holds every replay
until the reference extraction's lessons are folded back; D4's architect gate holds every
first publish. Each cost time deliberately. Say whether each hold paid, and for the reason
recorded rather than caution in general.

**What the contract missed.** §6.1's conformance suite is the mechanism that is supposed to
keep five packages identical. Every assertion added after Phase 3 is a gap it did not have
— list them, because that list is the honest measure of how good the contract was on the
day it froze (D2).

**Feeds the idea docs.** Anything about noticing vendor API change goes to
`docs/design/ideas/detecting-vendor-api-change.md` (Phase 8.3). Anything about verifying a
venue we cannot hold an account on goes to
`docs/design/ideas/external-experimental-feedback.md` and
`docs/design/ideas/binance-and-kraken-packages.md` (D21).

---

**Last Updated**: 2026-08-28 (v1.80 — **PHASE 4 COMPLETE. `dp_exchange_core` is live on public hexpm.** `0.1.1` published on the first push to `main`, `0.1.2` the same day. CI green both times, both jobs; the auto-increment, tag, release and bump-commit all behaved as §7.3 documented. **4.5 earned its place**: the conformance suite shipped in the tarball but was never *compiled* into a consumer, because a dependency is not built in the `:test` environment — D8 broken twice over, and 3.6's check could not see it because it asserted the tarball rather than the outcome. Moved to `lib/`, verified from Hex in a clean project. Assertion 7 now reads beam paths instead of a name list, which also catches an undeclared dependency. 49/77 tasks. Next: Phase 5, Coinbase.)
**Next Review**: before the first push — secret scanning + push protection (0.15)
