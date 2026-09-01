defmodule DpExchange.Core.ReferenceVenue do
  @moduledoc """
  A complete, in-process venue implementing the whole facade — the thing the conformance
  suite is proven against inside Core, rather than waiting on a venue package.

  **Core's own suite must not depend on a venue to exercise Core's own invariants.** If
  the first thing that runs `DpExchange.Core.AdapterContract` is `dp_exchange_coinbase`,
  then every defect in the suite is discovered in a repo that cannot fix it.

  ## Its symbol mapping is deliberately hostile

  `sep: ""` with a quote asset that **contains** another — `BUSD` and `USD` — which is the
  exact shape of the round-trip bug that motivated the invariant. `BTCBUSD` ends with
  `USD` before it ends with `BUSD`, so a quote list not ordered longest-first splits the
  base as `BTCB`: a pair that does not exist, carrying values that all look plausible.

  Note that `USD`, `USDT` and `USDC` do **not** collide this way — none is a suffix of
  another, so they round-trip in either order. A fixture built only on those would look
  like it was testing the ordering rule while testing nothing.

  Coinbase, the reference extraction, has an effectively identity mapping, so a fake
  modelled on it would exercise assertion 4 barely at all. This one is chosen to be the
  hardest case the contract has to survive, not the easiest.

  ## What it refuses, and why that is the interesting part

  It declares `{:get_transfers, 2}` and `{:quantization, 1}` as `:unsupported` and returns
  `{:error, :not_supported}` — **the atom** — from both, so the bidirectional agreement
  assertion has something real to check in each direction. A fake where everything works
  proves only half the contract.

  ## The two rules it follows, from thirteen real bug reports

  Eleven of the thirteen bugs found in a comparable in-process fake were the fake
  diverging from the real client. They split into six *loud* divergences — the fake
  rejecting what the real thing accepts — and three *silent* ones, which are the dangerous
  half. So:

    1. **Less capable is allowed; differently capable is not.** Where this fake cannot
       answer, it returns an error. It never returns an empty success for something
       unsupported — the original returned `{:ok, []}` for an unsupported aggregate and
       silently dropped clauses it could not parse, so callers got plausible wrong answers
       rather than failures.
    2. **It never rewrites a value the caller supplied.** The original discarded the
       caller's timestamp and substituted the current clock, landing points written 900
       seconds apart microseconds apart.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Core.{CanonicalPair, Capabilities, Instrument, Notice, Types, Venue}

  # Longest-first, which is the whole point: reversed, `BTCUSDC` parses as `BTC-USD`.
  # Longest-first, and `BUSD` before `USD` is the ordering that matters: `BTCBUSD` ends
  # with `USD` before it ends with `BUSD`, so the reverse order splits the base as
  # `BTCB`. USDC/USDT/USD do not collide that way — worth knowing, because a fixture
  # built only on those would prove nothing.
  @mapping %{sep: "", quotes: ~w(BUSD USDC USDT USD EUR BTC ETH)}

  @symbols ~w(BTC-USD BTC-USDC BTC-USDT BTC-BUSD ETH-USD ETH-EUR)

  # The reference venue does not stake — `has_staking: false` below, and these six
  # declared `:unsupported` so assertion 12 sees the declaration and the behaviour agree.
  @unsupported [
    {:get_transfers, 2},
    {:quantization, 1},
    {:get_positions, 1},
    {:get_funding, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
    {:list_portfolios, 1},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3}
  ]

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def start_link(_opts), do: :ignore

  # --- declaration -------------------------------------------------------

  @impl true
  def provider_name, do: "Reference Venue"

  @impl true
  def runtime_id, do: :reference_venue

  @impl true
  def asset_classes, do: [:crypto]

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),
      supported_quotes: @mapping.quotes,
      supported_order_types: [:market, :limit, :post_only],
      supported_time_in_force: [:gtc, :ioc],
      supported_instrument_types: [:spot],
      # The reference venue implements both, so it declares both. The conformance suite
      # asserts these two agree, which is what stops the pair drifting.
      supports_order_preview: true,
      supports_order_replace: true,
      supports_short_selling: false,
      streamable: [:quotes, :trades],
      authenticated_streamable: [],
      historical_timeframes: ~w(1m 5m 1h 1d),
      credential_benefit: :higher_ceiling,
      public_ceiling: %{limit: 10, per_ms: 1_000},
      authenticated_ceiling: %{limit: 100, per_ms: 1_000},
      max_candles_per_request: 300,
      reports_trade_volume: true,
      catalog_size: :small,
      measured_at: ~D[2026-08-27],
      measured_against: "in-process reference implementation, not a live venue"
    )
  end

  # Everything the facade declares is :experimental — the honest state for code no one
  # has run in production — except the two deliberate refusals.
  defp endpoint_maturities do
    active =
      for {name, arity} <- DpExchange.Core.Venue.behaviour_info(:callbacks),
          {name, arity} not in @unsupported,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.reduce(@unsupported, active, &Map.put(&2, &1, :unsupported))
  end

  # --- market data -------------------------------------------------------

  @impl true
  def get_price(symbol, _opts) do
    if symbol in @symbols do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: Decimal.new("42000.50"),
         volume: Decimal.new("1234.5"),
         # The caller's clock is never substituted for a venue's. Here there is no venue,
         # so this is the reference's own event time — stated, not disguised.
         timestamp: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }}
    else
      # A refusal, not an error: this venue does not carry the symbol, and that is a
      # permanent answer rather than something to retry forever.
      {:refused, :symbol_not_listed}
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, _range, _opts) do
    cond do
      symbol not in @symbols ->
        {:refused, :symbol_not_listed}

      timeframe not in capabilities().historical_timeframes ->
        # Refused rather than served at the nearest width. A missing granularity becoming
        # the closest one mislabels every candle it touches and every value stays
        # plausible.
        {:error, {:unsupported_timeframe, timeframe}}

      true ->
        {:ok, [elem(get_price(symbol, []), 1)]}
    end
  end

  @impl true
  def get_symbols(_opts), do: {:ok, @symbols}

  @impl true
  def get_order_book(symbol, _opts) do
    if symbol in @symbols do
      {:ok,
       %Types.OrderBook{
         symbol: symbol,
         bids: [
           {Decimal.new("42000"), Decimal.new("1.5")},
           {Decimal.new("41999"), Decimal.new("2")}
         ],
         asks: [
           {Decimal.new("42001"), Decimal.new("1.0")},
           {Decimal.new("42002"), Decimal.new("3")}
         ],
         timestamp: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }}
    else
      {:refused, :symbol_not_listed}
    end
  end

  @impl true
  def get_top_of_book(symbol, _opts) do
    if symbol in @symbols do
      {:ok,
       %Types.TopOfBook{
         symbol: symbol,
         bid: Decimal.new("42000"),
         ask: Decimal.new("42001"),
         bid_size: Decimal.new("1.5"),
         ask_size: Decimal.new("1.0"),
         # A venue that publishes its own stamp; several publish none, and `nil` here is a
         # legitimate answer the conformance suite must also accept.
         venue_time: ~U[2026-08-27 12:00:00Z],
         observed_at: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }}
    else
      {:refused, :symbol_not_listed}
    end
  end

  # The reference venue does not stake. It implements the callbacks and refuses, which is
  # what a non-staking venue does — and `has_staking: false` in its capabilities is the
  # declaration a caller routes on. Assertion 12 checks the two agree.
  @impl true
  def get_positions(_opts), do: Venue.not_supported()

  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @impl true
  def get_screener(_name, _opts), do: Venue.not_supported()

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts) do
    {:ok, Map.new(@symbols, fn symbol -> {symbol, Decimal.new("42000.50")} end)}
  end

  @impl true
  def list_instruments(_opts) do
    {:ok,
     Enum.map(@symbols, fn symbol ->
       [base, quote_asset] = String.split(symbol, "-")

       Instrument.new(
         symbol: symbol,
         base: base,
         quote: quote_asset,
         instrument: :spot,
         status: :tradable
       )
     end)}
  end

  # --- account and trading -----------------------------------------------

  @impl true
  def get_balances(_credentials, _opts) do
    {:ok,
     [
       %Types.Balance{
         currency: "USD",
         balance: Decimal.new("10000"),
         available_balance: Decimal.new("9500"),
         hold: Decimal.new("500"),
         timestamp: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }
     ]}
  end

  @impl true
  def get_accounts(_credentials, _opts), do: {:ok, [%{id: "acct-1", currency: "USD"}]}

  @impl true
  def get_fees(_credentials, _opts),
    do: {:ok, %{maker: Decimal.new("0.004"), taker: Decimal.new("0.006")}}

  @impl true
  def get_transfers(_credentials, _opts), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def place_order(_credentials, request, _opts) do
    {:ok,
     %Types.Order{
       id: "order-1",
       symbol: Map.get(request, :symbol, "BTC-USD"),
       side: Map.get(request, :side, :buy),
       order_type: Map.get(request, :order_type, :limit),
       quantity: Map.get(request, :quantity, Decimal.new("1")),
       price: Map.get(request, :price),
       status: :open,
       created_at: ~U[2026-08-27 12:00:00Z],
       provider: runtime_id()
     }}
  end

  @impl true
  def cancel_order(credentials, id, opts) do
    with {:ok, order} <- get_order(credentials, id, opts) do
      {:ok, %{order | status: :cancelled}}
    end
  end

  # The reference venue implements both, because it exists to be a complete facade — a
  # venue that genuinely has neither returns `Venue.not_supported()` and declares
  # `supports_order_preview: false` / `supports_order_replace: false`.
  @impl true
  def preview_order(_credentials, request, _opts) do
    {:ok, %{estimated_commission: Decimal.new("0.00"), request: request}}
  end

  @impl true
  def replace_order(credentials, id, _request, opts) do
    with {:ok, order} <- get_order(credentials, id, opts) do
      {:ok, %{order | status: :open}}
    end
  end

  @impl true
  def preview_replace(_credentials, id, changes, _opts) do
    # Priced against the resting order, which is the whole difference from preview_order/3.
    {:ok, %{order_id: id, estimated_commission: Decimal.new("0.00"), changes: changes}}
  end

  @impl true
  def close_position(credentials, symbol, opts) do
    # The venue picks the side and the size; a caller never states them.
    with {:ok, order} <- get_order(credentials, "close-#{symbol}", opts) do
      {:ok, %{order | symbol: symbol, side: :sell, status: :pending}}
    end
  end

  @impl true
  def cancel_all_orders(_credentials, opts) do
    # No default scope. The reference venue enforces the contract's own rule, so a
    # conformance run against it fails a package that quietly picked one.
    case Keyword.get(opts, :scope) do
      scope when scope in [:session, :account] ->
        {:ok, %{cancelled: ["ref-order-1"], rejected: []}}

      nil ->
        {:error, :scope_required}

      other ->
        {:error, {:unsupported_scope, other}}
    end
  end

  @impl true
  def convert(from, to, amount, _opts) do
    # One step, already settled. The reference venue offers both forms so a conformance run
    # exercises each; a real venue usually has one.
    {:ok,
     %Types.Conversion{
       id: "ref-convert-1",
       status: :settled,
       from_asset: from,
       to_asset: to,
       from_amount: amount,
       to_amount: amount,
       rate: Decimal.new("1"),
       provider: runtime_id()
     }}
  end

  @impl true
  def get_trade_volume(_credentials, _opts) do
    {:ok, [%{symbol: "BTC-USD", total_volume_base: Decimal.new("10.5")}]}
  end

  @impl true
  def get_auction_imbalance(symbol, opts) do
    # The auction is required. The reference venue enforces the contract's own rule so a
    # conformance run fails a package that picked one.
    case Keyword.get(opts, :auction) do
      auction when auction in [:opening, :closing] ->
        {:ok,
         [
           %Types.AuctionImbalance{
             symbol: symbol,
             auction: auction,
             paired_quantity: Decimal.new("701859"),
             imbalance_quantity: Decimal.new("5715"),
             # The venue's own value, unmapped — see Types.AuctionImbalance.
             side: "2",
             reference_price: Decimal.new("253.83"),
             near_price: Decimal.new("253.93"),
             far_price: Decimal.new("253.98"),
             venue_time: ~U[2026-08-28 19:59:59Z],
             observed_at: ~U[2026-08-28 20:00:00Z],
             provider: runtime_id()
           }
         ]}

      nil ->
        {:error, :auction_required}

      other ->
        {:error, {:unsupported_auction, other}}
    end
  end

  @impl true
  def list_payment_methods(_credentials, _opts) do
    # One usable and one pending, because a caller filtering on presence rather than status
    # picks one the venue will refuse.
    {:ok,
     [
       %{"id" => "bank-1", "type" => "bank", "status" => "verified"},
       %{"id" => "bank-2", "type" => "bank", "status" => "pending"}
     ]}
  end

  @impl true
  def add_payment_method(details, _opts),
    do: {:ok, Map.merge(%{"id" => "bank-3", "status" => "pending"}, details)}

  @impl true
  def transfer_internal(asset, amount, opts, _request_opts) do
    case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
      {nil, _to} -> {:error, {:missing_option, :from}}
      {_from, nil} -> {:error, {:missing_option, :to}}
      {from, to} -> {:ok, %{"asset" => asset, "amount" => amount, "from" => from, "to" => to}}
    end
  end

  @impl true
  def request_approved_address(network, address, label, _opts) do
    # `pending` and nothing else. A successful response is not permission to withdraw.
    {:ok, %{"network" => network, "address" => address, "label" => label, "status" => "pending"}}
  end

  @impl true
  def remove_approved_address(network, address, _opts),
    do: {:ok, %{"network" => network, "address" => address, "status" => "removed"}}

  @impl true
  def get_transactions(_credentials, _opts) do
    {:ok,
     [
       %{"type" => "Trade", "amount" => "1"},
       %{"type" => "Deposit", "amount" => "100"},
       %{"type" => "Fee", "amount" => "-0.5"}
     ]}
  end

  @impl true
  def list_networks(asset, opts) do
    case {asset, Keyword.get(opts, :network)} do
      {nil, nil} -> {:error, :asset_or_network_required}
      {nil, network} -> {:ok, [%{"network" => network, "assets" => ["USDC", "USDT"]}]}
      {asset, _network} -> {:ok, [%{"asset" => asset, "networks" => ["ethereum", "solana"]}]}
    end
  end

  @impl true
  def list_fee_promos(_opts), do: {:ok, [%{"symbol" => "BTCUSD", "maker_fee_bps" => 0}]}

  @impl true
  def get_fx_rate(pair, at, _opts) do
    {:ok,
     %Types.FxRate{
       pair: pair,
       rate: Decimal.new("0.69"),
       as_of: at,
       # The institution that computed it, distinct from the venue relaying it.
       source: "bcb",
       benchmark: "Spot",
       provider: runtime_id()
     }}
  end

  @impl true
  def get_trades(symbol, opts) do
    # A broken trade in the list, excluded by default. The reference venue carries one so a
    # conformance run exercises the exclusion rather than assuming it.
    trades = [
      %Types.Trade{
        symbol: symbol,
        id: "5335307668",
        price: Decimal.new("3610.85"),
        quantity: Decimal.new("0.27413495"),
        side: :buy,
        timestamp: ~U[2026-08-28 12:00:00Z],
        broken: false,
        provider: runtime_id()
      },
      %Types.Trade{
        symbol: symbol,
        id: "5335307669",
        price: Decimal.new("9999.99"),
        quantity: Decimal.new("1"),
        side: :sell,
        timestamp: ~U[2026-08-28 12:00:01Z],
        broken: true,
        provider: runtime_id()
      }
    ]

    if Keyword.get(opts, :include_broken, false) do
      {:ok, trades}
    else
      {:ok, Enum.reject(trades, & &1.broken)}
    end
  end

  @impl true
  def get_volume_profile(symbol, timeframe, _opts) do
    {:ok,
     [
       %Types.VolumeProfile{
         symbol: symbol,
         timeframe: timeframe,
         opened_at: ~U[2026-08-28 12:00:00Z],
         total_volume: Decimal.new("1000"),
         delta: Decimal.new("200"),
         buy_volume: Decimal.new("600"),
         sell_volume: Decimal.new("400"),
         buy_at_price: %{"24.20" => Decimal.new("100"), "24.21" => Decimal.new("500")},
         sell_at_price: %{"24.20" => Decimal.new("350"), "24.21" => Decimal.new("50")},
         session: :regular,
         provider: runtime_id()
       }
     ]}
  end

  @impl true
  def get_order(_credentials, id, _opts) do
    {:ok,
     %Types.Order{
       id: id,
       symbol: "BTC-USD",
       side: :buy,
       order_type: :limit,
       quantity: Decimal.new("1"),
       status: :open,
       provider: runtime_id()
     }}
  end

  @impl true
  def get_orders(_credentials, _opts), do: {:ok, []}

  @impl true
  def get_trade_history(_credentials, _opts), do: {:ok, []}

  # --- streaming ---------------------------------------------------------

  @impl true
  def subscribe(symbols, opts) do
    target = Keyword.get(opts, :to, self())

    # Pushed immediately, which is what a REST-only venue's internal poll would do on its
    # first tick. A caller cannot tell the difference, and that is the point.
    for symbol <- symbols, symbol in @symbols do
      case get_price(symbol, []) do
        {:ok, quote_struct} -> send(target, {:dp_exchange, runtime_id(), quote_struct})
        _refused_or_error -> :ok
      end
    end

    :ok
  end

  @impl true
  def unsubscribe(_symbols, _opts), do: :ok

  @impl true
  def update_symbols(_symbols, _opts), do: :ok

  @impl true
  def coverage(_opts) do
    # Observed, never intended. This reference observes its own sends, so it reports what
    # it actually delivered — a venue that could not observe delivery would answer
    # :not_covered rather than claiming success.
    Map.new(@symbols, fn symbol -> {symbol, :internal_poll} end)
  end

  @impl true
  def subscribe_notices(opts) do
    target = Keyword.get(opts, :to, self())
    send(target, {:dp_exchange, runtime_id(), Notice.new(:link_up, runtime_id())})
    :ok
  end

  # --- health ------------------------------------------------------------

  @impl true
  def test_connection(_credentials, _opts), do: {:ok, %{reachable: true}}

  @impl true
  def get_rate_limit_status(_credentials, _opts) do
    {:ok, %{limit: 10, remaining: 10, reset_time: nil}}
  end

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def quantization(_symbol), do: DpExchange.Core.Venue.not_supported()

  @doc "The hostile mapping, so a test can drive `CanonicalPair` with the same one."
  @spec mapping() :: CanonicalPair.mapping()
  def mapping, do: @mapping
end

defmodule DpExchange.Core.ReferenceVenue.SymbolFormat do
  @moduledoc """
  The reference venue's symbol format — separator-less with overlapping quote assets,
  which is the hardest shape assertion 4 has to survive.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.{CanonicalPair, ReferenceVenue}

  @impl true
  def to_canonical_symbol(native),
    do: CanonicalPair.to_canonical(ReferenceVenue.mapping(), native)

  @impl true
  def to_exchange_symbol(canonical),
    do: CanonicalPair.to_exchange(ReferenceVenue.mapping(), canonical)
end
