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
