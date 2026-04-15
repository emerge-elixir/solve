defmodule Solve.MixProject do
  use Mix.Project

  @description "Declarative UI agnostic state management architecture"
  @version "0.2.0"
  @source_url "https://github.com/emerge-elixir/solve"

  def project do
    [
      app: :solve,
      version: @version,
      elixir: "~> 1.18",
      name: "Solve",
      start_permanent: Mix.env() == :prod,
      description: @description,
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      dialyzer: [plt_add_apps: [:mix]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: preferred_cli_env()
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "dialyzer"
      ],
      "quality.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict"
      ]
    ]
  end

  defp preferred_cli_env do
    [
      credo: :test,
      dialyzer: :dev,
      quality: :test,
      "quality.fast": :test
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["Damirados"],
      links: %{
        "GitHub" => @source_url,
        "Issues" => @source_url <> "/issues"
      },
      files: [
        "lib",
        "CHANGELOG.md",
        "README.md",
        "ARCHITECTURE.md",
        "LICENSE",
        "mix.exs",
        "mix.lock"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "CHANGELOG.md",
        "README.md",
        "ARCHITECTURE.md"
      ],
      groups_for_extras: [
        Release: ["CHANGELOG.md"],
        Internals: ["ARCHITECTURE.md"]
      ],
      groups_for_modules: [
        {"Core", [Solve]},
        {"Controllers", [Solve.Controller, Solve.ControllerSpec, Solve.Collection]},
        {"Messaging", [Solve.Lookup, Solve.Dispatch, Solve.Message, Solve.Update]},
        {"Internals", [Solve.DependencyGraph]}
      ],
      nest_modules_by_prefix: [Solve]
    ]
  end
end
