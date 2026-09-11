defmodule DpExchange.Core.LinkSafetyCheck do
  @moduledoc """
  Finds a long-lived process that links a child it starts itself and never traps exits.

  ## The defect this exists for

  **A feed process must survive the death of any process it links.** Found live in four
  of five venue packages on 2026-09-07: `Feed.init/1` never called `Process.flag(:trap_exit,
  true)`, and `Socket.start_link/1` (or `PollingFeed.start_link/1`) ran from *inside* a
  `Feed` callback — `handle_call/3`, `handle_info/2`, or a `{:continue, _}` reached from
  either — which links the child to `Feed` itself, not to a supervisor. An abnormal exit
  on that link is untrappable without the flag, so a socket dying anywhere killed `Feed`,
  and the `Supervisor` restarted it from its **static start opts** — every `subscribe/2`
  a consumer had made since boot, gone in the same instant.

  Fixed identically in all five repos, by calling `Process.flag(:trap_exit, true)` as the
  first thing `init/1` does: `dp_exchange_coinbase` `e77b542`, `dp_exchange_gemini`
  `66acd3b`, `dp_exchange_webull` `d0c54a8`, `dp_exchange_schwab` `90dddc6`,
  `dp_exchange_robinhood` `51ad189`. **Five independent fixes converging on the identical
  one-line remedy is the strongest possible sign that the remedy, not a runtime
  simulation of the crash, is what a static check should look for.**

  ## Why this is static, not behavioural

  The obvious check is behavioural: start the package's real tree, read the feed's
  `Process.info(pid, :links)`, kill one, assert the feed survives. It was tried first and
  rejected, for a reason specific to this family rather than a general objection to
  behavioural tests: **starting a venue's real (non-fake) tree is not reliably
  network-free.**

  Four of five venues defer any socket or poll to `subscribe/2`/`update_symbols/2` — proven
  by reading `init/1` in each: `Coinbase`, `Gemini` and `Webull` return `{:ok, state}` with
  no `{:continue, _}`, and `Robinhood`'s `PollingFeed` schedules its first fetch
  `@default_start_delay_ms` (8s) out rather than firing one immediately. **`dp_exchange_schwab`
  does not**: `Feed.init/1` returns `{:ok, state, {:continue, :connect}}`, and
  `handle_continue(:connect, state)` unconditionally calls `ensure_route/1`, which — absent
  an already-open `state.socket` — calls `Rest.get_user_preference/2`, a real HTTP request
  to Schwab's live API, **regardless of whether any symbol has ever been subscribed**.
  Starting `DpExchange.Schwab`'s supervision tree with nothing but `child_spec/1` therefore
  dials the network today, which is exactly what a suite every consumer runs on every CI
  run must never do (`CLAUDE.md`'s testing strategy, tier 1).

  The one way to prevent that dial without starting the real socket is to inject an
  already-open stand-in through an option each venue happens to expose for its own tests
  (`:socket` here, differently named or absent elsewhere) — which is exactly what this
  suite's own moduledoc forbids: *"No assertion may name a socket, a channel string, a
  transport module or a polling interval. If one does, mechanism has leaked through the
  facade and the assertion is the bug, not the venue."* A behavioural check that only
  works by knowing a venue's private test-injection option name is that bug.

  There is also no reliable, generic way to *find* "the feed" once a tree is running.
  `DpExchange.Core.FeedBehaviour` existed for exactly this and was implemented by none of
  the five venues — grepped, zero adopters. Walking `child_spec/1`'s supervision tree for
  worker children finds every long-lived process a venue starts (a rate limiter, a task
  supervisor, a feed), not specifically the one this invariant is about.

  So: a behavioural version of this check would need to risk a live network call on at
  least one shipped venue, or lean on a naming convention the contract explicitly forbids,
  or both. **This is the "narrower thing that is [mechanically enforceable]"** — it proves
  nothing was ever started, checks source-derived fact rather than simulated behaviour, and
  cannot dial out because nothing here ever runs.

  ### One half of that reasoning expired the same day it was written

  The network-call objection was true of `dp_exchange_schwab`, whose `Feed.init/1` returned
  `{:ok, state, {:continue, :connect}}` and dialled the Streamer before anything had
  subscribed. **That was itself a boundary violation** — the family's rule is that a
  consumer who has not asked for a venue must not find a socket open — and it was fixed
  hours later, in `dp_exchange_schwab` `9973c0d`. All five venues now defer every dial to
  `subscribe/2` or a first tick, so starting a tree touches no network.

  The *second* objection stands, and hardened in 0.3.0: there is still no
  contract-sanctioned way to locate "the feed" generically, and `Core.FeedBehaviour` — the
  thing that would have provided one — was **deleted** rather than adopted. Its signatures
  matched nothing: `start_feed/2` existed in no venue, and its `update_symbols/2` was wrong
  for `dp_exchange_webull`, which takes credentials per call like every other endpoint in
  this family and so needs `update_symbols/3`. A behaviour whose shape contradicts all five
  implementations is not a hook waiting to be used; it is a fourth restatement of the
  contract that happens to be wrong, and adopting it would have meant changing working
  venues to match a module nobody had ever run.

  So walking `child_spec/1`'s tree still finds every long-lived child rather than the one
  this invariant is about. A behavioural check remains **possible but not clean**, and is
  recorded here rather than built, so the next person weighing it starts from what is
  actually true — including that the obvious-looking hook was examined and found unusable.

  ### What a static check cannot see, stated so nobody over-trusts it

  This proves the guard is *present*, not that a crash is *isolated*. A module can trap
  exits and still handle the resulting `{:EXIT, _, _}` wrongly. That is not hypothetical:
  `dp_exchange_webull` already had `trap_exit` and per-shard isolation on 2026-09-07 and
  **still** left `coverage/1` reporting a crashed shard's symbols as `:stream` — a real
  defect this assertion would have passed. Whether coverage tells the truth after a child
  dies is a per-venue invariant Core cannot express, because Core does not know which
  symbols a given child carried. It belongs in each venue's own suite, and every venue has
  such a test as of that date.

  ## What it checks

  For every module compiled from this package's own `lib/` that declares one of
  `GenServer`, `:gen_statem`, `GenStateMachine` or `WebSockex` as a `@behaviour` — every
  shape this family's `Feed` and `Socket` modules are actually built from — the module's
  own compiled abstract code is scanned, in full, for two facts:

    * **a link-creating call**: a remote call named `start_link` (any target module, any
      arity — `Socket.start_link/1`, `PollingFeed.start_link/1`, `Task.Supervisor.
      start_link/1`, all match, because `X.start_link` always links the calling process to
      the one it starts, by the same OTP convention this whole family builds on), or
      `Process.link/1` / `:erlang.link/1`, or `spawn_link` in any arity.
    * **the guard**: a call to `:erlang.process_flag(:trap_exit, true)` — what `Process.
      flag(:trap_exit, true)` compiles to (verified against a compiled probe module: it is
      a plain remote call, with `:trap_exit` and `true` as literal atom arguments, not a
      macro or anything special-formed).

  A module with the first and not the second is a violation: it manufactures a link to a
  process it started and has no way to survive that process dying abnormally. A module
  with neither is not a candidate at all — most process behaviours in a venue package
  start nothing themselves and have nothing to protect against.

  This deliberately does **not** require the link-creating call to be reachable specifically
  from `init/1`, or from any single named callback. The five real fixes disagree on where
  they call it and where they open sockets from (Coinbase and Schwab open lazily from a
  callback other than `init/1`; Gemini and Robinhood link something directly inside
  `init/1`) — the invariant that matters is "this module, considered as a whole, both
  manufactures a link and protects itself," not which specific function does which.

  `start_link/1`, `start_link/2`, `child_spec/1` and `child_spec/2` are never scanned as
  the SOURCE of a link-creating call — found live running this check against the real,
  compiled `dp_exchange_coinbase`: `Socket.start_link/1` (`use WebSockex`) delegates to
  `WebSockex.start_link/4` to bootstrap itself, which is a call literally named
  `start_link`, on every process-behaviour module in the family, always. That link
  belongs to whoever CALLS `Socket.start_link/1` — a `Feed` callback, in production —
  not to `Socket`, and `Feed` is exactly the module this check is supposed to flag (and
  does, correctly, once its own code rather than `Socket`'s bootstrap wrapper is what is
  under scan). `DpExchange.Core.UnwiredCheck` already excuses the same two names for an
  analogous reason (`@always_excluded`); this reuses that precedent rather than
  reinventing it.

  ## What this does not catch

  It does not prove the module *handles* the resulting `{:EXIT, pid, reason}` message
  correctly — clearing coverage, firing a `:link_down` notice, reopening the child. A
  `GenServer` that traps exits but defines no `handle_info/2` for the exit tuple still
  survives (`use GenServer` injects a default `handle_info/2` that logs and continues,
  proven by inspecting a compiled probe module's abstract code), which is the literal claim
  this check makes — "the feed process must survive" — and no more. Whether it *recovers
  usefully* is a richer behaviour, is genuinely different per venue (which notice, which
  state gets cleared, whether it reopens immediately or on the next tick), and is exactly
  the kind of venue-specific mechanism this contract's own moduledoc forbids an assertion
  from encoding.

  It also does not catch a link created any other way than the four call shapes above — a
  link established through a NIF, a port, or code assembled at runtime and dispatched via
  `apply/3` with a dynamically built function name. No static tool resolves genuinely
  dynamic dispatch, the same limit `DpExchange.Core.UnwiredCheck`'s moduledoc already
  states for the same reason.
  """

  @process_behaviours [GenServer, :gen_statem, GenStateMachine, WebSockex]
  # A plain list, not a `MapSet`: a `MapSet` literal built from a module attribute and
  # compared with `MapSet.member?/2` fails Dialyzer's PLT check with a
  # `call_without_opaque` mismatch — the same finding this family already hit once
  # (`Core.Notice`'s `@credential_keys`, C8 in the 2026-09-05 defect sweep) and reverted
  # for the same reason. Three entries make a linear scan irrelevant next to that.
  @link_creating_functions [:start_link, :link, :spawn_link]

  @type violation :: %{
          module: module(),
          function: atom(),
          arity: non_neg_integer(),
          file: String.t() | nil,
          line: pos_integer() | nil
        }

  @doc """
  Finds every process-behaviour module under `lib_root` that creates a link without
  trapping exits.

  `beam_dir` is a directory of compiled `.beam` files (typically
  `Mix.Project.build_path() |> Path.join("lib/\#{app}/ebin")`), the same one
  `DpExchange.Core.UnwiredCheck.run/3` reads. Only modules whose recorded `:compile_info`
  source path falls under `lib_root` are analysed, whichever Mix environment produced the
  `.beam` files.
  """
  @spec run(Path.t(), Path.t()) :: {:ok, [violation()]} | {:error, term()}
  def run(beam_dir, lib_root) do
    lib_root = Path.expand(lib_root)

    with {:ok, modules} <- collect_modules(beam_dir, lib_root) do
      violations =
        modules
        |> Enum.filter(&process_behaviour?/1)
        |> Enum.flat_map(&check_module/1)
        |> Enum.sort()

      {:ok, violations}
    end
  end

  @doc "Renders `run/2` violations as one line per finding, for a failure message."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    violations
    |> Enum.map(fn v ->
      location =
        case v.line do
          nil -> v.file || "unknown source"
          line -> "#{v.file}:#{line}"
        end

      "  #{inspect(v.module)} links a child from #{v.function}/#{v.arity} " <>
        "(#{location}) and never calls Process.flag(:trap_exit, true)"
    end)
    |> Enum.join("\n")
  end

  defp process_behaviour?(%{behaviours: behaviours}) do
    Enum.any?(behaviours, &(&1 in @process_behaviours))
  end

  defp check_module(described) do
    case find_link(described.forms) do
      nil ->
        []

      {name, arity, line} ->
        if any_trap_exit?(described.forms) do
          []
        else
          [
            %{
              module: described.module,
              function: name,
              arity: arity,
              file: described.source,
              line: line
            }
          ]
        end
    end
  end

  # `start_link/1` and `start_link/2` are never a source of "this module creates a
  # link", the same convention `DpExchange.Core.UnwiredCheck` already treats as
  # universally excused (`@always_excluded`) and for an analogous reason. Every
  # `use GenServer`/`use WebSockex`/`use :gen_statem` module's own `start_link/N`
  # delegates to that behaviour's own `start_link` — `WebSockex.start_link/4`,
  # `GenServer.start_link/3` — to bootstrap ITSELF, and that call's own name is
  # literally `:start_link`. Scanning it would flag every process-behaviour module in
  # the family, including ones that link nothing at all: found live against
  # `dp_exchange_coinbase`'s `Socket`, whose `start_link/1` delegates to
  # `WebSockex.start_link/4` and nothing else. The link that call creates belongs to
  # WHOEVER CALLS `Socket.start_link/1` (a `Feed` callback, in production) — which is
  # already the module this check is supposed to flag, and correctly does, once `Feed`'s
  # own code (not `Socket`'s) is the one under scan. `child_spec/1` and `child_spec/2`
  # are excluded for the same reason, though — see the moduledoc's "why this is static"
  # — their generated body never contains a literal call at all, only an MFA data tuple.
  @excused_from_link_scan [start_link: 1, start_link: 2, child_spec: 1, child_spec: 2]

  # First function form (in compiled order) whose body contains a link-creating call.
  # Named for the failure message; the invariant itself does not care which function it
  # was, per the moduledoc's "does not require... any single named callback".
  defp find_link(forms) do
    Enum.find_value(forms, fn
      {:function, anno, name, arity, clauses} ->
        if {name, arity} not in @excused_from_link_scan and contains_link_call?(clauses) do
          {name, arity, :erl_anno.line(anno)}
        end

      _other_form ->
        nil
    end)
  end

  defp any_trap_exit?(forms) do
    Enum.any?(forms, fn
      {:function, _anno, _name, _arity, clauses} -> contains_trap_exit?(clauses)
      _other_form -> false
    end)
  end

  defp contains_link_call?(term) do
    walk_any?(term, fn
      {:call, _anno, {:remote, _anno2, {:atom, _anno3, _mod}, {:atom, _anno4, fun}}, _args} ->
        fun in @link_creating_functions

      _other ->
        false
    end)
  end

  defp contains_trap_exit?(term) do
    walk_any?(term, fn
      {:call, _anno, {:remote, _anno2, {:atom, _anno3, :erlang}, {:atom, _anno4, :process_flag}},
       [{:atom, _anno5, :trap_exit}, {:atom, _anno6, true}]} ->
        true

      _other ->
        false
    end)
  end

  # A generic walk over Erlang abstract-format terms: every node is a tuple, a list of
  # nodes, or a leaf (atom/integer/string/etc). Tuples and lists are the only two shapes
  # that ever nest another node, so recursing into exactly those two, uniformly, reaches
  # every call in the term regardless of which clause, case, with, or comprehension it is
  # buried inside — the same reason `DpExchange.Core.UnwiredCheck` reads `:xref`'s real
  # edge relation rather than a grep: control flow does not hide a plain function call
  # from a walk that visits every subterm.
  defp walk_any?(term, matcher) do
    matcher.(term) or
      case term do
        tuple when is_tuple(tuple) -> tuple |> Tuple.to_list() |> walk_any?(matcher)
        list when is_list(list) -> Enum.any?(list, &walk_any?(&1, matcher))
        _leaf -> false
      end
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
        with_source(module, charlist_path, compile_info, lib_root)

      {:error, :beam_lib, reason} ->
        {:error, reason}
    end
  end

  defp with_source(module, charlist_path, compile_info, lib_root) do
    case Keyword.get(compile_info, :source) do
      nil ->
        {:ok, nil}

      source ->
        source = source |> to_string() |> Path.expand()

        if String.starts_with?(source, lib_root <> "/") do
          {:ok, described_module(module, charlist_path, source)}
        else
          {:ok, nil}
        end
    end
  end

  defp described_module(module, charlist_path, source) do
    {:ok, {^module, [attributes: attrs]}} = :beam_lib.chunks(charlist_path, [:attributes])

    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(charlist_path, [:abstract_code])

    %{
      module: module,
      source: source,
      forms: forms,
      behaviours: attrs |> Keyword.get_values(:behaviour) |> List.flatten()
    }
  end
end
