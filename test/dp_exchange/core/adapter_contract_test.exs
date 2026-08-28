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
    credentials: %{api_key: "reference", api_secret: "reference"}
end
