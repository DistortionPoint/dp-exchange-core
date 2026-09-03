# Money movement

**This is the one group where a defect moves funds.** Everywhere else in this contract a bug
produces a wrong number; here it produces a wrong transfer, and one of these operations
cannot be undone by anyone at any price.

It is also the one group that **can never be tested in this family**. Tier 4 of the testing
strategy is explicit: money-moving calls are never a test. They are answered in production,
by a consumer, with real funds. So the guarantees below are the *only* thing standing
between a host and a mistake, and if this guide is not good enough to be trusted, do not
call these endpoints.

## The decision is the host's

The package will place a withdrawal you ask for. It will not decide that one should happen,
will not retry one, and will not pick a default for anything that determines where funds go.

**Every parameter that decides a destination is required and never defaulted.** Not the
network, not the address, not the memo. A package choosing a default network is a package
choosing where your money goes.

## What is available where

| | Coinbase | Gemini | Webull | Schwab | Robinhood |
|---|---|---|---|---|---|
| deposit address | — | ✅ | — | — | — |
| networks | — | ✅ | — | — | — |
| allowlist read / request / remove | — | ✅ | — | — | — |
| withdrawal fee estimate | — | ✅ | — | — | — |
| **withdraw** | — | ✅ | — | — | — |
| payment methods | — | ✅ | — | — | — |
| internal transfer | — | ✅ | — | — | — |

**Gemini is the only venue in this family that moves money through its API**, and that is a
statement about the venues, not about how far these packages got. Robinhood Crypto publishes
nine operations and none is a transfer; Schwab's Trader API is accounts, orders and market
data; Webull and Coinbase Advanced Trade fund through their own applications. Each is
recorded with its source in that package's `docs/reference/*/negative-claims.md`.

So a host writing against this group is writing against Gemini today. Write it against the
contract anyway — the callbacks are the same shape everywhere, and the venues that answer
`{:error, :not_supported}` do so uniformly.

## Before you call `withdraw/5`

Four things, in order, and none of them is optional:

1. **`list_networks/2` first.** The same asset exists on several chains and the addresses
   are not interchangeable. `get_deposit_address/3` takes a network because nothing else in
   the contract says which ones a venue accepts. **Funds sent to an address on a chain the
   venue does not credit are gone** — the single most expensive mistake this surface allows.
   Network naming is not standardised: one venue's `ethereum` is another's `ERC20`. Rows come
   back as the venue's own maps because normalising them would invent a vocabulary no venue
   accepts back.
2. **Check the allowlist, and check it is *active*.** `list_approved_addresses/1` returns
   `Types.ApprovedAddress`, which carries whether each address is usable **yet**. Venues
   time-lock a newly added address. `request_approved_address/4` returning success is **not
   permission to withdraw** — it is a request. Read it back.
3. **Estimate, and do not record the estimate as a fee.** `estimate_withdrawal_fee/4` is
   separate from `withdraw/5` because the venues expose it separately and because the
   estimate can differ from the charge.
4. **Decide the memo.** Some networks — Solana, XRP, Cosmos — need one. An exchange address
   on a memo network without a memo is credited to nobody and is generally not recoverable.

## The memo: what the package can and cannot do for you

**It cannot tell you whether a network needs one.** `Types.DepositAddress`'s `:memo_required`
comes back **`nil`, not `false`**, and the difference is the whole point: `false` would be a
claim that no memo is needed, and `nil` says the venue did not tell us. Absence is never
substituted with a safe-looking value.

What it does do: `opts[:memo_required]` is **a caller's assertion, not a lookup**. Passing
`true` with no memo is refused locally rather than sent. A package must never synthesise a
memo.

## Idempotency, and why a retry is the dangerous part

**A retry without an idempotency key withdraws twice.** Gemini accepts `clientTransferId` —
*"a unique UUID for idempotent withdrawals. If provided, duplicate requests with the same
`clientTransferId` will not create additional transfers."*

This package **always sends one**. Not when asked; always. A withdrawal is exactly the
request whose response is most likely to be lost in transit and most damaging to repeat, and
"the caller should have passed a key" is not a defence when the caller is a retry loop
several layers up that never knew this was a withdrawal.

Pass your own through `opts` when you want to control it — that is what makes a deliberate
retry safe.

## A payment method being listed does not mean it is usable

Rows are the venue's own maps: a bank account, a card and a balance are different things with
different fields, and flattening them into one struct drops whichever one you needed.

**Venues hold new bank accounts pending verification, and the status is in the row.**
A caller filtering on presence rather than status picks a method the venue will refuse.
`add_payment_method/2` succeeding does not make the method usable either — Gemini verifies
out of band, which needs a person and some days.

## `transfer_internal/4` is not `withdraw/5`

Moving funds between two accounts at the same venue: nothing leaves the venue, no chain is
involved, no network fee is charged, and no allowlist applies. A caller reaching for
`withdraw/5` for an internal move pays a network fee it did not need to — and exposes the
funds to an address mistake that the internal path structurally cannot have.

`opts[:from]` and `opts[:to]` are both required.

## What a `{:refused, reason}` means here

The venue understood and declined — insufficient balance, an address not allowlisted, a
missing role on the key. **That is not a package error and retrying it is pointless**; the
`reason` carries the venue's own words.

Gemini publishes a `get_roles/1` call answering "will the venue let this key do that", and
asking it is cheaper than discovering a missing role from a refused withdrawal.

## What this package never does

- never retries a money-moving call on your behalf
- never defaults a network, an address, or a memo
- never treats a success without the field it needed as a success
- never turns a `nil` the venue sent into a `false` you can act on
- never decides that a transfer should happen

That last one is D2, and it is the reason this guide is short on convenience and long on
preconditions.
