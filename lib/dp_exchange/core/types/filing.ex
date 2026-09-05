defmodule DpExchange.Core.Types.Filing do
  @moduledoc """
  A regulatory filing the venue points at.

  ## This interface points; it does not fetch

  `:url` is where the document lives. **This package never follows it.** A filing is a large
  document on a third party's server, and fetching it is a decision with its own timeouts,
  rate limits and failure modes that belongs to whoever wants the contents — not to a venue
  interface relaying an index.

  ## `:form_type` is the regulator's word, not a normalised one

  `"10-K"`, `"8-K"`, `"6-K"`, `"20-F"` mean specific things and do not map onto a small set
  of atoms without losing which one it was. The string is carried as the venue sent it.
  """

  alias DpExchange.Core.Types.Validate

  @enforce_keys [:symbol, :provider]
  defstruct [:symbol, :id, :form_type, :title, :url, :filed_at, :period_end, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          id: String.t() | nil,
          form_type: String.t() | nil,
          title: String.t() | nil,
          url: String.t() | nil,
          filed_at: DateTime.t() | nil,
          period_end: Date.t() | nil,
          provider: atom()
        }

  @doc """
  Builds a `t:t/0`, failing closed if a required field is absent or `nil`.

  `@enforce_keys` guards presence, not `nil` — see `DpExchange.Core.Types.Validate`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs), do: Validate.new!(__MODULE__, @enforce_keys, attrs)
end
