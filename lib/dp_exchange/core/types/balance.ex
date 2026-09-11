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

  ## `:balance` may honestly be `nil`; `:currency` may not

  These two enforced keys are not the same kind of required, and this type used to claim
  they were — `balance: Decimal.t()`, with `new/1` refusing a `nil` in either.

  **A total the venue did not state is a real answer.** `dp_exchange_coinbase` derives the
  total from the venue's `available_balance` and `hold` and carries `nil` when either side
  is missing, on the stated ground that "available 1, total unknown" and "total equals
  available" are different claims and a consumer sizing against the second when the first
  is true trades against money that is held. That `nil` is the *correct* value, and the
  `available_balance` beside it is still real and still useful — so refusing the whole entry
  would throw away good data to avoid reporting an absence honestly. The typespec now says
  `Decimal.t() | nil`, which is what the family actually produces.

  **A currency the venue did not state is not.** A balance attributable to no asset cannot
  be acted on by anyone: there is no reading of it under which a consumer can size, book or
  reconcile anything. Unlike a missing quantity there is no "the venue declined to say"
  case either — a holdings row names its asset, and a `nil` here means a decode read the
  wrong key, which is precisely what `DpExchange.Core.Types.Validate`'s moduledoc describes
  a renamed venue field producing. It stays required, and a venue decoder that cannot name
  the asset must refuse the row rather than emit one.

  Same shape of decision, and the same reason, as `DpExchange.Core.Types.Order`'s narrowed
  `@required_non_nil` directly below its own `@enforce_keys`: state what is true rather than
  a stricter rule the packages then quietly violate.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:currency, :balance, :timestamp, :provider]
  defstruct [:currency, :balance, :available_balance, :hold, :timestamp, :provider]

  @type t :: %__MODULE__{
          currency: String.t(),
          balance: Decimal.t() | nil,
          available_balance: Decimal.t() | nil,
          hold: Decimal.t() | nil,
          timestamp: DateTime.t(),
          provider: atom() | String.t()
        }

  # `:balance` is deliberately absent — see the moduledoc's "`:balance` may honestly be
  # `nil`; `:currency` may not". `@enforce_keys` still guards its *presence*, so a decoder
  # that forgets the key entirely is still caught; what is allowed is stating the absence.
  @required_non_nil [:currency, :timestamp, :provider]

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`. The
  fields checked here are narrower than `@enforce_keys` on purpose: `:balance` may honestly
  be `nil` and the moduledoc says when.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @required_non_nil, attrs)
end
