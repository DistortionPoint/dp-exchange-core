defmodule DpExchange.Core.Types.ScreenerResult do
  @moduledoc """
  One row from a venue's screener, mover list or ranking.

  ## The criteria are the venue's, and two venues' lists are not comparable

  A "top mover" list is the output of a rule the venue chose: over what window, ranked by
  what, filtered to which universe. Two venues publish lists under the same name that answer
  different questions, and nothing in the rows says so.

  So `:screener` carries the venue's own identifier for the list, and `:metrics` carries
  whatever it ranked by, under the venue's own keys. **This interface does not re-rank, merge
  or compare across venues** — doing so would produce a combined list whose ordering means
  nothing, from rows that were each individually correct.

  `:rank` is the venue's position in its own list, kept because a caller asking for the top
  ten wants to know which was first, and lost the moment rows from two venues are mixed.
  """

  @enforce_keys [:symbol, :screener, :provider]
  defstruct [:symbol, :screener, :rank, :metrics, :venue_time, :provider]

  @type t :: %__MODULE__{
          symbol: String.t(),
          screener: String.t(),
          rank: pos_integer() | nil,
          metrics: %{optional(String.t()) => term()} | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }
end
