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
          id: String.t(),
          symbol: String.t(),
          side: side(),
          order_type: order_type(),
          time_in_force: atom() | nil,
          quantity: Decimal.t(),
          price: Decimal.t() | nil,
          stop_price: Decimal.t() | nil,
          status: status(),
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
