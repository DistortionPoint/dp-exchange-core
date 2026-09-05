# Building a venue package

The per-repo checklist. Every step exists because skipping it has cost something.

## 0. Before any code

- [ ] **Get the venue's own API documentation** and commit the relevant extracts to
      `docs/reference/<venue>/`. The vendor's documentation site — **not** a GitHub SDK,
      not a community write-up, not another client library.

      This is the rule that costs the most to skip. One venue's broker host was wrong
      twice, once from reverse-engineering the vendor's own GitHub SDK, which turned out
      to point at a different product entirely.

- [ ] **Commit it, do not link it.** A link moves; a commit makes the implementation
      reproducible and reviewable against a fixed source.

- [ ] If the docs describe a sandbox, **verify it actually works** before relying on it.
      None of the venues checked so far has one that does.

## 1. Scaffold

- [ ] Copy the repo standard: `.tool-versions`, `.gitignore` (with the `.env*` /
      `!.env.sample` pair and `.mcp.json`), `.formatter.exs`, `.credo.exs`,
      `.sobelow-conf`, `LICENSE`, `.github/workflows/ci.yml`, `config/`, `CLAUDE.md`,
      `.claude/agents/`, `docs/design/`.

- [ ] **Two session restarts, in this order**: `.tool-versions` alone and first, then
      everything else, then restart again before writing code. Neither the toolchain nor
      `CLAUDE.md` takes effect in the session that wrote it — a session that writes rules
      it cannot see will cheerfully violate them.

- [ ] `mix.exs`: `{:dp_exchange_core, "~> 0.1.0"}` — **three segments**, because while
      Core is `0.x` a minor bump may break you and that is the signal it is meant to send.

- [ ] `description:` prefixed `EXPERIMENTAL — `. It is what hexpm search shows, and for
      many readers it is the only text they see.

## 2. Declare before you implement

- [ ] Write `capabilities/0` **from the documentation, before the provider**. Deriving the
      declaration from the code you already wrote tells you what you built, not what the
      venue does.

- [ ] Record `measured_at` and `measured_against` for anything you probed, and leave them
      `nil` for anything you only read. An unlabelled number is worse than a missing one.

- [ ] Declare `:experimental` for everything. `:proven` is earned by production use.

- [ ] **When the venue has no answer, say so positively rather than leaving a field
      empty.** Five extractions found the same shape five times: a field whose `nil` reads
      as "nobody filled this in" when the truth is "the venue does not have one". Each of
      these is a statement, not a gap:
      - `max_leverage: :per_account` — margins, but the ceiling belongs to the account.
      - `authenticated_ceiling: nil` on a venue with real limits — the limit is a property
        of *your registration*, not the venue. Configure it; do not declare it.
      - `historical_timeframes: []` — no candle endpoint at all. Declaring a width you
        cannot serve is worse than declaring none.
      - `max_candles_per_request: nil` when the cap is a *period* rather than a count.
      If the contract cannot express your venue's answer, that is a Core gap — record it
      in the plan rather than picking the nearest field that almost fits.

- [ ] **Declare the order-shape fields even when they are all `false`.** `supported_sessions`,
      `supports_order_preview`, `supports_order_replace`, `supports_multi_leg_orders` and
      `catalog_access` all default to the crypto answer, which is right for a crypto venue
      and silently wrong for anything else. `Capabilities` raises if you claim preview,
      replace or multi-leg while `place_order/3` is `:unsupported`, and if you claim
      `catalog_access: :query_only` while `get_symbols/1` is — but it cannot catch a venue
      that quietly accepts the defaults.

- [ ] **Give a `ceiling` a `:scope` unless it really is per-credential.** `:account` and
      `:application` exist because a limiter keyed the wrong way over-permits, and the
      symptom is being throttled by the venue rather than by you. `limit: 0` is legal and
      means a registration with no throughput — not the same as `:unsupported`.

- [ ] **Check `historical_timeframes` against `Timeframe.nameable/0`, not `known/0`.**
      `1w` and `1M` are nameable and deliberately unbucketable. A venue serving them is
      normal; Core just cannot tell you where a weekly bucket starts.

## 3. Implement

- [ ] `@behaviour DpExchange.Core.Venue` on your one public module. The compiler's
      missing-callback check is the cheapest assertion you get.

- [ ] Your transport, your dependency. Core ships no `websockex` and never will; a venue
      that speaks WebSocket declares it for itself.

- [ ] Both endpoints. If the venue has no streaming API, `subscribe/2` polls internally
      and pushes — that is your job, not your caller's problem.

- [ ] `coverage/1` reports **observed** delivery. If you cannot observe it, say
      `:not_covered`.

- [ ] Fail closed everywhere. A timeframe you do not serve is an error, not the nearest
      width.

## 4. Reconcile against the host adapter, if one exists

- [ ] Diff your implementation against the existing adapter and **record every deliberate
      divergence**. The documentation wins on conflict, but the adapter often encodes a
      production lesson the documentation does not mention.

- [ ] Carry the incident moduledocs. Where a comment explains *why* a guard exists, that
      is the most valuable text in the file and it does not survive a careless copy.

## 5. Test

- [ ] `use DpExchange.Core.AdapterContract` — 14 assertion groups (see
      `DpExchange.Core.AdapterContract.assertions/0`), green.

- [ ] Your fake satisfies the same suite as the real adapter. Less capable is allowed;
      differently capable is not.

- [ ] Per-process isolation for the fake. Your consumer runs `async: true` and a
      node-global switch makes your package unusable in their suite.

- [ ] Tier-2 tests against the venue's public endpoints — tagged, excluded from CI, run
      **by hand**. A venue that sees you polling on a timer will rate-limit or block.

- [ ] Port the host's tests as a behavioural baseline where one exists, and record what
      you deliberately changed.

## 6. Ship

- [ ] `mix quality` clean, coverage at threshold, `mix test --cover` green. **Both gates —
      neither implies the other.**

- [ ] `usage-rules.md` for your venue: what is unusual about it, what your fake does not
      model, what a caller should not assume.

- [ ] `mix hex.build`, then **read the tarball listing**. Nothing from `config/`, no
      `.env`, no `.mcp.json`.

- [ ] Run the D17 audit before the first commit: `git status --ignored`, and a content
      scan for credential shapes across everything git would track.

- [ ] **Architect gate**: repo made public, org `HEX_API_KEY` added. Once per repo, and
      until it happens the package cannot publish — which is the intended safety.

## 7. Afterwards

- [ ] File the adoption issue on the consuming repo.
- [ ] Every fake divergence a consumer finds becomes a new assertion **in Core's shared
      suite**, not only in your fake. A gap fixed locally is one the next venue
      reintroduces.
