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
| `dp_exchange_core` | — the contract | published, experimental |
| `dp_exchange_coinbase` | Coinbase | published, experimental |
| `dp_exchange_gemini` | Gemini | published, experimental |
| `dp_exchange_webull` | Webull | published, experimental |
| `dp_exchange_robinhood` | Robinhood | published, experimental |
| `dp_exchange_schwab` | Charles Schwab | published, experimental |

All six are on Hex — checked against Hex's package API 2026-09-05, all six return `200`.
"Published" is not "proven": read `capabilities/0` for what is actually known about a given
endpoint, not this table.

Every package shares the `DpExchange.*` module namespace, which `dp_exchange_core` owns.
`dp_exchange_binance` and `dp_exchange_kraken` are reserved names with no
implementation — see [the idea doc](https://github.com/DistortionPoint/dp-exchange-core/blob/main/docs/design/ideas/binance-and-kraken-packages.md)
for why, and for what picking either up would take.

## What the contract covers

**88 callbacks**, of which a handful are required and the rest are declared. A venue package
implements what its venue serves and declares the rest `:unsupported` — which answers
`{:error, :not_supported}`, never a raise and never a missing function.

| group | callbacks |
|---|---|
| market data | quotes, top of book, order book, trades, candles, instruments, market overview |
| derivatives | option chains, expirations, greeks, futures, event contracts, funding, contract stats |
| reference | fundamentals, corporate events, filings, news, screeners, watchlists |
| account | accounts, balances, positions, portfolios, roles, fees, trade volume |
| orders | place, place many, preview, replace, preview replace, cancel, cancel all, close position |
| staking | rates, balances, rewards, history, stake, unstake |
| conversion | one-step, and the quote/commit pair |
| **money movement** | deposit addresses, networks, allowlist, withdrawal estimate, **withdraw**, payment methods, internal transfer |
| lifecycle | `child_spec/1`, `subscribe/2`, `subscribe_notices/1`, `coverage/1`, `coverage_by_kind/1`, `capabilities/0` |

Two lists tell a consumer *why* something is absent: `venue_does_not_serve/0` separates the
venue's own gaps from what a package has not ported, and `Venue.peripheral_endpoints/0` names
the ones a consumer can live without, with the reason for each.

## Guides

| | |
|---|---|
| [Authentication](usage-rules/auth.md) | what the host does, what the package does, per venue |
| [Money movement](usage-rules/money-movement.md) | the one group where a defect moves funds |
| [Live and demo together](usage-rules/environments.md) | per-process, not per-node |
| [Feeds and notices](usage-rules/feeds.md) | four venues push, one polls, nothing above the facade knows |
| [Symbols](usage-rules/symbols.md) | the round-trip invariant, and venues whose symbol is not a pair |
| [Testing](usage-rules/testing.md) | four tiers, and which capability each group can reach |
| [Implementing a venue package](usage-rules/adapter.md) | start here to write one |

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
