defmodule DpExchange.PackagingTest do
  use ExUnit.Case, async: true

  # What ships is not what the repo contains, and nothing warns when the two disagree.
  # These assert the tarball's contents directly, because the way this went wrong was
  # silent: `files:` at the project level is ignored by Hex, so the package shipped a
  # 4.4 MB dialyzer PLT and shipped neither the conformance suite nor usage-rules.md —
  # while `mix.exs` carried a comment saying it did.

  defp package_files do
    Mix.Project.config()
    |> Keyword.fetch!(:package)
    |> Keyword.fetch!(:files)
  end

  describe "files: is declared where Hex actually reads it" do
    test "the package declares its own file list" do
      # A `files:` in project/0 is silently ignored. This asserts the one Hex reads.
      assert is_list(package_files())
    end

    test "the project level does not also declare one, which would mislead a reader" do
      refute Keyword.has_key?(Mix.Project.config(), :files)
    end
  end

  describe "what must ship" do
    test "the conformance suite ships AS A COMPILED MODULE, not as a file" do
      # It lived in `test/support/` first. The file shipped and was never compiled,
      # because a dependency is not built in the `:test` environment — so a venue
      # package's `use DpExchange.Core.AdapterContract` failed with "module not loaded".
      # Shipping a file is not shipping a module.
      assert "lib" in package_files()
      assert File.exists?("lib/dp_exchange/core/adapter_contract.ex")
      refute "test/support" in package_files()
    end

    test "usage rules ship — they are how the contract reaches a consumer's agent" do
      files = package_files()

      assert "usage-rules.md" in files
      assert "usage-rules" in files

      for guide <- ~w(adapter symbols feeds testing) do
        assert File.exists?("usage-rules/#{guide}.md")
      end
    end

    test "the venue-package guide ships" do
      assert "docs/guides" in package_files()
      assert File.exists?("docs/guides/building-an-exchange-package.md")
    end
  end

  describe "what must NOT ship" do
    test "priv is not listed — the only thing in it is a 4.4 MB build artifact" do
      refute "priv" in package_files()
      refute Enum.any?(package_files(), &String.starts_with?(&1, "priv"))
    end

    test "config/ is not listed — it governs this package's dev and test, never a consumer's" do
      refute Enum.any?(package_files(), &String.starts_with?(&1, "config"))
    end

    test "nothing that could carry a secret is listed" do
      for entry <- package_files() do
        refute entry =~ ~r/\.env|\.mcp/, "#{entry} could carry a credential into a public tarball"
      end
    end
  end
end
