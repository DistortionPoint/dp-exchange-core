defmodule DpExchange.Core.UnwiredCheck do
  @moduledoc """
  Finds an internal function nothing in a package's own `lib/` ever calls.

  ## The defect this exists for

  **"Mechanism built, documented, and never wired."** Six instances in one week across
  this family, every one shipped green:

    * `rate_limit_blocking` plumbed through `Core.HttpClient` but never set by the
      caller — `dp_exchange_robinhood` (issue #16), `dp_exchange_webull` (issue #23,
      where it had to be threaded through three separate option allowlists and a fix
      stopping at the first layer still passed every test asserting the keyword was
      present), `dp_exchange_coinbase` (issue #26).
    * `FrameSender`'s retry path in `dp_exchange_coinbase` — documented as the thing a
      caller does after a failed batch; the caller reported and never retried
      (issue #22).
    * `dp_exchange_schwab`'s `subscribe_notices/1` facade — built, nothing ever emitted
      to it, because the internal registry it should have delegated to
      (`Feed.subscribe_notices/2`) had no caller anywhere in `lib/`.
    * `dp_exchange_schwab`'s `Auth.refresh/2` — zero call sites anywhere in `lib/`,
      while `Socket` captured `access_token` once at `start_link/1` and `websockex`
      reconnects synchronously with no delay, so an expired token became an undelayed
      loop hammering the venue with a credential the package could not replace.

  In every case a test called the function directly, so coverage stayed high and the
  suite stayed green — a test is not a caller. **An internal function with no caller in
  the package's own `lib/` is either dead code or an unwired mechanism, and both are
  defects.**

  ## Real call-graph data, not a grep

  Built on `:xref`, the same OTP cross-reference tool `Core.AdapterContract`'s "7.
  purity" assertion already reads `imports` chunks through. A grep trips on
  `apply(Mod, :fun, args)` and on a captured `&Mod.fun/1` — both are ordinary, correct
  ways to call a function and neither looks like a call textually. `:xref`'s edge
  relation (`E`, queried below as `E || M:F/A` — restrict the range to a specific
  callee) resolves both correctly, including a call from a function back to its own
  module. What it cannot resolve is genuinely dynamic dispatch — a module or function
  name assembled at runtime — and no static tool can; that limit is inherent to the
  problem, not particular to this check.

  `:xref.analyze(:exports_not_used)` was considered and rejected: its own semantics are
  "not called from outside the defining module," so a public function called only by a
  sibling function in the same module reads as unused even though something in `lib/`
  plainly calls it. Querying the raw edge relation and building the "was this ever a
  callee, from anywhere in the analysed set" answer ourselves avoids that false
  positive.

  ## What counts as a caller

  Anything reachable through `:xref`'s edge relation from a module whose compiled
  `:compile_info` source path is under `lib_root` — regardless of which Mix environment
  produced the `.beam` files. A package compiled under `MIX_ENV=test` (`elixirc_paths`
  commonly adding `test/support`) still only has its `lib/`-sourced modules added to the
  `:xref` server here, so a function reachable only from `test/support` — a fake, a
  fixture, a helper only the suite imports — is **not** treated as wired. That is
  deliberate: it is exactly the shape of six known instances of this defect, where a
  test calling the function directly was the reason nothing looked wrong.

  ## What is excluded, and why each is safe to exclude without an allowlist that rots

    * **`excluded_modules`** — whole modules the caller names explicitly, not inferred.
      `Core.AdapterContract`'s "16. internal wiring" assertion passes `[@venue, @fake]`:
      the facade (called only by consumers, by the family's own contract — see
      `usage-rules/adapter.md`) and the in-process fake (called only by a consumer's
      tests, never by this package's own `lib/`). Both bindings already exist for other
      assertions in the same suite; nothing new is hand-maintained here.
    * **Behaviour callbacks** — read from the module's own `:attributes` chunk
      (`@behaviour` targets) and each target's own `behaviour_info(:callbacks)`, so
      `GenServer`, `WebSockex`, `Supervisor`, `DpExchange.Core.Venue` and any other
      behaviour a module declares excuses exactly the callbacks that behaviour defines —
      never a function the module merely happens to export. A callback's default body,
      injected by `use` and never overridden, is still excused: it satisfies the same
      name/arity whether hand-written or macro-generated.
    * **`child_spec/1` and `start_link/1`** — always excused, on every module, because a
      `Supervisor` calls them by convention rather than through any call `:xref` can see
      in the analysed set.
    * **Compiler-injected exports** — `module_info/0`, `module_info/1`, and any export
      whose name is wrapped in double underscores (`__struct__`, `__info__`, `__impl__`,
      …), the compiler's own naming convention for exactly this category.

  ## What this does not catch

  A function reachable only through the package's own `Fake` module and never through
  any real production path is not flagged — `Fake` is part of `lib/`, so a call from it
  satisfies the letter of "something in `lib/` calls it," even though the real code path
  may still be dead. That is a narrower, rarer defect shape than the one this check was
  built for, and asserting it would mean inferring which of a module's callers are
  "real," which is not mechanically separable from the fake/real distinction this family
  already draws by hand in each package's own fixtures.
  """

  @dunder_pattern ~r/^__.+__$/
  # `child_spec/2` alongside `child_spec/1`: `use WebSockex` (and, for older `Supervisor`
  # versions, `use GenServer`) injects BOTH arities as real, overridable exports — neither
  # is a `@callback`, so behaviour introspection alone would miss the second. Found by
  # running this check against `dp_exchange_schwab`'s pre-fix `Socket`, which `use
  # WebSockex`s and never wrote `child_spec` itself.
  @always_excluded [child_spec: 1, child_spec: 2, start_link: 1]
  @compiler_exports [module_info: 0, module_info: 1]

  @type violation :: %{
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          file: String.t() | nil,
          line: pos_integer() | nil
        }

  @doc """
  Finds internal functions with no caller under `lib_root`.

  `beam_dir` is a directory of compiled `.beam` files (typically
  `Mix.Project.build_path() |> Path.join("lib/\#{app}/ebin")`). Only the ones among them
  whose recorded `:compile_info` source path falls under `lib_root` are analysed; the
  rest are silently ignored, whichever Mix environment produced them.

  `excluded_modules` are analysed for call-graph purposes (so a function they call still
  counts as wired) but never themselves reported as violations — pass the facade and any
  fake/reference implementation the caller exposes as public surface in its own right.
  """
  @spec run(Path.t(), Path.t(), [module()]) :: {:ok, [violation()]} | {:error, term()}
  def run(beam_dir, lib_root, excluded_modules \\ []) do
    lib_root = Path.expand(lib_root)
    excluded = MapSet.new(excluded_modules)

    with {:ok, modules} <- collect_modules(beam_dir, lib_root),
         {:ok, edges} <- called_edges(modules) do
      violations =
        modules
        |> Enum.reject(&MapSet.member?(excluded, &1.module))
        |> Enum.flat_map(&unused_exports(&1, edges))
        |> Enum.sort()

      {:ok, violations}
    end
  end

  @doc "Renders `run/3` violations as one line per finding, for a failure message."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    violations
    |> Enum.map(fn v ->
      location =
        case v.line do
          nil -> v.file || "unknown source"
          line -> "#{v.file}:#{line}"
        end

      "  #{inspect(v.module)}.#{v.function}/#{v.arity} — #{location}"
    end)
    |> Enum.join("\n")
  end

  defp collect_modules(beam_dir, lib_root) do
    beam_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn beam_path, {:ok, acc} ->
      case describe_beam(beam_path, lib_root) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, described} -> {:cont, {:ok, [described | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp describe_beam(beam_path, lib_root) do
    charlist_path = String.to_charlist(beam_path)

    case :beam_lib.chunks(charlist_path, [:compile_info]) do
      {:ok, {module, [compile_info: compile_info]}} ->
        with_source(module, beam_path, charlist_path, compile_info, lib_root)

      {:error, :beam_lib, reason} ->
        {:error, reason}
    end
  end

  defp with_source(module, beam_path, charlist_path, compile_info, lib_root) do
    case Keyword.get(compile_info, :source) do
      nil ->
        {:ok, nil}

      source ->
        source = source |> to_string() |> Path.expand()

        if String.starts_with?(source, lib_root <> "/") do
          {:ok, described_module(module, beam_path, charlist_path, source)}
        else
          {:ok, nil}
        end
    end
  end

  defp described_module(module, beam_path, charlist_path, source) do
    {:ok, {^module, [exports: exports]}} = :beam_lib.chunks(charlist_path, [:exports])
    {:ok, {^module, [attributes: attrs]}} = :beam_lib.chunks(charlist_path, [:attributes])

    %{
      module: module,
      beam_path: beam_path,
      source: source,
      exports: exports,
      behaviours: attrs |> Keyword.get_values(:behaviour) |> List.flatten()
    }
  end

  # The full edge relation (`E`), local and cross-module calls alike, restricted to the
  # modules just added — so a call from `test/support` or a dependency, neither of which
  # was ever added, cannot make an internal function look wired. Kept as `{caller,
  # callee}` pairs, not flattened to a callee set, because `unused_exports/2` needs to
  # tell a call from OUTSIDE a function's own default-argument group apart from the
  # group's own internal forwarding.
  defp called_edges(modules) do
    # `:xref.start/1` takes only a registered NAME, never a PID or an unnamed variant, so
    # unlike `Core.AdapterContract`'s `permitted_module?/2` (which sidesteps the same
    # sobelow finding by comparing dependency names as strings instead of atoms) there is
    # no way to avoid this call shape here. `System.unique_integer/1` is a VM-internal
    # counter, not user or venue input, so what it interpolates is bounded the same way
    # `Core.FakeInjection`'s fixed atom key is — sobelow's `DOS.BinToAtom` flags the call
    # shape itself, confidence aside, and this repo's `.sobelow-conf` accepts a
    # low-confidence finding rather than exit-0 the whole check (`exit: :high`).
    server = :"dp_exchange_core_unwired_check_#{System.unique_integer([:positive])}"
    {:ok, _pid} = :xref.start(server)

    try do
      :xref.set_default(server, verbose: false, warnings: false)

      Enum.each(modules, fn %{beam_path: path} ->
        {:ok, _module} = :xref.add_module(server, String.to_charlist(path))
      end)

      case :xref.q(server, ~c"E") do
        {:ok, edges} -> {:ok, MapSet.new(edges)}
        {:error, _module, _reason} = error -> {:error, error}
      end
    after
      :xref.stop(server)
    end
  end

  # A default argument (`def f(a, b \\ x)`) compiles to TWO exports, `f/1` and `f/2`,
  # with the lower arity's entire body a call to the higher one — Elixir's own
  # desugaring, not this module's assumption about one. Reporting each arity on its own
  # merits would flag `f/1` as unwired the moment every caller happens to pass the
  # optional argument explicitly, even though `f` itself is plainly in use: exactly what
  # running this check against `dp_exchange_schwab`'s pre-fix `Feed.subscribe/2` (called
  # everywhere as `/3`) and `Auth.headers/1` (called everywhere as `/2`) turned up.
  #
  # So a function's own name — not its arity — is the unit "does something else in
  # lib/ still reach this" is asked about. A same-name group counts as wired the moment
  # ANY of its arities has a caller from outside the group; a caller from within the
  # group (the desugared forwarding call itself) does not count, or a totally dead
  # default-argument function would wire itself through its own generated wrapper. An
  # unwired group is reported once, at its highest arity — where a real caller would
  # reach for it, and where `Auth.refresh/2` and `Auth.needs_refresh?/2` (both `\\`
  # arities, both dead end to end) name themselves in this package's own `@spec`s.
  defp unused_exports(described, edges) do
    excluded_locally = behaviour_callbacks(described.behaviours)

    described.exports
    |> Enum.reject(fn export -> excluded_export?(export, excluded_locally) end)
    |> Enum.group_by(fn {name, _arity} -> name end)
    |> Enum.reject(fn {name, group} -> group_wired?(edges, described.module, name, group) end)
    |> Enum.map(fn {name, group} ->
      max_arity = group |> Enum.map(fn {_name, arity} -> arity end) |> Enum.max()
      to_violation(described, name, max_arity)
    end)
  end

  defp group_wired?(edges, module, name, group) do
    arities = MapSet.new(group, fn {_name, arity} -> arity end)

    Enum.any?(edges, fn {caller, {callee_mod, callee_name, callee_arity}} ->
      callee_mod == module and callee_name == name and MapSet.member?(arities, callee_arity) and
        not from_same_group?(caller, module, name, arities)
    end)
  end

  defp from_same_group?({caller_mod, caller_name, caller_arity}, module, name, arities) do
    caller_mod == module and caller_name == name and MapSet.member?(arities, caller_arity)
  end

  defp excluded_export?({name, arity}, behaviour_callbacks) do
    {name, arity} in @always_excluded or
      {name, arity} in @compiler_exports or
      MapSet.member?(behaviour_callbacks, {name, arity}) or
      dunder?(name)
  end

  defp dunder?(name), do: name |> Atom.to_string() |> then(&Regex.match?(@dunder_pattern, &1))

  defp behaviour_callbacks(behaviours) do
    behaviours
    |> Enum.flat_map(&callbacks_of/1)
    |> MapSet.new()
  end

  defp callbacks_of(behaviour) do
    behaviour.behaviour_info(:callbacks)
  rescue
    UndefinedFunctionError -> []
  end

  defp to_violation(described, name, arity) do
    {line, _source} = locate(described, name, arity)

    %{module: described.module, function: name, arity: arity, file: described.source, line: line}
  end

  defp locate(described, name, arity) do
    case :beam_lib.chunks(String.to_charlist(described.beam_path), [:abstract_code]) do
      {:ok, {_module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        line =
          Enum.find_value(forms, fn
            {:function, anno, ^name, ^arity, _clauses} -> :erl_anno.line(anno)
            _other_form -> nil
          end)

        {line, described.source}

      _no_abstract_code ->
        {nil, described.source}
    end
  end
end
