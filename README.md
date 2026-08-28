# DpExchangeCore

> ## ⚠️ EXPERIMENTAL — read this before depending on it
>
> This package has **never run in production anywhere.** It is published early and
> openly so it can be used and reported on, not because it is finished.
>
> - **The API may change without a major version.** While it is `0.x`, a minor bump
>   can break you. Pin three-part (`~> 0.1.0`), not `~> 0.1`.
> - **Verification is uneven, and the gaps are on the expensive side.** The conformance
>   suite passes against fakes the authors wrote, and against venues' live public
>   endpoints. **Order placement and authenticated flows are thinly covered.** No test
>   in this repo spends money, and none ever will.
> - **Maturity is declared per endpoint, not per package.** Do not trust this banner as
>   your check — read `capabilities/0`, which reports `:proven`, `:experimental` or
>   `:unsupported` for each call. A package can be broadly usable while the one endpoint
>   you need is unproven, and the reverse.
> - **You should be able to decide against using this from this section alone.** If you
>   need a client that has been battle-tested against real money on a real venue, this
>   is not that yet.
>
> Divergences, surprises and outright breakage are all worth reporting:
> [open an issue](https://github.com/DistortionPoint/dp-exchange-core/issues).

The shared contract for the **DpExchange** family of exchange adapters: behaviours,
value types, canonical-pair normalisation, and the conformance suite every venue
package must pass.

This package on its own talks to no exchange. It defines what a venue package *is*, so
that a consumer can drive any venue through one identical facade and add a new one
without editing anything outside its own repo.

## The family

| Package | Venue | Status |
|---|---|---|
| `dp_exchange_core` | — the contract | experimental |
| `dp_exchange_coinbase` | Coinbase | not yet published |
| `dp_exchange_gemini` | Gemini | not yet published |
| `dp_exchange_webull` | Webull | not yet published |
| `dp_exchange_robinhood` | Robinhood | not yet published |
| `dp_exchange_schwab` | Charles Schwab | not yet published |

Every package shares the `DpExchange.*` module namespace, which `dp_exchange_core` owns.
`dp_exchange_binance` and `dp_exchange_kraken` are reserved names with no
implementation — see [the idea doc](https://github.com/DistortionPoint/dp-exchange-core/blob/main/docs/design/ideas/binance-and-kraken-packages.md)
for why, and for what picking either up would take.

## Installation

```elixir
def deps do
  [
    {:dp_exchange_core, "~> 0.1.0"}
  ]
end
```

Pin all three segments. While this is `0.x` a minor bump may break you, and that is the
signal it is meant to send.

## Usage

Consumers do not use this package directly — they depend on a venue package, which
depends on this one. See that package's `usage-rules.md`.

Implementers of a venue package start at `DpExchange.Core.Venue` (the facade every
package exposes) and `DpExchange.Core.AdapterContract` (the suite that proves it).

## Supervision

This library does not start itself. Venue packages expose `child_spec/1` and are
supervised by **you** — nothing opens a socket because a dependency was compiled in.

## License

MIT. See [LICENSE](https://github.com/DistortionPoint/dp-exchange-core/blob/main/LICENSE).
