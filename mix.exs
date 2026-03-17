defmodule Solve.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/emerge-elixir/solve"

  def project do
    [
      app: :solve,
      version: @version,
      elixir: "~> 1.18",
      name: "Solve",
      start_permanent: Mix.env() == :prod,
      description: description(),
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end

  defp description do
    "Declarative UI agnostic state management architecture"
  end

  defp docs do
    [
      main: "Solve",
      source_ref: "main",
      extras: [
        "ARCHITECTURE.md",
        "AUTOMATIC_EVENT_TARGETING.md",
        "CONTROLLERS_ATTRIBUTE_FEATURE.md"
      ],
      groups_for_modules: [
        {"Core", [Solve]},
        {"Controllers", [Solve.Controller, Solve.ControllerAssign]},
        {"Phoenix integration", [Solve.LiveView, Solve.LiveComponent]},
        {"Internals", [Solve.DependencyGraph]}
      ],
      nest_modules_by_prefix: [Solve]
    ]
  end
end
