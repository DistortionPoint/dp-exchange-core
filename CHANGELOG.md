# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific
version needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version — pin three-part (`~> 0.1.0`). Coverage is uneven by design: fakes and
live public endpoints are well covered, order placement and authenticated flows are
not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
which venue, what was run against it, and when. "Marked proven" with no evidence is not
an acceptable changelog line.

## [Unreleased]

### Added

- **`get_fx_rate/3` and `Types.FxRate`.** Gemini publishes `GET /v2/fxrate/{pair}/{ts}` and
  the family had no shape for it.

  **It is not a rate the venue trades at.** Gemini's own documentation says it *"does not
  offer foreign exchange services"* and that the endpoint is *"for historical reference
  only"*; the number comes from a third party the venue names. So `:source` and `:benchmark`
  are carried alongside the rate, and `:provider` — the venue relaying it — is a **separate
  field**. Collapsing them would make a Gemini-relayed BCB rate indistinguishable from one
  Gemini computed itself, and only the second would be the venue's own claim. **Two venues
  relaying the same pair at the same instant can legitimately disagree**, and a caller
  reconciling them needs to know it is comparing sources rather than finding a bug.

  `:as_of` is the instant asked for, echoed by the venue. A rate without it is a number with
  no time attached, which is not a rate.


- **`get_trades/2` — the public tape.** `Types.Trade` already existed and nothing could
  return it; two venues publish the tape and the family had no callback for it.

  **It is not `get_trade_history/2`**, which returns the credential's own fills. The tape is
  everyone's executions and has no order of yours behind it — answering one with the other
  hands a caller a filtered view of the market and calls it the market.

- **`Types.Trade` gains `:broken`, defaulting to `false`.** Exchanges bust erroneous prints,
  and **a broken trade did not stand**: its price is not a price the market traded at.
  Leaving one in a series puts a phantom high or low into every range, breakout and
  volatility figure built on it, and none of them will error. `get_trades/2` excludes them
  unless `opts[:include_broken]` says otherwise — hiding them entirely would conceal that
  the exchange made a correction.

  The moduledoc now also records what `:side` means: venues report **the taker's** side, so
  Gemini's `buy` means an ask was removed by an incoming buy order. A package mapping that
  to "the maker was selling" inverts every entry while every number stays real.

- **`get_auction_imbalance/2` and `get_volume_profile/3`, with `Types.AuctionImbalance` and
  `Types.VolumeProfile`.** Two equity-microstructure capabilities Webull publishes that the
  family had no facade or shape for.

  **An auction imbalance is not a quote or a book.** During an auction the continuous book
  stops being the price; what matters is how much can be matched, how much cannot, and
  where it would clear — three numbers a `Quote` has nowhere to put. A caller reading a
  continuous quote at 15:59 is reading a book that is not where the close will happen.
  `opts[:auction]` is required, because the opening and closing auctions are different
  auctions with different windows.

  **The imbalance side is carried as the venue sent it, unmapped.** Venues publish the
  direction as a code and the tables differ — Webull documents `imbalance_side` with the
  example `"2"` and does not say what 2 means. Guessing it backwards tells a caller there
  is unmatched buying when there is selling: wrong, entirely plausible, and at the one
  moment of the day with the most volume behind it.

  **A volume profile is not a candle with extra fields.** A candle's single volume number
  cannot say that of 1,000 shares 600 lifted the ask and 400 hit the bid, nor at which
  prices each happened, and neither type is derivable from the other. `:delta` is the
  venue's own figure and is **not** recomputed from the totals: a venue that classifies
  some prints as neither aggressive buy nor sell reports numbers that do not reconcile, and
  that gap is information about its classifier rather than a fault to paper over.

  **`get_auction_imbalance/2` returns a list**, newest first, because the venue publishes a
  *series*: the imbalance updates every few seconds through the auction window, and how it
  moved is the point. `opts[:history]` selects the published series where a venue serves
  the snapshot and the series separately — the same shape `get_orders/2` uses for resting
  versus closed orders. **A series entry may carry less than a snapshot**: Webull's NOII
  bars publish the three prices and the time and *not* the quantities or the side, which
  come back `nil` — the venue did not publish them there, rather than the imbalance being
  zero.


- **`:event_contract` in the instrument-type vocabulary.** Webull lists event contracts as a
  tradable instrument type and the vocabulary had no term for one, so a package serving them
  had to declare something untrue.

  **It is not an option and not a future.** There is no strike, no underlying to deliver,
  and the payoff is a step at 0 or 1 rather than a curve — declaring one as `:option` would
  hand a caller a Greeks-shaped hole where the instrument has no Greeks.

- **`convert/4` and `get_trade_volume/2` on `Venue`.** Two more Gemini endpoints with no
  facade.

  **`convert/4` is not a shorthand for `quote_conversion/4` plus `commit_conversion/2`,
  and the difference is who carries the price risk.** The two-step form shows a rate and
  holds it: the caller sees the number before anything moves. `convert/4` executes at
  whatever the venue's price is on arrival and the caller learns the rate from the result.
  A package cannot manufacture the first from the second — quoting a rate it computed
  itself and calling it held would be a promise the venue never made — so a venue declares
  each independently. Gemini's `/v1/wrap/{symbol}` is the one-step form.

  **`get_trade_volume/2` is the account's own volume, not the market's**, and not
  `get_trade_history/2` summed. The venue's aggregation is what its fee tiers are computed
  from; reproducing it means every fill over the reporting window — one request per symbol
  on a venue that requires one — and the result would still be this package's arithmetic
  rather than the venue's ledger. Where they disagree, the venue's decides what a caller
  is charged.

- **`cancel_all_orders/2` on `Venue`.** Gemini publishes two bulk cancels and the family had
  no facade for either.

  **`opts[:scope]` is required and has no default.** `:session` cancels what this
  credential's session opened; `:account` cancels everything the account has open,
  including orders placed by another key or by a person at the venue's own web interface.
  A default would make the wider, destructive reading the answer to a question nobody
  asked, and the narrower one would silently leave orders running. The caller states it.

  It is not `get_orders/2` plus `cancel_order/3` in a loop: that is N requests with N
  partial outcomes and cannot reach an order that appeared between the listing and the
  cancels.

  Returns `%{cancelled: [id], rejected: [id]}`. **A non-empty `rejected` is not a failed
  call** — the venue answered and some orders were already gone.

- **`preview_replace/4` and `close_position/3` on `Venue`.** Both are Coinbase endpoints
  the family had no facade for, and both are the kind that cannot be assembled from the
  calls that already exist.

  **`preview_replace/4` is not `preview_order/3` with an order id.** The venue prices an
  amendment against the resting order's own state, including whatever of it has already
  filled. A caller who asks what a fresh order would cost is asking a different question
  and getting a different number. Without it the choice is committing to an irreversible
  amendment blind, or cancel-then-place — which reopens the window `replace_order/4`
  exists to close.

  **`close_position/3` is not `get_positions/1` plus `place_order/3`.** The size a caller
  computes is the size as of the caller's last read; the venue's is the size now. On a
  position that moved in between, the caller's arithmetic leaves a residue or overshoots
  into a position the other way. Only the venue flattens to exactly zero, which is why it
  returns an `Order` — it *is* an order, placed on the caller's behalf with a side and size
  the caller never states.

  Both are peripheral, both record which of the two tests they fail, and every venue that
  does not serve them returns `not_supported()` as before.

### Changed





- **`Types.Order`'s `side`, `order_type`, `quantity` and `status` admit `nil` in the
  typespec.** They always could in practice — a venue sending a status this package does
  not recognise has produced `nil` since the beginning — and the typespec said otherwise,
  which meant dialyzer accepted the wrong thing and rejected the right one.

  Coinbase's `close_position/3` is where it surfaced: the venue never states the side of a
  closing order, and the type left no way to say so. The keys stay enforced, so a
  constructor must still decide; the types now allow that decision to be "the venue did not
  say".

- **BREAKING: `Core.Types.Quote` no longer carries `:bid` and `:ask`.** They are order book
  data — resting orders — and `Quote` is trade data. Every venue package in the family was
  filling them, and one read `price || ask` from a best-bid/ask endpoint, producing a quote
  whose `price` was a resting order. Every value was real; only the meaning was wrong.

  A caller wanting the top of the book calls `get_top_of_book/2`. A caller wanting what
  traded calls `get_price/2`. Neither can stand in for the other.

- `Core.Types.Quote`'s `:timestamp` guarantee is unchanged and now load-bearing: **the
  venue's own, used as-is**. Observation time lives on `TopOfBook.observed_at`, in a field
  that says what it is.

### Added
- **Options.** `Types.OptionContract` (identity only — no prices), `Types.OptionGreeks`
  (model output, with the theoretical value named `:model_price` because it is the field
  most easily mistaken for a price), `Types.OptionChain` (**two-dimensional**, expiry →
  strike → `{call, put}`, a one-sided strike keeping `nil` rather than a missing key), and
  `Types.OrderLeg`. Callbacks `get_option_chain/2`, `get_option_expirations/2`,
  `get_option_greeks/2`.

  A chain row carrying bid, ask, last, mark and theoretical value offers five plausible
  prices and no help choosing, so it is split three ways: identity here, book on
  `TopOfBook`, last trade on `Quote`. **`:multiplier` of `nil` does not mean 100.** A venue
  that cannot trade multi-leg must **refuse**, never decompose — a caller left holding one
  filled leg has naked risk it never chose.

- **BREAKING: `get_historical_prices/4` returns `[Types.Candle.t()]`**, not
  `[Types.Quote.t()]`. It declared quotes, and the venue packages returned **bare untyped
  maps** with their own key sets — so the declared type was false and nothing compared one
  venue's candles to another's.

  `Types.Candle` names its time field **`:opened_at`**, because venues disagree about
  whether a bar is stamped at its open or its close and the difference is one whole
  interval — a series joined across both conventions is misaligned by a day with every
  value correct. `coherent?/1` catches a malformed bar at the boundary. `:volume` is `nil`
  when unpublished, never `0`.

- **`Types.Order` gains `:time_in_force` and `:legs`.** `Capabilities.supported_time_in_force`
  declared what a venue accepts while the order type had no field for it, so a caller
  reading an order back could not tell an IOC that expired from a GTC still working.
- **Derivatives.** `Types.Funding` (settled `:amount` kept apart from `:estimated_amount` —
  a real response has them 40% apart) and `Types.ContractStats` (mark and index are separate
  prices, and neither is a traded price), with `get_funding/2` and `get_contract_stats/2`.
- **Conversions.** `Types.Conversion` plus `quote_conversion/4`, `commit_conversion/2` and
  `get_conversion/2` — the facade's only two-step write. `:expires_at` is the point:
  committing an expired quote can fill at the *current* rate, which looks like success.
  `expired?/2` returns `nil` when no expiry was stated — unknown, not valid.
- **Portfolios.** `Types.Portfolio` and `list_portfolios/1`. A portfolio is an **address**,
  not a value; balances, orders and positions are addressed with `portfolio: id` in `opts`
  rather than by adding a parameter to forty signatures.
- **Money movement, write side.** `Types.DepositAddress`, `Types.ApprovedAddress`,
  `Types.Withdrawal`, and `get_deposit_address/3`, `list_approved_addresses/1`,
  `estimate_withdrawal_fee/4`, `withdraw/5`.

  **`withdraw/5` is the only operation in this contract that cannot be undone.** The
  allow-list is first-class: `ApprovedAddress.usable?/2` returns `nil` for a pending address
  with no stated activation, because venues delay first use precisely so a stolen account
  cannot add an address and drain it. `DepositAddress.memo_required` is **tri-state** — a
  deposit missing a required memo is credited to nobody, so `nil` must never be defaulted to
  `false`. `:network` is enforced on both.
- **`Core.Types.Position`** and **`get_positions/1`** — exposure, distinct from a balance and
  not derivable from one. `:side` is explicit and `:quantity` always positive, because
  venues disagree about how to say "short" and a guessed sign convention yields a position
  that is exactly backwards while every number stays plausible. Realised and unrealised P&L
  are separate and never summed. **`:liquidation_price` of `nil` means the venue did not
  say, not that the position is safe.**
- **`data_kind` gains `:top_of_book`, `:candles` and `:positions`.** Measured against
  Gemini's AsyncAPI and Schwab's Streamer service list: all three are streamed by a venue in
  the family and had no kind. `:top_of_book` is deliberately not `:order_book` — venues
  stream them on separate channels because one carries a level and the other a book.
  `t:data_kind/0` records the full channel-to-kind mapping so it can be checked rather than
  trusted.
- **Custodial staking.** Six callbacks — `get_staking_rates/1`, `get_staking_balances/1`,
  `get_staking_rewards/1`, `get_staking_history/1`, `stake/3`, `unstake/3` — and a
  `has_staking` capability flag, which earlier notes recorded as shipped and which did not
  exist.

  **Custodial only.** A venue that returns an *unsigned transaction* for the caller to sign
  and broadcast is doing something else, and one venue publishes both. A caller believing it
  had staked when it holds an unsigned transaction nobody signed is the most expensive form
  of this family's recurring failure.

  Four types, shaped by the venues' published schemas:
  - `Types.StakingBalance` — keeps `staked`, `available_to_trade` and
    `available_for_withdrawal` **apart**; a real response has the whole position redeemable
    and none of it tradable. `by_provider` is carried, not summed: a redemption is addressed
    to a provider.
  - `Types.StakingRate` — percentages only, `rate_pct` and `apy_pct` both named. One venue
    publishes basis points, a simple percentage and an APY for the same position;
    `bps_to_pct/1` lives here so the 100× conversion is done once.
  - `Types.StakingReward` — carries its accrual period and the rate *at accrual*.
  - `Types.StakingTransaction` — carries the unbonding progression `amount` /
    `amount_paid_so_far` / `amount_remaining`. **`settled?/1` returns `nil` when the venue
    reports no progress** — unknown, not complete.
- **`Core.Types.TopOfBook`** — best bid and ask, with **no `price` field**. `bid_size` and
  `ask_size` are optional (`nil` means *not published*, never zero); `venue_time` is the
  venue's own or `nil`, since several BBO endpoints publish none; `observed_at` is required.
  `mid/1`, `spread/1` and `crossed?/1` are functions, not fields — a mid is derived, and a
  caller has to ask for it rather than find it sitting there looking like venue data.
- **`get_top_of_book/2`** on the `Venue` behaviour, registered in `peripheral_endpoints/0`.
- **Conformance assertion 14, "top of book is not a price"** — asserts the returned struct
  is a `TopOfBook`, that `observed_at` is set, that `venue_time` is the venue's or `nil`,
  and that `TopOfBook` has no `price` field and cannot grow one.

### Changed
- **`preview_order/3` and `replace_order/4` are now `Venue` callbacks**, and required
  rather than optional. §6.1's rule is that the facade is one fixed set, never extended
  per venue, and optionality is reserved for callbacks where requiring them would be pure
  ceremony. These two are not: whether a venue can preview an order, and whether it can
  amend one atomically, are things a consumer routes on — and `replace_order/4` is a claim
  about **risk**, since its absence means cancel-then-place, which opens a window in which
  no order is live.

  **Not a breaking change, because there is nothing to break yet.** No consumer implements
  this behaviour outside the family, and all five venue packages were updated in the same
  change. A venue that serves neither returns `Venue.not_supported()` and declares
  `supports_order_preview: false` / `supports_order_replace: false`. Once the host adopts
  these packages, adding a required callback *would* be breaking and would take the
  `0.2.0` seed §7.2 describes — that signal is deliberately not spent here.

### Added
- **Five capability fields and two facade callbacks**, closing every contract gap Schwab
  found. Each existed because a venue could not say something true about itself.
  - `ceiling` gained an optional **`:scope`** (`:credential | :account | :application`),
    and `:limit` became `non_neg_integer`. Both matter: a limiter keyed by credential
    **silently over-permits** a venue that counts per account, and a registration granted
    zero throughput is legal and is **not** `:unsupported` — the endpoint exists and the
    venue serves it; that application cannot use it, and the remedies differ.
  - **`supported_sessions`** — which trading session an order may name. `[]` is the
    continuous-market case and stays the default. `[:regular]` alone **raises**: it says
    nothing, and a consumer would build a session selector with one option.
  - **`supports_order_preview`**, **`supports_order_replace`**, **`supports_multi_leg_orders`**
    — all raise if claimed while `place_order/3` is `:unsupported`.
  - **`catalog_access`** (`:enumerable | :query_only`) — whether the catalogue can be
    listed at all. `:query_only` raises if `get_symbols/1` is `:unsupported`, because
    "searchable only" and "not served at all" are different facts.
  - **`preview_order/3`** and **`replace_order/4`** as **required** facade callbacks.
    Required rather than optional: the facade is one fixed set, and optionality is for
    ceremony. Both are peripheral, and `replace_order/4`'s reason states the risk —
    absence means cancel-then-place, which works and opens a window with no order live.
- **Four order types**: `:trailing_stop`, `:trailing_stop_limit`, `:market_on_close`,
  `:limit_on_close`. Real types Schwab accepts that Core had no word for, so a venue
  serving them had to under-declare — the safe direction, and still a lie.
- **Eight instrument types**: `:option`, `:future`, `:future_option`, `:index`,
  `:mutual_fund`, `:bond`, `:forex`, `:cash_equivalent`. `[:spot, :perp]` was the whole
  vocabulary while every venue was crypto; an option is not a spot instrument, so an
  equities broker declared `[:spot]` plus a comment saying that understated it. **A
  declaration that needs a comment to be true is what this struct exists to prevent.**
- Two conformance assertions: the order-shape claims must match what the facade answers,
  and `catalog_access` must match how `get_symbols/1` behaves without a query.



## [0.1.11] - 2026-08-31

### Fixed
- **The conformance suite refused `1w` and `1M` too.** `Capabilities.validate_history!/1`
  was fixed in 0.1.10 to check `Timeframe.nameable/0`, but `AdapterContract`'s assertion 2
  still checked `known/0` — so a venue serving weekly or monthly candles built its
  declaration successfully and then **failed Core's own conformance suite**. That is the
  worse of the two failures: the package looks correct right up until the suite it exists
  to satisfy rejects it. Second site of one defect; found running the suite against Schwab.

## [0.1.10] - 2026-08-31

### Added
- `Timeframe.nameable/0` and `Timeframe.nameable?/1` — the widths Core can read as a
  **label**, which is deliberately wider than `known/0`, the widths it can **bucket**.
  `1w` and `1M` are nameable and have no boundary rule, and never will: a weekly bar's
  start depends on which weekday the venue begins its week, and a month is not a fixed
  number of seconds.
- `max_leverage` accepts **`:per_account`** — a positive statement that the venue margins
  and the ceiling belongs to the account rather than to the venue. Reg-T forced it: a
  Schwab margin account carries five different buying powers that are not multiples of one
  another, and a cash account at the same venue carries none of them, so no scalar is true.
  `nil` with `supports_margin: true` still raises, because `nil` means "nobody said" — and
  the error now names `:per_account`, so a venue author discovers the option instead of
  inventing a number. Without it the only ways to ship were to declare
  `supports_margin: false`, which is false, or to invent a multiplier.

### Fixed
- `Capabilities` no longer refuses a venue that serves weekly or monthly candles.
  `validate_history!/1` checked `historical_timeframes` against `Timeframe.known()`,
  which is the set Core can *bucket* — so declaring `1w` raised, even though
  `Timeframe` already documents both as deliberately unbucketable and instructs callers
  to read "no boundary rule" as "cannot check" rather than "invalid". Core contradicted
  itself: `aligned?/2` tolerates an unmodelled width, `boundary/2` passes it through,
  and `Capabilities` rejected it outright. A venue serving a real weekly candle had two
  options, under-declare or not ship. It now checks `Timeframe.nameable/0`; a width Core
  cannot name at all, such as `3m`, is still refused. Found deriving Schwab's
  declaration.
- `Timeframe` now models `10m` (600 seconds). Its absence was **not** neutral:
  `aligned?/2` returns `true` for a width it cannot model — "no rule" must not read as
  "invalid" — so every 10-minute candle passed the authenticity check unexamined, and
  `boundary/2` was a no-op on it. Found deriving Schwab's declaration, where
  `/pricehistory` serves 1, 5, 10, 15 and 30-minute widths. Unlike `1w` and `1M`, which
  are deliberately absent because their boundaries are not fixed, 600 seconds is not
  ambiguous and there was no reason to leave it unmodelled.

## [0.1.9] - 2026-08-28

### Fixed
- `HttpClient.request/5`'s spec no longer advertises `{:error, :rate_limited,
  retry_after: seconds}`. **It never returned it.** Both rate-limit paths convert to a
  two-element error before returning, each deliberately and for a recorded reason — a
  venue 429 because a three-element tuple reaching a two-element `case` crashed 152
  collector tasks in one night, and our own limiter's refusal because the two used to
  share wording and a self-inflicted throttle was read as a flaky venue for weeks. The
  spec was corrected rather than the behaviour. This is the fourth wrong-spec defect
  found by a venue package, and it does the same damage as the others: dialyzer reports
  a caller's correct handling of the advertised shape as unreachable dead code.

### Added
- `HttpClient` accepts `raw_status: true`, returning `{:ok, response}` for a 4xx instead
  of flattening status and body into a message string. The contract makes
  `{:refused, reason}` permanent and `{:error, reason}` possibly transient, and a venue
  states which in its 4xx body — Gemini names `InvalidSymbol`, `InvalidParameterValue`.
  Without this a venue package has to recover the distinction by string-matching, and
  `String.contains?(message, "404")` also matches a body that happens to contain "404".
  Opt-in, because the string form is what existing callers match on. 5xx is unaffected: a
  server error is not a venue's considered answer.
- `Capabilities` ceilings may now carry an optional `:burst` — the depth a venue lets a
  caller run ahead of its rate before queueing. Found by the Gemini extraction: a GCRA
  limiter takes three parameters and this type carried two, so a venue that **publishes**
  its burst depth had nowhere to declare it and the package had to hardcode the number
  beside the declaration — the exact drift the struct exists to prevent. Gemini is the
  first venue in the family to publish one ("a burst rate of five additional requests
  that are queued"). Optional rather than required, because a venue that publishes no
  burst must not be made to invent one, and absence is distinguishable from a declared
  value. A present `:burst` must be a positive integer; zero is a limiter that never
  lets anything through.
- Repo foundation: toolchain pin, `.gitignore`, formatter, credo, license, `mix.exs`,
  config layout, CI workflow, design-docs scaffolding.
