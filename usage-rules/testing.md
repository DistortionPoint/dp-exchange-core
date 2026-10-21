# Testing, fakes and isolation

## Run the conformance suite

```elixir
defmodule DpExchange.YourVenue.ContractTest do
  use DpExchange.Core.AdapterContract,
    venue: DpExchange.YourVenue,
    fake: DpExchange.YourVenue.Fake,
    symbol_format: DpExchange.YourVenue.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD),
    credentials: %{api_key: "test", api_secret: "test"}
end
```

Fifty-three assertion groups, listed in `DpExchange.Core.AdapterContract.assertions/0`. It
ships inside the Hex tarball, so you get it as a dependency and run it against yourself.
**Prose in six `CLAUDE.md` files drifts; a suite running in five CI pipelines cannot.**

**Groups 52 and 53 need nothing from you and fail a package that breaks a rule the contract
already states.** Group 52: a float, zero, a negative, NaN or infinity as the `:quantity` or
`:price` of `place_order/3` (when active) must be `{:error, {:invalid_quantity, value}}` or
`{:error, {:invalid_price, value}}`, the value as given, on your fake. Your `order_args:`
request must carry a `:quantity` or a `:price` to spoil, or the group fails rather than pass
having probed nothing. Group 53 reads your source under `package_root:` (and the static
`config/*.exs` files) and fails on an atom made from text (`String.to_atom/1`, `:"x_#{y}"`,
`Module.concat/2` of anything but literals: use a closed lookup, or `String.to_existing_atom/1`
with the `ArgumentError` turned into a refusal), on `:erlang.binary_to_term/1` without
`[:safe]`, on `Application.compile_env/3` (read a consumer's configuration at call time with
`Application.get_env/3`), and on `System.get_env/1` anywhere but `config/runtime.exs`. Group 26
now also ends the add/remove cycle by unsubscribing the last symbol and expects `coverage/1`
to be empty: a fake that keeps an entry per symbol it was ever asked about fails it.

**Group 51 is opt-in and skips until you supply `process_probe: {Module, :function}`.** It is
the credential check that reaches the process which holds the credential for its lifetime, as
groups 19 (the struct) and 22 (the stored child spec) cannot. Your function takes a credentials
map holding a canary under every secret key name, starts your feed and/or socket **with no
network** (the fake transport, a stub, a port nothing listens on) and answers `{:ok, pid}` or
`{:ok, [pid, ...]}`. The group renders `:sys.get_status/2` of each, which carries the process
dictionary and the state OTP prints in a crash report, and fails if the canary is in it. Hold
the credential in a struct with a redacting `Inspect`, or define `format_status/1` on the
process; a probe that starts nothing it can examine fails the group rather than skipping it.

**Group 50 needs nothing from you: it holds the order-write discipline of the preview and
replace calls, when they are active.** `replace_order/4` given an empty change map or a
non-map answers `{:error, {:invalid_order_request, value}}`, and `preview_order/3` given a
request `place_order/3` refuses (a non-map, no `:order_type`, an unread key) answers the same
tuple. **Group 17 no longer lets a raise stand for a refusal:** with credentials stripped, a
fake must not answer `{:ok, _}` and must not raise, exit or throw.

**Two checks in group 41 are opt-in and skip until you name the fact only your fixture
knows.** Group 41 holds your fake to two family reasons: `unlisted_symbol: "ZZZ-USD"` (a well-formed symbol the
fake does not list; `get_price/2` for it must be `{:refused, :not_listed}`) and
`padded_credentials: %{api_key: " key\n", ...}` (a credentials map with surrounding
whitespace; `get_balances/2` with it must be `{:error, {:invalid_credentials, runtime_id}}`).
Group 40 needs nothing: when your fake exports the optional `wanted/1`, it must hold every
symbol subscribed and every symbol `coverage/1` reports.

**Group 42 is opt-in and skips until you supply the seam: `ambiguous_place_order:`.** A fake
cannot fail after sending, so you pass a 1-arity function that takes an order request map and
runs your **real** `place_order/3` path with a transport fault after the send, for example a
`Req` plug that returns a transport error or a 503 on every attempt:

    ambiguous_place_order: fn request -> MyVenue.place_order(creds, request, plug: down_plug) end

Group 42 asserts that answer is `{:error, {:order_unconfirmed, id, reason}}` (`id` is the
request's `client_order_id` when the request carried one, else `nil`, and a list of ids for a
batch), and that the same function given a request
refused before sending (no `:order_type`) is a plain or refused error, never `:order_unconfirmed`.

**Group 43 needs nothing from you: it holds your fake to refusing an option nothing reads, on
every endpoint it serves.** For each callback of `Core.Venue` that `capabilities/0` declares
active (reads, credentialed reads, writes and feed calls alike) the suite calls your fake with
your `endpoint_opts:` for that endpoint plus `dp_contract_unknown_option: true`. The answer must
be `{:error, {:unknown_option, :dp_contract_unknown_option}}`; a success or a refusal that
carried on as if the key were absent fails, as does any other error (a different key, another
tag, a raise). `{:error, :not_supported}` stays legal for an endpoint the venue does not serve.
Check the options with `DpExchange.Core.Options.check(opts, own_keys)` after the positional
arguments and before the credentials; see `usage-rules/adapter.md`.

Two rules decide what is judged. `get_price/2`, `get_top_of_book/2`, `get_symbols/1`,
`get_order_book/2` and `get_trades/2` are judged on the probe alone. Every other endpoint is
also called **without** the probe, and judged only if that plain call succeeded: a fake that
refuses the suite's generated arguments for a reason of its own (an order id it has not placed,
a withdrawal address it has not approved) never reached its options, and that refusal is not a
fault. It still must not raise, and must not succeed with the probe. The group fails if no
endpoint gave evidence at all (a fake that refuses every generated call), so declare what the
fake needs in `endpoint_opts:`. **The callbacks that cannot take the probe are listed, each with
its reason, in `AdapterContract.unknown_option_exclusions/0`:** the zero-argument declarations,
`quantization/1` (a symbol only), `child_spec/1` and `start_link/1` (lifecycle), and
`coverage/1`, `coverage_by_kind/1` and `wanted/1` (plain-value reads, which raise
`ArgumentError` on an unknown key rather than answering).

**Group 44 needs nothing from you: your fake must export every public function your facade does.**
`facade.__info__(:functions) -- fake.__info__(:functions)` must be `[]`, at the same arities
(default-argument arities included). A function the consumer can call and cannot fake is an
`UndefinedFunctionError` in their suite. The fake may export more.

**Group 45 needs nothing from you: it judges the notices your fake emits.** It subscribes to
notices, subscribes and unsubscribes `sample_pairs:` (and `unlisted_symbol:` when named), and
holds each `Core.Notice` delivered to `Notice.conformance_faults/1`: `details.reason` an atom or
a tagged tuple (text goes in `details.message`), a `:refusal` with `details.symbols`, a
`:data_quality` with a `reason`. The fakes in this family emit no notice, so today it judges
nothing; it is a tripwire, and **not** evidence that a real feed conforms.

**Group 46 needs nothing from you either.** It calls `subscribe_notices(to: self(),
timeout: 5_000)` on the fake and expects `{:error, {:unknown_option, :timeout}}`: registering
for notices sends no request on any venue, so nothing reads `:timeout` there
(`usage-rules/adapter.md`, "Transport keys only where read"). `subscribe/2` is not probed: a
venue whose subscribe sends a subscription request (Webull) reads the HTTP keys there.

**Groups 47, 48 and 49 hold the parts of venue rules W4 to W6 a fake can show** (the rules are
in the `DpExchange.Core.Venue` typedoc for `write_unconfirmed`; that moduledoc says which of
W1 to W7 are asserted and which are not, and why). They need nothing from you unless your fake
refuses the suite's generated arguments:

- **47 (W4):** `stake/3`, `unstake/3`, `convert/4`, `withdraw/5` and `transfer_internal/4`, each
  when active, are called with a float, zero, a negative, NaN and infinity as the amount. Each
  must answer `{:error, {:invalid_amount, value}}` with the value as given, **before anything
  else about the call is judged**: an amount is a positional argument, and those are checked
  first. A success is the fault that matters (a withdrawal of NaN); a validator that compares
  with `Decimal.gt?/2` before `Decimal.nan?/1` raises on NaN and fails here too.
- **48 (W5):** `stake/3` and `unstake/3`, when active, answer a valid call with
  `{:ok, %Types.StakingTransaction{}}`. A refusal is not a pass (group 5 already holds a success
  to its struct and skips a refusal): declare what the fake needs in `endpoint_opts:`, or
  declare the endpoint `:unsupported`.
- **49 (W6):** `get_order/3` and `cancel_order/3` are asked about an id nobody placed
  (`AdapterContract.unknown_order_id/0`) and must answer `{:refused, :not_found}`. A fake that
  answers an order for any id it is given leaves a consumer's not-found handling untestable.
  A venue whose order ids have a format (numeric ids, say) passes `unknown_order_id: "..."`
  in that format: a malformed id is rightly `{:invalid_order_id, id}` and proves nothing about
  W6. The id-taking callbacks with no documented unknown-id answer (`get_conversion/2`,
  `get_payment_method/3`, `get_watchlist/2`) are not asked.

**The other options of `use DpExchange.Core.AdapterContract`.** `endpoint_opts:`
(`%{{name, arity} => keyword()}`, what your fake needs before it will answer, such as an
account), `endpoint_symbols:` (`%{{name, arity} => symbol}` for an endpoint narrower than
`sample_pairs:`), `order_args:` (`%{order_request | order_requests | order_changes => value}`,
your venue's order rules), `absent_feed_opts:` (default `[feed: :dp_exchange_contract_absent_feed]`,
points the streaming calls at a feed nothing registered), `package_root:` (default `"lib"`,
where groups 16, 18 and 19 scan your compiled modules; an empty scan fails them), and
`unlisted_symbol:` / `padded_credentials:` for group 41.

**A fake that refuses is not a pass.** Groups 5, 24, 25, 31, 37, 39, 43 and 48 fail when a fake
refuses every endpoint they would have inspected (a missing `endpoint_opts:` entry, or a
fixture with no bar, no balance or no book level), rather than skipping. Group 37 needs the
unranged `get_historical_prices/4` to return at least one bar.

**`fake:` and `sample_pairs:` are not optional in practice.** Every group that calls an
active endpoint drives the fake, never the real venue, and several skip or loop zero times
on an empty `sample_pairs:`. The suite now fails group 1 if either is missing, rather than
reporting green for having checked almost none of it. Name at least two pairs the venue
lists (group 26 needs two to tell "added" from "replaced").

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
separately-supervised `GenServer`. A queued outcome popped by a `Task` is gone for your
test's next call too: the queue lives in one `Agent` your test process starts and links, and
only its pid is in your process dictionary.

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

The surface grew to 89 callbacks. **Most of the new ones cannot be verified above tier 1
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
