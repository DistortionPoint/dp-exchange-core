defmodule DpExchange.Core.UnwiredFixture do
  @moduledoc """
  Compiles small Elixir source fragments to `.beam` files on disk, so
  `DpExchange.Core.UnwiredCheckTest` can exercise the real `:beam_lib`/`:xref` path
  instead of asserting against the analysis functions' internals.

  Every fixture writes into its own directory under this package's own `tmp/` (never
  the system temp directory — see this repo's `CLAUDE.md`), named from
  `System.unique_integer/1` so concurrent `async: true` tests never share a directory
  or a module name.

  ## The root is per-RUN, not just per-test

  `System.unique_integer/1` is unique within one VM and restarts near 1 in the next, so two
  `mix test` runs of this package at once generate the identical `beam_2`, `beam_3`, … names.
  `test_helper.exs` then makes that fatal rather than merely confusing: it wipes this root
  before `ExUnit.start/0`, so a second run's start-up deletes the directories a first run's
  tests are still writing into. Observed as

      ** (File.Error) could not write to file ".../tmp/unwired_check_test/beam_2/
         Elixir.Outsider1.beam": no such file or directory

  across `UnwiredCheckTest`, `LinkSafetyCheckTest` and `CredentialRedactionCheckTest` — every
  test that compiles a fixture — and only ever when two runs overlapped, which is why it read
  as an intermittent rather than as the deterministic collision it is.

  `run_root/0` puts the OS pid in the path, so two runs cannot collide however their unique
  integers line up, and `test_helper.exs` wipes only the root belonging to its own run. Both
  call this one function: the wipe and the writes agreeing on the path is the whole point, and
  a second copy of the expression is how they would stop agreeing.
  """

  @type source :: %{required(:code) => String.t(), required(:path) => String.t()}

  @doc """
  This run's own fixture root, under the package's `tmp/`.

  A function rather than a module attribute on purpose: an attribute is evaluated when this
  file is COMPILED, which would bake in the compiling VM's pid and hand every later run the
  same directory — the exact collision this exists to remove.
  """
  @spec run_root() :: Path.t()
  def run_root, do: Path.join([File.cwd!(), "tmp", "unwired_check_test", "run_#{System.pid()}"])

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
    lib_root = Path.join(run_root(), "lib_#{unique}")
    beam_dir = Path.join(run_root(), "beam_#{unique}")
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
