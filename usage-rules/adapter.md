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
