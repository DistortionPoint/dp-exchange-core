defmodule DpExchange.Core.CredentialRedactionCheck do
  @moduledoc """
  Finds a struct, defined in a package's own `lib/`, that holds a secret-named field in
  cleartext under `inspect/1`.

  ## The defect this exists for

  **A crash of `Feed` or `Socket` printed a credential in cleartext, in OTP's own crash
  report.** Found live in four of five venue packages on 2026-09-07: both processes held
  `:credentials` as a bare map for their entire lifetime — `Feed` to keep resigning
  requests across reconnects and resubscribe sweeps, `Socket` to sign every authenticated
  frame. OTP's default crash report prints a process's state in full on termination, and a
  plain map prints every key it holds, secrets included — proven by crashing an equivalent
  process holding `%{api_key: "...", api_secret: "..."}` as a bare state field and reading
  the log back. A second path to the same leak was found the same way: a
  `FunctionClauseError`'s stacktrace prints the actual arguments a clause was called with,
  so a bad call handed the same raw credential map to a function whose every clause failed
  to match also printed it. `Process.flag(:sensitive, true)` was tried and ruled out — it
  changes what `:sys.get_state/1` and `:dbg` can see, not how a crash report or a
  stacktrace is formatted.

  Fixed identically in four repos, by wrapping the credential in a dedicated struct whose
  `Inspect` implementation is derived with `except:` naming every secret field, at the
  point the credential enters a long-lived process: `dp_exchange_coinbase` `4d00669`
  (`api_key`, `api_secret`), `dp_exchange_webull` `80eaf02` (`app_key`, `app_secret`,
  `access_token`), `dp_exchange_schwab` `336cbd8` (`access_token`, `refresh_token`,
  `client_id`, `client_secret`), `dp_exchange_robinhood` `cfc4861` (`api_key`,
  `private_key`). `dp_exchange_gemini` needed no fix: it signs and discards inside
  stateless pipelines and holds no credential in process state at all. **Four of five
  independently getting this wrong is a contract problem, not four coincidences** — the
  same reason assertions 16, 17 and 18 exist: a defect found once in this family and
  fixed only in the venue it was found in is a defect the next venue reintroduces.

  ## What it checks, and how "redacted" is verified

  For every struct defined in the package's own `lib/` (a module that exports
  `__struct__/0`, whose compiled `:compile_info` source path falls under `lib_root`), if
  any of its own fields — not inherited, not a sibling module's — is named one of the
  known secret names below, that field must not appear in `inspect/1`'s rendering of a
  struct instance carrying a distinctive value in exactly that field.

  **This is a behavioural check of the actual `Inspect` output, not a check for the
  presence of `@derive {Inspect, except: [...]}`.** A module is instantiated with
  `struct(module, [{secret_field, sentinel}])` — `struct/2`, not `struct!/2`, so
  `@enforce_keys` on an unrelated field never blocks construction — and the rendered
  `inspect/1` output is searched for the sentinel. A hand-written
  `defimpl Inspect, for: MyStruct do ... end` that never mentions `@derive` at all redacts
  exactly as validly as the derived form every real fix in this family used, and this
  check cannot tell the two apart because it never looks at the struct's source for either
  — only at what the field actually prints. Every module under test is already loaded, by
  construction: this check only ever runs from inside the same `mix test` invocation that
  compiled the package being checked (via `AdapterContract`'s generated assertion), so
  `struct/2` and `inspect/1` here execute against the real, already-running module —
  never against a fresh process, and never touching a network, the venue's own `Rest` or
  `Auth` module, or anything the venue's own code would dial out through.

  ## The secret-name list, and why each name is on it

  Fifteen names, as atoms, matched against a struct field's own name exactly — never a
  substring match, so a field called `token_type` or `tokenizer_state` is not caught by
  `token` and is not meant to be:

      api_key api_secret app_key app_secret secret password passphrase token
      access_token refresh_token client_secret private_key signature authorization bearer

  Twelve of these (`api_key`, `api_secret`, `secret`, `password`, `passphrase`, `token`,
  `access_token`, `refresh_token`, `private_key`, `signature`, `authorization`, `bearer`)
  are `DpExchange.Core.Notice`'s own `@credential_keys` — already the family's answer to
  "what does a secret-shaped key look like," shipped for a different purpose (rejecting a
  credential-shaped key from a `Notice`'s `:details`) but the identical question: does
  this name, on its own, mean "do not print this value." Reused rather than reinvented,
  the same way `LinkSafetyCheck` reused `UnwiredCheck`'s `start_link/1,2`/`child_spec/1,2`
  exclusion rather than re-deriving it.

  Three names extend that list, each because a real, shipped `Credentials` struct in this
  family has a field by that name and `Notice`'s list does not cover it:

    * **`app_key`, `app_secret`** — `dp_exchange_webull`'s `Credentials` struct
      (`lib/dp_exchange/webull/credentials.ex`). Webull's own commit message
      (`80eaf02`) is explicit that `app_key` *alone*, held as a bare string on `Socket`
      (a separate field, never wrapped in this struct), is not confidential — it is sent
      as a plaintext header on every signed request the venue accepts. That is not a
      reason to leave `app_key` off this list: it is a reason this check only ever looks
      at **struct fields**, never at a plain map or a bare string field, so Webull's
      deliberately-unwrapped `Socket.app_key` — which is not a struct field at all — stays
      completely untouched by this assertion, exactly as intended, while `app_key` *inside*
      `Credentials` (where Webull's own author chose to redact it alongside `app_secret`
      for consistency, even though it argued the field alone carries no confidentiality)
      still gets the same guarantee. `app_secret` is the actual HMAC-SHA1 signing key and
      is confidential without qualification.
    * **`client_secret`** — `dp_exchange_schwab`'s `Credentials` struct
      (`lib/dp_exchange/schwab/credentials.ex`), the OAuth application secret paired with
      `refresh_token`.

  **`client_id` is deliberately excluded**, though Schwab's own struct redacts it too
  (`@derive {Inspect, except: [:access_token, :refresh_token, :client_id, :client_secret]}`).
  An OAuth `client_id` is, by the convention the spec itself follows, a public identifier
  — it is embedded in redirect URLs and shipped inside public clients — and treating it as
  inherently secret would be exactly the "too broad" failure mode that gets a check turned
  off: a future venue's struct with a genuinely public `client_id`-shaped field would be
  flagged for something that is not a leak. Schwab's own choice to redact it anyway is not
  evidence the name itself is secret-shaped, only that redacting one field it did not have
  to cost nothing there — and this check does not require the OPPOSITE of what a venue
  chose (Schwab's own `client_id` redaction is still and always a pass, since this check
  only asserts a *lower bound* on what must be hidden, never an upper one).

  No struct across all five venues' actual `lib/` collides with any of the twelve
  `Notice`-derived names either — verified by reading every `defstruct` in all five
  repos before this list was finalised, not assumed.

  ## What this does not catch — stated so nobody over-trusts it

  **The original defect was a raw map, not a struct — this check would not have caught it
  as it actually shipped.** `Feed`/`Socket`, pre-fix, held `Keyword.get(opts, :credentials)`
  directly in state: an opaque value handed in by the caller, never constructed as a
  literal anywhere in the module's own compiled code. A struct-field check locks the fix
  in; it does not, and structurally cannot, reach back to the shape of the bug before the
  fix existed.

  Two static, map-shaped versions of this check were considered and rejected before
  settling on the struct check as the enforceable maximum:

    1. **"A process-behaviour module's compiled code contains a map literal with a
       secret-named key."** This does not reach the actual pre-fix defect at all — the
       offending modules never constructed the credential map as a literal; they only
       forwarded an externally-supplied one straight into state, so there was no map
       literal in `Feed`'s or `Socket`'s own source for this shape to find. It would,
       however, fire constantly on completely unrelated, entirely correct code: every
       venue's `Auth` module builds a transient map or keyword list with a secret-named
       key to hand to an HTTP client or a signer (`dp_exchange_coinbase`'s `Auth.jwt/2`
       builds `%{"sub" => api_key, ...}` and pattern-matches
       `%{api_key: api_key, api_secret: api_secret} = credentials` in its own function
       head, neither ever touching a `GenServer`'s state) — a check that cannot tell "this
       secret is about to be signed and discarded" from "this secret is about to be stored
       for the process's lifetime" is not a defect signal, it is noise with the shape of
       one.
    2. **"A process-behaviour module reads `:credentials` from its start options and
       stores the result without first passing it through a wrapping call."** Closer to
       the real shape, but only detectable by assuming every future fix uses a sibling
       module conventionally named `*.Credentials` with a `wrap/1` function — the exact
       naming convention four independent fixes happened to converge on, not something
       the contract requires. Encoding that assumption into a Core assertion is the same
       mistake `AdapterContract`'s own moduledoc already forbids in the other direction
       ("no assertion may name a socket, a channel string, a transport module or a polling
       interval" — mechanism leaking through the facade is the bug, whether the mechanism
       is a transport name or an implementation's own private helper-module convention).

  Both fail the same test this family already applies to a candidate assertion: would it
  survive contact with real, correct code across all five venues without being disabled.
  Neither does. **The struct-field check is the narrower thing that is enforceable; the
  raw-map shape is not, and pretending otherwise would manufacture coverage this contract
  does not actually have.**

  It also does not catch a struct assembled through `apply/3` or `Kernel.struct/2` at
  runtime from a dynamically computed field list — no static-shaped concern applies here,
  since this check already instantiates the struct at runtime rather than reading its
  source, but a struct whose OWN fields are computed dynamically at the call site
  (`struct(Mod, some_runtime_list)`) still has a fixed, statically-known field set via
  `Mod.__struct__/0`, which is what this check actually reads — so this limitation does
  not apply in practice; it is noted only for completeness.
  """

  @secret_field_names ~w(api_key api_secret app_key app_secret secret password passphrase
                         token access_token refresh_token client_secret private_key
                         signature authorization bearer)a

  # A plain list, not a `MapSet`: see `DpExchange.Core.Notice`'s own `@credential_keys` for
  # why — a `MapSet` literal built from a module attribute fails Dialyzer's PLT check with
  # a `call_without_opaque` mismatch against `MapSet.member?/2`'s own opaque spec. Fifteen
  # entries make a linear scan irrelevant next to that, the same conclusion `Notice` and
  # `LinkSafetyCheck` each already reached independently.

  @type violation :: %{module: module(), field: atom(), file: String.t() | nil}

  @doc """
  Finds every struct under `lib_root` with a secret-named field that leaks under
  `inspect/1`.

  `beam_dir` is a directory of compiled `.beam` files (typically
  `Mix.Project.build_path() |> Path.join("lib/\#{app}/ebin")`), the same one
  `DpExchange.Core.LinkSafetyCheck.run/2` and `DpExchange.Core.UnwiredCheck.run/3` read.
  Only modules whose recorded `:compile_info` source path falls under `lib_root` are
  analysed. Every module considered must already be loaded in the running node — true by
  construction when this runs from inside `AdapterContract`'s generated assertion, since
  that only ever executes after `mix test` has compiled and loaded the package under test.
  """
  @spec run(Path.t(), Path.t()) :: {:ok, [violation()]} | {:error, term()}
  def run(beam_dir, lib_root) do
    lib_root = Path.expand(lib_root)

    with {:ok, modules} <- collect_modules(beam_dir, lib_root) do
      violations =
        modules
        |> Enum.filter(&struct_module?/1)
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
      location = v.file || "unknown source"

      "  #{inspect(v.module)}'s :#{v.field} field prints in cleartext under " <>
        "inspect/1 (#{location})"
    end)
    |> Enum.join("\n")
  end

  defp struct_module?(%{module: module}) do
    Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0)
  end

  defp check_module(%{module: module, source: source}) do
    module
    |> struct_fields()
    |> Enum.filter(&(&1 in @secret_field_names))
    |> Enum.filter(&leaks?(module, &1))
    |> Enum.map(&%{module: module, field: &1, file: source})
  end

  defp struct_fields(module) do
    module.__struct__() |> Map.from_struct() |> Map.keys()
  end

  # A per-field, per-call unique sentinel — not a fixed string, and not the same value
  # reused for every field on the struct — so a match can only mean THIS field's value
  # reached the rendered output, never a coincidental collision with another field's
  # default or another test's fixture running concurrently (`async: true`).
  defp leaks?(module, field) do
    sentinel = "credential_redaction_probe_#{field}_#{System.unique_integer([:positive])}"
    rendered = module |> struct([{field, sentinel}]) |> inspect()
    String.contains?(rendered, sentinel)
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
        with_source(module, compile_info, lib_root)

      {:error, :beam_lib, reason} ->
        {:error, reason}
    end
  end

  defp with_source(module, compile_info, lib_root) do
    case Keyword.get(compile_info, :source) do
      nil ->
        {:ok, nil}

      source ->
        source = source |> to_string() |> Path.expand()

        if String.starts_with?(source, lib_root <> "/") do
          {:ok, %{module: module, source: source}}
        else
          {:ok, nil}
        end
    end
  end
end
