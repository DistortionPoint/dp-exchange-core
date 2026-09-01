defmodule DpExchangeCore.MixProject do
  use Mix.Project

  # SEED, not a release. CI increments the last segment of whatever it finds
  # here, so `0.1.0` first publishes as `0.1.1`. Hand-editing this to `0.2.0`
  # is how a breaking change is signalled (§7.3, D18). The bump script matches
  # the attribute assignment below by its exact literal form — do not reformat
  # it, and do not repeat that form anywhere else in this file, comments
  # included, or the script will rewrite the wrong line.
  @version "0.1.33"
  @source_url "https://github.com/DistortionPoint/dp-exchange-core"

  def project do
    [
      app: :dp_exchange_core,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      preferred_cli_env: preferred_cli_env(),
      test_coverage: test_coverage(),

      # Hex.pm
      name: "DpExchangeCore",
      description:
        "EXPERIMENTAL — Shared contract for the DpExchange family of exchange adapters: " <>
          "behaviours, value types, canonical-pair normalisation and a conformance suite.",
      package: package(),
      source_url: @source_url,
      docs: docs(),

      # UsageRules
      usage_rules: usage_rules()
    ]
  end

  # No `mod:` — a library does not start itself (§7.7). Consumers supervise the
  # facade through `child_spec/1`; a package that opened sockets on load would
  # take restart strategy and shutdown order away from the host (D12).
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Runtime. `websockex` is absent at every strength — not a hard dep and
      # not `optional: true`. Transport is venue-owned (D12, D20); Core has no
      # socket to open, and an optional dep would still advertise transport on
      # the package page.
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 2.0"},
      {:telemetry, "~> 1.0"},

      # Dev/Test. `plug` is here so the request pipeline can be exercised through
      # Req's test seam without a network — it never ships (`only: :test`).
      {:plug, "~> 1.16", only: :test},
      {:usage_rules, "~> 1.2", only: :dev},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp test_coverage do
    [
      threshold: 90,
      ignore_modules: []
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer",
        "sobelow --config"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp preferred_cli_env do
    [
      quality: :test
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["bcatherall"],

      # `files:` belongs HERE, not at the project level. Hex reads `package[:files]`;
      # a `files:` in `project/0` is silently ignored and Hex ships its own defaults
      # instead — which meant `priv/plts/dialyzer.plt` (4.4 MB of build artifact) went
      # into the tarball while the conformance suite and `usage-rules.md` did not.
      # Nothing warns about this. Inspect `mix hex.build` output before every publish.
      #
      # `test/support` deliberately does NOT ship. The conformance suite moved to `lib/`
      # because a dependency is never compiled in the `:test` environment — shipping the
      # file left it uncompiled and unusable in the consumer, which is the whole point of
      # shipping it. What remains in `test/support` is this package's own reference venue,
      # which proves the suite works here and is of no use to a consumer.
      #
      # `config/` is deliberately absent — it governs this package's own dev and test
      # only, never a consumer's.
      #
      # `priv/` is absent because the only thing in it is the dialyzer PLT.
      files: [
        "lib",
        "mix.exs",
        ".formatter.exs",
        "README.md",
        "LICENSE",
        "CHANGELOG.md",
        "AGENTS.md",
        "usage-rules.md",
        "usage-rules",
        "docs/guides"
      ]
    ]
  end

  defp docs do
    [
      # The namespace root is the landing page: it is the first thing a public reader
      # sees, and "this is a bare namespace, look elsewhere" is a poor first page (D1).
      main: "DpExchange",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "usage-rules.md",
        "usage-rules/adapter.md",
        "usage-rules/symbols.md",
        "usage-rules/feeds.md",
        "usage-rules/testing.md",
        "docs/guides/building-an-exchange-package.md"
      ],
      groups_for_extras: [
        "Usage rules": ~r/usage-rules/,
        Guides: ~r/docs\/guides/
      ],
      source_ref: "v#{@version}"
    ]
  end

  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [:usage_rules]
    ]
  end
end
