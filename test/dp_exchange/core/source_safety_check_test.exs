defmodule DpExchange.Core.SourceSafetyCheckTest do
  @moduledoc """
  `DpExchange.Core.SourceSafetyCheck` against real source files written under this run's own
  fixture root (the package's `tmp/`, never the system temp directory): one tree that does
  every forbidden thing once, a tree that mentions all of them and does none, and the ways a
  scan can fail to examine anything.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Core.{SourceSafetyCheck, UnwiredFixture}

  # Every line below is a finding except the module and its `end`; the numbers are asserted.
  @broken """
  defmodule Broken do
    def a(text), do: String.to_atom(text)
    def b(text), do: :"book_\#{text}"
    def c(chars), do: List.to_atom(chars)
    def d(text), do: :erlang.binary_to_atom(text, :utf8)
    def e(chars), do: :erlang.list_to_atom(chars)
    def f(frame), do: Module.concat(Foo, frame["channel"])
    def g(text), do: text |> String.to_atom()
    def h, do: Enum.map(["a"], &String.to_atom/1)
    def i(bin), do: :erlang.binary_to_term(bin)
    def j(bin), do: :erlang.binary_to_term(bin, [])
    def k, do: Application.compile_env(:app, :key)
    def l, do: Application.compile_env!(:app, :key)
    def m, do: System.get_env("HOME")
    def n, do: System.fetch_env!("HOME")
  end
  """

  # Mentions every forbidden call in prose, in a comment and in a string, and makes none.
  @clean """
  defmodule Clean do
    @moduledoc \"\"\"
    Never String.to_atom/1, Application.compile_env/3 or System.get_env/1.
    \"\"\"

    # String.to_atom(text) and :erlang.binary_to_term(bin) are not code here.
    def fixed, do: String.to_atom("fixed")
    def existing(text), do: String.to_existing_atom(text)
    def sub, do: Module.concat(__MODULE__, Sub)
    def listed, do: Module.concat([Foo, Bar])
    def derived(name, default), do: Module.concat(name, default |> Module.split() |> List.last())
    def safe(bin), do: :erlang.binary_to_term(bin, [:safe])
    def runtime, do: Application.get_env(:app, :key)
    def quoted_literal, do: :"fixed_atom"
    def text, do: "System.get_env and compile_env"
  end
  """

  @config_clean "import Config\n"
  @config_env ~S"""
  import Config
  config :app, key: System.get_env("KEY") || "dev"
  """

  # Writes `files` (relative path => source) under a root of its own and answers
  # `{lib_root, config_dir}`.
  defp tree!(files) do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(UnwiredFixture.run_root(), "source_safety_#{unique}")
    File.mkdir_p!(Path.join(root, "lib"))

    Enum.each(files, fn {path, source} ->
      full = Path.join(root, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, source)
    end)

    {Path.join(root, "lib"), Path.join(root, "config")}
  end

  defp lines_and_kinds(findings), do: Enum.map(findings, &{&1.line, &1.kind})

  describe "what it finds" do
    test "each way of making an atom from text, reading compile_env or the environment" do
      {lib, config} = tree!(%{"lib/broken.ex" => @broken})

      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)

      assert lines_and_kinds(findings) == [
               {2, :atom_from_text},
               {3, :atom_from_text},
               {4, :atom_from_text},
               {5, :atom_from_text},
               {6, :atom_from_text},
               {7, :atom_from_text},
               {8, :atom_from_text},
               {9, :atom_from_text},
               {10, :unsafe_binary_to_term},
               {11, :unsafe_binary_to_term},
               {12, :compile_env},
               {13, :compile_env},
               {14, :env_read},
               {15, :env_read}
             ]

      assert Enum.all?(findings, &String.ends_with?(&1.file, "lib/broken.ex"))
    end

    test "a finding names the call, so a reader need not open the file to know what it was" do
      {lib, config} = tree!(%{"lib/broken.ex" => @broken})
      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)

      assert Enum.map(findings, & &1.call) == [
               "String.to_atom",
               ":erlang.binary_to_atom",
               "List.to_atom",
               ":erlang.binary_to_atom",
               ":erlang.list_to_atom",
               "Module.concat",
               "String.to_atom",
               "String.to_atom",
               ":erlang.binary_to_term",
               ":erlang.binary_to_term",
               "Application.compile_env",
               "Application.compile_env!",
               "System.get_env",
               "System.fetch_env!"
             ]
    end

    test "a package that mentions every one in prose and makes none is clean" do
      {lib, config} =
        tree!(%{
          "lib/clean.ex" => @clean,
          "config/config.exs" => @config_clean,
          "config/runtime.exs" => @config_env
        })

      assert SourceSafetyCheck.run(lib, config) == {:ok, []}
    end

    test "findings are ordered by file and then line, whichever order the files were read in" do
      later = "defmodule B do\n  def b(t), do: String.to_atom(t)\nend\n"
      earlier = "defmodule A do\n  def pad, do: :ok\n  def a(t), do: String.to_atom(t)\nend\n"
      {lib, config} = tree!(%{"lib/b.ex" => later, "lib/a.ex" => earlier})

      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)
      assert Enum.map(findings, &{Path.basename(&1.file), &1.line}) == [{"a.ex", 3}, {"b.ex", 2}]
    end

    test "Module.concat over a call that makes text is flagged, over a module name is not" do
      source = """
      defmodule Concats do
        def a(x), do: Module.concat(Foo, String.capitalize(x))
        def b(x), do: Module.concat(Foo, to_string(x))
        def c(x), do: Module.concat(Foo, Enum.join(x, "."))
        def d(x), do: Module.concat(Foo, Atom.to_string(x))
        def e(x), do: Module.concat(Foo, inspect(x))
        def ok(name, default), do: Module.concat(name, default |> Module.split() |> List.last())
        def fixed(name), do: Module.concat(name, "Feed")
      end
      """

      {lib, config} = tree!(%{"lib/concats.ex" => source})

      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)
      assert lines_and_kinds(findings) == for(line <- 2..6, do: {line, :atom_from_text})
    end

    test "code inside a macro's quote is code, and is read" do
      source = """
      defmodule Macros do
        defmacro build(text) do
          quote do
            String.to_atom(unquote(text))
          end
        end
      end
      """

      {lib, config} = tree!(%{"lib/macros.ex" => source})

      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)
      assert lines_and_kinds(findings) == [{4, :atom_from_text}]
    end
  end

  describe "the environment" do
    test "is read nowhere but config/runtime.exs" do
      {lib, config} =
        tree!(%{
          "lib/clean.ex" => @clean,
          "config/config.exs" => @config_clean,
          "config/runtime.exs" => @config_env,
          "config/test.exs" => @config_env,
          "config/prod.exs" => "import Config\nconfig :app, key: System.fetch_env!(\"KEY\")\n"
        })

      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)

      assert Enum.map(findings, &{Path.basename(&1.file), &1.line, &1.kind}) == [
               {"prod.exs", 2, :env_read},
               {"test.exs", 2, :env_read}
             ]
    end

    test "static config is not otherwise judged: only the environment is its concern" do
      source = "import Config\nconfig :app, key: String.to_atom(\"a\" <> \"b\")\n"
      {lib, config} = tree!(%{"lib/clean.ex" => @clean, "config/dev.exs" => source})

      assert SourceSafetyCheck.run(lib, config) == {:ok, []}
    end

    test "a package with no config directory has none to scan" do
      {lib, config} = tree!(%{"lib/clean.ex" => @clean})

      refute File.dir?(config)
      assert SourceSafetyCheck.run(lib, config) == {:ok, []}
    end
  end

  describe "it refuses to examine nothing, or to skip what it cannot read" do
    test "a lib root with no .ex file is an error, not a clean package" do
      {lib, config} = tree!(%{"lib/notes.txt" => "no source here"})

      assert SourceSafetyCheck.run(lib, config) == {:error, {:no_files_scanned, lib}}
    end

    test "a lib root that does not exist is the same error" do
      {lib, config} = tree!(%{})
      missing = Path.join(Path.dirname(lib), "nowhere")

      assert SourceSafetyCheck.run(missing, config) == {:error, {:no_files_scanned, missing}}
    end

    test "a file that does not parse is an error naming it" do
      {lib, config} = tree!(%{"lib/clean.ex" => @clean, "lib/bad.ex" => "defmodule Bad do def ("})

      assert SourceSafetyCheck.run(lib, config) ==
               {:error, {:unparseable, Path.join(lib, "bad.ex")}}
    end

    test "a config file that does not parse is an error naming it" do
      {lib, config} = tree!(%{"lib/clean.ex" => @clean, "config/test.exs" => "config :app, ("})

      assert SourceSafetyCheck.run(lib, config) ==
               {:error, {:unparseable, Path.join(config, "test.exs")}}
    end

    test "a path that cannot be read as a file is an error naming it" do
      {lib, config} = tree!(%{"lib/ok.ex" => @clean})
      directory = Path.join(lib, "dir.ex")
      File.mkdir_p!(directory)

      assert SourceSafetyCheck.run(lib, config) == {:error, {:unreadable, directory, :eisdir}}
    end
  end

  describe "format/1" do
    test "one line per finding: file, line, why, and the call" do
      {lib, config} = tree!(%{"lib/broken.ex" => @broken})
      assert {:ok, findings} = SourceSafetyCheck.run(lib, config)

      lines = findings |> SourceSafetyCheck.format() |> String.split("\n")

      assert length(lines) == length(findings)
      assert Enum.at(lines, 0) =~ "broken.ex:2"
      assert Enum.at(lines, 0) =~ "atom table"
      assert Enum.at(lines, 0) =~ "String.to_atom"
      assert Enum.at(lines, 8) =~ "[:safe]"
      assert Enum.at(lines, 10) =~ "Application.get_env/3"
      assert Enum.at(lines, 12) =~ "config/runtime.exs"
    end

    test "no findings render as nothing" do
      assert SourceSafetyCheck.format([]) == ""
    end
  end
end
