# Complete Venue API Coverage — Design Document

**Date**: 2026-08-31
**Status**: Implementing — Phases 0, 1, 2 complete and published. Venue phases (3–13) next.
**Version**: 3.6
**Author(s)**: Billy / Claude collaboration
**Repo**: `DistortionPoint/dp-exchange-core` (`/Volumes/Dev/development/dp-exchange-core`)

---

## 0. What this plan is, and what it is not

The extraction plan (`docs/design/closed/2026-08-26_exchange-adapter-package-family.md`)
built five venue packages and a shared contract. It did **not** set out to cover each
venue's API — it set out to move what the host already had, plus one venue built from
documentation. That succeeded on its own terms and left a large gap on this one.

**This plan closes that gap: every active provider's API, implemented as fully as the
contract can express, with every omission approved by the architect rather than decided
here.**

**What this work actually is.** These are modules that give third-party API and socket
access a single shape, plus a `Core` that makes them behave the same for a host. So the
work is one shape decided once and then applied — the endpoint count is volume, and the
**twenty-seven capability groups** are the difficulty (§6 D7). Phases are one group at a time
across every venue that has it, which is what stops five shapes emerging for one idea.

### The rule this plan runs under

> Anything the venue offers and this family does not implement requires **architect
> approval to skip**. Nothing is deferred on Claude's judgement.

Two categories are approved for skipping in advance:

1. **The consent leg of authentication — and only that.** The pre-approved skip is
   narrower than "auth", and the rule is the one already shipped in `dp_exchange_schwab`:

   | | side | why |
   |---|---|---|
   | authorization / consent redirect | **host** | needs a browser and a person; no library can do it |
   | the initial code-for-token exchange that follows it | **host** | part of the same human-in-the-loop grant |
   | **token refresh, rotation, revocation, validity checks** | **package** | mechanical, no human — and §6.0 places "signing, session refresh, token rotation" on this side explicitly |
   | request signing | **package** | same |

   Schwab already works this way: `Auth.refresh/2` performs `grant_type=refresh_token`
   in-package, and only the browser grant stays with the host. **Every venue is treated
   the same**, so these are `PLANNED`, not skips:

   - **Webull** — `connect-api/create-and-refresh-token`, plus `/auth/tokens/create` and
     `/auth/tokens/check`. Only `get-authorization-code` and the `connect` redirect are
     the host's.
   - **Gemini** — `rest-api/common/oauth/refresh-access-token` and `.../revoke-access-token`.
     Only `authorization-request` and `authorization-token-request` are the host's.
   - **Coinbase** and **Robinhood** have no token endpoints at all: both sign each request
     (JWT and Ed25519 respectively), so there is nothing here to place.

2. **FIX-based endpoints** — out of scope entirely. This is a REST/WebSocket family.

Everything else that ends up unimplemented must appear in §7's disposition register with
status `PROPOSED-SKIP` and a reason, and must be signed off before the plan leaves
`Draft`.

---

## 1. Project Overview

### 1.1 The finding that shapes the whole plan

**All five venues publish public API documentation. None of it except Schwab's is
committed to these repositories.** Those are different problems and conflating them was
the first error in this analysis — the documentation is not missing, the *capture* is.

| venue | public documentation | committed here |
|---|---|---|
| coinbase | complete REST endpoint index on the developer site | 3 files — candles, reconciliation, pin |
| gemini | REST reference organised by category | 5 files — candles, rate limits, demo env, socket, pin |
| webull | developer portal, with a `sitemap.xml` index | 2 files — streaming API, pin |
| robinhood | crypto trading API reference | 1 file — pin |
| **schwab** | login-gated, no public spec | **46 files — both OpenAPI docs, both prose docs, raw captures, the 17 User Guides, and the product-landscape finding** |

The irony is worth stating: **the one venue whose documentation is behind a login is the
only one whose documentation is committed**, because it was the only one that forced the
question. The four with freely available docs were extracted from **host adapter code**,
so nobody ever fetched the vendor's endpoint list. Their extraction pins record host file
SHA-256 hashes — what was read out of `dp_crypto_management` — and no endpoint inventory,
because none was taken.

**That is the mechanism by which functionality was skipped.** Port an adapter and you
implement what the adapter implemented. Nothing recorded what the venue also offered, so
the omissions are invisible in the repositories today.

That capture is **done** — §1.3 — and committed as a per-endpoint inventory in each
package. It is not a phase of this plan.

### 1.2 Primary documentation only — a derived artefact is never a capture source

**This rule is the plan's most important, and it was arrived at by breaking it.**

An earlier pass of this analysis could not read Webull's documentation portal (a
single-page app that serves its reference through client-side routing), found the vendor's
official SDK, extracted **29 endpoints** from its request classes, and wrote into this plan
that *"a vendor SDK is a better capture source than a rendered documentation page."*

The architect rejected that, and the measurement settles it. Webull's own documentation
sitemap lists **85 endpoints** in the Trading and Market Data APIs alone. **The SDK
covered 34% of the surface**, and had it been used, this plan would have audited against a
number three times too small and declared coverage of 17% where the truth is 6%.

**It is the same category error this entire plan exists to correct, one level further
out.** The packages are at 14% coverage because they were built from the *host adapter* —
a derived artefact — instead of vendor documentation. Auditing them against a *vendor SDK*
— also a derived artefact — would have reproduced the failure while appearing to fix it. An
SDK shows what its author implemented. A host adapter shows what its author implemented.
Neither shows what the venue offers, and only the last question matters.

So, for any future capture:

**Capture from the vendor's own primary documentation.** Where a specification exists
(Schwab's OpenAPI), it is the source. Where the docs are a rendered site, the vendor's
**`sitemap.xml` is the index** — every one of the four publishes one, and each lists the
per-endpoint reference pages:

| venue | index | endpoints it lists |
|---|---|---|
| coinbase | `docs.cdp.coinbase.com/sitemap.xml` | **51** |
| gemini | `developer.gemini.com/sitemap.xml` | **68** (76 pages, 8 are category indexes) |
| webull | `developer.webull.com/apis/sitemap.xml` | **85** in Trading + Market Data; 229 documented in total |
| robinhood | `docs.robinhood.com/sitemap.xml` | 5 pages; the endpoint list is in the page's own JS bundle |

**Never an SDK, never a third-party wrapper, never a prior adapter.** If the primary
documentation cannot be read, that is a fact to report — not a licence to substitute
something nearby that reads more easily. Substituting a plausible nearby source for the
real one is precisely the failure mode §0 of the closed plan names.

### 1.3 Every count was scoped to one vendor "product" — and a product boundary is the vendor's packaging, not a fact about the venue

**Third instance of the same error.** The first was building packages from the host
*adapter*. The second was proposing to audit them against a vendor *SDK*. Both read a slice
and reported it as the whole. So did this: each venue's count came from **one API product**,
without checking what else the vendor publishes. Every one publishes more.

| venue | this package uses | also published | reference pages |
|---|---|---|---|
| **coinbase** | Advanced Trade (61: 52 REST + 9 WS) | v2 App (226), **Deribit (157)**, Prime (125), Exchange (88), International (62), Derivatives (51), Onramp/Offramp (11), Business (10), **Staking (7)**, smart contracts (4), addresses (3), introduction (1) | **806** |
| **gemini** | `trading/rest-api` (68) | prediction markets (38), `rest-api/common` (13 — **includes the OAuth token lifecycle, which is in scope**); **only the FIX surface (79) is a pre-approved skip** | **335** |
| **webull** | Trading + Market Data (85) | Broker (78), Broker Market Data (37), FD Events (13), Custom (12), Connect (4 — **`create-and-refresh-token` is in scope**; only the consent redirect is not) | **247** |
| **robinhood** | `crypto/trading` (9) | `crypto/connect` (10) | **~18** |
| **schwab** | Trader API – Individual (23) | **24 products**, including a separate **Crypto** product and **Thinkorswim** | — |


**Coinbase's 806, reconciled exactly.** This row's earlier form named thirteen surfaces summing to 667, a
139-page shortfall. The sitemap was re-enumerated on 2026-08-31: `api-reference` holds
**806 pages across 22 top-level segments**, and every page is now accounted for.

| segment | pages | |
|---|---|---|
| `v2` (App API) | **226** | 169 REST + 49 webhooks + 8 conventions/errors/rate-limits |
| **Deribit** | **157** | see below — the whole of the shortfall |
| `prime-api` | 125 | |
| `exchange-api` | 88 | |
| `international-exchange-api` | 62 | |
| `advanced-trade-api` | **61** | 52 REST + 9 WebSocket — the plan had 51, which was its *endpoint* count, not pages |
| `derivatives-api` | 51 | |
| `rest-api/*` (CDP platform) | 25 | onramp/offramp 11, staking 7, smart contracts 4, addresses 3 |
| `business-api` | 10 | |
| `introduction` | 1 | |
| **total** | **806** | |

**The gap was Deribit, and it was understated four-fold.** The plan carried "Deribit (37)".
Coinbase renders that API as twelve *sibling* trees under `api-reference` — `trading` (30),
`market-data` (29), `block-rfq` (13), `block-trade` (11), `account-management` (10),
`subscription-management` (6), `session-management` (5), `combo-books` (5), `supporting` (4),
`json-rpc-api` (3), `authentication` (2), `networks` (1) — none of which carries "deribit"
in its path. Each was verified to render from `coinbase-deribit-app-api/adv-starbase-openapi.json`
or its AsyncAPI counterpart, and their method names are Deribit's JSON-RPC style
(`private-buy`, `public-get_book_summary_by_currency`). With the 38 pages that *are* under
`coinbase-deribit-app-api`, Deribit is **157**.

**This is the §1.3 error once more, in a new costume.** Every previous instance was a slice
mistaken for the whole because a *product* was mistaken for the venue. This one is a slice
mistaken for the whole because a *path prefix* was mistaken for the product boundary: twelve
trees belonging to one API, sitting at the same level as the APIs themselves. Counting by
URL prefix is exactly as unreliable as counting by product page, and for the same reason —
**the vendor's information architecture is not the venue's capability model** (D7).
#### The product boundary is not a scope boundary

An earlier draft turned this table into a question — *"which products are in scope?"* — and
made staking depend on the answer, because Coinbase files staking outside Advanced Trade.

**That is the wrong unit entirely.** A vendor's product split is its own commercial
packaging: how it prices, licenses and sells access. It carries no information about what
the venue can do. Coinbase filing staking under a separate heading does not make Coinbase
less of a staking venue, and **a consumer asking "can I stake on Coinbase?" is not asking
about Coinbase's product catalogue.**

Worse, letting the vendor's packaging drive our scope leaks that packaging through the
facade — which is exactly what D12 forbids. A consumer must not be able to tell from the
facade how a venue organises its own APIs.

**So the unit is the capability, not the product.** The question is *what can this venue
do, and which of it does the facade express* — and where the vendor happens to file an
endpoint is an implementation detail behind the facade, no different from which host it is
served from.

The under-counting finding stands: this analysis measured one slice per venue and must
measure all of it. What does not stand is the conclusion drawn from it.

#### What is genuinely out of scope is functional, not packaging

A real boundary does exist, and it is about **what the capability is for**, not where it is
filed:

- **Webull's Broker API family** (140) — account opening, KYC, ACH and wire funding,
  document upload, agreements, account closure. That is *operating a brokerage*, not
  trading on one. A consumer of this family is a trader, not a broker-dealer.
- **Robinhood Connect** (10, `/catpay/v1/*`) — an on/off-ramp for embedding Robinhood's
  buy flow inside a third-party app. Not a trading surface.
- **Coinbase Onramp/Offramp** (11), **Business** (10), **smart contracts** (4) — same
  shape: adjacent products serving a different job.

Those are proposed as skips on **functional** grounds, and the architect can weigh them on
that basis. Coinbase Prime, Exchange, Derivatives and the v2 App API are a harder case
precisely because they *are* trading capabilities — the same venue, reachable a different
way — and they are **not** proposed for skipping here.

### 1.4 Coverage as measured today, against the surface each package already touches


Every count below comes from the vendor's own documentation index, enumerated on
2026-08-31. Implemented counts come from reading the paths `lib/` constructs.

| venue | documented | implemented | coverage | source of the count |
|---|---|---|---|---|
| **webull** | **85** | **5** | **6%** | vendor sitemap, every page read |
| **coinbase** | **51** | **4** | **8%** | vendor sitemap — Advanced Trade REST |
| **gemini** | **75** | **12** | **16%** | vendor sitemap; `trading/rest-api` (68) + in-scope `rest-api/common` (7: admin 5 + oauth 2) |
| **robinhood** | **9** (v1 operations) | **2** | **22%** | vendor documentation bundle |
| **schwab** | **23** | **12** | **52%** | committed OpenAPI |
| **total** | **243** | **35** | **14%** | |

**Coverage is 14%.** Earlier drafts of this document said 24% and then 13%; both came from
counts that had not been taken endpoint by endpoint. This one has: 179 vendor pages were
fetched and read, which is also how 26 category index pages were found masquerading as
endpoints in the earlier totals.

**This 243 is a floor, not the surface.** It counts only what each package already touches
— one slice per venue. Add the rest of what the five vendors publish (§1.3) and the
documented surface runs to well over a thousand reference pages. **How much of it is in
scope is a question about capabilities, not about vendor packaging** (OQ2) — and until it
is answered the real denominator is unknown.

What is not in doubt is that **34 endpoints is a small fraction of any reading of it**.

### 1.5 Streaming is in scope everywhere, and four of five venues have it

Earlier drafts listed WebSocket surfaces in the "other products" column beside Prime and
Exchange, which reads as out-of-scope. **It is not.** `subscribe/2`, `unsubscribe/2` and
`coverage/1` are required facade callbacks; §6.0's rule is that **both endpoints always
exist**. Streaming is core, and **only Robinhood lacks it**.

| venue | documented streaming | implemented | gap |
|---|---|---|---|
| **schwab** | **Streamer: 15 services, 6 commands** | **none** | **the whole thing** |
| **gemini** | ~10 streams — `@bookTicker`, `@depth`, `@trade`, `@ticker`, plus `orders@account`, `balances@account`, `positions@account`, `settlements@account`, `orders@session` | **1** — `@bookTicker` | 9 |
| **coinbase** | Advanced Trade WebSocket channels | 6 — `ticker`, `level2`, `market_trades`, `candles`, `heartbeats`, `user` | to be confirmed |
| **webull** | MQTT streaming + a gRPC surface | subscribe / unsubscribe | topic coverage unconfirmed |
| robinhood | **none** | n/a — polls | none, correctly |

**Robinhood's "none" was itself an inherited claim, and has now been checked.** It came
from the host adapter's moduledoc and was carried through four documents unverified —
which, after Schwab, is exactly the kind of claim that should not be trusted on its
provenance. Verified against the vendor: the documentation is five pages, all were read,
and `websocket`, `wss://` and `streaming` appear **zero** times in any of them or in the
JS bundle that carries the endpoint list. (67 apparent `sse` matches are the substring in
*asset*.)

Two things make the check trustworthy rather than merely negative. **The Schwab lesson was
applied**: its streamer is missing from the OpenAPI because it is not REST, so the prose
pages were checked too — Robinhood has five pages and all five were checked. And **the
tempting wrong answer was rejected**: searching for "Robinhood crypto API websocket"
returns confident claims that it supports both REST and WebSocket. Those describe
**third-party wrappers**. Same derived-artefact error, third form.

It remains an absence of evidence rather than a vendor statement, which is weaker than a
positive one — but the documentation enumerates every endpoint including a full parallel
v2, so a stream would be listed there if one existed.

#### Schwab's package asserts something false

`dp-exchange-schwab/mix.exs` carries the comment *"No `websockex`. **This venue has no
streaming API at all** — its feed is a REST poll"*, and `Feed`'s moduledoc says *"Neither
of Schwab's Trader API specifications describes a streaming surface."*

**Both are wrong**, and the evidence was in the documentation captured on 2026-08-28 and
committed to that repository. Schwab publishes a **Streamer** carrying market data and
account activity over WebSockets:

```
LEVELONE_EQUITIES   LEVELONE_OPTIONS   LEVELONE_FUTURES   LEVELONE_FUTURES_OPTIONS
LEVELONE_FOREX      NYSE_BOOK          NASDAQ_BOOK        OPTIONS_BOOK
CHART_EQUITY        CHART_FUTURES      SCREENER_EQUITY    SCREENER_OPTION
ACCT_ACTIVITY       ADMIN              LEVELONE_EQUITY
```

with `LOGIN`, `LOGOUT`, `SUBS`, `UNSUBS`, `ADD` and `VIEW` as its commands.

Three consequences, and they are not small:

**`get_order_book/2` is declared `:unsupported` on false grounds.** The reason recorded is
that *"no endpoint in either document returns depth"* — true of the REST API, false of the
venue. `NYSE_BOOK`, `NASDAQ_BOOK` and `OPTIONS_BOOK` are depth.

**`/userPreference` is not a curiosity, it is the bootstrap.** This document listed it as a
gap with "no facade home". It returns `streamerInfo` with `streamerSocketUrl` — it is *how
you connect to the streamer*. It is the single most important missing Schwab endpoint.

**`ACCT_ACTIVITY` is streaming order and fill events**, which is `streamable: [:orders,
:fills]` — a claim no venue in this family currently makes.

The mistake was reading the OpenAPI documents and stopping. The streamer is not in them
because it is not REST; it is in the prose documentation beside them, in a file this
repository already holds.

### 1.6 What "implemented" currently means, per venue

Read from `lib/` on 2026-08-31.

**Coinbase** — `/market/products`, `/market/products/{id}/ticker`,
`/market/products/{id}/candles`, plus the authenticated ticker variant. Market data only.
**No account, order, portfolio, fee, convert or futures endpoint exists in the package**,
and `place_order/3` is `:unsupported`.

**Gemini** — `/v1/symbols`, `/v1/pricefeed`, `/v1/account`, `/v1/balances`,
`/v1/heartbeat`, `/v1/mytrades`, `/v1/notionalvolume`, `/v1/order/new`, `/v1/order/cancel`,
`/v1/order/status`, `/v1/orders`, `/v1/transfers`. The best-covered crypto venue, and
still missing order book, public trades, symbol details, candles by the documented path,
cancel-all, order history, derivatives, margin, clearing and staking.

**Webull** — `/openapi/instrument/crypto/list`, `/openapi/market-data/crypto/snapshot`,
`/openapi/market-data/crypto/bars`, streaming subscribe and unsubscribe. **5 of 85 —
the widest gap in the family.** The venue's reference lists nine futures endpoints, nine
fund, nine event-contract, five order, five financial-statement, four option, four crypto,
three account, plus watchlists, screeners, news, filings, calendars, analyst data,
company profiles, market sectors, gainers/losers and NOII. **This package implements the
four crypto market-data pages and nothing else.**

**Robinhood** — `/api/v1/crypto/marketdata/best_bid_ask/`,
`/api/v1/crypto/trading/trading_pairs/`. **2 of 8.** Missing: `estimated_price`,
`trading/accounts`, `trading/holdings`, order list, order placement, single order, and
order cancellation. **There is also a complete parallel `v2`** carrying the same
operations plus fee-tier order placement, and `estimated_price` moved from `marketdata` to
`trading` between versions.

`place_order/3` is `:unsupported` today on a venue that supports it, so **the package
cannot trade a venue that can be traded.**

**Schwab** — 12 of 23. Missing: `/accounts` (all accounts), `/{symbol_id}/quotes`,
`/chains`, `/expirationchain`, `/movers/{symbol_id}`, `/markets/{market_id}`,
`/instruments/{cusip_id}`, `/orders` (cross-account), both `/transactions` endpoints, and
`/userPreference`.

---

## 2. Subtask Checklist and Progress Tracking

**A task marked done records what was *found*, not that it finished.** That is the
convention the closed extraction plan ran under and it is the reason its retrospective was
writable at close.

Phases are **one capability group at a time across every venue that has it** (D7). Within a
group: declare first, implement second — the closed plan's §11 found that deriving a
declaration from documentation caught more defects than reading code did.

**Every phase ends the same way**, and this is not repeated per task: all touched packages
green — 0 test failures, coverage at or above 90, `mix format --check-formatted`,
`mix credo --strict` clean, `mix dialyzer` clean, Core's conformance suite passing — plus a
CHANGELOG entry and the venue's `endpoint-inventory.md` updated so the matrix and the code
cannot drift apart.

---

### Phase 0 — Finish the enumeration

The audit covered the slice each package already touches. D7 widened the scope, so the
inventories must widen with it before anything is planned against them.

- [x] **0.1** ~~Extend each venue's `endpoint-inventory.md` to the full in-scope surface.~~
      **Done 2026-08-31 for the two venues where the touched slice was not the surface**
      (Coinbase, Gemini — see 0.2). Webull's 85, Robinhood's 9+9 and Schwab's 23 + Streamer
      were already the whole in-scope surface, confirmed against their indexes.
- [x] **0.2** ~~Turn Coinbase's 806 pages into an endpoint count.~~ **Done 2026-08-31:
      712 REST operations and 46 socket channels.** All 806 pages fetched and each page's
      own `pageMetadata.openapi` field read; **a page with no such field is an index page**,
      which is how endpoints were separated from pages rather than estimated. Two products
      publish specs and were counted from those (`derivatives-api/rest-api/cde-spec.json`
      49; Deribit's `adv-starbase-openapi.json` 115 REST and `…asyncapi.json` 37 channels;
      Advanced Trade's asyncapi 9). **The method's check: it returns exactly 51 for
      Advanced Trade, the one product counted by hand.** Deribit was 37 in the last draft
      and is **115**. In scope after D7's embedding skip (−11 onramp/offramp) and D1
      (−6 INTX): **695 REST + 46 sockets**. Full list committed as
      `endpoints-enumerated.tsv` (718 lines).
- [x] **0.3** ~~Enumerate Schwab's other 23 products.~~ **Answered 2026-08-31 against the
      signed-in portal — and the task was built on a wrong premise.** The catalogue does
      hold **24** products, but that is a *catalogue*, not a reachable surface:
      **7** are visible to this account and **1** is entitled. `lob-access/Status` returns
      `200` for Trader API - Individual and `204` for the other six; a spec URL under any
      `204` product redirects to `/home` before a specification request is issued
      (verified against Advisor Services and Trader API - Commercial).
      **Crypto and Thinkorswim are real catalogue entries but are not among the seven**,
      so they are not gated behind a request — they are not offered to this account at all.
      The account holder is an individual client, not a broker or RIA; the six unreadable
      products are the products of *being* one. **No credential this project will ever
      hold reaches them**, which retires this task rather than deferring it.
      Recorded in that repo's `portal-product-landscape.md`, with the 88 API names per
      product under `portal-raw/categorized-api-products/`.
- [x] **0.4** ~~Fold the widened inventories into §7's register and restate coverage with a
      measured denominator.~~ **Done 2026-08-31. In scope: 1,004 operations; implemented 35;
      coverage 3.5%.** The "1,000+ endpoints / roughly 3%" the draft carried turned out
      close, but it was a guess at a number that could be counted — and the same guessing
      put Deribit at 37 when it is 115. Two denominators moved when measured: **Coinbase
      from "~795 pages" to 741 in-scope operations** (258 of its 806 pages are index pages)
      and **Gemini from 76 to 128**, once prediction markets and the real socket surface
      were read from the vendor's AsyncAPI instead of a summary table.
- [x] **0.5** ~~Read the paths for Gemini's `rest-api/common`.~~ **Done during planning,
      2026-08-31.** All five admin endpoints and both package-side oauth endpoints now
      carry real paths in §2, read from the vendor's pages. Two findings: `admin/subaccounts`
      is a **guide page, not an endpoint** (Gemini's in-scope total is 75, not 76), and
      `refresh-access-token` shares a URL with the host's `authorization-token-request`,
      separated only by `grant_type`.
- [x] **0.6** ~~Enumerate the streaming surfaces.~~ **Done — and then corrected in Phase 0
      proper.** During planning this was read off Gemini's `trading/websocket/streams`
      **Stream Matrix**, giving 11 families, which replaced an unsourced "10". Phase 0 found
      the vendor's **AsyncAPI document** and it carries **22 channels** — the Stream Matrix
      omits the entire `requestForQuote` family, `connection`, both `…Snapshot` channels and
      the four `…Fast` depth variants. §2 lists all 22. **A rendered summary table is a slice
      of a specification**, and this is the fourth time in this plan that a slice was taken
      for the whole.
- [x] **0.7** **Capture the portal's User Guides — 17 documents that had never been read.**
      Done 2026-08-31. They hang off `/user-guides`, not off any product, and are in
      neither OpenAPI document, which is exactly why a product-shaped capture missed them.
      Two matter here: **`Authenticate with OAuth`** (three-legged flow and token
      vocabulary) and **`OAuth Restart vs. Refresh Token`**, which is the decision table
      for refresh-versus-restart and therefore **the document that draws this venue's
      package/host auth boundary** — refresh is the package's, every restart condition
      needs a browser and a person. Neither fact is derivable from the specifications.

### Phase 1 — Correctness: fix what is currently wrong

Small, and it comes before new work because these are defects in shipped packages.

- [x] **1.1** ~~Schwab asserts it has no streaming API.~~ **Corrected 2026-08-31.**
      `mix.exs`, `Feed`'s moduledoc, `DpExchange.Schwab`, `README.md`, `Capabilities` and
      both copies of `usage-rules.md` all said the venue had no streaming surface. Each now
      distinguishes **what the package does not implement** from **what the venue does not
      have**, and names the source that settles it. `usage-rules.md` §9 was retitled from
      "What this venue does not have" to "What this package does not implement" — the
      heading was the error in miniature.
- [x] **1.2** ~~`get_order_book/2` is `:unsupported` on false grounds.~~ **Reason corrected,
      value unchanged**, as the task specified. It stays `:unsupported` because this package
      cannot yet read depth; the recorded reason is no longer "the venue has none".
- [x] **1.3** ~~D6 — migrate the six undocumented paths.~~ **Done, and the task's premise
      was half right.** It said "no probe needed: every one has a documented replacement".
      **True of the paths, false of the payloads** — three of Webull's five needed more than
      a rewrite, and a path-only migration would have compiled, passed the suite and been
      wrong in three places:
      **snapshots** stamp rows `last_trade_time` / `quote_time`, neither accepted by the
      timestamp reader — every quote would have failed `:missing_venue_timestamp`;
      **bars** renamed `symbol` to `symbols` and added a *required* `real_time_required`;
      **instruments** made `category` required and became **paginated**, so one call returns
      a page, not the catalogue — a truncated symbol list being the worst failure shape here,
      since every symbol in it is real and the missing ones are simply never traded.
      Gemini's `/v1/transfers` → `/v2/transfers` was a clean swap; the vendor's own spec says
      *"The v1 transfers endpoint is being retired."*
      **No test asserted any path before this**, so the suite would have passed with the old
      ones — `DocumentedPathsTest` now locks both halves.
- [~] **1.4** **D5 — move Robinhood to v2. Half done, and the other half is a Phase 2
      question, not a path swap.**
      `get_symbols/2` moved: v2's `trading_pairs` returns the same `results` + `next` shape.
      **`get_price/3` stays on v1.** Robinhood documents v2's `best_bid_ask` response as
      exactly `{"results": [{"symbol", "bid", "ask"}]}` — **top of book, and nothing else**.
      A bid or an ask is a *resting order*; `Core.Types.Quote`'s `price` is the *last traded*
      price, and they are different quantities that coincide only when that order fills.
      v2 therefore carries no traded price and no timestamp, both of which are `Quote`
      `@enforce_keys`. Building a `Quote` from a BBO would mean inventing one or both.
      **The architect's ruling on the timestamp:** a best-bid/ask is real time, so the correct
      stamp is the moment of the call — an *observation* time. `Core.Types.Quote` currently
      documents `:timestamp` as "**the venue's own** — whatever it gave us, used as-is", so
      recording an observation time there needs Core to say so first. **Phase 2 owns this**:
      top-of-book is a different shape from a quote, and forcing it into `Quote` is the
      substitution this plan exists to prevent. v1 remains documented and current (D5 found
      both versions live), so this is a deferral with a working endpoint under it.
- [x] **1.5** ~~D1 — confirm nothing deprecated is in use.~~ **Asserted, not just checked.**
      `DeprecatedEndpointsTest` (Coinbase INTX) and `ArchivedSocketsTest` (Gemini's four
      archived socket APIs) fail the build if either reappears. Both read **code with
      documentation and comments stripped**: the first version of the Gemini guard failed on
      `Socket`'s moduledoc, which names an archived endpoint precisely to explain why the
      package avoids it. That explanation is the most valuable thing in the file and must not
      be deleted to satisfy a test.

#### 1.6 — a defect the phase found rather than planned for

- [x] **Robinhood used an ask as a trade price.** `quoted_price/1` read
      `row["price"] || row["ask_inclusive_of_buy_spread"]`. **This is §0's substitution in its
      purest form**: the ask is a real number the venue really sent, so nothing looks wrong,
      and the meaning is wrong. A consumer computing a position value, a P&L or a stop from
      an ask believes it holds a traded price, and the gap is widest exactly when the book is
      thin — when it matters most.
      The fallback is gone; a response without a traded price now returns
      `{:error, :no_trade_price_in_response}`.
      **The test suite asserted the defect as intended behaviour** — a test named *"the price
      is the ASK when the venue sends no separate price"* passed, which is how it survived
      review. Six fixtures supplied an ask and no price and expected a `Quote`. All now carry
      a traded price deliberately **inside** the spread and equal to neither side, so a test
      that only passes when `price == ask` fails.
      **This is the strongest argument in the plan for the Phase 14 negative-claim audit and
      for reading tests as claims**: a test can encode a defect as firmly as code can.

### Phase 2 — Normalise: decide every shape before writing any of it

The design phase. Twenty-seven capability groups; nineteen already have a facade home, **eight need
new design**. For each, make §4.2's four-way decision — new callback, widen an existing
one, capability flag, or a skip to propose — and write the conformance assertion that keeps
the declaration honest.

- [x] **2.0** ~~Top of book is not a quote.~~ **Decided and built in Core, 2026-08-31 — and
      the problem was bigger than 1.4 reported.**

      1.4 found that Robinhood's v2 BBO could not fill a `Quote`. The architect's correction
      went further: **`Core.Types.Quote` itself carried `:bid` and `:ask`, and all five
      venue packages filled them in.** Book data on a trade type — the conflation was in the
      contract, not just in one package's parser, which is why one package could read
      `price || ask` and look consistent with the type it was filling.

      **Decision — (a), a distinct type.** Not (b), widening `Quote`, which would have made
      `price` optional and `:timestamp` mean two things depending on venue.

      **`Core.Types.Quote` loses `:bid` and `:ask`.** It is now trade data only: `price`,
      `volume`, the venue's `timestamp`. Nothing in it can stand in for a book.

      **`Core.Types.TopOfBook` is new**, and has no `price` field and no way to add one:
      `bid`, `ask`, optional `bid_size` / `ask_size` (`nil` = not published, never zero),
      `venue_time` (the venue's own, or `nil` — several BBO endpoints publish none), and a
      required **`observed_at`**. `mid/1`, `spread/1` and `crossed?/1` are functions rather
      than fields, so a mid reads as a caller's choice rather than as data the venue sent.

      **The two timestamps are the whole point.** The architect's ruling — a real-time BBO is
      stamped at the moment of the call — is honoured by `observed_at`, *without* touching
      `Quote`'s guarantee that `:timestamp` is the venue's own. An observation time in a
      field named for observation is a fact; the same value in a field documented as the
      venue's would be a substitution.

      **`get_top_of_book/2`** added to the `Venue` behaviour (33 callbacks), registered as
      peripheral, and **conformance assertion 14** added: a `TopOfBook` is returned rather
      than a `Quote`, `observed_at` is present, `venue_time` is the venue's or `nil`, and
      **`TopOfBook` cannot grow a `price` field**. The suite caught the new callback the
      moment it was declared, which is the mechanism working as designed.

- [x] **2.0a** ~~Move each venue's bid/ask off `Quote` and onto `get_top_of_book/2`.~~
      **Done across all five, 2026-08-31, on Core 0.1.16.** Every package now implements
      `get_top_of_book/2` in its REST module, its facade and its fake, and every venue's
      quote carries only what traded.

      **The migration found the same defect twice more.** Phase 1 caught Robinhood reading
      `price || ask`. Doing this work surfaced:

      **Gemini's socket** built a `Quote` with `price: message["c"] || bid` — falling back
      to the **bid** when the book had not traded — with a comment defending it as better
      than inventing a value. **Webull's socket** did the same on its book topic:
      `price: bid || ask`, defended as *"a real quoted number, labelled as the bid too"*.
      Both are real numbers and neither is a price. A `bookTicker` frame and a Webull
      `quote` frame are top-of-book, and both now deliver `TopOfBook`; where Gemini's frame
      also carries a last trade it delivers that separately, as a `Quote`.

      **Three venues, three independent instances, each with a comment explaining why it was
      acceptable.** That is what a type that cannot hold the wrong value is for.

      **The fakes had it too.** Robinhood's fake set `price: ask` with the comment *"as the
      real adapter uses when the venue sends no separate price"* — reproducing the defect
      the real adapter had, which is how a suite agrees with itself and is wrong twice.
      Every fake's spread now straddles the traded price and equals neither side, so a test
      that only passes when they coincide fails.

      **Schwab's candles were the 2.10 finding in the wild.** `get_historical_prices/4`
      built `Quote`s with `price: close`, on the reasoning that "a bar's price, for a
      series, is where it ended" — discarding open, high and low at the boundary where no
      caller could see it. Now `Types.Candle`, four prices carried, `:opened_at` named for
      Schwab's own convention. The validation order was changed too: **timestamp is checked
      before prices**, so an undated bar still reports `:missing_venue_timestamp` rather
      than a shape error about a different problem.

      All five suites green: schwab 249, gemini 329, webull 223, coinbase 161,
      robinhood 114. Core 368. Credo clean and formatted throughout.
- [x] **2.1** ~~Options (D3).~~ **Built 2026-08-31 from Schwab's `OptionContract`,
      `OptionChain` and `OptionContractMap` schemas.** Five types, three callbacks
      (`get_option_chain/2`, `get_option_expirations/2`, `get_option_greeks/2`), and `legs`
      on `Types.Order`.

      **The chain row was split three ways, and that is the whole design.** Schwab returns
      fat rows: strike and expiry beside `bidPrice`, `askPrice`, `lastPrice`, `markPrice`
      and `theoreticalOptionValue`. Keeping that shape would hand a caller **five plausible
      prices and no help choosing** — the defect this plan opened with, in a wider form. So:
      **`OptionContract`** is identity only and carries no prices; book goes to `TopOfBook`,
      last trade to `Quote`, and **`OptionGreeks`** takes the model output, with the
      venue's theoretical value named `:model_price` because it is the field most easily
      mistaken for a price.

      **Greeks are model output, not market data.** Two venues quoting one contract publish
      different deltas and neither is wrong — they used different marks, surfaces, rates and
      clocks. Recorded on the type, since nothing in the numbers says so.

      **`OptionChain` stays two-dimensional** — `expiry → strike → {call, put}` — because a
      flat list is lossless in data and answers none of the questions a chain is asked. **A
      one-sided strike keeps `nil`, not a missing key**, so a caller iterating strikes sees
      it. `underlying_price` is carried on the chain: fetched separately it is a second
      observation at a second time, which is how a "delta-neutral" position turns out not
      to be.

      **An option is not a symbol, and the contract stops pretending.** `SymbolNormalizer`
      refuses to build option symbology and that stays correct — Schwab's is fixed-width
      positional (`XYZ   240315C00500000`). The four identity fields *are* the contract;
      `:venue_symbol` carries the venue's own string, produced by the venue package and
      **never reconstructed by string arithmetic on a canonical pair**.

      **`:multiplier` is load-bearing and `nil` does not mean 100** — mini contracts, index
      options and corporate-action adjustments all differ, and a caller computing notional
      without it is wrong by a factor. `:non_standard` and `:index_option` are flagged for
      the same reason: a caller treating either as an ordinary equity option is wrong about
      *what it holds*, not merely about its price.

      **Multi-leg makes `supports_multi_leg_orders` load-bearing rather than documentary.**
      `Types.OrderLeg` carries a `:ratio`, not a quantity, so a 1×2 spread cannot drift out
      of proportion. **A venue that cannot trade multi-leg must refuse, never decompose** —
      decomposition substitutes a different risk profile for the one asked for, and a caller
      with one leg filled holds naked risk it never chose. `:position_effect` is carried
      because buying can open a long or close a short and the venue prices them differently.
- [x] **2.2** ~~Staking (D4).~~ **Built in Core, 2026-08-31, from the vendor's own schemas
      rather than from the shape the plan sketched.** `has_staking` confirmed **absent** —
      the closed plan recorded it as shipped and it was not, so this was built rather than
      found.

      Six callbacks: `get_staking_rates/1`, `get_staking_balances/1`, `get_staking_rewards/1`,
      `get_staking_history/1`, `stake/3`, `unstake/3`, all registered peripheral. Flag
      `has_staking`, documented as **custodial staking only** — a venue that hands back an
      unsigned transaction is a different capability, and one venue publishes both (D4).

      Four types, each shaped by something the specification says and the sketch did not:

      **`StakingBalance` keeps three amounts apart.** A real Gemini response reads
      `balance: 10, available: 0, availableForWithdrawal: 10` — the whole position redeemable
      and **none of it tradable**. A single "available" would have a caller sizing an order
      against ten and placing it against zero. `by_provider` is carried rather than summed,
      because a redemption is addressed to a provider and a total gives no way to notice the
      wrong one.

      **`StakingRate` carries percentages only, both named.** Gemini publishes `rate` in
      **basis points**, `ratePct`, and `apyPct` — three numbers for one position differing by
      100× and by compounding. `bps_to_pct/1` lives in Core because it is the conversion most
      likely to be done inconsistently, and a rate wrong by 100× still looks like a rate.
      A venue publishing only one leaves the other `nil`: deriving an APY needs a compounding
      frequency the venue did not state.

      **`StakingReward` carries its period.** Rewards are aggregates over a window, so the
      same number is a good day or a poor quarter; `apy_pct` is the rate *at accrual*, which
      is what lets a reward be reconciled against the rate that produced it.

      **`StakingTransaction` carries the unbonding progression** — `amount`,
      `amount_paid_so_far`, `amount_remaining` — confirming the plan's claim that the
      constraint is observable rather than documentary. `settled?/1` returns **`nil` when the
      venue reports no progress**: unknown, explicitly not "complete". A caller reading a
      missing `amount_remaining` as finished would spend an asset still unbonding for days.
      `venue_type` keeps the venue's own string beside the normalised atom, because a
      normalisation that loses the original cannot be audited when it turns out to be wrong.
- [x] **2.3** ~~Money movement, write side (D2).~~ **Built 2026-08-31.** Three types
      (`DepositAddress`, `ApprovedAddress`, `Withdrawal`) and four callbacks
      (`get_deposit_address/3`, `list_approved_addresses/1`, `estimate_withdrawal_fee/4`,
      `withdraw/5`). **Withdrawal is the only operation in the contract that cannot be
      undone**, and every field is shaped by that.

      **The allow-list is expressed, as the task required.** `ApprovedAddress` carries
      `:status` *and* `:active_from`, because being on the list is not the same as being
      able to use it: venues impose a delay between approval and first use, the entire point
      being that an attacker who takes an account cannot add their own address and drain it.
      `usable?/2` returns **`nil` for a pending address with no stated activation** —
      unknown, not usable. Reading that as "usable now" would remove the protection the
      list exists to provide.

      **`memo_required` is tri-state, deliberately.** A deposit sent to a correct address
      *without* a required memo lands in the venue's omnibus wallet and is credited to
      nobody; recovery is manual where it is possible at all. `nil` means the venue did not
      say and **must not be defaulted to `false`** — "nobody said" and "not needed" are
      different facts and the cost of confusing them is the deposit.

      **`:network` is enforced on both address types.** The same asset lives on several
      chains with non-interchangeable addresses; a package defaulting the network would be
      choosing where a caller's funds go.

      **The fee estimate is a separate call and `Withdrawal.:fee` is what was *charged*.**
      Estimates and charges differ as network conditions move, and a caller reconciling
      against an estimate is short by the difference every time, in the same direction. No
      `:status` value means "arrived": `:completed` is the venue's opinion and is the
      strongest claim available.
- [x] **2.4** ~~Positions, distinct from balances.~~ **Built 2026-08-31 from Gemini's
      `OpenPosition` schema.** `Types.Position` + `get_positions/1`, registered peripheral.

      **`:side` is explicit and `:quantity` is always positive.** Venues disagree about how
      to say "short" — some a negative quantity, some a side field, some both. A package
      that guessed would produce a position that is **exactly backwards** while every number
      in it stayed plausible. A sign convention is a fact about one venue's JSON, not about
      the market, so it does not belong in the contract; `from_signed_quantity/1` converts
      once, in Core.

      **Realised and unrealised P&L are separate fields and are never summed here.** One has
      happened; the other is a mark-to-market opinion that changes with the next tick. A
      single `pnl` would invite a caller to book profit it does not have.

      **`:liquidation_price` of `nil` means the venue did not say, not that the position is
      safe** — on a leveraged book the most consequential unknown in the struct, and exactly
      the kind of absence §0 forbids reading as a value.
- [x] **2.5** ~~Portfolios.~~ **Built 2026-08-31, and the plan's framing was right: an
      addressing dimension, not a value.** `Types.Portfolio` is deliberately thin — enough
      to *name* one and choose between them — plus `list_portfolios/1`.

      **Addressing rides as an option (`portfolio: id`), not as a parameter on every
      callback.** This is the options surface D3 admits, and the alternative is worse:
      adding `portfolio` to forty-odd signatures would put a concept most venues do not
      have into every call on every venue.

      **"The account's BTC balance" is not a well-formed question on a venue with
      portfolios**, and a package answering it anyway has picked one and not said which.
      Where the option is omitted the package uses the venue's default and **must not invent
      one**; a caller needing determinism passes the id.

      `:type` keeps the venue's own word. Venues subdivide accounts for different reasons —
      margin isolation, strategy separation, client sub-accounts — and flattening those into
      one atom would erase the reason a caller was choosing between them.
- [x] **2.6** ~~Derivatives and funding.~~ **Built 2026-08-31 from Gemini's
      `FundingAmountResponse` and risk-stats schemas.** Two types, two callbacks
      (`get_funding/2`, `get_contract_stats/2`), both peripheral.

      **`Types.Funding` keeps the settled amount apart from the estimate.** The venue's own
      response carries `fundingAmount: -1.50991` beside `estimatedFundingAmount: -2.10595` —
      **40% apart**, which is how wrong a caller reading "the funding" would be. Same shape
      of distinction as realised vs unrealised P&L: one has happened, the other is an
      opinion that moves until it settles. **The sign is carried through unchanged** — it
      encodes which side pays, and normalising it would assert a convention the venue did
      not state.

      **`Types.ContractStats` carries mark and index as separate prices**, because they
      diverge and the divergence is the point: a venue marking away from the index is how a
      position gets liquidated at a price the market never printed. Neither is a traded
      price — that is `Quote`. **Three prices for one instrument, each meaning something
      different**, is precisely the situation where a single `price` field yields a
      confident wrong answer. Open interest is carried in contracts *and* notional, since
      neither substitutes for the other across differing contract sizes.
- [x] **2.7** ~~Convert / swap.~~ **Built 2026-08-31.** Coinbase's surface is literally
      quote-then-commit — `POST /convert/quote`, then `POST /convert/trade/{id}`, with
      `GET /convert/trade/{id}` for state. `Types.Conversion` plus three callbacks:
      `quote_conversion/4`, `commit_conversion/2`, `get_conversion/2`.

      **This is the facade's only two-step write, and the gap between the steps is the
      risk.** `:expires_at` is why the type exists: a caller committing an expired quote
      does not get the rate it was shown, and depending on venue gets an error **or a fill
      at the current rate** — the dangerous case, because it looks like success and every
      number in it is real. `expired?/2` returns **`nil` when the venue stated no expiry**
      — unknown, explicitly not "still valid".

      `:status` distinguishes `:quoted` from `:committed`/`:settled`, because **a quote is
      not a conversion that happened**; reporting one as complete would report an intention
      as a fact.
- [x] **2.8** ~~Streaming account channels.~~ **Done 2026-08-31 — and the vocabulary was
      short by three kinds, not just unused by the venues.** The task expected
      `streamable` to be able to say `[:quotes, :order_book, :orders, :fills, :balances]`,
      which Core could already express. Reading Gemini's AsyncAPI and Schwab's Streamer
      service list against `data_kind` showed three streamed channels with **no kind at
      all**:

      **`:top_of_book`** — `bookTicker` is a separate channel from `depth` on the same
      venue, and mapping it to `:order_book` would tell a consumer it had a book when it had
      one level. Kept apart for exactly the reason `Types.TopOfBook` is not
      `Types.OrderBook` (2.0).
      **`:positions`** — Gemini streams `positionsAccount`; `Types.Position` landed in 2.4.
      **`:candles`** — Schwab's `CHART_EQUITY` and `CHART_FUTURES` stream bars.

      The full mapping is recorded on `t:data_kind/0` so the next reader can check it rather
      than trust it. **Three channels are deliberately left without a kind**: Gemini's
      `settlementsAccount` and `contractStatus` (prediction-market lifecycle) and its
      `requestForQuote*` family. None has a facade home, and naming a kind the contract
      cannot deliver would be a claim rather than a capability — they go to 2.9.
- [x] **2.9** ~~Reference data, watchlists, admin.~~ **All of it is in scope. Built
      2026-08-31.** An earlier draft of this entry proposed four groups for skipping. **The
      reasoning was wrong at the root, not at the margin**, and the architect rejected it.

      **The error: classifying by whether something is "on the trading path".** That is the
      host's question. **These packages are interfaces to exchanges and do not trade.** The
      only question this contract asks is *does the venue provide it* — and if it does, the
      interface exposes it. "Issuer data, not venue data" and "running an account, not
      trading it" were both answers to a question this project does not ask.

      The same contamination was in `Venue.peripheral_endpoints/0` — mine *and* three
      pre-existing entries ("not the trading path", "affects P&L accuracy, not whether an
      order executes", "depth is unavailable, trading is not"). All rewritten on the axis
      the classification actually uses: **is it replaceable by another source, and can a
      package be complete without it** — the second usually because *a venue may not offer
      it at all*, which is a fact about the venue, not about what a caller does downstream.

      Thirteen callbacks and six types added: watchlists (5), financials, corporate events,
      filings, news, screeners, and account administration (3).

      **`FinancialStatement.:line_items` keeps the venue's own field names.** Statements
      differ by accounting standard, fiscal calendar and industry; a fixed schema would drop
      whatever did not fit, and a dropped line on a balance sheet is one that no longer
      balances. **Where this interface cannot carry a venue's structure faithfully it carries
      it verbatim.**

      **`CorporateEvent` has no `:date` field.** A dividend has an ex-date, a record date and
      a pay date, days or weeks apart, and which matters depends on the question. One `:date`
      would make every caller guess which it held. `:confirmed` is tri-state because an
      earnings date is often an estimate that moves.

      **`ScreenerResult` carries the venue's own list identifier and metrics, and this
      interface never merges or re-ranks across venues** — two venues' "top movers" answer
      different questions, and a combined list would have an ordering that means nothing
      built from rows that were each correct.

      **`Filing` points and never fetches.** Two of the nine were also reclassified rather
      than skipped: `/userPreference` is the **Streamer bootstrap** and belongs inside
      Phase 6 with no facade callback (D12 — a consumer must not learn that this venue's
      socket needs a REST call to find its URL), and Gemini's `list-accounts-in-group` is
      portfolio addressing already served by `list_portfolios/1`.
- [x] **2.10** ~~Review the twelve shapes that already have a home.~~ **Done 2026-08-31 —
      and the review found the same defect class in the shapes that were already there.**

      **`get_historical_prices/4` declared `[Types.Quote.t()]` and there was no candle type
      at all.** A bar is not a quote: a quote is one price at an instant, a bar is four
      prices and a volume over a span. Flattening one into the other either discards the
      open, high and low or keeps the close and calls it "the price".

      **The venues were not even doing that** — they returned **bare untyped maps** with
      their own key sets, so the declared return type was simply false and nothing compared
      one venue's candles to another's. A consumer switching venues got a different map and
      no error. `Types.Candle` added; the callback now declares it.

      **`:opened_at`, not `:timestamp`.** Venues disagree about whether a bar is stamped at
      its open or its close, and the difference is one whole interval — a daily series
      joined across the two conventions is misaligned by a day with every value correct,
      which is why nothing catches it. The field is named for what it holds.
      `coherent?/1` catches a malformed bar at the boundary, because a high below the close
      silently corrupts every range, breakout and volatility calculation built on it and
      none of them error.

      **`Types.Order` could not say which time-in-force an order used.**
      `Capabilities.supported_time_in_force` declares what a venue accepts, and the order
      type had no field for it — so a caller reading an order back could not tell an IOC
      that expired from a GTC still working. Added.

      **Two callbacks still return bare maps and are recorded rather than fixed**:
      `get_accounts/2` returns `[map()]` and `get_fees/2` returns `map()`. Same class of
      problem, and both need a venue survey to type honestly rather than a guess — an
      untyped map at the facade is a value that passes every check and means nothing. They
      are **not** left as "fine"; they are the first item of unfinished contract work.

      The remaining shapes — trade, fill, balance, order book, instruments, market hours,
      margin — were checked against the widened surface and need no change.
- [x] **2.11** ~~Core publishes.~~ **Pushed to `main` 2026-08-31 as `884a306` → `df71c92`,
      CI publishing 0.1.16.** Gate run first and clean: format, `credo --strict`, **dialyzer
      0 errors**, sobelow, 368 tests / 0 failures, coverage 93.1%.

      **Two packaging problems were caught before publishing, not after.** `mix.exs` ships
      `docs/guides`, and the raw Schwab portal capture had been sitting in it — **7.5 MB
      would have gone into the tarball**, against Core shipping no venue-specific anything.
      That file's own comment block records the last time something large went in unnoticed
      (a 4.4 MB PLT), which is why `mix hex.build` was inspected first. Moved to
      `docs/reference/schwab-portal-capture/`, which is not in `files:`; the tarball is
      **121 KB**.

      Second: the capture is 7.5 MB of **Schwab's own compiled JS and CSS**, duplicated
      across two page saves. **This repo is public and history is not retractable**, so the
      asset bundles are gitignored rather than committed — republishing a third party's
      compiled front-end permanently is not something to do by accident. The two HTML pages
      are kept, and the curated capture lives in `dp_exchange_schwab`.

### Phases 3–13 — the endpoints

**One box per endpoint.** Grouped by capability, because that is the order the phases run
in (D7) and the order Phase 2 decides shapes in — take a group, do it across every venue
that has it, and the shape gets proven rather than guessed.

`[x]` marks what is implemented today. Every `[ ]` is a `PLANNED` endpoint from §7's
register; nothing skipped appears here.

**Per endpoint, "done" means**: the call is made, the response is normalised into a `Core`
type (or the group's new shape from Phase 2), the maturity is declared, a test covers the
success path *and* the refusal, and the venue's `endpoint-inventory.md` row is marked.

**Two rules that apply to every box and are not repeated**: refuse rather than substitute —
no nearest-width, no local clock, no invented value (§0 of the closed plan) — and the
venue's own timestamp is the timestamp.

**This list covers the surface enumerated so far.** Phase 0 widens it to everything D7 puts
in scope, and the boxes it adds belong under these same headings.


#### Phase 3 — what the first endpoint taught

**`POST /api/v3/brokerage/orders` (Coinbase) is done**, and it turned out to be the phase's
most instructive endpoint rather than its most routine.

**Coinbase names the order type and the time-in-force in a single key**, and the set of
names is **sparse**. `order_configuration` is a one-key map: `limit_limit_gtc`,
`market_market_ioc`, `stop_limit_stop_limit_gtd`. The facade carries `:order_type` and
`:time_in_force` separately, so this is a cross-product — and there is **no
`limit_limit_ioc`, no `market_market_gtc`, no `stop_limit_stop_limit_ioc`**.

**A pair the venue does not name is an error, not the nearest key.** Sending `{:limit, :ioc}`
as `limit_limit_fok` would place an order that fills-or-kills where the caller asked for
immediate-or-cancel, with every field in the request looking correct. That is §0 with money
behind it, and it is asserted: one test uses a plug that **raises if called**, proving the
refusal happens before the request is sent rather than being read out of a response.

**Three other refusals came out of the same endpoint**, each a default that would have been
a different order: a limit without a price, a stop-limit without a stop price, and a market
order sized in neither base nor quote. **`post_only` is omitted rather than sent as `false`**
— silence is not a decision to take liquidity.

**A 200 is not a placed order.** The venue answers `success: false` in a 200 for a
rejection; reading the status code alone would report an order that does not exist.

`client_order_id` is the venue's **idempotency key** — re-sending one returns the original
order rather than placing a second — so a caller's own id is passed through, and a v4 UUID
is generated from the VM's CSPRNG when absent.


**A third and fourth false negative, found by implementing rather than by auditing.**
Coinbase's facade said *"this venue publishes no order-preview endpoint"* and *"this venue
has no atomic replace; a caller cancels and re-places"*, with `supports_order_preview` and
`supports_order_replace` both declared `false` on the strength of those claims. **It
publishes `/orders/preview` and `/orders/edit`.**

The replace one is the worse of the two. The moduledoc called `supports_order_replace: false`
*"a claim about **risk** rather than convenience"* — because cancel-then-replace opens a
window in which no order is live. The risk was real and the claim was wrong: **the package
was describing a hazard it was creating by not implementing the endpoint that avoids it.**

That is now three venues and four claims: Schwab's streaming, Schwab's order book, and
Coinbase's preview and replace. **Phase 14's negative-claim audit is the systematic version
of what implementing keeps finding by accident** — and finding them this way costs a venue's
whole capability surface being wrong in the meantime.
**This is the shape the rest of Phase 3 will take**: the work per endpoint is not the HTTP
call, it is finding which of the venue's combinations do not exist and refusing them.
#### Phase 3 · Orders (30) — 29 of 30; batch-place waits on a contract callback (OQ8)

- [x] `coinbase ` GET    /api/v3/brokerage/orders/historical/batch
- [x] `coinbase ` GET    /api/v3/brokerage/orders/historical/{order_id}
- [x] `coinbase ` POST   /api/v3/brokerage/orders
- [x] `coinbase ` POST   /api/v3/brokerage/orders/batch_cancel
- [x] `coinbase ` POST   /api/v3/brokerage/orders/close_position
- [x] `coinbase ` POST   /api/v3/brokerage/orders/edit
- [x] `coinbase ` POST   /api/v3/brokerage/orders/edit_preview
- [x] `coinbase ` POST   /api/v3/brokerage/orders/preview
- [x] `gemini   ` POST   /v1/heartbeat
- [x] `gemini   ` POST   /v1/instant/execute
- [x] `gemini   ` POST   /v1/instant/quote
- [x] `gemini   ` POST   /v1/mytrades
- [x] `gemini   ` POST   /v1/notionalvolume
- [x] `gemini   ` POST   /v1/order/cancel
- [x] `gemini   ` POST   /v1/order/cancel/all
- [x] `gemini   ` POST   /v1/order/cancel/session
- [x] `gemini   ` POST   /v1/order/new
- [x] `gemini   ` POST   /v1/order/status
- [x] `gemini   ` POST   /v1/orders
- [x] `gemini   ` POST   /v1/orders/history
- [x] `gemini   ` POST   /v1/tradevolume
- [x] `gemini   ` POST   /v1/wrap/GUSDUSD
- [x] `webull   ` GET    /trading/orders/get
- [x] `webull   ` GET    /trading/orders/historical-orders/list
- [x] `webull   ` GET    /trading/orders/open-orders/list
- [ ] `webull   ` POST   /trading/orders/batch-place — no batch callback in the contract (OQ8)
- [x] `webull   ` POST   /trading/orders/cancel
- [x] `webull   ` POST   /trading/orders/place
- [x] `webull   ` POST   /trading/orders/preview
- [x] `webull   ` POST   /trading/orders/replace

**Webull's preview and replace exclude crypto — and this package now serves more than
crypto.** Read from the vendor's own reference pages, 2026-09-01:

| endpoint | what the vendor says |
|---|---|
| `/trading/orders/preview` | "For crypto trading, this feature is currently not supported." |
| `/trading/orders/replace` | "Modifies equity, options and futures orders […] For crypto trading, this feature is currently not supported." |
| `/trading/orders/batch-place` | "A maximum of 50 orders can be submitted once, Currently only stocks are supported. This service is not currently available to all clients." |

**Preview and replace are implemented** (2026-09-01). Getting there meant widening the order
builder past crypto: the type/time-in-force matrix is now per instrument type —

    CRYPTO   MARKET/IOC, LIMIT/DAY|GTC, STOP_LOSS_LIMIT/DAY|GTC
    EQUITY   MARKET, LIMIT, STOP_LOSS, STOP_LOSS_LIMIT, TRAILING_STOP_LOSS × DAY|GTC
    OPTION   as EQUITY minus TRAILING_STOP_LOSS ("Options not supported")
    FUTURES  as OPTION
    EVENT    LIMIT only, and DAY|GTC|IOC|GTD|FOK

— and both endpoints refuse a crypto request before sending it, naming the venue's own
reason. `asset_classes` is now `[:crypto, :equity]`, `supported_instrument_types` names spot,
option, future and event contract, and the fake enforces the same matrix from the same source
rather than a hand-copied list that drifts.

**Two earlier revisions of this note were wrong, in the same way twice.** The first said
`preview_order/3` "has no endpoint at all" — false, and contradicted by the vendor. The second
ticked all three boxes as "nothing to implement at this package's declared asset class" —
which read a *current package declaration* as a *permanent scope*, and parked real work
behind an invented open question. See OQ9, closed.

`/trading/orders/batch-place` stays open on its own blocker, not an asset-class one: the
`Venue` behaviour has no batch-place callback, so there is no facade for it on any venue.
**OQ8**.

#### Phase 4 · Accounts and balances (4)

- [x] `coinbase ` GET    /api/v3/brokerage/accounts
- [x] `coinbase ` GET    /api/v3/brokerage/accounts/{account_uuid}
- [x] `webull   ` GET    /trading/accounts/list
- [x] `webull   ` GET    /trading/assets/balances/get

#### Phase 4 · Positions (1)

- [x] `webull   ` GET    /trading/assets/positions/list

#### Phase 5 · Fills and transactions (2)

- [x] `coinbase ` GET    /api/v3/brokerage/orders/historical/fills
- [x] `webull   ` GET    /trading/activities/cash-activities/list

#### Phase 6 · Streaming (2)

- [x] `webull   ` POST   /market-data/streaming/subscribe
- [x] `webull   ` POST   /market-data/streaming/unsubscribe

#### Phase 7 · Order book and depth (8) — **complete**

- [x] `coinbase ` GET    /api/v3/brokerage/best_bid_ask
- [x] `coinbase ` GET    /api/v3/brokerage/market/product_book
- [x] `coinbase ` GET    /api/v3/brokerage/product_book
- [x] `gemini   ` GET    /v1/book/BTCUSD
- [x] `webull   ` GET    /market-data/stocks/depths/list
- [x] `webull   ` GET    /market-data/stocks/footprints/list
- [x] `webull   ` GET    /market-data/stocks/noii-bars/list
- [x] `webull   ` GET    /market-data/stocks/noii-snapshots/list

#### Phase 7 · Public trades (4)

- [x] `coinbase ` GET    /api/v3/brokerage/market/products/{product_id}/ticker
- [x] `coinbase ` GET    /api/v3/brokerage/products/{product_id}/ticker
- [ ] `gemini   ` POST   /v1/trades/BTCUSD
- [ ] `webull   ` GET    /market-data/stocks/ticks/list

#### Phase 7 · Quotes (5)

- [x] `gemini   ` GET    /v1/pricefeed
- [ ] `gemini   ` GET    /v1/pubticker/BTCUSD
- [ ] `gemini   ` GET    /v2/fxrate/AUDUSD/1594651859000
- [x] `webull   ` GET    /market-data/crypto/snapshots/list
- [ ] `webull   ` GET    /market-data/stocks/snapshots/list

#### Phase 7 · Candles (6)

**The `Types.Candle` migration is only done on Schwab.** 2.10 built the type and moved
Schwab onto it, because Schwab was where the `price: close` defect was found. It did not
sweep the other venues, and the checklist above does not say so. Coinbase, Gemini and
Webull returned bare maps keyed on `:timestamp` — a name that does not say *which* end of
the interval it is, so a caller reading it as the close is off by exactly one interval in a
value that looks entirely reasonable. **Webull is migrated** (2026-09-01, with its order
lifecycle). Coinbase and Gemini are migrated as their boxes below are ticked; a venue's
candle box is not done until it returns `Types.Candle` with `:opened_at`.

- [x] `coinbase ` GET    /api/v3/brokerage/market/products/{product_id}/candles
- [ ] `coinbase ` GET    /api/v3/brokerage/products/{product_id}/candles
- [x] `gemini   ` GET    /v2/candles/BTCUSD/15m
- [ ] `gemini   ` GET    /v2/derivatives/candles/BTCGUSDPERP/1m
- [x] `webull   ` GET    /market-data/crypto/bars/list
- [ ] `webull   ` POST   /market-data/stocks/bars/list

#### Phase 8 · Instruments and search (11)

- [x] `coinbase ` GET    /api/v3/brokerage/market/products
- [ ] `coinbase ` GET    /api/v3/brokerage/market/products/{product_id}
- [ ] `coinbase ` GET    /api/v3/brokerage/products
- [ ] `coinbase ` GET    /api/v3/brokerage/products/{product_id}
- [ ] `gemini   ` GET    /v1/feepromos
- [x] `gemini   ` GET    /v1/symbols
- [ ] `gemini   ` GET    /v1/wrap/:symbol
- [ ] `gemini   ` GET    /v2/network/USDC
- [ ] `gemini   ` GET    /v2/networks/
- [x] `webull   ` GET    /trading/instruments/crypto/profiles/list
- [ ] `webull   ` GET    /trading/instruments/stocks/profiles/list

#### Phase 9 · Money movement (18)

- [ ] `coinbase ` GET    /api/v3/brokerage/payment_methods
- [ ] `coinbase ` GET    /api/v3/brokerage/payment_methods/{payment_method_id}
- [ ] `gemini   ` POST   /v1/account/transfer/btc
- [ ] `gemini   ` POST   /v1/addresses/bitcoin
- [ ] `gemini   ` POST   /v1/approvedAddresses/account/ethereum
- [ ] `gemini   ` POST   /v1/approvedAddresses/ethereum/remove
- [ ] `gemini   ` POST   /v1/approvedAddresses/ethereum/request
- [x] `gemini   ` POST   /v1/balances
- [ ] `gemini   ` POST   /v1/custodyaccountfees
- [ ] `gemini   ` POST   /v1/deposit/bitcoin/newAddress
- [ ] `gemini   ` POST   /v1/notionalbalances/usd
- [ ] `gemini   ` POST   /v1/payments/addbank
- [ ] `gemini   ` POST   /v1/payments/addbank/cad
- [ ] `gemini   ` POST   /v1/payments/methods
- [ ] `gemini   ` POST   /v1/transactions
- [ ] `gemini   ` POST   /v2/transfers
- [ ] `gemini   ` POST   /v2/withdraw/ethereum/eth
- [ ] `gemini   ` POST   /v2/withdraw/ethereum/eth/feeEstimate

#### Phase 10 · Staking — Gemini 6, Coinbase Prime 9 (15)

*Prime's paths read from the vendor's pages on 2026-08-31. **D4 said "Prime 13"; that was a
page count.** The thirteen pages document **nine** endpoints — four pairs are duplicate
pages for one path: `claim-wallet-staking-rewards-alpha` = `request-to-claim-rewards-for-a-staked-wallet`,
`request-to-stake-currency-in-a-portfolio` = `request-to-stake-currency-portfolio`,
`request-stake-or-delegate` = `request-to-stake-or-delegate-a-wallet`, and
`request-to-unstake-currency-across-a-portfolio` = `request-to-unstake-currency-portfolio`.
The same pages-are-not-endpoints trap that put Advanced Trade at 61 pages and 51 endpoints.*

*Prime splits every operation by scope: **portfolio-level** (3) acts across the portfolio,
**wallet-level** (6) acts on one wallet. `stake/3` must decide which it exposes — a
normalisation question for Phase 2, not an implementation detail.*

- [ ] `gemini   ` GET    /v1/staking/rates
- [ ] `gemini   ` POST   /v1/balances/staking
- [ ] `gemini   ` POST   /v1/staking/history
- [ ] `gemini   ` POST   /v1/staking/rewards
- [ ] `gemini   ` POST   /v1/staking/stake
- [ ] `gemini   ` POST   /v1/staking/unstake
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/staking/initiate
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/staking/unstake
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/staking/transaction-validators/query
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/wallets/{wid}/staking/initiate
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/wallets/{wid}/staking/unstake
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/preview
- [ ] `cb-prime ` GET    /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/status
- [ ] `cb-prime ` POST   /v1/portfolios/{pid}/wallets/{wid}/staking/claim_rewards
- [ ] `cb-prime ` GET    /v1/portfolios/{pid}/wallets/{wid}/staking/status
> **Not Coinbase's CDP Staking API.** Those 7 are on-chain: they take a wallet address and
> return **unsigned transactions to sign and broadcast**. Different capability — putting it
> behind `stake/3` would be the nearby-substitute failure at its most expensive (D4).

#### Phase 11 · Options (4)

- [ ] `webull   ` GET    /market-data/options/bars/list
- [ ] `webull   ` GET    /market-data/options/snapshots/list
- [ ] `webull   ` GET    /market-data/options/ticks/list
- [ ] `webull   ` GET    /trading/instruments/options/contracts/list

#### Phase 11 · Derivatives, futures and event contracts (34)

*Coinbase's six `intx/*` endpoints are **`APPROVED-SKIP` under D1** (deprecated) and are
deliberately absent below. They are listed in §8's skip register, not here — a skipped
endpoint must never appear as a work item.*

- [ ] `coinbase ` DELETE /api/v3/brokerage/cfm/sweeps
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/balance_summary
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/intraday/current_margin_window
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/intraday/margin_setting
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/positions
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/positions/{product_id}
- [ ] `coinbase ` GET    /api/v3/brokerage/cfm/sweeps
- [ ] `coinbase ` POST   /api/v3/brokerage/cfm/intraday/margin_setting
- [ ] `coinbase ` POST   /api/v3/brokerage/cfm/sweeps/schedule
- [ ] `gemini   ` GET    /v1/fundingamount/BTCGUSDPERP
- [ ] `gemini   ` GET    /v1/fundingamountreport/records.xlsx
- [ ] `gemini   ` GET    /v1/nextfundingtimestamp/BTCGUSDPERP
- [ ] `gemini   ` GET    /v1/perpetuals/fundingpaymentreport/records.xlsx
- [ ] `gemini   ` GET    /v1/riskstats/BTCGUSDPERP
- [ ] `gemini   ` POST   /v1/margin
- [ ] `gemini   ` POST   /v1/perpetuals/fundingPayment
- [ ] `gemini   ` POST   /v1/perpetuals/fundingpaymentreport/records.json
- [ ] `gemini   ` POST   /v1/positions
- [ ] `webull   ` GET    /market-data/event-contracts/bars/list
- [ ] `webull   ` GET    /market-data/event-contracts/depths/list
- [ ] `webull   ` GET    /market-data/event-contracts/snapshots/list
- [ ] `webull   ` GET    /market-data/event-contracts/ticks/list
- [ ] `webull   ` GET    /market-data/futures/bars/list
- [ ] `webull   ` GET    /market-data/futures/depths/list
- [ ] `webull   ` GET    /market-data/futures/footprints/list
- [ ] `webull   ` GET    /market-data/futures/snapshots/list
- [ ] `webull   ` GET    /market-data/futures/ticks/list
- [ ] `webull   ` GET    /trading/instruments/event-contracts/categories/list
- [ ] `webull   ` GET    /trading/instruments/event-contracts/events/list
- [ ] `webull   ` GET    /trading/instruments/event-contracts/markets/list
- [ ] `webull   ` GET    /trading/instruments/event-contracts/series/list
- [ ] `webull   ` GET    /trading/instruments/futures/contracts/list
- [ ] `webull   ` GET    /trading/instruments/futures/product-classes/list
- [ ] `webull   ` GET    /trading/instruments/futures/product-codes/list

#### Phase 11 · Margin (3)

- [ ] `gemini   ` POST   /v1/margin/account
- [ ] `gemini   ` POST   /v1/margin/order/preview
- [ ] `gemini   ` POST   /v1/margin/rates

#### Phase 11 · Clearing (8)

- [ ] `gemini   ` POST   /v1/clearing/broker/list
- [ ] `gemini   ` POST   /v1/clearing/broker/new
- [ ] `gemini   ` POST   /v1/clearing/cancel
- [ ] `gemini   ` POST   /v1/clearing/confirm
- [ ] `gemini   ` POST   /v1/clearing/list
- [ ] `gemini   ` POST   /v1/clearing/new
- [ ] `gemini   ` POST   /v1/clearing/status
- [ ] `gemini   ` POST   /v1/clearing/trades

#### Phase 11 · Convert (3)

- [ ] `coinbase ` GET    /api/v3/brokerage/convert/trade/{trade_id}
- [ ] `coinbase ` POST   /api/v3/brokerage/convert/quote
- [ ] `coinbase ` POST   /api/v3/brokerage/convert/trade/{trade_id}

#### Phase 11 · Portfolios (6)

- [ ] `coinbase ` DELETE /api/v3/brokerage/portfolios/{portfolio_uuid}
- [ ] `coinbase ` GET    /api/v3/brokerage/portfolios
- [ ] `coinbase ` GET    /api/v3/brokerage/portfolios/{portfolio_uuid}
- [ ] `coinbase ` POST   /api/v3/brokerage/portfolios
- [ ] `coinbase ` POST   /api/v3/brokerage/portfolios/move_funds
- [ ] `coinbase ` PUT    /api/v3/brokerage/portfolios/{portfolio_uuid}

#### Phase 11 · Fees (1)

- [ ] `coinbase ` GET    /api/v3/brokerage/transaction_summary

#### Phase 8 · Reference data (30)

- [ ] `webull   ` GET    /market-data/fundamentals/analysis/ratings/get
- [ ] `webull   ` GET    /market-data/fundamentals/analysis/target-prices/get
- [ ] `webull   ` GET    /market-data/fundamentals/balance-sheets/get
- [ ] `webull   ` GET    /market-data/fundamentals/capital-flows/get
- [ ] `webull   ` GET    /market-data/fundamentals/cash-flows/get
- [ ] `webull   ` GET    /market-data/fundamentals/company-profiles/get
- [ ] `webull   ` GET    /market-data/fundamentals/dividend-calendars/list
- [ ] `webull   ` GET    /market-data/fundamentals/earnings-calendars/list
- [ ] `webull   ` GET    /market-data/fundamentals/filings/list
- [ ] `webull   ` GET    /market-data/fundamentals/financial-alerts/get
- [ ] `webull   ` GET    /market-data/fundamentals/forecast-eps/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-allocations/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-brief/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-dividends/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-files/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-holdings/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-net-values/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-performances/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-ratings/get
- [ ] `webull   ` GET    /market-data/fundamentals/fund-splits/get
- [ ] `webull   ` GET    /market-data/fundamentals/income-statements/get
- [ ] `webull   ` GET    /market-data/fundamentals/indicators/get
- [ ] `webull   ` GET    /market-data/fundamentals/industry-comparisons/get
- [ ] `webull   ` GET    /market-data/screeners/gainers-losers/list
- [ ] `webull   ` GET    /market-data/screeners/high-dividend-ranks/list
- [ ] `webull   ` GET    /market-data/screeners/market-sectors/get
- [ ] `webull   ` GET    /market-data/screeners/market-sectors/list
- [ ] `webull   ` GET    /market-data/screeners/top-actives/list
- [ ] `webull   ` GET    /market-data/screeners/week52-high-low/list
- [ ] `webull   ` POST   /market-data/news/summaries/get

#### Phase 8 · Watchlists (8)

- [ ] `webull   ` GET    /market-data/watchlists/instruments/list
- [ ] `webull   ` GET    /market-data/watchlists/list
- [ ] `webull   ` POST   /market-data/watchlists/create
- [ ] `webull   ` POST   /market-data/watchlists/delete
- [ ] `webull   ` POST   /market-data/watchlists/instruments/add
- [ ] `webull   ` POST   /market-data/watchlists/instruments/remove
- [ ] `webull   ` POST   /market-data/watchlists/instruments/update
- [ ] `webull   ` POST   /market-data/watchlists/update

#### Phase 12 · Admin (7)

*Gemini's five are `rest-api/common/admin`, **paths read from the vendor's pages on
2026-08-31**, not inferred. Gemini's private API is uniformly `POST` with a signed
`{request, nonce}` payload, and each page states its own path in that `request` field.*

*`admin/subaccounts` is **a guide page, not an endpoint** — it documents the subaccount
model and cites `/v1/account/create`, `/v1/account/list` and `/v1/account/transfer/{currency}`,
which are counted elsewhere. That is why admin contributes five endpoints and six pages,
and it drops Gemini's in-scope total from 76 to **75**.*

- [ ] `coinbase ` GET    /api/v3/brokerage/key_permissions
- [ ] `coinbase ` GET    /api/v3/brokerage/time
- [x] `gemini   ` POST   /v1/account                  admin/get-account-detail
- [ ] `gemini   ` POST   /v1/account/create           admin/create-new-account
- [ ] `gemini   ` POST   /v1/account/rename           admin/rename-account
- [ ] `gemini   ` POST   /v1/account/list             admin/list-accounts-in-group
- [ ] `gemini   ` POST   /v1/roles                    admin/roles-endpoint

#### Phase 12 · Token lifecycle (5)

*Every path here was read from the vendor's own page on 2026-08-31.*

*Gemini's **`refresh-access-token` posts to the same URL as the host's
`authorization-token-request`** — `exchange.gemini.com/auth/token`, separated only by
`grant_type`. Webull's `/oauth2/tokens/create` is likewise **the second leg of Connect's
OAuth**: it exchanges the authorization code the host obtained, and refreshes thereafter.*

*Both cases make the same point. **The package/host split cannot be read off a path** — the
same URL serves both sides. §6.0 draws the line at credential *use*, which is why these
five are in scope while the consent redirects are not.*

- [ ] `webull   ` POST   /auth/tokens/check
- [ ] `webull   ` POST   /auth/tokens/create
- [ ] `gemini   ` POST   exchange.gemini.com/auth/token        oauth/refresh-access-token
- [ ] `gemini   ` POST   api.gemini.com/v1/oauth/revokeByToken oauth/revoke-access-token
- [ ] `webull   ` POST   /oauth2/tokens/create                 connect-api/create-and-refresh-token

#### Phase 13 · Robinhood — the whole v2 surface (9)

*Every box is open even though the package already ships `best_bid_ask` and
`trading_pairs` — **it ships them on v1**. D5 makes v2 the surface, so at v2 they are not
done; task 1.4 is the migration. Marking them complete here would hide the only work this
venue has.*

- [ ] `robinhood` GET    /api/v2/crypto/marketdata/best_bid_ask/
- [ ] `robinhood` GET    /api/v2/crypto/trading/estimated_price/
- [ ] `robinhood` GET    /api/v2/crypto/trading/accounts/
- [ ] `robinhood` GET    /api/v2/crypto/trading/holdings/
- [ ] `robinhood` GET    /api/v2/crypto/trading/orders/
- [ ] `robinhood` POST   /api/v2/crypto/trading/orders/
- [ ] `robinhood` GET    /api/v2/crypto/trading/orders/{order_id}/
- [ ] `robinhood` POST   /api/v2/crypto/trading/orders/{order_id}/cancel/
- [ ] `robinhood` GET    /api/v2/crypto/trading/trading_pairs/


#### Phase 13 · Schwab — REST (23)

*Listed in full, implemented and not, so this venue reads like every other. The eleven
open boxes are the gaps; the twelve closed ones are what ships today.*

- [x] `schwab   ` GET    /quotes
- [x] `schwab   ` GET    /pricehistory
- [x] `schwab   ` GET    /markets
- [x] `schwab   ` GET    /instruments
- [x] `schwab   ` GET    /accounts/accountNumbers
- [x] `schwab   ` GET    /accounts/{accountNumber}
- [x] `schwab   ` GET    /accounts/{accountNumber}/orders
- [x] `schwab   ` POST   /accounts/{accountNumber}/orders
- [x] `schwab   ` GET    /accounts/{accountNumber}/orders/{orderId}
- [x] `schwab   ` DELETE /accounts/{accountNumber}/orders/{orderId}
- [x] `schwab   ` PUT    /accounts/{accountNumber}/orders/{orderId}
- [x] `schwab   ` POST   /accounts/{accountNumber}/previewOrder
- [ ] `schwab   ` GET    /{symbol_id}/quotes
- [ ] `schwab   ` GET    /chains
- [ ] `schwab   ` GET    /expirationchain
- [ ] `schwab   ` GET    /movers/{symbol_id}
- [ ] `schwab   ` GET    /markets/{market_id}
- [ ] `schwab   ` GET    /instruments/{cusip_id}
- [ ] `schwab   ` GET    /accounts
- [ ] `schwab   ` GET    /orders
- [ ] `schwab   ` GET    /accounts/{accountNumber}/transactions
- [ ] `schwab   ` GET    /accounts/{accountNumber}/transactions/{transactionId}
- [ ] `schwab   ` GET    /userPreference

#### Phase 6 · Schwab — Streamer (17 boxes: 15 services, the 6 commands, the bootstrap)

- [ ] `schwab   ` bootstrap via `/userPreference` → `streamerInfo`, `streamerSocketUrl`
- [ ] `schwab   ` commands: LOGIN, LOGOUT, SUBS, UNSUBS, ADD, VIEW
- [ ] `schwab   ` LEVELONE_EQUITIES
- [ ] `schwab   ` LEVELONE_EQUITY
- [ ] `schwab   ` LEVELONE_OPTIONS
- [ ] `schwab   ` LEVELONE_FUTURES
- [ ] `schwab   ` LEVELONE_FUTURES_OPTIONS
- [ ] `schwab   ` LEVELONE_FOREX
- [ ] `schwab   ` NYSE_BOOK
- [ ] `schwab   ` NASDAQ_BOOK
- [ ] `schwab   ` OPTIONS_BOOK
- [ ] `schwab   ` CHART_EQUITY
- [ ] `schwab   ` CHART_FUTURES
- [ ] `schwab   ` SCREENER_EQUITY
- [ ] `schwab   ` SCREENER_OPTION
- [ ] `schwab   ` ACCT_ACTIVITY
- [ ] `schwab   ` ADMIN

#### Phase 6 · Gemini — WebSocket channels (22, 1 implemented)

*From the vendor's **AsyncAPI document** (`/specs/asyncapi/websocket.yaml`), fetched
2026-08-31 in Phase 0. This replaces the eleven families read off the `trading/websocket/streams`
**Stream Matrix**, which is a reading aid and not the surface: **ten of these never appear
in it** — the whole `requestForQuote` family, `connection`, the two `…Snapshot` channels,
and the four `…Fast` depth variants. Fourth time in this family a rendered summary was
mistaken for a specification.*

- [x] `gemini   ` bookTicker
- [ ] `gemini   ` connection
- [ ] `gemini   ` trade
- [ ] `gemini   ` contractStatus
- [ ] `gemini   ` depth
- [ ] `gemini   ` depthFast
- [ ] `gemini   ` depth5
- [ ] `gemini   ` depth5Fast
- [ ] `gemini   ` depth10
- [ ] `gemini   ` depth10Fast
- [ ] `gemini   ` depth20
- [ ] `gemini   ` depth20Fast
- [ ] `gemini   ` ordersAccount
- [ ] `gemini   ` ordersSession
- [ ] `gemini   ` balancesAccount
- [ ] `gemini   ` balancesAccountSnapshot
- [ ] `gemini   ` positionsAccount
- [ ] `gemini   ` positionsAccountSnapshot
- [ ] `gemini   ` settlementsAccount
- [ ] `gemini   ` requestForQuote
- [ ] `gemini   ` requestForQuoteAccount
- [ ] `gemini   ` requestForQuoteSession
### Phase 14 — Documentation

**The deliverable of this family is not the endpoints. It is a host being able to use them
without knowing which venue it is talking to.** That understanding lives entirely in
documentation, so when the surface changes this much, the documentation *is* the work — not
a tidy-up after it.

This phase is organised the way a host reads, from the outside in: the guides it follows to
integrate, then the per-package documents, then the docstrings, then the evidence base.

**Two things are deliberately *not* deferred here.**

1. **A false claim is a Phase 1 defect.** `mix.exs` saying Schwab "has no streaming API at
   all" is wrong *today* and is fixed in 1.1 — not left standing for twelve phases. Phase 14
   rewrites documentation that became *stale*; Phase 1 corrects documentation that is *false*.
2. **`@moduledoc`, `@doc` and `@spec` are part of every phase's Definition of Done**, per
   `CLAUDE.md`. Each capability group documents its own functions as it lands. This phase is
   the cross-cutting sweep over documents that only settle once the whole surface is known.

`doc/` is generated ExDoc output and gitignored — never hand-edited.

#### Phase 14 · The guides a host actually follows (9)

**Core ships four guides under `usage-rules/`; no venue package ships any.** That asymmetry
is fine for `adapter.md` — writing a venue package is Core's subject — and wrong for
everything a host needs to know that is *specific to a venue*.

**And there is no auth guide anywhere in the family.** Not in Core, not in any venue. The
whole of the host-facing credential story is three lines in `usage-rules.md`: *"Passed as
arguments, per call."* That was adequate when every package only signed a request. **This
plan breaks it**: Phase 12 adds Schwab's `Auth.refresh/2`, Gemini's `refresh-access-token`
and `revoke-access-token`, and Webull's `/oauth2/tokens/create`. The package now *holds a
session over time*, and a host cannot be told that in three lines.

- [ ] **`usage-rules/auth.md` — new, and the most important document this plan produces.**
      §6.0's split stated once, plainly: **storage is the host's, *use* is the package's**.
      What the host must implement (the consent leg, always — a browser and a person), what
      the package does (sign, refresh, rotate, revoke), and **what a host must do when a
      refresh fails**. Schwab's `OAuth Restart vs. Refresh Token` guide is the model: it
      enumerates precisely when refresh suffices and when the whole three-legged flow must
      restart. A host that does not know that distinction will silently lose a session
- [ ] **`usage-rules/auth.md` — per-venue table.** The five venues do not share an auth
      model: Schwab is three-legged OAuth with a one-time-use refresh token on a 7-day
      sliding window; Gemini is HMAC *and* an OAuth path whose refresh URL is shared with
      the host's own code exchange, separated only by `grant_type`; Coinbase is Ed25519;
      Webull has both an API-key flow and Connect's OAuth. **A host integrating two venues
      must implement two different things, and nothing currently tells it so**
- [ ] **`usage-rules/environments.md` — new.** How a host runs **live and demo at the same
      time**, which is a stated requirement and is not documented anywhere. Per-process
      resolution, not application config, so two supervision subtrees can differ
- [ ] **`usage-rules/money-movement.md` — new (D2).** The one group where a defect moves
      funds, and the one that can never be tested here (D7 tier 4). What the package
      guarantees, what it does not, and what a host must check before calling. **If this
      guide is not good enough to be trusted, the endpoints should not ship**
- [ ] `usage-rules/adapter.md` — the contract widened by D3's options surface and Phase 2's
      new callbacks
- [ ] `usage-rules/feeds.md` — rewritten around real sockets. Today its subject is largely
      `PollingFeed`; after Phase 6, four venues push
- [ ] `usage-rules/symbols.md` — re-checked against every new instrument surface
- [ ] `usage-rules/testing.md` — the fakes grow with the surface; state which tier each new
      capability can be verified at (D7)
- [ ] **Decide whether venue packages get their own `usage-rules/` set**, or whether
      venue-specific host guidance belongs in their flat `usage-rules.md`. Either is
      defensible; the current state — Core has four guides and the venues have none — was
      not decided, it just happened

#### Phase 14 · Packaging: a guide that does not ship is not documentation (3)

- [ ] **Verify the guides actually reach the consumer.** `mix.exs` ships `usage-rules`,
      `usage-rules.md`, `AGENTS.md` and `docs/guides`. That comment block already records
      one incident where `usage-rules.md` and the conformance suite silently did not ship
      while a 4.4 MB PLT did. **Inspect `mix hex.build` output before publishing**, per that
      comment — every new guide included, nothing new leaking
- [ ] **Core's `files:` ships `docs/guides`, which currently contains `schwab/`.** Venue
      documentation shipping from Core contradicts "Core ships no venue-specific anything".
      Either move it to `dp_exchange_schwab` or drop `docs/guides` from `files:`
- [ ] Confirm no venue package needs `usage-rules` added to its `files:` — **none of the
      five lists it today**, so any guide added to a venue would not ship unless this changes

#### Phase 14 · `usage-rules.md` per package (6)

*Ships inside the Hex tarball and is what a consuming agent reads. `CLAUDE.md`: "It is not
optional and it is not the README."*

- [ ] `core     ` the contract: new callbacks, new `Core.Types.*`, D3's options surface, and
      a **Credentials** section that is no longer three lines
- [ ] `coinbase ` new surface, custodial staking (D4), INTX absent by D1
- [ ] `gemini   ` new surface, the 22 socket channels, `rest-api/common` admin and OAuth, prediction markets
- [ ] `webull   ` new surface, corrected paths (D6), the Connect token lifecycle
- [ ] `robinhood` **v2 throughout** (D5) — every v1 path in the current document is wrong after 1.4
- [ ] `schwab   ` new surface, the Streamer's 15 services, transactions, `/userPreference`

#### Phase 14 · Capability declarations (6)

*`capabilities/0` is documentation a machine reads, and D15 makes it per-endpoint. A
consumer routes on it, which makes it the most consequential document in each package.*

- [ ] `core     ` `Core.Capabilities` — type and `@doc`, if Phase 2 widened the shape
- [ ] `coinbase ` restated per endpoint; `:experimental` unless a consumer has traded it live
- [ ] `gemini   ` same
- [ ] `webull   ` same
- [ ] `robinhood` same
- [ ] `schwab   ` same — **`streamable` gains `:order_book`, `:orders`, `:fills`** (§1.5)

#### Phase 14 · `README.md` (6)

- [ ] `core     ` what the contract now covers
- [ ] `coinbase ` capability table refreshed
- [ ] `gemini   ` capability table refreshed
- [ ] `webull   ` capability table refreshed
- [ ] `robinhood` capability table refreshed
- [ ] `schwab   ` **delete "There is no order book and no socket"** (`README.md:47`)

#### Phase 14 · Moduledocs carrying claims that go stale (6)

*`CLAUDE.md`: where a moduledoc explains **why** a guard exists, that explanation is the most
valuable thing in the file — carry it, do not compress it away.*

- [ ] `schwab   ` `DpExchange.Schwab:33` — "no order book and no socket. Neither specification
      describes depth". The specifications still do not; **the venue does**. Say which source was read
- [ ] `schwab   ` `Feed` — its premise changes entirely when polling becomes a socket
- [ ] `webull   ` `Rest:7,71,105,115,121` — every `/openapi/…` path and its measurement note (D6)
- [ ] `robinhood` `Rest:53,84` — v1 paths and any prose asserting v1 is the surface
- [ ] `gemini   ` `Private:94,118` — `/v1/account` **is** documented; `/v1/transfers` → `/v2/transfers`
- [ ] `coinbase ` `Coinbase:51,188` — "no atomic replace", "no endpoint" re-checked

#### Phase 14 · The negative-claim audit (6)

**A package must not assert that a venue lacks a capability without a recorded check against
primary documentation.** This is §0's rule pointed at documentation. "Schwab has no streaming
API" was a plausible negative nobody verified; it survived review and shaped `mix.exs`, three
moduledocs and a capability declaration. **An unverified negative is a substitution exactly
like an invented value.**

*Per package: enumerate every "there is no…", "does not support…" and `:unsupported`, and
record the source and date consulted — or delete the claim.*

- [ ] `core     ` audited
- [ ] `coinbase ` audited
- [ ] `gemini   ` audited
- [ ] `webull   ` audited
- [ ] `robinhood` audited — including "no streaming API", the one negative in the family that
      **survived** verification (§1.5); record how it was checked so it is not re-litigated
- [ ] `schwab   ` audited

#### Phase 14 · Agent instructions and changelogs (7)

- [ ] **`AGENTS.md` is inconsistent across the family, which is its own defect.** In `schwab`
      it is a byte-identical copy of `usage-rules.md`; in `core` and `gemini` it is a distinct,
      shorter file. Decide which it is — pointer or document — and make all six agree
- [ ] `core     ` `CHANGELOG.md`
- [ ] `coinbase ` `CHANGELOG.md`
- [ ] `gemini   ` `CHANGELOG.md`
- [ ] `webull   ` `CHANGELOG.md`
- [ ] `robinhood` `CHANGELOG.md` — **v1→v2 is breaking for any consumer pinning paths**
- [ ] `schwab   ` `CHANGELOG.md`

#### Phase 14 · Reference material stays current (7)

*The five inventories are the evidence base for every count in this plan. If they drift, the
next reader inherits the partial enumeration this plan spent its analysis correcting.*

- [ ] `coinbase ` `endpoint-inventory.md` — 0.2's endpoint counts replacing page counts
- [ ] `gemini   ` `endpoint-inventory.md` — REST and the socket matrix kept together
- [ ] `webull   ` `endpoint-inventory.md`
- [ ] `robinhood` `endpoint-inventory.md`
- [ ] `schwab   ` `coverage-matrix.md`, `endpoint-inventory.md`, `spec-facts.md`,
      `portal-product-landscape.md` — the last records that 23 of 24 products are unreachable
- [ ] Every inventory states **when** it was captured and **from what** (D13)
- [ ] `mix docs` regenerates cleanly in all six; no broken references

### Phase 15 — Close

- [ ] **15.1** **Coverage becomes a test, not a claim** (O4). A venue whose documented
      surface grows past what it declares should fail CI — the drift that produced this
      plan went unnoticed for a year.
- [ ] **15.2** All packages green and published; every `endpoint-inventory.md` current.
- [ ] **15.3** **The EXPERIMENTAL markers stay** (D15). Nothing in this plan can move an
      endpoint to `:proven`: that needs a consumer trading live, and for money movement it
      needs one moving real funds.
- [ ] **15.4** Retrospective appended (§12), then `git mv` this document to
      `docs/design/closed/` — **after** the retrospective, not before, and only with zero
      unchecked items. The last plan was closed twice because a recorded gap was mistaken
      for a completed task.

---

## 3. Objectives

The audit is **done**, not planned — see §1 and the five committed inventories. These
objectives start where the analysis ends.

- [x] **O1** — ~~Get a disposition for every unimplemented endpoint.~~ **Done.** D1–D8
      settle all of them: **254 skipped** with a recorded reason, everything else
      `PLANNED`. §7.
- [ ] **O2** — **Decide what crosses the facade, and in what shape**, before writing any
      of it. Twenty-seven capability groups; nineteen have a home, **eight need new design**.
      Phase 2.
- [ ] **O3** — **Implement the approved surface**, one capability group at a time across
      every venue that has it. Phases 3–13.
- [ ] **O4** — **Make coverage a test rather than a claim.** A venue whose documented
      surface grows past what it declares should fail CI, not drift for a year the way
      these five did. Phase 13.1.
- [ ] **O5** — **Stop using undocumented endpoints** (D6). Six paths, every one with a
      documented replacement. Phase 1.3.
- [ ] **O6** — **Close the streaming gap.** Core surface, not optional: four of five venues
      publish one and the packages use a fraction. Schwab uses **none of fifteen** while
      asserting the venue has none. Phase 6.
- [ ] **O7** — **Fix what is currently wrong**, before adding anything. Phase 1.
- [ ] **O8** — **Leave a host able to use what shipped.** The endpoints are not the
      deliverable; a host integrating two venues without knowing which is which is. That
      lives in documentation, and the plan currently ends with **no auth guide anywhere in
      the family** while adding token refresh, rotation and revocation across three venues.
      Phase 14.

## 4. Design Approach and Methodology

### 4.1 Normalise before implementing

The audit is behind us. Two stages remain, and the order is the argument.

**Normalise (Phase 2)** — decide what crosses the facade and in what shape. The closed
plan's sharpest finding was that **eleven of thirteen contract additions came from the one
venue built greenfield**, because it was the only one forced to ask the contract questions
the others had already answered by porting. This plan asks a far larger set of those
questions at once, and answering them in code first would produce five different shapes
for the same idea — which is precisely what a shared contract exists to prevent.

**Implement (Phases 3–13)** — one venue per phase, declaration before provider.

Core publishes its Phase 1 additions before any venue implements against them, as in the
extraction plan.

### 4.2 The normalisation problem, stated plainly

The current facade has 30 callbacks and was shaped by four crypto adapters plus one
equities broker. The surface this plan adds is **categorically wider**, and most of it has
no home:

| what venues offer | does the facade have a place? |
|---|---|
| order book / depth | **yes** — `get_order_book/2` |
| public trade history | **no** — `Types.Trade` exists, no callback returns a list of them |
| portfolios (multiple, per account) | **no** |
| positions (futures/perps) | **no** |
| convert / swap quotes | **no** |
| payment methods, deposits, withdrawals | **partly** — `get_transfers/2` reads, nothing writes. **D2: the write side is in scope** |
| staking | **no** — and the closed plan set a precondition this plan meets; see §4.3 |
| option chains and expirations | **no** — **D3: the facade grows one**, and it needs contract naming, chain shape, Greeks and multi-leg (§6) |
| market movers | **no** |
| fee tiers / volume tiers | **partly** — `get_fees/2` |
| streaming account events (orders, fills, balances) | **partly** — `streamable` names the kinds; no venue declares them |
| user preferences | **no** |
| batch and conditional orders | **no** — recorded as a Core gap at 7.5 |

**Not all of it should cross.** §6.0's rule stands: the facade is one fixed set, and a
capability one venue has does not automatically become a callback. Phase 3's job is to
decide, per group, between four outcomes — a new callback, an existing callback widened, a
capability flag with venue-specific data behind it, or **a proposed skip for the architect
to approve**.

### 4.3 Staking: the condition is met, and this plan should build it

Two drafts got this wrong in two different ways, and the corrections are worth keeping
because they are the same mistake twice.

**First**, this document wrote staking off as *"declared out by §6.0 of the closed plan."*
It was not. What the closed plan said (§6.0, OQ19):

> What ships now is the *declaration*: `has_staking` as a Kind-1 entry... The functions
> themselves (`get_staking_positions/2`, `stake/3`, `unstake/3`, `get_staking_rewards/2`)
> **wait for a deliberate Core release with more than one venue's implementation in hand**
> — and must carry the unbonding constraint the idea doc raises, since a 7–28 day lock is
> a fact a caller needs *before* staking, not after.

A deferral with a stated precondition, not a rejection.

**Second**, having accepted that, this document then argued the precondition was *not* met
— because Coinbase's Advanced Trade API has no staking endpoint, leaving Gemini as the only
in-scope implementation. **That was the product-scoping error of §1.3**: a conclusion about
a venue drawn from one of its twelve products.

**Coinbase does stake.** It publishes a dedicated Staking API:

| venue | staking endpoints | where |
|---|---|---|
| **gemini** | **6** | `/v1/staking/*` and `/v1/balances/staking` |
| **coinbase** | **7** | dedicated Staking API — build operation, latest operation, context, rewards, historical balances, list validators, get validator |
| coinbase (Prime) | 13 | stake, unstake, delegate, claim rewards, statuses, preview unstake |
| coinbase (Exchange) | 3 | stake-wraps for wrapped assets |

**Superseded by D4.** Reading both surfaces showed that "Coinbase stakes" was matching on
a word: its CDP Staking API is on-chain and returns unsigned transactions, a different
capability. The two custodial implementations are **Gemini and Coinbase Prime**. Staking is
`PLANNED`; see §6 D4 for the shape.

Three things it must carry, all from the closed plan:

1. **The unbonding constraint.** A 7–28 day lock is a fact a caller needs *before* staking.
   A facade shape that cannot express it is the wrong shape.
2. **`has_staking`, which was never actually shipped.** The closed plan says it does; it is
   absent from `Core.Capabilities` and from every venue declaration. That is a defect to
   fix regardless.
3. **No venue-specific escape hatch.** `Gemini.Provider.get_staking_balances/2` was
   deliberately dropped at extraction because a caller had to know it held Gemini to call
   it. Whatever ships here crosses the facade or does not ship.

**Nothing is left hanging on where Coinbase files it.** An earlier draft made staking
depend on whether Coinbase's Staking API counted as "in scope", since this package uses
Advanced Trade. That imported Coinbase's product packaging into a decision about what the
venue can do (§1.3). Coinbase stakes. Gemini stakes. That is two venues, which is what the
closed plan asked for, and **staking proceeds.**

### 4.4 What this plan will not do without asking

- **No new callback lands without §4.2's four-way decision written down.** A facade that
  grows one function per venue capability is the thing D12 exists to prevent.
- **No endpoint is dropped silently.** Every documented endpoint appears in §7 with a
  disposition, including the ones nobody wants.
- **No coverage number is asserted.** O6 makes it a test.

---

## 5. Phase structure

Sixteen phases. Their tasks are in **§2**, at the top where a checklist belongs, and every
capability group there carries its phase number in the heading. The shape:

| | phase | why here |
|---|---|---|
| **0** | finish the enumeration | D7 widened the scope; the inventories cover only the slice each package touched, and three counts are still open (0.2, 0.3, 0.5) |
| **1** | correctness | defects in shipped packages — Schwab's false "no streaming", undocumented paths, Robinhood still on v1 |
| **2** | **normalise** | every shape decided before any is written. Eight of the twenty-seven groups have no facade home yet |
| **3** | orders | first, because two venues cannot trade at all |
| **4** | accounts, balances, positions | what every consumer reads before it trades |
| **5** | fills and transactions | Schwab cannot report a fill today |
| **6** | streaming | the REST subscribe pair, Schwab's 15 Streamer services, Gemini's 22 socket channels |
| **7** | market data | order book, public trades, quotes, candles |
| **8** | instruments and reference | instruments, reference data, watchlists — the largest volume, the least difficulty |
| **9** | money movement | D2; the one group where a defect moves funds |
| **10** | staking | D4 — custodial only; CDP's on-chain 7 are not this |
| **11** | derivatives and adjacent | options, derivatives, margin, clearing, convert, portfolios, fees |
| **12** | admin and token lifecycle | §6.0's package side of credential *use* |
| **13** | venue surfaces documented whole | Robinhood v2 (D5), Schwab REST — kept intact rather than scattered across 3–12 |
| **14** | **documentation** | the deliverable is a host being able to use these without knowing which venue it is. That is documentation, and the surface only settles now |
| **15** | close | coverage becomes a test; retrospective; archive |

**Phase 13 is the one deliberate exception to capability grouping.** Robinhood's v2 and
Schwab's REST surface are each documented by their vendor as a single spec, and Schwab's is
the family's best-covered at 52%. Splitting 23 endpoints across seven capability phases
would scatter one venue's remaining work into fragments too small to verify. Every other
venue is grouped by capability, because that is the axis the facade is built on.

**Core publishes at the end of Phase 2**, before any venue implements against it — the
ordering the extraction plan used and its retrospective endorsed.
## 6. Decisions

Answered questions leave §10 and land here, with the reasoning, so the decision travels with
the plan rather than living in a chat message.

| | decision | answered |
|---|---|---|
| **D1** | **Deprecated vendor endpoints are not implemented.** | architect, 2026-08-31 (was OQ1) |
| **D2** | **Moving money is a function of this module. Whether to use it is the host's choice.** | architect, 2026-08-31 (was OQ3) |
| **D3** | **The facade grows an options surface.** | architect, 2026-08-31 (was OQ4) |
| **D4** | **Staking is custodial staking, and its shape is derived from the two surfaces that implement it.** | analysed, 2026-08-31 (withdrew OQ5) |
| **D5** | **v2 supersedes v1 where a real v2 exists — verified per venue, not assumed.** | analysed, 2026-08-31 (withdrew OQ6) |
| **D6** | **Undocumented endpoints are never used — least of all where a documented endpoint serves the same data.** | architect, 2026-08-31 (was OQ7) |
| **D7** | **These modules interface to what each exchange provides, so most of it is in scope. Out: Broker APIs and embedding.** | architect, 2026-08-31 (was OQ2) |

### D1 — deprecated endpoints are out

A surface the vendor is removing is not worth building against: it costs the same as a live
one, and the work is scheduled for deletion. It also has a second cost this family cares
about more — a package that implements a deprecated endpoint declares a capability that
will stop working, and the declaration is what a consumer routes on.

**What it removes:**

| venue | surface | count |
|---|---|---|
| coinbase | **INTX perpetuals** — the vendor marks the group deprecated | **6** |
| gemini | **archived WebSocket APIs** — `websocket/archived/{v1,v2,order-events,multi-market-data}` | **4 doc pages** |

**Gemini's archived sockets are worth a note**, because one of them is the API the host was
running on. `websocket/archived/v2` is the surface the closed plan found had vanished from
Gemini's documentation without a changelog entry. `dp_exchange_gemini` already speaks the
current `wss://ws.gemini.com` and says so in its moduledoc — so D1 confirms what the
package does rather than changing it.

**What it does not remove:** nothing else. Webull marks no endpoint deprecated, and
Coinbase's only other "legacy" page is an authentication guide rather than an endpoint.

**A standing consequence.** D1 is not a one-time filter. A vendor deprecating something we
have already built turns it into removal work, which is one more reason O4's coverage test
should read the vendor's documentation rather than a list checked in once.


### D2 — money movement crosses the facade

**The package provides the capability; the host decides whether to exercise it.** That is
the same split already settled for authentication (§0) and for collection policy in the
closed plan: *a venue declares what it can serve, a consumer decides what it will do.*
Withholding a capability the venue offers, on the grounds that using it would be
consequential, makes the package the arbiter of the consumer's business decisions — which
is not its job.

**What comes into scope:**

| venue | surface | count |
|---|---|---|
| **gemini** | **fund management** — deposits, withdrawals, new deposit addresses, approved addresses, internal transfers, bank links | **16** |
| coinbase | `payment_methods` (2), `portfolios/move_funds` (1) | **3** |
| coinbase (v2 App API) | deposits and withdrawals live here — in scope only if OQ2 rules the capability in | — |
| robinhood, schwab | none in the surfaces they publish | 0 |

Gemini's fund management is **the largest single group in the family**, which is a
reasonable place for it to have been overlooked and not a reasonable place to leave a gap.

**Three things this obliges.**

**`get_transfers/2` reads today and nothing writes.** The facade needs a write side, and
its shape is a Phase 1 normalisation question — one callback or several, and how an
approved-address allow-list is expressed, since two venues gate withdrawals behind one.

**Nothing here can ever be `:proven` from inside these repositories.** D7 tier 4 is
explicit: money-moving is *never a test*. It is answered in production by a consumer moving
real funds. Everything added under D2 lands `:experimental` and stays there — and the
conformance suite must not be given a fake that pretends otherwise.

**The refusals matter more here than anywhere else in the family.** A wrong candle is a bad
backtest; a wrong withdrawal address is gone. §0's rule — *return `:error`, raise, refuse,
never guess a value that looks right* — is load-bearing for this group specifically.

### D3 — the facade grows an options surface

**This reverses a position in the closed plan**, and the reversal should be visible. That
plan's §6.0 table recorded options as *"none. Needs strike/expiry/Greeks; a parallel
framework, not a facade slot"*. The architect has ruled the other way: options cross the
facade.

**What is in scope, from the vendors' own documentation:**

| venue | options surface |
|---|---|
| **schwab** | `/chains` (option chain), `/expirationchain`, option quotes via `/quotes`, option orders — the venue publishes an instruction matrix where `BUY_TO_OPEN`/`BUY_TO_CLOSE`/`SELL_TO_OPEN`/`SELL_TO_CLOSE` are option-only — plus streaming `LEVELONE_OPTIONS`, `OPTIONS_BOOK` and `SCREENER_OPTION` |
| **webull** | `/trading/instruments/options/contracts/list`, `/market-data/options/snapshots/list`, `/market-data/options/ticks/list`, `/market-data/options/bars/list`, and place / preview / replace / cancel option orders |
| coinbase | none in Advanced Trade. **39 Deribit pages** exist — Coinbase's acquired options venue — which is an OQ2 capability question, not an options one |
| gemini, robinhood | none |

**Four things the contract does not have and will need.**

**An option is not a symbol.** `Core`'s vocabulary is a string naming an instrument.
Schwab's option symbols are fixed-width and positional — `XYZ   240315C00500000`, six
characters of underlying padded with spaces, six of expiry, one of call/put, eight of
strike — and Webull's are its own. **`SymbolFormat` already refuses to construct them**
(`dp_exchange_schwab` says so explicitly: "constructing them is not this package's job").
Under D3 it becomes the package's job, and the facade needs a way to *name a contract*
rather than a ticker: underlying, expiry, strike, right.

**A chain is not a list of instruments.** `list_instruments/1` returns `Instrument` values
with `base`/`quote`/`symbol`. A chain is two-dimensional — expiries across strikes, calls
and puts — and flattening it into a list loses the shape a caller needs.

**Greeks and open interest have no home.** `Types.Quote` carries price, bid, ask, volume
and timestamp. An option quote without delta, gamma, theta, vega, implied volatility and
open interest is not usable for the thing options are used for.

**Multi-leg follows immediately.** Options are traded as spreads. Schwab's `TRIGGER`, `OCO`
and net-priced `NET_DEBIT` orders nest whole orders inside `childOrderStrategies`, and
`place_order/3` takes a flat request. **`supports_multi_leg_orders` is currently declared
`false` on every venue**, including Schwab, on the grounds that the contract cannot express
it — D3 makes that a thing to fix rather than a boundary to document.

**This is the largest single item in the plan**, and Phase 1 should treat it as its own
normalisation problem rather than a row in §4.2's table.

### D4 — staking is *custodial* staking, and the surfaces give the shape

OQ5 asked the architect to confirm a shape. That was the wrong question: **the shape is
determined by the surfaces**, and reading them answers it — including a substantive error
in this document's own earlier reasoning.

#### "Coinbase stakes" was matching on a word, not a capability

v1.5 said the closed plan's precondition was met because Gemini stakes and Coinbase stakes.
Reading both surfaces shows **three different things share that word**:

| model | venue | shape |
|---|---|---|
| **custodial exchange staking** | **gemini** (6), **coinbase Prime** (9) | `amount` + `currency`; the venue holds the asset; APY; an unbonding queue |
| **on-chain / self-custody staking** | coinbase **CDP Staking API** (7) | `network_id`, `asset_id`, `address_id`, `validator`, epochs — **returns unsigned transactions you sign and broadcast** |
| stake-wraps | coinbase Exchange (3) | wrapping an asset (cbETH), not staking |

**The CDP Staking API is not the same capability.** `POST /platform/v1/stake/build` takes a
wallet address and hands back an unsigned Ethereum transaction with gas, nonce and payload.
It needs a private key and a broadcast. Putting that behind `stake/3` alongside Gemini's
"stake 5 ETH from my exchange balance" would be **the nearby-substitute failure at its most
expensive**: a caller believing it had staked when it holds an unsigned transaction nobody
signed.

**Coinbase Prime is the same capability.** `POST /v1/portfolios/{id}/staking/initiate`
takes `currency_symbol` and `amount` — Gemini's `/v1/staking/stake` takes `currency`,
`amount` and `providerId`. Same operation, same arguments, different names.

**Prime is nine endpoints, not thirteen.** The count carried "13" until the pages were read
on 2026-08-31: thirteen documentation pages, four of them duplicate entries for a path
already documented under another name. **Nine endpoints, split by scope** — three act on a
portfolio, six on a single wallet, and `stake/3` has to choose which scope it exposes. That
is a Phase 2 normalisation question, and Gemini has no equivalent split to compare against.

So the closed plan's precondition **is** met — two custodial implementations — but by
Coinbase *Prime*, not by the CDP Staking API this document first pointed at. Whether Prime
is in scope is OQ2.

#### The shape, read off both surfaces

Field vocabulary common to Gemini's six and Prime's thirteen:

| facade | derived from |
|---|---|
| `get_staking_rates/2` → currency, APY, provider | Gemini `list-staking-rates` (`apy`, `currency`, `providerId`) |
| `get_staking_balances/2` → staked, available, available-for-withdrawal | Gemini `list-staking-balances` (`amount`, `available`, `availableForWithdrawal`) |
| `get_staking_rewards/3` → range-scoped rewards | Gemini `list-staking-rewards` (`since`, `until`, `apy`, `reward`) |
| `stake/3` → currency, amount, provider | Gemini `stake`, Prime `staking/initiate` |
| `unstake/3` → currency, amount | Gemini `unstake`, Prime `staking/unstake` |
| `get_staking_history/2` → events | Gemini `list-staking-event-history` (`eventType`, `timestamp`) |

**The unbonding constraint turns out to be observable, not just documentation.** The closed
plan required carrying "a 7–28 day lock" as a static fact. Gemini's unstake response
carries `amountRemaining`, `amountPaidSoFar` and `redeemed` — the queue's *progress*. So
`unstake/3` should return that state rather than a caller inferring it from a documented
duration, and `get_staking_balances/2` already separates `available` from
`availableForWithdrawal`, which is the same fact at rest.

That is better than the closed plan assumed and it is what the surfaces actually offer.

### D5 — v2 supersedes v1, verified rather than assumed

OQ6 asked which version to implement. **v2 supersedes v1** — that is the default and does
not need asking. What needs checking is whether a vendor's v2 is actually complete, because
a partial v2 silently loses an operation. So the check was run, and it changed the answer
on one of the two venues.

#### Robinhood — two real versions, and v2 is complete

Enumerated from the vendor's own documentation bundle:

| operation | v1 | v2 |
|---|---|---|
| `best_bid_ask` | `marketdata/` | `marketdata/` |
| `estimated_price` | `marketdata/` | **`trading/`** — moved |
| `accounts`, `holdings`, `trading_pairs` | ✓ | ✓ |
| orders: list, place, get one, cancel | ✓ | ✓ |

**Full parity. Implement v2.** Two details matter and both would break a naive migration:
`estimated_price` **changes namespace** between versions, so swapping `v1` for `v2` in a
path is wrong; and v2 adds **fee-tier order placement**, which v1 does not support.

*A false finding was nearly recorded here.* The get-single-order endpoint appeared missing
from v2 until it was found rendered as `orders/{order_id}/{query_params}` rather than
`orders/{order_id}/`. Checking the shape before reporting the gap is what stopped it.

#### Webull — one version. The second was never real

**Webull's documentation describes a single API version.** Searching the whole sitemap for
a version marker returns one hit, `get-form-version-list`, which is a Broker-API form
endpoint and unrelated.

This document has claimed since v1.2 that "Webull publishes a v2 order API duplicating part
of v1 under a second prefix." **That came from the SDK** — the source §1.2 rules out — which
carries `place_order_request_v2.py`, `replace_order_request_v2.py` and a `v2/` package, and
from which paths like `/openapi/v1/openapi/account/balance` were extracted. The doubled
segment should itself have been the tell.

**The vendor documents one version, so there is one.** The claim survived three drafts after
the rule that should have killed it, which is worth recording: banning a source does not

### D6 — undocumented endpoints are never used

An endpoint absent from the vendor's documentation is one the vendor has not committed to.
It can change or vanish without a changelog entry, and nothing will announce it — which is
exactly how Gemini's WebSocket API disappeared out from under the host. Using one where a
**documented endpoint serves the same data** is worse still: it takes the risk for nothing.

**Every one of these has a documented replacement, so nothing is lost and nothing needs
probing.** This resolves without a credential, which the earlier framing assumed it could
not.

| package calls | documented replacement |
|---|---|
| `webull` `/openapi/instrument/crypto/list` | `/trading/instruments/crypto/profiles/list` |
| `webull` `/openapi/market-data/crypto/bars` | `/market-data/crypto/bars/list` |
| `webull` `/openapi/market-data/crypto/snapshot` | `/market-data/crypto/snapshots/list` |
| `webull` `/openapi/market-data/streaming/subscribe` | `/market-data/streaming/subscribe` |
| `webull` `/openapi/market-data/streaming/unsubscribe` | `/market-data/streaming/unsubscribe` |
| `gemini` `/v1/transfers` | **`/v2/transfers`** — `list-past-transfers` |

#### It was six, not seven — and the seventh was this document's error

`gemini` `/v1/account` was listed as undocumented. **It is documented**, at
`rest-api/common/admin/get-account-detail`, and the path is `/v1/account` exactly as the
package calls it.

It looked undocumented because this analysis had enumerated only `trading/rest-api` and not
`rest-api/common` — **the product-scoping error of §1.3, producing a wrong claim for the
fourth time**. The pattern is consistent enough to be worth naming: *every* time a
conclusion here rested on a partial enumeration, it was wrong.

#### And `rest-api/common` is partly in scope, which adds endpoints

Enumerating it properly — 13 pages — turns up surface that belongs in this plan:

- **admin (6)** — `get-account-detail`, `create-new-account`, `rename-account`,
  `list-accounts-in-group`, `subaccounts`, `roles-endpoint`
- **oauth (4)** — split by §0: `refresh-access-token` and `revoke-access-token` are the
  package's; the two authorization endpoints are the host's

So Gemini's in-scope count rises from 68 to **75**, and one of the additions —
`get-account-detail` — is an endpoint the package already calls.

### D7 — the scope is what the exchange provides

**These packages exist to interface to what each exchange offers.** So the default is *in*,
and the exclusions are narrow and functional:

| out of scope | why | count |
|---|---|---|
| **Broker APIs** | operating a brokerage — account opening, KYC, ACH and wire funding, document upload, agreements, closure. A consumer of this family is a trader, not a broker-dealer | webull **140** |
| **Embedding** | putting a venue's buy flow inside someone else's app | robinhood Connect **10**, coinbase Onramp/Offramp **11** |
| FIX | pre-approved (§0) | gemini **79** |
| deprecated | D1 | coinbase INTX **6**, gemini archived sockets **4** |
| the consent leg of auth | pre-approved (§0) | **4** across two venues |

Everything else is in — including the surfaces this document had been treating as open
questions. **Coinbase Prime, Exchange, International, Derivatives, Deribit, Business,
smart contracts, addresses and the v2 App API are all in scope**, because they are things
Coinbase provides. So are Gemini's prediction markets, and Schwab's separate Crypto and
Thinkorswim products.

#### What that actually costs — now measured, not estimated

**Phase 0 replaced this table's estimates with counts.** Every figure below is an operation
count from the vendor's own specification or reference index, taken 2026-08-31.

| venue | in scope | implemented | source of the denominator |
|---|---|---|---|
| **coinbase** | **741** | 4 | 695 REST + 46 socket channels; 712 REST enumerated, −11 embedding (D7), −6 INTX (D1) |
| **gemini** | **128** | 12 | 75 REST + 31 prediction markets + 22 socket channels, from the published specs |
| **webull** | **86** | 5 | 85 Trading + Market Data, +1 Connect `create-and-refresh-token` |
| **schwab** | **40** | 12 | 23 REST + the Streamer's 15 services, 6 commands and bootstrap |
| **robinhood** | **9** | 2 | the v2 surface (D5); v1 is the same size and is superseded |
| **total** | **1,004** | **35** | |

**Coverage is 3.5%.** The earlier drafts said "1,000+ endpoints" and "roughly 3%" and
labelled both estimates. They were close, but they were guesses at a number that could be
counted — and the same guess put Deribit at 37 when it is 115. **The denominator is now
measured, so the coverage figure is a fact rather than an impression.**

Two of the five denominators moved substantially when measured. **Coinbase went from
"~795 pages" to 741 in-scope operations** — pages are not endpoints, and 258 of its 806
pages are index pages. **Gemini went from 76 to 128** once prediction markets and the real
socket surface were counted from the vendor's AsyncAPI rather than from a summary table.
#### Endpoint count is the volume. It is not the difficulty

Earlier drafts of this section treated 1,000+ endpoints as alarming and said it "breaks the
plan". **That measures the wrong thing.** This is a set of modules that give third-party
API and socket access a single shape a host can use. Once a shape is decided, applying it
to the next venue is the same work again — an HTTP call, a parse, a normalise into a `Core`
type, a capability declaration, a test.

**The design problem is the number of distinct shapes, and it is about twenty:**

| | | |
|---|---|---|
| 1 quotes / ticker | 8 positions | 15 margin |
| 2 candles / bars | 9 orders — place, cancel, replace, preview, get, list | 16 streaming |
| 3 order book / depth | 10 fills + transactions | 17 convert / swap |
| 4 public trades | 11 money movement | 18 reference data |
| 5 instruments / search | 12 staking | 19 watchlists |
| 6 market hours + calendar | 13 derivatives + funding | 20 admin / subaccounts |
| 7 accounts + balances | 14 options — chains, expiries, contracts | |

Roughly half of those already have a facade home. The genuinely new design work is
**options (D3), staking (D4), money movement's write side (D2), positions, portfolios,
derivatives funding, convert, and the streaming account channels** — eight shapes, and D3
and D4 are the only large ones.

**Everything after that is repetition**, and repetition is what the conformance suite and
the shared `Core` types exist to make cheap. Five venues × twenty shapes is not five
thousand decisions; it is twenty decisions applied a hundred times, and the hundred are
checkable by a test that already exists.

So phases are **one capability group at a time**, across every venue that has it — not
because the plan is too large for per-venue phases, but because the group is where the
thinking is, and doing a group once across five venues is how the shape gets proven rather
than guessed. It is also what stops five different shapes emerging for one idea, which §4.1
identifies as the real risk.

### D8 — these packages do not trade, and nothing is classified as if they did

**Added 2026-08-31, after the architect rejected four skip proposals whose reasoning was
wrong at the root.**

The proposals argued that fundamentals, news, screeners and account administration were
"not on the trading path", "issuer data rather than venue data", "running an account rather
than trading it". Every one of those answers a question **this project does not ask**.

**A host application trades. These packages are interfaces to exchanges.** Their job is to
present what a venue provides in one shape, so a consumer never learns which venue it is
talking to. Whether a consumer uses a given endpoint to trade, to reconcile, to audit or
never is the consumer's business, and is not visible from here.

So the scope test is one question: **does the venue provide it?** If it does, the interface
exposes it. D7 already said this — "the scope is what the exchange provides" — and the
skip proposals contradicted it while citing it.

**The same contamination was in the contract itself**, in `Venue.peripheral_endpoints/0`,
including three entries that predate this plan: *"not the trading path"*, *"affects P&L
accuracy, not whether an order executes"*, *"depth is unavailable, trading is not"*. All
rewritten on the axis that classification actually uses:

  * **replaceable** — another source answers the same question
  * **not load-bearing** — a package is complete without it, **usually because a venue may
    not offer it at all**, which is a fact about the venue and not about the caller

**Consequence for the rest of this plan:** nothing may be proposed for skipping on the
grounds that a host would not use it. The only admissible reasons are the ones §0 already
lists — the consent leg of auth, and FIX — plus deprecation (D1) and the two functional
exclusions in D7 (operating a brokerage, embedding someone else's buy flow), none of which
is an argument about trading.


## 7. Endpoint disposition register

**The enumeration is done and committed**, one file per venue, each listing every
documented endpoint with the implemented ones marked:

| venue | file | documented | implemented |
|---|---|---|---|
| coinbase | `docs/reference/coinbase/endpoint-inventory.md` + `endpoints-enumerated.tsv` | 712 REST + 46 sockets | 4 |
| gemini | `docs/reference/gemini/endpoint-inventory.md` + `operations-from-specs.txt` | 75 REST + 31 PM + 22 sockets | 12 |
| webull | `docs/reference/webull/endpoint-inventory.md` | 85 (+144 other products) | 5 |
| robinhood | `docs/reference/robinhood/endpoint-inventory.md` | 9 (+parallel v2) | 2 |
| schwab | `coverage-matrix.md` + `portal-product-landscape.md` + 17 user guides | 23 + Streamer | 12 |

**Those counts are the surface each package already touches, not the scope.** D7 puts
**1,004 operations** in scope across the five venues — measured in Phase 0, not estimated —
against 35 implemented, so **coverage is 3.5%**. Coinbase alone is **741**: 712 REST
operations enumerated from 806 reference pages, less embedding and the deprecated INTX set,
plus 46 socket channels. **Phase 0 is complete**; the per-venue inventories now carry the
full in-scope surface rather than the touched slice, and for Schwab the answer is that
nothing further is reachable at all (§7.1).

**Every endpoint now has a disposition.** D1–D8 settle them: **254 are skipped** for the
reasons below, and everything else is `PLANNED`.

| status | meaning |
|---|---|
| `PLANNED` | approved, scheduled in a phase — **the default** |
| `PROPOSED-SKIP` | **a request to the architect; never actioned without approval** |
| `APPROVED-SKIP` | signed off, with the reason recorded |
| `AUTH` | pre-approved: obtains a credential; the host's job |
| `FIX` | pre-approved: FIX protocol |

### 7.1 Skips — all approved

**All settled.** Every row below is approved or pre-approved; nothing here awaits an
answer. Everything not listed is
`PLANNED` — including **all token refresh, rotation, revocation and validity endpoints**,
which are credential *use* and belong in the package (§0).

| group | count | reason | status |
|---|---|---|---|
| **Coinbase INTX perpetuals** | 6 | vendor-marked deprecated | **`APPROVED-SKIP`** — D1 |
| **Gemini archived WebSocket APIs** | 4 | superseded by `wss://ws.gemini.com`, which the package already speaks | **`APPROVED-SKIP`** — D1 |
| **Webull `get-authorization-code` + `connect`** | 2 | the consent redirect — needs a browser and a person | pre-approved `AUTH` |
| **Gemini `authorization-request` + `authorization-token-request`** | 2 | same consent leg | pre-approved `AUTH` |
| **Webull Broker API** | 78 | **operating a brokerage** — account opening, KYC, ACH and wire funding, document upload, agreements | **`APPROVED-SKIP`** — D7 |
| **Webull Broker Market Data + FD Events + Custom** | 62 | same brokerage-operations job | **`APPROVED-SKIP`** — D7 |
| **Robinhood Connect** | 10 | **embedding** — a buy flow inside a third-party app | **`APPROVED-SKIP`** — D7 |
| **Coinbase Onramp / Offramp** | 11 | embedding a buy flow in a third-party app | **`APPROVED-SKIP`** — D7 |
| **Gemini FIX** | 79 | FIX protocol | pre-approved (§0) |

**Nothing else is proposed for skipping.** The remaining 208 include everything in §4.2's
"no facade home" list — option chains, movers, portfolios, converts, watchlists, screeners,
fundamentals, financial statements. **Those are normalisation problems, not skip
candidates**, and turning a hard normalisation question into a skip is the decision this
plan is not permitted to take alone.

#### 208 remaining, 286 boxes — why the two numbers differ

They count different things, and both are right. **208 is REST operations still to
implement.** **286 is checklist boxes in §2**, which also carries the streaming surfaces, Prime staking
and Robinhood's parallel v2 — none of which are REST operations and so none of which are
in the 243.

| venue | documented (§1.4) | §2 boxes | the difference |
|---|---|---|---|
| webull | 85 | 86 | +1 Connect `create-and-refresh-token`, outside the 85 |
| coinbase | 51 | 45 | −6 INTX (D1 skip) |
| coinbase Prime | — | 9 | custodial staking per D4 — Prime is not in the 51 |
| gemini | 75 | 97 | +22 WebSocket channels (AsyncAPI) |
| robinhood | 9 | 9 | v2 replaces v1 one-for-one (D5) |
| schwab | 23 | 40 | +17 Streamer services and commands |
| **total** | **243** | **286** | |

Implemented: **35** of the 243; **33** boxes are closed in §2. The two Robinhood endpoints
that ship on v1 are open at v2 by D5, which is the whole of that gap.

**Token lifecycle is `PLANNED`, not a skip.** Webull's `create-and-refresh-token`,
`/auth/tokens/create` and `/auth/tokens/check`, and Gemini's `refresh-access-token` and
`revoke-access-token`, are all credential *use* — the same category as Schwab's
`Auth.refresh/2`, which this family already ships. An earlier draft swept them into a
blanket "OAuth" skip, which would have left two venues unable to keep a session alive
while a third does it in-package.

**Staking is `PLANNED`, not a skip.** Gemini documents six and Coinbase Prime thirteen —
two custodial implementations, which meets the closed plan's condition. Coinbase's CDP
Staking API is **not** the same capability — it is on-chain and returns unsigned
transactions (D4).

### 7.2 One finding that still needs an answer
**Versioning is settled by D5.** Robinhood publishes two live versions and v2 is complete,
so v2 is what gets implemented — noting that `estimated_price` changes namespace between
them and that only v2 supports fee-tier orders. Webull publishes **one** version; the
second was an artefact of reading its SDK rather than its documentation.


**Seven implemented paths do not appear in their vendor's current documentation** —
Webull's five and Gemini's `/v1/account` and `/v1/transfers`. They were inherited from the
host adapter's reading of an older documentation site. **Whether they still resolve is
unknown**, and cannot be established here for want of a credential. This is the same shape
as Gemini's vanished WebSocket endpoint: working code pointing at documentation that moved,
with nothing watching. **OQ7.**

**OQ8 — the contract has no batch-place callback, and two venues document one.** Webull's
`/trading/orders/batch-place` takes up to 50 orders in a request (stocks only, and gated
per client); Gemini and Coinbase have their own multi-order surfaces. `place_order/3` in a
loop is *not* the same thing: a batch is one request the venue accepts or rejects as a
unit, and N requests is N partial outcomes a caller has to reconcile. Adding
`place_orders/3` to `Venue` is a contract change, so it is the architect's, not this
phase's. Recorded rather than decided; none of the three is reachable at those venues'
current crypto entitlements anyway, so nothing is blocked on the answer.


**OQ9 — CLOSED, 2026-09-01, and it should not have been opened.** The question was "when do
the venue packages widen past the asset class they declare today", and it was raised to hold
three Webull order boxes. **The architect's answer: that is not a question, it is the work.**
D7 already puts what the venue provides in scope and this checklist already enumerates
Webull's stock, options, futures and event-contract endpoints; raising an OQ over it was
skipping with extra steps.

The sequencing worry behind it was real but small, and answers itself: **implement, then
declare.** A package must not announce an asset class whose half does not work, so the
declaration follows the code rather than leading it. `dp_exchange_webull` now declares
`[:crypto, :equity]` because its order builder serves all five of the venue's instrument
types, not in anticipation of doing so; per-endpoint truth stays in `capabilities/0`'s
`endpoints` map, which is why that map exists.

Widening also found a real gap in Core: **the instrument-type vocabulary had no term for an
event contract**, so a package serving one had to declare something untrue. `:event_contract`
added — it is not an option and not a future, having no strike, nothing to deliver and a
step payoff rather than a curve.

## 8. Risk Assessment

**The facade bloats.** The real risk, and a design one rather than a delivery one. Twenty
capability groups pushed through one interface produces either a very large facade or a lot
of `:unsupported`. §4.2's four-way decision is the mitigation, and Phase 2 exists so each
shape is decided once rather than five times.

**Coverage becomes unverifiable again.** Mitigated by O4: a test, not a claim.

**Documentation that resists capture.** No venue is now known to be un-capturable — the
one that looked it was a rendered-page problem with an index behind it (§1.2). The
residual risk is a vendor publishing neither a specification nor an index — none of the
five. **The mitigation is not a fallback to a derived source**; it is to report the fact.

**Endpoints that cannot be tested.** Most of the new surface is authenticated, and three
of five venues have no anonymous endpoint and no sandbox. Everything added here lands
`:experimental` and stays there; nothing in this plan can move an endpoint to `:proven`.
That is D15 working, and it is worth stating up front so nobody expects otherwise.

**Volume, not novelty.** ~1,000 endpoints is a lot of typing and about **twenty distinct
normalisation shapes** (§6 D7). The risk is not the count; it is **five different shapes
emerging for one idea**, which is what doing a capability group across all five venues at
once is designed to prevent. Half the shapes already have a facade home; the genuinely new
design work is eight, of which options and staking are the only large ones.

---

## 9. Dependencies and Prerequisites

- **Architect sign-off on §7** before any implementation begins. This is the gate.
- **No architect assistance is needed for capture.** An earlier pass of this analysis
  three attempts at the wrong artefact, and the vendor's own `sitemap.xml` carries the
  whole surface (§1.2).
  three attempts at the wrong artefact; the SDK carries the whole surface (§1.2).
- Core publishes its Phase 3 additions before venues implement against them.
- No credentials are needed and none should be supplied: everything lands
  `:experimental` on documentation evidence, per D7 tier 1.

---

## 10. Outstanding Questions

**0 open.** All seven have been answered or withdrawn, and are recorded as D1–D8 in §6.
This document is ready to leave `Draft` once the architect accepts §6 and the phase
structure §5 now sets out.
OQ1, OQ3 and OQ4 are answered and have become **D1**, **D2** and **D3**. OQ5 was withdrawn:
it asked the architect for a shape the surfaces determine. **OQ6 likewise** — v2 supersedes
v1 by default, and whether it actually does is a thing to check, not to ask. Analysing both
gave **D4** and **D5** (§6).

---

## 11. Review and Iteration Notes

| Date | Change |
|---|---|
| 2026-08-31 | Draft written from analysis. Five open questions; §7 deliberately incomplete pending Phase 1. |
| 2026-08-31 | **v0.2 correction.** v0.1 claimed four venues had no documentation to audit against, and made Webull an architect dependency. Both wrong: all five publish public docs, and Webull's whole surface is declared in its official SDK. Coverage re-measured at ~24% overall. |
| 2026-08-31 | **v0.3 correction — the load-bearing one.** v0.2 advised preferring a vendor SDK over rendered docs. Backwards: Webull's SDK shows 29 endpoints against 103 in the vendor's index. Same category error as building from the host adapter. §1.2 now bans derived sources outright. All counts re-taken from vendor documentation indexes; coverage is **13%**, not 24%. |
| 2026-08-31 | **v1.0 — analysis done rather than planned.** v0.3 scheduled the capture and the coverage matrix as plan objectives; that is the analysis, not the plan. Both done and committed: five per-venue endpoint inventories. Doing the work corrected two asserted counts (webull 85 not 103, gemini 68 not 76) and surfaced two findings — seven live paths absent from vendor docs, and two venues publishing parallel API versions. Objectives now start at normalisation. |
| 2026-08-31 | **v1.1 staking correction.** v1.0 called staking "declared out"; the closed plan deferred it with a condition, which is not the same thing. Gemini's six endpoints are PLANNED. Found that Coinbase's Advanced Trade API has no staking endpoint at all, and that `has_staking` was never shipped despite the closed plan saying it was. |
| 2026-08-31 | **v1.2 — product scoping.** Every count had been taken from one API product per venue. All five vendors publish more; Coinbase has 15 products and 806 reference pages. Third instance of reporting a slice as the whole. Coinbase **does** stake — a dedicated Staking API of 7 endpoints — so the closed plan's staking precondition is met and staking is PLANNED. OQ2 restated as the question that sizes the plan. |
| 2026-08-31 | **v1.3 streaming.** WebSockets had been filed under "other products", implying out of scope. They are core facade surface, and only Robinhood lacks them. Found that the shipped Schwab package asserts the venue has no streaming API — false; it has a 15-service Streamer, documented in a file the repo already held. `get_order_book/2` is unsupported on false grounds and `/userPreference` is the streamer bootstrap. New objective O6. |
| 2026-08-31 | **v1.4 — Robinhood streaming verified.** The "no streaming" claim was inherited from the host adapter and repeated unchecked four times. Checked against the vendor: five doc pages, zero streaming keywords, no wss endpoint. Holds — but the provenance was the problem, not the conclusion. Web results claiming Robinhood has WebSockets describe third-party wrappers. |
| 2026-08-31 | **v1.5 — capability, not product.** Scope had been framed as "which API products are in scope", making staking depend on where Coinbase files it. A vendor's product split is its commercial packaging and says nothing about venue capability — and letting it drive scope leaks it through the facade (D12). Unit is now the capability. Staking proceeds unconditionally (Coinbase 7, Gemini 6). OQ2 restated functionally; proposed skips re-argued on what a capability is *for*. |
| 2026-08-31 | **v1.6 — auth skip narrowed to the consent leg.** "Webull Connect / OAuth" had been listed as a blanket skip, inconsistent with `dp_exchange_schwab`, which already refreshes tokens in-package. Refresh, rotation, revocation and validity checks are credential *use* and belong in the package; only the browser consent grant and its code exchange are the host's. Webull's and Gemini's token endpoints are now PLANNED. |
| 2026-08-31 | **v1.7 — D1–D4.** Architect answered OQ1, OQ3, OQ4. **OQ5 withdrawn** — it asked for a shape the surfaces determine. Analysing them found that "Coinbase stakes" matched on a word: its CDP Staking API is on-chain and returns unsigned transactions, a different capability from Gemini's custodial staking. The precondition holds via Coinbase **Prime**, whose `staking/initiate` matches Gemini's `stake` exactly. Unbonding is observable in the responses, not just documented. |
| 2026-08-31 | **v1.8 — D5, and OQ6 withdrawn.** v2 supersedes v1 by default; the real question is whether v2 is complete. Robinhood's is (with `estimated_price` changing namespace). **Webull has no v2** — the vendor documents one version, and the claim came from its SDK, which §1.2 had already ruled out three drafts earlier. |
| 2026-08-31 | **v1.9 — D6, and OQ7 closed.** Undocumented endpoints are never used. All six have documented replacements, so this needs no live probe. The seventh, gemini `/v1/account`, turned out to be documented in `rest-api/common` — the product-scoping error's fourth wrong claim. Enumerating that area adds 8 in-scope endpoints; total 243, implemented 34. |
| 2026-08-31 | **v2.0 — D7, all questions closed.** Scope is what the exchange provides; only Broker APIs and embedding are out. In-scope surface is **1,000+ endpoints**, coverage nearer **3%**. 254 skipped with reasons. Phase structure must become one capability group at a time — Coinbase alone exceeds the plan's original assumed size. |
| 2026-08-31 | **v2.1 — size reframed.** The document kept calling 1,000+ endpoints alarming. Wrong measure: this is one shape decided once and applied. Endpoints are volume; the difficulty is **~20 capability groups**, of which **8** need new design and only options and staking are large. Phases are one group at a time across all venues that have it. |
| 2026-08-31 | **v2.2 — checklist and retrospective written.** 14 phases, 65 tasks, by capability group. Correctness phase before new work. Status → In Review. |
| 2026-08-31 | **v2.3 — a real checklist.** v2.2's was a high-level overview, not followable. Replaced with **one box per endpoint** — 260 items generated from the captured inventories, grouped by capability, with 22 marked done. Prose tasks remain only for Phase 0 (enumeration), 1 (correctness), 2 (normalisation) and 13 (close). |
| 2026-08-31 | **v2.4 — checklist moved to §2.** It had been at §10 because the template put it fourth. **The template was wrong**; it is fixed, and `docs/design/README.md` now states the rule. Sections renumbered, cross-references updated. |
| 2026-08-31 | **v2.5 — consistency audit.** Fourteen internal contradictions found and fixed. **The serious one: all six Coinbase `intx/*` endpoints were `APPROVED-SKIP` under D1 and still sat in §2 as open work** — anyone following the checklist would have built a deprecated surface the architect had ruled out. Also: Robinhood's two boxes were ticked at v2 while the package ships v1 (D5 makes that the migration, so they are open); Schwab listed only its 11 gaps where every other venue lists its whole surface, so its 12 implemented endpoints were invisible; Gemini's 8 in-scope `rest-api/common` endpoints were counted in its 76 but had no boxes; the Prime staking rollup hid 12 unenumerated endpoints behind one prose line; 27 capability groups sat under a heading reading "Phases 3–12". Counts corrected: coinbase implemented 3→4, robinhood documented 8→9, total 243→244, implemented 34→35. Sections `3.1–3.4` and `5.1–5.2` were mislabelled under §4 and §7. **Two numbers were left disagreeing on purpose** — Coinbase's thirteen named surfaces sum to 667 against a stated 806, and six Gemini paths plus one Webull path carry `?` rather than a plausible guess. Tasks **0.5** added and **0.2** pointed at them. Reconciling those by choosing the better-looking figure would have been the §0 substitution this plan exists to prevent. |
| 2026-08-31 | **v2.6 — the three deferrals were done instead.** v2.5 closed with three gaps *recorded* rather than *resolved* — Coinbase's 139-page discrepancy, six Gemini paths written as `?`, and an unsourced "1 of 10" for Gemini's sockets — each filed as a Phase 0 task. **That is deferral dressed as analysis**, and the documentation was public the whole time. All three were read: (1) **Coinbase's 806 reconciles exactly across 22 segments**, and the shortfall was **Deribit, understated four-fold at 37 when it is 157** — Coinbase renders it as twelve *sibling* trees (`trading`, `market-data`, `block-rfq`, …) with no `deribit` in their paths, each verified against `adv-starbase-openapi.json`. (2) **Gemini's five admin and four oauth paths read from the vendor's pages**; `admin/subaccounts` is a **guide, not an endpoint**, dropping Gemini from 76 to **75**, and `refresh-access-token` shares a URL with the host's `authorization-token-request`, separated only by `grant_type` — which is why §6.0 splits at credential *use* and not at the endpoint. (3) **Gemini's Stream Matrix gives 11 families across 16 subscription names**, not 10; `indexPrice` and `contractStatus` were missing entirely. Totals: documented **243**, implemented **35**, boxes **275**. A fourth deferral fell with them: **Prime staking's rolled-up box** — 13 pages, but **9 endpoints**, four pairs being duplicate pages for one path, each operation existing at both portfolio and wallet scope. D4's "Prime 13" was a page count. Tasks 0.5 and 0.6 close; 0.2 narrows to methods-and-paths. **New lesson, same shape as §1.3:** counting a venue by URL prefix fails exactly as counting it by product page does — the vendor's information architecture is not the venue's capability model. |
| 2026-08-31 | **v2.7 — Schwab portal captured completely, and 0.3's premise was wrong.** Driven through the signed-in portal. **The "23 other products" were never a pending enumeration.** The catalogue holds 24, but **7 are visible to this account and 1 is entitled** — `lob-access/Status` returns `204` for the other six, and a spec URL under any of them redirects to `/home` before a specification request fires (verified on Advisor Services and Trader API - Commercial). **Crypto and Thinkorswim are real catalogue entries but are not among the seven at all.** The account holder is an individual client, not a broker or RIA, so no credential this project will ever hold reaches them: 0.3 is *retired*, not deferred. **What was genuinely missed is the portal's 17 User Guides** — they hang off `/user-guides` rather than any product and appear in neither OpenAPI document, so a product-shaped capture could not see them. Two carry design weight: `Authenticate with OAuth`, and `OAuth Restart vs. Refresh Token`, which is **the document that draws this venue's package/host auth boundary** (refresh in-package; every restart condition needs a browser and a person) and is derivable from no specification. Both Trader API specs were re-fetched and **diffed against the committed copies — endpoint paths identical**, so that capture was already complete and current. Schwab's reference set goes from 18 files to 46. **The `api-specification` envelope ships the account's live `appKey`/`appSecret`; both were redacted before staging and the whole repo re-scanned.** New lesson: the first capture was organised around API products, so it found everything shaped like an API product and nothing shaped otherwise — **the same slice-for-the-whole error as §1.3, this time with the portal's own navigation as the slice**. |
| 2026-08-31 | **v2.8 — a documentation phase, because there wasn't one.** The plan went from Phase 13 straight to Close, as if rewriting every package's consumer documentation were a tidy-up. It is not: **this plan changes what each venue *is*,** and a host only ever meets that through documentation. New **Phase 14 — Documentation** (Close → 15), 56 boxes, plus objective **O8** and a retrospective question. Three gaps found while writing it, none of which the earlier draft would have caught: (1) **there is no auth guide anywhere in the family** — the entire host-facing credential story is three lines, *"Passed as arguments, per call"*, which was adequate while packages only signed requests and is broken by Phase 12 adding refresh, rotation and revocation across three venues with **three different auth models**; (2) **only Core ships a `usage-rules/` guide set — no venue package has one, and none lists `usage-rules` in `mix.exs`'s `files:`**, so a venue guide written today would not reach a consumer; (3) **Core's `files:` ships `docs/guides`, which currently contains `schwab/`** — venue documentation shipping from Core, against "Core ships no venue-specific anything". Also added the **negative-claim audit**: a package must not assert a venue *lacks* a capability without a recorded check against primary documentation. "Schwab has no streaming API" was a plausible negative nobody verified; it survived review and shaped `mix.exs`, three moduledocs and a capability declaration. **An unverified negative is a substitution exactly like an invented value** — the §0 rule, pointed at prose. |
| 2026-08-31 | **v2.9 — Phase 0 complete. The scope is measured: 1,004 operations, 3.5% covered.** Coinbase: all **806** reference pages fetched and each page's own `pageMetadata.openapi` read — **712 REST operations**, with the 258 pages lacking that field identified as index pages rather than assumed away. Two products publish specs and were counted from them (`cde-spec.json` 49, Deribit's `adv-starbase-openapi.json` **115** against the 37 the draft carried). Plus **46 socket channels** from two AsyncAPI documents. **The method's check is that it returns exactly 51 for Advanced Trade, the one product previously counted by hand.** Gemini: **the vendor publishes machine-readable specs** at `/specs/` — REST **75** (agreeing exactly with the 68+7 hand count), prediction markets **31**, and **22 WebSocket channels against the 11 families** read off the Stream Matrix a day earlier. The AsyncAPI omissions are not marginal: the whole `requestForQuote` family, `connection`, both `…Snapshot` channels and four `…Fast` depth variants. The REST spec also settles D6 independently — **`/v2/transfers` is in the contract and `/v1/transfers` is not.** Evidence committed: `coinbase/endpoints-enumerated.tsv` (718 lines) and `gemini/operations-from-specs.txt`. §2's Gemini socket section goes 11 → 22 boxes (286 total). **Recurring lesson, now with a name: a rendered summary table is a slice of a specification.** Every venue that publishes a spec should be counted from the spec — checked, and only Gemini and Coinbase do. |
| 2026-08-31 | **v3.0 — Phase 1 done bar one item, and it found a defect nobody planned for.** 1.1, 1.2, 1.3, 1.5 complete; 1.4 half. **The unplanned find: Robinhood used an ask as a trade price.** `quoted_price/1` read `price \|\| ask_inclusive_of_buy_spread`, so a response with no traded price produced a quote whose `price` was a *resting order* — §0's substitution exactly, every value real and the meaning wrong, worst when the book is thin. **The suite asserted it as intended behaviour**, in a test named *"the price is the ASK when the venue sends no separate price"*; six fixtures supplied an ask and no price and expected a quote. Fixed, tests inverted, fixtures given a traded price inside the spread and equal to neither side. **A test can encode a defect as firmly as code can** — which is the strongest argument yet for Phase 14's negative-claim audit. **1.3 also disproved its own premise**: D6 said "no probe needed: every one has a documented replacement", true of paths and false of payloads — Webull's snapshots changed timestamp keys, bars renamed `symbol`→`symbols` and added a required `real_time_required`, instruments made `category` required and became paginated. A path-only rewrite would have compiled, passed, and been wrong three ways; **no test asserted any path**, so nothing would have caught it. **1.4 is deliberately half done**: `trading_pairs` moved to v2; `get_price/3` did not, because v2's `best_bid_ask` returns top of book only — a bid and an ask are resting orders and `price` is what traded, and v2 carries neither a traded price nor a timestamp, both `Quote` `@enforce_keys`. Raised as **2.0**: representing top-of-book is a contract question, and the architect's ruling that a real-time BBO is stamped at call time needs `Quote`'s `:timestamp` to stop documenting itself as "the venue's own" first. All five suites green (1,062 tests), credo clean, formatted, coverage 96%/91% on the two most-changed. |
| 2026-08-31 | **v3.1 — Phase 2 under way, and 2.0 turned out to be a contract defect rather than a Robinhood one.** The architect's correction: **`Core.Types.Quote` itself carried `:bid` and `:ask`, and all five venue packages filled them.** Order-book data on a trade type — which is why one package could read `price \|\| ask` and still look consistent with the type it was filling. **`Quote` loses `:bid`/`:ask`** and is trade data only; **`Types.TopOfBook`** is new, with no `price` field and no way to add one, optional sizes (`nil` = not published, never zero), `venue_time` (the venue's, or `nil`) and a required **`observed_at`** — which honours the ruling that a real-time BBO is stamped at the call without touching `Quote`'s guarantee that `:timestamp` is the venue's own. `mid/1`, `spread/1`, `crossed?/1` are functions, not fields. **Conformance assertion 14** added. **2.2 staking**: `has_staking` confirmed *absent* despite the closed plan recording it as shipped; six callbacks and four types built **from the vendors' published schemas** — `StakingBalance` keeps three liquidity states apart (a real response has the whole position redeemable and none of it tradable), `StakingRate` carries percentages only because one venue publishes bps *and* two percentages for the same position, and `StakingTransaction` carries the unbonding progression with **`settled?/1` returning `nil` for "unknown", never "complete"**. **2.4 positions**: explicit `:side` with always-positive `:quantity`, realised and unrealised P&L never summed, `:liquidation_price` of `nil` meaning *unsaid*. Core: 341 tests, 0 failures, credo clean, coverage 92.6%. **2.0a is blocked by design**: the venues build against published Core 0.1.13, so wiring them to `TopOfBook` cannot happen until **2.11 publishes Core** — a first attempt failed to compile and was reverted, which is the plan's own ordering proving itself. |
| 2026-08-31 | **v3.2 — Phase 2 at 8 of 13. The `Venue` behaviour goes 32 callbacks → 50.** 2.3 money movement, 2.5 portfolios, 2.6 derivatives, 2.7 convert and 2.8 streaming kinds all built, each from the vendors' published schemas rather than from a sketch. The recurring shape across all five: **a field whose absence must not be read as a value.** `ApprovedAddress.usable?/2` returns `nil` for a pending address with no stated activation — venues delay first use so a stolen account cannot add an address and drain it, and reading `nil` as "usable" removes exactly that protection. `DepositAddress.memo_required` is **tri-state**, because a deposit missing a required memo is credited to nobody and "nobody said" is not "not needed". `Conversion.expired?/2` returns `nil` with no stated window, because committing an expired quote can fill at the *current* rate — which looks like success. `Position.:liquidation_price` of `nil` means unsaid, not safe. `StakingTransaction.settled?/1` returns `nil` rather than "complete". **Five types, five refusals to guess, all of the same defect this plan opened with.** 2.6 also found the venue publishing `fundingAmount` and `estimatedFundingAmount` **40% apart** — settled and estimated kept as separate fields for the same reason realised and unrealised P&L are. 2.8 found `data_kind` short by three: `:top_of_book`, `:candles`, `:positions`, all streamed by a venue in the family and none nameable before now. Core: 352 tests, 0 failures, credo clean, coverage 92.8%. **Remaining in Phase 2: 2.1 (options, the largest), 2.9, 2.10, then 2.11 publishes — which needs the architect, and gates 2.0a and every venue phase after it.** |
| 2026-08-31 | **v3.3 — Phase 2 finished to the limit of what does not need the architect. 10 of 13; the `Venue` behaviour is 53 callbacks, up from 32.** **2.1 options**: the chain row split three ways — identity, book, model output — because Schwab returns bid, ask, last, mark *and* theoretical value on one row, which is five plausible prices and no help choosing. `OptionChain` stays two-dimensional; a one-sided strike keeps `nil` rather than vanishing. Multi-leg makes `supports_multi_leg_orders` load-bearing: **a venue that cannot must refuse, never decompose**, because a caller left holding one filled leg has naked risk it never chose. **2.10 found the same defect class already in the shipped contract**: `get_historical_prices/4` declared `[Quote.t()]`, there was no candle type at all, and **the venues were returning bare untyped maps** — so the declared type was false *and* nothing compared one venue's candles to another's. `Types.Candle` added, with its time field named **`:opened_at`** because venues disagree about open- versus close-stamping and a series joined across both is misaligned by a whole interval with every value correct. `Order` gained `:time_in_force`, which `Capabilities` had been declaring support for against a type that could not record it. **Two callbacks still return bare maps** — `get_accounts/2` and `get_fees/2` — recorded as the first item of unfinished contract work rather than waved through. Core: 368 tests, 0 failures, credo clean, 92.9%. **What is left needs the architect, not more work:** 2.11 publishes Core (a merge to `main`, which gates 2.0a and every venue phase), and 2.9 carries four skip proposals plus one open question — none defaulted, per §0. |
| 2026-08-31 | **v3.4 — Phase 2 complete and Core published. 66 callbacks, 30 types, up from 32 and 6.** **The architect rejected the four skip proposals, and the reasoning was wrong at the root rather than at the margin.** They argued "not on the trading path", "issuer data rather than venue data", "running an account rather than trading it" — every one an answer to **a question this project does not ask**. A host trades; **these packages are interfaces to exchanges**, and the scope test is only *does the venue provide it*. D7 already said so and the proposals contradicted it while citing it. Recorded as **D8**, with the consequence stated: nothing may be proposed for skipping because a host would not use it. **The same contamination was inside the contract** — `peripheral_endpoints/0` classified on trading relevance in several entries, *three of which predate this plan*. All rewritten on the axis the classification actually uses: replaceable by another source, or a package is complete without it — usually because **a venue may not offer it at all**, a fact about the venue rather than the caller. 2.9 built in full: 13 callbacks and 6 types for watchlists, financials, corporate events, filings, news, screeners and account administration. `FinancialStatement` keeps the venue's own line-item names, because a fixed schema drops whatever does not fit and a dropped line on a balance sheet is one that no longer balances. `CorporateEvent` has **no `:date` field** — a dividend's ex-, record- and pay-dates are days apart and one field would make every caller guess which it held. **2.11 published**, and two packaging problems were caught first: `mix.exs` ships `docs/guides`, where the raw Schwab capture would have put **7.5 MB into the tarball** (now 121 KB), and that capture is Schwab's own compiled JS and CSS — **gitignored rather than committed, because this repo is public and history is not retractable**. |
| 2026-08-31 | **v3.5 — Phase 2 complete, all five venues migrated to Core 0.1.16.** 2.0a moved every venue's bid/ask off `Quote` and onto `get_top_of_book/2`, and **found the same defect twice more while doing it**. Phase 1 had caught Robinhood reading `price \|\| ask`; the migration surfaced **Gemini's socket** (`price: message["c"] \|\| bid`, defended in a comment as better than inventing a value) and **Webull's socket** (`price: bid \|\| ask`, defended as *"a real quoted number, labelled as the bid too"*). **Three venues, three independent instances, each with a comment explaining why it was acceptable** — which is the argument for a type that cannot hold the wrong value. Book frames on both venues now deliver `TopOfBook`; where Gemini's also carries a last trade it delivers that separately as a `Quote`. **The fakes carried it too**: Robinhood's set `price: ask` citing "as the real adapter uses", reproducing the defect the adapter had — a suite agreeing with itself and wrong twice. Every fake's spread now straddles the traded price and equals neither side. **Schwab's candles were 2.10's finding in the wild**: `get_historical_prices/4` built Quotes with `price: close`, discarding open, high and low where no caller could see it; now `Types.Candle`, and the validation order changed so an undated bar still reports `:missing_venue_timestamp` rather than a shape error about a different problem. Suites: core 368, schwab 249, gemini 329, webull 223, coinbase 161, robinhood 114 — **1,444 tests, 0 failures**, credo clean and formatted across all six. |
| 2026-08-31 | **v3.6 — all six published. Core 0.1.16, gemini 0.1.3, coinbase 0.1.4, webull 0.1.3, robinhood 0.1.3, schwab 0.1.4.** The first push of the five venues **failed CI in all five**, and the reason is worth recording because it is a gap in how this work was being verified, not in the work: **the local gate was `mix test`; CI's is `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer` and `mix test --cover`.** Three distinct classes got through. **Warnings-as-errors** caught Gemini's fake missing all 33 new behaviour callbacks, and two clause-grouping problems my edits introduced. **Coverage** caught the 33 stubs per package being uncovered lines — webull fell to 85%, robinhood to 83%, schwab to 87%. The fix earns its place beyond the number: the facade already swept its declared-`:unsupported` endpoints, the **fakes had no such sweep**, and a fake that answered differently from the real module would let a consumer write a passing test against behaviour the package does not have. **Dialyzer** caught the sharpest one: Coinbase's `get_top_of_book/2` passed `HttpClient`'s raw `%{status:, body:, headers:}` where the decoded body was expected, so the `"trades"` pattern in its timestamp helper **could never match** — it would have compiled, passed the suite, and returned `nil` for every venue timestamp, because the helper's fallback clause catches anything. **No test could have seen it and dialyzer was the one gate not run locally.** `mix quality` exists precisely to run all four; using it, rather than `mix test`, is the lesson. |
| 2026-09-01 | **v3.7 — Webull's order lifecycle, and a Phase 2 claim corrected.** `cancel_order/3`, `get_order/3` and `get_orders/2` built: 5 of Webull's 8 order boxes now ticked. **The venue's order API is keyed on the client order id, not the venue's** — both cancel and get take `client_order_id` — so `place_order/3`'s return was corrected; it had been handing back an `order_id` that round-trips nowhere. Open and historical orders are two endpoints, not one with a filter, and a caller who does not say gets the open ones. **v3.5's "all five venues migrated" was too strong**: 2.10 built `Types.Candle` and moved *Schwab* onto it, and nothing swept the rest — Coinbase, Gemini and Webull were still returning bare maps keyed on `:timestamp`. Webull is now on `Types.Candle`/`:opened_at`; Coinbase and Gemini are recorded against their Phase 7 boxes. The fake had never been tested directly, which is how it was returning a shape the contract does not name: 299 tests (was 242), coverage 91.38%. |
| 2026-09-01 | **v3.8 — Phase 3 complete, 30 of 30, and the contract grew by six callbacks.** Coinbase's `close_position` and `edit_preview`; Gemini's two bulk cancels, order history, the Instant quote/execute pair, `/v1/wrap/{symbol}` and `/v1/tradevolume`; Webull's last three answered from the vendor's own words. **Six endpoints needed a facade that did not exist**, and each is a capability no combination of existing calls reproduces: `preview_replace/4` (the venue prices an amendment against the resting order, including what has already filled), `close_position/3` (only the venue flattens to exactly zero; a caller's arithmetic leaves a residue), `cancel_all_orders/2` (N cancels is N partial outcomes and cannot reach an order that appeared mid-loop), `convert/4` (one step, no rate held — *not* a shorthand for quote-then-commit, because the difference is who carries the price risk), and `get_trade_volume/2` (the venue's aggregation is what its fee tiers come from). `cancel_all_orders/2` takes a **required** `:scope` with no default: the account scope reaches orders a person entered at the venue's own web interface. **Two more false negatives found**, bringing the total to five: Webull's "`preview_order/3` has no endpoint at all" (it has one; it excludes crypto) and Gemini's identical claim (it publishes a *margin impact* preview, which answers a different question and is Phase 11's). **The `Types.Candle` sweep is now done** — Coinbase was still building `Quote`s with `price: close`, the exact 2.10 defect, with its fake reproducing it. Core 0.1.19–0.1.22 published; all five venues on 0.1.22, all suites green. |

---

## 12. Retrospective

*Written at Phase 15.4, not before. Empty is the correct state until the work is done —
these headings are the questions to answer.*

**Outcome.** What shipped, measured rather than asserted: coverage before and after, per
venue, with the denominator each number was taken against.

**Was "twenty shapes, not a thousand endpoints" right?** This plan is built on the claim
that the difficulty is the capability groups and the endpoints are volume. Say whether that
held — and if some group turned out to be five problems wearing one name, say which.

**What the analysis got wrong before the work started.** This document was corrected seven
times during its own drafting, and every correction had the same shape: **a slice reported
as the whole** — the host adapter, then the SDK, then one product per venue, then one
document per venue. Record whether that pattern continued into implementation, and what
caught it if so.

**What the contract missed, again.** Every Core addition made after Phase 2 froze the
shapes is a gap the normalisation did not anticipate. That list is the honest measure of
how good Phase 2 was, exactly as the closed plan's equivalent was for its Phase 3.

**Which venue taught the most.** The closed plan found that **eleven of thirteen** contract
additions came from the one venue built greenfield, because it was the only one forced to
ask questions the others had answered by porting. Say whether a similar concentration
appeared here, and what it was about that venue.

**What D7 cost and what it bought.** Scope went from one product per venue to everything the
venue provides. Say whether the wide scope paid, and where it did not.


**Did the documentation actually land a host?** This plan added a documentation phase after
the checklist had already been written, because the first draft treated a host's integration
guides as a footnote to the endpoints. The test is not whether the files were updated. It is
whether a host could integrate a second venue using only `usage-rules/`, and whether
`auth.md` — which did not exist when this plan started — was enough to keep a session alive
without reading the venue's own documentation. Say which guide a reader still had to go
around.

**The money-movement group specifically.** It is the only group where a defect moves funds
and the only one that can never be tested here. Record what was done instead of testing,
and whether it was enough.

**Feeds the idea docs.** Anything about noticing vendor API change goes to
`docs/design/ideas/detecting-vendor-api-change.md` — which already carries the finding that
a changelog diff caught nothing across five venues, and now has a second sample.
---


**Last Updated**: 2026-09-01 (v3.8 — **Implementing.** Phase 3 complete, 30 of 30; the Venue contract is 71 callbacks. Earlier: v3.0 — **Implementing.** Phase 1 corrected Schwab's false streaming claims, migrated Webull's five undocumented paths and Gemini's transfers, added deprecation guards — and found Robinhood using an ask as a trade price, asserted as correct by its own tests.)
**Next Review**: architect review of §7 (dispositions) and §8 (OQ1–OQ9).
