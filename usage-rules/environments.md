# Running live and demo at the same time

A host that trades needs both at once: a production subtree taking real orders and a demo
subtree exercising the same code with test funds. **That is a supervision-tree question, not
a configuration-file question**, and this family is built for it.

## Per-process, not per-node

`Application.put_env/3` is node-wide. Flipping the node to demo mid-run redirects every
other process on it, including whatever is trading with real money.

So environment resolves through `DpExchange.Core.Config`, which reads in this order:

1. an explicit `:environment` in the call's options — **wins always**
2. `Core.Config` — the calling process, then its `$callers` ancestor chain, then
   application env
3. `:production`

Step 2's ancestor walk is the one that gets omitted in reimplementations, and omitting it
makes the seam work in simple cases and fail in exactly the concurrent ones it exists for.

## Two subtrees, side by side

```elixir
children = [
  Supervisor.child_spec(
    {DpExchange.Gemini,
     name: :gemini_live,
     credentials: live_credentials(),
     environment: :production,
     symbols: ["BTC-USD"],
     subscriber: LiveConsumer},
    id: :gemini_live
  ),
  Supervisor.child_spec(
    {DpExchange.Gemini,
     name: :gemini_demo,
     credentials: demo_credentials(),
     environment: :sandbox,
     symbols: ["BTC-USD"],
     subscriber: DemoConsumer},
    id: :gemini_demo
  )
]
```

Two `id:`s and two `name:`s, because they are two independent venues that happen to share a
module. **The credentials are different accounts** — a production key does not work against
a demo host and should never be sent to one.

## Crossing a process boundary

A `GenServer` runs in its own process and will not find the caller's dictionary at all — it
is not in the caller's `$callers` chain. **Resolve in the caller and put the answer in the
message**: `Config.snapshot/2` on the way in, `Config.resolve_snapshot/3` on the way out.

Resolving inside the server is too late, and it fails in the direction that looks like it
works: production is unaffected, so only a consumer's async suite breaks.

## What each venue actually offers

Demo environments are not a uniform feature, and the differences change what you can test.

| venue | demo | REST | streaming | what it is |
|---|---|---|---|---|
| **Gemini** | `:sandbox` | `api.sandbox.gemini.com` | `wss://ws.sandbox.gemini.com` | **a full exchange with test funds** — bots simulate book activity; new accounts get $100,000 and 1,000 BTC |
| **Webull** | `:uat` | `us-openapi-alb.uat.webullbroker.com` | **none** | authenticated REST against test data, no live stream at all |
| **Coinbase** | — | — | — | no sandbox for Advanced Trade |
| **Robinhood** | — | — | — | none published |
| **Schwab** | — | — | — | **none.** Its own documentation says Trader API sandboxes "will be available later this year" |

Gemini's is the one that changes what this family can honestly offer: order placement,
cancellation and balances stop being "never a test, answered only in production" and become
**testable against real venue machinery with fake money**. A consumer can run its whole
trading integration there before a single real order.

## Webull's half-story, and why it refuses rather than falls back

`environment: :uat` gives REST and **no stream**. `mqtt-uat.webullbroker.com` is NXDOMAIN;
there is no UAT broker, and no configuration produces one.

`subscribe/2` in UAT **refuses**. It does not fall back to production, because a consumer
testing against UAT while receiving *production* prices would be reading real market data
believing it was fake — which is the failure mode this whole family is built to prevent.

`Environment.streaming?/1` exists so a caller can ask before it commits, rather than
discovering the gap from a subscription that never delivers.

## Production is the default, and that is the safe direction

The wrong default fails in only one direction:

- defaulting to **production** means a consumer who meant demo sends a real order to a real
  exchange with real money — silent, and expensive
- defaulting to **demo** means a consumer who meant production gets test balances and
  obviously-wrong prices — loud, and free

Gemini's demo book is crossed as often as not; a frame captured 2026-08-28 carried a bid of
`68169.88` against an ask of `64886.32`, which no real venue would ever show. You will
notice.

So: production is the default, and selecting demo is an explicit act. **An unrecognised
environment value raises** rather than resolving to production — a typo must not quietly
become a live order.

## A documentation defect worth knowing about

Gemini's market-data page names `exchange.sandbox.gemini.com` as the sandbox base URL.
**That is the website, not the API.** Measured 2026-08-28:
`https://exchange.sandbox.gemini.com/v1/symbols` returns 404 and an HTML page, while
`https://api.sandbox.gemini.com/v1/symbols` returns 391 symbols.

A consumer following the vendor's page gets 404s that look like a broken endpoint rather
than a wrong host. This package uses the correct hosts; the note is here so the vendor page
does not send you the other way.
