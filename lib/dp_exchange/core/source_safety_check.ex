defmodule DpExchange.Core.SourceSafetyCheck do
  @moduledoc """
  Finds, in a package's own source, the four ways a venue's text or a consumer's environment
  reaches somewhere it must not: an atom built from text, an unsafe `binary_to_term`, a
  `compile_env` read, and an environment read outside `config/runtime.exs`.

  ## The defects this exists for

  **An atom made from venue or caller text is an atom-table leak.** Atoms are never garbage
  collected and the table is finite (about a million by default), so a feed that does
  `String.to_atom(frame["channel"])` for every channel name a venue sends, or
  `:"\#{symbol}_book"` for every symbol a caller subscribes, walks the table toward a node-wide
  crash that no log line announces. The remedy is a closed lookup (a `case` over the values the
  venue documents, with a refusal for the rest) or `String.to_existing_atom/1` with the
  `ArgumentError` turned into a refusal. This is why `Core.Notice` tests credential keys as
  strings and `Core.FakeInjection` keeps one static key, and it is the shape of lens S of the
  tick AQ audit: `String.to_atom/1`, `List.to_atom/1`, `:erlang.binary_to_atom/1,2`,
  `:erlang.list_to_atom/1`, and an interpolated atom (`:"foo_\#{x}"`, which compiles to
  `:erlang.binary_to_atom/2`) are all flagged. An argument that is a literal
  (`String.to_atom("ok")`) builds one fixed atom and is not. `Module.concat/1,2` composes module
  names (a tree's `<name>.Feed`), so it is flagged only where an argument is visibly built from
  text: an interpolation, a `<>`, a `term["key"]` read, a `Map.get`/`Map.fetch`, or a call that
  makes text (`String.*`, `to_string/1`, `inspect/1`, `Enum.join/2`, `Atom.to_string/1`).

  **`:erlang.binary_to_term/1` on bytes the package did not write leaks atoms, and can build
  funs.** `:erlang.binary_to_term(bin, [:safe])` refuses both, and is the only spelling
  accepted.

  **`Application.compile_env/3` in a library freezes the consumer's configuration at the moment
  the dependency was compiled.** A consumer who changes its config later is silently running on
  the old value until it recompiles the dependency, and in a release the value is baked into
  the artifact. Anything a consumer is meant to configure is read at call time with
  `Application.get_env/3` (through `DpExchange.Core.Config`, so an `async: true` test can vary
  it). `compile_env!/2` is the same read and is flagged too.

  **Only `config/runtime.exs` may read the environment.** `config.exs`, `dev.exs`, `test.exs`
  and `prod.exs` are static, and a library's own code asks `Application.get_env/3` and nothing
  else: `System.get_env/0,1,2`, `System.fetch_env/1` and `System.fetch_env!/1` are flagged in
  every other file this check reads.

  ## How it reads

  The source, not the beam: `Application.compile_env/3` is gone by the time a module is
  compiled (its value is substituted and the call is not in the abstract code), and the AST
  keeps the call's arguments, so a literal can be told from a variable. Every `.ex` file under
  `lib_root` and every `.exs` file in `config_dir` other than `runtime.exs` is parsed with
  `Code.string_to_quoted/2` and walked, so a mention in a comment, a docstring or a string is
  never a finding.

  ## What it does not catch

  A call assembled at runtime (`apply(String, :to_atom, [text])`, or a module held in a
  variable) and any code a macro generates from data. Dynamic dispatch is beyond a static
  tool, the limit `Core.UnwiredCheck` states for the same reason. A capture
  (`&String.to_atom/1`) or the right side of a pipe is flagged where it is written, since the
  text it will be applied to is not visible there.

  ## It refuses to scan nothing

  A `lib_root` with no `.ex` file is `{:error, {:no_files_scanned, lib_root}}`, not
  `{:ok, []}`: one mistyped `package_root:` would otherwise read as a clean package. A file it
  cannot read or parse is an error naming it, never a skip.
  """

  @typedoc "What a finding is."
  @type kind ::
          :atom_from_text
          | :unsafe_binary_to_term
          | :compile_env
          | :env_read

  @type violation :: %{
          file: String.t(),
          line: pos_integer() | nil,
          kind: kind(),
          call: String.t()
        }

  @env_functions [:get_env, :fetch_env, :fetch_env!]

  @doc """
  Scans `lib_root` (every `.ex` file under it) and `config_dir` (every `.exs` file directly in
  it except `runtime.exs`; a missing directory has none) and answers the findings.

  `{:ok, []}` is a clean package. `{:error, {:no_files_scanned, lib_root}}` when `lib_root`
  holds no `.ex` file, `{:error, {:unreadable, file, reason}}` and `{:error, {:unparseable,
  file}}` for a file it cannot read or parse.
  """
  @spec run(Path.t(), Path.t()) :: {:ok, [violation()]} | {:error, term()}
  def run(lib_root, config_dir) do
    lib_root = Path.expand(lib_root)

    with {:ok, lib_files} <- lib_files(lib_root),
         {:ok, lib_findings} <- scan(lib_files, :lib),
         {:ok, config_findings} <- scan(config_files(config_dir), :config) do
      {:ok, Enum.sort_by(lib_findings ++ config_findings, &{&1.file, &1.line})}
    end
  end

  @doc "Renders `run/2` violations as one line per finding, for a failure message."
  @spec format([violation()]) :: String.t()
  def format(violations) do
    Enum.map_join(violations, "\n", fn violation ->
      "  #{violation.file}:#{violation.line} — #{explain(violation.kind)} (#{violation.call})"
    end)
  end

  defp explain(:atom_from_text) do
    "an atom built from text; the atom table is never collected. Use a closed lookup, or " <>
      "String.to_existing_atom/1 with the ArgumentError turned into a refusal"
  end

  defp explain(:unsafe_binary_to_term) do
    "binary_to_term without [:safe] builds atoms and funs from bytes it was handed"
  end

  defp explain(:compile_env) do
    "compile_env freezes the consumer's configuration at dependency-compile time; read it " <>
      "at call time with Application.get_env/3"
  end

  defp explain(:env_read), do: "only config/runtime.exs may read the environment"

  # --- files ---------------------------------------------------------------

  defp lib_files(lib_root) do
    case lib_root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort() do
      [] -> {:error, {:no_files_scanned, lib_root}}
      files -> {:ok, files}
    end
  end

  defp config_files(config_dir) do
    config_dir
    |> Path.expand()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == "runtime.exs"))
    |> Enum.sort()
  end

  defp scan(files, scope) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case scan_file(file, scope) do
        {:ok, findings} -> {:cont, {:ok, findings ++ acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp scan_file(file, scope) do
    with {:ok, source} <- read(file),
         {:ok, ast} <- parse(source, file) do
      {_ast, findings} = Macro.prewalk(ast, [], &collect(&1, &2, file, scope))
      {:ok, findings}
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:unreadable, file, reason}}
    end
  end

  defp parse(source, file) do
    case Code.string_to_quoted(source, file: file) do
      {:ok, ast} -> {:ok, ast}
      {:error, _syntax} -> {:error, {:unparseable, file}}
    end
  end

  defp collect({{:., _dot_meta, [target, function]}, meta, args} = node, acc, file, scope)
       when is_atom(function) and is_list(args) do
    case classify(scope, target_of(target), function, args) do
      nil -> {node, acc}
      {kind, call} -> {node, [finding(file, meta, kind, call) | acc]}
    end
  end

  defp collect(node, acc, _file, _scope), do: {node, acc}

  defp finding(file, meta, kind, call),
    do: %{file: file, line: Keyword.get(meta, :line), kind: kind, call: call}

  defp target_of({:__aliases__, _meta, parts}), do: parts
  defp target_of(atom) when is_atom(atom), do: atom
  defp target_of(_other), do: nil

  # --- rules ---------------------------------------------------------------

  # The environment is read nowhere but `config/runtime.exs`, which is never scanned.
  defp classify(_scope, [:System], function, _args) when function in @env_functions,
    do: {:env_read, "System.#{function}"}

  defp classify(:config, _target, _function, _args), do: nil

  defp classify(:lib, [:Application], function, _args)
       when function in [:compile_env, :compile_env!],
       do: {:compile_env, "Application.#{function}"}

  defp classify(:lib, [:String], :to_atom, args), do: atom_rule(args, "String.to_atom")
  defp classify(:lib, [:List], :to_atom, args), do: atom_rule(args, "List.to_atom")
  defp classify(:lib, [:Module], :concat, args), do: concat_rule(args)

  # An interpolated atom, `:"a_\#{x}"`, is `:erlang.binary_to_atom(<<...>>, :utf8)` in the AST.
  defp classify(:lib, :erlang, function, args) when function in [:binary_to_atom, :list_to_atom],
    do: atom_rule(args, ":erlang.#{function}")

  defp classify(:lib, :erlang, :binary_to_term, args), do: term_rule(args)
  defp classify(_scope, _target, _function, _args), do: nil

  # A call with no arguments is a capture or the right side of a pipe: the text it is applied to
  # is not visible here, so it is never a literal.
  defp atom_rule(args, call) do
    if args != [] and Enum.all?(args, &literal?/1), do: nil, else: {:atom_from_text, call}
  end

  # **`Module.concat/1,2` composes module names, so a variable is not text.** Every venue's
  # supervisor derives `<tree name>.Feed` from the consumer's own tree-name atom and a fixed
  # suffix (tick AO): one atom per tree the consumer starts, never one per frame. Flagging every
  # non-literal argument failed all five venues on that derivation. What is flagged is an
  # argument visibly built from text: an interpolation, a `<>`, a `term["key"]` read, or a
  # `Map.get`/`Map.fetch`. A bare capture or pipe target is still flagged (nothing is visible).
  defp concat_rule([]), do: {:atom_from_text, "Module.concat"}

  defp concat_rule(args) do
    if Enum.any?(args, &textual?/1), do: {:atom_from_text, "Module.concat"}, else: nil
  end

  defp textual?({:<<>>, _meta, parts}), do: not Enum.all?(parts, &is_binary/1)
  defp textual?({:<>, _meta, _operands}), do: true
  defp textual?({{:., _meta, [Access, :get]}, _call, _args}), do: true

  defp textual?({{:., _meta, [{:__aliases__, _alias, [:Map]}, function]}, _call, _args})
       when function in [:get, :fetch, :fetch!],
       do: true

  # A call that produces or reshapes text: `String.*`, `Atom.to_string/1`, `Enum.join/1,2`,
  # `to_string/1` and `inspect/1,2`. `Module.concat(Foo, String.capitalize(channel))` is a module
  # (so an atom) per distinct frame, exactly as `Module.concat(Foo, "x" <> channel)` is.
  defp textual?({{:., _meta, [{:__aliases__, _alias, [:String]}, _function]}, _call, _args}),
    do: true

  defp textual?({{:., _meta, [{:__aliases__, _alias, [:Atom]}, :to_string]}, _call, _args}),
    do: true

  defp textual?({{:., _meta, [{:__aliases__, _alias, [:Enum]}, :join]}, _call, _args}), do: true

  defp textual?({function, _meta, args})
       when function in [:to_string, :inspect] and is_list(args),
       do: true

  defp textual?(list) when is_list(list), do: Enum.any?(list, &textual?/1)
  defp textual?(_ast), do: false

  defp term_rule([_bytes, options]) when is_list(options) do
    if :safe in options, do: nil, else: {:unsafe_binary_to_term, ":erlang.binary_to_term"}
  end

  defp term_rule(_args), do: {:unsafe_binary_to_term, ":erlang.binary_to_term"}

  # What builds one fixed value no input can change.
  defp literal?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp literal?({:__aliases__, _meta, parts}), do: Enum.all?(parts, &is_atom/1)
  defp literal?({:__MODULE__, _meta, context}) when is_atom(context), do: true
  defp literal?({:<<>>, _meta, parts}), do: Enum.all?(parts, &is_binary/1)
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?(_ast), do: false
end
