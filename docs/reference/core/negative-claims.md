# Core — every negative this package makes, and what is behind it

**Audited 2026-09-03.** Core talks to no exchange, so its negatives are a different kind from
a venue package's. They are claims about **the contract, the ecosystem, and the family** —
"no venue needs this", "Hex does not do that", "there must never be a field for this" — and
they are load-bearing in the same way: five packages are built on them, and a wrong one
propagates five times.

The rule is the venue rule, restated for a package with no venue: **an unverified negative is
a substitution exactly like an invented value.** A design constraint asserted without a
reason is indistinguishable from one that was measured, and only the second survives someone
asking why.

## Claims about the contract's own shape

| claim | verified how | holds? |
|---|---|---|
| **There is no `has_websocket` and there must never be one** | design, not measurement — and the reason is stated: both endpoints exist on every venue, so transport is never a capability. Enforced by `Capabilities.new/1` having no such field | ✅ |
| `authenticated_streamable` must be a superset of `streamable` | enforced in code by `validate_streaming!/1`; a kind that streams anonymously and not with a credential is not a thing a venue does | ✅ |
| **Weekly and monthly have no boundary rule and never will** | a weekly bar's start depends on which weekday a venue begins its week; a month is not a fixed number of seconds. `seconds/1` returns `:error` and `aligned?/2` returns `true` — "no rule" means "cannot check", never "invalid" | ✅ |
| `historical_timeframes: []` means the venue publishes no candle endpoint | enforced: `Capabilities` raises if a package claims history without naming widths | ✅ |
| **`limit: 0` is legal and is not `nil`** | Schwab grants order throughput per registration, and zero is a real grant. Verified against its portal, 2026-08-31 | ✅ |
| `max_leverage: :per_account` is not a missing value | a Schwab margin account carries five buying powers that are not multiples of one another; a cash account carries none. No scalar is true | ✅ |

## Claims about the ecosystem

These are the ones most likely to be wrong by drift, because they are claims about somebody
else's software.

| claim | verified how | holds? |
|---|---|---|
| **A `files:` in `project/0` is silently ignored; Hex reads `package[:files]`** | measured, not read: the tarball shipped a 4.4 MB PLT while `usage-rules.md` and the conformance suite did not. Nothing warned | ✅ — and it is why `mix hex.build` output is inspected before every publish |
| **A dependency is never compiled in the `:test` environment** | measured: the conformance suite shipped from `test/support` and arrived uncompiled and unusable in the consumer. It lives in `lib/` for that reason | ✅ |
| `Application.compile_env/3` freezes the *consumer's* config at dependency-compile time | Elixir documented behaviour; the reason this library prefers `get_env/3` everywhere a consumer is meant to configure something | ✅ |
| **A `cast` to a dead or restarting process returns `:ok` and is dropped** | OTP documented behaviour, and the incident behind the notice channel's design: two symbols suspended at 03:14 and 03:27 UTC opened fresh positions at 21:46 | ✅ |
| ExUnit propagates `:"$callers"` to spawned `Task`s | documented, and relied on by `Core.Config`'s ancestor walk — the step whose omission makes the seam work in simple tests and fail in concurrent ones | ✅ |

## Claims about the family

| claim | verified how | holds? |
|---|---|---|
| **Core ships no venue-specific dependency** | `mix.exs` has no `websockex` at any strength, not even `optional: true`. A venue that speaks WebSocket ships what it needs | ✅ |
| **Core ships nothing venue-specific in the tarball** | `files:` lists `lib`, `mix.exs`, `.formatter.exs`, `README.md`, `LICENSE`, `CHANGELOG.md`, `AGENTS.md`, `usage-rules.md`, `usage-rules` and `docs/guides`. `docs/guides` holds one file, and it is about writing a venue package — Core's own subject. Checked 2026-09-03 | ✅ |
| No `Application` module; nothing starts on load | there is no `mod:` in `application/0`. A consumer who has not asked for a venue does not find a socket open | ✅ |
| `config/` does not ship | absent from `files:`; it governs this package's own dev and test only | ✅ |

## One that needed correcting, and it was a packaging claim

7.5 MB of saved Schwab portal HTML sat in **`docs/guides/`**, which *is* in `files:`. It
would have published inside `dp_exchange_core` — venue-specific material shipping from the
package whose whole premise is that it has none.

It was moved to `docs/reference/`, which does not ship, on 2026-08-31. **The curated version
lives in `dp_exchange_schwab`**; what remains here is the unprocessed original, kept because
it cost a login to obtain.

**Its ideal home is still the Schwab repository, and it has not been moved there.** Nothing
ships from Core because of it and no claim in this file is affected, but the raw capture
remains venue material sitting in Core's repository, and this line is here so that is a
recorded state rather than an oversight.

## What is not audited here, and why

Core makes no claim about what any venue does or does not serve. Every such claim lives in
the venue package that makes it, next to the endpoint inventory it was read from:

- `dp_exchange_coinbase/docs/reference/coinbase/negative-claims.md`
- `dp_exchange_gemini/docs/reference/gemini/negative-claims.md`
- `dp_exchange_webull/docs/reference/webull/negative-claims.md`
- `dp_exchange_schwab/docs/reference/schwab/negative-claims.md`
- `dp_exchange_robinhood/docs/reference/robinhood/negative-claims.md`

Across those five, the audit found **nine false negatives** — working endpoints a consumer
was being refused — and **four mislabelled absences**, where a venue's own gap was filed as
this family's backlog. None of the thirteen was found by a test. Nothing fails when a comment
is wrong, which is the entire argument for auditing them on a schedule rather than on
suspicion.
