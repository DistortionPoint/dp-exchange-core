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

  ## What it does NOT show: a subscriber's life

  `subscribe/2` here delivers once, synchronously, to the caller and keeps no subscriber
  set, so there is nothing to monitor, prune or double-deliver. **A real feed is not
  like that and must not be copied from this.** It keeps a feed-wide subscriber set and
  symbol set; it monitors a pid subscriber once (`DpExchange.Core.Fanout.watch/2`, a no-op
  for a pid already watched, so a second `subscribe` of the same pid never doubles delivery);
  it drops a dead pid on `:DOWN` (`Fanout.forget/2`) and releases the venue-side
  subscription when the set empties; and it filters on the live symbol set at send time, so
  a frame for a just-unsubscribed symbol is not sent. See `usage-rules/feeds.md`.

  ## What it refuses, and why that is the interesting part

  It declares `{:get_transfers, 2}` and `{:quantization, 1}` as `:unsupported` and returns
  `{:error, :not_supported}` — **the atom** — from both, so the bidirectional agreement
  assertion has something real to check in each direction. A fake where everything works
  proves only half the contract.

  ## The two rules it follows, from thirteen real bug reports

  Most of the bugs found in a comparable in-process fake were the fake diverging from the
  real client. (An earlier version of this note gave counts, "eleven of thirteen, six loud
  and three silent", that do not add up; the source is not recorded here, so only the shape
  is kept.) Some were *loud* — the fake rejecting what the real thing accepts — and some
  *silent*, which are the dangerous kind. So:

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

  alias DpExchange.Core.{CanonicalPair, Capabilities, Config, Instrument, Options, Types, Venue}

  # Longest-first, which is the whole point: reversed, `BTCUSDC` parses as `BTC-USD`.
  # Longest-first, and `BUSD` before `USD` is the ordering that matters: `BTCBUSD` ends
  # with `USD` before it ends with `BUSD`, so the reverse order splits the base as
  # `BTCB`. USDC/USDT/USD do not collide that way — worth knowing, because a fixture
  # built only on those would prove nothing.
  @mapping %{sep: "", quotes: ~w(BUSD USDC USDT USD EUR BTC ETH)}

  @symbols ~w(BTC-USD BTC-USDC BTC-USDT BTC-BUSD ETH-USD ETH-EUR)

  # What `subscribe/2` has actually delivered in THIS process — see `coverage/1`.
  @covered_key {__MODULE__, :covered}

  # A call that sends no request reads its own keys and `:credentials` only
  # (`DpExchange.Core.Options`, "What is allowed"); group 46 holds it.
  @no_request_options [:to, :feed, :credentials]

  # The orders this process has placed, `%{id => Types.Order}`. A fake that answers any id it is
  # asked about has invented an order nobody placed (venue rule W6): an unknown id is
  # `{:refused, :not_found}`, as on the real path. Process-scoped, like `@covered_key`, for the
  # same reason: the suite runs `async: true`. Never evicted: it lives and dies with the test
  # process that placed the orders, which is the only reason that is acceptable. A venue that
  # keeps orders for a long-lived process bounds them.
  @orders_key {__MODULE__, :orders}

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
  # The reference implementation of assertion 22, and it is here because the assertion
  # caught THIS module first (dp-exchange-core issue #29). A supervisor stores the
  # `{module, :start_link, [opts]}` MFA a child spec names, and OTP writes that argument
  # list through `inspect/1` into the `Start Call:` line of the report it logs on any child
  # termination — so a raw credentials map is a live secret in the application log after any
  # crash. Wrapping has to happen HERE: by the time `start_link/1` or `init/1` runs, the
  # supervisor above has already captured the raw list.
  def child_spec(opts) do
    opts =
      case Keyword.fetch(opts, :credentials) do
        {:ok, credentials} when is_map(credentials) ->
          Keyword.put(opts, :credentials, struct(__MODULE__.Credentials, credentials))

        _absent_or_not_a_map ->
          opts
      end

    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  defmodule Credentials do
    @moduledoc """
    A redacting credentials wrapper — the shape every venue package is expected to have.

    `except:`, never `only:`: `only:` prints any field added later by default, which is the
    wrong direction for a struct whose entire purpose is not printing things.

    `Kernel.struct/2` drops keys this struct does not declare, so a key it has never heard
    of cannot leak through either — it is gone, not merely unprinted.
    """
    @derive {Inspect, except: [:api_key, :api_secret, :private_key, :access_token]}
    defstruct [:api_key, :api_secret, :private_key, :access_token]
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
  def get_price(symbol, opts) do
    # A symbol that is not text is refused locally, before anything else: the family
    # convention (`Core.Venue.get_price/2`), held by conformance assertion 33. Then the
    # options (group 43): this read has none of its own.
    with :ok <- check_symbol(symbol),
         :ok <- Options.check(opts, Options.transport_options()) do
      priced(symbol)
    end
  end

  defp priced(symbol) do
    if symbol in @symbols do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: Decimal.new("42000.50"),
         volume: Decimal.new("1234.5"),
         volume_window: :running_total,
         # The caller's clock is never substituted for a venue's. Here there is no venue,
         # so this is the reference's own event time — stated, not disguised.
         venue_time: ~U[2026-08-27 12:00:00Z],
         observed_at: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }}
    else
      # A refusal, not an error: this venue does not carry the symbol, and that is a
      # permanent answer rather than something to retry forever.
      {:refused, :not_listed}
    end
  end

  # `nil`, a non-string and a blank string are `{:invalid_symbol, value}`, decided before any
  # lookup. A well-formed string the venue does not list is a different answer (a refusal).
  defp check_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  defp check_symbol(other), do: {:error, {:invalid_symbol, other}}

  # An order id, by the same rule: `nil`, a non-string or a blank one is refused locally.
  defp check_order_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_order_id, id}}, else: :ok
  end

  defp check_order_id(other), do: {:error, {:invalid_order_id, other}}

  # The options of a call that sends no request: its own keys and `:credentials` only
  # (`DpExchange.Core.Options`, "What is allowed"), checked after the positional arguments and
  # before the credentials. Group 43 holds it for every endpoint.
  defp check_options(opts, own \\ []), do: Options.check(opts, [:credentials | own])

  # An amount is a `Decimal`, an integer or a numeric string, finite and above zero. A float
  # has already lost digits; zero, a negative, NaN and infinity are not amounts. Anything else
  # is `{:invalid_amount, value}` with the value as the caller gave it (venue rule W4).
  defp check_amount(value) when is_float(value), do: {:error, {:invalid_amount, value}}

  defp check_amount(value) do
    with {:ok, decimal} <- cast_amount(value),
         true <- readable?(decimal),
         true <- Decimal.gt?(decimal, 0) do
      {:ok, decimal}
    else
      _invalid -> {:error, {:invalid_amount, value}}
    end
  end

  # An order the venue has no record of is a permanent answer, not an error (`cancel_order/3`).
  defp fetch_order(id) do
    case Map.fetch(Process.get(@orders_key, %{}), id) do
      {:ok, order} -> {:ok, order}
      :error -> {:refused, :not_found}
    end
  end

  defp remember_order(%Types.Order{id: id} = order) do
    Process.put(@orders_key, Map.put(Process.get(@orders_key, %{}), id, order))
    order
  end

  defp next_order_id, do: "order-#{System.unique_integer([:positive])}"

  # A symbol list is a proper list of non-blank strings, else `{:invalid_symbols, value}`.
  # Returns the list upper-cased, as every real facade does (assertion 29).
  defp check_symbols(symbols) do
    if proper_list?(symbols) and Enum.all?(symbols, &match?(:ok, check_symbol(&1))),
      do: {:ok, Enum.map(symbols, &String.upcase/1)},
      else: {:error, {:invalid_symbols, symbols}}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  # A subscriber is a pid or an atom other than `nil`, `true` and `false`; `nil` has already
  # been resolved to the caller by `Config.opt/3`.
  defp check_subscriber(to) when is_pid(to), do: {:ok, to}
  defp check_subscriber(to) when is_atom(to) and to not in [nil, true, false], do: {:ok, to}
  defp check_subscriber(to), do: {:error, {:invalid_subscriber, to}}

  @impl true
  def get_historical_prices(symbol, timeframe, range, opts) do
    cond do
      match?({:error, _reason}, check_symbol(symbol)) ->
        check_symbol(symbol)

      # The positional range, before the options: `{:invalid_range, range}` is a malformed
      # `:start`/`:end` (`Core.Venue`, "Errors decided locally"). It used to be read with
      # `Keyword.get/2`, which raised on a non-list and handed a non-`DateTime` to
      # `DateTime.compare/2`, so the worked example every author copies raised where every
      # real facade refuses.
      match?({:error, _reason}, check_range(range)) ->
        check_range(range)

      match?({:error, _reason}, historical_options(opts)) ->
        historical_options(opts)

      not is_boolean(Keyword.get(opts, :include_partial, false)) ->
        {:error, {:invalid_option, :include_partial, Keyword.get(opts, :include_partial)}}

      # MD4: this venue has no bar-count parameter, so `:limit` is refused, never accepted
      # and ignored. It used to be ignored, in the worked example every author copies.
      Keyword.has_key?(opts, :limit) ->
        {:error, {:unsupported_option, :limit}}

      symbol not in @symbols ->
        {:refused, :not_listed}

      timeframe not in capabilities().historical_timeframes ->
        # Refused rather than served at the nearest width. A missing granularity becoming
        # the closest one mislabels every candle it touches and every value stays
        # plausible.
        {:error, {:unsupported_timeframe, timeframe}}

      true ->
        # **A `Candle`, not a `Quote`.** This returned `[elem(get_price(symbol, []), 1)]` — a
        # one-element list holding a `Types.Quote` — from a callback `Core.Venue` types as
        # `result([Types.Candle.t()])`. A consumer reading `bar.open` or `bar.opened_at` off
        # the worked example every venue author copies got a struct that has neither. Caught
        # by assertion 5 on its first run, once 5 had a check of its own.
        {:ok, %Types.Quote{price: price, venue_time: at}} = get_price(symbol, [])

        bar = %Types.Candle{
          symbol: symbol,
          timeframe: timeframe,
          # On the width's own grid (MD2): the bar that contains the price's time, so a "1d"
          # request is answered with a bar opening at 00:00 and not at the quote's 12:00.
          opened_at: DpExchange.Core.Timeframe.boundary(at, timeframe),
          open: price,
          high: price,
          low: price,
          close: price,
          volume: nil,
          provider: runtime_id()
        }

        {:ok, Enum.filter([bar], &in_range?(&1.opened_at, range))}
    end
  end

  # A keyword list whose `:start` and `:end`, when present and not `nil`, are `DateTime`s with
  # `:start` before `:end`. Anything else is `{:invalid_range, range}`, the range as given.
  defp check_range(range) do
    with true <- is_list(range) and Keyword.keyword?(range),
         start = Keyword.get(range, :start),
         finish = Keyword.get(range, :end),
         true <- time_or_nil?(start) and time_or_nil?(finish),
         true <- is_nil(start) or is_nil(finish) or DateTime.compare(start, finish) == :lt do
      :ok
    else
      _malformed -> {:error, {:invalid_range, range}}
    end
  end

  defp time_or_nil?(value), do: is_nil(value) or is_struct(value, DateTime)

  # Its own keys: `:limit` is known (and then refused as unsupported, MD4).
  defp historical_options(opts),
    do: Options.check(opts, [:include_partial, :limit | Options.transport_options()])

  # `:start` inclusive, `:end` exclusive, on `opened_at` (MD2).
  defp in_range?(at, range) do
    start = Keyword.get(range, :start)
    finish = Keyword.get(range, :end)

    (is_nil(start) or DateTime.compare(at, start) != :lt) and
      (is_nil(finish) or DateTime.compare(at, finish) == :lt)
  end

  @impl true
  def get_symbols(opts) do
    with :ok <- Options.check(opts, Options.transport_options()) do
      {:ok, @symbols}
    end
  end

  @impl true
  def get_order_book(symbol, opts) do
    with :ok <- check_symbol(symbol),
         :ok <- Options.check(opts, [:depth, :limit | Options.transport_options()]),
         {:ok, depth} <- check_depth(Keyword.get(opts, :depth)) do
      booked(symbol, depth)
    end
  end

  # `:depth` is levels per side (MD5): absent, or a whole number of levels the venue carries
  # (it carries two a side). Anything else, above the maximum included, is refused rather than
  # clamped or raised on, as `Core.Venue` states. `:limit` has no use here and is ignored.
  defp check_depth(nil), do: {:ok, nil}
  defp check_depth(depth) when depth in 1..2//1, do: {:ok, depth}
  defp check_depth(depth), do: {:error, {:invalid_option, :depth, depth}}

  defp booked(symbol, depth) do
    if symbol in @symbols do
      {:ok,
       %Types.OrderBook{
         symbol: symbol,
         bids: Enum.take(levels(["42000", "1.5"], ["41999", "2"]), depth || 2),
         asks: Enum.take(levels(["42001", "1.0"], ["42002", "3"]), depth || 2),
         venue_time: ~U[2026-08-27 12:00:00Z],
         observed_at: ~U[2026-08-27 12:00:00Z],
         provider: runtime_id()
       }}
    else
      {:refused, :not_listed}
    end
  end

  defp levels(first, second) do
    for [price, size] <- [first, second], do: {Decimal.new(price), Decimal.new(size)}
  end

  @impl true
  def get_top_of_book(symbol, opts) do
    with :ok <- check_symbol(symbol),
         :ok <- Options.check(opts, Options.transport_options()) do
      top_of(symbol)
    end
  end

  defp top_of(symbol) do
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
      {:refused, :not_listed}
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
  def get_market_overview(opts) do
    with :ok <- check_options(opts) do
      {:ok, Map.new(@symbols, fn symbol -> {symbol, Decimal.new("42000.50")} end)}
    end
  end

  @impl true
  def list_instruments(opts) do
    with :ok <- check_options(opts) do
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
  end

  # --- account and trading -----------------------------------------------

  @impl true
  def get_balances(credentials, opts) do
    with :ok <- check_options(opts),
         :ok <- check_credentials(credentials) do
      {:ok, balances()}
    end
  end

  # A credential value with surrounding whitespace or a control character is refused before
  # anything is signed, as `{:invalid_credentials, venue}` (the family convention, see
  # `DpExchange.Core.Venue`), and never echoed.
  defp check_credentials(credentials) when is_map(credentials) do
    padded? =
      Enum.any?(credentials, fn
        {_key, value} when is_binary(value) -> String.match?(value, ~r/\A\s|\s\z|[[:cntrl:]]/u)
        _other -> false
      end)

    if padded?, do: {:error, {:invalid_credentials, runtime_id()}}, else: :ok
  end

  defp check_credentials(_credentials), do: :ok

  defp balances do
    [
      %Types.Balance{
        currency: "USD",
        balance: Decimal.new("10000"),
        available_balance: Decimal.new("9500"),
        hold: Decimal.new("500"),
        timestamp: ~U[2026-08-27 12:00:00Z],
        provider: runtime_id()
      }
    ]
  end

  @impl true
  def get_accounts(_credentials, opts) do
    with :ok <- check_options(opts), do: {:ok, [%{id: "acct-1", currency: "USD"}]}
  end

  @impl true
  def get_fees(_credentials, opts) do
    with :ok <- check_options(opts),
         do: {:ok, %{maker: Decimal.new("0.004"), taker: Decimal.new("0.006")}}
  end

  @impl true
  def get_transfers(_credentials, _opts), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def place_order(_credentials, request, opts) do
    # The refusals of `Core.Venue.place_order/3`, in its order, before anything is built. The
    # order that comes back is the one asked for: a side atom (never the caller's string),
    # `Decimal` amounts, and no price on a market order (which is refused above, not dropped).
    # Its id is generated and unique per write (venue rule W6), and remembered, so the same
    # process can read and cancel it and no other id is known.
    with {:ok, plan} <- plan_order(request),
         :ok <- check_options(opts) do
      order =
        remember_order(%Types.Order{
          id: next_order_id(),
          symbol: plan.symbol,
          side: plan.side,
          order_type: plan.order_type,
          quantity: plan.quantity,
          price: plan.price,
          status: :open,
          created_at: ~U[2026-08-27 12:00:00Z],
          provider: runtime_id()
        })

      {:ok, order}
    end
  end

  @order_keys [
    :symbol,
    :side,
    :order_type,
    :time_in_force,
    :quantity,
    :price,
    :stop_price,
    :client_order_id
  ]

  defp plan_order(request) when is_map(request) do
    with :ok <- known_order_keys(request),
         :ok <- check_symbol(Map.get(request, :symbol)),
         {:ok, side} <- order_side(Map.get(request, :side)),
         {:ok, type} <- order_type(Map.get(request, :order_type)),
         :ok <- order_duration(type, Map.get(request, :time_in_force)),
         {:ok, quantity} <- order_amount(request, :quantity, true),
         :ok <- unused_price_fields(type, request),
         {:ok, price} <- order_amount(request, :price, type != :market),
         :ok <- order_client_id(Map.get(request, :client_order_id)) do
      {:ok,
       %{symbol: request.symbol, side: side, order_type: type, quantity: quantity, price: price}}
    end
  end

  defp plan_order(request), do: {:error, {:invalid_order_request, request}}

  defp known_order_keys(request) do
    case Enum.find(Map.keys(request), &(&1 not in @order_keys)) do
      nil -> :ok
      key -> {:error, {:unsupported_order_field, key}}
    end
  end

  defp order_side(side) when side in [:buy, :sell], do: {:ok, side}

  defp order_side(side) when is_binary(side) do
    case String.downcase(side) do
      "buy" -> {:ok, :buy}
      "sell" -> {:ok, :sell}
      _other -> {:error, {:invalid_side, side}}
    end
  end

  defp order_side(nil), do: {:error, {:missing_field, :side}}
  defp order_side(side), do: {:error, {:invalid_side, side}}

  defp order_type(nil), do: {:error, {:missing_field, :order_type}}
  defp order_type(type) when type in [:market, :limit, :post_only], do: {:ok, type}
  defp order_type(type), do: {:error, {:unsupported_order_type, type}}

  # Optional here (the reference sends no duration of its own), but one it is given must be
  # one its `capabilities/0` serves.
  defp order_duration(_type, nil), do: :ok
  defp order_duration(_type, tif) when tif in [:gtc, :ioc], do: :ok
  defp order_duration(type, tif), do: {:error, {:unsupported_order_combination, type, tif}}

  # A field the order type does not use is refused, never dropped.
  defp unused_price_fields(type, request) do
    cond do
      Map.get(request, :stop_price) != nil -> {:error, {:unexpected_field, :stop_price}}
      type == :market and Map.get(request, :price) != nil -> {:error, {:unexpected_field, :price}}
      true -> :ok
    end
  end

  # A `Decimal`, an integer or a numeric string above zero. A float has already lost digits.
  defp order_amount(request, key, required?) do
    case Map.get(request, key) do
      nil when required? -> {:error, {:missing_field, key}}
      nil -> {:ok, nil}
      value -> positive_amount(value, key)
    end
  end

  defp positive_amount(value, key) do
    with {:ok, decimal} <- cast_amount(value),
         true <- readable?(decimal),
         true <- Decimal.gt?(decimal, 0) do
      {:ok, decimal}
    else
      _invalid -> {:error, {invalid_tag(key), value}}
    end
  end

  # A number this venue will do arithmetic on: finite, and with an exponent `Types.Validate`
  # admits. `Decimal.gt?/2` aligns exponents with `10^difference`, so a caller's
  # `1e999999999` made the comparison allocate a number of that many digits, in the venue's
  # process, before any refusal. The bound is the one every `Core.Types.*` constructor holds.
  defp readable?(%Decimal{coef: coef, exp: exp}) do
    is_integer(coef) and abs(exp) <= Types.Validate.max_decimal_exponent()
  end

  defp cast_amount(%Decimal{} = decimal), do: {:ok, decimal}
  defp cast_amount(value) when is_integer(value) or is_binary(value), do: Decimal.cast(value)
  defp cast_amount(_other), do: :error

  defp invalid_tag(:quantity), do: :invalid_quantity
  defp invalid_tag(:price), do: :invalid_price

  defp order_client_id(nil), do: :ok

  defp order_client_id(id) when is_binary(id),
    do: if(String.trim(id) == "", do: {:error, {:invalid_client_order_id, id}}, else: :ok)

  defp order_client_id(id), do: {:error, {:invalid_client_order_id, id}}

  @impl true
  def cancel_order(credentials, id, opts) do
    # Only a working order is cancelled. A filled, cancelled, rejected or expired one is final:
    # answering `{:ok, order}` for it would report a cancel that did not happen (a filled order
    # told "cancelled" is a position the caller believes it does not hold), and overwriting its
    # status would turn a terminal state into another one.
    with {:ok, order} <- get_order(credentials, id, opts),
         :ok <- working(order, :order_not_cancellable) do
      {:ok, remember_order(%{order | status: :cancelled})}
    end
  end

  # The statuses of an order that is still live. Everything else is terminal and stays so.
  @working [:pending, :open, :partially_filled]

  defp working(%Types.Order{status: status}, _reason) when status in @working, do: :ok
  defp working(%Types.Order{status: status}, reason), do: {:refused, {reason, status}}

  # The reference venue implements both, because it exists to be a complete facade — a
  # venue that genuinely has neither returns `Venue.not_supported()` and declares
  # `supports_order_preview: false` / `supports_order_replace: false`.
  @impl true
  def preview_order(_credentials, request, opts) do
    # The request is checked exactly as `place_order/3` checks it, in its order, then the
    # options. It used to be echoed back unread, so a non-map or a request with no side was
    # priced.
    with {:ok, _plan} <- plan_order(request),
         :ok <- check_options(opts) do
      {:ok, %{estimated_commission: Decimal.new("0.00"), request: request}}
    end
  end

  @impl true
  def replace_order(credentials, id, changes, opts) do
    # The id as `cancel_order/3` checks it, then the change map (`plan_changes/1`), then the
    # options; the order must be one this process placed.
    with :ok <- check_order_id(id),
         {:ok, _plan} <- plan_changes(changes),
         {:ok, order} <- get_order(credentials, id, opts),
         :ok <- working(order, :order_not_replaceable) do
      # A terminal order is refused above, never re-opened: this used to set `:open` on a
      # cancelled order, which is a terminal state becoming a live one.
      {:ok, remember_order(%{order | status: :open})}
    end
  end

  @impl true
  def preview_replace(_credentials, id, changes, opts) do
    # Priced against the resting order, which is the whole difference from preview_order/3.
    # Its id and change map are held to the same rules as `replace_order/4`'s.
    with :ok <- check_order_id(id),
         {:ok, _plan} <- plan_changes(changes),
         :ok <- check_options(opts) do
      {:ok, %{order_id: id, estimated_commission: Decimal.new("0.00"), changes: changes}}
    end
  end

  # A change map is partial by nature: a field it leaves out is not checked and not required,
  # and every field it carries is judged by `place_order/3`'s rule for that field, a present
  # `nil` included. A non-map and an empty map change nothing, so they are
  # `{:invalid_order_request, changes}`. The ladder is `plan_order/1`'s, minus the checks that
  # need the whole order (a missing field; a price on a market order, which a change that does
  # not name the type cannot be judged on).
  defp plan_changes(changes) when is_map(changes) and map_size(changes) > 0 do
    with :ok <- known_order_keys(changes),
         :ok <- changed(changes, :symbol, &check_symbol/1),
         :ok <- changed(changes, :side, &order_side/1),
         :ok <- changed(changes, :order_type, &order_type/1),
         :ok <- changed(changes, :time_in_force, &changed_duration/1),
         :ok <- changed(changes, :quantity, &positive_amount(&1, :quantity)),
         :ok <- changed(changes, :stop_price, &unused_stop_price/1),
         :ok <- changed(changes, :price, &positive_amount(&1, :price)),
         :ok <- changed(changes, :client_order_id, &order_client_id/1) do
      {:ok, changes}
    end
  end

  defp plan_changes(changes), do: {:error, {:invalid_order_request, changes}}

  # Runs `validator` on the value of `key` when the change map carries it, `nil` included.
  defp changed(changes, key, validator) do
    case Map.fetch(changes, key) do
      :error -> :ok
      {:ok, value} -> accepted(validator.(value))
    end
  end

  defp accepted(:ok), do: :ok
  defp accepted({:ok, _checked}), do: :ok
  defp accepted({:error, _reason} = error), do: error

  # A duration on its own: the order type it rides on may not be in the change.
  defp changed_duration(tif) when tif in [:gtc, :ioc], do: :ok
  defp changed_duration(tif), do: {:error, {:unsupported_order_combination, :limit, tif}}

  # The reference venue serves no stop order, so a stop price is never a field it uses.
  defp unused_stop_price(_stop_price), do: {:error, {:unexpected_field, :stop_price}}

  @impl true
  def close_position(_credentials, symbol, opts) do
    # The venue picks the side and the size; a caller never states them. The suite opens no
    # position, so the order that closes one is minted here, with its own generated id.
    with :ok <- check_symbol(symbol),
         :ok <- check_options(opts) do
      order =
        remember_order(%Types.Order{
          id: next_order_id(),
          symbol: symbol,
          side: :sell,
          order_type: :market,
          quantity: Decimal.new("1"),
          status: :pending,
          provider: runtime_id()
        })

      {:ok, order}
    end
  end

  @impl true
  def cancel_all_orders(_credentials, opts) do
    # No default scope. The reference venue enforces the contract's own rule, so a
    # conformance run against it fails a package that quietly picked one.
    with :ok <- check_options(opts, [:scope]) do
      cancel_scope(Keyword.get(opts, :scope))
    end
  end

  # One order already gone in the session: a non-empty `rejected` is a partial success.
  defp cancel_scope(:session), do: {:ok, %{cancelled: ["ref-order-1"], rejected: ["ref-order-2"]}}
  defp cancel_scope(:account), do: {:ok, %{cancelled: ["ref-order-1"], rejected: []}}
  defp cancel_scope(nil), do: {:error, :scope_required}
  defp cancel_scope(other), do: {:error, {:unsupported_scope, other}}

  @impl true
  def convert(from, to, amount, opts) do
    # One step, already settled. The reference venue offers both forms so a conformance run
    # exercises each; a real venue usually has one. The amount is checked first (venue rule
    # W4) and comes back as the `Decimal` it was cast to.
    with {:ok, amount} <- check_amount(amount),
         :ok <- check_options(opts) do
      {:ok,
       %Types.Conversion{
         id: "ref-convert-#{System.unique_integer([:positive])}",
         status: :settled,
         from_asset: from,
         to_asset: to,
         from_amount: amount,
         to_amount: amount,
         rate: Decimal.new("1"),
         provider: runtime_id()
       }}
    end
  end

  @impl true
  def get_trade_volume(_credentials, opts) do
    with :ok <- check_options(opts) do
      {:ok, [%{symbol: "BTC-USD", total_volume_base: Decimal.new("10.5")}]}
    end
  end

  @impl true
  def get_auction_imbalance(symbol, opts) do
    # The auction is required. The reference venue enforces the contract's own rule so a
    # conformance run fails a package that picked one.
    # The symbol first, as every other single-symbol read here: a `nil`, non-string or blank
    # one is `{:invalid_symbol, value}` before the auction is looked at.
    with :ok <- check_symbol(symbol),
         :ok <- check_options(opts, [:auction]) do
      auction_imbalance(symbol, Keyword.get(opts, :auction))
    end
  end

  defp auction_imbalance(symbol, auction) do
    case auction do
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
  def list_payment_methods(_credentials, opts) do
    # One usable and one pending, because a caller filtering on presence rather than status
    # picks one the venue will refuse.
    with :ok <- check_options(opts) do
      {:ok,
       [
         %{"id" => "bank-1", "type" => "bank", "status" => "verified"},
         %{"id" => "bank-2", "type" => "bank", "status" => "pending"}
       ]}
    end
  end

  @impl true
  def add_payment_method(details, opts) do
    with :ok <- check_options(opts) do
      {:ok, Map.merge(%{"id" => "bank-3", "status" => "pending"}, details)}
    end
  end

  @impl true
  def place_orders(_credentials, requests, opts) do
    # One entry per request, and the second one refused. A batch that reported a single
    # ok-or-error would let a consumer ship code that believes "the batch failed" when four
    # of five were placed. Each id is generated, so none repeats across writes (venue rule W6).
    # A `requests` that is not a proper list is `{:invalid_argument, :requests}` (`Core.Venue`),
    # decided before the options; `Enum.with_index/1` raised on a non-list.
    with :ok <- check_requests(requests),
         :ok <- check_options(opts) do
      {:ok,
       requests
       |> Enum.with_index()
       |> Enum.map(fn
         {_request, 1} ->
           %{"error" => "INSUFFICIENT_BUYING_POWER"}

         {request, _index} ->
           %{"order_id" => next_order_id(), "symbol" => request[:symbol]}
       end)}
    end
  end

  defp check_requests(requests),
    do: if(proper_list?(requests), do: :ok, else: {:error, {:invalid_argument, :requests}})

  @impl true
  def get_payment_method(_credentials, id, opts) do
    with :ok <- check_options(opts) do
      {:ok, %{"id" => id, "status" => "verified", "type" => "bank"}}
    end
  end

  @impl true
  def get_notional_balances(_credentials, currency, opts) do
    # The quantity and its valuation are separate keys, and stay that way. Merging them is
    # the mistake the callback's doc is about.
    with :ok <- check_options(opts) do
      {:ok,
       [
         %{"currency" => "BTC", "amount" => "1", "amountNotional" => "40000", "in" => currency}
       ]}
    end
  end

  @impl true
  def list_custody_fees(_credentials, opts) do
    with :ok <- check_options(opts) do
      {:ok, [%{"currency" => "BTC", "amount" => "0.0001", "timestampms" => 1_700_000_000_000}]}
    end
  end

  @impl true
  def transfer_internal(asset, amount, opts, request_opts) do
    # The amount first (venue rule W4), then both option lists. `:from` and `:to` are the
    # transfer's own keys; the suite hands the same `endpoint_opts:` to both lists, so both are
    # checked against them. A transfer whose source is its destination is refused (W4).
    with {:ok, _decimal} <- check_amount(amount),
         :ok <- check_options(opts, [:from, :to]),
         :ok <- check_options(request_opts, [:from, :to]) do
      transfer(asset, amount, Keyword.get(opts, :from), Keyword.get(opts, :to))
    end
  end

  defp transfer(_asset, _amount, nil, _to), do: {:error, {:missing_option, :from}}
  defp transfer(_asset, _amount, _from, nil), do: {:error, {:missing_option, :to}}
  defp transfer(_asset, _amount, same, same), do: {:error, {:invalid_transfer, :same_account}}

  defp transfer(asset, amount, from, to),
    do: {:ok, %{"asset" => asset, "amount" => amount, "from" => from, "to" => to}}

  @impl true
  def request_approved_address(network, address, label, opts) do
    # `pending` and nothing else. A successful response is not permission to withdraw.
    with :ok <- check_options(opts) do
      {:ok,
       %{"network" => network, "address" => address, "label" => label, "status" => "pending"}}
    end
  end

  @impl true
  def remove_approved_address(network, address, opts) do
    with :ok <- check_options(opts) do
      {:ok, %{"network" => network, "address" => address, "status" => "removed"}}
    end
  end

  @impl true
  def get_transactions(_credentials, opts) do
    with :ok <- check_options(opts) do
      {:ok,
       [
         %{"type" => "Trade", "amount" => "1"},
         %{"type" => "Deposit", "amount" => "100"},
         %{"type" => "Fee", "amount" => "-0.5"}
       ]}
    end
  end

  @impl true
  def list_networks(asset, opts) do
    with :ok <- check_options(opts, [:network]) do
      networks_for(asset, Keyword.get(opts, :network))
    end
  end

  defp networks_for(nil, nil), do: {:error, :asset_or_network_required}

  defp networks_for(nil, network),
    do: {:ok, [%{"network" => network, "assets" => ["USDC", "USDT"]}]}

  defp networks_for(asset, _network),
    do: {:ok, [%{"asset" => asset, "networks" => ["ethereum", "solana"]}]}

  @impl true
  def list_fee_promos(opts) do
    with :ok <- check_options(opts) do
      {:ok, [%{"symbol" => "BTCUSD", "maker_fee_bps" => 0}]}
    end
  end

  @impl true
  def get_fx_rate(pair, at, opts) do
    with :ok <- check_options(opts) do
      fx_rate(pair, at)
    end
  end

  defp fx_rate(pair, at) do
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
    # The single-symbol order of checks (`Core.Venue`): the symbol first, then the options.
    # `:since` and `:limit` have no venue parameter here, so they are refused, never accepted
    # and ignored (MD4). All three used to be skipped: a blank symbol was answered with
    # trades stamped with it, and `include_broken: "no"` was read as true.
    cond do
      match?({:error, _reason}, check_symbol(symbol)) ->
        check_symbol(symbol)

      match?({:error, _reason}, trade_options(opts)) ->
        trade_options(opts)

      not is_boolean(Keyword.get(opts, :include_broken, false)) ->
        {:error, {:invalid_option, :include_broken, Keyword.get(opts, :include_broken)}}

      unsupported = Enum.find([:since, :limit], &Keyword.has_key?(opts, &1)) ->
        {:error, {:unsupported_option, unsupported}}

      symbol not in @symbols ->
        {:refused, :not_listed}

      true ->
        traded(symbol, Keyword.get(opts, :include_broken, false))
    end
  end

  # Its own keys: `:since` and `:limit` are known (and then refused as unsupported, MD4).
  defp trade_options(opts),
    do: Options.check(opts, [:include_broken, :since, :limit | Options.transport_options()])

  defp traded(symbol, include_broken?) do
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

    if include_broken? do
      {:ok, trades}
    else
      {:ok, Enum.reject(trades, & &1.broken)}
    end
  end

  @impl true
  def get_volume_profile(symbol, timeframe, opts) do
    # The positional arguments first, then the options (`Core.Venue`): a symbol that is not
    # text is `{:invalid_symbol, v}`, one the venue does not list is `{:refused, :not_listed}`,
    # and a width it does not serve is an error, never the nearest one (the callback's own
    # words). All three used to be skipped, so any symbol and any width was answered with a
    # profile stamped with them.
    with :ok <- check_symbol(symbol),
         :ok <- check_options(opts),
         :ok <- listed(symbol),
         :ok <- served_timeframe(timeframe) do
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
  end

  defp listed(symbol) do
    if symbol in @symbols, do: :ok, else: {:refused, :not_listed}
  end

  defp served_timeframe(timeframe) do
    if timeframe in capabilities().historical_timeframes,
      do: :ok,
      else: {:error, {:unsupported_timeframe, timeframe}}
  end

  @impl true
  def get_order(_credentials, id, opts) do
    # The id first: `nil`, a non-string or a blank one is `{:invalid_order_id, id}`, before
    # anything else is looked at; then the options. An id this process never placed is
    # `{:refused, :not_found}`, not an order made up for it (venue rule W6). `cancel_order/3`
    # and `replace_order/4` read through here.
    with :ok <- check_order_id(id),
         :ok <- check_options(opts) do
      fetch_order(id)
    end
  end

  @impl true
  def get_orders(_credentials, opts) do
    with :ok <- check_options(opts), do: {:ok, Map.values(Process.get(@orders_key, %{}))}
  end

  @impl true
  def get_trade_history(_credentials, opts) do
    # One fill, so the answer is something group 54 can judge and a consumer's test can read:
    # an empty list is a success that proves nothing about the `Fill` a venue returns.
    with :ok <- check_options(opts) do
      {:ok,
       [
         %Types.Fill{
           order_id: "ref-order-1",
           trade_id: "ref-fill-1",
           symbol: "BTC-USD",
           side: :buy,
           quantity: Decimal.new("0.5"),
           price: Decimal.new("42000.50"),
           fee: Decimal.new("10.50"),
           fee_currency: "USD",
           timestamp: ~U[2026-08-27 12:00:00Z],
           liquidity: :taker,
           provider: runtime_id()
         }
       ]}
    end
  end

  # --- streaming ---------------------------------------------------------

  @impl true
  def subscribe(symbols, opts) do
    # Arguments first, symbols before subscriber (assertion 32); upper-cased on the way in,
    # as every real facade does (assertion 29).
    # Then the options (group 46): no request is sent, so no transport key but
    # `:credentials` is read here.
    with {:ok, symbols} <- check_symbols(symbols),
         {:ok, target} <- check_subscriber(Config.opt(opts, :to, self())),
         :ok <- Options.check(opts, @no_request_options) do
      deliver_subscription(symbols, target)
    end
  end

  defp deliver_subscription(symbols, target) do
    # Pushed immediately, which is what a REST-only venue's internal poll would do on its
    # first tick. A caller cannot tell the difference, and that is the point.
    #
    # The symbols that actually got a send are recorded, and they are what `coverage/1`
    # reports. A symbol this reference does not list is not added — so coverage stays a
    # record of what was delivered rather than of what was asked for. A listed symbol is
    # always priced (`check_symbols/1` has already refused a blank one, and `priced/1`
    # answers every member of `@symbols`), so the match below cannot fail today; if
    # `get_price/2` ever refuses a listed symbol this raises instead of quietly dropping it.
    delivered =
      for symbol <- symbols, symbol in @symbols, reduce: [] do
        acc ->
          {:ok, quote_struct} = get_price(symbol, [])
          send(target, {:dp_exchange, runtime_id(), quote_struct})
          [symbol | acc]
      end

    Process.put(@covered_key, MapSet.union(covered(), MapSet.new(delivered)))

    :ok
  end

  @impl true
  def unsubscribe(symbols, opts) do
    # A malformed list is refused, never `:ok` (assertion 32); upper-cased on the way in, as
    # every real facade does (assertion 29). Then the options (group 43).
    with {:ok, symbols} <- check_symbols(symbols),
         :ok <- Options.check(opts, @no_request_options) do
      # Nothing arrives for an unsubscribed symbol, so nothing should be reported for it.
      Process.put(@covered_key, MapSet.difference(covered(), MapSet.new(symbols)))

      :ok
    end
  end

  @impl true
  def update_symbols(symbols, opts) do
    # The options before the live set is touched: a refused call leaves the set as it was.
    with {:ok, symbols} <- check_symbols(symbols),
         :ok <- Options.check(opts, @no_request_options) do
      replace_symbols(symbols, opts)
    end
  end

  defp replace_symbols(symbols, opts) do
    # **It used to be `:ok` and nothing else**, which made it indistinguishable from a
    # venue that had simply ignored the call — and left this reference implementing two of
    # the contract's three subscription operations. `c:DpExchange.Core.Venue.update_symbols/2`
    # REPLACES the live set, which is the whole difference between it and `subscribe/2`;
    # a reference where one of them does nothing teaches the next venue author that the
    # distinction does not matter.
    #
    # Caught by assertion 26 on the run that introduced it, the same way assertion 14
    # caught `coverage/1` reporting a constant. Both had been sitting here for as long as
    # nothing asked.
    Process.put(@covered_key, MapSet.new())
    subscribe(symbols, opts)
  end

  @impl true
  def coverage(_opts) do
    # **Observed, never intended — and it used to be neither.** This returned
    # `Map.new(@symbols, ...)`: every symbol this module knows about, reported as covered
    # whether or not anything had ever been subscribed, while the comment above it claimed
    # "this reference observes its own sends, so it reports what it actually delivered". It
    # observed nothing. It was a constant.
    #
    # That is the exact substitution `c:DpExchange.Core.Venue.coverage/1` exists to forbid —
    # a claim wearing the shape of an observation — sitting in the module every venue author
    # reads as the worked example, and in the fixture Core runs its own conformance suite
    # against. `Core.AdapterContract`'s assertion 14 could not catch it, because until the
    # same change that fixed this, that assertion iterated a map it never made non-empty and
    # so had never been able to fail on anything.
    #
    # Now it is what `subscribe/2` actually sent, minus what `unsubscribe/2` took away.
    Map.new(covered(), fn symbol -> {symbol, :internal_poll} end)
  end

  # Process-scoped, because the suite requires `async: true` safety and asserts
  # process-scoped isolation in its own assertion 13: two tests subscribing different
  # symbols at the same time must not see each other's coverage.
  defp covered, do: Process.get(@covered_key, MapSet.new())

  # What the caller asked to stream, as opposed to `coverage/1`'s observed delivery. This
  # reference delivers synchronously on subscribe, so the two sets are the same here.
  @impl true
  def wanted(_opts), do: covered()

  @impl true
  def subscribe_notices(opts) do
    # Registers and sends nothing: this reference has no feed, so it raises no notice, and a
    # `:link_up` on registration is one the real feeds do not send (family convention 9).
    with {:ok, _target} <- check_subscriber(Config.opt(opts, :to, self())),
         :ok <- Options.check(opts, @no_request_options) do
      :ok
    end
  end

  # --- health ------------------------------------------------------------

  @impl true
  def test_connection(_credentials, opts) do
    with :ok <- check_options(opts), do: {:ok, %{reachable: true}}
  end

  @impl true
  def get_rate_limit_status(_credentials, opts) do
    with :ok <- check_options(opts), do: {:ok, %{limit: 10, remaining: 10, reset_time: nil}}
  end

  @impl true
  def market_status(opts) do
    with :ok <- check_options(opts), do: {:ok, :open}
  end

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

defmodule DpExchange.Core.ReferenceVenue.ProcessProbe do
  @moduledoc """
  The reference venue's answer to group 51's `process_probe:`: a long-lived process that
  holds a credential for its lifetime, the way a venue's feed or socket does, started with
  no network. The credential is wrapped in the redacting `ReferenceVenue.Credentials` the
  moment it enters the process, which is the shape every venue package is expected to have.
  """

  use GenServer

  alias DpExchange.Core.ReferenceVenue.Credentials

  @doc "Starts the process from a credentials map. Named `start_link/1` so a supervisor can too."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(credentials) when is_map(credentials),
    do: GenServer.start_link(__MODULE__, credentials)

  @impl true
  def init(credentials), do: {:ok, %{credentials: struct(Credentials, credentials)}}
end
