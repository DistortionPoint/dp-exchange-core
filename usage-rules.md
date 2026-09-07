# Using `dp_exchange_core`

> **EXPERIMENTAL.** This package has not run in production. While it is `0.x` a minor
> version may break you — pin all three segments (`~> 0.1.0`). Maturity is declared
> **per endpoint** through `capabilities/0`, not per package: read that, not this banner.

`dp_exchange_core` is the contract for the DpExchange family. It talks to no exchange. It
defines what a venue package *is*, so a consumer can drive any venue through one identical
facade and add a new one without editing anything outside its own repo.

## The one thing to understand first

**Every venue package exposes the same facade, and nothing crosses it.** Transport, rate
limiting, credential handling, session lifecycle and supervision are internal to a venue
package. You cannot tell from the facade whether data arrives over a WebSocket, an MQTT
session or a polling loop, and you must not try to find out.

What differs between venues is which facade functions are *active*, declared once in
`capabilities/0`. **Branch on capabilities, never on venue identity.** A `case venue do`
in your code is the coupling this contract exists to remove.

## As a consumer

```elixir
# In your supervision tree. Nothing starts itself — a package you have not asked for
# never opens a connection.
children = [
  {DpExchange.Coinbase, credentials: coinbase_credentials()}
]

# Pull.
{:ok, %DpExchange.Core.Types.Quote{} = quote} = DpExchange.Coinbase.get_price("BTC-USD", [])

# Push. The same struct arrives as a message; one handler serves both.
:ok = DpExchange.Coinbase.subscribe(["BTC-USD"], to: self())
receive do
  {:dp_exchange, :coinbase, %DpExchange.Core.Types.Quote{} = quote} -> handle(quote)
end
```

**Both endpoints exist on every venue.** A venue with no streaming API implements
`subscribe/2` over its own polling and pushes the results. There is no flag for this and
nothing to branch on.

### Three return shapes, and the third matters

| Shape | Meaning | What to do |
|---|---|---|
| `{:ok, value}` | it worked | proceed |
| `{:refused, reason}` | **the venue does not carry this** — permanent | stop asking |
| `{:error, reason}` | it failed, possibly transiently | retry as your policy allows |

Collapsing `:refused` into `:error` makes a delisted symbol look like a network blip
forever. Collapsing it into `:ok` is worse.

### `{:error, :not_supported}` is the atom

Never the string. Match the atom.

## Read `capabilities/0` before you rely on anything

```elixir
caps = DpExchange.Coinbase.capabilities()

case DpExchange.Core.Capabilities.maturity(caps, {:place_order, 3}) do
  :proven -> place_it()
  :experimental -> place_it_but_watch()
  :unsupported -> use_something_else()
end
```

`:proven` and `:experimental` both mean **it works** — maturity says how well a thing is
known, never whether it runs. `:unsupported` means the function exists and returns
`{:error, :not_supported}`; it will not raise and will not quietly return degraded data.

Anything undeclared is `:experimental`. That is the honest default, not a claim.

### Three fields whose *absence* means something specific

Reading these as "not set" loses the whole point of declaring them:

- **`max_leverage: :per_account`** — the venue margins, but has no single ceiling. Read the
  ceiling from the balance response, not from the declaration. A Schwab margin account
  carries five different buying powers that are not multiples of one another, and a cash
  account at the same venue carries none of them, so no scalar is true. `nil` here means
  the venue does not margin at all.
- **`authenticated_ceiling: nil` on a venue that clearly has limits** — the limit is not a
  property of the venue. Schwab's order ceiling is set per *application* at registration,
  anywhere in `0..120` per minute per *account*, so any number in the package would be a
  claim about somebody else's registration. Configure your own.
- **`historical_timeframes: []`** — the venue publishes no candle endpoint. It is not "we
  did not check": a venue that serves candles must name the widths, and `Capabilities`
  raises if it claims history without them.

### Five fields that say what the venue can do with an order

- **`supported_sessions`** — which trading session an order may name. `[]` means the
  venue trades continuously and a caller never names one; that is every crypto venue.
  Non-empty means the market closes, and an order carries which window it is for.
- **`supports_order_preview`** — the venue will validate an order and estimate its cost
  **without placing it**. Where it is true, use it: on a venue that throttles writes and
  not reads, a rejection found by previewing costs nothing and one found by placing costs
  a scarce write.
- **`supports_order_replace`** — the venue amends atomically. Where it is `false`, your
  only route is cancel-then-place, which is **not equivalent**: it opens a window in which
  no order is live. Treat this as a risk property, not a convenience.
- **`supports_multi_leg_orders`** — `false` on every venue in the family today, including
  ones whose *venue* supports spreads. `place_order/3` takes a flat request; the field
  tells you the venue is richer than the contract rather than letting you discover it.
- **`catalog_access`** — `:enumerable` means `get_symbols/1` returns everything.
  **`:query_only` means there is no list-everything call**, so you must pass a search
  term and will get `{:error, {:query_required, venue}}` without one. That is *not*
  `:not_supported` — the endpoint works.

### Rate ceilings: read `:scope`, and do not treat zero as absent

A `ceiling` may carry **`:scope`** — `:credential`, `:account` or `:application`. It
changes what you must key your limiter by: a limiter keyed by credential **silently
over-permits** a venue that counts per account, and you will find out by being throttled.

**`limit: 0` is a legal value and is not `nil`.** It means this registration was granted
no throughput on that path. The endpoint exists and the venue serves it — your application
cannot use it. That is a different problem from `:unsupported`, with a different remedy:
one is a conversation with the venue, the other is not.

### Timeframes: nameable is wider than bucketable

`Timeframe.known/0` is what Core can **bucket** — `aligned?/2` and `boundary/2` answer for
those. `Timeframe.nameable/0` is what Core can **read as a label**, and adds `1w`, `1M`
and `1y`.

Weekly, monthly and yearly have no boundary rule and never will: a weekly bar's start
depends on which weekday the venue begins its week, a month is not a fixed number of
seconds, and neither is a year (365 or 366 days, depending which one). So `seconds/1`
returns `:error` for all three and `aligned?/2` returns `true` — **"no rule" means
"cannot check", never "invalid"**. Validate a declaration against `nameable/0`; reach for
`known/0` only when you need the width in seconds.

## Coverage is observed, never intended

`coverage/1` reports what is **actually arriving**, by route. It is not a list of what you
subscribed to. A venue that cannot observe delivery answers `:not_covered` rather than
reporting a success it cannot see.

This is the strongest guarantee in the contract, and it exists because a venue once
reported 325 symbols subscribed and confirmed while 174 were delivering.

### `coverage/1` alone cannot tell a half-dead feed from a healthy one

`coverage/1` collapses every kind of data a symbol receives into one route. That is exactly
right for "is anything arriving" and exactly wrong for "is everything arriving that should
be": on Coinbase, the `level2` (order book) channel delivered over 11,000 frames for 406
symbols while `ticker` (quotes) was dark for all but 5, and `coverage/1` truthfully answered
`:stream` for all 406 — it counts any payload, an order book update exactly as much as a
quote. "Ticker dark, book healthy" and "everything healthy" produced the identical
`coverage/1` map, and the defect stayed invisible across two issues before it was found.

**`coverage_by_kind/1`, where a venue implements it, answers the question `coverage/1`
cannot**:

```elixir
%{
  quotes:     %{"BTC-USDC" => :stream},                        # 5 symbols
  order_book: %{"BTC-USDC" => :stream, "XLM-USDC" => :stream}  # 406 symbols
}
```

The gap between the two map sizes *is* the signal a single boolean-per-symbol threw away.

**Optional, and check for it before relying on it.** It is in `Venue.@optional_callbacks`
precisely so Core could ship it without every venue package instantly failing conformance;
call `function_exported?(YourVenue, :coverage_by_kind, 1)` before calling it. Where it is
implemented, its own symbols are guaranteed to be exactly the union `coverage/1` reports, and
every kind key is one the venue's own `capabilities().streamable` declares — the conformance
suite asserts both. **It is not a replacement for `coverage/1`, not a per-channel report** (a
venue's own channel names never cross the facade), and **not a freshness or latency API** —
it is the same observed-arrival fact, split by `data_kind()`.

## Notices: a prompt to re-read, never the record

`subscribe_notices/1` carries what the *package* says about *itself* — link state,
credentials rejected, sustained rate limiting, coverage change, catalogue change.

**Delivery is not guaranteed, and your correctness must not depend on it.** A
`:catalog_change` notice is a reason to call `list_instruments/1`; it is not the authority
that a pair was delisted. Treat a notice as a nudge and a dropped message costs latency.
Treat it as the record and a dropped message is silent, wrong state — which has happened:
two symbols suspended at 03:14 and 03:27 opened fresh positions at 21:46 because the
message that would have stopped them vanished with a restarting process.

## Credentials

Passed as arguments, per call. A package never reads them from a vault, an environment
variable or your config, and never stores them. Notices never carry them.

**Storage is yours; *use* is the package's.** Signing, session refresh, token rotation and
revocation happen inside a venue package — a package that only signed, and handed you an
expired token back twice an hour, would be unusable for anything unattended. The consent leg
— a browser, a login page, a person — is always yours, at every venue in this family.

The five venues do not share an auth model, and integrating two of them means implementing
two different things. **Read [Authentication](usage-rules/auth.md) before writing any of it**;
in particular the Schwab section, because its refresh token is one-time use and losing the
rotated value is unrecoverable without a person.

## The contract is 88 callbacks, and a package implements what its venue serves

`Venue.required_callbacks/0` is what the compiler enforces. Everything else is optional, and
an unimplemented callback **exists and returns `{:error, :not_supported}`** — never a raise,
never a missing function.

Two things a consumer should read rather than infer:

- **`venue_does_not_serve/0`** splits the `:unsupported` list in two: what the venue does not
  serve, and what this package has not ported. Both answer identically; only the second can
  ever change. A host planning around a gap needs to know which it is looking at.
- **`Venue.peripheral_endpoints/0`** names the endpoints a consumer can live without, with the
  reason for each. It is the difference between a gap that costs you a feature and one that
  costs you the migration.

**`asset_classes` is a statement about a package today, never a permanent scope boundary.**
A venue package serving crypto today may serve options tomorrow, and the only test of scope
is whether the venue provides it.

## Options in `opts` are the venue's own vocabulary

Callbacks take `keyword()`, and packages read venue-specific keys from it — `category:` on
Webull, `portfolio:` on Coinbase, `account_number:` on Robinhood. One rule keeps that from
becoming the coupling this contract removes:

**A call that passes no options gets a correct answer.** Options select among things a venue
offers; they never carry something the call cannot work without. Where a venue genuinely
requires a parameter this contract has no word for, the package refuses **locally and by
name** rather than sending a request the venue will reject less clearly.

An option a package does not recognise is ignored, not an error — a consumer moving between
venues carries options only one of them reads.

## Money movement is its own subject

One group of callbacks moves funds, one of them cannot be undone by anyone, and none of it is
ever tested in this family — it is answered in production, with real money.

**Read [Money movement](usage-rules/money-movement.md) before calling any of it.** Its
preconditions are not style advice: the network is required and never defaulted because
funds sent to an address on a chain the venue does not credit are gone, and
`memo_required: nil` means *the venue did not say* rather than *no memo is needed*.

## Detailed guides

- [Implementing a venue package](usage-rules/adapter.md) — writing one
- [Authentication](usage-rules/auth.md) — what you do, what the package does, per venue
- [Running live and demo at the same time](usage-rules/environments.md)
- [Money movement](usage-rules/money-movement.md) — the group where a defect moves funds
- [Symbols and the round-trip invariant](usage-rules/symbols.md)
- [Feeds, subscriptions and notices](usage-rules/feeds.md)
- [Testing, fakes and isolation](usage-rules/testing.md)
