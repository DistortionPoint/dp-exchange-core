# Testing, fakes and isolation

## Run the conformance suite

```elixir
defmodule DpExchange.YourVenue.ContractTest do
  use DpExchange.Core.AdapterContract,
    venue: DpExchange.YourVenue,
    symbol_format: DpExchange.YourVenue.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD),
    credentials: %{api_key: "test", api_secret: "test"}
end
```

Seventeen assertion groups, listed in `DpExchange.Core.AdapterContract.assertions/0`. It
ships inside the Hex tarball, so you get it as a dependency and run it against yourself.
**Prose in six `CLAUDE.md` files drifts; a suite running in five CI pipelines cannot.**

## The four verification tiers, and only two ever run unattended

1. **In-process fakes** — every CI run. The default.
2. **Live public endpoints** — per venue, **by hand**, during its extraction. *Never on a
   schedule*: a venue that sees a package polling it on a timer will rate-limit or block.
3. **Authenticated, read-only** — needs credentials a public repo must never hold. Runs
   where the keys already are, which is a consumer's machine, not this repo's CI.
4. **Money-moving** — never a test. It is answered in production by a consumer trading
   live, and that is what moves an endpoint to `:proven`.

**What a green CI run does not prove**: that the venue behaves as your fake does. Tier 1
proves your code is self-consistent. Nothing below tier 3 proves it is *right*.

## No mocking

Use real fixtures and real processes. A mock asserts that your code called what you
expected, which is a restatement of the code rather than a test of it.

Your fake is a **real implementation of the facade** that happens to answer from memory.
It runs the same conformance suite as the real adapter.

## Two rules for your fake, from thirteen real bug reports

Eleven of thirteen bugs found in a comparable in-process fake were the fake diverging from
the real client. Six were *loud* — the fake rejecting what the real thing accepts — which
cost time and nothing else. Three were *silent*, and those are the ones to design against:

1. **Less capable is allowed. Differently capable is not.** Where the fake cannot answer,
   it returns an error. It never returns an empty success for something unsupported — the
   original answered `{:ok, []}` to an unsupported query and silently dropped clauses it
   could not parse, so callers got plausible wrong answers rather than failures.
2. **Never rewrite a value the caller supplied.** The original discarded the caller's
   timestamp and substituted the current clock, landing points written 900 seconds apart
   microseconds apart.

**Every divergence found becomes a new assertion in the shared suite.** A gap fixed only in
your fake is a gap the next venue reintroduces. That ratchet is why a comparable suite grew
to over a thousand lines and why none of those thirteen bugs ever reached an external user.

## Isolate the fake per process — this is a hard requirement

Your consumer runs `async: true`. `Application.put_env/3` is node-wide. **Any seam a
consumer's tests need to vary must be resolvable per process**, or your package is unusable
in their suite.

```elixir
# In a test, for its own process tree only:
DpExchange.Core.Config.put_override(:your_venue_fake, MyFake)

# In your package, at call time — never compile time:
DpExchange.Core.Config.get(:dp_exchange_core, :your_venue_fake, RealClient)
```

Resolution order: this process's dictionary, then the `$callers` ancestor chain, then
application env.

**The `$callers` walk is the step people omit**, and omitting it works in simple tests and
fails in exactly the concurrent ones the seam exists for. ExUnit propagates `$callers` to
spawned `Task`s.

### Crossing a process boundary needs one more step

A `GenServer` runs in its own process and is not in the caller's `$callers` chain, so it
will not find the override at all. **Snapshot in the caller and put it in the message:**

```elixir
snapshot = DpExchange.Core.Config.snapshot([:your_venue_fake])
GenServer.call(server, {:fetch, symbol, snapshot})
```

Resolving inside the server is too late, and it fails in the direction that looks like it
works: production is unaffected, so only your consumer's async suite breaks.

### Why this is non-negotiable

Seven tests once set a global rate-limiting flag for their duration, and for that duration
every other async test on the node was metered against a one-request bucket. An unrelated
WebSocket test came back `{:error, {:rate_limited, 1}}` while asserting on connection
errors. The failure was silent, intermittent and seed-dependent.

**A consumer will want venue A faked while venue B is real, and two tests will want the
same fake to behave differently — one returning `429`, one succeeding.** Global config
cannot express that at all.

## Making a fake fail on demand, and skipping its credential check

Every venue's `Fake` is wired to `DpExchange.Core.FakeInjection` — a deterministic seam
for exercising your own retry/circuit-breaker/alerting code against a `Venue`
implementation, and for testing pure dispatch/decode logic without constructing
valid-looking credentials for every call.

```elixir
# Make the next call fail once, then resume normal fake behaviour:
DpExchange.Core.FakeInjection.queue_failures(:coinbase, [{:error, :timeout}])
DpExchange.Coinbase.Fake.get_price("BTC-USD", credentials: creds)  #=> {:error, :timeout}
DpExchange.Coinbase.Fake.get_price("BTC-USD", credentials: creds)  #=> {:ok, %Quote{}}

# Make every call for one symbol fail, indefinitely — every other symbol is untouched:
DpExchange.Core.FakeInjection.fail_always(:coinbase, "ETH-USD", {:refused, :not_listed})

# Skip a venue-faithful credential refusal, for a wiring-only test. Robinhood's `Fake`
# gates every call on `credentials:` (the real venue signs everything); this bypasses
# that refusal without changing it for anyone who doesn't opt in:
DpExchange.Core.FakeInjection.bypass_credentials(:robinhood)
DpExchange.Robinhood.Fake.get_price("BTC-USD", [])  #=> {:ok, %Quote{}}, no credentials needed
```

**Not every venue's `Fake` gates credentials centrally, and this does not add a check
that was never there.** Coinbase's `Fake`, for instance, has no single credential
refusal to bypass — most of its functions never inspected `credentials` in the first
place, and `bypass_credentials/1` has nothing to do there. Check the venue package's own
`Fake` moduledoc for whether it applies.

**There is no `error_rate`-shaped knob and there will not be one.** Every outcome is
queued explicitly and consumed in order — a test that fails 30% of the time on its own
schedule is not more useful than one that never fails. `queue_failures/2,3` pops one
entry per matching call; `fail_always/2,3` never pops, for "every call fails" until you
call `FakeInjection.reset/1`.

**Per-symbol targeting is real isolation, not a convention to remember.** A
symbol-specific override can never be satisfied by, or interfere with, a call for a
different symbol — the same rule this family applies everywhere a batch could otherwise
let one bad member take down the rest.

Built on the same `Config` process-scoped override machinery as everything else on this
page, so it inherits the identical `async: true` / `$callers` isolation guarantee — and
the identical limitation: injection configured in your test only reaches a `Fake`
function called from your test's own process or a `Task` it spawns, not from inside a
separately-supervised `GenServer`.

**Not every function is wired.** A `Fake` function that takes a *list* of symbols in one
call — a venue's own bulk subscribe, say — is deliberately left out: whole-call injection
can pick the outcome one call returns, but it cannot express "this one symbol in the
batch fails, the rest succeed." Check the venue package's own `Fake` moduledoc for which
functions are wired.

## Tests must be deterministic

Three things worth stating because they have each cost a debugging session here:

- **`function_exported?/3` returns false for a module that is merely not loaded.** Call
  `Code.ensure_loaded!/1` first, or the assertion tests something other than what it says.
- **Never assert on node-global counters** — `:erlang.system_info(:atom_count)` and
  friends move because of other async tests. Assert the local property instead.
- **Synchronise on events, not on elapsed time.** A `Process.sleep/1` before an assertion
  races whatever it is waiting for. Widening the sleep converts a visible flake into a slow
  one.

## Which tier each capability group can actually be verified at

The surface grew to 88 callbacks. **Most of the new ones cannot be verified above tier 1
here, and saying which is which is the point of this table** — a group that CI cannot reach
is a group whose correctness rests on the reference documentation and a consumer's
production use, and a package author should know that before shipping it.

| capability group | highest tier reachable | why |
|---|---|---|
| quotes, book, candles, instruments | **2** — live public endpoints | public on every venue but Robinhood and Schwab, which need a credential for everything |
| options chains, expirations, greeks | **2** on Webull and Schwab | public where the venue publishes them |
| fundamentals, screeners, news | **2** on Webull | public |
| accounts, balances, positions, fills | **3** — authenticated, read-only | needs credentials this repo must never hold |
| order placement and cancellation | **3 on Gemini only** | its demo environment is a full exchange with test funds |
| order placement everywhere else | **4** | no sandbox exists; the first real call is a real order |
| staking, custody (Coinbase Prime) | **3**, institutional credentials only | nobody in this project holds them |
| **money movement** | **4 — never a test** | answered in production by a consumer with real funds; see `usage-rules/money-movement.md` |
| token refresh and rotation | **3** | needs a live grant, and Schwab's refresh is one-time-use so a test spends it |

**Gemini's demo environment is the one place this changes.** Order placement, cancellation
and balances move from tier 4 to tier 3 there — real venue machinery, fake money — which is
why the authenticated endpoints exist in that package at all. See
`usage-rules/environments.md`.

## A refresh test spends a real token

Schwab's refresh token is one-time use and every refresh mints a replacement. **A test that
calls `Auth.refresh/2` against the live venue consumes the credential it was given** and
returns a new one that must be persisted or the account is lost until a person logs in
again.

So the refresh path is tested at tier 1 against a fake token endpoint, and the tier-3
version is run by hand, once, by someone holding the credential and ready to write the result
down. That is not a gap in the suite — it is the honest cost of an at-most-once operation,
and it is why `refresh/2` forces retries off rather than trusting a test to remember.

## Fakes grow with the surface, and a stale fake is worse than a missing one

Every callback a package implements needs a fake clause. A fake that has not kept up answers
`{:error, :not_supported}` for something the real adapter now serves — which is **the
false-negative defect, reproduced inside the test suite**, and it will make a correct
implementation look broken.

Two rules that fall out of that:

- **Add the fake clause in the same change as the real one.** The conformance suite runs
  against both, so a missing clause fails immediately; a *wrong* one does not.
- **A fake never returns an empty success for something unsupported.** `{:ok, []}` for a
  query it could not parse is the exact silent divergence this guide's thirteen bug reports
  were mostly made of.

## Coverage is a floor, not a finish line

The threshold is 90 and CI enforces it. Two things it does not measure, both of which have
bitten this family:

- **A default-argument head counts as a line.** An unused `\\ []` head is counted as missed
  and can drop a package below the threshold while nothing is actually untested. Delete the
  head rather than writing a test for it.
- **Coverage says nothing about whether the fake resembles the venue.** Tier 1 proves your
  code is self-consistent. Nothing below tier 3 proves it is right.
