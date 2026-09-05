defmodule DpExchange.Core.Types.Balance do
  @moduledoc """
  Normalised balance entry, returned by every venue package.

  ## `:timestamp` means *when we asked*

  A balance is the only one of the six value types with no venue event time behind it.
  It is a snapshot, not an occurrence: no exchange reports "this balance happened at
  10:04". So its timestamp is the moment the request was made, and **that is its
  freshness** — the only honest answer to "how old is this number".

  It is enforced for the same reason every other type enforces its timestamp. A balance
  with no freshness is indistinguishable from a stale one, and a consumer sizing a trade
  against a balance it believes is current is exactly the failure this family is built to
  refuse.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:currency, :balance, :timestamp, :provider]
  defstruct [:currency, :balance, :available_balance, :hold, :timestamp, :provider]

  @type t :: %__MODULE__{
          currency: String.t(),
          balance: Decimal.t(),
          available_balance: Decimal.t() | nil,
          hold: Decimal.t() | nil,
          timestamp: DateTime.t(),
          provider: atom() | String.t()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
