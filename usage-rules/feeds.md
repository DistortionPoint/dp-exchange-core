# Feeds, subscriptions and notices

## `subscribe/2` pushes; it does not hand back a stream

```elixir
:ok = DpExchange.YourVenue.subscribe(["BTC-USD"], to: self())
```

Events arrive as messages to the subscribing process, or to a pid named in `opts`, tagged
so a process subscribed to several venues can tell them apart. **The payload is the same
`Core.Types.*` struct the pull endpoints return**, so one handler serves a price whether
you asked for it or were sent it.

## The package emits; the consumer connects

You never hand a package a function. An injected sink is consumer code executing inside
package processes, at times the package chooses, with the package's failure modes — and it
drags your event vocabulary across the boundary, so the package ends up knowing what you do
with data.

If you find yourself wanting to pass a callback into the facade, that is the design telling
you something belongs on your side of it.

## Subscriptions are addressed by the thing itself

`unsubscribe/2` takes the same identifiers `subscribe/2` was given — on crypto the pair, on
an equity venue the symbol. **There is no subscription handle**, because you already know
what you subscribed to and a reference would be pure overhead wrapping it, plus one more
thing to leak.

A dead subscriber stops delivery too. A venue must not accumulate events for a process that
no longer exists.

## Back-pressure is a bounded mailbox, and it is declared

A venue pushing faster than you consume drops oldest beyond a stated bound and emits a
`:degraded` notice saying so.

Growing a mailbox silently until the node dies is the failure this avoids. Dropping
silently is the failure the notice avoids.

## `coverage/1` is observed, never intended

```elixir
%{"BTC-USD" => :stream, "ETH-USD" => :internal_poll, "SOL-USD" => :not_covered}
```

`:stream` means pushed without asking each time. `:internal_poll` means arriving, but the
package is fetching it. `:not_covered` means nothing is arriving by any route.

**It reports what actually arrived, not what was subscribed.** A venue that cannot observe
delivery answers `:not_covered` rather than claiming a success it cannot see. This is the
strongest guarantee in the contract, and it is here because a venue once reported 325
symbols subscribed and confirmed while 174 were delivering — the disagreement between what
was asked for and what arrived is the highest-value signal in the system, and folding them
into one number throws it away.

Note that `:stream` does not say *socket*. Whether a pushed route is a WebSocket, an MQTT
session or long-polling is package-internal.

## `coverage/1` collapses every kind into one boolean — `coverage_by_kind/1` does not

`coverage/1` counts any payload for a symbol as delivering, whichever `data_kind()` it
carries. That is the exact mechanism behind an incident that took two issues to pin down: on
Coinbase, the order-book channel delivered over 11,000 frames for 406 symbols while the
quotes channel was dark for all but 5, and `coverage/1` truthfully reported `:stream` for all
406. **"One kind dark, another healthy" and "everything healthy" are indistinguishable
through `coverage/1` alone.**

```elixir
%{
  quotes:     %{"BTC-USDC" => :stream},                        # 5 symbols
  order_book: %{"BTC-USDC" => :stream, "XLM-USDC" => :stream}  # 406 symbols
}
```

`coverage_by_kind/1` is **optional** — check `function_exported?/3` before calling it, since
Core ships it ahead of any venue adopting it by design (`Venue.@optional_callbacks`, so
publishing it never breaks a venue package mid-release). Where a venue implements it, the
conformance suite guarantees two things hold: its symbols are exactly the union `coverage/1`
reports, and every kind it names is one the venue's own `capabilities().streamable` declares.

It is **not** a replacement for `coverage/1` — a caller asking only "is anything arriving"
still gets a plain answer. It is **not** a per-channel report — Coinbase's `level2` and
`ticker` never cross the facade; the kind is always `data_kind()`. And it is **not** a
freshness or latency API — same observed-arrival fact as `coverage/1`, split by kind, nothing
about *when*.

## An order book stream delivers deltas, not a maintained book

`DpExchange.Core.Types.OrderBookDelta` is what a venue pushes for a book **update**:
`DpExchange.Core.Types.OrderBook` — the full, sorted snapshot — is still what `get_order_book/2`
returns and still what a venue's initial subscribe frame delivers, but every change after
that arrives as a delta, passed straight through by the venue package rather than folded
into a book the package holds for you.

```elixir
%DpExchange.Core.Types.OrderBookDelta{
  symbol: "BTC-USD",
  levels: [
    {:bid, Decimal.new("64000.00"), Decimal.new("0")},
    {:ask, Decimal.new("64001.50"), Decimal.new("1.2")}
  ],
  timestamp: ~U[2026-09-06 12:00:03.114Z],
  sequence: 88_213_940,
  provider: :coinbase
}
```

**This package no longer maintains a book on your behalf.** `dp_exchange_coinbase` used to
— a full order book per symbol, ~22,800 bid and ~21,100 ask levels for `BTC-USD` on a live
node, rebuilt on every delta, inside a socket process that was already starving on its own
`send_timeout` because it was never idle. That was market state duplicated in the one place
that could least afford to hold it, and the host receiving it was already writing the same
data into its own store. If you want a maintained book, build one from the stream of
`OrderBookDelta` structs on your side of the boundary — that is genuinely your call to make,
not a default this package was making for you.

### `levels` is a flat list in the venue's own order, and a zero quantity means removal

Each entry is `{side, price, quantity}` — `OrderBook.level/0`'s `{price, quantity}` with the
side prepended, because a single delta frame changes both sides in one venue-ordered message
and splitting it into two lists would either drop that order or invent one that was never
sent.

**A `quantity` of zero means the level at that price ceased to exist — it is not a price of
zero, and this package does not resolve it for you.** That is the venue's own meaning,
carried through unchanged; deciding what to do with a vanished level — drop it from a book
you are building, log it, ignore it — is state-keeping, and state-keeping is exactly the job
this type exists to keep out of the package.

### A delta cannot be mistaken for a book, which is the whole reason it has its own type

Reading a single delta as though it were the whole book "would see a handful of prices and
nothing else" — a caller matching on `%DpExchange.Core.Types.OrderBook{}` cannot receive an
`%OrderBookDelta{}` by accident, because the struct name says which one it is holding. That
is the type-level fix for exactly the failure that used to be prevented by holding state
instead.

### `coverage_by_kind/1` still reports `:order_book` for a delta stream — deliberately

A venue streaming deltas still declares `:order_book` in `capabilities().streamable`, and
`coverage_by_kind/1` still answers `:order_book` for it, same as it would for a snapshot
stream. **No new `data_kind()` was added for this.** `coverage_by_kind/1` exists to answer
"which *kind* of data is arriving" — quotes dark, book healthy, and so on — not "in what
*shape*". A host asking whether book data is arriving for a symbol does not care whether the
next message is a full snapshot or an incremental delta; it cares whether book data is
arriving at all, and `:order_book` already answers that. Splitting the vocabulary by shape
would add a second axis to a closed vocabulary every venue declares against, for a
distinction `coverage_by_kind/1` was never built to make — the struct type itself is what
already tells a caller which shape it is holding.

### Reconnect reconciliation is yours, and the tools are the ones you already have

A package holding no book has nothing to wipe on reconnect, so the fact that deltas after a
reconnect are **not contiguous** with deltas before it is now visible to you instead of
silently absorbed. Two existing signals are what you reconcile against, and nothing new was
added for this:

  * **`:link_down` / `:link_up`** notices bracket exactly where the gap falls.
  * **`:sequence`**, present on both `OrderBook` and `OrderBookDelta` wherever the venue
    publishes one, lets you confirm whether what arrives after `:link_up` is actually
    contiguous with what you already hold.

Consistent with the rule earlier in this file — *a notice is a prompt to re-read, never the
record* — the correct response to `:link_up` on a book stream is to re-pull
`get_order_book/2` (or accept the fresh snapshot the venue's own protocol sends on
resubscribe, where it sends one) and resume applying deltas from there, rather than to keep
applying them across the gap on the assumption that nothing was missed. Two signals are
enough to know *when* to re-sync and *whether* what you resumed on is contiguous; neither one
reconstructs the missing deltas themselves, and nothing does — a gap in a delta stream is
lost, not recoverable, which is exactly why re-reading the current state rather than trusting
continuity is the only correct response to it.

## Notices are a separate channel

```elixir
:ok = DpExchange.YourVenue.subscribe_notices(to: self())
```

What the **package** says about **itself**, never market data: link up and down, credentials
rejected or expiring, sustained rate limiting, coverage change, catalogue change, refusals,
degradation.

You may want this without the data channel. A monitoring process that never touches a price
still needs to know a credential expired.

### A notice is a prompt to re-read, never the record

Delivery is not guaranteed and your correctness must not depend on it. Reporting on the
work must never become the reason the work does not happen, so an undeliverable notice is
dropped rather than retried or blocked on.

The failure this warns about has happened. Three cached copies of a symbol's status were
kept in step with fire-and-forget casts — and **a cast to a dead or restarting process
returns `:ok` and is dropped**. Two symbols suspended at 03:14 and 03:27 UTC opened fresh
positions at 21:46.

So: `:catalog_change` is a reason to call `list_instruments/1`. `:coverage_change` is a
reason to call `coverage/1`. Neither is the authority for anything.

### Catalogue changes are usually observed, not announced

Most venues do not announce a delisting — the pair simply stops appearing — so a package
learns it by diffing and says so with `observed: true`. **A vanished pair is not evidence
of a delisting**, and `Instrument` resolves unrecognised status to `:unknown`, never to
`:tradable`.

## Telemetry is the other channel, and the line matters

**Telemetry is measurement you aggregate. A notice is a condition you act on.**

A request duration is a metric. A single `429` is a metric. "Your API key was rejected" is
not, and it must not be delivered by a mechanism whose handlers run inside the emitting
process and whose delivery is legitimately lossy.

Link events are `[:dp_exchange, :link, :up | :down | :event | :reconnect_attempt]`. The
category is the **link**, not the wire beneath it — a venue streaming over MQTT has no
"ws" to report.

## Never let intent stand in for evidence

If you take one rule from this file, take that one. It is what `coverage/1` encodes, it is
why notices are advisory, and it is the shape of nearly every incident behind this contract.

## Four of the five venues push, and the fifth polls behind the same facade

| venue | transport | `streamable` | `coverage/1` reports |
|---|---|---|---|
| Coinbase | WebSocket | `[:quotes, :order_book]` | `:stream` |
| Gemini | WebSocket, 22 channels | `[:quotes, :top_of_book]` | `:stream` |
| Webull | **MQTT** | `[:quotes, :top_of_book, :trades]` | `:stream` |
| Schwab | WebSocket (Streamer) | `[:quotes, :top_of_book, :order_book, :candles, :orders, :fills]` | `:stream` |
| Robinhood | **REST poll inside the package** | `[:top_of_book]` | `:internal_poll` |

Read that column from each package's own `capabilities/0` rather than from here: it is the
one thing in this table that changes as a package wires a kind its venue already carried.
Robinhood's is `[:top_of_book]` and **not** `[:quotes]` deliberately — the venue publishes no
last-trade data to poll for, so a bid/ask is the only thing it can deliver.

**Nothing above the facade branches on that column.** The one visible difference is the value
`coverage/1` reports, which is a statement about *what is arriving*, never about how — and
that is the whole design. `:stream` does not mean socket; Webull's `:stream` is an MQTT
session, and it is nobody's business above the boundary.

Do not build a poll on top of a package that reports `:internal_poll`. It already polls,
paced against that venue's budget, and a second loop doubles the request count for no extra
data.

## `streamable` is not `authenticated_streamable`

Two lists, and the second must be a **superset** of the first — `Capabilities.new/1` enforces
it, because a kind that streams anonymously and not with a credential is not a thing a venue
does.

Schwab's are identical, and that is itself information: **there is no public market data
there and no anonymous socket.** Its Streamer login is built from the OAuth session, so every
kind in the list needs a credential and the two lists cannot differ.

Where they *do* differ, the gap is what a credential buys you on the socket specifically —
which is not always the same as what it buys on REST.

## A recognised channel that this package does not deliver

Gemini publishes 22 socket channels. Schwab's Streamer publishes services this package
subscribes to and services it does not. **A package may decode a frame and deliver nothing**,
and where it does, that is declared: `streamable` names the kinds that reach a subscriber,
not the kinds the wire carries.

This is the one place where "the socket is connected and healthy" and "you are receiving what
you asked for" come apart, which is exactly what `coverage/1` exists to expose. Ask it.

## A stream that refuses rather than falls back

Webull's UAT environment has REST and **no broker at all** — `mqtt-uat.webullbroker.com` is
NXDOMAIN. `subscribe/2` there **refuses**.

It does not quietly connect to production, because a consumer testing against UAT while
receiving production prices would be reading real market data believing it was fake. That is
the substitution failure in its most dangerous form, and `Environment.streaming?/1` exists so
a caller can ask before it commits.

## A poll-based feed that goes silent still has to say so

Robinhood's feed — and any venue's gap-filler for symbols a socket does not reach — is
`Core.PollingFeed` underneath the facade. It can fail in a way a socket-based feed
cannot: every fetch keeps failing while the process stays alive, ticking, and answering
calls normally. Nothing crashes, no supervisor restarts it, and the only visible symptom
is that data stops arriving — which reads downstream as a quiet market, not a broken
venue. `PollingFeed` detects this itself (`status/1` calls it `delivering: false`) and,
until now, said so only in a `Logger.warning` — a sentence a human had to go grepping for
after the fact to find DpCryptoManagement's issue #21 (154 consecutive failed attempts,
discovered only because someone searched the logs for that literal wording).

`PollingFeed.start_link/1` takes an `:on_notice` option for exactly this — an injected
function, same shape as `:on_refusal`, called with a `%Core.Notice{kind: :coverage_change}`
the instant the feed crosses INTO delivering-nothing, and a second, `severity: :info`
notice the instant it crosses back OUT. It fires once per transition — not once per failed
fetch and not once per sweep while an outage continues — so a 342-symbol feed retrying
every symbol every cycle does not turn one outage into a notice storm. `:on_notice`
defaults to a no-op: a venue that has not wired it to its own `subscribe_notices/1`
fanout yet still gets a working feed, not a crash.

If you are building a venue on top of `PollingFeed`, wire `:on_notice` to whatever
delivers your own package's notices to its subscribers. Until you do, this failure mode
is invisible to your consumers exactly as it was before — the option existing is not the
same as a venue using it.

An `:ok` bulk response with zero events (`{:ok, []}`) counts as delivering nothing for
this same escalation, even though the call itself succeeded — a bad credential filtered
to an empty result set server-side looks identical to a failure from `PollingFeed`'s
side, and is treated the same way rather than silently resetting nothing.

## `:fetch_all` can refuse individual symbols without crashing the feed

`t:PollingFeed.fetch_all/0`'s third outcome, `{:refused, refusals}` (`refusals ::
[{symbol, reason}]`), is the batch analogue of `:fetch`'s own `{:refused, reason}`: name
every symbol in this call the venue stated it does not carry, and each is reported once
through `:on_refusal` rather than retried forever as an ordinary `{:error, reason}` would
be. If your bulk endpoint's response format cannot yet tell you which symbol in a batch
was bad — verify that live before assuming it can — return `{:error, reason}` for the
whole cycle instead; that fails closed (retried, never silently dropped) rather than
guessing which symbol to blame.

## Reconnection is the package's problem, and the notice is yours

A dropped socket reconnects, resubscribes, and emits link notices along the way —
`[:dp_exchange, :link, :up | :down | :reconnect_attempt]`. The category is the **link**, not
the wire beneath it, so an MQTT venue has no "ws" to report.

**What a reconnect cannot promise is that the gap was empty.** A venue that pushed a trade
while the socket was down did not queue it for you. If a gap matters to your correctness,
re-read the state through the pull endpoint after a `:up` notice — that is what makes the
notice a prompt to re-read rather than a record.
