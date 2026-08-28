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
