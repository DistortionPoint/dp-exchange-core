defmodule DpExchange.Core.Types.Watchlist do
  @moduledoc """
  A named list of instruments held **at the venue**.

  ## The venue's list is not the host's list

  A host already knows which symbols it cares about. This is a different list, stored by the
  venue, and the two can disagree — which is the reason to expose it rather than to assume
  the host's own list is authoritative. A watchlist edited in the venue's own app is a fact
  about the account, and a host reconciling against it needs to read it.

  So this type carries the venue's identifier and the venue's membership, and does not merge
  them with anything the host holds. **Merging is the host's decision**, and it needs both
  sides to make it.

  ## `:symbols` is `nil` when unfetched, `[]` when empty

  Venues list watchlists and their contents through separate endpoints, so a watchlist
  fetched from the index has a name and no membership. `nil` says "not fetched"; `[]` says
  "fetched, and empty". A caller syncing against `nil` read as empty would delete every
  symbol in the list.
  """

  @enforce_keys [:id, :provider]
  defstruct [:id, :name, :symbols, :venue_time, :provider]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          symbols: [String.t()] | nil,
          venue_time: DateTime.t() | nil,
          provider: atom()
        }
end
