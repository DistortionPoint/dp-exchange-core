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

## Not every venue's symbol is a pair

This guide is written for crypto, where a symbol names two things — what you are buying and
what you are paying with. **On an equity, option, future or event-contract venue it names
one.** `AAPL` does not say what you pay with; it is USD because the venue is a US broker.

So on those venues there is nothing to split, nothing to join, and no separator to translate.
Canonical and native are the same string, and **the work moves entirely into refusing the
symbols that are not this venue's shape.**

That refusal is load-bearing, not tidiness. A host that meant to send `BTC-USD` to Gemini
and sent it to Schwab must not get an answer: `BTC` is a real listed equity symbol, and so
are `ETH` and `SOL` — all of them ETFs holding nothing like the coin. **A crypto pair
silently resolving to an equity ticker is exactly the failure this family exists to
prevent**, and it is the one that stays plausible all the way to a filled order.

## Derivative symbols are the venue's, and are not constructed here

Schwab's option symbols are fixed-width and positional: 21 characters — six of underlying,
six of `yymmdd`, one `C`/`P`, eight of strike. Webull's option and futures instruments carry
their own identifiers. **None of them is built by string arithmetic in this family.**

A caller holding an option symbol got it from the chain endpoint. That is the only correct
source, because the venue's own listing is the only thing that knows which contracts exist —
a constructed symbol for a strike that was never listed is well-formed and meaningless.

`SymbolFormat` recognises these shapes so it can *pass them through unchanged*, which is a
different job from normalising a pair and should not be confused with one.

## Every new instrument surface was re-checked

Re-verified 2026-09-01 across the five packages, after the options, futures and
event-contract endpoints landed:

| venue | native form | round-trips | note |
|---|---|---|---|
| Coinbase | `BTC-USD` | ✅ | effectively identity |
| Gemini | `btcusd` — lowercase, separatorless | ✅ | the family's genuinely lossy one; 157 of 346 live symbols end in a quote that is a suffix of another |
| Webull | `BTCUSD` | ✅ | `USDT`/`USDC` must precede `USD` |
| Robinhood | `BTC-USD` | ✅ | identity |
| Schwab | `AAPL`, and 21-char option symbols | ✅ | not a pair; refusal is the work |

The invariant is the same one in every row, including the rows where the transformation is
identity: **`to_canonical_symbol(to_exchange_symbol(pair)) == pair`.** An identity mapping
that quietly uppercases, trims or rejects breaks it just as thoroughly as a wrong quote
ordering, and the conformance suite generates over each package's own `supported_quotes` so
it is checked rather than assumed.
