# Adoption issue for `dp_crypto_management` — ready to file

Phase 5.13 (D16). **Written 2026-08-28, not yet filed.**

`gh issue create` cannot reach `DistortionPoint/dp_crypto_management`, which is
private. Measured: **`gh` can see a DistortionPoint repository if and only if it is
public** — it sees the five public ones and none of the private ones, while seeing 133
private repositories in another org, so this is not a token without private access.

`git` reaches all of them because it authenticates by **SSH key**, not by the PAT. Two
credentials, one of which has no DistortionPoint private grant.

Paste the body below, or run:

```bash
gh issue create --repo DistortionPoint/dp_crypto_management \
  --title 'Adopt dp_exchange_core and dp_exchange_coinbase' \
  --body-file docs/handoff/adoption-issue.md
```

---

`dp_exchange_core` and `dp_exchange_coinbase` are published. This issue is what you need
to write your own design doc for adopting them — scope, surface, and every way they differ
from the adapters they replace. It is input to your plan, not a substitute for one:
sequencing, phasing and rollout are yours.

**Packages**: [`dp_exchange_core 0.1.7`](https://hex.pm/packages/dp_exchange_core) ·
[`dp_exchange_coinbase 0.1.2`](https://hex.pm/packages/dp_exchange_coinbase)

**Extraction pinned at** `553fa787` on `master`, with the Coinbase subtree **dirty** —
six tracked files modified and one untracked. Per-file SHA-256 of what was read is in
[`docs/reference/coinbase/extraction-pin.md`](https://github.com/DistortionPoint/dp-exchange-coinbase/blob/main/docs/reference/coinbase/extraction-pin.md).
Anything that landed in that subtree after it is not reflected.

---

## What you replace

- `lib/dp_crypto_management/connectors/exchanges/core/` — the whole directory
- `lib/dp_crypto_management/connectors/exchanges/coinbase/` — the whole directory
- `RateLimiting.HostRateLimiter` — the shim added for adapters that bypassed `HttpClient`

**Provider tables that stop being needed.** The facade means nothing outside a venue
package knows a venue exists beyond its name:

- `websocket/supervisor.ex:258`'s codec whitelist
- `feed_supervisor.ex`'s `websocket_module` and `feed_module` dispatch
- `stream_bootstrap.ex`'s `stream_channels` and `pairs_per_socket` maps
- `provider_registry.ex`'s `@default_providers`, if venue resolution moves to
  `DpExchange.venue/1`

## What you build

**Glue from `subscribe/2` to your `Events.*`.** The package sends
`{:dp_exchange, :coinbase, %Core.Types.Quote{}}` to the subscribing process. Receiving and
publishing is yours — the package holds no function of yours and cannot.

**A notices subscriber.** `subscribe_notices/1` carries link state, credentials rejected,
sustained pressure, coverage change, catalogue change. **Treat a notice as a prompt to
re-read, never as the record**: delivery is not guaranteed, and a consumer that treats
`:catalog_change` as the authority that a pair was delisted has rebuilt the dropped-cast
bug that let two suspended symbols open positions at 21:46.

**Provenance tagging on receipt.** The `source: :stream` / `:feed` stamping in
`price_updated/1` and `feed_sink/0` does not cross the facade — mechanism stops there. You
know which venue you subscribed to and by what call, so you can stamp it yourself.

## What you stop doing

- Starting venue sockets. `DpExchange.Coinbase` goes in your supervision tree and starts
  its own — including its own rate limiter, configured from the ceilings it declares.
- Sharding pairs across connections. Coinbase carries its whole subscription on one.
- Holding venue rate-limit configuration. `@provider_configs` becomes the venue's business.
- Injecting a sink or socket plumbing. Neither type exists any more.

## The facade

One module, `DpExchange.Coinbase`, and nothing else in the package is public API.
26 callbacks: `child_spec/1`, `start_link/1`; `provider_name/0`, `runtime_id/0`,
`asset_classes/0`, `capabilities/0`; `get_price/2`, `get_historical_prices/4`,
`get_symbols/1`, `get_order_book/2`, `get_market_overview/1`, `list_instruments/1`;
`get_balances/2`, `get_accounts/2`, `get_fees/2`, `get_transfers/2`, `place_order/3`,
`cancel_order/3`, `get_order/3`, `get_orders/2`, `get_trade_history/2`; `subscribe/2`,
`unsubscribe/2`, `update_symbols/2`, `coverage/1`, `subscribe_notices/1`;
`test_connection/2`, `get_rate_limit_status/2`, `market_status/1`, `quantization/1`.

**Branch on `capabilities/0`, never on venue identity.** Each endpoint declares
`:proven | :experimental | :unsupported`, and the declaration and the behaviour may not
disagree in either direction — the conformance suite asserts both.

---

## Behaviour deltas — the migration's task list

Your 4,582 LOC of Coinbase tests are what these break. Full detail with evidence in
[`reconciliation.md`](https://github.com/DistortionPoint/dp-exchange-coinbase/blob/main/docs/reference/coinbase/reconciliation.md).

| # | Today | In the package | Why |
|---|---|---|---|
| 1 | `provider: "coinbase"` | `provider: :coinbase` | The atom, so a consumer matches one thing. 16 of your assertions pin the string |
| 2 | `{:error, "not_supported"}` in places | `{:error, :not_supported}` always | A caller matching the atom silently missed the string |
| 3 | errors and refusals share a shape | `{:refused, reason}` is distinct | Permanent vs transient is what a caller acts on; conflating them makes a delisting a forever-blip |
| 4 | `generate_fallback_candles/4` behind `mock_external_apis` | no such path exists | See below — this one is a live defect on your side |
| 5 | two ticker formatters, `:public_ticker` / `:auth_ticker` | one | **Measured: both endpoints return the same shape** |
| 6 | `parse_rate_limit_headers/2` returns `limit: 100, remaining: 100` | no parser | Those are pagination cursors; Coinbase publishes no rate-limit headers at all |
| 7 | missing timestamp → substituted | `{:error, :missing_venue_timestamp}` | A quote whose freshness cannot be stated must not be returned |
| 8 | over-wide candle range → empty result | `{:error, {:range_too_wide, …}}` up front | **Measured: 351 candles returns zero, not the first 350** |
| 9 | `acquire/3` loops per token | one atomic reservation | Your loop is N round trips, non-atomic, and leaks tokens on partial failure |
| 10 | `check/3` ignores `weight` | honours it | Yours answers `:ok` with room for exactly one |
| 11 | `check/3` fails open, `acquire/3` fails closed | both fail closed | Undocumented asymmetry on the same condition |
| 12 | `record(provider, 0, opts)` records twice | rejected at the boundary | `1..0` is `[1, 0]` on 1.18.4 |
| 13 | `has_websocket`, `websocket_module`, `stream_channels`, `pairs_per_socket` | absent | Transport does not cross the facade |
| 14 | `auto_collect`, `default_quotes`, `overview_suits_collection` | absent | Consumer policy, not venue capability. `supported_quotes` and a new `catalog_size` remain |
| 15 | `Gemini.get_staking_balances/2`-style venue-specific functions | not on the facade | A caller must not need to know which venue it holds |

## Three things worth fixing on your side regardless of adoption

**`generate_fallback_candles/4` is still reachable.** Its error path was fixed in May 2026
after fabricated candles were traced to phantom backtest profits, but the generator
survived behind `Application.get_env(:dp_crypto_management, :test_overrides)[:mock_external_apis]`
— a **node-wide** flag, so one `async: true` test setting it gives every other test on the
node invented OHLC. The timestamps are `end_time - i * granularity` and fail
`Timeframe.aligned?/2` for any realistic `end_time`; the base price is $42,500, the same
table behind the Gemini incident.

**The Coinbase rate-limit parser fabricates.** `cb-after` / `cb-before` are pagination
cursors. Keying off them to return `limit: 100, remaining: 100` gives a caller a constant
that never moves as budget is spent — and its own comment says "Coinbase doesn't expose
exact limits". Measured: Coinbase returns no `x-ratelimit-*`, no `cb-*`, no `retry-after`.

**One comment is wrong in a way that misleads.** `coinbase/provider.ex` justifies removing
its granularity fallback with *"Coinbase itself models this correctly — an unrecognised
enum (`THREE_HOUR`) returns EMPTY"*. It does not; it returns
`parsing field "granularity": "THREE_HOUR" is not a valid value`. The conclusion is right
and we kept it. The stated evidence would lead the next reader to treat a rejected request
as "no data" and move on.

---

## Status, honestly

Both packages are **EXPERIMENTAL** and neither has run in production. Maturity is declared
per endpoint; nothing claims `:proven`, because `:proven` is earned by production use and
that is what adopting this starts.

Coverage is uneven by design: in-process fakes and live public endpoints are well covered,
**order placement and authenticated flows are not**. No test in either repo spends money.

Reporting a divergence is the loop working, not a complaint — issues on the package repos.
