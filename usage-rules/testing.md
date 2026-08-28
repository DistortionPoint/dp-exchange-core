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

Thirteen assertion groups. It ships inside the Hex tarball, so you get it as a dependency
and run it against yourself. **Prose in six `CLAUDE.md` files drifts; a suite running in
five CI pipelines cannot.**

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

## Tests must be deterministic

Three things worth stating because they have each cost a debugging session here:

- **`function_exported?/3` returns false for a module that is merely not loaded.** Call
  `Code.ensure_loaded!/1` first, or the assertion tests something other than what it says.
- **Never assert on node-global counters** — `:erlang.system_info(:atom_count)` and
  friends move because of other async tests. Assert the local property instead.
- **Synchronise on events, not on elapsed time.** A `Process.sleep/1` before an assertion
  races whatever it is waiting for. Widening the sleep converts a visible flake into a slow
  one.
