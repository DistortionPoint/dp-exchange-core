defmodule DpExchange.Core.AdapterContractTest do
  @moduledoc """
  Core running its own conformance suite against its own reference venue.

  This is what stops the suite's first real exercise happening in a venue repo that
  cannot fix it.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Core.ReferenceVenue,
    fake: DpExchange.Core.ReferenceVenue,
    symbol_format: DpExchange.Core.ReferenceVenue.SymbolFormat,
    sample_pairs: ~w(BTC-USDC ETH-USD BTC-USDT),
    credentials: %{api_key: "reference", api_secret: "reference"},
    # The reference venue lives in `test/support/`, not `lib/` — this package is not
    # itself venue-shaped, and assertion 16 must scope to where the fixture actually
    # is rather than to Core's own many consumer-facing modules.
    package_root: "test/support"
end
