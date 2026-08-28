defmodule DpExchange.Core.DataProvider do
  @moduledoc """
  Behavior defining the interface for cryptocurrency exchange data providers.

  This module provides a unified interface for interacting with different
  trading venues (Coinbase, Gemini, and the rest) while abstracting away
  the implementation details of each provider's API.
  """

  alias DpExchange.Core.{Capabilities, Instrument}

  @type symbol :: String.t()
  @type currency :: String.t()
  @type decimal_string :: String.t()
  @type timestamp :: DateTime.t()

  @type price_data :: %{
          symbol: symbol(),
          price: decimal_string(),
          volume: decimal_string() | nil,
          timestamp: timestamp(),
          provider: String.t()
        }

  @type balance_data :: %{
          currency: currency(),
          balance: decimal_string(),
          available_balance: decimal_string(),
          provider: String.t()
        }

  @type credentials :: %{
          api_key: String.t(),
          api_secret: String.t(),
          passphrase: String.t() | nil,
          sandbox: boolean()
        }

  @type rate_limit_info :: %{
          remaining: integer(),
          reset_time: timestamp(),
          limit: integer()
        }

  @type order_data :: %{
          id: String.t(),
          symbol: symbol(),
          # "buy" | "sell"
          side: String.t(),
          # "market" | "limit" | "stop" | "stop-limit"
          order_type: String.t(),
          quantity: decimal_string(),
          price: decimal_string() | nil,
          stop_price: decimal_string() | nil,
          # "pending" | "open" | "filled" | "cancelled" | "rejected"
          status: String.t(),
          filled_quantity: decimal_string(),
          remaining_quantity: decimal_string(),
          average_fill_price: decimal_string() | nil,
          fee: decimal_string(),
          created_at: timestamp(),
          updated_at: timestamp(),
          provider: String.t()
        }

  @type order_request :: %{
          symbol: symbol(),
          # "buy" | "sell"
          side: String.t(),
          # "market" | "limit" | "stop" | "stop-limit"
          order_type: String.t(),
          quantity: decimal_string(),
          price: decimal_string() | nil,
          stop_price: decimal_string() | nil,
          # "GTC" | "IOC" | "FOK"
          time_in_force: String.t() | nil,
          client_order_id: String.t() | nil
        }

  @type api_response :: {:ok, any()} | {:error, String.t()}
  @type api_response_with_rate_limit :: {:ok, any(), rate_limit_info()} | {:error, String.t()}

  @doc """
  Get current price data for a specific trading pair/symbol.

  ## Parameters
  - `symbol`: Trading pair symbol (e.g., "BTC-USD", "ETH-USD")
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, price_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback get_price(symbol(), keyword()) :: {:ok, price_data()} | {:error, String.t()}

  @doc """
  Get historical price data for a specific trading pair/symbol.

  ## Parameters
  - `symbol`: Trading pair symbol (e.g., "BTC-USD", "ETH-USD")
  - `start_time`: Start time for historical data
  - `end_time`: End time for historical data
  - `opts`: Optional parameters (granularity, etc.)

  ## Returns
  - `{:ok, [price_data()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_historical_prices(symbol(), DateTime.t(), DateTime.t(), keyword()) ::
              {:ok, [price_data()]} | {:error, String.t()}

  @doc """
  Get account balances for all currencies.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, [balance_data()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_balances(credentials(), keyword()) ::
              {:ok, [balance_data()]} | {:error, String.t()}

  @doc """
  Get available trading pairs/symbols supported by the provider.

  ## Parameters
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, [symbol()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_symbols(keyword()) :: {:ok, [symbol()]} | {:error, String.t()}

  @doc """
  Test API connectivity and authentication.

  ## Parameters
  - `credentials`: API credentials for authentication (optional for public endpoints)
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, :connected}` on successful connection
  - `{:error, reason}` on failure
  """
  @callback test_connection(credentials() | nil, keyword()) ::
              {:ok, :connected} | {:error, String.t()}

  @doc """
  Get current rate limit status for the API.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, rate_limit_info()}` on success
  - `{:error, reason}` on failure
  """
  @callback get_rate_limit_status(credentials(), keyword()) ::
              {:ok, rate_limit_info()} | {:error, String.t()}

  @typedoc """
  Asset class identifier. `:crypto` covers 24/7 spot and (when the
  provider supports it) margin crypto markets; `:equity` covers regular
  and extended US-equity sessions.
  """
  @type asset_class :: :crypto | :equity

  @doc """
  Get the provider name/identifier.

  ## Returns
  - Provider name as string (e.g., "coinbase", "gemini")
  """
  @callback provider_name() :: String.t()

  @doc """
  Runtime atom identifier for the provider — used by GenServer state
  trackers (DataCollectionManager, ProcessManager) that key by atom
  rather than string. Each adapter declares its own identifier so
  there is no central name→atom whitelist.

  Most adapters return `provider_name() |> String.downcase() |> String.to_atom()`
  shape. The mock provider returns `:mock_provider` for historical
  reasons (older code paths assumed the literal atom).
  """
  @callback runtime_id() :: atom()

  @doc """
  Asset classes this provider supports. Used by
  `Strategy.AccountCapabilities` to gate template recommendations and by
  the Strategy resource to reject configurations where the strategy's
  declared asset class isn't tradable on its credential's provider.

  Providers must return a non-empty list. A provider that supports both
  crypto and equity (e.g. Webull) returns `[:crypto, :equity]`; pure
  crypto exchanges return `[:crypto]`.
  """
  @callback asset_classes() :: [asset_class(), ...]

  @doc """
  Get supported features for this provider.

  ## Returns
  - Map of feature flags indicating what functionality is supported
  """
  @callback supported_features() :: %{
              websocket: boolean(),
              historical_data: boolean(),
              real_time_balances: boolean(),
              order_management: boolean()
            }

  @typedoc """
  Provider capabilities consumed by orchestration code (price collection,
  orderbook collector, indicator engine bootstrap, strategy bootstrap)
  to make routing decisions WITHOUT pattern-matching on provider name.

  This was a bare map carrying a `required(...)` contract, which Dialyzer checks
  but the compiler does not: an adapter that omitted a key compiled clean and the
  omission surfaced later as a `nil` reaching a routing decision. It is now
  `Exchanges.Core.Capabilities`, whose `@enforce_keys` turns that same omission
  into a compile error — which matters most for a NEW adapter, exactly the case
  this behaviour exists to protect. Consumers pattern-matching
  `%{supports_short_selling: x}` are unaffected: a struct matches a map pattern.

  Every new field added here must be answered by every provider — the
  whole point is that adding a provider should be a `git mv`-ready
  drop-in with zero edits in orchestration code.

  ## Fields

  * `:requires_credentials_for_public_data` — `true` when the provider
    rejects public quote/orderbook calls without API credentials. The
    orchestration layer uses the same code path for all providers
    (always attempts credential lookup); this flag is informational for
    diagnostics + admin UI hints.
  * `:has_rest_order_book` — `true` when the provider exposes a REST
    orderbook endpoint that `OrderbookCollector` can poll. When `false`,
    that path is skipped.
  * `:has_rest_historical_candles` — `true` when the provider exposes a
    REST endpoint returning OHLCV bars. When `false`, the indicator
    engine accumulates ticks into candles in-process.
  * `:supports_short_selling` — `true` when the provider supports
    short positions (margin / derivatives). `false` for spot-only
    crypto adapters (Robinhood Crypto, Webull retail crypto). The
    pipeline gates short entries against this — short decisions on
    spot-only adapters are rejected with `provider_no_short_support`.
  * `:reports_trade_volume` — `true` when the adapter delivers real
    per-bar/ticker TRADE VOLUME. `false` for adapters that expose price
    only (Webull's crypto OpenAPI publishes no trade volume anywhere —
    not the candle endpoint, not the snapshot quote; Robinhood's quote
    carries `volume: nil`). Volume-derived signals (`ObvDivergence`,
    `VolumeConfirmation`, MFI/OBV indicators) cannot work on a
    volume-less venue: they read a constant/zero series and either sit
    permanently neutral or saturate on float noise. Strategy deployment
    gates volume-requiring templates against this so a venue mismatch is
    rejected up front instead of silently producing a dead strategy.

  Every venue publishes through the same path, so there is no "does this venue
  publish its own ticks" capability to declare: fan-out is the consumer's, uniformly.
  """
  @type capabilities :: Capabilities.t()

  @doc """
  Capability declaration for this provider — consumed by orchestration code so
  it can make routing decisions without `case provider do "webull" ->`
  branches. See `Exchanges.Core.Capabilities` for field semantics.

  Build it with `Capabilities.new/1`, which validates the collection-scope
  invariants a struct cannot express.

  Required: every adapter must answer truthfully. There is no default
  on the behaviour because silent defaults hide adapter bugs (a new
  adapter that forgets to override would silently look like a streaming
  provider and starve its indicator engines).
  """
  @callback capabilities() :: capabilities()

  @doc """
  Place a new trading order.

  ## Parameters
  - `order_request`: Order details including symbol, side, type, quantity, etc.
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, order_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback place_order(order_request(), credentials(), keyword()) ::
              {:ok, order_data()} | {:error, String.t()}

  @doc """
  Cancel an existing order.

  ## Parameters
  - `order_id`: Order ID to cancel
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, order_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback cancel_order(String.t(), credentials(), keyword()) ::
              {:ok, order_data()} | {:error, String.t()}

  @doc """
  Get order status and details.

  ## Parameters
  - `order_id`: Order ID to query
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, order_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback get_order(String.t(), credentials(), keyword()) ::
              {:ok, order_data()} | {:error, String.t()}

  @doc """
  Get list of orders (open, filled, cancelled).

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters (status filter, symbol filter, pagination, etc.)

  ## Returns
  - `{:ok, [order_data()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_orders(credentials(), keyword()) :: {:ok, [order_data()]} | {:error, String.t()}

  @doc """
  Get order book (bids and asks) for a symbol.

  ## Parameters
  - `symbol`: Trading pair symbol
  - `opts`: Optional parameters (depth, etc.)

  ## Returns
  - `{:ok, order_book_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback get_order_book(symbol(), keyword()) :: {:ok, map()} | {:error, String.t()}

  @doc """
  Get trade history for the account.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters (symbol filter, pagination, etc.)

  ## Returns
  - `{:ok, [trade_data()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_trade_history(credentials(), keyword()) :: {:ok, [map()]} | {:error, String.t()}

  @doc """
  Get the credentialed account's deposit / withdrawal history.

  Needed to compute cost basis for assets TRANSFERRED INTO the venue rather
  than bought on it — without it, transfer-in positions get current price
  as their "cost basis" and stop-loss / trailing-stop rules fire at
  meaningless levels.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional filters (`:currency`, `:since`, `:limit`)

  ## Returns
  - `{:ok, [transfer_data()]}` where each entry has at minimum:
      - `:currency` — uppercase asset code (e.g. "BTC", "BAT")
      - `:type` — `:deposit` or `:withdrawal`
      - `:amount` — `Decimal` or string-parseable number
      - `:timestamp` — `DateTime.t()`
    Adapters MAY include exchange-specific fields (`:tx_hash`, `:address`)
    in the map; consumers must not require them.
  - `{:error, reason}` on failure
  - `{:error, :not_supported}` when the exchange has no transfer API or
    the adapter hasn't implemented one yet. Adapters MUST return this
    rather than raise, so callers can decide how to fall back.
  """
  @callback get_transfers(credentials(), keyword()) ::
              {:ok, [map()]} | {:error, :not_supported} | {:error, term()}

  # Optional callback — adapters that don't support transfers can omit
  # the implementation and the facade will return `:not_supported`.
  @optional_callbacks get_transfers: 2

  @doc """
  The venue's full listing, with base, quote, instrument type and status —
  everything `get_symbols/1` discards.

  `get_symbols/1` returns `[String.t()]`, so each adapter fetches the venue's
  rich payload and drops all but the name. The pair catalog needs precisely
  those dropped fields, and recovering them by parsing the symbol back apart is
  what this design rejects: an earlier draft regex-matched a `PERP` suffix and
  got Gemini's quote distribution measurably wrong. Gemini is the sharp case —
  its symbols carry no separator, so `BTCUSDCPERP` cannot be split at all
  without the venue's own fields.

  Optional. Venues publishing a single-quote `-USD` catalog with no non-spot
  instruments (Webull, Robinhood) can omit it; a consumer's catalogue derives
  from `get_symbols/1` for those and marks anything unresolvable `:unknown`.

  Phase 2 of
  `docs/design/2026-08-05_exchange-quote-currencies-and-decoupled-data-collection.md`.
  """
  @callback list_instruments(keyword()) ::
              {:ok, [Instrument.t()]} | {:error, term()}

  @optional_callbacks list_instruments: 1

  @doc """
  Get the spot price for `symbol` quoted in `quote_currency` at the
  given UTC timestamp. Historical-price adapters implement this; live
  exchange adapters generally return `{:error, :not_supported}`.

  Phase 4 of
  `docs/design/2026-06-30_boundary-violation-audit-and-refactor.md`.

  ## Parameters

  - `symbol` — the base ticker (e.g. `"BTC"`, `"ETH"`).
  - `quote_currency` — the quote currency (e.g. `"USD"`).
  - `timestamp` — the UTC datetime for the historical price.
  - `opts` — adapter-specific options.

  ## Returns

  - `{:ok, Decimal.t()}` — the historical price.
  - `{:error, :not_supported}` — the adapter doesn't implement
    historical prices (e.g. spot-only exchanges).
  - `{:error, term()}` — other failures (network, API, unmapped
    symbol).
  """
  @callback get_historical_price(symbol(), currency(), DateTime.t(), keyword()) ::
              {:ok, Decimal.t()} | {:error, :not_supported} | {:error, term()}

  # Optional callback — adapters that only serve live prices can omit
  # the implementation and the facade will return `:not_supported`.
  @optional_callbacks get_historical_price: 4

  @doc """
  Get account information and balances.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, [account_data()]}` on success
  - `{:error, reason}` on failure
  """
  @callback get_accounts(credentials(), keyword()) :: {:ok, [map()]} | {:error, String.t()}

  @doc """
  Get fee structure for trading.

  ## Parameters
  - `credentials`: API credentials for authentication
  - `opts`: Optional parameters for the request

  ## Returns
  - `{:ok, fee_data()}` on success
  - `{:error, reason}` on failure
  """
  @callback get_fees(credentials(), keyword()) :: {:ok, map()} | {:error, String.t()}

  @typedoc """
  Per-symbol quantization constraints — the broker's order-acceptance
  rules for a specific instrument:

  - `min_qty` — smallest quantity the broker will accept (Decimal string).
  - `qty_step` — quantity increment (Decimal string). Sizes must be a
    multiple of this step (e.g. 0.0001 for crypto; 0.01 for fractional
    equity; 1 for whole-share equity).
  - `min_notional` — smallest dollar-value the order must represent
    (Decimal string). Webull crypto requires \$1 minimum, Webull equity
    fractional requires \$5, etc.
  - `price_tick` — smallest price increment the limit price must be a
    multiple of (Decimal string).

  Any field may be `nil` when the broker imposes no constraint.
  """
  @type quantization :: %{
          min_qty: decimal_string() | nil,
          qty_step: decimal_string() | nil,
          min_notional: decimal_string() | nil,
          price_tick: decimal_string() | nil
        }

  @doc """
  Quantization constraints for `symbol` on this provider. Used by the
  sizer (small-capital fractional sizing) and the order-build step to
  snap the requested quantity + limit price to a broker-acceptable
  shape before submission. Otherwise the broker rejects the order at
  submission time with a confusing "invalid quantity" error.

  Optional callback — adapters that don't implement it fall through to
  a permissive default (`min_qty: nil, qty_step: nil`) and the
  caller skips quantization. Implementations should return constraints
  derived from the broker's published symbol metadata, falling back to
  sensible per-asset-class defaults when the metadata is unavailable.
  """
  @callback quantization(symbol()) ::
              {:ok, quantization()} | {:error, :not_supported | String.t()}

  @typedoc """
  One pair's 24h market snapshot, returned in bulk by
  `get_market_overview/1`. Used by the universe analyzer's
  discovery pass (Decision 2 of the 2026-06-05 plan) to rank
  exchange-listed pairs without local candle data.

  Any field may be `nil` when the provider doesn't expose it.
  Volume is denominated in the quote-asset (USD for `*-USD`
  pairs); adapters normalize before returning.
  """
  @type market_overview_entry :: %{
          required(:symbol) => symbol(),
          required(:volume_usd_24h) => Decimal.t() | nil,
          required(:price_change_pct_24h) => Decimal.t() | nil,
          required(:high_24h) => Decimal.t() | nil,
          required(:low_24h) => Decimal.t() | nil,
          required(:spread_bps) => Decimal.t() | nil,
          # Optional real-time quote fields, added when the adapter's
          # bulk endpoint exposes them (Coinbase, Binance, Kraken via
          # 2026-07-02 cycle 46 sweep; Gemini's per-symbol fan-out).
          # `PriceCollectionTask.bulk_results/3` reads `last_price`
          # first, falling through to `bid → ask → midpoint(high, low)`
          # only when the adapter genuinely lacks a current-price
          # signal on this endpoint. Adapters that DON'T surface these
          # (Robinhood / Webull) can omit them.
          optional(:last_price) => Decimal.t() | nil,
          optional(:bid) => Decimal.t() | nil,
          optional(:ask) => Decimal.t() | nil
        }

  @doc """
  Single bulk-stats call returning a 24h overview for every tradable
  pair on this provider. Used by the universe analyzer's discovery
  pass to rank pairs without falling back to per-symbol polling.

  Implementations:
  - Binance: single `/api/v3/ticker/24hr` call (~2000 pairs).
  - Coinbase: paginated `/api/v3/brokerage/products`.
  - Kraken: comma-chunked `/0/public/Ticker` calls.
  - Gemini: `/v1/symbols` + per-symbol `/v1/pubticker/{s}` fan-out.
  - Robinhood / Webull: no bulk endpoint exposed; declare
    `{:error, :not_supported}`. The analyzer routes those
    strategies through the sibling-credential pattern (Decision 2)
    or skips the discovery pass entirely if no sibling is present.

  Optional callback — adapters that don't implement it fall through
  to `{:error, :not_supported}` in the analyzer's router.
  """
  @callback get_market_overview(credentials() | nil) ::
              {:ok, [market_overview_entry()]} | {:error, :not_supported | String.t()}

  @optional_callbacks quantization: 1, get_market_overview: 1
end
