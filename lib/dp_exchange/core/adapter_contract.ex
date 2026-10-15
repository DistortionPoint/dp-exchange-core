defmodule DpExchange.Core.AdapterContract do
  @moduledoc """
  The conformance suite every venue package runs in its own CI.

  **This is the mechanism.** Prose in six `CLAUDE.md` files drifts; a suite that runs in
  five CI pipelines cannot.

  ## Why this lives in `lib/` and not `test/support/`

  It was in `test/support/` first, following the reference repo, and **that does not
  work for a suite consumers run.** `elixirc_paths(:test)` governs *this* package's own
  build; a dependency is not compiled in the `:test` environment, so the file shipped
  inside the tarball and was never compiled into the consumer. A venue package's
  `use DpExchange.Core.AdapterContract` failed with *module not loaded and could not be
  found* — the suite present on disk and absent from the code path.

  Shipping a file is not the same as shipping a module. A public testing API belongs in
  `lib/`, which is why `Ecto.Adapters.SQL.Sandbox` and `Phoenix.ConnTest` live there.

  `use ExUnit.Case` appears only inside the generated block, so nothing here needs
  ExUnit at compile time and this compiles cleanly as a dependency.

      defmodule DpExchange.Coinbase.ContractTest do
        use DpExchange.Core.AdapterContract,
          venue: DpExchange.Coinbase,
          symbol_format: DpExchange.Coinbase.SymbolFormat,
          sample_pairs: ~w(BTC-USDC ETH-USDC),
          credentials: %{api_key: "test", api_secret: "test"}
      end

  ## Options of `use`

    * `:venue` - **required**, the facade module.
    * `:fake` and `:sample_pairs` - not optional in practice: group 1 fails without them.
    * `:symbol_format` - the `SymbolNormalizer` module; group 4 is generated only when named.
    * `:credentials` - the credentials map the calls carry (default `%{}`).
    * `:endpoint_opts` - `%{{name, arity} => keyword()}`, what the fake needs to answer.
    * `:endpoint_symbols` - `%{{name, arity} => symbol}` for an endpoint narrower than
      `:sample_pairs`.
    * `:order_args` - `%{order_request | order_requests | order_changes => value}`; an unknown
      key raises at compile time.
    * `:absent_feed_opts` - options pointing the streaming calls at a feed nothing registered
      (default `[feed: :dp_exchange_contract_absent_feed]`).
    * `:package_root` - where groups 16, 18 and 19 scan compiled modules (default `"lib"`).
    * `:unlisted_symbol` and `:padded_credentials` - the opt-in facts of group 41.

  ## What it asserts, and what it deliberately does not

  Forty-one groups, listed in `assertions/0`. The load-bearing one is **capabilities and
  behaviour agreeing in both directions**: over-declaring fails in a caller's hands at
  runtime, and under-declaring hides working functionality. Holding both is what makes
  `capabilities/0` trustworthy enough for a consumer to branch on instead of branching on
  venue identity.

  **Maturity is asserted for presence, not for truth.** Every active endpoint must declare
  `:proven` or `:experimental`, because an absent value is the failure this prevents.
  Whether a `:proven` claim is *true* is not machine-checkable, and a suite that pretended
  otherwise would be worse than one that admits the limit.

  **No assertion may name a socket, a channel string, a transport module or a polling
  interval.** If one does, mechanism has leaked through the facade and the assertion is the
  bug, not the venue.

  ## The fake satisfies the same suite as the real adapter

  That is the ratchet. The suite's job is not to anticipate every way a fake can diverge —
  it is to make each discovered divergence permanent. The reference implementation this
  pattern comes from went from nothing to over a thousand lines by absorbing thirteen gaps
  its first consumer found, and none reached an external user across thousands of downloads.

  **Every gap found becomes a new assertion here.** A gap fixed only in one venue's fake is
  a gap the next venue will reintroduce.
  """

  alias DpExchange.Core.Types.Quote, as: ContractQuote

  @doc """
  The assertion groups, for documentation and for a venue package to report against.
  """
  @spec assertions() :: [{pos_integer(), String.t()}]
  def assertions do
    [
      {1, "behaviour completeness — every required callback, optionals all-or-nothing"},
      {2, "capabilities — a validated %Capabilities{} whose invariants hold"},
      {3, "identity — name, runtime id and asset classes are present and well-formed"},
      {4, "symbol round-trip — to_canonical(to_exchange(p)) == p, over declared quotes"},
      {5, "return types — Core.Types.* with Decimal numerics and DateTime timestamps"},
      {6, "error discipline — {:error, :not_supported} as the atom, and never a raise"},
      {7, "purity — the package links against no host application"},
      {8, "both endpoints answer — pull and subscribe, on every venue, with no flag"},
      {9, "fake fidelity — the fake satisfies this same suite"},
      {10, "facade completeness and exclusivity — only the facade is public"},
      {11, "self-sufficiency — nothing injected but credentials and options"},
      {12, "capabilities and behaviour agree, in both directions"},
      {13, "process-scoped isolation — usable in a consumer's async suite"},
      {14, "top of book is not a price — a BBO carries resting orders, never a traded price"},
      {15,
       "coverage by kind — optional; when a venue exports it, the union invariant against " <>
         "coverage/1 holds and every key is a kind the venue's own capabilities declare"},
      {16,
       "internal wiring — every internal export has a caller inside this package's own " <>
         "lib/, so a mechanism cannot ship built, documented and never reached"},
      {17,
       "credential gate — on a venue requiring credentials, no active endpoint's fake " <>
         "succeeds when called with credentials stripped"},
      {18,
       "link safety — a process behaviour that starts a linked child traps exits, so " <>
         "that child's abnormal death cannot propagate untrapped into the process " <>
         "that started it"},
      {19,
       "credential redaction — a struct holding a secret-named field redacts it under " <>
         "inspect/1, so a crash report or a failed function clause's stacktrace never " <>
         "prints it in cleartext"},
      {20,
       "subscribed push shape — subscribe/2's fake delivers a DpExchange.Core.Types.* " <>
         "struct tagged with runtime_id/0, never raw venue data"},
      {21,
       "historical timeframe discipline — a width outside historical_timeframes is " <>
         "refused, never served at the nearest one"},
      {22,
       "credential redaction in child_spec/1 — a secret passed in :credentials is not " <>
         "rendered in the args a supervisor stores and OTP prints on every child crash"},
      {23,
       "venue time and observed time — Quote and OrderBook carry the venue's own DateTime " <>
         "or nil in venue_time, never an unparsed stand-in, and observed_at is always there"},
      {24,
       "balance attribution — every Balance names the asset it is a balance of, because " <>
         "an amount attributable to nothing cannot be sized, booked or reconciled"},
      {25,
       "order book ordering — bids descending and asks ascending, so hd(bids) is the best " <>
         "bid, and every level carries a real Decimal price"},
      {26,
       "subscription set semantics — subscribe/2 adds to the live set, update_symbols/2 " <>
         "replaces it, unsubscribe/2 removes only what it names"},
      {27,
       "a forwarded nil is an absent option — subscribe/2 with `to: nil` delivers to the " <>
         "caller, neither to nobody nor by raising"},
      {28,
       "a streaming call answers when no feed is running — subscribe/2, unsubscribe/2, " <>
         "update_symbols/2, subscribe_notices/1 and coverage/1 return a value, never an " <>
         "exit in the caller"},
      {29,
       "a lower-case subscription is delivered under the canonical symbol — the fake " <>
         "upper-cases subscribed symbols as the real facade does"},
      {30,
       "a quote's volume states its window — a Quote from get_price/2 carrying a volume " <>
         "names it as one print, a running total or a rolling 24h total, and one carrying " <>
         "none names no window"},
      {31,
       "fake order round trip — the ids the fake's place_order/3, place_orders/3, " <>
         "replace_order/4 and close_position/3 return (each when declared active) are " <>
         "accepted by the same fake's get_order/3 and cancel_order/3, unless those are " <>
         "declared unsupported"},
      {32,
       "streaming arguments are validated first — a malformed symbol list is " <>
         "{:invalid_symbols, v} and a bad :to is {:invalid_subscriber, v}, on the fake and " <>
         "on the real facade with no feed running, never :ok and never :feed_not_started"},
      {33,
       "a symbol that is not text is refused before credentials — nil, a number or a " <>
         "blank string on get_price/2 and get_top_of_book/2 is {:invalid_symbol, v}"},
      {34,
       "place_order request discipline — a non-map is {:invalid_order_request, r}, a " <>
         "missing order_type {:missing_field, :order_type}, an unread key " <>
         "{:unsupported_order_field, k}, a price on a market order {:unexpected_field, :price}"},
      {35,
       "order ids are checked first — nil or a blank id on get_order/3 and cancel_order/3 " <>
         "is {:invalid_order_id, v}, before the account option and before credentials"},
      {36,
       "include_partial must be a boolean — a non-boolean on get_historical_prices/4 is " <>
         "{:invalid_option, :include_partial, v}"},
      {37,
       "candles are oldest first, aligned to their width (30-minute grid for a wider " <>
         "intraday width on a session-traded venue), and a range is :start inclusive, " <>
         ":end exclusive"},
      {38,
       "order book options — :depth caps the levels per side; :limit is refused " <>
         "{:unsupported_option, :limit}, honoured natively or tolerated, never a stray error"},
      {39,
       "prices and sizes are positive — every Quote, Trade and Candle price, every book " <>
         "level's price and size, with books best first"},
      {40,
       "wanted/1 — optional; when the fake exports it, it holds every symbol subscribed and " <>
         "every symbol coverage/1 reports, as a list or a MapSet"},
      {41,
       "family reasons — opt-in by `unlisted_symbol:` and `padded_credentials:`; an unlisted " <>
         "symbol is {:refused, :not_listed} and a padded credential is " <>
         "{:error, {:invalid_credentials, runtime_id}}"}
    ]
  end

  @doc """
  The `Core.Types` struct(s) each `Core.Venue` callback's success is typed as, read from the
  behaviour's own `@callback` specs.

  Returns `%{{name, arity} => [module]}` for every callback whose success type names a
  `DpExchange.Core.Types.*` struct, and omits the rest. Read from the compiled specs rather
  than written as a table, so it cannot drift from the contract it restates. Used by
  assertion 5.
  """
  @spec promised_types() :: %{{atom(), non_neg_integer()} => [module()]}
  def promised_types do
    {:ok, callbacks} = Code.Typespec.fetch_callbacks(DpExchange.Core.Venue)

    for {{name, arity}, [{:type, _line, :fun, [_args, result]} | _rest]} <- callbacks,
        modules = core_types_in(result),
        modules != [],
        into: %{},
        do: {{name, arity}, modules}
  end

  defp core_types_in(
         {:remote_type, _line, [{:atom, _module_line, module}, {:atom, _t_line, :t}, []]}
       ) do
    if String.starts_with?(inspect(module), "DpExchange.Core.Types."), do: [module], else: []
  end

  defp core_types_in(ast) when is_tuple(ast),
    do: ast |> Tuple.to_list() |> core_types_in() |> Enum.uniq()

  defp core_types_in(ast) when is_list(ast),
    do: ast |> Enum.flat_map(&core_types_in/1) |> Enum.uniq()

  defp core_types_in(_leaf), do: []

  @doc """
  The names of the `Core.Venue` callbacks whose first argument is `credentials()`, read from
  the behaviour's own `@callback` specs.

  The suite shapes a call's arguments by whether the callback takes its credential
  positionally. That used to be a hand-written list of eleven names, and it rotted in the
  way a list does: `list_payment_methods/2`, `get_payment_method/3`, `get_notional_balances/3`,
  `list_custody_fees/2`, `get_transactions/2`, `place_orders/3`, `cancel_all_orders/2`,
  `preview_order/3`, `preview_replace/4`, `close_position/3` and `get_trade_volume/2` all take
  `credentials()` first and none was on it. Each was therefore called with a symbol where the
  credential belongs, a fake that matched on its credentials raised, and the raise was taken
  for an answer by every assertion that tolerates one. A union such as
  `credentials() | nil` (`test_connection/2`) counts.
  """
  @spec credentialed_callbacks() :: [atom()]
  def credentialed_callbacks do
    {:ok, callbacks} = Code.Typespec.fetch_callbacks(DpExchange.Core.Venue)

    for {{name, _arity}, [spec | _rest]} <- callbacks,
        {:type, _line, :fun, [{:type, _args_line, :product, [first | _args]}, _result]} <- [spec],
        takes_credentials?(first),
        uniq: true,
        do: name
  end

  defp takes_credentials?({:user_type, _line, :credentials, []}), do: true

  defp takes_credentials?(ast) when is_tuple(ast),
    do: ast |> Tuple.to_list() |> takes_credentials?()

  defp takes_credentials?(ast) when is_list(ast), do: Enum.any?(ast, &takes_credentials?/1)
  defp takes_credentials?(_leaf), do: false

  # Argument shapes as DATA rather than a clause per arity. Ten clauses is ten places to be
  # inconsistent, and the shapes really are a small table.
  @arg_shapes %{
    {:credentialed, 2} => [:credentials, :opts],
    {:credentialed, 3} => [:credentials, :symbol, :opts],
    {:public, 1} => [:opts],
    {:public, 2} => [:symbol, :opts],
    {:public, 3} => [:symbol, :timeframe, :opts],
    {:public, 4} => [:symbol, :timeframe, :opts, :opts]
  }

  # Callbacks whose arguments are not a symbol: an order request, a batch of them, an order
  # id, a set of changes. Shaped as `{:credentialed, 3}` the order writes were called as
  # `place_order(credentials, "BTC-USD", opts)`, every fake raised, and assertion 5 counted
  # the raise as conforming, so no venue's order path was ever checked against the `Order` it
  # promises (found 2026-10-10, once 5 stopped doing so). `replace_order/4` has no
  # credentialed arity-4 shape at all, so every position was `opts`, and it raised the same
  # way. `place_orders/3`, `preview_order/3` and `preview_replace/4` were the same shape of
  # mistake and are listed for the same reason.
  @arg_overrides %{
    {:place_order, 3} => [:credentials, :order_request, :opts],
    {:place_orders, 3} => [:credentials, :order_requests, :opts],
    {:preview_order, 3} => [:credentials, :order_request, :opts],
    {:replace_order, 4} => [:credentials, :order_id, :order_changes, :opts],
    {:preview_replace, 4} => [:credentials, :order_id, :order_changes, :opts],
    # **The rest of the callbacks whose arguments are not `(symbol, timeframe, opts...)`.**
    # Found 2026-10-10: by arity alone `stake/3` was called as `stake("BTC-USD", "1h", opts)`
    # — a timeframe where its `Decimal` amount belongs — `withdraw/5` with five keyword lists,
    # `get_fx_rate/3` with `"1h"` for its `DateTime`, `quantization/1` with a keyword list for
    # its symbol. Each fake raised, and assertions 12 and 17 take a raise as an answer, so
    # none of these paths was ever checked. Every position below is the `Core.Venue` spec's.
    {:quantization, 1} => [:symbol],
    {:stake, 3} => [:asset, :amount, :opts],
    {:unstake, 3} => [:asset, :amount, :opts],
    {:quote_conversion, 4} => [:asset, :quote_asset, :amount, :opts],
    {:convert, 4} => [:asset, :quote_asset, :amount, :opts],
    {:get_deposit_address, 3} => [:asset, :network, :opts],
    {:list_networks, 2} => [:asset, :opts],
    {:estimate_withdrawal_fee, 4} => [:asset, :network, :amount, :opts],
    {:withdraw, 5} => [:asset, :network, :amount, :address, :opts],
    {:transfer_internal, 4} => [:asset, :amount, :opts, :opts],
    {:request_approved_address, 4} => [:asset, :network, :address, :opts],
    {:remove_approved_address, 3} => [:asset, :address, :opts],
    {:get_fx_rate, 3} => [:fx_pair, :at, :opts],
    {:get_financials, 3} => [:symbol, :statement_kind, :opts],
    {:create_watchlist, 3} => [:name, :symbols, :opts],
    {:rename_account, 3} => [:account_id, :name, :opts],
    # **Found 2026-10-11 reading the table against the spec once more.** `subscribe/2`,
    # `unsubscribe/2` and `update_symbols/2` take a LIST of symbols and were shaped by arity as
    # `(symbol, opts)`, so every fake-driven assertion that walks the callbacks handed them a
    # bare string; the fake raised in `Enum.map/2` and the raise was taken for an answer.
    # `add_payment_method/2` takes a details MAP and was handed a string the same way.
    {:subscribe, 2} => [:symbols, :opts],
    {:unsubscribe, 2} => [:symbols, :opts],
    {:update_symbols, 2} => [:symbols, :opts],
    {:add_payment_method, 2} => [:payment_details, :opts]
  }

  @order_arg_kinds [:order_request, :order_requests, :order_changes]

  @doc """
  Checks the `order_args:` option of `use DpExchange.Core.AdapterContract`. It must be a map
  whose keys are drawn from `:order_request`, `:order_requests` and `:order_changes`.

  An unknown key raises at compile time instead of being ignored. A misspelt key that was
  silently dropped would leave the suite's default order in place, and the assertion it
  was meant to reach would go on failing, or passing, for a reason nobody declared.
  """
  @spec validate_order_args!(term()) :: %{optional(atom()) => term()}
  def validate_order_args!(order_args) when is_map(order_args) do
    case Map.keys(order_args) -- @order_arg_kinds do
      [] ->
        order_args

      unknown ->
        raise ArgumentError,
              "order_args: accepts only #{inspect(@order_arg_kinds)}, got #{inspect(unknown)}"
    end
  end

  def validate_order_args!(order_args) do
    raise ArgumentError, "order_args: must be a map, got #{inspect(order_args)}"
  end

  @doc """
  How a call to `name/arity` is shaped, position by position: `:credentials`, `:symbol`,
  `:timeframe`, `:opts`, or one of the order arguments.

  `credentialed?` is whether the callback takes its credential positionally — see
  `credentialed_callbacks/0`. A per-callback override wins over the shape the arity implies.
  Both the call assertions and assertion 17's credential-stripped call are built from this one
  table; the stripped call used to rebuild its own and ignore the overrides, so for
  `place_order/3` and `replace_order/4` it sent a malformed order, the fake raised, and
  "no `{:ok, _}` with credentials stripped" held for a reason that had nothing to do with
  credentials.
  """
  @spec arg_shape(atom(), non_neg_integer(), boolean()) :: [atom()]
  def arg_shape(name, arity, credentialed?) do
    kind = if credentialed?, do: :credentialed, else: :public

    case Map.fetch(@arg_overrides, {name, arity}) do
      {:ok, shape} -> shape
      :error -> Map.get(@arg_shapes, {kind, arity}, List.duplicate(:opts, arity))
    end
  end

  @doc """
  What is wrong with a fake's answer to an endpoint its `capabilities/0` declares active,
  or `nil` when nothing is.

    * `:not_supported` — the fake answered `{:error, :not_supported}`: the declaration and the
      behaviour disagree (assertion 12, over-declaring).
    * `:raised` — the call raised. `{:raised, error}` is how the suite's `call_on/3` reports
      it. A raise is not an answer, and treating it as one let a fake that crashed on every
      endpoint pass "does not answer :not_supported".

  Any other answer, refusals and errors included, is not this check's business.
  """
  @spec active_endpoint_fault(term()) :: nil | :not_supported | :raised
  def active_endpoint_fault({:error, :not_supported}), do: :not_supported
  def active_endpoint_fault({:raised, _error}), do: :raised
  def active_endpoint_fault(_answer), do: nil

  @doc """
  Whether `result` is a success that gave assertion 5 a struct to check: `{:ok, struct}` or
  `{:ok, [struct | _]}`.

  Assertion 5 takes a refusal, an error and an empty list as "not a success, so nothing to
  compare", which is right for each answer alone. Across a whole fake it is not: a fake that
  refused every endpoint (a missing `endpoint_opts:`) or returned `{:ok, []}` everywhere
  passed the group having compared nothing. The group requires at least one answer for which
  this is `true`.
  """
  @spec struct_answer?(term()) :: boolean()
  def struct_answer?({:ok, %_struct{}}), do: true
  def struct_answer?({:ok, [%_struct{} | _rest]}), do: true
  def struct_answer?(_result), do: false

  @doc """
  What is wrong with a call's answer to an endpoint `capabilities/0` declares `:unsupported`,
  or `nil` when nothing is. Assertion 12's under-declaring direction.

    * `nil` — `{:error, :not_supported}`, the atom the contract promises.
    * `:string_refusal` — `{:error, "not_supported"}`. A caller matching the atom misses it
      and treats a refusal as an unrecognised error.
    * `:raised` — the call raised (`{:raised, error}` from the suite's `call_on/3`).
    * `:served` — `{:ok, _}`: declared unsupported but it works, which hides functionality a
      consumer could have used.
    * `:other` — any other answer, which is neither the atom nor a success.
  """
  @spec unsupported_fault(term()) :: nil | :string_refusal | :raised | :served | :other
  def unsupported_fault({:error, :not_supported}), do: nil
  def unsupported_fault({:error, "not_supported"}), do: :string_refusal
  def unsupported_fault({:raised, _error}), do: :raised
  def unsupported_fault({:ok, _value}), do: :served
  def unsupported_fault(_answer), do: :other

  @doc """
  What is wrong with a message `subscribe/2` pushed, or `nil` when nothing is. Assertion 20.

  `message` is the `{:dp_exchange, runtime_id, payload}` the suite received and `runtime_id`
  is the venue's own `c:DpExchange.Core.Venue.runtime_id/0`.

    * `:wrong_tag` — tagged with something other than the venue's `runtime_id/0`, so a
      process subscribed to several venues cannot tell them apart. Judged first.
    * `:not_a_core_struct` — the payload is not a `DpExchange.Core.Types.*` struct: raw venue
      data forwarded to subscribers, the shape with a wired decoder that never ran.
  """
  @spec subscribed_push_fault({:dp_exchange, term(), term()}, atom()) ::
          nil | :wrong_tag | :not_a_core_struct
  def subscribed_push_fault({:dp_exchange, tag, payload}, runtime_id) do
    cond do
      tag != runtime_id -> :wrong_tag
      not core_type_struct?(payload) -> :not_a_core_struct
      true -> nil
    end
  end

  defp core_type_struct?(%module{}),
    do: module |> Atom.to_string() |> String.starts_with?("Elixir.DpExchange.Core.Types.")

  defp core_type_struct?(_other), do: false

  @doc """
  The timeframe assertion 21 asks `get_historical_prices/4` for: the first width of
  `Timeframe.nameable/0` that `caps.historical_timeframes` does not name, or `nil` when the
  venue declares the whole vocabulary and there is no width left to prove a refusal with.
  """
  @spec unserved_timeframe(DpExchange.Core.Capabilities.t()) :: String.t() | nil
  def unserved_timeframe(%DpExchange.Core.Capabilities{} = caps) do
    case DpExchange.Core.Timeframe.nameable() -- caps.historical_timeframes do
      [unserved | _rest] -> unserved
      [] -> nil
    end
  end

  @doc """
  What is wrong with a call's answer to a timeframe the venue does not declare, or `nil`.
  Assertion 21.

  `:substituted` is `{:ok, _}`: the venue served the width it has in place of the one asked
  for, a missing granularity becoming the closest one, which mislabels every candle it
  touches. A refusal, an error and a raise are not this check's business.
  """
  @spec timeframe_fault(term()) :: nil | :substituted
  def timeframe_fault({:ok, _candles}), do: :substituted
  def timeframe_fault(_answer), do: nil

  # --- the family conventions (assertions 32-35) ---------------------------------------
  #
  # Every decision below is a public function the macro calls, so each can be shown to fail
  # in `contract_teeth_test.exs` against a module that breaks the convention, instead of
  # being a line inside a quote that only a venue's CI ever runs.

  @doc """
  What is wrong with a call's answer to an argument the family refuses locally, or `nil`.
  Assertions 32 to 35.

  `expected` is the whole error term, for example `{:invalid_symbols, nil}`; the answer must
  be exactly `{:error, expected}`.

    * `:raised` — the call raised, exited or threw (`{:raised, error}`, `{:exit, reason}` or
      `{:throw, value}` from the suite's `call_on/3`). A raise is not a refusal.
    * `{:answered, answer}` — any other answer: `:ok` for a malformed list, `{:ok, _}`,
      `{:error, :feed_not_started}` where a symbol was wrong, a refusal after credentials.
  """
  @spec refusal_fault(term(), term()) :: nil | :raised | {:answered, term()}
  def refusal_fault({:error, expected}, expected), do: nil
  def refusal_fault({:raised, _error}, _expected), do: :raised
  def refusal_fault({kind, _reason}, _expected) when kind in [:exit, :throw], do: :raised
  def refusal_fault(answer, _expected), do: {:answered, answer}

  @doc """
  The calls of `cases` that `module` can be asked, as `{name, args, expected}` triples:
  exported at that arity and not declared `:unsupported` in `caps`.

  A callback a venue legitimately declares `:unsupported` is skipped the way the suite's
  other assertions skip it. It is not a pass: assertion 12 holds the declaration to the
  behaviour.
  """
  @spec eligible_cases(module(), DpExchange.Core.Capabilities.t(), [{atom(), list(), term()}]) ::
          [{atom(), list(), term()}]
  def eligible_cases(module, %DpExchange.Core.Capabilities{} = caps, cases) do
    # Loaded first: `function_exported?/3` is false for a module not yet loaded.
    Code.ensure_loaded(module)

    Enum.filter(cases, fn {name, args, _expected} ->
      arity = length(args)

      function_exported?(module, name, arity) and
        DpExchange.Core.Capabilities.active?(caps, {name, arity})
    end)
  end

  @doc """
  Whether a run of `cases` against `module` examined nothing it should have: no case is
  eligible (`eligible_cases/3`) although `caps` declares at least one of the cases' calls
  active, which means that call is not exported at its arity.

  A venue that declares every call of `cases` `:unsupported` has nothing to hold and is
  `false`; the declaration itself is held by assertion 12.
  """
  @spec nothing_checked?(
          module(),
          DpExchange.Core.Capabilities.t(),
          [{atom(), list(), term()}]
        ) :: boolean()
  def nothing_checked?(module, %DpExchange.Core.Capabilities{} = caps, cases) do
    declared? =
      Enum.any?(cases, fn {name, args, _expected} ->
        DpExchange.Core.Capabilities.active?(caps, {name, length(args)})
      end)

    declared? and eligible_cases(module, caps, cases) == []
  end

  @doc """
  Runs each `{name, args, expected}` of `cases` against `module` and returns the ones whose
  answer is not `{:error, expected}`, as `{name, arity, expected, fault}` with `fault` as
  `refusal_fault/2` names it. Empty means every case was refused as the convention says.

  The arguments are not kept in the result: they carry the suite's credentials, and a failure
  message prints what it is given.
  """
  @spec case_faults(module(), [{atom(), list(), term()}]) ::
          [{atom(), arity(), term(), :raised | {:answered, term()}}]
  def case_faults(module, cases) do
    for {name, args, expected} <- cases,
        fault = refusal_fault(apply_safely(module, name, args), expected),
        do: {name, length(args), expected, fault}
  end

  defp apply_safely(module, name, args) do
    apply(module, name, args)
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {kind, reason}
  end

  @doc """
  A failure message for `case_faults/2`'s result, one line per call that was not refused.
  """
  @spec format_case_faults([{atom(), arity(), term(), term()}]) :: String.t()
  def format_case_faults(faults) do
    Enum.map_join(faults, "\n", fn {name, arity, expected, fault} ->
      "  #{name}/#{arity}: expected {:error, #{inspect(expected)}}, got " <>
        inspect(fault, limit: 8)
    end)
  end

  @doc """
  Symbol lists the streaming calls must refuse as `{:invalid_symbols, value}`: not a list, a
  list holding a non-string or a blank string (whitespace-only is blank), and an improper
  list. `sample` is a symbol the venue serves, so the bad lists are bad for exactly one reason.
  """
  @spec invalid_symbol_lists(String.t()) :: [term()]
  def invalid_symbol_lists(sample) do
    [
      nil,
      sample,
      42,
      [nil],
      [42],
      [:atom],
      [""],
      ["  "],
      [sample, "  "],
      [sample | improper_tail()]
    ]
  end

  # The improper list is the point of the case. Built from a value dialyzer cannot narrow, so
  # the deliberate cons onto a non-list is not reported as a mistake.
  defp improper_tail, do: Application.get_env(:dp_exchange_core, :__improper_list_tail__, "tail")

  @doc """
  `:to` values a streaming call must refuse as `{:invalid_subscriber, value}`: neither a pid
  nor an atom other than `nil`, `true` and `false`. `nil` is not here: it means the caller.
  """
  @spec invalid_subscribers() :: [term()]
  def invalid_subscribers, do: [42, "subscriber", true, false, {:not, :a_pid}]

  @doc """
  The `{name, args, expected}` cases of assertion 32, for the streaming calls given `opts`.

  Every malformed symbol list on `subscribe/2`, `unsubscribe/2` and `update_symbols/2`; every
  bad `:to` on `subscribe/2` and `subscribe_notices/1`; and one call wrong in both ways, which
  must answer for the symbols, because the symbols are checked first. `opts` decides whether
  this drives a fake or the real facade with no feed running.
  """
  @spec streaming_refusal_cases(String.t(), keyword()) :: [{atom(), list(), term()}]
  def streaming_refusal_cases(sample, opts) do
    lists =
      for name <- [:subscribe, :unsubscribe, :update_symbols],
          bad <- invalid_symbol_lists(sample),
          do: {name, [bad, opts], {:invalid_symbols, bad}}

    subscribers =
      for bad <- invalid_subscribers(),
          {name, args} <- [
            {:subscribe, [[sample], Keyword.put(opts, :to, bad)]},
            {:subscribe_notices, [Keyword.put(opts, :to, bad)]}
          ],
          do: {name, args, {:invalid_subscriber, bad}}

    both = {:subscribe, [nil, Keyword.put(opts, :to, 42)], {:invalid_symbols, nil}}

    lists ++ subscribers ++ [both]
  end

  @doc """
  Single-symbol values `get_price/2` and `get_top_of_book/2` must refuse as
  `{:invalid_symbol, value}`: `nil`, a number, and a whitespace-only string.
  """
  @spec invalid_single_symbols() :: [term()]
  def invalid_single_symbols, do: [nil, 42, "  "]

  @doc """
  The `{name, args, expected}` cases of assertion 33. `opts_for` gives the options for a
  callback name; the suite passes options with credentials stripped, because the refusal is
  decided before credentials are read.
  """
  @spec single_symbol_refusal_cases((atom() -> keyword())) :: [{atom(), list(), term()}]
  def single_symbol_refusal_cases(opts_for) when is_function(opts_for, 1) do
    for name <- [:get_price, :get_top_of_book],
        bad <- invalid_single_symbols(),
        do: {name, [bad, opts_for.(name)], {:invalid_symbol, bad}}
  end

  @doc """
  The malformed `place_order/3` requests of assertion 34, as `{request, expected}`, built
  from `base`, a request the venue accepts: a non-map (`{:invalid_order_request, request}`),
  a request with no `:order_type` (`{:missing_field, :order_type}`) and one with a key the
  builder does not read (`{:unsupported_order_field, key}`).
  """
  @spec order_request_cases(map()) :: [{term(), term()}]
  def order_request_cases(base) when is_map(base) do
    [
      {"not-an-order-request", {:invalid_order_request, "not-an-order-request"}},
      {nil, {:invalid_order_request, nil}},
      {[], {:invalid_order_request, []}},
      {Map.delete(base, :order_type), {:missing_field, :order_type}},
      {Map.put(base, :contract_unknown_field, 1),
       {:unsupported_order_field, :contract_unknown_field}}
    ]
  end

  @doc """
  The requests that put a `:price` on a market order, one for each time in force the venue
  might want for it, or `[]` when `caps` does not support `:market`.

  The time in force a venue takes on a market order is the venue's own (one wants `:ioc`, one
  none at all), and the check order is time in force before price fields. So the request is
  sent with no duration and with each duration `caps` names, and `market_price_fault/1`
  judges the set.
  """
  @spec market_price_requests(map(), DpExchange.Core.Capabilities.t()) :: [map()]
  def market_price_requests(base, %DpExchange.Core.Capabilities{} = caps) when is_map(base) do
    if :market in caps.supported_order_types do
      durations = Enum.uniq([nil, Map.get(base, :time_in_force) | caps.supported_time_in_force])
      Enum.map(durations, &market_with_price(base, &1))
    else
      []
    end
  end

  defp market_with_price(base, nil) do
    base
    |> Map.put(:order_type, :market)
    |> Map.delete(:time_in_force)
    # A stop price on the base would be refused alongside the price, and which comes first is
    # the venue's choice; the request must carry the one extra field under test.
    |> Map.delete(:stop_price)
    |> Map.put(:price, Decimal.new("1"))
  end

  defp market_with_price(base, duration),
    do: base |> market_with_price(nil) |> Map.put(:time_in_force, duration)

  @doc """
  What is wrong with the answers to `market_price_requests/2`, or `nil`. Assertion 34.

  Every answer must be `{:error, {:unexpected_field, :price}}` or a refusal of the *duration*
  that was tried (`{:unsupported_order_combination, type, tif}`,
  `{:missing_field, :time_in_force}`, `{:unexpected_field, :time_in_force}`), and at least one
  must be the price refusal.

    * `{:answered, answer}` — an answer that is neither: a success (the price was dropped
      and a different order placed than the one asked for), a raise, any other error.
    * `:price_never_refused` — every duration was refused for being the wrong duration, so
      nothing showed what the venue does with the price.
  """
  @spec market_price_fault([term()]) :: nil | :price_never_refused | {:answered, term()}
  # No answers: the venue declares no `:market`, so `market_price_requests/2` built nothing and
  # there is no price to refuse. Demanding a refusal there failed every venue without market
  # orders (Gemini) for an order type it already refuses as unsupported.
  def market_price_fault([]), do: nil

  def market_price_fault(answers) when is_list(answers) do
    case Enum.find(answers, &(not market_price_answer?(&1))) do
      nil ->
        if {:error, {:unexpected_field, :price}} in answers, do: nil, else: :price_never_refused

      offender ->
        {:answered, offender}
    end
  end

  defp market_price_answer?({:error, {:unexpected_field, field}}),
    do: field in [:price, :time_in_force]

  defp market_price_answer?({:error, {:unsupported_order_combination, _type, _tif}}), do: true
  # A good-till-date duration tried on a market order may name its expiry key rather than
  # `:time_in_force`; that is still the duration being refused, not the price being dropped.
  defp market_price_answer?({:error, {:missing_field, field}}), do: field != :order_type
  defp market_price_answer?(_answer), do: false

  @doc """
  Order ids `get_order/3` and `cancel_order/3` must refuse as `{:invalid_order_id, value}`:
  `nil` and a whitespace-only string.
  """
  @spec invalid_order_ids() :: [term()]
  def invalid_order_ids, do: [nil, "  "]

  @doc """
  The `{name, args, expected}` cases of assertion 35. `opts_for` gives, for a callback name,
  the option lists to try; the suite passes the venue's own options with credentials stripped
  and an empty list, because the id is checked before the account option and before
  credentials.
  """
  @spec order_id_refusal_cases((atom() -> [keyword()])) :: [{atom(), list(), term()}]
  def order_id_refusal_cases(opts_for) when is_function(opts_for, 1) do
    for name <- [:get_order, :cancel_order],
        bad <- invalid_order_ids(),
        opts <- opts_for.(name),
        do: {name, [%{}, bad, opts], {:invalid_order_id, bad}}
  end

  # --- the market-data conventions (assertions 36-39) ----------------------------------
  #
  # As above: each decision is a public function the macro calls, so `contract_teeth_test.exs`
  # can show it fail. They judge what a venue's FAKE returned; they never name transport.

  @invalid_include_partial ["true", "false", 0, 1, :yes]

  @doc """
  The width assertions 36 and 37 ask `get_historical_prices/4` for: `"1h"` when `caps` declares
  it, else the first declared width the shared vocabulary gives a fixed length, else the first
  declared width, or `nil` when none is declared.

  A venue is asked for a width it serves: asking for one it does not would be refused for the
  width before the option under test was ever read.
  """
  @spec probe_timeframe(DpExchange.Core.Capabilities.t()) :: String.t() | nil
  def probe_timeframe(%DpExchange.Core.Capabilities{historical_timeframes: widths}) do
    cond do
      "1h" in widths ->
        "1h"

      fixed = Enum.find(widths, &match?({:ok, _width}, DpExchange.Core.Timeframe.seconds(&1))) ->
        fixed

      true ->
        List.first(widths)
    end
  end

  @doc """
  The `{name, args, expected}` cases of assertion 36: `get_historical_prices/4` with an
  `:include_partial` that is not a boolean must answer `{:error, {:invalid_option,
  :include_partial, value}}`. `nil` is not tried: several venues read it as an absent option.
  """
  @spec include_partial_refusal_cases(String.t(), String.t(), keyword()) ::
          [{atom(), list(), term()}]
  def include_partial_refusal_cases(symbol, timeframe, opts) do
    for bad <- @invalid_include_partial do
      {:get_historical_prices, [symbol, timeframe, [], Keyword.put(opts, :include_partial, bad)],
       {:invalid_option, :include_partial, bad}}
    end
  end

  @session_grid_seconds 1_800

  @doc """
  What is wrong with the candles a fake returned for `timeframe`, or `nil`. Assertion 37.

    * `{:unordered, opened_at}` — a bar that is not later than the one before it. Oldest
      first, strictly.
    * `{:unaligned, opened_at}` — a bar not on its width's grid. The grid is
      `Timeframe.aligned?/2` (strict, UTC), except that for a venue that is not crypto-only
      (`asset_classes`) a width wider than 30 minutes and shorter than a day is
      session-anchored (US equity sessions open at 09:30 ET) and only needs 30-minute
      alignment. Daily and longer bars are mapped to 00:00 UTC of the session date and stay
      strict. Widths the vocabulary does not model are not judged.
  """
  @spec candle_series_fault([struct()], String.t(), [atom()]) ::
          nil | {:unordered | :unaligned, term()}
  def candle_series_fault(candles, timeframe, asset_classes) do
    times = Enum.map(candles, & &1.opened_at)

    Enum.find_value(times, fn at ->
      if not on_grid?(at, timeframe, asset_classes), do: {:unaligned, at}
    end) || ascending_fault(times)
  end

  defp on_grid?(at, timeframe, asset_classes) do
    case DpExchange.Core.Timeframe.seconds(timeframe) do
      {:ok, width} when width > @session_grid_seconds and width < 86_400 ->
        if asset_classes == [:crypto],
          do: DpExchange.Core.Timeframe.aligned?(at, timeframe),
          else: DpExchange.Core.Timeframe.aligned?(at, "30m")

      _strict_or_unmodelled ->
        DpExchange.Core.Timeframe.aligned?(at, timeframe)
    end
  end

  defp ascending_fault(times) do
    times
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn [earlier, later] ->
      if DateTime.compare(earlier, later) != :lt, do: {:unordered, later}
    end)
  end

  @doc """
  The ranges assertion 37 re-asks with, as `{range, must_include}`, chosen from the fake's own
  bars (oldest first). Two or more bars: `start` the first bar's `opened_at` and `end` the last
  one's, which must keep the first and drop the last. One bar: `start` alone (keeps it) and
  `end` alone (drops it). None: nothing to ask.
  """
  @spec candle_range_probes([struct()]) :: [{keyword(), [DateTime.t()]}]
  def candle_range_probes([]), do: []

  def candle_range_probes([only]),
    do: [{[start: only.opened_at], [only.opened_at]}, {[end: only.opened_at], []}]

  def candle_range_probes([first | rest]) do
    [{[start: first.opened_at, end: List.last(rest).opened_at], [first.opened_at]}]
  end

  @doc """
  What is wrong with a ranged answer, or `nil`. `:start` is inclusive and `:end` exclusive, on
  `opened_at`: `{:outside_range, opened_at}` for a bar outside `range`, `{:missing,
  opened_at}` for one of `must_include` that was dropped.

  An answer that is not `{:ok, candles}` is `nil`: a venue may refuse a range its window cannot
  reach, and a refusal is not evidence about the bounds.
  """
  @spec range_fault(keyword(), term(), [DateTime.t()]) ::
          nil | {:outside_range | :missing, DateTime.t()}
  def range_fault(range, {:ok, candles}, must_include) when is_list(candles) do
    times = Enum.map(candles, & &1.opened_at)

    case Enum.find(times, &outside_range?(&1, range)) do
      nil -> missing_fault(times, must_include)
      outside -> {:outside_range, outside}
    end
  end

  def range_fault(_range, _answer, _must_include), do: nil

  defp missing_fault(times, must_include) do
    Enum.find_value(must_include, fn wanted ->
      if not Enum.any?(times, &(DateTime.compare(&1, wanted) == :eq)), do: {:missing, wanted}
    end)
  end

  defp outside_range?(at, range) do
    start = Keyword.get(range, :start)
    finish = Keyword.get(range, :end)

    (start != nil and DateTime.compare(at, start) == :lt) or
      (finish != nil and DateTime.compare(at, finish) != :lt)
  end

  @doc """
  Whether the unbounded candle ask of assertion 37 gave the group anything to check, or
  `{:no_candles, answer}`.

  Only a non-empty `{:ok, candles}` is something to check. A refusal, a raise or an empty
  list used to skip the whole group, which then reported green having examined no candle.
  """
  @spec candle_ask_fault(term()) :: nil | {:no_candles, term()}
  def candle_ask_fault({:ok, [_first | _rest]}), do: nil
  def candle_ask_fault(answer), do: {:no_candles, answer}

  @doc """
  Whether assertion 39 examined nothing: `endpoints` were active but none of their answers
  was checked (`examined` holds one boolean per endpoint, `true` when a value was inspected).

  No active endpoint at all is not a failure (the venue declares them all `:unsupported`).
  """
  @spec nothing_examined?([term()], [boolean()]) :: boolean()
  def nothing_examined?([], _examined), do: false
  def nothing_examined?(_endpoints, examined), do: true not in examined

  @doc "The `:depth` assertion 38 asks for: one level per side."
  @spec book_probe_depth() :: pos_integer()
  def book_probe_depth, do: 1

  @doc """
  What is wrong with the answer to a `depth` request, or `nil`: `{:too_many_levels, side, n}`
  when a side carries more than `depth` levels. A refusal is `nil`; a venue may have a minimum.
  """
  @spec book_depth_fault(term(), pos_integer()) ::
          nil | {:too_many_levels, :bids | :asks, non_neg_integer()}
  def book_depth_fault({:ok, %DpExchange.Core.Types.OrderBook{bids: bids, asks: asks}}, depth) do
    cond do
      length(bids) > depth -> {:too_many_levels, :bids, length(bids)}
      length(asks) > depth -> {:too_many_levels, :asks, length(asks)}
      true -> nil
    end
  end

  def book_depth_fault(_answer, _depth), do: nil

  @doc """
  What is wrong with the answer to a request carrying `limit:`, given the answer `baseline`
  without it, or `nil`. Only what the convention requires: Coinbase refuses `:limit`
  (`{:unsupported_option, :limit}`) because its old option meant depth, while a venue whose
  book has no `:limit` ignores it as Core's usage rules let it, and one with a native `:limit`
  may refuse a value (`{:invalid_option, :limit, v}`). So a success and those two refusals are
  fine; a raise (`:raised`) or any other answer (`{:answered, answer}`) is not. Nothing is
  judged when the baseline itself was not a success.
  """
  @spec book_limit_fault(term(), term()) :: nil | :raised | {:answered, term()}
  def book_limit_fault({:ok, _baseline}, answer) do
    case answer do
      {:ok, _book} -> nil
      {:error, {:unsupported_option, :limit}} -> nil
      {:error, {:invalid_option, :limit, _value}} -> nil
      {kind, _reason} when kind in [:raised, :exit, :throw] -> :raised
      other -> {:answered, other}
    end
  end

  def book_limit_fault(_baseline, _answer), do: nil

  # --- the decisions of the groups whose checks used to live only inside the quoted tests.
  # Each is public so a test can hand it a value that is wrong in one specific way and see it
  # named: a decision that exists only inside a `test` body in a consuming package cannot be
  # shown to fail, and an assertion that cannot be shown to fail is not known to bite.

  @doc """
  What is wrong with one side of an order book a fake returned, or `nil`. Assertion 25.

  `direction` is `:desc` for bids and `:asc` for asks. `{:too_thin, n}`: fewer than two levels,
  which no comparator can order wrongly, so the assertion would pass having checked nothing.
  `{:unreadable_level, level}`: a level that is not `{Decimal, size}`. `{:unsorted, prices}`:
  the prices are not best first.
  """
  @spec book_ordering_fault(term(), :asc | :desc) ::
          nil
          | {:too_thin, non_neg_integer()}
          | {:unreadable_level, term()}
          | {:unsorted, [Decimal.t()]}
  def book_ordering_fault(levels, direction) when direction in [:asc, :desc] do
    cond do
      not is_list(levels) -> {:unreadable_level, levels}
      length(levels) < 2 -> {:too_thin, length(levels)}
      true -> levels_ordering_fault(levels, direction)
    end
  end

  defp levels_ordering_fault(levels, direction) do
    Enum.find_value(levels, &unreadable_price/1) || unsorted_prices(levels, direction)
  end

  defp unreadable_price({%Decimal{}, _size}), do: nil
  defp unreadable_price(other), do: {:unreadable_level, other}

  defp unsorted_prices(levels, direction) do
    prices = Enum.map(levels, &elem(&1, 0))
    if prices != Enum.sort_by(prices, & &1, {direction, Decimal}), do: {:unsorted, prices}
  end

  @doc """
  What is wrong with the times on a struct a fake returned, or `nil`. Assertions 14 and 23.

  `module` is the struct the endpoint promises (`Quote`, `OrderBook` or `TopOfBook`).
  `{:wrong_struct, value}`; `{:observed_at, value}` unless it is a `DateTime`; `{:venue_time,
  value}` unless it is a `DateTime` or `nil`: the venue's own time, never an epoch integer, a
  `NaiveDateTime` or a stand-in.
  """
  @spec time_fault(term(), module()) ::
          nil | {:wrong_struct, term()} | {:observed_at, term()} | {:venue_time, term()}
  def time_fault(%module{} = value, module) do
    cond do
      not match?(%DateTime{}, value.observed_at) -> {:observed_at, value.observed_at}
      is_nil(value.venue_time) or match?(%DateTime{}, value.venue_time) -> nil
      true -> {:venue_time, value.venue_time}
    end
  end

  def time_fault(other, _module), do: {:wrong_struct, other}

  @doc """
  What is wrong with a `Balance` a fake returned, or `nil`. Assertion 24.

  `{:currency, value}` unless it is non-blank text (an amount attributable to no asset cannot
  be sized, booked or reconciled), `{:timestamp, value}` unless a `DateTime`, `{:provider,
  value}` when empty. `:balance` is deliberately not judged: it may honestly be `nil`.
  """
  @spec balance_fault(term()) ::
          nil
          | {:wrong_struct, term()}
          | {:currency | :timestamp | :provider, term()}
  def balance_fault(%DpExchange.Core.Types.Balance{} = value) do
    cond do
      not (is_binary(value.currency) and String.trim(value.currency) != "") ->
        {:currency, value.currency}

      not match?(%DateTime{}, value.timestamp) ->
        {:timestamp, value.timestamp}

      value.provider in [nil, ""] ->
        {:provider, value.provider}

      true ->
        nil
    end
  end

  def balance_fault(other), do: {:wrong_struct, other}

  @doc """
  What is wrong with the volume window on a `Quote` a fake returned, or `nil`. Assertion 30.

  A quote with no volume names no window: `{:window_without_volume, window}`. A quote with a
  volume names which quantity it is (one of `Quote.volume_windows/0`): `{:unstated_window,
  window}`.
  """
  @spec volume_window_fault(term()) ::
          nil | {:wrong_struct, term()} | {:window_without_volume | :unstated_window, term()}
  def volume_window_fault(%ContractQuote{volume: nil, volume_window: nil}), do: nil

  def volume_window_fault(%ContractQuote{volume: nil, volume_window: window}),
    do: {:window_without_volume, window}

  def volume_window_fault(%ContractQuote{volume_window: window}) do
    if window in ContractQuote.volume_windows(), do: nil, else: {:unstated_window, window}
  end

  def volume_window_fault(other), do: {:wrong_struct, other}

  @doc """
  What is wrong with the answer of an endpoint to assertion 5's question, or `nil`: does a
  success hold the `Core.Types` struct (one of `modules`) its callback promises?

  Returns a short description of the offence: a struct of another module, a raw map, a list
  holding something else, or a raise. A refusal or an error is not a success and is not judged.
  """
  @spec answer_type_fault(term(), [module()]) :: nil | String.t()
  def answer_type_fault({:ok, %module{}}, modules),
    do: if(module in modules, do: nil, else: inspect(module))

  def answer_type_fault({:ok, list}, modules) when is_list(list) do
    Enum.find_value(list, fn
      %module{} -> if module in modules, do: nil, else: "a list containing #{inspect(module)}"
      other -> "a list containing #{other |> inspect() |> String.slice(0, 60)}"
    end)
  end

  def answer_type_fault({:ok, %{} = raw}, _modules),
    do: "a raw map #{raw |> inspect() |> String.slice(0, 60)}"

  # A fake that raised did not answer, and counted as conforming: a fake crashing on every
  # endpoint passed this group.
  def answer_type_fault({:raised, error}, _modules),
    do: "a raise: #{error |> Exception.message() |> String.slice(0, 80)}"

  def answer_type_fault(_not_a_success, _modules), do: nil

  @doc """
  What is wrong with a fake's subscription set after four calls, or `nil`. Assertion 26.

  `subscribe/2` adds to the live set, `update_symbols/2` replaces it, `unsubscribe/2` removes
  only what it names; the set is read back through `coverage/1`. Needs two symbols the fake
  serves. The fault names the first rule broken: `{:never_covered, symbol}` (nothing to compare
  with), `{:subscribe_dropped, symbols}`, `{:subscribe_missed, symbol}`,
  `{:unsubscribe_left, symbol}`, `{:unsubscribe_overreached, symbol}`,
  `{:update_not_taken, symbol}` or `{:update_left, symbol}`.
  """
  @spec subscription_set_fault(module(), [String.t(), ...], keyword()) ::
          nil | {atom(), term()}
  def subscription_set_fault(fake, [first, second | _rest], opts) do
    covered = fn -> fake.coverage(opts) |> Map.keys() |> MapSet.new() end

    fake.update_symbols([], opts)
    fake.subscribe([first], opts)
    after_first = covered.()
    fake.subscribe([second], opts)
    after_second = covered.()
    fake.unsubscribe([first], opts)
    after_unsub = covered.()
    fake.update_symbols([first], opts)
    after_update = covered.()

    dropped = after_first |> MapSet.difference(after_second) |> MapSet.to_list()

    [
      {:never_covered, first, not MapSet.member?(after_first, first)},
      {:subscribe_dropped, dropped, dropped != []},
      {:subscribe_missed, second, not MapSet.member?(after_second, second)},
      {:unsubscribe_left, first, MapSet.member?(after_unsub, first)},
      {:unsubscribe_overreached, second, not MapSet.member?(after_unsub, second)},
      {:update_not_taken, first, not MapSet.member?(after_update, first)},
      {:update_left, second, MapSet.member?(after_update, second)}
    ]
    |> Enum.find_value(fn {fault, detail, broken?} -> if broken?, do: {fault, detail} end)
  end

  @doc """
  What is wrong with a fake's `wanted/1`, or `nil`. Assertion 40.

  A fake that does not export `wanted/1` has not adopted the optional callback and is never
  faulted. Otherwise, after `subscribe/2` of `pairs`, `wanted/1` is a list or a `MapSet`
  (`{:not_a_collection, value}`), holds every symbol subscribed
  (`{:subscribed_not_wanted, symbols}`) and holds every symbol `coverage/1` reports
  (`{:covered_not_wanted, symbols}`), because what arrived was asked for. The set is cleared
  with `update_symbols/2` first, so an earlier subscription cannot satisfy it.
  """
  @spec wanted_fault(module(), [String.t()], keyword()) :: nil | {atom(), term()}
  def wanted_fault(fake, pairs, opts) do
    Code.ensure_loaded(fake)

    if function_exported?(fake, :wanted, 1) do
      fake.update_symbols([], opts)
      fake.subscribe(pairs, opts)
      wanted_answer_fault(fake.wanted(opts), pairs, fake.coverage(opts))
    end
  end

  defp wanted_answer_fault(wanted, pairs, coverage) when is_list(wanted) do
    wanted_answer_fault(MapSet.new(wanted), pairs, coverage)
  end

  defp wanted_answer_fault(wanted, pairs, coverage) when is_struct(wanted, MapSet) do
    asked = pairs |> Enum.map(&String.upcase/1) |> MapSet.new()
    missed = asked |> MapSet.difference(wanted) |> MapSet.to_list() |> Enum.sort()

    unasked =
      coverage |> Map.keys() |> MapSet.new() |> MapSet.difference(wanted) |> Enum.sort()

    cond do
      missed != [] -> {:subscribed_not_wanted, missed}
      unasked != [] -> {:covered_not_wanted, unasked}
      true -> nil
    end
  end

  defp wanted_answer_fault(other, _pairs, _coverage), do: {:not_a_collection, other}

  @doc """
  What is wrong with a fake's answers for the two opt-in family reasons, or `nil`. Assertion 41.

  `unlisted` is a well-formed symbol the fake does not list and `price_answer` is what its
  `get_price/2` said for it: anything but `{:refused, :not_listed}` is
  `{:unlisted_symbol, answer}`. `padded_answer` is what a credentialed read said for a
  credentials map with surrounding whitespace, from a venue whose `runtime_id/0` is `venue`:
  anything but `{:error, {:invalid_credentials, venue}}` is `{:padded_credentials, answer}`.
  A `nil` for either answer is a reason the venue did not opt in to, and is not judged.
  """
  @spec family_reason_fault(term(), term(), atom()) :: nil | {atom(), term()}
  def family_reason_fault(price_answer, padded_answer, venue) do
    cond do
      price_answer not in [nil, {:refused, :not_listed}] ->
        {:unlisted_symbol, price_answer}

      padded_answer not in [nil, {:error, {:invalid_credentials, venue}}] ->
        {:padded_credentials, padded_answer}

      true ->
        nil
    end
  end

  @doc """
  What is wrong with a fake's `subscribe/2` given `to: nil`, or `nil`. Assertion 27.

  A forwarded `nil` is a caller that said nothing, and nothing means the caller: it must not
  raise and must deliver to the calling process. `wait` is how long to wait for the delivery.
  `{:raised, error}` or `{:escaped, kind, reason}`; `:nothing_delivered`.
  """
  @spec nil_recipient_fault(module(), [String.t()], keyword(), non_neg_integer()) ::
          nil | {:raised, Exception.t()} | {:escaped, atom(), term()} | :nothing_delivered
  def nil_recipient_fault(fake, pairs, opts, wait) do
    fake.subscribe(pairs, Keyword.put(opts, :to, nil))

    receive do
      {:dp_exchange, _venue, _payload} -> nil
    after
      wait -> :nothing_delivered
    end
  rescue
    error -> {:raised, error}
  catch
    kind, reason -> {:escaped, kind, reason}
  end

  @doc """
  What is wrong with a fake's `subscribe/2` given a lower-case pair, or `nil`. Assertion 29.

  The real facade upper-cases subscribed symbols, so the payload arrives under `pair` (the
  canonical form). `:not_delivered` when nothing arrived under it within `wait` milliseconds.
  """
  @spec lower_case_delivery_fault(module(), String.t(), keyword(), non_neg_integer()) ::
          nil | :not_delivered
  def lower_case_delivery_fault(fake, pair, opts, wait) do
    fake.subscribe([String.downcase(pair)], Keyword.put(opts, :to, self()))

    receive do
      {:dp_exchange, _venue, %{symbol: ^pair}} -> nil
    after
      wait -> :not_delivered
    end
  end

  @doc """
  What is wrong with a streaming call made while no feed runs, or `nil`. Assertion 28.

  `call` is a zero-arity function making the call. A streaming callback returns a value
  (`:ok`, `{:error, _}` or a map); `{:escaped, kind, reason}` when it exited, threw or raised
  in the caller, `{:not_a_value, result}` for any other answer.
  """
  @spec streaming_call_fault((-> term())) ::
          nil | {:escaped, atom(), term()} | {:not_a_value, term()}
  def streaming_call_fault(call) when is_function(call, 0) do
    result =
      try do
        call.()
      catch
        kind, reason -> {:escaped, kind, reason}
      end

    cond do
      match?({:escaped, _kind, _reason}, result) -> result
      result == :ok or match?({:error, _reason}, result) or is_map(result) -> nil
      true -> {:not_a_value, result}
    end
  end

  @doc """
  The identity fault of a venue's `provider_name/0` answer, or `nil`. Assertion 3.
  """
  @spec provider_name_fault(term()) :: nil | {:provider_name, term()}
  def provider_name_fault(name) do
    if is_binary(name) and String.trim(name) != "", do: nil, else: {:provider_name, name}
  end

  @doc """
  The identity fault of a venue's `runtime_id/0` answer, or `nil`. Assertion 3.

  The id is an atom equal to the module's last segment, underscored: `DpExchange.Coinbase` is
  `:coinbase`. `to_string/1` is compared, because `nil`, `true` and `false` stringify to words
  no module segment is.
  """
  @spec runtime_id_fault(module(), term()) :: nil | {:runtime_id, term(), String.t()}
  def runtime_id_fault(venue, id) when is_atom(venue) do
    segment = venue |> Module.split() |> List.last() |> Macro.underscore()
    if is_atom(id) and to_string(id) == segment, do: nil, else: {:runtime_id, id, segment}
  end

  @asset_classes [:crypto, :equity, :option, :future, :event_contract]

  @doc """
  The identity fault of a venue's `asset_classes/0` answer, or `nil`. Assertion 3: a non-empty
  list of the classes a host switches on.
  """
  @spec asset_classes_fault(term()) :: nil | {:asset_classes, term()}
  def asset_classes_fault([_first | _rest] = classes) do
    if Enum.all?(classes, &(&1 in @asset_classes)), do: nil, else: {:asset_classes, classes}
  end

  def asset_classes_fault(other), do: {:asset_classes, other}

  @doc """
  The endpoints `venue_does_not_serve/0` names that `caps` does not declare `:unsupported`.
  Assertion 8: an endpoint the venue does not serve cannot also be one the package answers.
  """
  @spec unrecorded_absences([{atom(), arity()}], DpExchange.Core.Capabilities.t()) ::
          [{atom(), arity()}]
  def unrecorded_absences(venue_absences, %DpExchange.Core.Capabilities{endpoints: endpoints}) do
    unsupported = for {endpoint, :unsupported} <- endpoints, do: endpoint
    Enum.reject(venue_absences, &(&1 in unsupported))
  end

  @stream_pull_pairs [
    quotes: {:get_price, 2},
    top_of_book: {:get_top_of_book, 2},
    trades: {:get_trades, 2},
    candles: {:get_historical_prices, 4}
  ]

  @doc """
  The `{kind, endpoint}` pairs a package declares streamable while saying the venue does not
  serve the matching pull endpoint at all (`absent`). Assertion 8: the two cannot both be
  true.
  """
  @spec streamed_but_absent([{atom(), arity()}], [atom()]) :: [{atom(), {atom(), arity()}}]
  def streamed_but_absent(absent, streamable) do
    for {kind, endpoint} <- @stream_pull_pairs,
        kind in streamable,
        endpoint in absent,
        do: {kind, endpoint}
  end

  @doc """
  The kinds in `streamable` or `authenticated_streamable` that this contract has no word for
  (`Capabilities.data_kinds/0`). Assertion 8.
  """
  @spec unknown_stream_kinds(DpExchange.Core.Capabilities.t()) :: [term()]
  def unknown_stream_kinds(%DpExchange.Core.Capabilities{} = caps) do
    known = DpExchange.Core.Capabilities.data_kinds()

    (caps.streamable ++ caps.authenticated_streamable)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in known))
  end

  @doc """
  Whether a term holds a pid, port or reference anywhere inside it, structs and map keys
  included. Assertion 11: a facade answer is data, never a process the caller must manage.
  """
  @spec carries_process?(term()) :: boolean()
  def carries_process?(term) when is_pid(term) or is_port(term) or is_reference(term),
    do: true

  def carries_process?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.any?(&carries_process?/1)

  def carries_process?(term) when is_list(term), do: Enum.any?(term, &carries_process?/1)

  def carries_process?(%_struct{} = term),
    do: term |> Map.from_struct() |> carries_process?()

  def carries_process?(term) when is_map(term),
    do: Enum.any?(term, fn {key, value} -> carries_process?(key) or carries_process?(value) end)

  def carries_process?(_scalar), do: false

  @doc """
  The optional callbacks `module` implements at the wrong arity, as `{name, arity, arities}`:
  the callback's name is exported at `arities` but not at the one the behaviour declares, so a
  caller at the declared arity gets an `UndefinedFunctionError`. Assertion 1.
  """
  @spec half_implemented_optionals(module()) :: [{atom(), arity(), [arity()]}]
  def half_implemented_optionals(module) do
    Code.ensure_loaded!(module)
    exports = module.__info__(:functions)

    for {name, arity} <- DpExchange.Core.Venue.behaviour_info(:optional_callbacks),
        not function_exported?(module, name, arity),
        other = for({^name, a} <- exports, do: a),
        other != [],
        do: {name, arity, other}
  end

  @positive_fields %{
    DpExchange.Core.Types.Quote => [:price],
    DpExchange.Core.Types.Trade => [:price],
    DpExchange.Core.Types.Candle => [:open, :high, :low, :close]
  }

  @doc """
  What is wrong with a value (or list of values) a fake returned, or `nil`. Assertion 39.

  A traded price (`Quote.price`, `Trade.price`, a candle's open, high, low and close) is above
  zero: `{:non_positive, field, value}`. A `TopOfBook` bid or ask is `nil` or above zero. An
  `OrderBook` level has a price and a size above zero and each side is best first
  (`{:non_positive, {side, :price | :size}, value}`, `{:unreadable_level, side, level}`,
  `{:unsorted, side}`). Any other value is not judged.
  """
  @spec market_value_fault(term()) :: nil | tuple()
  def market_value_fault(values) when is_list(values),
    do: Enum.find_value(values, &market_value_fault/1)

  def market_value_fault(%DpExchange.Core.Types.OrderBook{bids: bids, asks: asks}),
    do: side_fault(:bids, bids, :desc) || side_fault(:asks, asks, :asc)

  def market_value_fault(%DpExchange.Core.Types.TopOfBook{bid: bid, ask: ask}) do
    Enum.find_value([bid: bid, ask: ask], fn {field, value} ->
      if not (is_nil(value) or positive?(value)), do: {:non_positive, field, value}
    end)
  end

  def market_value_fault(%module{} = value) do
    fields = Map.get(@positive_fields, module, [])

    Enum.find_value(fields, fn field ->
      price = Map.get(value, field)
      if not positive?(price), do: {:non_positive, field, price}
    end)
  end

  def market_value_fault(_other), do: nil

  defp side_fault(side, levels, direction) when is_list(levels) do
    Enum.find_value(levels, &level_fault(side, &1)) || order_fault(side, levels, direction)
  end

  defp side_fault(side, other, _direction), do: {:unreadable_level, side, other}

  defp level_fault(side, {price, size}) do
    cond do
      not positive?(price) -> {:non_positive, {side, :price}, price}
      not positive?(size) -> {:non_positive, {side, :size}, size}
      true -> nil
    end
  end

  defp level_fault(side, other), do: {:unreadable_level, side, other}

  defp order_fault(side, levels, direction) do
    prices = Enum.map(levels, &elem(&1, 0))
    if prices != Enum.sort_by(prices, & &1, {direction, Decimal}), do: {:unsorted, side}
  end

  defp positive?(%Decimal{} = value), do: Decimal.positive?(value)
  defp positive?(_other), do: false

  # `test_connection/2` and `get_rate_limit_status/2` are the only two name-based exemptions
  # from assertion 17, and both for the same reason: their own callback doc types the
  # credential `credentials() | nil`. The contract, not a venue's choice, says a missing
  # credential is an expected input there, because both mean "can I reach the venue at all"
  # rather than "give me this venue's data". A denylist of two, not an allowlist of what to
  # check, so it cannot rot into a list nobody updates.
  @credential_gate_exempt ~w(test_connection get_rate_limit_status)a

  @doc """
  The endpoints assertion 17 asks a `credential_benefit: :required` venue's fake to refuse
  when called with credentials stripped.

  Every facade callback that is **answerable** (not `child_spec/1` or `start_link/1`, which
  start something), **active** in `caps`, not one of the two whose own doc types the
  credential `credentials() | nil`, not declared in `Capabilities.no_venue_contact`, and not
  `market_status/1` on a venue whose `asset_classes` are exactly `[:crypto]` (crypto trades
  continuously, so there is no session for a credential to gate).

  This is public, and the assertion calls it, so that the selection can be shown to fail:
  the previous tests of this decision rebuilt it by hand beside the fixtures and asserted
  what the fixtures did, so no change to the decision could break them. The assertion also
  refuses an **empty** result, because a loop over no endpoints reports green having
  examined none.
  """
  @spec credential_gated_endpoints(DpExchange.Core.Capabilities.t(), [atom()]) ::
          [{atom(), arity()}]
  def credential_gated_endpoints(%DpExchange.Core.Capabilities{} = caps, asset_classes) do
    for {name, arity} <- DpExchange.Core.Venue.behaviour_info(:callbacks),
        name not in [:child_spec, :start_link],
        name not in @credential_gate_exempt,
        not (name == :market_status and asset_classes == [:crypto]),
        not DpExchange.Core.Capabilities.no_venue_contact?(caps, {name, arity}),
        DpExchange.Core.Capabilities.active?(caps, {name, arity}),
        do: {name, arity}
  end

  @doc """
  The applications a package may link against: its own, every declared dependency, and what
  those depend on at runtime, as strings.

  `deps` is `Mix.Project.config()[:deps]` in any of Mix's three shapes. The purity assertion
  read it with `for {dep, _rest} <- deps`, which matches a two-element tuple only, so every
  dependency declared with a requirement AND options — `{:jason, "~> 1.4", optional: true}`,
  `{:foo, "~> 1.0", only: :test}` — was silently dropped from the declared set.
  """
  @spec permitted_apps(atom(), [tuple()]) :: MapSet.t(String.t())
  def permitted_apps(app, deps) when is_atom(app) and is_list(deps) do
    roots = [app | Enum.map(deps, &elem(&1, 0))]
    roots |> expand_apps(%{}) |> Map.keys() |> MapSet.new(&Atom.to_string/1)
  end

  # `seen` is a plain map, not a `MapSet`: threading an opaque `MapSet` through this
  # recursion is a dialyzer `call_without_opaque` error.
  defp expand_apps([], seen), do: seen

  defp expand_apps([app | rest], seen) do
    if Map.has_key?(seen, app) do
      expand_apps(rest, seen)
    else
      expand_apps(runtime_applications(app) ++ rest, Map.put(seen, app, true))
    end
  end

  # A dependency not built in this environment has no `.app` to load; it contributes itself
  # and nothing else, which is the right answer for a `only: :dev` tool.
  defp runtime_applications(app) do
    _loaded = Application.load(app)

    List.wrap(Application.spec(app, :applications)) ++
      List.wrap(Application.spec(app, :included_applications))
  end

  @doc """
  The modules in `modules` that belong to an application outside `permitted`.

  `build_lib_dir` is `Path.join(Mix.Project.build_path(), "lib")`. A module found under it
  belongs to the application named by its first path segment. A module found anywhere else is
  OTP or the Elixir standard library and is permitted, and a module found nowhere is a
  host-application module this package depends on without saying so, which is foreign.

  **The previous check could not fire for a dependency.** It looked for `/deps/<name>/` in
  the module's path, but Mix compiles a dependency into `_build/<env>/lib/<name>/ebin` and
  loads it from there, never from `deps/`. Every dependency module therefore matched nothing
  and was permitted, so a package linking an undeclared dependency passed. Only the
  `:non_existing` branch ever rejected anything.
  """
  @spec foreign_modules([module()], MapSet.t(String.t()), Path.t()) :: [module()]
  def foreign_modules(modules, permitted, build_lib_dir) do
    prefix = Path.expand(build_lib_dir) <> "/"
    Enum.reject(modules, &permitted_module?(&1, permitted, prefix))
  end

  defp permitted_module?(module, permitted, prefix) do
    case :code.which(module) do
      path when is_list(path) -> permitted_path?(Path.expand(to_string(path)), permitted, prefix)
      # **Nowhere at all is foreign.** A module this package calls that no loaded
      # application provides is a host-app module it does not depend on.
      :non_existing -> false
      # Cover-compiled: `mix test --cover` recompiles the project's OWN modules in memory,
      # so there is no path to read the app from. Asked of the application controller
      # instead; taking it as permitted made every module of the package under test count
      # as permitted for ANY package, which is exactly what this function decides.
      :cover_compiled -> permitted_app?(Application.get_application(module), permitted)
      # Preloaded (`:erlang`, `:init`): OTP itself.
      _preloaded -> true
    end
  end

  # Deliberate defensive clause, reachable only under `--cover` with a cover-compiled module
  # that no application claims. No such module can be arranged without hand-compiling one
  # through `:cover`, so it is not tested; an unowned module is foreign (fail closed).
  defp permitted_app?(nil, _permitted), do: false
  defp permitted_app?(app, permitted), do: MapSet.member?(permitted, Atom.to_string(app))

  defp permitted_path?(path, permitted, prefix) do
    if String.starts_with?(path, prefix) do
      [app | _rest] = path |> String.replace_prefix(prefix, "") |> Path.split()
      MapSet.member?(permitted, app)
    else
      true
    end
  end

  @doc false
  defmacro __using__(opts) do
    [
      setup(opts),
      completeness(),
      capabilities(),
      identity(),
      symbol_round_trip(opts),
      agreement(),
      agreement_active(),
      both_endpoints(),
      coverage_routes(),
      coverage_by_kind(),
      wanted_callback(),
      family_reasons(),
      top_of_book_assertion(),
      purity(),
      volume_window_stated(),
      isolation(),
      wiring(),
      link_safety(),
      credential_gate(),
      credential_redaction(),
      subscribed_push_shape(),
      historical_timeframe_discipline(),
      venue_and_observed_time(),
      balance_attribution(),
      order_book_ordering(),
      subscription_set_semantics(),
      forwarded_nil(),
      feed_absent(),
      lower_case_subscription(),
      fake_round_trip(),
      streaming_arguments(),
      single_symbol_refusals(),
      order_request_refusals(),
      order_id_refusals(),
      include_partial_refusals(),
      candle_conventions(),
      book_option_conventions(),
      positive_values(),
      convention_helpers(),
      return_types(),
      return_type_helpers(),
      helpers(),
      arg_helpers(),
      subscription_set_helpers(),
      credential_gate_helpers(),
      order_arg_helpers(),
      value_arg_helpers(),
      value_arg_more_helpers(),
      process_helpers()
    ]
  end

  # Each group is its own quoted block rather than one long one. That is a readability
  # rule credo enforces, and it happens to be right here: a 400-line quote is a block
  # nobody reads before adding the 401st line.
  defp setup(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      use ExUnit.Case, async: true

      alias DpExchange.Core.{Capabilities, SymbolNormalizer, Timeframe, Venue}

      @venue Keyword.fetch!(opts, :venue)
      # The venue's in-process fake. Every assertion that calls an ACTIVE endpoint
      # (assertions 12, 14, 17, 20, 21) runs against this and never against the real
      # venue — calling an active endpoint for real is a live network request, and a
      # tier-1 run that reaches a third party's API is tier 1 in name only.
      @fake Keyword.get(opts, :fake)
      @symbol_format Keyword.get(opts, :symbol_format)
      @sample_pairs Keyword.get(opts, :sample_pairs, [])
      @credentials Keyword.get(opts, :credentials, %{})
      @package_root Keyword.get(opts, :package_root, "lib")

      # Per-endpoint options a venue's fake needs before it will answer at all, as
      # `%{{name, arity} => keyword()}`. Empty for a venue whose endpoints need none.
      #
      # **This exists because three venues were passing assertions that never ran.** Several
      # fake-driven assertions call an active endpoint with `opts: []`, and on an
      # account-scoped venue every one of those calls is refused before it reaches the
      # behaviour under test: `dp_exchange_webull` needs an `:account_id`,
      # `dp_exchange_robinhood` an `:account_number`, `dp_exchange_schwab` an account hash.
      # The assertions then took the refusal as a legitimate answer and skipped — a green
      # test proving nothing, which is worse than a red one.
      #
      # Caught on assertion 24: breaking each venue's fake on purpose failed two packages
      # and left three green. It is not confined to 24 — assertion 17 strips credentials and
      # expects a failure, and on these same three venues it got one for the missing account
      # rather than the missing credential, passing for the wrong reason.
      #
      # The KEY is the venue's, not Core's: `:account_id` and `:account_number` are venue
      # facts, and a lookup table of them here would be exactly the venue-specific knowledge
      # this contract is built to keep out of Core. The venue declares its own.
      @endpoint_opts Keyword.get(opts, :endpoint_opts, %{})

      # Per-venue order arguments, as `%{kind => value}` with `kind` one of
      # `:order_request`, `:order_requests` or `:order_changes`, each replacing the suite's
      # generic default. Found 2026-10-11 when assertion 31 began driving `replace_order/4`
      # and `place_orders/3`: the generic `%{price: 1}` edit and the `:gtc` batch entry
      # break venue rules the fakes faithfully enforce. Coinbase's edit needs both size and
      # price, Schwab's replace is a whole order, and Webull's batch refuses `:gtc`. Those
      # are venue facts, so, as with `endpoint_opts:`, the venue declares them.
      @order_args DpExchange.Core.AdapterContract.validate_order_args!(
                    Keyword.get(opts, :order_args, %{})
                  )

      # The options that point the venue's streaming calls at a feed nothing registered.
      # Assertion 28 drives the REAL facade with them, not the fake, and only down the
      # no-feed path, so nothing starts and nothing reaches the network. `:feed` is the key
      # all five packages read when this was written. A venue that names its feed another
      # way passes its own.
      @absent_feed_opts Keyword.get(opts, :absent_feed_opts,
                          feed: :dp_exchange_contract_absent_feed
                        )

      # Per-endpoint sample symbol, as `%{{name, arity} => symbol}`, for the endpoint whose
      # coverage is narrower than `sample_pairs:`. Empty for a venue where one symbol suits
      # every endpoint.
      #
      # `dp_exchange_webull` is the case: it serves an order book for US stocks and ETFs and
      # refuses one for a crypto pair — deliberately, since the venue publishes no crypto
      # depth endpoint and the fake "refuses it the same way the real package does rather
      # than inventing a book". Its `sample_pairs:` are crypto, so assertion 23's
      # `get_order_book/2` arm could only ever see that refusal.
      #
      # The alternative was to keep treating the refusal as a skip, which is how these
      # assertions came to run on one venue in five. Naming a symbol the endpoint actually
      # serves makes the assertion RUN instead, which is the point of having it.
      @endpoint_symbols Keyword.get(opts, :endpoint_symbols, %{})

      # **Opt-in, default skip: facts only the venue's fixture knows.** Assertion 41 holds the
      # fake to two family reasons it can only be driven into with venue knowledge, and a
      # venue that has not supplied the fixture is not failed for lacking it:
      #
      #   * `unlisted_symbol:` — a well-formed symbol the fake does not list. `get_price/2` on
      #     it must answer `{:refused, :not_listed}`.
      #   * `padded_credentials:` — a credentials map whose values carry surrounding
      #     whitespace. A credentialed read must answer
      #     `{:error, {:invalid_credentials, runtime_id}}`.
      @unlisted_symbol Keyword.get(opts, :unlisted_symbol)
      @padded_credentials Keyword.get(opts, :padded_credentials)
    end
  end

  defp completeness do
    quote location: :keep do
      # --- 1. behaviour completeness --------------------------------------

      describe "1. behaviour completeness" do
        test "implements every required facade callback" do
          Code.ensure_loaded!(@venue)

          missing =
            Enum.reject(Venue.required_callbacks(), fn {name, arity} ->
              function_exported?(@venue, name, arity)
            end)

          assert missing == [],
                 "#{inspect(@venue)} is missing required facade callbacks: #{inspect(missing)}"
        end

        test "declares the facade behaviour" do
          behaviours =
            @venue.module_info(:attributes)
            |> Keyword.get_values(:behaviour)
            |> List.flatten()

          assert Venue in behaviours,
                 "#{inspect(@venue)} must declare @behaviour DpExchange.Core.Venue — the " <>
                   "compiler's missing-callback check is the cheapest of these assertions"
        end

        # **Several groups below skip, or loop zero times, when `sample_pairs:` is empty.**
        # 14, 20, 23 and 25 are guarded by `@sample_pairs != []` and report green having run
        # nothing; 29 iterates `Enum.take(pairs, 1)` and passes on an empty list. Assertion 4
        # already refuses an empty list for the round trip, but only for a venue that names a
        # `symbol_format:`. A venue configured without pairs therefore passed the whole suite
        # for having checked almost none of it, which is worse than a red run. Stated once,
        # here, rather than in each group.
        test "the suite is configured with a fake and sample pairs to drive it" do
          assert @fake,
                 "`fake:` is not set, so every fake-driven group has nothing to drive. " <>
                   "Pass the venue's in-process fake."

          assert @sample_pairs != [],
                 "`sample_pairs:` is empty, so groups 14, 20, 23, 25 and 29 skip or loop " <>
                   "zero times and report green having checked nothing. Name at least two " <>
                   "pairs this venue lists."
        end

        test "optional callbacks are implemented or absent, never half" do
          # "Half" is the callback's NAME exported at some other arity and not at the one the
          # behaviour declares: a consumer calling it at the declared arity gets an
          # `UndefinedFunctionError`, and `function_exported?/3` at that arity says absent
          # while the module plainly meant to implement it. It asserted `is_boolean/1` of
          # `function_exported?/3`, which is always true. The decision is
          # `AdapterContract.half_implemented_optionals/1`, public so it can be shown to fail.
          half = DpExchange.Core.AdapterContract.half_implemented_optionals(@venue)

          assert half == [],
                 "#{inspect(@venue)} implements an optional callback at the wrong arity " <>
                   "(`{name, declared arity, arities exported}`): #{inspect(half)}"
        end
      end
    end
  end

  defp capabilities do
    quote location: :keep do
      # --- 2. capabilities ------------------------------------------------

      describe "2. capabilities" do
        test "returns a validated declaration" do
          assert %Capabilities{} = caps = @venue.capabilities()

          # Rebuilding through new/1 runs the raising validations. A declaration
          # assembled with %Capabilities{} directly would skip every invariant.
          assert %Capabilities{} = Capabilities.new(Map.from_struct(caps))
        end

        test "declared candle widths are in the shared vocabulary" do
          # `nameable/0`, not `known/0`. The vocabulary of *labels* is deliberately wider
          # than the set Core can *bucket*: `1w`, `1M` and `1y` have no boundary rule and
          # never will, because a weekly bar's start depends on the venue's week, a month
          # is not a fixed number of seconds, and neither is a year. A venue that
          # genuinely serves them must be able to say so — the alternative is
          # under-declaring what it serves.
          caps = @venue.capabilities()
          assert caps.historical_timeframes -- Timeframe.nameable() == []
        end

        test "a claim of history names the widths it serves" do
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_historical_prices, 4}) and
               Map.has_key?(caps.endpoints, {:get_historical_prices, 4}) do
            assert caps.historical_timeframes != [],
                   "the backfill would iterate nothing and report success"
          end
        end

        test "authenticated streaming is a subset of streaming" do
          caps = @venue.capabilities()
          assert caps.authenticated_streamable -- caps.streamable == []
        end

        test "capabilities/0 needs no credentials and no network" do
          # A consumer decides whether to use the package at all from this, so it has to
          # be answerable at boot.
          task = Task.async(fn -> @venue.capabilities() end)
          assert %Capabilities{} = Task.await(task, 5_000)
        end
      end
    end
  end

  defp identity do
    quote location: :keep do
      # --- 3. identity ----------------------------------------------------

      describe "3. identity" do
        test "provider_name/0 is a non-empty string" do
          name = @venue.provider_name()

          assert DpExchange.Core.AdapterContract.provider_name_fault(name) == nil,
                 "provider_name/0 is #{inspect(name)}; it must be a non-blank string"
        end

        # It asserted `is_atom/1` only, which `nil` passes, and so does `:foo` on
        # `DpExchange.Coinbase`. The name says what it means: the module's last segment,
        # underscored — `DpExchange.Coinbase` is `:coinbase`.
        test "runtime_id/0 is an atom matching the namespace segment" do
          id = @venue.runtime_id()

          # The decision is `AdapterContract.runtime_id_fault/2`: it compares `to_string/1`
          # with the segment, because `nil`, `true` and `false` stringify to words no module
          # segment is, and comparing `id` with those atoms directly warns under the type
          # checker, which knows each venue's literal `runtime_id/0`.
          assert DpExchange.Core.AdapterContract.runtime_id_fault(@venue, id) == nil,
                 "runtime_id/0 is #{inspect(id)}; it must be the atom of #{inspect(@venue)}'s " <>
                   "last segment, underscored"
        end

        test "asset_classes/0 is a non-empty list of known classes" do
          classes = @venue.asset_classes()

          # The vocabulary a host switches on. It widened from `[:crypto, :equity]` on
          # 2026-09-01, when the first package started serving option, futures and
          # event-contract endpoints — a class a venue serves and cannot declare is a class
          # the host cannot route to. See `AdapterContract.asset_classes_fault/1`.
          assert DpExchange.Core.AdapterContract.asset_classes_fault(classes) == nil,
                 "asset_classes/0 is #{inspect(classes)}; it must be a non-empty list of " <>
                   "[:crypto, :equity, :option, :future, :event_contract]"
        end
      end
    end
  end

  defp symbol_round_trip(opts) do
    quote bind_quoted: [opts: opts], location: :keep do
      # --- 4. symbol round-trip -------------------------------------------

      if Keyword.get(opts, :symbol_format) do
        describe "4. symbol round-trip" do
          test "the format module implements the normaliser contract" do
            behaviours =
              @symbol_format.module_info(:attributes)
              |> Keyword.get_values(:behaviour)
              |> List.flatten()

            assert SymbolNormalizer in behaviours
          end

          test "to_canonical(to_exchange(pair)) == pair for the sample pairs" do
            # An empty `sample_pairs:` made this loop zero times and pass with nothing
            # checked. Found 2026-10-10 by reading the suite.
            assert @sample_pairs != [],
                   "`sample_pairs:` is empty, so the round trip was checked for no pair — " <>
                     "name at least one pair this venue lists"

            for pair <- @sample_pairs do
              round_tripped =
                pair
                |> @symbol_format.to_exchange_symbol()
                |> @symbol_format.to_canonical_symbol()

              assert round_tripped == pair,
                     "#{pair} round-tripped to #{round_tripped} — this is where a " <>
                       "USD/USDT confusion silently changes which pair is traded"
            end
          end

          test "the round trip holds over every quote the venue declares" do
            # Generated rather than sampled: the sample pairs are the ones someone
            # thought of, and the bug this catches lives in the ones they did not.
            caps = @venue.capabilities()

            assert caps.supported_quotes != [],
                   "capabilities().supported_quotes is empty, so the round trip was checked " <>
                     "over no quote — declare the quotes this venue trades against"

            for quote_asset <- caps.supported_quotes, base <- ~w(BTC ETH SOL) do
              pair = "#{base}-#{quote_asset}"

              round_tripped =
                pair
                |> @symbol_format.to_exchange_symbol()
                |> @symbol_format.to_canonical_symbol()

              assert round_tripped == pair, "#{pair} round-tripped to #{round_tripped}"
            end
          end

          test "both directions are total — malformed input does not raise" do
            for input <- ["", "NOTAPAIR", "---", "btc-usd", "BTC-"] do
              assert is_binary(@symbol_format.to_canonical_symbol(input))
              assert is_binary(@symbol_format.to_exchange_symbol(input))
            end
          end
        end
      end
    end
  end

  # Every fake call inside this group builds its arguments with `endpoint_args/2`, never by
  # hand. The `get_symbols/1` call here already carried `credentials:`, so it was not among
  # the assertions found inert — but assertions 14 and 23 hand-built theirs too and, by
  # omitting exactly that, ran on one venue in five. One builder for every call site means a
  # venue's `endpoint_opts` and `endpoint_symbols` reach all of them and no call can drift
  # back out of the mechanism.
  #
  # The note lives out here rather than beside the call because everything inside the
  # `quote` counts toward credo's long-quote ceiling — which this comment tripped when it
  # was written inline, and which is the same reason each assertion group is its own quoted
  # block rather than one long one.
  defp agreement do
    quote location: :keep do
      # --- 6, 12. error discipline and agreement ---------------------------

      describe "12. capabilities and behaviour agree, in both directions" do
        test "the order-shape claims match what the facade actually answers" do
          # `supports_order_preview` and `supports_order_replace` are claims a consumer
          # routes on. A venue declaring one and refusing the call sends a caller down a
          # path that cannot run, and a venue serving one without declaring it is invisible
          # — which on `replace_order/4` costs risk, since the alternative is a window with
          # no order live.
          #
          # Driven against the venue's FAKE, never the real venue: `preview_order/3` and
          # `replace_order/4` are active, signed write-shaped endpoints on several venues
          # in this family, and calling either for real would make every ordinary `mix
          # test` run dial the live API — exactly the tier-2 violation D7 forbids on a
          # schedule.
          assert @fake,
                 "pass `fake:` to run this assertion. Calling preview_order/3 and " <>
                   "replace_order/4 on the real venue would make every CI run hit the " <>
                   "live API, which D7 reserves for tier 2 and for a human choosing to " <>
                   "run it."

          caps = @venue.capabilities()
          credentials = @credentials

          for {field, {name, arity}, args} <- [
                {:supports_order_preview, {:preview_order, 3}, [credentials, %{}, []]},
                {:supports_order_replace, {:replace_order, 4}, [credentials, "id", %{}, []]}
              ] do
            declared = Map.fetch!(caps, field)
            answers? = apply(@fake, name, args) != {:error, :not_supported}

            assert declared == answers?,
                   "#{field} is #{inspect(declared)} but #{name}/#{arity} " <>
                     "#{if answers?, do: "answers", else: "returns :not_supported"}"
          end
        end

        test "catalog_access matches how get_symbols/1 behaves without a query" do
          # `:query_only` is only true if the venue actually demands a term. A venue
          # declaring it and then returning a list has declared a restriction it does not
          # have, which is as misleading as the reverse.
          #
          # Driven against the venue's FAKE, never the real venue: `get_symbols/1` is an
          # active, uncredentialed endpoint on several venues in this family, so calling
          # it for real would make every ordinary `mix test` run dial the live API —
          # reproduced live against `api.gemini.com/v1/symbols` before this was fixed.
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_symbols, 1}) do
            assert @fake,
                   "pass `fake:` to run this assertion. Calling get_symbols/1 on the " <>
                     "real venue would make every CI run hit the live API, which D7 " <>
                     "reserves for tier 2 and for a human choosing to run it."

            # `apply/3` because this suite is GENERIC over a fake the consuming package
            # supplies, and a direct call lets the compiler specialise on whichever one
            # happens to be compiling. When that fake returns only `{:ok, _}` — Core's own
            # reference venue does — every `{:error, _}` branch below is reported as "this
            # clause will never match", for branches that are reachable in the packages that
            # need them: `dp_exchange_schwab` genuinely answers `{:error, {:query_required,
            # _}}` here, which is the whole reason `catalog_access` has a `:query_only`
            # value. Silencing it per-package would mean every future venue with a simple
            # fake inheriting mystery warnings out of a shared macro.
            #
            # `endpoint_args/2`, never a hand-built arg list — see this function's own
            # comment, above the `quote`, for what hand-building cost.
            #
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            result = apply(@fake, :get_symbols, endpoint_args(:get_symbols, 1))

            case caps.catalog_access do
              :query_only ->
                assert match?({:error, _reason}, result),
                       "catalog_access is :query_only but get_symbols/1 answered without a query"

              :enumerable ->
                refute match?({:error, {:query_required, _venue}}, result),
                       "get_symbols/1 demands a query but catalog_access says :enumerable"
            end
          end
        end

        test "every declared endpoint is a real facade callback" do
          caps = @venue.capabilities()
          callbacks = Venue.behaviour_info(:callbacks)

          for {endpoint, _maturity} <- caps.endpoints do
            assert endpoint in callbacks,
                   "#{inspect(endpoint)} is declared but is not a facade callback — a " <>
                     "declaration about a function nobody can call"
          end
        end

        test "an :unsupported endpoint returns the atom, and does not raise" do
          caps = @venue.capabilities()

          for endpoint <- Capabilities.endpoints_at(caps, :unsupported) do
            result = call_endpoint(endpoint)

            # The decision is `AdapterContract.unsupported_fault/1`, public so the teeth
            # tests run the suite's own logic and not a copy of it.
            assert DpExchange.Core.AdapterContract.unsupported_fault(result) == nil,
                   "#{inspect(endpoint)} declares :unsupported but did not return " <>
                     "{:error, :not_supported} — the atom, never the string. Got " <>
                     "#{inspect(result, limit: 8)}"
          end
        end
      end
    end
  end

  # The second half of group 12, apart from `agreement/0` so neither quoted block passes
  # credo's length ceiling.
  defp agreement_active do
    quote location: :keep do
      describe "12. capabilities and behaviour agree — active endpoints" do
        test "an active endpoint does not answer :not_supported" do
          # Under-declaring hides working functionality; over-declaring fails in the
          # caller's hands. Only checking one direction leaves the other open.
          #
          # Driven against the venue's FAKE, never the real venue. Calling an active
          # endpoint for real is a network request, and a tier-1 run that reaches a third
          # party's API is tier 1 in name only — it would hit the live venue from every CI
          # run of every consumer. The `:unsupported` direction is safe against the real
          # venue precisely because those endpoints return without going anywhere.
          assert @fake,
                 "pass `fake:` to run this assertion. Calling active endpoints on the " <>
                   "real venue would make every CI run hit the live API, which D7 " <>
                   "reserves for tier 2 and for a human choosing to run it."

          caps = @venue.capabilities()

          # Enumerated from EVERY facade callback and asked through `active?/2`, not from
          # `Capabilities.endpoints_at(caps, :proven) ++ endpoints_at(caps, :experimental)`.
          # `endpoints_at/2` iterates only the EXPLICIT entries in `caps.endpoints` — but
          # `Capabilities`'s own moduledoc makes an ABSENT entry active too ("anything not
          # named in the map is :experimental — the only honest default"). An endpoint
          # never mentioned in `endpoints` at all was therefore active by that same
          # default and invisible to the old enumeration regardless — under-declaring by
          # silence passed the exact check that catches under-declaring by a wrong value.
          # See `DpExchange.Core.ContractTeethTest`'s `Broken.SilentlyUnsupported`.
          # An `@optional_callbacks` entry the fake does not define at all is not a raise to
          # report: leaving it out is what "optional" allows (see `Venue`'s moduledoc).
          optional = Venue.behaviour_info(:optional_callbacks)
          Code.ensure_loaded(@fake)

          for endpoint <- Venue.behaviour_info(:callbacks),
              answerable?(endpoint),
              Capabilities.active?(caps, endpoint),
              endpoint not in optional or
                function_exported?(@fake, elem(endpoint, 0), elem(endpoint, 1)) do
            result = call_on(@fake, endpoint)

            # A raise is not an answer. `call_on/3` returns it as `{:raised, error}`, which
            # is `!= {:error, :not_supported}`, so a fake that crashed on an active
            # endpoint used to pass this check for the wrong reason (the same hole assertion
            # 5's `answer_type_fault/2` closes for struct-typed callbacks). The decision is
            # `AdapterContract.active_endpoint_fault/1`, public so it can be shown to fail.
            case DpExchange.Core.AdapterContract.active_endpoint_fault(result) do
              nil ->
                :ok

              :not_supported ->
                flunk(
                  "#{inspect(endpoint)} is active (declared, or by the undeclared-is-" <>
                    "experimental default) but the fake answered :not_supported — the " <>
                    "fake and the declaration disagree"
                )

              :raised ->
                flunk(
                  "#{inspect(endpoint)} is active but the fake RAISED instead of " <>
                    "answering: #{inspect(result, limit: 8)}. A raise is not a " <>
                    "{:error, _} — if the call needs an option, declare it in " <>
                    "`endpoint_opts:`; if the venue cannot serve it, declare it :unsupported"
                )
            end
          end
        end

        test "every core endpoint carries an explicit maturity" do
          # Asserted for PRESENCE, not truth. An absent value is the failure this
          # prevents; whether a :proven claim is true is not machine-checkable, and a
          # suite that pretended otherwise would be worse than one admitting the limit.
          caps = @venue.capabilities()

          undeclared =
            Enum.reject(Venue.core_endpoints(), &Map.has_key?(caps.endpoints, &1))

          assert undeclared == [],
                 "core endpoints with no declared maturity: #{inspect(undeclared)}"
        end
      end
    end
  end

  defp both_endpoints do
    quote location: :keep do
      # --- 8. both endpoints answer ----------------------------------------

      describe "8. both endpoints answer — no flag, no exceptions" do
        test "the pull endpoints are not refused wholesale" do
          caps = @venue.capabilities()

          assert Capabilities.active?(caps, {:get_symbols, 1}),
                 "every venue can be pulled; there is no flag for it"
        end

        test "subscribe is never :unsupported" do
          # A venue whose upstream API is REST-only passes by polling internally and
          # pushing the results. That is the package's job, not the caller's problem.
          caps = @venue.capabilities()

          assert Capabilities.active?(caps, {:subscribe, 2}),
                 "every venue can be subscribed; a REST-only venue polls and pushes"
        end

        test "every absence has a recorded cause" do
          # **A callback declared `:unsupported` must be filed under one of two causes**:
          # the venue does not serve it, or this package has not ported it. Both answer a
          # caller identically and only one can ever change, so a host planning around a gap
          # needs to know which it is looking at.
          #
          # The mislabel goes both ways and both are defects. A venue's own absence filed as
          # a backlog item invents work that cannot be done and quietly implies an endpoint
          # the vendor does not publish; a backlog item filed as the venue's absence hides a
          # capability a consumer could have had. **Robinhood shipped four of the first kind
          # and no test failed** — nothing fails when a comment is wrong, which is why this
          # is an assertion rather than a review note.
          #
          # A package that does not implement `venue_does_not_serve/0` is exempt: the split
          # is optional in the contract. One that *does* must account for every absence.
          caps = @venue.capabilities()

          if function_exported?(@venue, :venue_does_not_serve, 0) do
            # `apply/3`, and the credo exemption is deliberate. This is an OPTIONAL callback
            # guarded by `function_exported?/3` one line up, so the module being called is
            # not knowable at compile time — which is exactly what `apply/3` says and a
            # direct call does not.
            #
            # This used to bind `venue = @venue` and call `venue.venue_does_not_serve()`, on
            # the stated reasoning that going through a variable dodged the warning while
            # `apply/3` "would say the same thing and credo objects". **The first half
            # stopped being true and the comment did not.** Elixir 1.18 tracks the binding
            # through, so the warning came back and this package emitted it on every test
            # run — a mitigation that no longer mitigated, still carrying a comment claiming
            # it did. Verified by compiling: the warning is gone with `apply/3` and present
            # without it.
            #
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            venue_absences = apply(@venue, :venue_does_not_serve, [])

            stray = DpExchange.Core.AdapterContract.unrecorded_absences(venue_absences, caps)

            assert stray == [],
                   "venue_does_not_serve/0 names endpoints that are not declared " <>
                     ":unsupported: #{inspect(stray)}. An endpoint the " <>
                     "venue does not serve cannot also be one this package answers."
          end
        end

        test "streamable names only kinds this contract has a word for" do
          # `streamable` is the one declaration a consumer cannot check for itself: it is a
          # claim about what `subscribe/2` delivers, and a kind that arrives by no route
          # produces silence rather than an error.
          #
          # **This is the assertion that would have caught a real over-declaration.** One
          # package declared six streamable kinds while its socket was written, tested and
          # never called by the facade — four of the six reached no subscriber by any route,
          # and every test passed for a release. A structural check cannot prove delivery,
          # but it can refuse a vocabulary this contract does not define, which is where
          # over-declaration usually starts.
          unknown = DpExchange.Core.AdapterContract.unknown_stream_kinds(@venue.capabilities())

          assert unknown == [],
                 "streamable declares kinds this contract has no word for: " <>
                   "#{inspect(unknown)}"
        end

        test "a declared streaming kind is not contradicted by its own pull endpoint" do
          # Where a venue streams a kind it also pulls, the pull must not be declared
          # `:unsupported` **for the reason that the venue lacks it**. The two can differ
          # legitimately — depth over a socket and none over REST is a real shape — so this
          # asserts only the contradiction that cannot be true: an endpoint listed in
          # `venue_does_not_serve/0` whose kind the same package claims to stream.
          caps = @venue.capabilities()

          if function_exported?(@venue, :venue_does_not_serve, 0) do
            # See assertion 12's call site for why this is `apply/3` and why the credo
            # exemption is deliberate.
            #
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            absent = apply(@venue, :venue_does_not_serve, [])

            contradictions =
              DpExchange.Core.AdapterContract.streamed_but_absent(absent, caps.streamable)

            assert contradictions == [],
                   "these kinds are declared streamable while the same package says the " <>
                     "venue does not serve them at all: #{inspect(contradictions)}"
          end
        end
      end
    end
  end

  # Split out of `both_endpoints/0` rather than added to it. That block had grown past
  # credo's `Avoid long quote blocks` ceiling, which this file already treats as the same
  # "400-line block nobody reads" its groups exist to avoid — see `credential_gate_helpers/0`
  # for the same split made for the same reason. Same assertion group, same number; only the
  # quoted block is separate.
  defp coverage_routes do
    quote location: :keep do
      describe "8. coverage/1 reports observed routes" do
        test "coverage/1 reports observed routes only" do
          # **This used to iterate `@venue.coverage([])`, which is `%{}` on every package in
          # this family** — measured, all five, because nothing is subscribed and `coverage/1`
          # reports what is actually arriving. The loop ran zero times and the test passed
          # unconditionally, on every venue, from the day it was written.
          #
          # That is a step past the case `docs/reference/core/assertion-coverage.md` records
          # under "Third axis", where one venue's fixture was too thin. Here no fixture was
          # reached at all: the assertion called the REAL module, which cannot have coverage
          # in a suite that starts no feed.
          #
          # The structural half is worth keeping, and is now stated as its own claim rather
          # than as the silent precondition of a loop.
          assert @venue.coverage([]) == %{},
                 "coverage/1 must answer an empty map when nothing is subscribed — a venue " <>
                   "reporting coverage for symbols no one asked for is reporting a claim, " <>
                   "which is the thing this callback exists not to do"

          # The behavioural half drives the FAKE, the way every other fake-driven assertion
          # here does, and subscribes first so that there is something to report. The
          # non-emptiness check is not decoration: without it, a fake that quietly stopped
          # reporting coverage would put this test straight back to passing for having looked
          # at nothing, which is exactly how it got here.
          #
          # **What this does not catch, stated plainly:** the real feed's own coverage
          # bookkeeping. The suite drives fakes; each venue's feed tests hold the real one.
          if @fake, do: assert_fake_coverage_routes(@fake, @sample_pairs)
        end

        # Guarded at the CALL SITE, not with a `nil` head here. `@fake` is a literal module in
        # every package that names one, so a `nil` clause is unreachable code the compiler
        # rejects under `--warnings-as-errors`.
        defp assert_fake_coverage_routes(fake, pairs) do
          opts = arg_value(:opts, {:subscribe, 2})
          fake.subscribe(pairs, opts)
          covered = fake.coverage(opts)

          assert covered != %{},
                 "the fake reported no coverage after subscribing #{inspect(pairs)}, so every " <>
                   "route assertion below it executes zero times and this test passes for " <>
                   "having checked nothing. Either `subscribe/2` did not take (the fake may " <>
                   "need something `endpoint_opts:` should carry), or the sample pairs are " <>
                   "symbols this venue does not serve — `dp_exchange_schwab` reports nothing " <>
                   "for a crypto pair, and names equities in `sample_pairs:` for that reason."

          for {_symbol, route} <- covered do
            assert route in [:stream, :internal_poll, :not_covered],
                   "coverage must report an observed route, never a claim"
          end
        end
      end
    end
  end

  defp coverage_by_kind do
    quote location: :keep do
      # --- 15. coverage by kind (optional) ---------------------------------
      #
      # `coverage_by_kind/1` is in `Venue.@optional_callbacks`, deliberately: Core
      # publishes it before any venue adopts it, and a required callback here would mean
      # every venue depending on Core from Hex instantly fails completeness — the exact
      # cross-repo coupling that caused a premature-deploy incident once already. So an
      # ABSENT callback is a venue that has not adopted yet, NOT a failure, and this
      # group asserts nothing at all in that case. Do not "fix" the `if` below into an
      # unconditional assertion — that turns an optional callback back into a required
      # one from the suite's side, which is the coupling this design refused.

      describe "15. coverage by kind" do
        test "when exported, its union of symbols matches coverage/1 exactly, and it " <>
               "names no kind the venue does not declare streamable" do
          Code.ensure_loaded?(@venue)

          if function_exported?(@venue, :coverage_by_kind, 1) and @fake do
            # `apply/3` for the same reason as assertion 12's — an optional callback guarded
            # one line up is not knowable at compile time, and a direct call warns for every
            # package that does not implement it. This site had no mitigation at all.
            #
            # **Driven against the FAKE, after a subscribe.** Both sides of the equality
            # below used to read the real module with nothing subscribed, so both were `%{}`
            # and `MapSet.new([]) == MapSet.new([])` held on every package — the assertion
            # that exists to stop these two facts drifting could not observe them drift. The
            # `undeclared` check further down was live on exactly one venue, whose fake
            # happened to name a kind even when empty.
            #
            # The structural claim the old call made is kept as its own assertion first: with
            # nothing subscribed the two real functions must agree that there is nothing.
            #
            # `apply/3` on both `coverage_by_kind/1` calls, and the reason is the one the
            # original site already recorded: an optional callback guarded one line up is not
            # knowable at compile time, and a direct call warns for every package that does
            # not implement it — Core's own reference venue among them. Binding the module to
            # a variable does NOT answer that; Elixir propagates the literal and warns anyway,
            # which is worth writing down because it looks like it should work.
            #
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            structural = apply(@venue, :coverage_by_kind, [[]])

            assert structural |> Map.values() |> Enum.all?(&(&1 == %{})),
                   "with nothing subscribed, coverage_by_kind/1 must report no symbols under " <>
                     "any kind — a kind carrying symbols here is a claim, not an observation"

            fake = @fake
            opts = arg_value(:opts, {:subscribe, 2})
            fake.subscribe(@sample_pairs, opts)

            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            by_kind = apply(fake, :coverage_by_kind, [opts])
            coverage_symbols = fake.coverage(opts) |> Map.keys() |> MapSet.new()

            assert MapSet.size(coverage_symbols) > 0,
                   "the fake reported no coverage after subscribing #{inspect(@sample_pairs)}, " <>
                     "so the union equality below compares two empty sets and cannot fail. " <>
                     "See assertion 14's own message for the two things that cause this."

            union =
              by_kind
              |> Map.values()
              |> Enum.flat_map(&Map.keys/1)
              |> MapSet.new()

            assert union == coverage_symbols,
                   "coverage_by_kind/1's symbols #{inspect(MapSet.to_list(union))} are not " <>
                     "the union coverage/1 reports (#{inspect(MapSet.to_list(coverage_symbols))}) " <>
                     "— the two are meant to be definitionally the same fact, and letting them " <>
                     "drift is what this assertion exists to stop"

            declared = MapSet.new(@venue.capabilities().streamable)
            reported = by_kind |> Map.keys() |> MapSet.new()
            undeclared = MapSet.difference(reported, declared)

            assert MapSet.size(undeclared) == 0,
                   "coverage_by_kind/1 reports #{inspect(MapSet.to_list(undeclared))}, which " <>
                     "capabilities().streamable does not declare — a venue reporting coverage " <>
                     "for a kind it does not claim to stream contradicts its own declaration"
          end
        end
      end
    end
  end

  # --- 30. a quote's volume states its window. dp-exchange-core issue #42 — its own block,
  # because inside `purity/0` it pushed that block past the length and complexity limits.
  defp volume_window_stated do
    quote location: :keep do
      describe "30. a quote's volume states its window" do
        # dp-exchange-core issue #42. A volume with no stated window was summed into candles
        # by a consumer that could not tell a rolling 24-hour total from one print, which put
        # a pair's average volume about 1000× too high. See `Types.Quote`'s
        # `:volume_window` section.
        test "a Quote carrying a volume states what quantity it is" do
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_price, 2}) and @sample_pairs != [] do
            assert @fake,
                   "pass `fake:` to run this assertion — see the top-of-book assertion above"

            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(@fake, :get_price, endpoint_args(:get_price, 2)) do
              {:ok, %DpExchange.Core.Types.Quote{} = quote_struct} ->
                # `AdapterContract.volume_window_fault/1`: a quote with no volume names no
                # window, and one with a volume names which quantity it is.
                fault = DpExchange.Core.AdapterContract.volume_window_fault(quote_struct)

                assert fault == nil,
                       "get_price/2 returned volume #{inspect(quote_struct.volume)} with " <>
                         "volume_window #{inspect(quote_struct.volume_window)} (#{inspect(fault)}). " <>
                         "A window describes a volume, so a quote with none names no window; a " <>
                         "quote with one states which quantity it is — one print, a running " <>
                         "total, or a rolling 24h total — because a consumer aggregates each " <>
                         "differently."

              # The same refusal-is-not-a-pass rule as the assertion above.
              other ->
                flunk("""
                capabilities/0 declares get_price/2 active, but the fake answered:

                    #{inspect(other)}

                Either the endpoint is not really active and capabilities/0 should say
                `:unsupported`, or the fake needs something this call did not carry —
                declare it in `endpoint_opts:` on `use DpExchange.Core.AdapterContract`.
                """)
            end
          end
        end
      end
    end
  end

  # --- 40. wanted/1 (optional) -----------------------------------------------------------
  #
  # `wanted/1` is in `Venue.@optional_callbacks`, for the reason `coverage_by_kind/1` is: Core
  # publishes it before every venue has adopted it. A fake that does not export it is not
  # failed, and this group then asserts nothing. Do not turn the `if` into an unconditional
  # assertion.
  defp wanted_callback do
    quote location: :keep do
      describe "40. wanted/1" do
        test "when the fake exports it, it holds what was subscribed and what coverage/1 " <>
               "reports" do
          if @fake && @sample_pairs != [] do
            opts = arg_value(:opts, {:subscribe, 2})
            fault = DpExchange.Core.AdapterContract.wanted_fault(@fake, @sample_pairs, opts)

            assert fault == nil,
                   "wanted/1 disagrees with what was subscribed or with coverage/1: " <>
                     "#{inspect(fault)}. wanted/1 is the symbols asked for, as a list or a " <>
                     "MapSet; coverage/1 is what arrived, and nothing arrives unasked."
          end
        end
      end
    end
  end

  # --- 41. family reasons, opt-in ----------------------------------------------------------
  #
  # Both checks need a fact only the venue's fixture has (a symbol its fake does not list, a
  # padded credential its credential check refuses), so each runs only when `use` names it
  # (`unlisted_symbol:`, `padded_credentials:`). Absent, it is skipped: the venues that have
  # not got the fixture yet are not failed for lacking it, and the suite does not guess one.
  defp family_reasons do
    quote location: :keep do
      describe "41. family reasons" do
        test "an unlisted symbol is {:refused, :not_listed} (opt-in: unlisted_symbol:)" do
          caps = @venue.capabilities()

          if @fake && @unlisted_symbol && Capabilities.active?(caps, {:get_price, 2}) do
            args = List.replace_at(endpoint_args(:get_price, 2), 0, @unlisted_symbol)
            # A `nil` answer is not "did not opt in" here (the option is named): it is an
            # answer that is not `{:refused, :not_listed}`, so it must reach the fault.
            answer = call_on(@fake, {:get_price, 2}, args) || :nil_answer

            assert DpExchange.Core.AdapterContract.family_reason_fault(
                     answer,
                     nil,
                     @venue.runtime_id()
                   ) == nil,
                   "get_price/2 for the unlisted symbol #{inspect(@unlisted_symbol)} answered " <>
                     "#{inspect(answer)}, not {:refused, :not_listed}"
          end
        end

        test "a padded credential is {:error, {:invalid_credentials, venue}} " <>
               "(opt-in: padded_credentials:)" do
          caps = @venue.capabilities()

          if @fake && @padded_credentials && Capabilities.active?(caps, {:get_balances, 2}) do
            args =
              :get_balances
              |> endpoint_args(2)
              |> List.replace_at(0, @padded_credentials)
              |> List.update_at(-1, &Keyword.put(&1, :credentials, @padded_credentials))

            answer = call_on(@fake, {:get_balances, 2}, args) || :nil_answer

            assert DpExchange.Core.AdapterContract.family_reason_fault(
                     nil,
                     answer,
                     @venue.runtime_id()
                   ) == nil,
                   "get_balances/2 with padded credentials answered #{inspect(answer)}, not " <>
                     "{:error, {:invalid_credentials, #{inspect(@venue.runtime_id())}}}"
          end
        end
      end
    end
  end

  # Assertion 14, apart from `purity/0` so neither quoted block grows past credo's ceiling.
  defp top_of_book_assertion do
    quote location: :keep do
      describe "14. top of book is not a price" do
        # These assertions exist because the confusion they forbid already shipped: a venue
        # package read `price || ask` from a best-bid/ask endpoint, so a response with no
        # traded price produced a quote whose `price` was a resting order. Review missed it,
        # and the package's own tests asserted it as correct.

        test "TopOfBook has no price field, and cannot grow one by accident" do
          # Structural, and asserted rather than trusted: the entire point of the type is
          # that there is nowhere to put a traded price. A field added later would silently
          # re-open the defect this type was built to close.
          top = %DpExchange.Core.Types.TopOfBook{
            symbol: "BTC-USD",
            observed_at: DateTime.utc_now(),
            provider: :contract_check
          }

          refute Map.has_key?(top, :price),
                 "TopOfBook must never carry `price`. A caller wanting a traded price " <>
                   "calls get_price/2 and gets a Quote, or gets an error."
        end

        test "get_top_of_book/2 returns a TopOfBook that records when it was observed" do
          # Driven against the venue's FAKE, never the real venue: `get_top_of_book/2` is
          # an active, uncredentialed endpoint on several venues in this family, so
          # calling it for real would make every ordinary `mix test` run dial the live
          # API — reproduced live against `api.gemini.com/v1/pubticker/btcusd` before
          # this was fixed.
          caps = @venue.capabilities()

          if Capabilities.active?(caps, {:get_top_of_book, 2}) and @sample_pairs != [] do
            assert @fake,
                   "pass `fake:` to run this assertion. Calling get_top_of_book/2 on " <>
                     "the real venue would make every CI run hit the live API, which " <>
                     "D7 reserves for tier 2 and for a human choosing to run it."

            # `apply/3` for the same reason as assertion 12's `get_symbols/1` call: this
            # suite is generic over the consuming package's fake, and specialising on one
            # turns `is_nil(top.venue_time)` into a "comparison between distinct types"
            # whenever that fake always sets `venue_time`. A venue that publishes no time
            # for a BBO is exactly the case this assertion exists to allow — see
            # `Types.Quote`'s 0.2.0 split — so the branch is live, just not for this fake.
            #
            # `endpoint_args/2` rather than a hand-built `[symbol, []]`. The hand-built
            # version is why this assertion ran on one venue out of five: it carried no
            # credential, and a public-SHAPED endpoint on a `credential_benefit: :required`
            # venue can only receive one through `opts`.
            #
            # credo:disable-for-next-line Credo.Check.Refactor.Apply
            case apply(@fake, :get_top_of_book, endpoint_args(:get_top_of_book, 2)) do
              {:ok, top} ->
                # `AdapterContract.time_fault/2`. A BBO carries resting orders and a Quote a
                # traded price, so they are not interchangeable; `observed_at` is required (a
                # BBO is stale the instant it is read, so when it was read is part of the
                # value); `venue_time` is the venue's own or nil, never a stand-in for it.
                module = DpExchange.Core.Types.TopOfBook
                fault = DpExchange.Core.AdapterContract.time_fault(top, module)

                assert fault == nil,
                       "get_top_of_book/2 must return a TopOfBook with a DateTime " <>
                         "observed_at and a venue_time that is the venue's own DateTime or " <>
                         "nil. Got #{inspect(fault)}"

              # A refusal from an endpoint `capabilities/0` declares ACTIVE is not a pass.
              # See assertion 24's helper for the incident: the identical
              # `_refused_or_unsupported -> :ok` clause is how three packages passed an
              # assertion that never executed on them, and closing it there and not here
              # would be the "fix applied where it was found rather than where it applies"
              # this family keeps paying for.
              other ->
                flunk("""
                capabilities/0 declares get_top_of_book/2 active, but the fake answered:

                    #{inspect(other)}

                Either the endpoint is not really active and capabilities/0 should say
                `:unsupported`, or the fake needs something this call did not carry —
                declare it in `endpoint_opts:` on `use DpExchange.Core.AdapterContract`.

                See docs/reference/core/assertion-coverage.md, "Second axis".
                """)
            end
          end
        end
      end
    end
  end

  defp purity do
    quote location: :keep do
      # --- 7, 10, 11. purity, exclusivity, self-sufficiency ----------------

      describe "7. purity" do
        test "the compiled package links against nothing but its declared dependencies" do
          # Asserted from the BEAM's `imports` chunk rather than by grepping for a list
          # of forbidden namespaces. Two reasons, and the second is the better one.
          #
          # A name list has to contain the names it forbids, so a package shipping this
          # suite fails its own check — which is how this assertion was first written.
          #
          # More importantly, a list only forbids what someone thought to list. The
          # imports chunk answers the real question: does this package reach for anything
          # its consumers have not agreed to install? A transitive reference nobody
          # noticed shows up here and in no grep.
          #
          # The decision itself is `AdapterContract.foreign_modules/3`, public so it can be
          # tested: a dependency is permitted by the application its module is built into
          # (`_build/<env>/lib/<app>/ebin`), not by a `deps/` path no dependency is loaded
          # from, and `mix.exs` deps are read in all three tuple shapes.
          config = Mix.Project.config()
          app = config[:app]
          permitted = DpExchange.Core.AdapterContract.permitted_apps(app, config[:deps] || [])

          linked =
            Mix.Project.build_path()
            |> Path.join("lib/#{app}/ebin/*.beam")
            |> Path.wildcard()
            |> Enum.flat_map(fn beam ->
              {:ok, {_module, [imports: imports]}} =
                :beam_lib.chunks(String.to_charlist(beam), [:imports])

              Enum.map(imports, fn {module, _fun, _arity} -> module end)
            end)
            |> Enum.uniq()

          # An empty scan is not a clean one: no beam under the build path (a wrong build
          # path, a package not compiled here) used to leave `linked` empty and `foreign`
          # trivially `[]`, so purity passed having read nothing.
          assert linked != [],
                 "no compiled #{app} module imports anything under " <>
                   "#{Mix.Project.build_path()}/lib/#{app}/ebin, so purity examined nothing"

          foreign =
            DpExchange.Core.AdapterContract.foreign_modules(
              linked,
              permitted,
              Path.join(Mix.Project.build_path(), "lib")
            )

          assert foreign == [],
                 "#{app} links against modules outside stdlib and its declared " <>
                   "dependencies: #{inspect(foreign)}"
        end
      end

      describe "11. self-sufficiency" do
        test "the package supervises itself through its own child_spec/1" do
          # The venue must start, subscribe and serve with nothing but credentials and
          # options: a callback in an argument list is an injected sink wearing a different
          # name, and the entry point a consumer supervises is `child_spec/1`. (That the
          # facade takes data and no function is the next test's walk over its answers and
          # assertion 7's imports check; this one asserts only the entry point.)
          # `Code.ensure_loaded!/1` first: `function_exported?/3` answers false for a
          # module that is merely not loaded, so without it this asserts "not exported"
          # while meaning "does not exist".
          Code.ensure_loaded!(@venue)

          assert function_exported?(@venue, :child_spec, 1),
                 "the package declares its own supervision entry point"
        end

        # It walked the `:unsupported` endpoints, which answer `{:error, :not_supported}`,
        # so it could not fail. The answers that can carry a process are the ACTIVE ones,
        # and they are asked of the fake, which answers without a network.
        test "no facade return value carries a process, socket or reference" do
          if @fake, do: assert_no_process_in_answers(@fake, @venue)
        end
      end
    end
  end

  defp isolation do
    quote location: :keep do
      # --- 13. process-scoped isolation ------------------------------------

      describe "13. process-scoped isolation" do
        test "an override in this process does not reach a sibling" do
          # A suite that needed a global to prove isolation would have disproved it, so
          # nothing here calls Application.put_env/3.
          DpExchange.Core.Config.put_override(:contract_probe, :mine)

          sibling =
            Task.async(fn ->
              Process.delete(:"$callers")
              DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe, :default)
            end)

          assert Task.await(sibling) == :default
          assert DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe) == :mine
        end

        test "a Task spawned inside the override inherits it" do
          # The $callers walk, asserted explicitly because it is the step most likely to
          # be skipped — and skipping it works in simple tests and fails in concurrent
          # ones.
          DpExchange.Core.Config.put_override(:contract_probe, :inherited)

          task =
            Task.async(fn ->
              DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe, :default)
            end)

          assert Task.await(task) == :inherited
        end

        test "two concurrent processes hold different values for the same seam" do
          parent = self()

          spawn_probe = fn value ->
            Task.async(fn ->
              Process.delete(:"$callers")
              DpExchange.Core.Config.put_override(:contract_probe, value)
              send(parent, :ready)

              receive do
                :go -> DpExchange.Core.Config.get(:dp_exchange_core, :contract_probe)
              end
            end)
          end

          a = spawn_probe.(:refusing)
          b = spawn_probe.(:succeeding)

          # Explicit, generous timeout rather than ExUnit's 100ms default. This assertion
          # proves two concurrent processes hold *different* values for one seam — it is
          # not measuring how fast a spawn is, so waiting longer weakens nothing: it still
          # fails if a `:ready` never arrives at all. On the default budget, two `Task`
          # spawns plus scheduling can exceed 100ms under a full suite's parallel load, and
          # this one did — observed failing once on seed 3 in `dp_exchange_schwab` and
          # passing on an immediate re-run of the same seed.
          #
          # This macro is compiled into all five venue packages' own suites, so a flake here
          # is a flake in every one of them, in a shared assertion whose whole purpose is to
          # be trusted. A conformance check that fails at random is one people learn to
          # re-run rather than read.
          assert_receive :ready, 5_000
          assert_receive :ready, 5_000
          send(a.pid, :go)
          send(b.pid, :go)

          assert Enum.sort([Task.await(a), Task.await(b)]) == [:refusing, :succeeding]
        end
      end
    end
  end

  defp wiring do
    quote location: :keep do
      # --- 16. internal wiring ----------------------------------------------

      describe "16. internal wiring" do
        test "every internal export has a caller inside this package's own lib/" do
          # "Mechanism built, documented, and never wired" — six instances in one week
          # across this family, every one shipped green: `rate_limit_blocking` plumbed
          # through Core.HttpClient but never set by a caller (issues #16, #23, #26 —
          # #23 had to be fixed through three separate option allowlists, and a fix
          # stopping at the first still passed every test asserting the keyword was
          # present); FrameSender's retry path, reported but never retried (issue #22);
          # `subscribe_notices/1`'s registry, built and never reached; `Auth.refresh/2`,
          # zero call sites, while a Socket held a token that could only expire. Every
          # one of those functions had a test calling it directly, so coverage stayed
          # green and the suite stayed silent — a test is not a caller.
          #
          # `DpExchange.Core.UnwiredCheck` reads `:xref`'s real call graph rather than
          # grepping for call sites, so a captured `&Mod.fun/1` and a literal
          # `apply(Mod, :fun, args)` both count as real usage — see its moduledoc for
          # what it excludes and why each exclusion is safe without a hand-maintained
          # allowlist that rots. `@venue` and `@fake` are excluded here because both are
          # already-bound public surface called only by consumers, not because either is
          # hand-picked for this assertion.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          facade_and_fake = Enum.reject([@venue, @fake], &is_nil/1)

          assert {:ok, violations} =
                   DpExchange.Core.UnwiredCheck.run(beam_dir, lib_root, facade_and_fake),
                 scan_failure_message(:unwired, lib_root)

          assert violations == [],
                 "internal function(s) with no caller anywhere in this package's own " <>
                   "lib/ — either dead code or a mechanism built and never wired:\n" <>
                   DpExchange.Core.UnwiredCheck.format(violations)
        end
      end
    end
  end

  defp link_safety do
    quote location: :keep do
      # --- 18. link safety --------------------------------------------------

      describe "18. link safety" do
        test "a process that starts a linked child also traps exits" do
          # Found live in four of five venue packages on 2026-09-07: `Feed.init/1` never
          # called `Process.flag(:trap_exit, true)`, and `Socket.start_link/1` ran from
          # inside a `Feed` callback — which links the socket to `Feed`, not to a
          # supervisor. An abnormal socket exit was therefore untrappable and killed
          # `Feed`, and the venue's `Supervisor` restarted it from its STATIC start opts
          # — every `subscribe/2` a consumer had made since boot, silently gone. Fixed
          # identically in all five repos by trapping exits before anything gets linked:
          # `dp_exchange_coinbase` e77b542, `dp_exchange_gemini` 66acd3b,
          # `dp_exchange_webull` d0c54a8, `dp_exchange_schwab` 90dddc6,
          # `dp_exchange_robinhood` 51ad189.
          #
          # This is deliberately STATIC, not a behavioural "start the tree and kill a
          # linked child" test — see `DpExchange.Core.LinkSafetyCheck`'s moduledoc for
          # why that was tried first and rejected: starting a venue's real (non-fake)
          # tree was not reliably network-free (on 2026-09-07 dp_exchange_schwab's `Feed`
          # dialled its Streamer unconditionally from `init/1`'s own `{:continue,
          # :connect}`; that was fixed the same day, in `9973c0d`), and the objection that
          # stands is that there is no contract-sanctioned way to find "the feed" in a
          # venue's tree without a venue-specific name this suite is expressly forbidden
          # from knowing. A static check over the compiled module — does it create a link,
          # and does it also trap exits — never starts a process at all, so it cannot dial
          # out for any venue, present or future.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          assert {:ok, violations} = DpExchange.Core.LinkSafetyCheck.run(beam_dir, lib_root),
                 scan_failure_message(:link_safety, lib_root)

          assert violations == [],
                 "process(es) that link a child they start and never call " <>
                   "Process.flag(:trap_exit, true) — that child's abnormal exit will " <>
                   "crash the process that started it, and a Supervisor restarts from " <>
                   "static opts, discarding every subscribe/2 made since boot:\n" <>
                   DpExchange.Core.LinkSafetyCheck.format(violations)
        end
      end
    end
  end

  defp credential_gate do
    quote location: :keep do
      # --- 17. credential gate ----------------------------------------------

      describe "17. credential gate" do
        test "on a venue requiring credentials, no active endpoint's fake " <>
               "succeeds when called with credentials stripped" do
          # Found independently in two venue packages the same week this assertion was
          # written: six credentialed functions on a venue where **every request is
          # signed and there is no anonymous endpoint** answered `{:ok, _}` for `%{}` or
          # `nil` credentials, because nothing checked the argument at all. Tier 1
          # in-process fakes are the only tier that runs on every CI run and the only one
          # most consumers ever exercise, so a fake that succeeds where the real venue
          # would refuse silently certifies broken consumer code — a caller that forgot
          # its credentials would see its own tests pass.
          #
          # Fake-only, and gated on `credential_benefit: :required` rather than run
          # unconditionally: a venue with `:no_difference` or `:higher_ceiling` may
          # legitimately serve some of these endpoints without a credential (some venues'
          # `get_fees/2` or `get_transfers/2` genuinely differ), and asserting a refusal
          # there would be inventing a rule the venue never claimed. `:required` is a
          # positive statement that public data is not served at all without one, which
          # is exactly the claim a `{:ok, _}` from stripped credentials would contradict.
          #
          # Deliberately NOT asserting shape equality against the real venue
          # (`call_on(@venue, args) == call_on(@fake, args)`): that would only be safe if
          # every venue's auth check fails locally before any HTTP dial-out, which is an
          # invariant about venues this suite has not reviewed and must not assume. A
          # conformance assertion that can make a live network call under some future
          # venue's implementation is a worse failure mode than the gap it would close.
          #
          # ## Widened from a fixed list to every active endpoint (2026-09-07)
          #
          # This used to gate on `@credentialed`, a hand-maintained list of eleven names
          # written when the contract had a small, stable credentialed surface. A
          # callback outside that list — one that takes no dedicated `credentials`
          # argument and instead reads a credential out of `opts`, which is how every one
          # of `get_option_chain/2`, `get_news/1`, `get_corporate_events/1` and
          # `quantization/1` do it on a venue that signs every request — was invisible to
          # the loop no matter how it answered with no credential. Found independently in
          # `dp_exchange_webull` and `dp_exchange_schwab` on 2026-09-07, both auditing
          # their own widened surface by hand because this assertion could not: each fake
          # had the identical defect (`{:ok, _}` with credentials stripped) on exactly
          # the callbacks the fixed list did not name.
          #
          # The rule this widens to: on a venue declaring `credential_benefit: :required`,
          # `:required` means every active endpoint needs a credential, so this checks
          # them all — `Venue.behaviour_info(:callbacks)` minus a small, NAMED exemption,
          # never a list of what to check. A hand-maintained list of what to check is the
          # same class of thing as the hand-maintained list this replaces: it rots, and
          # the rot is invisible.
          #
          # `answerable?/1` drops `child_spec/1` and `start_link/1` — calling `start_link`
          # on even a FAKE could start a real process, which no assertion in this suite
          # should ever risk. `credential_gated_endpoints/2` (the same drop, kept there)
          # drops exactly two more: `test_connection/2` and `get_rate_limit_status/2`,
          # because their OWN callback doc types the credential `credentials() | nil` —
          # the contract itself, not a venue's choice, says a missing credential is
          # expected there, since both mean "can I reach the venue at all" rather than
          # "give me this venue's data". Every other callback in the behaviour is
          # checked, including ones that return a bare `:ok`/map/list rather than a
          # `result()` tuple — those can never match `{:ok, _}` below and pass this
          # assertion trivially, so including them costs nothing and excluding them by
          # hand would only be one more list to keep in sync.
          #
          # ## `market_status/1`, resolved (2026-09-07)
          #
          # This callback's own doc makes one unconditional claim: "crypto venues answer
          # `:open`." That is NOT a licence to exempt `market_status/1` by name the way
          # `test_connection/2` and `get_rate_limit_status/2` are exempt above —
          # `dp_exchange_schwab`'s real `market_status/1` calls an authenticated
          # `/markets` endpoint, and its fake correctly refuses without a credential. A
          # name-based exemption would silence that protection for the one venue where
          # this assertion is doing real work today, purely to accommodate two venues
          # where it currently is not — exactly the "decorative check" this suite exists
          # to avoid.
          #
          # What actually distinguishes Webull's and Robinhood's `market_status/1` from
          # Schwab's is not the callback name, it is each venue's `asset_classes/0`. A
          # venue whose entire surface is `[:crypto]` has no exchange-mandated trading
          # session for a credential to gate — "crypto trades continuously" is true of
          # the ASSET CLASS, not a fact fetched from the venue, so no credential can
          # change it. A venue serving anything else can have real, authenticated market
          # hours (Schwab does) or, like Webull, publish nothing this package can reach
          # at all: Webull's OpenAPI documents 85 endpoints and none of them is a
          # market-status or trading-calendar call (`docs/reference/webull/` in that
          # package); the one trading-calendar endpoint Webull publishes anywhere,
          # `/broker/master-data/trading-calendars/list`, belongs to its separate Broker
          # API product on a different host (`broker-api.webull.com`) needing its own
          # broker-tier credential this contract's `credentials()` does not model — out
          # of reach regardless of what any caller supplies.
          #
          # The `market_status/1` clause of `credential_gated_endpoints/2` is that
          # narrower exemption, skipped only when `@venue.asset_classes() == [:crypto]`.
          # Webull serves five asset classes and does not qualify — its `market_status/1`
          # is checked like any other endpoint, and it satisfies the check by declaring
          # itself `:unsupported` (`{:error, :not_supported}`), the honest answer for a
          # venue this package cannot reach a usable endpoint on. Robinhood is
          # crypto-only and does qualify, so its `{:ok, :open}` with no credential is
          # exempt on that ground alone — argued in its own package's review rather than
          # assumed silently, and recorded here for the same reason the two-name
          # exemption above is recorded here rather than in a venue's own test file. See
          # `usage-rules/adapter.md` for the consumer-facing version of this argument.
          #
          # ## `get_fees/2`, and `Capabilities.no_venue_contact` (2026-09-07)
          #
          # The `market_status/1` exemption above is grounded in a per-VENUE fact (the
          # asset class serves no session for a credential to gate). This one is
          # grounded in a per-ENDPOINT fact that no asset-class or venue-identity
          # predicate can express: `dp_exchange_webull`'s `get_fees/2` answers a flat
          # crypto spread captured from the venue's own published pricing
          # (`source: :published_rate`) and builds no request at all, on a venue that
          # otherwise correctly requires credentials for everything else. A
          # 2026-09-06 sweep gated it anyway to satisfy this assertion in its
          # then-unqualified form, reasoning that the real path "had never run through
          # `Auth.headers/2`" — true, and the reason there was nothing to gate. That
          # broke a real consumer who resolves fees before any account is attached.
          #
          # Rather than a THIRD name-based or venue-based exemption growing here, the
          # venue itself now declares this: `Capabilities.no_venue_contact` is a list
          # of `{name, arity}` an active endpoint may appear in when its real
          # implementation, on that venue, never builds a request — the same
          # per-endpoint shape `endpoints` already uses, so it cannot rot into a single
          # hand-maintained list the way `@credentialed` did. Declaring an endpoint
          # there is a claim the venue package must be able to point at real code to
          # back — see `Capabilities`'s own moduledoc for what belongs there and what
          # does not. This assertion trusts the declaration; it is the venue's
          # moduledoc and code review that keep it honest, the same trust this suite
          # already places in `credential_benefit` itself.
          # The body is `assert_credential_gate/2` (`credential_gate_helpers/0`), apart so
          # this quoted block stays under credo's length ceiling.
          assert_credential_gate(@venue, @fake)
        end
      end
    end
  end

  defp credential_redaction do
    quote location: :keep do
      # --- 19. credential redaction ------------------------------------------

      describe "19. credential redaction" do
        test "a struct with a secret-named field redacts it under inspect/1" do
          # Found live in four of five venue packages on 2026-09-07: `Feed`/`Socket` held
          # `:credentials` as a bare map for their whole lifetime, and OTP's default crash
          # report prints a process's state in full on termination — a plain map prints
          # every key it holds, secrets included. Proven by crashing an equivalent process
          # holding `%{api_key: "...", api_secret: "..."}` as a bare state field and
          # reading the log back; a second path found the same way, a
          # `FunctionClauseError`'s stacktrace prints the actual arguments a failed clause
          # was called with. `Process.flag(:sensitive, true)` does not help — it changes
          # what `:sys.get_state/1`/`:dbg` can see, not crash-report or stacktrace
          # formatting. Fixed identically in four repos by wrapping the credential in a
          # struct whose `Inspect` is derived with `except:` naming every secret field:
          # `dp_exchange_coinbase` 4d00669, `dp_exchange_webull` 80eaf02,
          # `dp_exchange_schwab` 336cbd8, `dp_exchange_robinhood` cfc4861.
          #
          # `DpExchange.Core.CredentialRedactionCheck` verifies this BEHAVIOURALLY —
          # `struct/2` a real instance of every struct your `lib/` defines with a
          # distinctive value in each secret-named field, and search the actual
          # `inspect/1` rendering for it — never by looking for `@derive` in your source.
          # A hand-written `defimpl Inspect` that never mentions `@derive` at all passes
          # exactly as validly. See its moduledoc for the full secret-name list, why each
          # name is on it, and — the part that matters most — what this does NOT catch:
          # the original defect was a raw map, never a struct, and this check would not
          # have caught it as it actually shipped. It locks the fix in; it cannot reach
          # back to the shape of the bug before the fix existed.
          config = Mix.Project.config()
          app = config[:app]
          lib_root = Path.expand(@package_root)
          beam_dir = Mix.Project.build_path() |> Path.join("lib/#{app}/ebin")

          assert {:ok, violations} =
                   DpExchange.Core.CredentialRedactionCheck.run(beam_dir, lib_root),
                 scan_failure_message(:credential_redaction, lib_root)

          assert violations == [],
                 "struct(s) with a secret-named field that prints in cleartext under " <>
                   "inspect/1 — a crash report or a failed function clause's stacktrace " <>
                   "would print it too:\n" <>
                   DpExchange.Core.CredentialRedactionCheck.format(violations)
        end
      end
    end
  end

  defp subscribed_push_shape do
    quote location: :keep do
      # --- 20. subscribed push shape -----------------------------------------

      describe "20. subscribed push shape" do
        test "subscribe/2 delivers a Core.Types.* struct, tagged with runtime_id/0" do
          # `c:DpExchange.Core.Venue.subscribe/2`'s own doc makes an unconditional claim,
          # never checked before this: "Events arrive as messages... tagged so a process
          # subscribed to several venues can tell them apart" and "The payload is a
          # DpExchange.Core.Types.* struct — the same value the pull endpoints return."
          #
          # Assertion 16 (internal wiring) catches a decoder with no caller, but a decoder
          # that IS wired and hands the raw response straight to the sink — never building
          # the struct the doc promises — passes every existing assertion: the function
          # that forwards it has a caller, and `subscribe/2` answers `:ok` either way.
          # This is that gap: a raw, undecoded payload forwarded to subscribers is a
          # plausible value with the wrong shape, which is this family's own named
          # recurring failure mode, applied to the one endpoint the pull-side checks never
          # reach.
          #
          # Fake-only, like assertion 17: every fake in this family pushes synchronously,
          # inside the call that returns `:ok`, so there is nothing to wait on and no
          # network is ever dialled.
          caps = @venue.capabilities()

          if @fake && @sample_pairs != [] && Capabilities.active?(caps, {:subscribe, 2}) do
            # The venue's own `endpoint_opts`, as assertions 26, 27 and 29 already pass them: a
            # fake that needs one to subscribe was called without it here alone.
            opts = :opts |> arg_value({:subscribe, 2}) |> Keyword.put(:to, self())
            assert :ok = @fake.subscribe(@sample_pairs, opts)

            assert_receive {:dp_exchange, runtime_id, payload},
                           5_000,
                           "subscribe/2 returned :ok for #{inspect(@sample_pairs)} but " <>
                             "delivered nothing — a caller has no way to tell that from " <>
                             "a quiet market"

            # The decision is `AdapterContract.subscribed_push_fault/2`, public so the
            # teeth tests run the suite's own logic and not a copy of it.
            case DpExchange.Core.AdapterContract.subscribed_push_fault(
                   {:dp_exchange, runtime_id, payload},
                   @venue.runtime_id()
                 ) do
              nil ->
                :ok

              :wrong_tag ->
                flunk(
                  "subscribe/2 tagged its message #{inspect(runtime_id)}, not " <>
                    "#{inspect(@venue.runtime_id())} — a caller subscribed to several " <>
                    "venues cannot tell them apart"
                )

              :not_a_core_struct ->
                flunk(
                  "subscribe/2 pushed #{inspect(payload)} — the facade's own contract " <>
                    "is that the payload is a DpExchange.Core.Types.* struct, the same " <>
                    "value the pull endpoints return, never raw venue data"
                )
            end
          end
        end
      end
    end
  end

  defp order_book_ordering do
    quote location: :keep do
      # --- 25. order book ordering ---------------------------------------------

      describe "25. order book ordering" do
        # `Core.Types.OrderBook` states this and anticipates the mistake by name: "The
        # ordering is part of the contract, not a convenience: a caller reading `hd(bids)`
        # as the best bid is reading it correctly, and a venue package that returns
        # venue-order without re-sorting has broken the contract even though every value in
        # it is true."
        #
        # **Nothing checked it, and on 2026-09-13 most of the packages that build an
        # `OrderBook` were returning the venue's row order.** The family had both answers
        # running at once and every suite was green. Two of them even carried a test
        # asserting the venue's order was kept, each with an ascending bid list as its
        # fixture — the tell, since that is precisely the order this contract calls broken.
        #
        # **The 2026-09-13 sweep credited `dp_exchange_coinbase` as the one package already
        # sorting, and that was half right, which is worse than wrong.** Coinbase builds a
        # book on TWO paths: `Socket`'s `level2` snapshot, which sorted, and `Rest`'s
        # `get_order_book/2`, which did not. The sweep found `Socket.sorted/2`, took the
        # package as done, and `dp_exchange_webull` copied the attribution into its own
        # comment. Coinbase's REST decoder kept returning venue row order until 2026-09-14,
        # protected by the family's own record saying it was fine.
        #
        # The lesson for the next reader is not about coinbase. It is that "does this
        # package sort?" is the wrong question — a package has one book path per transport,
        # and each one has to be checked.
        #
        # This is the suite's own policy applied: "Every gap found becomes a new assertion
        # here. A gap fixed only in one venue's fake is a gap the next venue reintroduces."
        #
        # **What this does NOT catch, stated plainly: the bug that prompted it.** The suite
        # drives the venue's FAKE, and all five fakes already returned sorted books — the
        # drift was in the real decoders, which read venue rows this suite never sees.
        # Driving the real one would make every ordinary `mix test` dial the live API, and
        # feeding it an unsorted fixture would mean handing the suite a `plug:`, which is
        # transport and which this module's own rule forbids an assertion to name.
        #
        # So the division of labour is: each venue's own tests hold its decoder (every one
        # fixed on 2026-09-13, and coinbase's REST path on 2026-09-14, gained a test that
        # fails if the sort is removed),
        # and this holds the fake, the contract's visibility, and the next venue to arrive.
        # Saying so is more useful than implying it closes the hole — the same reason
        # assertion 23 records that it cannot catch a venue's own local clock.
        #
        # It does catch the regression that matters most for a fake: assertion 9 requires
        # the fake to satisfy this suite, so a fake written with a plausible-looking
        # descending ask ladder now fails here instead of teaching the next reader that
        # venue order is acceptable.
        test "bids come back highest first and asks lowest first" do
          assert_book_ordering(@venue, @fake)
        end
      end

      # Skips a venue that declares the endpoint `:unsupported` — `dp_exchange_robinhood`
      # and `dp_exchange_schwab` serve no REST order book and say so in `capabilities/0`,
      # which is the honest reason to skip. A refusal from an endpoint declared ACTIVE is
      # not one, for the reason assertion 24's helper records.
      defp assert_book_ordering(venue, fake) do
        endpoint = {:get_order_book, 2}

        if Capabilities.active?(venue.capabilities(), endpoint) and @sample_pairs != [] and fake do
          case apply(fake, :get_order_book, endpoint_args(:get_order_book, 2)) do
            {:ok, %DpExchange.Core.Types.OrderBook{} = book} ->
              assert_side_ordering(book.bids, :desc, "bids", "highest")
              assert_side_ordering(book.asks, :asc, "asks", "lowest")

            other ->
              flunk("""
              capabilities/0 declares get_order_book/2 active, but the fake answered:

                  #{inspect(other)}

              Either the endpoint is not really active and capabilities/0 should say
              `:unsupported`, or the fake needs something this call did not carry —
              declare it in `endpoint_opts:` on `use DpExchange.Core.AdapterContract`.
              """)
          end
        end
      end

      defp assert_side_ordering(levels, direction, side, superlative) do
        # **A fixture too thin to order cannot fail this assertion**, and an assertion that
        # cannot fail is not coverage. A list of one is sorted under every comparator; a list
        # of none is too. So the depth of the fake's book is not a detail of the fixture —
        # it is the difference between this assertion checking the ordering contract and
        # reporting green for having looked at nothing.
        #
        # Measured on `dp_exchange_gemini`, whose fake returned exactly one level a side.
        # Its contract suite ran assertion 25, reached the behaviour, and passed — and no
        # edit to that fake could have made it fail, because there was no pair of prices to
        # put in the wrong order. Adding a second, deliberately misordered level turned it
        # red at once: 48 tests, 1 failure. The assertion was never broken. It had nothing
        # to work on, and nothing said so.
        #
        # This is a third axis on top of the two `docs/reference/core/assertion-coverage.md`
        # already records. That file asks "does an assertion exist?" and then "does it run on
        # every venue?". Both were yes here. The question it did not ask is whether an
        # assertion that runs is **able to fail**, and the answer has to be checked against
        # the fixture, not against the assertion.
        # The decision is `AdapterContract.book_ordering_fault/2`, public so a test can hand it
        # a side that is too thin, unreadable or out of order and see each named.
        case DpExchange.Core.AdapterContract.book_ordering_fault(levels, direction) do
          nil ->
            :ok

          {:too_thin, count} ->
            flunk(
              "the fake's #{side} carry #{count} level(s), and this assertion " <>
                "cannot fail on fewer than two — a list of one is sorted under every " <>
                "comparator, so the ordering contract is not being checked for this " <>
                "package at all. This is a requirement on the FAKE's fixture and not on " <>
                "the venue: give `Fake.get_order_book/2` at least two levels a side, in " <>
                "the order `Core.Types.OrderBook` requires, so that getting it wrong is " <>
                "something this assertion can see."
            )

          {:unreadable_level, level} ->
            flunk(
              "every #{side} level carries a real Decimal price — `Core.Types.OrderBook`'s " <>
                "`level/0` is `{Decimal.t(), Decimal.t()}`, and a caller reading " <>
                "`hd(#{side})` as the #{superlative} price cannot be handed " <>
                "#{inspect(level)}"
            )

          {:unsorted, prices} ->
            flunk(
              "#{side} must be #{direction}ending so `hd(#{side})` is the #{superlative} — " <>
                "the ordering is part of `Core.Types.OrderBook`'s contract, not a " <>
                "convenience, and a package returning venue-order without re-sorting has " <>
                "broken it even though every value in it is true. Got: #{inspect(prices)}"
            )
        end
      end
    end
  end

  defp venue_and_observed_time do
    quote location: :keep do
      # --- 23. venue time and observed time on Quote and OrderBook -------------

      describe "23. venue time and observed time" do
        # Core 0.2.0 split `Quote`/`OrderBook`'s single `:timestamp` into `:venue_time`
        # (the venue's own, `nil` where it publishes none) and `:observed_at` (when the
        # package read it, always present) — see
        # `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`.
        #
        # **The split is only worth having if `:venue_time` stays honest**, and nothing
        # checked that. Assertion 14 already makes exactly this check for `TopOfBook`,
        # which had the two fields from the start; these extend it to the two types that
        # just gained them. Not the "comprehensive endpoint → struct map"
        # `docs/reference/core/assertion-coverage.md` considered and declined: two named
        # callbacks whose return type the contract already fixes, with no list to maintain.
        #
        # What this catches is a decode bug with a plausible shape — a raw epoch integer, a
        # `NaiveDateTime`, or a venue string left unparsed in `:venue_time`. What it cannot
        # catch is a venue putting its own local clock there; no assertion can, because a
        # `DateTime` from `DateTime.utc_now/0` is indistinguishable from one the venue sent.
        # That is held by the type's documentation and by review, and saying so is more
        # useful than implying this closes it.
        #
        # Fake-driven for the same reason assertion 14 is: both endpoints are active and
        # uncredentialed on several venues here, so calling the real one would make every
        # ordinary `mix test` dial the live API.
        test "get_price/2's Quote carries the venue's own time or nil, and always observed_at" do
          assert_times(@venue, @fake, {:get_price, 2}, DpExchange.Core.Types.Quote)
        end

        test "get_order_book/2's OrderBook keeps the same discipline" do
          assert_times(@venue, @fake, {:get_order_book, 2}, DpExchange.Core.Types.OrderBook)
        end

        test "neither type still carries a :timestamp field" do
          # Structural, and asserted rather than trusted — the same reasoning as
          # `TopOfBook has no price field`. A `:timestamp` reintroduced later would be a
          # field with no defined meaning: callers would fill it from whichever of the two
          # times was nearest to hand, which is the ambiguity this split removed.
          refute Map.has_key?(
                   struct(DpExchange.Core.Types.Quote, %{}),
                   :timestamp
                 ),
                 "Quote must not regrow :timestamp — venue_time and observed_at are " <>
                   "different facts and one field cannot say which it holds"

          refute Map.has_key?(struct(DpExchange.Core.Types.OrderBook, %{}), :timestamp),
                 "OrderBook must not regrow :timestamp"
        end
      end

      # Assertion 23's shared body. A `defp` in the helpers quote rather than repeated in
      # each test: two endpoints ask the identical question of two different types, and
      # inlining it twice pushed the enclosing quote past credo's complexity ceiling — which
      # is the tool noticing the duplication before a reader had to.
      #
      # Skips a venue that declares the endpoint `:unsupported` — `dp_exchange_robinhood`
      # serves no `get_price/2` and no order book, `dp_exchange_schwab` no order book, and
      # each says so in `capabilities/0`, which is the honest reason to skip.
      #
      # A refusal from an endpoint declared ACTIVE is NOT one, and this used to end
      # `_refused_or_unsupported -> :ok` with a comment calling that "a legitimate answer
      # here, not a failure". It is the identical clause that let three packages pass
      # assertion 24 without ever executing it — see that helper for the incident. Leaving
      # it closed there and open here would be the "fix applied where it was found rather
      # than where it applies" this family keeps paying for.
      defp assert_times(venue, fake, {name, arity} = endpoint, expected_module) do
        caps = venue.capabilities()

        if Capabilities.active?(caps, endpoint) and @sample_pairs != [] and fake do
          # `endpoint_args/2` rather than a hand-built `[symbol, []]` — see `arg_value/2`'s
          # `credentials:` note. The hand-built version carried no credential, so this ran
          # on one venue out of five.
          case apply(fake, name, endpoint_args(name, arity)) do
            {:ok, value} ->
              assert_time_fields(value, expected_module, name, arity)

            other ->
              flunk("""
              capabilities/0 declares #{name}/#{arity} active, but the fake answered:

                  #{inspect(other)}

              Either the endpoint is not really active and capabilities/0 should say
              `:unsupported`, or the fake needs something this call did not carry —
              declare it in `endpoint_opts:` on `use DpExchange.Core.AdapterContract`.

              See docs/reference/core/assertion-coverage.md, "Second axis".
              """)
          end
        end
      end

      defp assert_time_fields(value, expected_module, name, arity) do
        # `AdapterContract.time_fault/2`. `observed_at` is mandatory: it is what lets
        # `venue_time` be nil without any caller having to invent a time. `venue_time` is the
        # venue's own DateTime or nil, never an unparsed epoch, a NaiveDateTime, or a
        # stand-in for a time the venue did not send.
        fault = DpExchange.Core.AdapterContract.time_fault(value, expected_module)

        assert fault == nil,
               "#{name}/#{arity} must return a #{inspect(expected_module)} with a DateTime " <>
                 "observed_at and a venue_time that is a DateTime or nil. Got #{inspect(fault)}"
      end
    end
  end

  defp historical_timeframe_discipline do
    quote location: :keep do
      # --- 21. historical timeframe discipline --------------------------------

      describe "21. historical timeframe discipline" do
        test "a timeframe outside historical_timeframes is refused, never served at the " <>
               "nearest width" do
          # This family's own named recurring failure, verbatim from this package's
          # CLAUDE.md: "a missing granularity becoming the closest one" — every value
          # stays plausible and only the meaning is wrong, which is why it does not
          # surface as a failure on its own. `get_historical_prices/4`'s own doc makes the
          # identical claim ("The venue rejects a timeframe it does not serve rather than
          # substituting the nearest one"), and nothing checked it before this.
          #
          # Fake-only: picks a width from the shared vocabulary the venue's OWN
          # declaration does not name, and asks the fake for it. `Timeframe.nameable/0` is
          # Core's vocabulary, not a per-venue list this assertion has to keep in sync.
          caps = @venue.capabilities()

          if @fake && Capabilities.active?(caps, {:get_historical_prices, 4}) do
            # The width and the verdict are `AdapterContract.unserved_timeframe/1` and
            # `timeframe_fault/1`, public so the teeth tests run the suite's own logic.
            case DpExchange.Core.AdapterContract.unserved_timeframe(caps) do
              nil ->
                # This venue declares the entire nameable vocabulary — there is no width
                # left that would prove it refuses one.
                :ok

              unserved ->
                # The timeframe is the one argument this assertion must choose itself — an
                # `unserved` width is the whole question. The symbol and the opts come from
                # the venue's own declarations, the same as every other fake call here, so a
                # venue needing an option or a narrower symbol for this endpoint is not
                # silently refused.
                result =
                  call_on(@fake, {:get_historical_prices, 4}, [
                    arg_value(:symbol, {:get_historical_prices, 4}),
                    unserved,
                    [],
                    arg_value(:opts, {:get_historical_prices, 4})
                  ])

                assert DpExchange.Core.AdapterContract.timeframe_fault(result) == nil,
                       "get_historical_prices/4 answered {:ok, _} for #{inspect(unserved)}, " <>
                         "a width capabilities().historical_timeframes does not name — a " <>
                         "missing granularity becoming the closest one mislabels every " <>
                         "candle it touches"
            end
          end
        end
      end

      # --- 22. credentials never reach a supervisor's stored child spec -------

      describe "22. credential redaction in child_spec/1" do
        test "child_spec/1 renders no secret the consumer passed in :credentials" do
          # dp-exchange-core issue #29. A supervisor stores the `{module, :start_link,
          # [opts]}` MFA its child spec names, and OTP writes that argument list through
          # `inspect/1` into the `Start Call:` line of the report it logs on ANY child
          # termination. A raw `%{api_key: ..., private_key: ...}` map therefore prints its
          # values, in full, into ordinary application logs — the artifact most likely to
          # be shipped to an aggregator, attached to a bug report or quoted in a ticket. A
          # consumer found live keys exactly this way and nearly pasted them into a GitHub
          # issue while reporting an unrelated bug.
          #
          # **This is the assertion that assertion 19 says it cannot make.**
          # `Core.CredentialRedactionCheck` proves every STRUCT a package defines redacts
          # on inspect, and its own moduledoc records that it would not have caught the
          # defect as it actually shipped, where the value never became a struct at all.
          # This asks the only question a consumer cares about: having handed the venue a
          # secret the documented way, is that secret visible in what the supervisor will
          # store and the logger will print?
          #
          # Every secret key name any venue in this family uses is passed at once, so this
          # needs no per-venue list to keep in sync. `Kernel.struct/2` DROPS keys a given
          # venue's own credentials struct does not declare, so an unrecognised key cannot
          # leak either — it is gone, not merely unprinted.
          canary = "dpx-credential-canary-#{System.unique_integer([:positive])}"

          secrets = %{
            api_key: canary,
            api_secret: canary,
            private_key: canary,
            app_key: canary,
            app_secret: canary,
            access_token: canary,
            refresh_token: canary,
            client_id: canary,
            client_secret: canary,
            passphrase: canary,
            secret: canary,
            token: canary
          }

          rendered = inspect(@venue.child_spec(credentials: secrets), limit: :infinity)

          refute rendered =~ canary,
                 "#{inspect(@venue)}.child_spec/1 renders a secret passed in :credentials " <>
                   "in cleartext. A supervisor stores those args and OTP prints them on " <>
                   "every child crash, so this is a live credential written to the log by " <>
                   "any crash at all. Wrap the :credentials value in a struct with a " <>
                   "redacting Inspect IN child_spec/1 — doing it in start_link/1 or " <>
                   "init/1 is too late, because the supervisor above has already captured " <>
                   "the raw list. Rendered: #{rendered}"
        end
      end
    end
  end

  defp balance_attribution do
    quote location: :keep do
      # --- 24. a Balance names the asset it is a balance of ---------------------

      describe "24. balance attribution" do
        # `Core.Types.Balance` enforces `:currency`, and its `new/1` refuses a `nil` there.
        # **No venue decoder in this family calls `new/1`** — every one builds the struct
        # literally, which the type's own `Types.Validate` moduledoc explicitly permits — so
        # that check had never run anywhere, and four of the five packages read `currency`
        # straight out of the venue's JSON by key with nothing between. A renamed or absent
        # key produced `%Balance{currency: nil}`: an amount attributable to no asset,
        # returned inside `{:ok, balances}`, which a consumer cannot size, book or reconcile
        # against and which nothing in the value flags.
        #
        # Fixed in all four, and asserted here because of this suite's own ratchet rule:
        # "Every gap found becomes a new assertion here. A gap fixed only in one venue's
        # fake is a gap the next venue will reintroduce." Four separate fixes with no shared
        # assertion behind them is exactly that shape.
        #
        # **`:balance` is deliberately NOT checked.** `Core.Types.Balance` states that it may
        # honestly be `nil` while `:currency` may not — `dp_exchange_coinbase` derives its
        # total from the venue's available and hold figures and carries `nil` when either is
        # missing, rather than claiming a total it cannot compute. The two fields are not the
        # same kind of required: an unknown quantity is still a balance, an unattributable
        # one is not. An assertion covering both would force that venue to discard a real
        # `available_balance` in order to report an absence honestly.
        #
        # Fake-driven, like assertions 14, 20 and 23: `get_balances/2` is credentialed and
        # active on every venue that serves it, so calling the real one would make an
        # ordinary `mix test` reach the live API with real credentials.
        test "get_balances/2's Balance carries the currency it is a balance of" do
          assert_balance_attribution(@venue, @fake)
        end
      end

      # Silently skips a venue that declares the endpoint `:unsupported`, one with no fake,
      # and any answer that is not `{:ok, _}` — a refusal is a legitimate answer here, and a
      # venue with no balances to report is not a failure either.
      # A venue that declares `get_balances/2` `:unsupported`, or passes no fake, is skipped.
      # A venue that declares it ACTIVE and whose fake then refuses is NOT — that is the
      # silent skip this whole assertion exists to stop being possible.
      #
      # It used to end `_refused_or_unsupported -> :ok`, and that one clause is how three
      # packages passed an assertion that never ran on them: their fakes refused an
      # account-scoped call the suite made with no account, and the refusal was taken for an
      # answer. `endpoint_opts` removed the reason for that refusal, so a refusal now means
      # something is genuinely out of step — the capability says the endpoint works and the
      # venue's own fake says otherwise — and the two ways to be honest about it are both
      # named in the message.
      defp assert_balance_attribution(venue, fake) do
        endpoint = {:get_balances, 2}

        if Capabilities.active?(venue.capabilities(), endpoint) and fake do
          case apply(fake, :get_balances, endpoint_args(:get_balances, 2)) do
            {:ok, balances} when is_list(balances) ->
              # `Enum.each/2` over `[]` runs `assert_balance/1` zero times and reports green,
              # which is the same inability-to-fail assertion 25's own depth check records —
              # see `assert_side_ordering/4` for the measurement that found the axis. The
              # fake's fixture is the thing under test here as much as the code is.
              assert balances != [],
                     "capabilities/0 declares get_balances/2 active and the fake answered " <>
                       "`{:ok, []}`. Every per-balance assertion below then executes zero " <>
                       "times, so this group passes without checking a single Balance. The " <>
                       "fake's fixture must carry at least one."

              Enum.each(balances, &assert_balance/1)

            other ->
              flunk("""
              capabilities/0 declares get_balances/2 active, but the fake answered:

                  #{inspect(other)}

              A refusal here is not a pass. Either the endpoint is not really active and
              capabilities/0 should say `:unsupported`, or the fake needs something this
              call did not carry — declare it in `endpoint_opts:` on
              `use DpExchange.Core.AdapterContract`, the way the account-scoped venues
              declare their own `:account_id` / `:account_number` / `:account_hash`.

              Silently accepting this is what let three packages pass assertions that never
              executed on them — see docs/reference/core/assertion-coverage.md, "Second
              axis".
              """)
          end
        end
      end

      defp assert_balance(value) do
        # `AdapterContract.balance_fault/1`. `currency` must name the asset this is a balance
        # of: an amount attributable to nothing cannot be sized, booked or reconciled, and
        # unlike a missing quantity there is no "the venue declined to say" reading of it.
        # `timestamp` is when the balance was asked for (a balance with no freshness is
        # indistinguishable from a stale one) and `provider` says which venue answered.
        fault = DpExchange.Core.AdapterContract.balance_fault(value)

        assert fault == nil,
               "get_balances/2 must return DpExchange.Core.Types.Balance structs that name " <>
                 "their currency, timestamp and provider. Got #{inspect(fault)}"
      end
    end
  end

  defp return_types do
    quote location: :keep do
      # --- 5. return types -----------------------------------------------------

      describe "5. return types" do
        # **Assertion 5 was listed and had no check of its own.** `assertions/0` described it
        # as cross-cutting — "several groups each check part of" it — and they did check
        # parts: prices are Decimals in 14, times are DateTimes in 23, a Balance names its
        # asset in 24. Nothing asked the question the entry actually states: does an active
        # endpoint answer with the `Core.Types` struct its `Core.Venue` callback promises?
        #
        # Found 2026-09-24 in `dp_exchange_schwab`: `get_order/3` and `get_orders/2`, typed
        # `result(Types.Order.t())`, returned the venue's raw JSON map — and so did its fake,
        # which is the only thing this suite drives, so no assertion here could see it. Two
        # of that package's own tests had pinned the raw map.
        #
        # **The expectation comes from `Core.Venue`'s own `@callback` specs**, read with
        # `Code.Typespec.fetch_callbacks/1`, not from a table here — so a callback added later
        # is checked the day it is added, and a table cannot drift from the contract it
        # restates. Of the 88 callbacks, those whose success type names a `Core.Types` struct
        # are checked; an answer that is not `{:ok, _}` is left to the assertions that own
        # refusals (6 and 12). What fails is a success of the wrong kind: a raw map, or a list
        # holding anything but the promised struct.
        #
        # **What this does not catch, stated plainly:** the real venue. The suite drives
        # fakes; a fake that decodes through the same function as its real facade — the fix
        # `dp_exchange_schwab` made — is what carries the guarantee across.
        test "an active endpoint answers with the Core.Types struct its callback promises" do
          if @fake, do: assert_promised_types(@fake, @venue)
        end
      end

      defp assert_promised_types(fake, venue) do
        caps = venue.capabilities()

        answers =
          for {{name, arity}, modules} <- DpExchange.Core.AdapterContract.promised_types(),
              Capabilities.active?(caps, {name, arity}) do
            result = call_on(fake, {name, arity}, endpoint_args(name, arity))
            {name, arity, modules, result}
          end

        # **A group whose every active endpoint was refused checked no struct at all**, and
        # `answer_type_fault/2` takes a refusal as "not a success, so nothing to compare". A fake
        # refusing everything (a missing `endpoint_opts:`) therefore passed this group.
        assert answers == [] or
                 Enum.any?(answers, fn {_name, _arity, _modules, result} ->
                   DpExchange.Core.AdapterContract.struct_answer?(result)
                 end),
               "every active endpoint that promises a Core.Types struct was refused, failed " <>
                 "or answered an empty list, so no struct was checked and this group passes " <>
                 "for having looked at nothing. Declare what the fake needs in " <>
                 "`endpoint_opts:`, or give its fixture a row. Answers: " <>
                 inspect(Enum.map(answers, fn {n, a, _m, r} -> {n, a, elem_tag(r)} end))

        violations =
          for {name, arity, modules, result} <- answers,
              violation = DpExchange.Core.AdapterContract.answer_type_fault(result, modules),
              violation != nil do
            "  #{name}/#{arity} promises #{inspect(modules)} and answered #{violation}"
          end

        assert violations == [],
               "success answers that are not the Core.Types struct Core.Venue promises — a " <>
                 "consumer matching the struct, or reading its fields, breaks on this venue " <>
                 "only:\n" <> Enum.join(violations, "\n")
      end
    end
  end

  # What assertion 5 prints of one answer, apart from `return_types/0` so neither quoted
  # block passes credo's complexity ceiling. The verdict is `answer_type_fault/2`.
  defp return_type_helpers do
    quote location: :keep do
      defp elem_tag(result) when is_tuple(result), do: elem(result, 0)
      defp elem_tag(_result), do: :other
    end
  end

  # --- 31. the id a fake's place_order/3 returns is one its own get_order/3 and
  # cancel_order/3 accept. The decision is `Core.OrderRoundTripCheck.run/3`, public so it can
  # be shown to fail against a fake that refuses its own ids; this only builds the calls.
  defp fake_round_trip do
    quote location: :keep do
      describe "31. fake order round trip" do
        # dp_exchange_gemini issue #5. Gemini's fake answered `place_order/3` with an order
        # and then refused that order's id in its own `get_order/3` and `cancel_order/3`.
        # Nothing here noticed, because nothing used what `place_order/3` returned: group 5
        # asks `get_order/3` about an id the SUITE made up and takes a refusal for an answer,
        # and group 12 asks only that an active endpoint not say `:not_supported`. A
        # consumer's tier-1 test that places, reads back and cancels could not pass.
        #
        # **A refusal from an active `place_order/3` is not a pass**, for the reason
        # assertion 24's helper records: it is how an assertion goes on "passing" without
        # ever executing. Declare what the fake needs in `endpoint_opts:`, or declare the
        # endpoint `:unsupported`.
        #
        # **What this does not catch, stated plainly:** the real venue, and an id the real
        # venue would mint in a shape the fake does not. It proves the fake is consistent
        # with itself, which is the half that reaches a consumer's test suite.
        #
        # The same holds for the ids `place_orders/3`, `replace_order/4` and
        # `close_position/3` mint, each asked only when declared active. A refused
        # `place_orders/3` entry, or a refused `close_position/3` (the suite opens no
        # position), is an answer the contract allows and not a failure.
        test "ids the order-minting calls return are accepted by get_order/3, cancel_order/3" do
          if @fake, do: assert_order_round_trip(@fake, @venue.capabilities())
        end
      end

      defp assert_order_round_trip(fake, caps) do
        place_args = endpoint_args(:place_order, 3)

        placed_opts = List.last(place_args)

        calls = %{
          place_order: place_args,
          get_order: &round_trip_args(:get_order, &1, placed_opts),
          cancel_order: &round_trip_args(:cancel_order, &1, placed_opts),
          place_orders:
            :place_orders
            |> endpoint_args(3)
            |> round_trip_opts({:place_orders, 3}, placed_opts),
          replace_order: fn id ->
            :replace_order
            |> endpoint_args(4)
            |> List.replace_at(1, id)
            |> round_trip_opts({:replace_order, 4}, placed_opts)
          end,
          close_position:
            :close_position
            |> endpoint_args(3)
            |> round_trip_opts({:close_position, 3}, placed_opts)
        }

        case DpExchange.Core.OrderRoundTripCheck.run(fake, caps, calls) do
          :skipped ->
            :ok

          {:ok, violations} ->
            assert violations == [],
                   "the fake refused an order id its own place_order/3 had just returned. " <>
                     "A consumer's test that places an order and then reads or cancels it " <>
                     "cannot pass against this fake:\n" <>
                     DpExchange.Core.OrderRoundTripCheck.format(violations)

          {:error, reason} ->
            flunk("""
            capabilities/0 declares place_order/3 active, but the round trip could not start:

                #{DpExchange.Core.OrderRoundTripCheck.format_error(reason)}

            Either the endpoint is not really active and capabilities/0 should say
            `:unsupported`, or the fake needs something this call did not carry —
            declare it in `endpoint_opts:` on `use DpExchange.Core.AdapterContract`.

            See docs/reference/core/assertion-coverage.md, "Second axis".
            """)
        end
      end

      # The order id goes in the second position, where `get_order/3` and `cancel_order/3`
      # take it. The options are the endpoint's own `endpoint_opts` where the venue declared
      # some, and otherwise the options the order was PLACED with: an order placed under an
      # account is read and cancelled under that account, and a venue that scopes
      # `get_order/3` but not `cancel_order/3` in `endpoint_opts:` is not misconfigured for it.
      # The minting calls beyond `place_order/3` take the same fallback: their own declared
      # `endpoint_opts:` where there are some, the placed order's options otherwise.
      defp round_trip_opts(args, endpoint, placed_opts) do
        if Map.has_key?(@endpoint_opts, endpoint),
          do: args,
          else: List.replace_at(args, -1, placed_opts)
      end

      defp round_trip_args(name, id, placed_opts) do
        endpoint = {name, 3}

        opts =
          if Map.has_key?(@endpoint_opts, endpoint),
            do: arg_value(:opts, endpoint),
            else: placed_opts

        [arg_value(:credentials, endpoint), id, opts]
      end
    end
  end

  # --- 32-35. the family conventions, from the architect's tick O and P decisions. Each
  # decision is a public function above (`streaming_refusal_cases/2`, `order_request_cases/1`,
  # `market_price_fault/1`, ...) so that it can be shown to fail; these only build the calls.
  # Fake-driven like every group that calls an active endpoint, except the second half of 32,
  # which drives the real facade down the no-feed path assertion 28 already treats as safe:
  # nothing starts and nothing reaches the network.
  defp streaming_arguments do
    quote location: :keep do
      describe "32. streaming arguments are validated first" do
        # Found 2026-10-11 reading the five packages against each other. `unsubscribe(nil)`
        # answered `:ok` on some and raised on others, a bad `:to` was `{:invalid_subscriber,
        # _}` on three venues and a delivery to nobody on two, and a bad symbol list answered
        # `:feed_not_started` whenever no feed ran. Bad input must not depend on whether a
        # feed happens to be up, so the arguments are judged first, symbols before subscriber.
        test "the fake refuses a malformed symbol list and a bad subscriber" do
          if @fake do
            opts = arg_value(:opts, {:subscribe, 2})
            assert_conventions(@fake, streaming_cases(opts), "the fake's streaming calls", true)
          end
        end

        test "the real facade refuses the same with no feed running" do
          assert_conventions(
            @venue,
            streaming_cases(@absent_feed_opts),
            "the facade's streaming calls with no feed",
            true
          )
        end
      end

      defp streaming_cases(opts),
        do: DpExchange.Core.AdapterContract.streaming_refusal_cases(sample_symbol(), opts)
    end
  end

  defp single_symbol_refusals do
    quote location: :keep do
      describe "33. a symbol that is not text is refused before credentials" do
        # Called with credentials stripped: the refusal is decided locally, so it must not
        # matter that there are none. A venue that read credentials first answered
        # `{:missing_credentials, _}` for `nil`, and one that built the request first sent an
        # empty path segment, which the venue reads as a different endpoint.
        test "get_price/2 and get_top_of_book/2 answer {:invalid_symbol, value}" do
          if @fake do
            cases =
              DpExchange.Core.AdapterContract.single_symbol_refusal_cases(
                &stripped_arg_value(:opts, {&1, 2})
              )

            assert_conventions(@fake, cases, "the fake's single-symbol reads", false)
          end
        end
      end
    end
  end

  defp order_request_refusals do
    quote location: :keep do
      describe "34. place_order request discipline" do
        # Every rule exists so a caller cannot retry its way into a duplicate order or get a
        # different order than it asked for: a field the type does not use is refused and
        # never dropped, a missing type is never defaulted, a non-map never raises.
        test "a malformed request is refused with its tag, and a market price is not dropped" do
          if @fake, do: assert_order_request_refusals(@fake, @venue.capabilities())
        end
      end

      defp assert_order_request_refusals(fake, caps) do
        if Capabilities.active?(caps, {:place_order, 3}) do
          [credentials, base, opts] = endpoint_args(:place_order, 3)

          cases =
            for {request, reason} <- DpExchange.Core.AdapterContract.order_request_cases(base),
                do: {:place_order, [credentials, request, opts], reason}

          assert_conventions(fake, cases, "the fake's place_order/3", true)
          assert_market_price_refused(fake, caps, [credentials, base, opts])
        end
      end

      defp assert_market_price_refused(fake, caps, [credentials, base, opts]) do
        requests = DpExchange.Core.AdapterContract.market_price_requests(base, caps)
        answers = for r <- requests, do: call_on(fake, {:place_order, 3}, [credentials, r, opts])

        assert DpExchange.Core.AdapterContract.market_price_fault(answers) == nil,
               "a `:price` on a `:market` order must be `{:error, {:unexpected_field, :price}}`, " <>
                 "never dropped. Answers, one per time in force tried: " <>
                 inspect(answers, limit: 8)
      end
    end
  end

  defp order_id_refusals do
    quote location: :keep do
      describe "35. order ids are checked first" do
        # With the venue's own options and with none, both with credentials stripped: the id
        # is judged before the account option and before credentials, so neither a missing
        # account nor a missing credential may be the answer for a blank id.
        test "get_order/3 and cancel_order/3 answer {:invalid_order_id, value}" do
          if @fake do
            cases =
              DpExchange.Core.AdapterContract.order_id_refusal_cases(fn name ->
                Enum.uniq([stripped_arg_value(:opts, {name, 3}), [credentials: %{}]])
              end)

            assert_conventions(@fake, cases, "the fake's order id reads", false)
          end
        end
      end
    end
  end

  # --- 36-39. the market-data conventions of tick R (MD1, MD2, MD3, MD5, MD6), fake-driven.
  defp include_partial_refusals do
    quote location: :keep do
      describe "36. include_partial must be a boolean" do
        # The still-forming bar is opt-in (MD1), so the option is a flag, and a flag that is
        # not a boolean is refused rather than read as truthy: `"false"` is truthy.
        test "get_historical_prices/4 answers {:invalid_option, :include_partial, v}" do
          endpoint = {:get_historical_prices, 4}
          timeframe = DpExchange.Core.AdapterContract.probe_timeframe(@venue.capabilities())

          if @fake && timeframe do
            cases =
              DpExchange.Core.AdapterContract.include_partial_refusal_cases(
                arg_value(:symbol, endpoint),
                timeframe,
                arg_value(:opts, endpoint)
              )

            assert_conventions(@fake, cases, "the fake's candle options", true)
          end
        end
      end
    end
  end

  defp candle_conventions do
    quote location: :keep do
      describe "37. candles are oldest first, on their grid, and a range is [start, end)" do
        # MD2 and MD3. The range is chosen from the fake's own bars, so a venue is never asked
        # for a window it has no data in; a refused range is not evidence and is skipped.
        test "the fake's candles and the ranges re-asked from them" do
          caps = @venue.capabilities()
          timeframe = DpExchange.Core.AdapterContract.probe_timeframe(caps)

          if @fake && timeframe && Capabilities.active?(caps, {:get_historical_prices, 4}) do
            assert_candle_conventions(timeframe)
          end
        end
      end

      defp ask_candles(timeframe, range) do
        endpoint = {:get_historical_prices, 4}
        args = [arg_value(:symbol, endpoint), timeframe, range, arg_value(:opts, endpoint)]
        call_on(@fake, endpoint, args)
      end

      defp assert_candle_conventions(timeframe) do
        # **The unbounded ask must return bars.** A refusal or an empty list used to skip the
        # whole group (`with` fell through), so a fake missing an `endpoint_opts:` entry, or
        # one with no fixture rows, passed having checked no candle. The range asks below
        # may still be refused (a window with no data is not evidence); this one may not.
        answer = ask_candles(timeframe, [])

        case DpExchange.Core.AdapterContract.candle_ask_fault(answer) do
          nil ->
            {:ok, candles} = answer
            assert_candle_series(candles, timeframe)

          {:no_candles, other} ->
            flunk(
              "capabilities/0 declares get_historical_prices/4 active, but asking the fake " <>
                "for #{inspect(timeframe)} with no range answered #{inspect(other, limit: 8)}, " <>
                "not a non-empty `{:ok, candles}`, so no candle was checked and this group " <>
                "passes for having looked at nothing. Declare what the fake needs in " <>
                "`endpoint_opts:`, give its fixture a bar, or declare the endpoint " <>
                "`:unsupported`."
            )
        end
      end

      defp assert_candle_series(candles, timeframe) do
        fault =
          DpExchange.Core.AdapterContract.candle_series_fault(
            candles,
            timeframe,
            @venue.asset_classes()
          )

        assert fault == nil,
               "get_historical_prices/4 candles must be oldest first and aligned to " <>
                 "#{timeframe} (Core.Timeframe.aligned?/2; a session-traded venue needs " <>
                 "30-minute alignment for a wider intraday width). Got #{inspect(fault)}"

        probes = DpExchange.Core.AdapterContract.candle_range_probes(candles)
        for {range, must} <- probes, do: assert_range_kept(timeframe, range, must)
      end

      defp assert_range_kept(timeframe, range, must_include) do
        answer = ask_candles(timeframe, range)
        fault = DpExchange.Core.AdapterContract.range_fault(range, answer, must_include)

        assert fault == nil,
               "a range is `:start` inclusive and `:end` exclusive on opened_at. Asked " <>
                 "#{inspect(range)}, got #{inspect(fault)}"
      end
    end
  end

  defp book_option_conventions do
    quote location: :keep do
      describe "38. order book options: :depth is honoured, :limit is not misread" do
        # MD5. `:depth` is levels per side. `:limit` is Coinbase's refused spelling; a venue
        # without one may ignore it (Core's usage rules), so only a raise or an unrelated
        # error is a fault. Skipped where `get_order_book/2` is declared `:unsupported`.
        test "depth: 1 returns at most one level a side; limit: 1 is refused or tolerated" do
          if @fake && Capabilities.active?(@venue.capabilities(), {:get_order_book, 2}) do
            assert_book_options()
          end
        end
      end

      defp assert_book_options do
        [symbol, opts] = endpoint_args(:get_order_book, 2)
        depth = DpExchange.Core.AdapterContract.book_probe_depth()
        # `extra` replaces a same-named key in the venue's own `endpoint_opts` (a keyword's first
        # entry wins on lookup, so appending would silently ask with the venue's own value).
        ask = fn extra ->
          call_on(@fake, {:get_order_book, 2}, [symbol, Keyword.merge(opts, extra)])
        end

        depth_fault = DpExchange.Core.AdapterContract.book_depth_fault(ask.(depth: depth), depth)

        assert depth_fault == nil,
               "get_order_book/2 with depth: #{depth} must carry at most #{depth} level(s) a " <>
                 "side. Got #{inspect(depth_fault)}"

        limit_fault = DpExchange.Core.AdapterContract.book_limit_fault(ask.([]), ask.(limit: 1))

        assert limit_fault == nil,
               "get_order_book/2 with limit: 1 must succeed, or be refused " <>
                 "{:unsupported_option, :limit} or {:invalid_option, :limit, v}. " <>
                 "Got #{inspect(limit_fault)}"
      end
    end
  end

  defp positive_values do
    quote location: :keep do
      describe "39. prices and sizes are positive, books are best first" do
        # MD6 and MD5. A traded price at or below zero is a refused item, never a value; a
        # book level with no size is no liquidity and is dropped. Checked on the fake's own
        # answers; an answer that is not a success is skipped.
        test "every price, size and level the fake returns" do
          if @fake do
            endpoints = positive_endpoints()
            examined = for endpoint <- endpoints, do: assert_positive(endpoint)

            # **A fake that refuses every one of these examined nothing.** Each refusal is
            # skipped above (a refused item is not evidence), so a fake missing an
            # `endpoint_opts:` entry passed the group having looked at no value at all.
            refute DpExchange.Core.AdapterContract.nothing_examined?(endpoints, examined),
                   "every active price endpoint (#{inspect(endpoints)}) was refused or " <>
                     "failed, so no price, size or level was checked and this group passes " <>
                     "for having looked at nothing. Declare what the fake needs in " <>
                     "`endpoint_opts:`, or declare the endpoints `:unsupported`."
          end
        end
      end

      defp positive_endpoints do
        for endpoint <- [
              {:get_price, 2},
              {:get_top_of_book, 2},
              {:get_historical_prices, 4},
              {:get_trades, 2},
              {:get_order_book, 2}
            ],
            Capabilities.active?(@venue.capabilities(), endpoint),
            do: endpoint
      end

      defp positive_args({:get_historical_prices, 4} = endpoint) do
        timeframe = DpExchange.Core.AdapterContract.probe_timeframe(@venue.capabilities())
        [arg_value(:symbol, endpoint), timeframe || "1h", [], arg_value(:opts, endpoint)]
      end

      defp positive_args({name, arity}), do: endpoint_args(name, arity)

      # Answers whether it examined a value, so the test can refuse a run that examined none.
      defp assert_positive({name, _arity} = endpoint) do
        case call_on(@fake, endpoint, positive_args(endpoint)) do
          {:ok, value} ->
            fault = DpExchange.Core.AdapterContract.market_value_fault(value)

            assert fault == nil,
                   "#{name} returned a value that breaks the price conventions: #{inspect(fault)}"

            true

          _not_a_success ->
            false
        end
      end
    end
  end

  defp convention_helpers do
    quote location: :keep do
      # Runs `cases` against `module`, skipping a callback `capabilities/0` declares
      # `:unsupported`. `required?` refuses a run that examined nothing: a loop over no calls
      # reports green having checked none, which is the failure this suite exists against.
      defp assert_conventions(module, cases, what, required?) do
        eligible =
          DpExchange.Core.AdapterContract.eligible_cases(module, @venue.capabilities(), cases)

        # Nothing eligible is a failure only when the venue declares one of these calls active
        # (so it is missing); a venue that declares them all `:unsupported` has nothing to hold.
        assert not (required? and
                      DpExchange.Core.AdapterContract.nothing_checked?(
                        module,
                        @venue.capabilities(),
                        cases
                      )),
               "#{what}: no call was eligible, so nothing was checked"

        faults = DpExchange.Core.AdapterContract.case_faults(module, eligible)

        assert faults == [],
               "#{what} did not refuse as the family convention says:\n" <>
                 DpExchange.Core.AdapterContract.format_case_faults(faults)
      end
    end
  end

  defp lower_case_subscription do
    quote location: :keep do
      # --- 29. a lower-case subscription is delivered under the canonical symbol ----------

      describe "29. a lower-case subscription is delivered under the canonical symbol" do
        # Found 2026-09-28. Every venue's real facade upper-cases subscribed symbols,
        # because its `Feed` drops a payload for a symbol it does not want and the venue
        # delivers the canonical form. Every fake took the symbols as given, so `btc-usd`
        # delivered nothing against the fake while the real package delivered `BTC-USD`. A
        # consumer's tier-1 tests certified silence where the venue delivers: the fake
        # drifting from the real facade, which is the half of the contract this suite
        # exists to keep honest. The real facade's half is each package's own test.
        test "subscribe/2 with a lower-case sample pair delivers under the canonical symbol" do
          if @fake, do: assert_lower_case_delivered(@fake, @sample_pairs)
        end
      end

      defp assert_lower_case_delivered(fake, pairs) do
        for pair <- Enum.take(pairs, 1), do: assert_lower_case_delivered_one(fake, pair)
      end

      defp assert_lower_case_delivered_one(fake, pair) do
        opts = arg_value(:opts, {:subscribe, 2})

        # The decision is `AdapterContract.lower_case_delivery_fault/4`, public so it can be
        # shown to fail. 5_000 ms is the wait for a delivery from an asynchronous fake.
        fault = DpExchange.Core.AdapterContract.lower_case_delivery_fault(fake, pair, opts, 5_000)

        assert fault == nil,
               "subscribe/2 with #{inspect(String.downcase(pair))} delivered nothing " <>
                 "under #{inspect(pair)}. The real facade upper-cases subscribed " <>
                 "symbols; the fake must too, or it certifies silence."
      end
    end
  end

  defp feed_absent do
    quote location: :keep do
      # --- 28. a streaming call answers when no feed is running ------------------------

      describe "28. a streaming call answers when no feed is running" do
        # Every streaming callback is specified to return a value: `:ok | {:error, term()}`,
        # or a map. Found 2026-09-27: three of five venues sent these calls into their feed
        # with a bare `GenServer.call/3`, which EXITS the caller, with `:noproc` when no feed
        # is running and with `:timeout` when a feed is too busy. The other two answered
        # `{:error, :feed_not_started}`, so the same consumer code survived on two venues and
        # crashed on three. That is the drift this suite exists to catch.
        #
        # **Unlike every other streaming assertion here, this drives the real facade.** The
        # fake has no feed to be missing. The no-feed path starts nothing and sends nothing,
        # so it is safe at tier 1. **What this does not catch:** a busy feed's `:timeout`,
        # which needs a feed's whole call budget to observe. Each venue's own facade test
        # holds a feed that dies mid-call, which goes through the same `catch`.
        test "with no feed running, every streaming call returns a value" do
          # Loaded first: `function_exported?/3` below is false for a module not yet loaded,
          # and tests run in random order, so this could filter every entry out and pass.
          Code.ensure_loaded!(@venue)

          for {name, arity, call} <- [
                {:subscribe, 2, fn -> @venue.subscribe(@sample_pairs, @absent_feed_opts) end},
                {:unsubscribe, 2, fn -> @venue.unsubscribe(@sample_pairs, @absent_feed_opts) end},
                {:update_symbols, 2,
                 fn -> @venue.update_symbols(@sample_pairs, @absent_feed_opts) end},
                {:subscribe_notices, 1, fn -> @venue.subscribe_notices(@absent_feed_opts) end},
                {:coverage, 1, fn -> @venue.coverage(@absent_feed_opts) end}
              ],
              function_exported?(@venue, name, arity) do
            # `AdapterContract.streaming_call_fault/1`, public so it can be shown to fail.
            fault = DpExchange.Core.AdapterContract.streaming_call_fault(call)

            assert fault == nil,
                   "#{name}/#{arity} with no feed running: #{inspect(fault)}. A streaming " <>
                     "call returns a value (`:ok`, `{:error, _}` or a map); wrap the call " <>
                     "into the feed and answer `{:error, :feed_not_started}` rather than " <>
                     "exiting the caller."
          end
        end
      end
    end
  end

  defp forwarded_nil do
    quote location: :keep do
      # --- 27. a forwarded nil is an absent option -----------------------------

      describe "27. a forwarded nil is an absent option" do
        # This family forwards `opts` unchanged through every layer, by convention, so an
        # option a caller's own caller never set arrives as `key: nil` rather than absent.
        # `Keyword.get/3` substitutes its default only for an ABSENT key, and
        # `DpExchange.Core.Config.opt/3` exists precisely because of that — its moduledoc
        # records the trap closing "as a class". It had not closed everywhere.
        #
        # Found 2026-09-23 on `:to`, in all five packages at once, and the two halves failed
        # in OPPOSITE directions. A real `Feed` put `nil` in its subscriber set, and
        # `Core.Fanout.deliver/4` resolves `nil` the way it resolves any name nothing answers
        # to — nobody — so `subscribe/2` answered `:ok` and data never arrived. The fakes
        # called `send(nil, _)`, which raises. A consumer's tier-1 tests therefore could not
        # have shown them the real behaviour, even by accident: the fake crashed where the
        # venue went quiet.
        #
        # **What this does not catch, stated plainly:** the real feed. The suite drives
        # fakes; each venue package holds a probe-based test of its own `Feed.subscribe/3`
        # for the same line. This is the half that reaches a consumer's test suite.
        #
        # Deliberately NOT asserted for `:name`. There `nil` is not "unset" — it is OTP's own
        # documented way to say "do not register this process", and every venue's test
        # support starts unnamed feeds with it. The sweep that found `:to` converted `:name`
        # too, and five test files went red at once; that is recorded so it is not tried
        # again.
        test "subscribe/2 with `to: nil` delivers to the caller, and does not raise" do
          if @fake, do: assert_nil_recipient_is_the_caller(@fake, @sample_pairs)
        end
      end

      defp assert_nil_recipient_is_the_caller(fake, pairs) do
        opts = arg_value(:opts, {:subscribe, 2})

        # The decision is `AdapterContract.nil_recipient_fault/4`, public so it can be shown
        # to fail. 5_000 ms is the wait for a delivery from a fake that sends asynchronously.
        case DpExchange.Core.AdapterContract.nil_recipient_fault(fake, pairs, opts, 5_000) do
          nil ->
            :ok

          :nothing_delivered ->
            flunk(
              "subscribe/2 with `to: nil` delivered nothing to the caller. A `nil` " <>
                "subscriber is delivered to nobody, and answers `:ok` while doing it."
            )

          raised ->
            flunk(
              "subscribe/2 raised on `to: nil`: #{inspect(raised)}. A forwarded `nil` is a " <>
                "caller that said nothing, and nothing means the caller — resolve it with " <>
                "`DpExchange.Core.Config.opt/3`, not `Keyword.get/3`."
            )
        end
      end
    end
  end

  defp subscription_set_semantics do
    quote location: :keep do
      # --- 26. subscription set semantics ---------------------------------------

      describe "26. subscription set semantics" do
        # **`subscribe/2` adds; `update_symbols/2` replaces; `unsubscribe/2` removes.** The
        # three are different operations on one set, and nothing checked that a venue kept
        # them different.
        #
        # Found 2026-09-16 by asking the fakes the same three questions in order. Four of
        # five answered that a second `subscribe/2` REPLACED the first — their `subscribe/2`
        # and `update_symbols/2` were byte-for-byte the same line — while every real `Feed`
        # in the family unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))`,
        # and `dp_exchange_robinhood`'s facade spells it `current ++ symbols`). So a
        # consumer's tier-1 tests certified the opposite of what the venue does: subscribe
        # twice, keep one symbol against the fake, keep both against the venue.
        #
        # `c:DpExchange.Core.Venue.subscribe/2`'s own doc does not say which it is, and this
        # assertion does not need it to. The contract settles it by shape:
        # `c:update_symbols/2` exists to "change a live subscription's symbol set" and
        # `c:unsubscribe/2` to stop delivery for named symbols. Neither has any purpose if
        # `subscribe/2` already replaces — a caller would just subscribe the new list. Two
        # callbacks the contract distinguishes, implemented as one function, is the tell.
        #
        # **What this does not catch, stated plainly:** the real feed's own set arithmetic.
        # The suite drives fakes; each venue's feed tests hold the real one. Assertion 25
        # records the same division of labour for the same reason. What it does catch is the
        # fake drifting from it, which is the half that reaches a consumer's test suite.
        test "subscribe/2 adds to the set, update_symbols/2 replaces it, unsubscribe/2 removes" do
          # Every other fake-driven group checks for a fake; this one called `nil.update_symbols`
          # without one. And with fewer than two pairs it raised a bare `MatchError`.
          if @fake do
            assert length(@sample_pairs) >= 2,
                   "assertion 26 needs two `sample_pairs:` the venue serves, or \"added\" and " <>
                     "\"replaced\" are the same answer; got #{inspect(@sample_pairs)}"

            assert_subscription_set_semantics(@fake, @sample_pairs)
          end
        end
      end
    end
  end

  defp subscription_set_helpers do
    quote location: :keep do
      defp assert_subscription_set_semantics(fake, pairs) do
        opts = arg_value(:opts, {:subscribe, 2})

        # Needs two symbols the venue actually serves; with one, "added" and "replaced" are
        # the same answer and this assertion could not fail — see
        # `docs/reference/core/assertion-coverage.md`, "Third axis". The decision is
        # `AdapterContract.subscription_set_fault/3`, public so it can be shown to fail.
        case DpExchange.Core.AdapterContract.subscription_set_fault(fake, pairs, opts) do
          nil ->
            :ok

          {:never_covered, symbol} ->
            flunk(
              "the fake reported no coverage for #{inspect(symbol)} after subscribing it, " <>
                "so every comparison below is between empty sets and this assertion cannot " <>
                "fail. See assertion 14's message for the two things that cause this."
            )

          {:subscribe_dropped, dropped} ->
            flunk(
              "subscribe/2 dropped #{inspect(dropped)} when a second symbol was " <>
                "subscribed. It ADDS to the live set — every real Feed in this family " <>
                "unions — and a fake that replaces certifies consumer code that subscribes " <>
                "once per symbol and silently keeps only the last. If this fake's " <>
                "subscribe/2 and update_symbols/2 are the same line, that is why."
            )

          {:subscribe_missed, symbol} ->
            flunk("subscribe/2 did not add #{inspect(symbol)} to the live set")

          {:unsubscribe_left, symbol} ->
            flunk(
              "unsubscribe/2 left #{inspect(symbol)} covered — it stops delivery for the " <>
                "symbols it names"
            )

          {:unsubscribe_overreached, symbol} ->
            flunk("unsubscribe/2 removed #{inspect(symbol)}, which it was not asked about")

          {:update_not_taken, symbol} ->
            flunk("update_symbols/2 did not take: #{inspect(symbol)} is not covered")

          {:update_left, symbol} ->
            flunk(
              "update_symbols/2 left #{inspect(symbol)} covered. It REPLACES the set — that " <>
                "is the whole difference between it and subscribe/2, and a venue where " <>
                "both add has one callback doing two jobs and the other doing none."
            )
        end
      end
    end
  end

  # Assertion 11's process check. It walked the `:unsupported` endpoints, which answer
  # `{:error, :not_supported}`, so it could not fail. The answers that can carry a process
  # are the ACTIVE ones, asked of the fake, which answers without a network. Only a success
  # is data: `call_on/3` turns an exit into `{:exit, reason}`, which may name a pid.
  defp process_helpers do
    quote location: :keep do
      defp assert_no_process_in_answers(fake, venue) do
        caps = venue.capabilities()

        for {{name, arity}, _modules} <- DpExchange.Core.AdapterContract.promised_types(),
            Capabilities.active?(caps, {name, arity}) do
          result = call_on(fake, {name, arity}, endpoint_args(name, arity))

          carries? = DpExchange.Core.AdapterContract.carries_process?(result)

          refute match?({:ok, _value}, result) and carries?,
                 "#{name}/#{arity} answered with a process, port or reference inside: " <>
                   inspect(result, limit: 8)
        end
      end
    end
  end

  defp helpers do
    quote location: :keep do
      # --- helpers ---------------------------------------------------------

      defp call_endpoint(endpoint), do: call_on(@venue, endpoint)

      defp call_on(module, {name, arity}),
        do: call_on(module, {name, arity}, endpoint_args(name, arity))

      # The 3-arity form takes explicit args rather than deriving them from `{name,
      # arity}` — assertion 17 needs the SAME shape `endpoint_args/2` builds but with
      # credentials stripped, which is a different question from "what does this
      # endpoint normally take".
      defp call_on(module, {name, _arity}, args) do
        apply(module, name, args)
      rescue
        error -> {:raised, error}
      catch
        kind, reason -> {kind, reason}
      end

      # Lifecycle callbacks are not answerable by calling them — `child_spec/1` returns a
      # spec, `start_link/1` starts something. Their maturity is asserted for presence
      # like everything else; the round trip does not apply.
      defp answerable?({name, _arity}), do: name not in [:child_spec, :start_link]
    end
  end

  # How each endpoint's arguments are shaped, by position: credentials first where the
  # facade takes them, then a symbol, then options.
  defp arg_helpers do
    quote location: :keep do
      # Read from `Core.Venue`'s own specs, not listed by hand: see
      # `AdapterContract.credentialed_callbacks/0` for the eleven callbacks a list missed.
      @credentialed DpExchange.Core.AdapterContract.credentialed_callbacks()

      # Assertions 16, 18 and 19 all read compiled modules under `package_root`. A root that
      # matches nothing used to answer `{:ok, []}` from all three — "no violations" — so one
      # mistyped or stale `package_root:` turned three assertions green at once, two of them
      # the credential-leak ones, while examining nothing. The checks now refuse an empty
      # scan; this says what to do about it, because `{:error, {:no_modules_scanned, _}}`
      # arriving at a bare `assert ... = ...` would otherwise read as a broken check rather
      # than as a misconfigured suite.
      defp scan_failure_message(check, lib_root) do
        "#{check} could not scan anything under #{lib_root}. That is almost always " <>
          "`package_root:` on `use DpExchange.Core.AdapterContract` pointing somewhere this " <>
          ~s(package's compiled modules are not — it defaults to "lib", venue packages set ) <>
          ~s("lib/dp_exchange", and Core's own suite sets "test/support". Until it points ) <>
          "at real modules, assertions 16, 18 and 19 are all examining nothing and passing. " <>
          "If the error above names `:no_abstract_code`, it is a different cause: that " <>
          "module's beam was compiled without debug_info, so there is no code to read. " <>
          "`:not_loadable` names a module the test node cannot load."
      end

      # The shape table, overrides included, is `AdapterContract.arg_shape/3`, shared with
      # assertion 17's credential-stripped call so the two cannot drift apart.
      defp endpoint_args(name, arity) do
        name
        |> DpExchange.Core.AdapterContract.arg_shape(arity, credentialed?(name))
        |> Enum.map(&arg_value(&1, {name, arity}))
      end

      defp arg_value(:credentials, _endpoint), do: @credentials

      # The order-write arguments, apart in `order_arg_helpers/0` so this block stays simple.
      defp arg_value(kind, _endpoint)
           when kind in [:order_request, :order_requests, :order_id, :order_changes],
           do: order_arg(kind)

      defp arg_value(:symbol, endpoint),
        do: Map.get(@endpoint_symbols, endpoint, sample_symbol())

      defp arg_value(:timeframe, _endpoint), do: "1h"

      # Asset, amount, network, address and the rest — see `@arg_overrides`. Apart in
      # `value_arg_helpers/0`, like the order arguments, to keep this block simple.
      defp arg_value(kind, _endpoint)
           when kind in [
                  :asset,
                  :quote_asset,
                  :amount,
                  :network,
                  :address,
                  :fx_pair,
                  :at,
                  :statement_kind,
                  :name,
                  :symbols,
                  :payment_details,
                  :account_id
                ],
           do: value_arg(kind)

      # The venue's own per-endpoint options, plus the credential every venue's contract
      # test already supplies.
      #
      # **`credentials:` is here because four of five packages were skipping assertions 14
      # and 23 entirely.** Both build a call to the fake for a PUBLIC-shaped endpoint —
      # `get_top_of_book/2`, `get_price/2`, `get_order_book/2` — whose arg shape carries no
      # credential position, so the only place one can travel is `opts`. Nothing put it
      # there, so every venue declaring `credential_benefit: :required` answered
      # `{:error, {:missing_credentials, _}}`, and the assertions' own
      # `_refused_or_unsupported -> :ok` clause took that for an answer. Only
      # `dp_exchange_gemini`, which needs no credential, ever ran them.
      #
      # `put_new/3`, so a venue's own `endpoint_opts` still wins, and so assertion 17's
      # stripped-credential path — which sets `credentials: %{}` deliberately — is not
      # fighting this one. A venue that needs no credential is unharmed: an extra opt its
      # facade does not read costs nothing.
      defp arg_value(:opts, endpoint) do
        @endpoint_opts
        |> Map.get(endpoint, [])
        |> Keyword.put_new(:credentials, @credentials)
      end

      defp sample_symbol, do: List.first(@sample_pairs) || "BTC-USD"

      defp credentialed?(name), do: name in @credentialed
    end
  end

  # Assertion 17's own helpers, split from `arg_helpers/0` rather than added to it: a
  # single quoted block growing past credo's complexity ceiling is the same "400-line
  # block nobody reads" this file's groups already exist to avoid, just measured in
  # cyclomatic complexity instead of line count.
  # `place_order/3` and `replace_order/4`'s arguments for assertion 5 — see `@arg_overrides`.
  defp order_arg_helpers do
    quote location: :keep do
      # The venue's own `order_args:` entry where it declared one, the generic default
      # otherwise. `:order_id` is never overridden: assertion 31 replaces it with a minted id.
      defp order_arg(kind) do
        case Map.fetch(@order_args, kind) do
          {:ok, value} -> value
          :error -> default_order_arg(kind)
        end
      end

      # A small limit buy: the shape every venue's `place_order/3` reads, sized so no fake
      # refuses it for being too large.
      defp default_order_arg(:order_request) do
        %{
          symbol: sample_symbol(),
          side: :buy,
          order_type: :limit,
          time_in_force: :gtc,
          quantity: Decimal.new("0.001"),
          price: Decimal.new("1")
        }
      end

      # `place_orders/3` takes a list: a batch of one is still a batch.
      defp default_order_arg(:order_requests), do: [order_arg(:order_request)]
      defp default_order_arg(:order_id), do: "contract-order-1"
      defp default_order_arg(:order_changes), do: %{price: Decimal.new("1")}
    end
  end

  # The non-symbol, non-order arguments `@arg_overrides` names, each the type its
  # `Core.Venue` spec declares. The asset is the sample pair's base, so a venue that only
  # knows its own listed assets is asked about one of them.
  defp value_arg_helpers do
    quote location: :keep do
      defp value_arg(:asset), do: sample_symbol() |> String.split("-") |> hd()
      defp value_arg(:quote_asset), do: "USD"
      defp value_arg(:amount), do: Decimal.new("0.001")
      defp value_arg(:network), do: "contract-network"
      defp value_arg(:address), do: "contract-address"
      defp value_arg(:fx_pair), do: "EUR-USD"
      defp value_arg(:at), do: ~U[2026-01-02 15:00:00Z]
    end
  end

  # The rest of `value_arg/1`'s clauses, apart so neither block passes credo's complexity
  # ceiling. Same function, same order: `__using__/1` expands the two blocks adjacently.
  defp value_arg_more_helpers do
    quote location: :keep do
      defp value_arg(:statement_kind), do: :income
      defp value_arg(:name), do: "contract-name"
      defp value_arg(:symbols), do: [sample_symbol()]
      defp value_arg(:payment_details), do: %{"type" => "bank", "name" => "contract-method"}
      defp value_arg(:account_id), do: "contract-account-1"
    end
  end

  defp credential_gate_helpers do
    quote location: :keep do
      defp assert_credential_gate(venue, fake) do
        caps = venue.capabilities()

        if caps.credential_benefit == :required do
          assert fake,
                 "pass `fake:` to run this assertion. It never dials out — only the " <>
                   "fake is called — but it needs the venue's in-process fake to " <>
                   "call against."

          # The selection is `AdapterContract.credential_gated_endpoints/2`, public so the
          # decision itself can be shown to fail. See its doc for the exemptions.
          gated =
            DpExchange.Core.AdapterContract.credential_gated_endpoints(
              caps,
              venue.asset_classes()
            )

          # A loop over nothing passes: a venue that is `:required` and exempts or declares
          # away ALL of its endpoints has had this assertion examine none.
          assert gated != [],
                 "#{inspect(venue)} declares credential_benefit: :required but no active " <>
                   "endpoint is left for the credential gate to check, so it passes having " <>
                   "checked nothing. Declare at least one credentialed endpoint active."

          for {name, arity} <- gated do
            args = stripped_credential_args(name, arity)

            refute match?({:ok, _}, call_on(fake, {name, arity}, args)),
                   "#{inspect({name, arity})} answered {:ok, _} with credentials " <>
                     "stripped, but #{inspect(venue)} declares credential_benefit: " <>
                     ":required — a fake that succeeds without credentials certifies " <>
                     "consumer code that forgot to supply them"
          end
        end
      end

      # The selection of WHICH endpoints are gated (the two `credentials() | nil` callbacks, a
      # crypto-only `market_status/1`, `no_venue_contact`) is
      # `AdapterContract.credential_gated_endpoints/2`. `market_status/1`'s own doc claims
      # "crypto venues answer `:open`" because crypto has no session for a credential to
      # gate; that is scoped to `asset_classes() == [:crypto]` rather than folded into the
      # name exemptions, so `dp_exchange_schwab`'s authenticated `market_status/1` stays
      # covered.

      # The same shape `endpoint_args/2` builds, with every credential position
      # emptied — positional where the venue's arg shape carries one (`@credentialed`,
      # unchanged, still governs SHAPE only: whether credentials arrive as an argument
      # or through `opts`), and in `opts` for every endpoint, public-shaped ones
      # included.
      defp stripped_credential_args(name, arity) do
        name
        |> DpExchange.Core.AdapterContract.arg_shape(arity, credentialed?(name))
        |> Enum.map(&stripped_arg_value(&1, {name, arity}))
      end

      defp stripped_arg_value(:credentials, _endpoint), do: %{}

      # `credentials: %{}`, never a bare `[]`. An opts list that started empty and stayed
      # empty would prove nothing had been stripped — it never carried a credential to begin
      # with, on any venue. An EXPLICIT empty credential exercises a venue whose facade
      # reads `Keyword.get(opts, :credentials, %{})` rather than an absent key its own code
      # may never read at all.
      #
      # The venue's own `@endpoint_opts` are kept alongside it, and that is the half this
      # was missing. On an account-scoped venue the call was refused for the MISSING ACCOUNT
      # before the stripped credential was ever looked at, so this assertion passed for the
      # wrong reason on three of the five packages — it proved the fake rejects a call with
      # no account, which is not what it claims to prove. `credentials: %{}` is put last so
      # a venue cannot accidentally supply a credential here through its endpoint opts.
      defp stripped_arg_value(:opts, endpoint) do
        @endpoint_opts
        |> Map.get(endpoint, [])
        |> Keyword.put(:credentials, %{})
      end

      defp stripped_arg_value(other, endpoint), do: arg_value(other, endpoint)
    end
  end
end
