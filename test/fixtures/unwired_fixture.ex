defmodule DpExchange.Core.UnwiredFixture do
  @moduledoc """
  Compiles small Elixir source fragments to `.beam` files on disk, so
  `DpExchange.Core.UnwiredCheckTest` can exercise the real `:beam_lib`/`:xref` path
  instead of asserting against the analysis functions' internals.

  Every fixture writes into its own directory under this package's own `tmp/` (never
  the system temp directory — see this repo's `CLAUDE.md`), named from
  `System.unique_integer/1` so concurrent `async: true` tests never share a directory
  or a module name.
  """

  @root Path.join([File.cwd!(), "tmp", "unwired_check_test"])

  @type source :: %{required(:code) => String.t(), required(:path) => String.t()}

  @doc """
  Compiles each `%{code: source, path: "relative/lib/path.ex"}` entry and writes the
  resulting `.beam` file into a fresh directory.

  `path` never has to exist on disk — it only has to be the string
  `DpExchange.Core.UnwiredCheck` compares against a `lib_root`, so a fixture can place a
  module "outside `lib/`" (to prove such a module's calls do not count as wiring)
  without ever writing a file there.

  Returns `{beam_dir, lib_root}`.
  """
  @spec compile!([source()]) :: {Path.t(), Path.t()}
  def compile!(sources) do
    # `mix test` compiles ad-hoc/dynamic code (including this) with `debug_info: false`
    # by default, for speed — `:xref.add_module/2`, which `UnwiredCheck` calls, refuses
    # a beam compiled without it. This is a one-way flip (never reset to `false`), so
    # concurrent `async: true` fixtures racing here cannot undo each other's setting.
    Code.put_compiler_option(:debug_info, true)

    unique = System.unique_integer([:positive, :monotonic])
    lib_root = Path.join(@root, "lib_#{unique}")
    beam_dir = Path.join(@root, "beam_#{unique}")
    File.mkdir_p!(beam_dir)

    Enum.each(sources, fn %{code: code, path: path} ->
      full_source_path = Path.join(lib_root, path)

      code
      |> Code.compile_string(full_source_path)
      |> Enum.each(fn {module, binary} ->
        beam_path = Path.join(beam_dir, Atom.to_string(module) <> ".beam")
        File.write!(beam_path, binary)
      end)
    end)

    {beam_dir, lib_root}
  end
end
