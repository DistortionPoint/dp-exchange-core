defmodule DpExchange.Core.Types.Portfolio do
  @moduledoc """
  A named subdivision of an account that balances, orders and positions are addressed to.

  ## A portfolio is an address, not a value

  This is the distinction that shapes the type. A balance is a number the venue reports; a
  portfolio is *where you ask for it*. Two portfolios on one account hold separate balances,
  take separate positions and can be margined separately — so "the account's BTC balance" is
  not a well-formed question on a venue that has them, and a package answering it anyway has
  picked one and not said which.

  So this type is deliberately thin. It carries what is needed to **name** a portfolio and
  choose between them; everything you would then ask *about* one comes back through the
  normal calls, addressed with `portfolio: id`.

  ## Addressing rides as an option, not as a parameter on every callback

  A venue without portfolios has one implicit context and ignores the option. A venue with
  them uses it, and where it is omitted the package uses the venue's default — **and must
  not invent one**. A caller that needs determinism passes the id.

  This is the options surface D3 admits: adding `portfolio` to forty callback signatures
  would put a concept most venues do not have into every call on every venue.

  ## `:type` is the venue's own word

  Venues subdivide accounts for different reasons — margin isolation, strategy separation,
  sub-accounts for clients — and call the result different things. The word is kept rather
  than mapped, because a normalisation that flattened "margin portfolio" and "sub-account"
  into one atom would erase the reason a caller was choosing between them.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:id, :provider]
  defstruct [:id, :name, :type, :deleted, :provider]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          type: String.t() | nil,
          deleted: boolean() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
