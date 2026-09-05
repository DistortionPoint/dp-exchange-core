defmodule DpExchange.Core.Types.FinancialStatement do
  @moduledoc """
  A financial statement as the venue publishes it.

  ## The line items are the venue's, kept as sent

  `:line_items` is a map of the venue's own field names to their values. It is deliberately
  not normalised into a fixed set of fields.

  Statements differ by accounting standard, by fiscal calendar, by industry and by how much
  detail the venue chose to relay. A fixed schema would have to drop whatever did not fit,
  and dropping a line from a balance sheet is not a lossy convenience — it is a statement
  that no longer balances. **Where this interface cannot carry a venue's structure faithfully
  it carries it verbatim**, rather than reshaping it into something that looks tidier and
  says less.

  ## `:period_end` and `:fiscal_period` are both needed

  A fiscal year is not a calendar year and does not end on the same date for every issuer.
  `:period_end` is the date the statement covers to; `:fiscal_period` is the venue's own
  label for it — `"FY2025"`, `"Q3"`. Comparing two issuers on `:period_end` alone compares
  different quarters; comparing on the label alone compares different dates.

  ## `:currency` is not assumed

  Statements are reported in the issuer's currency, which is not the venue's quote currency
  and not the caller's. `nil` means the venue did not say — it does not mean USD.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :kind, :line_items, :provider]
  defstruct [
    :symbol,
    :kind,
    :line_items,
    :period_end,
    :fiscal_period,
    :currency,
    :venue_time,
    :provider
  ]

  @type kind :: :balance_sheet | :income | :cash_flow | :indicators | :other

  @type t :: %__MODULE__{
          symbol: String.t(),
          kind: kind(),
          line_items: %{optional(String.t()) => term()},
          period_end: Date.t() | nil,
          fiscal_period: String.t() | nil,
          currency: String.t() | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
