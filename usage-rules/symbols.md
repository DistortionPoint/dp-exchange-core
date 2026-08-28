# Symbols and the round-trip invariant

Canonical form is `BASE-QUOTE`, uppercase, dash-separated: `BTC-USD`.

## Your `SymbolFormat` declares the contract

```elixir
defmodule DpExchange.YourVenue.SymbolFormat do
  @behaviour DpExchange.Core.SymbolNormalizer

  @mapping %{sep: "", quotes: ~w(BUSD USDC USDT USD EUR BTC ETH)}

  @impl true
  def to_canonical_symbol(native),
    do: DpExchange.Core.CanonicalPair.to_canonical(@mapping, native)

  @impl true
  def to_exchange_symbol(canonical),
    do: DpExchange.Core.CanonicalPair.to_exchange(@mapping, canonical)
end
```

Both directions are required. A package shipping one fails the compiler's missing-callback
check, which is deliberate: one-directional normalisation round-trips wrong silently.

## Quotes must be ordered longest-first — and here is what that actually means

The rule is usually stated as "longest first", which is right but under-explains itself.

**The collision is a quote that *contains* a shorter quote.** `BUSD` ends with `USD`. So
`BTCBUSD` matches `USD` before it matches `BUSD`, and a shortest-first list splits the base
as `BTCB` — a pair that does not exist, carrying values that all look plausible.

Worth knowing what does **not** collide: `USD`, `USDT` and `USDC` round-trip correctly in
either order, because none is a suffix of another. A fixture built only on those looks like
it is testing the ordering rule while testing nothing.

## The invariant

```
to_canonical_symbol(to_exchange_symbol(pair)) == pair
```

For every pair, not just the ones you thought of. The conformance suite generates pairs
over your own declared `supported_quotes` for exactly that reason.

## Both directions are total

Malformed input must never raise. Unparseable input is uppercased and passed through, never
dropped — **a dropped symbol is invisible, a strange one is reviewable.**

## Asset aliases

Where your venue publishes legacy codes, map them:

```elixir
@mapping %{sep: "", quotes: ~w(USD EUR), asset_aliases: %{"XBT" => "BTC"}}
```

The alias is reversed on the way out, so the round trip still holds.
