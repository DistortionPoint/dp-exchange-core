defmodule DpExchange.Core.Types.OptionChain do
  @moduledoc """
  Every listed contract on one underlying, addressed the way traders address them.

  ## A chain is two-dimensional, and flattening it loses the question

  A chain is **expiry × strike**, with a call and a put at each intersection. Returning a
  flat list of contracts would be lossless in data and useless in shape: the questions asked
  of a chain are "what expiries are there", "what strikes at this expiry", and "the call and
  the put at this strike" — and a list answers none of them without the caller rebuilding
  the grid the venue already had.

  Schwab publishes it as `callExpDateMap` and `putExpDateMap`, each keyed by expiry and then
  by strike. This keeps that structure and normalises the keys:

      %{~D[2026-03-15] => %{
          Decimal.new("500") => %{call: %OptionContract{}, put: %OptionContract{}}
        }}

  **A missing side is `nil`, not an absent key.** A strike listed with only a call is a real
  thing, and a caller iterating strikes must see it rather than have it silently skipped.

  ## `:underlying_price` is carried because the chain is meaningless without it

  Moneyness, and every Greek, is relative to where the underlying is. A chain snapshot and
  an underlying price fetched separately are two observations at two times, and on a moving
  underlying that is how a caller ends up with a "delta-neutral" position that is not.
  """

  @enforce_keys [:underlying, :expiries, :provider]
  defstruct [:underlying, :expiries, :underlying_price, :venue_time, :provider]

  @type strike_row :: %{call: term() | nil, put: term() | nil}

  @type t :: %__MODULE__{
          underlying: String.t(),
          expiries: %{optional(Date.t()) => %{optional(Decimal.t()) => strike_row()}},
          underlying_price: Decimal.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc "The expiries in the chain, earliest first."
  @spec expiry_dates(t()) :: [Date.t()]
  def expiry_dates(%__MODULE__{expiries: expiries}) do
    expiries |> Map.keys() |> Enum.sort(Date)
  end

  @doc """
  The strikes listed at `expiry`, ascending. `[]` when the expiry is not in the chain.

  `[]` for an absent expiry rather than an error: a caller walking expiries it got from
  `expiry_dates/1` cannot ask for one that is missing, and a caller asking for an arbitrary
  date is asking whether anything is listed — which is what an empty list says.
  """
  @spec strikes(t(), Date.t()) :: [Decimal.t()]
  def strikes(%__MODULE__{expiries: expiries}, expiry) do
    expiries
    |> Map.get(expiry, %{})
    |> Map.keys()
    |> Enum.sort(&(Decimal.compare(&1, &2) != :gt))
  end
end
