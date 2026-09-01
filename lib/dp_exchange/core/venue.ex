defmodule DpExchange.Core.Venue do
  @moduledoc """
  **The facade. The single module a consumer touches, identical on every venue.**

      defmodule DpExchange.Coinbase do
        @behaviour DpExchange.Core.Venue
      end

  Nothing else in a venue package is public API. A venue's transport, rate limiting,
  signing, session handling and supervision are implementation detail behind this, and a
  consumer cannot reach them because there is nothing here that returns them.

  ## The one rule everything else follows from

  **The facade is one fixed set of functions, never extended per venue and never omitted.**
  What differs between venues is which of them are *active*, and that is declared — once,
  in `c:capabilities/0` — rather than expressed by a venue defining extra functions or
  leaving some out.

  This is what dissolves the "all the same, but some have extras" tension. A venue does not
  add functions; it declares which ones it answers. There is no second mechanism and no
  escape hatch, because an escape hatch is a way for a caller to need to know which venue
  it is holding, and that is the one thing this contract exists to prevent.

  ## What crosses, in full

  Anything not on this list is a design error, not an omission.

  **In**: credentials, symbols, order requests, options. That is the entire inbound
  surface. No modules, no functions, no callbacks, no sink — a consumer never hands a
  package a piece of itself.

  **Out**: `{:ok, value}` / `{:error, reason}` / `{:refused, reason}` from the pull
  endpoints; `DpExchange.Core.Types.*` structs pushed to subscribers; `DpExchange.Core.Notice`
  structs on the notices channel; telemetry under `[:dp_exchange, …]`.

  **Never out**: socket handles, connection pools, transport library state, MQTT sessions,
  rate-limit buckets, signing keys, retry timers, supervisor pids.

  ## Both endpoints always exist

  Every venue can be **pulled** and can be **subscribed**. There is no flag for it and
  nothing to branch on. A venue with no streaming API implements `c:subscribe/2` over its
  own polling and pushes the results; a consumer calling `c:subscribe/2` gets a stream
  whether the mechanism beneath it is a socket, an MQTT session or a loop.

  That is not a convenience. The moment a consumer can ask *how* the data arrives, it can
  branch on the answer, and every consumer above the package forks on transport.

  ## Maturity is per endpoint, and it is bidirectional

  `c:capabilities/0` reports `:proven | :experimental | :unsupported` for each function.
  The declaration and the behaviour may not disagree, in **either** direction:

    * `:proven` or `:experimental` means the function **works**. Neither may answer
      `{:error, :not_supported}` — maturity says how well a thing is known, never whether
      it runs.
    * `:unsupported` means the function **exists and returns `{:error, :not_supported}`**.
      It may not raise, may not be undefined, and may not quietly succeed with degraded
      data.

  Both halves are asserted by the conformance suite. Checking only the first lets a venue
  under-declare and hide working functionality; checking only the second lets it
  over-declare and fail in a caller's hands. Holding both is what lets a consumer branch on
  `c:capabilities/0` instead of on venue identity.

  `{:error, :not_supported}` is **the atom**. The source this contract was extracted from
  returned the string `"not_supported"` in some places and the atom in others — in one case
  both within a single module — so a caller matching the atom silently missed the string and
  treated a refusal as an unrecognised error.

  ## A library does not start itself

  `c:child_spec/1` exists so **you** supervise the venue. This package ships no aggregate
  supervisor and no start-everything entry point: it would have to know which venues exist,
  and it would take a decision that is yours — which venues run, under what restart
  strategy, with what names. A consumer that has not asked for a venue never finds a socket
  open.
  """

  alias DpExchange.Core.{Capabilities, Instrument, Notice, Types}

  @typedoc "Opaque to this contract. A venue package documents its own shape."
  @type credentials :: map()

  @typedoc "Canonical `BASE-QUOTE` for a pair; a bare symbol on an equity venue."
  @type symbol :: String.t()

  @typedoc """
  The three-state maturity of one endpoint.

  `:experimental` is the default and the only honest starting state. `:proven` is earned
  per endpoint by production use, never by careful implementation.
  """
  @type maturity :: :proven | :experimental | :unsupported

  @typedoc """
  How a symbol's data is reaching the caller right now, **as observed**.

  Never what was subscribed. A venue that cannot observe delivery answers `:not_covered`
  rather than assuming its subscription worked.
  """
  @type route :: :stream | :internal_poll | :not_covered

  @typedoc "Whether the venue is trading right now. Crypto venues answer `:open` always."
  @type market_status :: :open | :closed | :pre | :post

  @typedoc """
  A refusal is not an error.

  `{:refused, reason}` is the venue stating it does not carry this symbol at all — a
  permanent answer. `{:error, reason}` may be transient and is worth retrying. Collapsing
  the two makes a delisted symbol look like a network blip forever.
  """
  @type result(value) :: {:ok, value} | {:error, term()} | {:refused, term()}

  # --- Lifecycle ---------------------------------------------------------

  @doc """
  Starts the venue's whole tree — connections, limiter, session refresh, whatever it needs.

  A venue with no processes returns `:ignore`. **You** put this in your supervision tree
  and choose its restart strategy, shutdown order and name.
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Starts the venue directly. See `c:child_spec/1` — a venue with no processes returns `:ignore`."
  @callback start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}

  # --- Declaration -------------------------------------------------------
  #
  # Static, credential-free, and safe to call at boot. A consumer decides whether to use a
  # package at all from these four, so none of them may need a network or a key.

  @doc "The venue's display name."
  @callback provider_name() :: String.t()

  @doc "The venue's stable identifier, matching its package's namespace segment."
  @callback runtime_id() :: atom()

  @doc "Which asset classes this venue trades, e.g. `[:crypto]` or `[:crypto, :equity]`."
  @callback asset_classes() :: [atom()]

  @doc """
  The activation map: which functions are answerable, and how well each is known.

  Static and safe at boot. This is what a consumer branches on instead of venue identity.
  """
  @callback capabilities() :: Capabilities.t()

  # --- Market data -------------------------------------------------------
  #
  # Credentials are an INPUT to which upstream endpoint serves the caller best, never a
  # gate on whether one does. Several venues serve the same data publicly and
  # authenticated, with a materially higher ceiling on the authenticated path, and a
  # package holding credentials should be using it. Which endpoint was actually called is
  # mechanism and does not cross this boundary — the caller passes credentials or does
  # not, and reads the consequence from `c:capabilities/0`.

  @doc "The current price for `symbol`."
  @callback get_price(symbol(), keyword()) :: result(Types.Quote.t())

  @doc """
  Historical candles for `symbol` at `timeframe`.

  The venue rejects a timeframe it does not serve rather than substituting the nearest
  one. A missing granularity silently becoming the closest one mislabels every candle it
  touches, and every value stays plausible.
  """
  @callback get_historical_prices(symbol(), String.t(), keyword(), keyword()) ::
              result([Types.Candle.t()])

  @doc "Every symbol the venue lists."
  @callback get_symbols(keyword()) :: result([symbol()])

  @doc """
  Best bid and ask for `symbol` — the top of the book, **not a traded price**.

  Returns `Types.TopOfBook`, which has no `price` field. A caller wanting what the
  instrument last traded at calls `get_price/2`; a caller wanting what it can currently
  trade at calls this. The two must never stand in for one another — see
  `Types.TopOfBook`'s moduledoc for the defect that rule was written from.

  Most venues publish a dedicated BBO endpoint that is cheaper than a full book, which is
  why this is not `get_order_book/2` with a depth of one. Several publish no timestamp with
  it and several publish no sizes; the type makes both optional rather than inventing them.
  """
  @callback get_top_of_book(symbol(), keyword()) :: result(Types.TopOfBook.t())

  @doc """
  Staking rates on offer, per asset and provider.

  **This is custodial staking** — the venue holds the asset and pays a rate. It is not
  on-chain staking: an endpoint that returns an *unsigned transaction* for a caller to sign
  and broadcast is a different capability and must never be reached through these callbacks.
  A caller believing it had staked when it holds an unsigned transaction nobody signed is
  the most expensive form of this family's recurring failure.
  """
  @callback get_staking_rates(keyword()) :: result([Types.StakingRate.t()])

  @doc "Staked positions, one per asset, with their liquidity states kept apart."
  @callback get_staking_balances(keyword()) :: result([Types.StakingBalance.t()])

  @doc "Rewards accrued over a period. The period is part of the value, not a filter."
  @callback get_staking_rewards(keyword()) :: result([Types.StakingReward.t()])

  @doc "Movements in and out of staked positions, redemptions included with their progress."
  @callback get_staking_history(keyword()) :: result([Types.StakingTransaction.t()])

  @doc """
  Stakes `amount` of `asset`.

  Returns the resulting transaction. **This moves funds**: a consumer calling it has decided
  to, and D2 puts that decision with the host rather than with this package.
  """
  @callback stake(String.t(), Decimal.t(), keyword()) :: result(Types.StakingTransaction.t())

  @doc """
  Redeems `amount` of a staked `asset`.

  **Returns immediately; the redemption does not complete immediately.** The returned
  transaction carries `:amount_remaining`, which is non-zero for as long as the asset is
  unbonding. A caller that treats the return value as settled will spend an asset it does
  not have yet — see `Types.StakingTransaction`.
  """
  @callback unstake(String.t(), Decimal.t(), keyword()) :: result(Types.StakingTransaction.t())

  @doc """
  Open positions — exposure, not holdings.

  Distinct from `get_balances/1`: a balance says what the account holds, a position says
  what exposure it has taken and how far it is from liquidation. A spot-only venue declares
  this `:unsupported`; that is not the same as having none.
  """
  @callback get_positions(keyword()) :: result([Types.Position.t()])

  @doc """
  Funding for a perpetual — settled, projected, and when the next one lands.

  Returns `Types.Funding`, which keeps the settled amount and the venue's estimate apart. A
  venue that does not trade perpetuals declares this `:unsupported`.
  """
  @callback get_funding(symbol(), keyword()) :: result(Types.Funding.t())

  @doc """
  Risk statistics for a derivative — mark, index and open interest.

  Returns `Types.ContractStats`. Mark and index are separate prices with separate meanings,
  and neither is what the instrument last traded at.
  """
  @callback get_contract_stats(symbol(), keyword()) :: result(Types.ContractStats.t())

  @doc """
  Quotes a conversion of `amount` from one asset to another. **Nothing moves.**

  Returns a `Types.Conversion` with `status: :quoted` and, where the venue states one, an
  `:expires_at`. The rate is held only until then. Committing is a separate call —
  `commit_conversion/2` — and a caller that never commits has done nothing but ask.
  """
  @callback quote_conversion(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Types.Conversion.t())

  @doc """
  Commits a previously quoted conversion. **This moves funds.**

  A quote past its window may be refused, or filled at the current rate rather than the
  quoted one — which is the outcome to guard against, because it looks like success. D2 puts
  the decision to call this with the host.
  """
  @callback commit_conversion(String.t(), keyword()) :: result(Types.Conversion.t())

  @doc "A conversion's current state, quoted or committed."
  @callback get_conversion(String.t(), keyword()) :: result(Types.Conversion.t())

  @doc """
  Converts `amount` of `from` into `to` in **one call**, with no quote to accept first.

  Optional, and deliberately separate from `quote_conversion/4` plus `commit_conversion/2`
  rather than a shorthand for them.

  **The difference is who carries the price risk, and it is not a detail.** The two-step
  form shows a rate and holds it: the caller sees the number before anything moves, and a
  stale quote is refused. This form executes at whatever the venue's price is when it
  arrives, and the caller learns the rate from the result. A venue offering only one of the
  two cannot be made to offer the other by a package wrapping it — quoting a rate this
  package computed and calling it held would be a promise the venue never made.

  So a venue declares each independently, and a caller that must see a price first uses
  `quote_conversion/4` or does without.

  Returns a `Conversion` already `:settled` — it has happened.
  """
  @callback convert(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Types.Conversion.t())

  @doc """
  The portfolios this credential can address.

  A portfolio is **where** you ask, not what you get back: balances, orders and positions
  are addressed to one with `portfolio: id` in `opts`. A venue with a single implicit
  context declares this `:unsupported` and ignores the option.

  **Where the option is omitted on a venue that has portfolios, the package uses the venue's
  default and does not invent one.** A caller needing determinism passes the id.
  """
  @callback list_portfolios(keyword()) :: result([Types.Portfolio.t()])

  @doc """
  A deposit address for `asset` on `network`.

  **The network is required and not defaulted.** The same asset exists on several chains and
  the addresses are not interchangeable; a package choosing a default network would be
  choosing where a caller's funds go.

  Read `Types.DepositAddress`'s `:memo_required` before sending. `nil` there means the venue
  did not say, which is not the same as `false`.
  """
  @callback get_deposit_address(String.t(), String.t(), keyword()) ::
              result(Types.DepositAddress.t())

  @doc "Addresses on the withdrawal allow-list, with whether each is usable yet."
  @callback list_approved_addresses(keyword()) :: result([Types.ApprovedAddress.t()])

  @doc """
  Estimates the fee to withdraw `amount` of `asset` over `network`.

  Separate from `withdraw/5` because the venues expose it separately, and because the
  estimate can differ from the charge. Do not record an estimate as a fee.
  """
  @callback estimate_withdrawal_fee(String.t(), String.t(), Decimal.t(), keyword()) ::
              result(Decimal.t())

  @doc """
  Withdraws `amount` of `asset` over `network` to `address`.

  **This is the only operation in this contract that cannot be undone.** D2 places the
  decision to call it with the host, not with this package.

  Two failure modes are worth naming because neither is a package bug:

    * the address is not on the venue's allow-list, or is on it and **not yet active** —
      see `Types.ApprovedAddress`
    * the asset requires a memo and none was given, in which case the funds leave and are
      not credited to anyone

  A memo is passed as `memo:` in `opts`. A package must not synthesise one.
  """
  @callback withdraw(String.t(), String.t(), Decimal.t(), String.t(), keyword()) ::
              result(Types.Withdrawal.t())

  @doc """
  The option chain for an underlying — expiry × strike, both sides.

  Returns `Types.OptionChain`. Two-dimensional deliberately: a flat list of contracts is
  lossless in data and answers none of the questions a chain is asked.
  """
  @callback get_option_chain(String.t(), keyword()) :: result(Types.OptionChain.t())

  @doc """
  The expiries listed on an underlying, without the strikes.

  Venues expose this separately because a full chain is large and a caller choosing an
  expiry does not need every strike to do it.
  """
  @callback get_option_expirations(String.t(), keyword()) :: result([Date.t()])

  @doc """
  Greeks and implied volatility for one contract.

  Returns `Types.OptionGreeks`. **Model output, not market data** — two venues quoting the
  same contract publish different numbers and neither is wrong.
  """
  @callback get_option_greeks(String.t(), keyword()) :: result(Types.OptionGreeks.t())

  @doc "Watchlists held at the venue. The venue's list, which may differ from the host's."
  @callback list_watchlists(keyword()) :: result([Types.Watchlist.t()])

  @doc "One watchlist including its membership."
  @callback get_watchlist(String.t(), keyword()) :: result(Types.Watchlist.t())

  @doc "Creates a watchlist at the venue."
  @callback create_watchlist(String.t(), [String.t()], keyword()) :: result(Types.Watchlist.t())

  @doc "Replaces a watchlist's name or membership."
  @callback update_watchlist(String.t(), keyword()) :: result(Types.Watchlist.t())

  @doc "Deletes a watchlist at the venue."
  @callback delete_watchlist(String.t(), keyword()) :: result(:ok)

  @doc """
  Financial statements for an issuer.

  `kind` selects balance sheet, income, cash flow or the venue's indicator set. Line items
  come back under the venue's own names — see `Types.FinancialStatement` for why they are
  not normalised into a fixed schema.
  """
  @callback get_financials(String.t(), atom(), keyword()) ::
              result([Types.FinancialStatement.t()])

  @doc "Dividends, earnings dates and splits. Each date is carried under its own name."
  @callback get_corporate_events(keyword()) :: result([Types.CorporateEvent.t()])

  @doc "Regulatory filings the venue indexes. This interface points at them; it never fetches one."
  @callback get_filings(String.t(), keyword()) :: result([Types.Filing.t()])

  @doc "News the venue publishes or relays, with its own tagging."
  @callback get_news(keyword()) :: result([Types.NewsItem.t()])

  @doc """
  A venue screener, mover list or ranking, by the venue's own identifier for it.

  Rows carry the venue's ranking and metrics. Two venues' lists under one name answer
  different questions; this interface does not merge or re-rank them.
  """
  @callback get_screener(String.t(), keyword()) :: result([Types.ScreenerResult.t()])

  @doc "Creates an account or sub-account at the venue."
  @callback create_account(keyword()) :: result(map())

  @doc "Renames an existing account at the venue."
  @callback rename_account(String.t(), String.t(), keyword()) :: result(map())

  @doc "The roles this credential holds, as the venue defines them."
  @callback get_roles(keyword()) :: result(map())

  @doc "The order book for `symbol`, best price first on both sides."
  @callback get_order_book(symbol(), keyword()) :: result(Types.OrderBook.t())

  @doc """
  Recent public trades for `symbol` — the tape.

  Optional. **This is not `get_trade_history/2`**, which returns the credential's *own*
  fills. The tape is everyone's executions and has no order of yours behind it; a package
  answering one with the other would hand a caller a filtered view of the market and call
  it the market.

  **Broken trades are excluded unless `opts[:include_broken]` says otherwise.** An exchange
  that busts an erroneous print has said it did not stand, and leaving it in a series puts a
  phantom high or low into every range and volatility figure built on it — none of which
  will error. Venues with no concept of busts have nothing to exclude.

  `opts[:since]` and `opts[:limit]` narrow the window where a venue supports them, and go
  to the venue rather than being applied to the page it returned.
  """
  @callback get_trades(symbol(), keyword()) :: result([Types.Trade.t()])

  @doc """
  A foreign-exchange reference rate for `pair` at `at`.

  Optional. **Not a rate the venue trades at** — a venue publishing this is relaying a
  third party's number for historical reference, which is why `Types.FxRate` carries the
  source and the benchmark alongside the rate.

  `at` is the instant the rate is for, not a window: the venue answers for that moment. A
  venue that serves only recent history says so by refusing, rather than returning its
  nearest available rate under the requested timestamp.
  """
  @callback get_fx_rate(String.t(), DateTime.t(), keyword()) :: result(Types.FxRate.t())

  @doc """
  The order imbalance published ahead of an opening or closing auction.

  Optional. `opts[:auction]` is `:opening` or `:closing` and is **required** — the two are
  different auctions with different windows, and a venue asked for neither has nothing to
  answer.

  **Returns a list**, newest first, because the venue publishes a series and not only a
  latest value: the imbalance updates every few seconds through the auction window and how
  it moved is the point. `opts[:history]` selects the published series where a venue serves
  the snapshot and the series separately — the same shape `get_orders/2` uses for resting
  versus closed orders.

  **A series entry may carry less than a snapshot.** Webull's NOII bars publish the three
  auction prices and the time and *not* the paired quantity, the imbalance quantity or the
  side; those come back `nil`, which means the venue did not publish them on that endpoint
  rather than that the imbalance was zero.

  **Not derivable from `get_order_book/2`.** During an auction the continuous book stops
  being the price: what matters is how much can be matched, how much cannot, and where the
  auction would clear. A caller reading a continuous quote at 15:59 is reading a book that
  is not where the close will happen.

  Published only inside the venue's auction windows; outside them a venue may answer with
  the last one it published, which is why `Types.AuctionImbalance` carries both the venue's
  own time and when it was observed.
  """
  @callback get_auction_imbalance(symbol(), keyword()) :: result([Types.AuctionImbalance.t()])

  @doc """
  Traded volume split by price and by side, one entry per interval.

  Optional. **Not a `Candle` with extra fields and not derivable from one**: a candle's
  single volume number cannot say that of 1,000 shares, 600 lifted the ask and 400 hit the
  bid, nor at which prices each happened. Neither can be reconstructed from the other, which
  is why `Types.VolumeProfile` is its own type.

  `timeframe` uses the same vocabulary `get_historical_prices/4` does, and a venue that does
  not serve a width returns an error rather than the nearest one it does.
  """
  @callback get_volume_profile(symbol(), String.t(), keyword()) ::
              result([Types.VolumeProfile.t()])

  @doc "A bulk snapshot across the venue's symbols, where it offers one."
  @callback get_market_overview(keyword()) :: result(map())

  @doc """
  The venue's listings with the fields `c:get_symbols/1` discards — base, quote,
  instrument type, trading status.

  Optional: single-quote venues derive base and quote trivially and have no non-spot
  instruments, so requiring an implementation there is ceremony.
  """
  @callback list_instruments(keyword()) :: result([Instrument.t()])

  # --- Account and trading -----------------------------------------------
  #
  # Credentials arrive as arguments. A package never reads them from a vault, an
  # environment variable or a consumer's config — it is handed what it needs, per call.

  @doc "Balances for the credentialed account."
  @callback get_balances(credentials(), keyword()) :: result([Types.Balance.t()])

  @doc "Accounts visible to the credential."
  @callback get_accounts(credentials(), keyword()) :: result([map()])

  @doc "The fee schedule that applies to this credential."
  @callback get_fees(credentials(), keyword()) :: result(map())

  @doc "Deposit and withdrawal history — needed to compute cost basis for transferred-in assets."
  @callback get_transfers(credentials(), keyword()) :: result([map()])

  @doc "Places an order. Irreplaceable by definition: this is the act."
  @callback place_order(credentials(), map(), keyword()) :: result(Types.Order.t())

  @doc "Cancels an order."
  @callback cancel_order(credentials(), String.t(), keyword()) :: result(Types.Order.t())

  @doc """
  Cancels open orders in bulk, at a scope the caller must state.

  Optional. **`opts[:scope]` is required and has no default** — `:session` cancels what
  this credential's session opened, `:account` cancels everything the account has open
  including orders placed by another key or by a person at the venue's own web interface.

  The two are not interchangeable and the wider one is destructive in a way a caller may
  not expect, so a missing scope is an error rather than a choice made here. Gemini's own
  documentation recommends the narrow one; that is guidance for the caller, not licence
  for this contract to pick.

  **This is not `get_orders/2` followed by `cancel_order/3` in a loop.** That is N requests
  with N partial outcomes, and it cannot cancel an order that appeared between the listing
  and the cancels. Only the venue closes the set it holds.

  Returns `%{cancelled: [id], rejected: [id]}`. **A non-empty `rejected` is not a failed
  call** — the venue answered and some orders were already gone. Returning an error there
  would tell a caller nothing was cancelled when most of it was.
  """
  @callback cancel_all_orders(credentials(), keyword()) ::
              result(%{cancelled: [String.t()], rejected: [String.t()]})

  @doc """
  Validates an order **without placing it**, returning the venue's own estimate of what
  it would cost.

  Optional. Schwab and Coinbase serve it. It is the call that checks an
  order against the venue's rules before committing to it — which matters most exactly
  where order writes are rate-limited and reads are not.

  Declared through `supports_order_preview`, so a caller can tell "this venue has no
  preview" from "this package has not implemented one".
  """
  @callback preview_order(credentials(), map(), keyword()) :: result(map())

  @doc """
  Replaces an open order **atomically**.

  Optional. Every crypto venue in the family cancels and re-places, and on a venue that
  supports replacement those two calls are **not equivalent**: cancel-then-place opens a
  window in which no order is live, and on a moving market that window is the risk.

  So this is a claim about risk rather than convenience, and it is declared through
  `supports_order_replace` rather than being inferred from the callback existing.
  """
  @callback replace_order(credentials(), String.t(), map(), keyword()) :: result(Types.Order.t())

  @doc """
  Validates a *change* to an open order without making it, returning the venue's estimate
  of the amended order.

  Optional, and distinct from `preview_order/3` in the way that matters: `preview_order/3`
  asks what an order that does not exist would cost, and this asks what an order that
  **does** exist would cost after a change. A caller cannot get the second by asking the
  first — the venue prices an amendment against the resting order's own state, including
  whatever of it has already filled.

  The reason to have it at all is the same one behind `replace_order/4`. Amending is
  irreversible at the venue, and a caller who cannot price the amendment first is choosing
  between committing blind and cancel-then-place, which reopens the very window
  `replace_order/4` exists to close.

  Declared through `supports_order_preview`, alongside `preview_order/3`.
  """
  @callback preview_replace(credentials(), String.t(), map(), keyword()) :: result(map())

  @doc """
  Closes an open position on `symbol` by placing the order that flattens it.

  Optional. **This is an order, not a query** — the venue works out the side and the size
  from the position it holds and then places the order itself, which is why it returns an
  `Order` like `place_order/3` does.

  That is also why it is not replaceable by `get_positions/1` plus `place_order/3`: the
  size a caller computes is the size as of the caller's last read, and the venue's is the
  size now. On a position that moved in between, the caller's arithmetic leaves a residue
  or overshoots into a position the other way. Only the venue can flatten to exactly zero.

  A venue that does not carry positions has nothing to close, and says so through
  `capabilities/0` rather than through this returning an empty success.
  """
  @callback close_position(credentials(), symbol(), keyword()) :: result(Types.Order.t())

  @doc "One order's current state."
  @callback get_order(credentials(), String.t(), keyword()) :: result(Types.Order.t())

  @doc "Orders visible to the credential."
  @callback get_orders(credentials(), keyword()) :: result([Types.Order.t()])

  @doc "Past fills for the credential."
  @callback get_trade_history(credentials(), keyword()) :: result([Types.Fill.t()])

  @doc """
  The credential's own traded volume, as the venue aggregates it.

  Optional. **This is the account's volume, not the market's** — `get_market_overview/1`
  answers the second question and this one answers "what have I traded".

  It is not `get_trade_history/2` summed. The venue's aggregation is the one its own fee
  tiers are computed from, and reproducing it means fetching every fill over the reporting
  window — on a venue that requires a symbol per request, that is one request per symbol
  per period, and the result would still be this package's arithmetic rather than the
  venue's ledger. Where the two disagree, the venue's is the one that decides what a
  caller is charged.

  Shape is the venue's own, so `map()`: the fields differ enough between venues that a
  normalised struct would be mostly `nil` on all of them.
  """
  @callback get_trade_volume(credentials(), keyword()) :: result([map()])

  # --- Streaming ---------------------------------------------------------

  @doc """
  Subscribes the caller to `symbols`.

  **The venue decides everything about how.** Connections, sharding, pacing, protocol,
  whether it streams at all or polls and pushes the results — none of it crosses this
  boundary, and a caller cannot discover it.

  Events arrive as messages to the subscribing process, or to a pid given in `opts`,
  tagged so a process subscribed to several venues can tell them apart. The payload is a
  `DpExchange.Core.Types.*` struct — **the same value the pull endpoints return** — so one
  handler serves a price whether the caller asked for it or was sent it.

  ## Back-pressure is a bounded mailbox, and it is declared

  A venue pushing faster than its subscriber consumes drops oldest beyond a stated bound
  and emits a `:degraded` notice saying so. Growing a mailbox silently until the node dies
  is the failure this avoids; dropping silently is the failure the notice avoids.
  """
  @callback subscribe([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  Stops delivery for `symbols`.

  **Addressed by the thing itself, never by a handle.** Takes the same identifiers
  `c:subscribe/2` was given: on crypto the pair, on an equity venue the symbol. A caller
  already knows what it subscribed to, so a subscription reference would be pure overhead
  wrapping something it already holds — and one more thing to leak.

  A dead subscriber stops delivery too. A venue must not accumulate events for a process
  that no longer exists.
  """
  @callback unsubscribe([symbol()], keyword()) :: :ok | {:error, term()}

  @doc "Changes a live subscription's symbol set without tearing the venue's connections down."
  @callback update_symbols([symbol()], keyword()) :: :ok | {:error, term()}

  @doc """
  What is **observed arriving**, by which route — never what was subscribed.

  This is the strongest guarantee in the contract, and it exists because intent standing in
  for evidence is how a venue reported 325 symbols subscribed and confirmed while 174 were
  delivering. A venue that cannot observe delivery answers `:not_covered` rather than
  reporting success it cannot see.

  Symbols absent from the map are `:not_covered`.
  """
  @callback coverage(keyword()) :: %{symbol() => route()}

  @doc """
  Subscribes the caller to the package's notices — what it is doing and what is going
  wrong with it.

  Distinct from `c:subscribe/2`, which carries what the *venue* says about the *market*. A
  monitoring process that never touches market data still needs to know a credential was
  rejected.

  **A notice is a prompt to re-read, never the record.** Delivery is not guaranteed — see
  `DpExchange.Core.Notice`.
  """
  @callback subscribe_notices(keyword()) :: :ok | {:error, term()}

  # --- Health ------------------------------------------------------------

  @doc "Whether the venue is reachable and the credential, if given, is accepted."
  @callback test_connection(credentials() | nil, keyword()) :: result(map())

  @doc "What the venue's ceiling currently is and how much of it is left."
  @callback get_rate_limit_status(credentials() | nil, keyword()) :: result(map())

  @doc """
  Whether the venue is trading right now.

  Crypto venues answer `:open`. An equity venue answers honestly, including pre- and
  post-market.

  **Not cosmetic.** A feed that delivers nothing warns loudly and keeps warning, so without
  this an equities package alarms every night and every weekend — and a real outage becomes
  indistinguishable from Saturday. The venue is the only thing that knows its own calendar;
  the *policy* — whether to trade in extended hours — stays with the consumer.
  """
  @callback market_status(keyword()) :: result(market_status())

  @doc """
  Rounds a price and quantity to what the venue will actually accept.

  Optional: when a venue does not implement it, a caller skips quantization and falls back
  to per-asset-class defaults.
  """
  @callback quantization(symbol()) :: result(map())

  @optional_callbacks [
    list_instruments: 1,
    quantization: 1
  ]

  @doc """
  Every callback a venue package must implement, as `{name, arity}`.

  The conformance suite drives its completeness assertion off this rather than a
  hand-maintained list, so a callback added here cannot be forgotten there.
  """
  @spec required_callbacks() :: [{atom(), arity()}]
  def required_callbacks do
    __MODULE__.behaviour_info(:callbacks) -- __MODULE__.behaviour_info(:optional_callbacks)
  end

  @doc """
  The endpoints a package must prove before it can stop being EXPERIMENTAL.

  ## The rule matters more than the list

  The facade will grow, and someone will have to classify an endpoint this list does not
  contain. **An endpoint is core only if both hold:**

    1. **Irreplaceable** — only this venue can answer it. If a consumer can get the same
       answer elsewhere, the package failing is an inconvenience rather than a blocker.
    2. **Load-bearing** — the consumer's primary job *fails* without it rather than
       degrading. If the documented behaviour on absence is "the caller does without", it
       is not core.

  Reclassify by applying the two tests, never by amending a table.

  ## Two properties of the boundary

  **Core is per venue.** An endpoint the venue does not offer is `:unsupported` and drops
  out of that venue's core set; a market-data-only venue is not held to trading it does not
  have.

  **Trading is core exactly when it exists.** If `place_order/3` is active then the order
  group is core, and nothing but live trading proves it.
  """
  @spec core_endpoints() :: [{atom(), arity()}]
  def core_endpoints do
    [
      # Nothing else can tell a consumer whether to use the package at all.
      {:provider_name, 0},
      {:runtime_id, 0},
      {:asset_classes, 0},
      {:capabilities, 0},
      # Nothing works if the package cannot run.
      {:child_spec, 1},
      {:start_link, 1},
      # Only the venue knows what the venue lists, or what it costs.
      {:get_symbols, 1},
      {:get_price, 2},
      # The push half of the same job. `unsubscribe` because failing to stop is a leak,
      # and `coverage` because a stream you cannot verify is a stream you cannot trust.
      {:subscribe, 2},
      {:unsubscribe, 2},
      {:coverage, 1},
      # Only the venue knows your position on it; nothing can be sized without it.
      {:get_balances, 2},
      # Core when trading is active at all — irreplaceable by definition.
      {:place_order, 3},
      {:cancel_order, 3},
      {:get_order, 3},
      {:get_orders, 2},
      # Knowing you are blocked is part of working, and only the venue can say.
      {:test_connection, 2},
      {:get_rate_limit_status, 2}
    ]
  end

  @doc """
  The endpoints outside the core set, each with the test it fails.

  Recorded because it is what a future classifier reasons from, not as a list to append to.
  """
  @spec peripheral_endpoints() :: %{{atom(), arity()} => String.t()}
  def peripheral_endpoints do
    %{
      {:get_historical_prices, 4} =>
        "replaceable — historical prices are routinely sourced from a different provider entirely",
      {:quantization, 1} =>
        "not load-bearing — an unsupporting venue means the caller skips quantization",
      {:get_order_book, 2} =>
        "not load-bearing — a consumer reaches every other endpoint without depth; " <>
          "irreplaceable where published, since a book is the venue's own",
      {:list_watchlists, 1} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does, since " <>
          "the venue's list is the venue's and can differ from any the host holds",
      {:get_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:create_watchlist, 3} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:update_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:delete_watchlist, 2} =>
        "not load-bearing — a venue may keep no lists; irreplaceable where it does",
      {:get_financials, 3} =>
        "replaceable — issuer statements are published by the issuer and carried by many " <>
          "data providers, so a venue is one source among several",
      {:get_corporate_events, 1} =>
        "replaceable — dividends, earnings dates and splits come from the issuer and are " <>
          "carried by many providers",
      {:get_filings, 2} =>
        "replaceable — filings live with the regulator; a venue indexing them is a pointer",
      {:get_news, 1} => "replaceable — a venue relaying news is one feed among many",
      {:get_screener, 2} =>
        "not load-bearing — a venue may publish no screeners; irreplaceable where it does, " <>
          "since the criteria are the venue's own and no other source reproduces its list",
      {:create_account, 1} =>
        "not load-bearing — a venue may not open accounts through its API; irreplaceable " <>
          "where it does, since only the venue creates accounts on the venue",
      {:rename_account, 3} =>
        "not load-bearing — a venue may not expose account administration; irreplaceable " <>
          "where it does",
      {:get_roles, 1} =>
        "not load-bearing — a venue may define no roles; irreplaceable where it does, since " <>
          "only the venue knows what this credential is permitted to reach",
      {:get_top_of_book, 2} =>
        "replaceable — the top level of get_order_book/2 answers the same question wherever " <>
          "a venue publishes depth",
      {:get_option_chain, 2} =>
        "not load-bearing — a venue may list no options at all, so a package without this " <>
          "is complete rather than lacking; irreplaceable where the venue does list them",
      {:get_option_expirations, 2} =>
        "replaceable — derivable from get_option_chain/2, at the cost of fetching every " <>
          "strike to learn the dates",
      {:get_option_greeks, 2} =>
        "replaceable — model output; any pricing library computes it from the contract and " <>
          "a volatility input, and two venues publish different numbers anyway",
      {:get_deposit_address, 3} =>
        "not load-bearing — a venue may accept no deposits through its API; irreplaceable " <>
          "where it does, since only the venue can say where its own custody receives",
      {:list_approved_addresses, 1} =>
        "not load-bearing — not every venue keeps an allow-list; irreplaceable where one exists",
      {:estimate_withdrawal_fee, 4} =>
        "replaceable — network fees are observable on the chain, though not to the venue's " <>
          "own precision",
      {:withdraw, 5} =>
        "not load-bearing — a venue may not permit withdrawal through its API; irreplaceable " <>
          "where it does, since nothing outside the venue moves the venue's custody",
      {:list_portfolios, 1} =>
        "not load-bearing — a venue may have one implicit context and nothing to name",
      {:quote_conversion, 4} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does, " <>
          "since only the venue quotes its own rate",
      {:commit_conversion, 2} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does",
      {:get_conversion, 2} =>
        "not load-bearing — a venue may offer no conversion; irreplaceable where it does, " <>
          "since only the venue holds the conversion's state",
      {:get_funding, 2} =>
        "not load-bearing — a venue may list no perpetuals; irreplaceable where it does, " <>
          "since funding is the venue's own and differs between venues on one contract",
      {:get_contract_stats, 2} =>
        "not load-bearing — a venue may list no derivatives; irreplaceable where it does, " <>
          "since a mark price is the venue's own valuation and nothing external reproduces it",
      {:get_positions, 1} =>
        "not load-bearing — a spot venue holds none; irreplaceable where they exist, since " <>
          "only the venue knows what it has you down for",
      {:get_staking_rates, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since the " <>
          "rate is the venue's own offer",
      {:get_staking_balances, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since only " <>
          "the venue knows what it holds staked",
      {:get_staking_rewards, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does",
      {:get_staking_history, 1} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, since only " <>
          "the venue holds its own record",
      {:stake, 3} => "not load-bearing — a venue may not stake; irreplaceable where it does",
      {:unstake, 3} =>
        "not load-bearing — a venue may not stake; irreplaceable where it does, and the " <>
          "only route back out of the venue's custody",
      {:list_instruments, 1} =>
        "not load-bearing — a richer get_symbols/1; absence costs detail, not function",
      {:get_market_overview, 1} => "not load-bearing — a bulk convenience over per-symbol calls",
      {:get_fees, 2} =>
        "not load-bearing — a consumer reaches every other endpoint without the schedule; " <>
          "irreplaceable where published, since a venue's fees are its own",
      {:get_trade_history, 2} => "not load-bearing — after-the-fact reconstruction",
      {:get_transfers, 2} =>
        "not load-bearing — a record of movements the venue has already made; " <>
          "irreplaceable, since only the venue holds its own ledger",
      {:get_accounts, 2} => "not load-bearing — balances are the sizing input",
      {:update_symbols, 2} =>
        "not load-bearing — an optimisation over unsubscribe/2 + subscribe/2, both core",
      {:market_status, 1} =>
        "not load-bearing — a venue that cannot say is treated as open, which is the crypto answer",
      {:preview_order, 3} =>
        "not load-bearing — absence means placing without a dry run, which is how every " <>
          "other venue in the family works",
      {:replace_order, 4} =>
        "not load-bearing, but it is RISK-bearing — absence means cancel-then-place, " <>
          "which works and opens a window in which no order is live",
      {:preview_replace, 4} =>
        "not load-bearing — absence means amending without a dry run; the amendment " <>
          "itself is what bears risk, and that is replace_order/4's entry",
      {:convert, 4} =>
        "irreplaceable and not load-bearing — only the venue converts on the venue, and a " <>
          "consumer that never converts is complete without it; NOT a shorthand for " <>
          "quote_conversion/4 plus commit_conversion/2, which hold a rate this one does not",
      {:get_trade_volume, 2} =>
        "irreplaceable and not load-bearing — the venue's own aggregation is what its fee " <>
          "tiers are computed from, and summing get_trade_history/2 gives this package's " <>
          "arithmetic rather than the venue's ledger; a consumer that never reports on its " <>
          "own volume is complete without it",
      {:get_fx_rate, 3} =>
        "replaceable — an FX reference rate is a third party's number that the venue is " <>
          "relaying, and the source publishes it directly; NOT the venue's own market, " <>
          "which is why Types.FxRate names the source separately from the provider",
      {:get_trades, 2} =>
        "replaceable — the public tape is carried by every market-data provider, and a " <>
          "consumer already reading one elsewhere does not need the venue's; NOT the same " <>
          "question as get_trade_history/2, which is the credential's own fills",
      {:get_auction_imbalance, 2} =>
        "irreplaceable and not load-bearing — only the exchange running the auction " <>
          "publishes its imbalance, and a consumer that never trades an auction is " <>
          "complete without it; NOT derivable from get_order_book/2, which describes the " <>
          "continuous market the auction replaces",
      {:get_volume_profile, 3} =>
        "irreplaceable and not load-bearing — the split of volume by price and side is the " <>
          "venue's own classification of its own prints, and a Candle's single volume " <>
          "number cannot be decomposed back into it",
      {:cancel_all_orders, 2} =>
        "irreplaceable and not load-bearing — get_orders/2 plus cancel_order/3 in a loop " <>
          "is N partial outcomes and cannot reach an order that appeared between the two, " <>
          "but a caller that never needs a bulk cancel is complete without it",
      {:close_position, 3} =>
        "irreplaceable and not load-bearing — get_positions/1 plus place_order/3 leaves a " <>
          "residue when the position moves between the read and the order, and only the " <>
          "venue flattens to exactly zero; a venue carrying no positions has nothing to close",
      {:subscribe_notices, 1} =>
        "not load-bearing — losing notices costs visibility into the stream, not the stream"
    }
  end

  @doc """
  The refusal every unsupported endpoint returns.

  **The atom, never the string.** The source this was extracted from used both — in one
  module, both forms — so a caller matching the atom silently missed the string and treated
  a refusal as an unrecognised error.
  """
  @spec not_supported() :: {:error, :not_supported}
  def not_supported, do: {:error, :not_supported}

  @doc "Every notice kind a venue may emit. See `DpExchange.Core.Notice`."
  @spec notice_kinds() :: [Notice.kind()]
  def notice_kinds, do: Notice.kinds()
end
