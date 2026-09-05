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

### The domain vocabularies are closed lists, and `new/1` checks them

`supported_order_types` and `supported_time_in_force` are validated against a fixed list
at `new/1` time — a value outside it raises rather than being carried through silently.
Read the current lists from `DpExchange.Core.Capabilities`'s source when in doubt; they
grow only when a venue proves it needs a word this contract does not yet have.

Current `supported_time_in_force`: `:gtc`, `:ioc`, `:fok`, `:gtd`, `:day`, `:gfw`, `:gfm`.
The last two — "good for week" and "good for month" — are real Robinhood values, added
because the vendor's own OpenAPI schema names them in both the order request and response
schemas and this contract had no slot for them before. Purely additive: a venue declaring
a subset of this list is unaffected by the addition.

Current `supported_order_types`: `:market`, `:limit`, `:stop`, `:stop_limit`,
`:post_only`, `:ioc`, `:fok`, `:trailing_stop`, `:trailing_stop_limit`,
`:market_on_close`, `:limit_on_close`. The last four exist because Schwab accepts them and
Core had no word for them; declaring one says the venue accepts the type, not that Core
can express every parameter it takes — `place_order/3`'s request map is for that.

## Prefer `Types.*.new/1` over a struct literal in your decoder

Every `Core.Types.*` module exposes a validating `new/1`, built on
`DpExchange.Core.Types.Validate`: `struct!/2`, plus a check that every field the type's own
`@enforce_keys` names is present **and non-`nil`**, raising `ArgumentError` naming the
offending field when it is not.

`@enforce_keys` alone guards presence, not `nil` — `%Candle{open: nil, high: ..., low: ...,
close: ..., ...}` builds without complaint even though `Candle`'s typespec calls `open` a
`Decimal.t()`, never a `Decimal.t() | nil`. That gap is not academic: a `nil` in a field the
typespec forbids is exactly what a decode bug on a venue key that got renamed produces, and
without `new/1` the failure surfaces several calls downstream — inside `Decimal` or
similar — with nothing pointing at which field was actually the problem.

`%Candle{...}` and every other struct literal still work; nothing here removes `defstruct`
or `@enforce_keys`, and internal code or a test building a known-good value by hand is
unaffected. `new/1` is the path your own decoder should prefer, because it turns a decode
bug into an `ArgumentError` at the boundary instead of a crash three calls downstream with
no indication which venue field caused it.

`Types.Order` is the one type where this needs a caveat: it enforces the presence of seven
keys, but its own moduledoc documents that all but `:provider` legitimately admit `nil` —
"the venue's word, or nothing," since a venue can acknowledge a cancel with an id and
nothing else. So `Order.new/1` narrows its check to `:provider` alone. Check a type's own
moduledoc rather than assuming every enforced key must come out non-nil.

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

## The surface is 88 callbacks, and almost all of them are optional

`Venue.required_callbacks/0` is the list the compiler enforces; everything else is declared
`:unsupported` and answers `{:error, :not_supported}`. **A new package does not implement 88
functions.** It implements what its venue serves and declares the rest — which is exactly the
work, because the declaring is where the thinking is.

One of the optional ones is optional for a different reason than the rest: `coverage_by_kind/1`
is not ceremony to skip, it is a callback Core ships **ahead of any venue adopting it**, so
that publishing it never breaks a venue package mid-release. Adopt it when you can — see
`usage-rules/feeds.md` for the incident it exists to make visible — but a package that has not
yet is not a package doing anything wrong.

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

### A forwarded `opts` turns "never configured" into `key: nil`, not into absence

Every venue package in this family forwards its own `opts` **unchanged**, by convention,
through several layers — a `Feed` passes its `opts` straight to `PollingFeed.start_link/1`,
which never itself set `interval_ms`. When nothing upstream ever configured a key, it does
not vanish from the list; it arrives as `key: nil`, explicit and present, because something
upstream read it with a bare `Keyword.get/2` and passed the `nil` straight through.

**`Keyword.get(opts, key, default)` only substitutes `default` for an ABSENT key, never for
one that is present and `nil`.** Against `interval_ms: nil` it returns `nil`, not a sane
default — and a `nil` reaching `Process.send_after/3`, or arithmetic further downstream,
crashes the *calling* process, which this library does not supervise.
`DpExchange.Core.Config.opt/3` is `Keyword.get/3` with exactly that one difference: a
present-and-`nil` value is treated the same as an absent one. Reach for it, not
`Keyword.get/3` or `||`, at every default-bearing option your decoder or `Feed` reads out of
forwarded `opts` — deliberately not `||`, because `||` is falsy on `false` too and would
silently turn an explicit `log_requests: false` back into its default.

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
