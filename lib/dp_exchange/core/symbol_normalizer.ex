defmodule DpExchange.Core.SymbolNormalizer do
  @moduledoc """
  The **symbol-normalisation contract** every venue package must satisfy.

  A venue's `SymbolFormat` module `@behaviour`s this so the contract is
  *obligatory*: a package that ships without both directions of the conversion fails
  the compiler's missing-callback check. This is what makes the
  multi-exchange promise safe — one caller's canonical `BASE-QUOTE` pairs mean the
  same thing on every venue, because every venue is forced to round-trip them through
  the shared `DpExchange.Core.CanonicalPair` normaliser with its own mapping.

  Two directions, both total (never raise — malformed input degrades to
  `"UNKNOWN"` for the inbound direction so a bad feed message can't crash a parser):

  - `to_canonical_symbol/1` — exchange-native → canonical `BASE-QUOTE` (uppercase,
    dash). The form the rest of the system stores and reasons about.
  - `to_exchange_symbol/1` — canonical `BASE-QUOTE` → exchange-native. The form a
    connector puts on the wire (orders, subscriptions).

  Venues with more than one native channel — a WebSocket vocabulary differing from
  the REST one is common — implement these two against their **account/REST** form — the authoritative native form
  for orders and balances — and expose channel-specific helpers alongside.
  """

  @doc "Exchange-native symbol → canonical `BASE-QUOTE` (uppercase, dash-separated)."
  @callback to_canonical_symbol(native :: String.t()) :: String.t()

  @doc "Canonical `BASE-QUOTE` → this exchange's native symbol form."
  @callback to_exchange_symbol(canonical :: String.t()) :: String.t()
end
