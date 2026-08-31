defmodule DpExchange.Core.Types.CorporateEvent do
  @moduledoc """
  A dated event on an issuer — a dividend, an earnings release, a split.

  ## The dates are several, and they are not interchangeable

  A dividend has an **ex-date**, a **record date** and a **pay date**, and they are days or
  weeks apart. Which one matters depends entirely on the question: the ex-date determines
  who receives it, the pay date when the cash arrives. A single `:date` field would force
  every caller to guess which one it held.

  So each is carried under its own name, and `:date` is not among them. A venue that
  publishes only one populates only that one; the rest stay `nil`, meaning **not published**
  rather than "same as the one you have".

  ## An earnings date is often approximate, and the venue knows it

  Issuers announce "week of", and venues relay estimates that move. `:confirmed` carries the
  venue's own statement of whether the date is fixed. `nil` means it did not say — which is
  not the same as confirmed, and a caller treating an estimate as fixed will be early or
  late by days.
  """

  @enforce_keys [:symbol, :kind, :provider]
  defstruct [
    :symbol,
    :kind,
    :ex_date,
    :record_date,
    :pay_date,
    :announced_date,
    :amount,
    :currency,
    :ratio,
    :confirmed,
    :details,
    :provider
  ]

  @type kind :: :dividend | :earnings | :split | :other

  @type t :: %__MODULE__{
          symbol: String.t(),
          kind: kind(),
          ex_date: Date.t() | nil,
          record_date: Date.t() | nil,
          pay_date: Date.t() | nil,
          announced_date: Date.t() | nil,
          amount: Decimal.t() | nil,
          currency: String.t() | nil,
          ratio: String.t() | nil,
          confirmed: boolean() | nil,
          details: %{optional(String.t()) => term()} | nil,
          provider: atom()
        }
end
