# Implementing a venue package

## The shape

```elixir
defmodule DpExchange.YourVenue do
  @behaviour DpExchange.Core.Venue
end
```

That module is the **entire public API of your package**. Everything else — transport,
signing, session handling, supervision — is internal, and the conformance suite asserts it.

Declare the behaviour. The compiler's missing-callback check is the cheapest assertion in
the whole contract and it runs before any test does.

## Do not add functions to the facade

A venue does not add functions; it declares which ones it answers. A public function only
your venue has is a function a caller must know which venue it is holding to call — which
is the coupling the family exists to remove.

This is not hypothetical. One venue shipped `get_staking_balances/2` as a public
venue-specific function. It does not cross the facade, and the consumer loses that call at
migration.

If a capability is genuinely missing from the facade, that is a Core change with a
deliberate release behind it, not a local addition.

## `capabilities/0` is a claim about a real venue

```elixir
def capabilities do
  DpExchange.Core.Capabilities.new(
    endpoints: %{
      {:get_price, 2} => :experimental,
      {:get_transfers, 2} => :unsupported
    },
    supported_quotes: ~w(USD USDC),
    historical_timeframes: ~w(1m 1h 1d),
    credential_benefit: :higher_ceiling,
    public_ceiling: %{limit: 10, per_ms: 1_000},
    authenticated_ceiling: %{limit: 100, per_ms: 1_000},
    measured_at: ~D[2026-08-27],
    measured_against: "GET /api/v3/exchangeInfo"
  )
end
```

**Build it with `new/1`.** Assembling `%Capabilities{}` directly skips every validation,
and the validations are the point.

### Declare what you measured, not what you assume

If a value was measured, say when and against what. If it was read from documentation and
never probed, say that instead. **An unlabelled number is worse than a missing one.**

This is not fussiness. A state table drafted by people who knew the system was wrong in
**7 of 21 rows**; the measured version replaced it.

### The declaration and the behaviour may not disagree

- `:proven` or `:experimental` → the function **works**. It may not answer
  `{:error, :not_supported}`.
- `:unsupported` → the function **exists and returns `{:error, :not_supported}`**. Not a
  raise, not undefined, not degraded data.

Over-declaring fails in your caller's hands at runtime. Under-declaring hides working
functionality. The suite checks both directions because checking one leaves the other open.

### Never declare transport

There is no `has_websocket` and there must never be one. Both endpoints exist on every
venue. What a caller legitimately needs is *which kinds of data* stream — `streamable:
[:quotes, :order_book]` — not which channels carry them. `"level2"` is your venue's word;
`:order_book` is everyone's.

## Fail closed; never substitute

The recurring failure in this family is **a nearby substitute where there should be an
error**. A missing granularity becoming the closest one. A missing endpoint becoming
synthetic data. Every value stays plausible and only the meaning is wrong, which is why it
does not surface as a failure.

If asked for a timeframe you do not serve, return an error. Do not serve the nearest width.

## Timestamps are the venue's own

Use what the venue gave you, unchanged. Where it gave nothing, `nil` is the honest answer —
a substituted local clock is a plausible value with the wrong meaning.

`Balance` is the one exception, and it is stated: its timestamp is **when you asked**,
because a balance has no venue event time and its freshness is the only thing a caller can
reason about.

## Carry the incident, not just the code

Where a moduledoc explains *why* a guard exists, that explanation is the most valuable
thing in the file. Carry it when the code moves or is copied. A guard without its reason
reads as defensive padding, and the next person tidying up deletes it.

## The surface is 87 callbacks, and almost all of them are optional

`Venue.required_callbacks/0` is the list the compiler enforces; everything else is declared
`:unsupported` and answers `{:error, :not_supported}`. **A new package does not implement 87
functions.** It implements what its venue serves and declares the rest — which is exactly the
work, because the declaring is where the thinking is.

`Venue.peripheral_endpoints/0` names the ones a consumer can live without, with the reason
for each. It is what tells a package author which absences are survivable and which will
cost a consumer the migration.

## Options: `opts` is the venue's own vocabulary, and that is deliberate

The facade takes `keyword()` on nearly every callback, and packages read venue-specific keys
out of it — `category:` on Webull, `portfolio:` on Coinbase, `account_number:` on Robinhood.
That looks like the coupling this family exists to remove, and it is not, because of one
rule:

**A caller that passes no options must get a correct answer.** Options select among things
the venue offers; they never carry something the call cannot work without. Where a venue
genuinely requires a parameter this contract has no word for — Robinhood v2's account number
— the package refuses **locally**, by name, rather than sending a request the venue will
reject with something less specific.

Two things follow that are worth stating because they are easy to get backwards:

- **Never route on an option the caller did not pass.** Webull's five categories are five
  separate endpoints with five different parameter sets; guessing which one a caller meant
  produces a plausible answer from the wrong market.
- **An option this package does not recognise is ignored, not an error.** A consumer moving
  between venues carries options that only one of them reads, and refusing them would make
  the uniform facade unusable for the thing it is for.

## Asset classes are a statement about today

`asset_classes` says what the package serves **now** — `:crypto`, `:equity`, `:option`,
`:future`, `:event_contract`. It is never a permanent scope boundary, and it must never be
used to justify not implementing something: "this venue's options endpoints are out of scope
because we declared crypto" is the argument in its wrong form, and it has been made in this
family and was wrong.

The only test of scope is **does the venue provide it**.

## Two lists, not one: absence has two causes

Split your `:unsupported` endpoints into what the venue does not serve and what this package
has not ported, and expose the first through `venue_does_not_serve/0`.

Both answer a caller identically. Only one of them can ever change, and a host planning
around a gap needs to know which it is looking at.

**The mislabel goes both ways, and both are defects.** A venue's absence filed as a backlog
item invents work that cannot be done and quietly implies an endpoint the vendor does not
publish. A backlog item filed as the venue's absence hides a capability a consumer could
have had. Robinhood shipped four of the first kind and they were found by auditing, not by
tests — nothing fails when a comment is wrong.

## Every negative gets an audit

Write `docs/reference/<venue>/negative-claims.md`, tabulating every place your package says
the venue *does not* do something, with the source and the date you consulted it.

**An unverified negative is a substitution exactly like an invented value.** "The venue has
no order book" and "we never looked" produce the same `{:error, :not_supported}`, and only
one of them is true. Across five venues this audit found **nine false negatives** — every one
of them a working endpoint a consumer was being refused.

Two patterns produced most of them:

- **A true statement about one endpoint restated as a claim about the venue.** "The stock
  snapshot does not serve options" is correct; "this venue does not serve options" is not.
- **A derived artefact read instead of the vendor.** A claim originating in the host
  application's own adapter, or in a third-party wrapper's README, carried forward until
  somebody read the vendor's pages.
