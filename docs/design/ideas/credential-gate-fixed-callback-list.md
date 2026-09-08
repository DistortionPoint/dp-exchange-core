# Assertion 17's `@credentialed` list cannot see opts-based credentials

**Date:** 2026-09-07
**Status:** Resolved 2026-09-07 — see "What changed" below.
**Related:**
  - `lib/dp_exchange/core/adapter_contract.ex`, `credential_gate/0` (assertion 17)
  - `dp_exchange_webull` `9f43e4d` — "Gate the widened Fake surface on credentials, as the
    real venue does"
  - `dp_exchange_schwab` `4ad5c93` — "Align Fake, refusal shapes and option validation with
    the rest of the family"

## The gap

Assertion 17 loops over `Venue.behaviour_info(:callbacks)` filtered by
`credential_gated?(name)`, and that predicate is `name in @credentialed` — a fixed list of
eleven names (`get_balances`, `get_accounts`, `get_fees`, `get_transfers`, `place_order`,
`cancel_order`, `get_order`, `get_orders`, `get_trade_history`, `test_connection`,
`get_rate_limit_status`) written when the contract's credentialed surface was small and
every credentialed callback took `credentials` as a dedicated positional argument.

The callback surface has since grown to include endpoints that take no `credentials`
argument at all and instead read one out of `opts` — `get_option_chain/2`,
`get_option_expirations/2`, `list_watchlists/1`, `get_watchlist/2`, `create_watchlist/3`,
`update_watchlist/2`, `delete_watchlist/2`, `get_financials/3`, `get_corporate_events/1`,
`get_filings/2`, `get_news/1`, `get_screener/2`, `get_positions/1`, `get_transactions/2`,
and any future addition in the same shape. None of these are in `@credentialed`, so
assertion 17 never calls them and cannot tell whether their fake honours
`credential_benefit: :required`.

This is not hypothetical: `dp_exchange_webull` and `dp_exchange_schwab` each found, by
hand, the identical defect on this exact set of callbacks the same day — a fake answering
`{:ok, _}` with credentials stripped, on a venue that signs every request. Both fixed their
own package and both said, independently, that the durable fix belongs in Core. Neither
built it, because closing it needs something the contract does not have yet: a per-callback
declaration of *where* a credential lives (`credentials` argument vs. an `opts` key, and
which key), since Core cannot assume `opts[:credentials]` is the convention every future
venue will use.

## Why this is not a quick fix

- `@arg_shapes` already encodes calling convention by `{kind, arity}`, but "credentialed"
  there means "takes a `credentials` argument," which is exactly the thing the widened
  surface does not do — adding it there would need a third shape category, not a bigger
  list.
- Any generic detection has to invent credentials to strip *out of opts* without knowing
  the key name, or accept a declaration on `Capabilities` (or a new callback attribute)
  naming which opts key is the credential, per callback.
- A wrong guess here is worse than the current gap: an assertion that strips the wrong
  key and gets `{:ok, _}` back would report a false pass, actively certifying broken code
  more confidently than no check does.

## What exists today

Assertion 17's own test now documents this limitation in place (see
`adapter_contract.ex`, `credential_gate/0`) so nobody mistakes a green assertion 17 for
proof that a venue's whole credentialed surface is gated. Each venue is still responsible
for auditing its own opts-based callbacks by hand, as `dp_exchange_webull` and
`dp_exchange_schwab` did.

## What changed

The "per-callback declaration of where a credential lives" this note assumed closing the
gap would need turned out not to be necessary. The rule that closed it instead: on a
`:required` venue, `credential_gated?/1` no longer asks "is this name in a fixed list of
callbacks known to take credentials" — it asks "is this name outside a two-name
exemption" (`test_connection/2`, `get_rate_limit_status/2`, both exempt because their
own callback doc types the credential `credentials() | nil`). Every other active
callback is checked, and `stripped_credential_args/2` empties BOTH possible credential
positions — the positional argument where `@credentialed` (unchanged, and still the
thing that decides argument SHAPE, not gating) says there is one, and `opts[:credentials]`
unconditionally, via `[credentials: %{}]` rather than the `[]` every `:opts` position
used to get regardless of shape. No per-callback "where does the credential live"
declaration was needed because the answer no longer matters to the LOOP — only to
building the right call.

`Venue.behaviour_info(:callbacks)` minus lifecycle (`child_spec/1`, `start_link/1`, via
the existing `answerable?/1`) minus the two-name exemption is the full set now checked.
A callback whose return type can never match `{:ok, _}` (`capabilities/0`, the streaming
surface) passes trivially and needed no separate exclusion.

Verified against all three `:required` venues with a temporary `path:` dependency onto
this Core checkout: `dp_exchange_schwab` (495 tests) passes with 0 new failures.
`dp_exchange_webull` (736 tests) and `dp_exchange_robinhood` (236 tests) each get exactly
one new failure, `{:market_status, 1}` answering `{:ok, :open}` unconditionally — both
are crypto-only venues whose `market_status/1` never calls out to the venue at all
(`Venue.market_status/1`'s own doc: crypto venues answer `:open` always), so this is a
genuine, still-open finding in each venue's own repo, not a defect in this widened
assertion. See `CHANGELOG.md`'s `[Unreleased]` entry for the full account.
