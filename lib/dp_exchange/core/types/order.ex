defmodule DpExchange.Core.Types.Order do
  @moduledoc """
  Normalised order, returned by every venue package.

  `:created_at` and `:updated_at` are **the venue's own** values where it supplies them
  and `nil` where it does not. `nil` is the honest answer; a substituted local clock
  would be a plausible value with the wrong meaning.

  Not every venue supports every `t:order_type/0` or reports every `t:status/0`. The
  union here is what the contract can *express*; what a given venue can actually accept
  is declared by that package's `capabilities/0`, and asking for one it does not support
  is an error rather than a silent downgrade to the nearest available type.

  ## Why the enforced keys still admit `nil`

  All seven are enforced, and all but `provider` allow `nil`. That is not laxity — it is the
  same rule as everywhere else here: **the venue's word, or nothing.**

  A venue sending a status this package does not recognise gets `nil`, never the nearest
  atom a caller might branch on. Coinbase's `close_position/3` returns an order whose side
  the venue never states — the venue worked the side out from a position this package did
  not read — and filling in `:sell` because closing is usually selling is wrong exactly
  where it matters, on a short.

  **`symbol` and `id` joined them on 2026-09-01.** Robinhood acknowledges a cancel request
  without describing the order it cancelled: there is an id and nothing else, and inventing
  a symbol to satisfy a type would put a guess where the venue was silent.

  The keys stay enforced so a constructor must *decide*. The types admit `nil` so the
  decision can be "the venue did not say".
  """

  @enforce_keys [:id, :symbol, :side, :order_type, :quantity, :status, :provider]
  defstruct [
    :id,
    :symbol,
    :side,
    :order_type,
    # `Capabilities.supported_time_in_force` says which a venue accepts; without this the
    # type could not say which one an order actually used. A caller reading an order back
    # could not distinguish an IOC that expired from a GTC still working.
    :time_in_force,
    :quantity,
    :price,
    :stop_price,
    :status,
    :filled_quantity,
    :average_price,
    :fee,
    :fee_currency,
    # Empty for an ordinary single-instrument order. Non-empty for a spread, which the
    # venue fills as a unit or not at all — see `Types.OrderLeg`. A venue that cannot
    # trade multi-leg refuses rather than decomposing: submitting the legs separately is
    # something the venue never received, and reports back as though it had. A venue that
    # cannot accept multi-leg refuses.
    :legs,
    :created_at,
    :updated_at,
    :provider
  ]

  @type side :: :buy | :sell

  @type order_type :: :market | :limit | :stop | :stop_limit | :post_only | :ioc | :fok

  @type status ::
          :pending
          | :open
          | :partially_filled
          | :filled
          | :cancelled
          | :rejected
          | :expired

  @type t :: %__MODULE__{
          id: String.t() | nil,
          symbol: String.t() | nil,
          side: side() | nil,
          order_type: order_type() | nil,
          time_in_force: atom() | nil,
          quantity: Decimal.t() | nil,
          price: Decimal.t() | nil,
          stop_price: Decimal.t() | nil,
          status: status() | nil,
          filled_quantity: Decimal.t() | nil,
          average_price: Decimal.t() | nil,
          fee: Decimal.t() | nil,
          fee_currency: String.t() | nil,
          legs: [DpExchange.Core.Types.OrderLeg.t()] | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          provider: atom() | String.t()
        }
end
