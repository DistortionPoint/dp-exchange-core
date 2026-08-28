defmodule DpExchange.Core.Types.Quote do
  @moduledoc """
  Normalised price quote, returned by every venue package.

  `:timestamp` is **the venue's own** — whatever it gave us, used as-is. It is not
  normalised, not substituted, and never invented: a quote whose freshness we cannot
  state is a quote we must not return.
  """

  @enforce_keys [:symbol, :price, :timestamp, :provider]
  defstruct [:symbol, :price, :volume, :bid, :ask, :timestamp, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          price: Decimal.t(),
          volume: Decimal.t() | nil,
          bid: Decimal.t() | nil,
          ask: Decimal.t() | nil,
          timestamp: DateTime.t(),
          provider: atom() | String.t()
        }
end
