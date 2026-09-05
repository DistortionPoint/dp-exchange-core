defmodule DpExchange.Core.Types.ApprovedAddress do
  @moduledoc """
  An address on a venue's withdrawal allow-list.

  ## Why this is in the contract at all

  Two venues in this family gate withdrawals behind an allow-list: a withdrawal to an
  address that is not on it is refused, whatever the balance. A facade that could not
  express the list would leave a caller unable to tell "this withdrawal failed" from "this
  withdrawal was never going to work", and unable to do anything about the second.

  ## `:status` and `:active_from` are the whole point

  Adding an address is not the same as being able to use it. Venues impose a waiting period
  between approval and first use — the point of an allow-list being that an attacker who
  takes an account cannot immediately add their own address and drain it.

  So an address can be on the list and still unusable:

    * `:pending` — requested, not yet usable
    * `:active` — usable now
    * `:rejected` — refused

  `:active_from` is when a `:pending` address becomes usable, where the venue states it.
  **`nil` does not mean "usable now"** — it means the venue did not say, and a caller
  planning a withdrawal against an unstated activation is planning against a guess.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:address, :network, :status, :provider]
  defstruct [:address, :network, :status, :asset, :label, :active_from, :requested_at, :provider]

  @type status :: :pending | :active | :rejected

  @type t :: %__MODULE__{
          address: String.t(),
          network: String.t(),
          status: status(),
          asset: String.t() | nil,
          label: String.t() | nil,
          active_from: DateTime.t() | nil,
          requested_at: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)

  @doc """
  Whether this address can be withdrawn to as at `now`.

  Returns `nil` when the address is `:pending` and the venue stated no activation time —
  **unknown, not usable**. The only safe reading of an unstated activation is to ask the
  venue again rather than to attempt the withdrawal.
  """
  @spec usable?(t(), DateTime.t()) :: boolean() | nil
  def usable?(%__MODULE__{status: :active}, _now), do: true
  def usable?(%__MODULE__{status: :rejected}, _now), do: false
  def usable?(%__MODULE__{status: :pending, active_from: nil}, _now), do: nil

  def usable?(%__MODULE__{status: :pending, active_from: active_from}, now) do
    DateTime.compare(now, active_from) != :lt
  end
end
