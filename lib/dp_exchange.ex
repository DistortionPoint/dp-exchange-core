defmodule DpExchange do
  @moduledoc """
  The **DpExchange** family: one identical facade over every trading venue.

  > #### ⚠️ EXPERIMENTAL {: .warning}
  >
  > No package in this family has run in production. While they are `0.x` the API may
  > change without a major version — pin all three segments (`~> 0.1.0`). Coverage is
  > uneven *by design*: in-process fakes and live public endpoints are well covered,
  > order placement and authenticated flows are not.
  >
  > **Do not treat this banner as your check.** Maturity is declared **per endpoint**
  > through each venue's `capabilities/0`, which reports `:proven`, `:experimental` or
  > `:unsupported` for individual calls. A package can be broadly usable while the one
  > endpoint you depend on is unproven, and the reverse.

  ## What this package is

  `dp_exchange_core` is the **contract**, not a client. It talks to no exchange. It
  defines what a venue package *is* — the facade every one exposes, the value types they
  return, the canonical-pair normaliser, and the conformance suite that proves an
  implementation conforms.

  Each venue lives in its own repository and its own Hex package, depends on this one,
  and shares this namespace.

  ## What the facade guarantees

  Every venue package exposes the **same** functions, and a consumer drives any venue
  through them without knowing which venue it is:

    * **Declaration** — `provider_name/0`, `runtime_id/0`, `asset_classes/0`,
      `capabilities/0`. Static, credential-free, safe to call at boot.
    * **Market data** — prices, historical candles, symbols, order books, instruments.
    * **Account and trading** — balances, accounts, fees, transfers, orders, fills.
      Credentials are passed in as arguments; a package never reads them from a vault.
    * **Streaming** — `subscribe/2`, `unsubscribe/2`, `update_symbols/2`, `coverage/1`.
      Subscriptions are addressed by the thing itself — the pair, or the symbol on an
      equity venue — never by a handle a caller would have to hold.

  A new venue can be added by implementing that facade, with **zero** edits to this
  package, to any other venue package, or to the application consuming them.

  ## What the facade deliberately does not do

  **It never tells you how the data arrived.** Transport, rate limiting, credential and
  session handling, sharding and supervision are internal to a venue package. Whether
  `subscribe/2` opened one WebSocket, twelve, an MQTT session or a polling loop is not
  observable through the facade, and that is the load-bearing decision of the whole
  family — not an omission.

  What you can ask is *what* a venue can do and *how fresh* it is, through
  `capabilities/0` and `coverage/1`. `coverage/1` reports what is **observed arriving**,
  never what was subscribed: a venue that cannot observe delivery says so rather than
  claiming success.

  **It does not start anything.** Venue packages expose `child_spec/1` and are supervised
  by *you*. This package ships no aggregate supervisor and no start-everything entry
  point — it would have to know which venues exist, and it would take a decision that is
  the consuming application's: which venues run, in what restart strategy, under what
  names. A consumer who has not asked for a venue never finds a socket open.

  ## The family

  | Package | Venue |
  |---|---|
  | `dp_exchange_core` | — this package, the contract |
  | `dp_exchange_coinbase` | Coinbase |
  | `dp_exchange_gemini` | Gemini |
  | `dp_exchange_webull` | Webull |
  | `dp_exchange_robinhood` | Robinhood |
  | `dp_exchange_schwab` | Charles Schwab |

  `dp_exchange_binance` and `dp_exchange_kraken` are **reserved names with no
  implementation**. Neither venue can be verified past public market data from the
  maintainer's jurisdiction, so neither could ever leave EXPERIMENTAL, and shipping a
  package that can never be proven is worse than not shipping one.

  ## The namespace is the registry

  `"coinbase"` resolves to `DpExchange.Coinbase` by convention, so `venue/1` needs no
  registry to maintain, no boot-time registration and no scan of loaded applications.
  See `venue/1`.
  """

  @doc """
  Resolves a venue name to its facade module.

  `"coinbase"`, `:coinbase` and `"Coinbase"` all resolve to `DpExchange.Coinbase`, if
  that package is a dependency of the calling application.

  ## Fails closed

  Returns `{:error, :unknown_venue}` — never a guess, never a nearby substitute — when
  the name does not correspond to a loaded venue module. Three distinct ways to be
  unknown, all one answer:

    * the atom does not exist, because no such module was ever compiled. `Module.safe_concat/2`
      raises rather than minting an atom from caller input, so a hostile or mistyped name
      cannot grow the atom table;
    * the module exists but is not loaded, meaning that venue package is not a dependency;
    * the module is loaded but is not a venue — `DpExchange.Core` is a real module under
      this namespace and must not resolve as a venue.

  ## Enumeration is not offered, deliberately

  There is no `list_venues/0`. A consumer that wants to know which venues it has already
  has the list, in its own `mix.exs`. This package resolves; it does not enumerate.

  ## Examples

      iex> DpExchange.venue("no_such_venue")
      {:error, :unknown_venue}

      iex> DpExchange.venue(DpExchange.Core)
      {:error, :unknown_venue}
  """
  @spec venue(String.t() | atom()) :: {:ok, module()} | {:error, :unknown_venue}
  def venue(name) when is_binary(name) or is_atom(name) do
    name
    |> to_string()
    |> Macro.camelize()
    |> then(&Module.safe_concat(DpExchange, &1))
    |> validate_venue()
  rescue
    ArgumentError -> {:error, :unknown_venue}
  end

  defp validate_venue(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) do
      {:ok, module}
    else
      {:error, :unknown_venue}
    end
  end
end
