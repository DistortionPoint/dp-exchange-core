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
those. `Timeframe.nameable/0` is what Core can **read as a label**, and adds `1w` and `1M`.

Weekly and monthly have no boundary rule and never will: a weekly bar's start depends on
which weekday the venue begins its week, and a month is not a fixed number of seconds. So
`seconds/1` returns `:error` for both and `aligned?/2` returns `true` — **"no rule" means
"cannot check", never "invalid"**. Validate a declaration against `nameable/0`; reach for
`known/0` only when you need the width in seconds.

## Coverage is observed, never intended

`coverage/1` reports what is **actually arriving**, by route. It is not a list of what you
subscribed to. A venue that cannot observe delivery answers `:not_covered` rather than
reporting a success it cannot see.

This is the strongest guarantee in the contract, and it exists because a venue once
reported 325 symbols subscribed and confirmed while 174 were delivering.

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

## Detailed guides

- [Implementing a venue package](usage-rules/adapter.md)
- [Symbols and the round-trip invariant](usage-rules/symbols.md)
- [Feeds, subscriptions and notices](usage-rules/feeds.md)
- [Testing, fakes and isolation](usage-rules/testing.md)
