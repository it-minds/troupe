defmodule Troupe.Ctl.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_ctl,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "The command line. Speaks only the protocol.",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Troupe.Ctl.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      # `troupe admin bundle publish <dir>` reads `mcp.yaml`; the parser is the one the
      # protocol already carries for agent definitions.
      {:yaml_elixir, "~> 2.12"},
      # Test only, and deliberately so: to test a client you need a server. It is
      # never a dependency outside the test environment, and `mix troupe.boundaries` reads the compiled
      # beams rather than this file, so it would still catch a call from `lib/`.
      {:troupe_gateway, in_umbrella: true, only: :test},
      {:jason, "~> 1.4"}
    ]
  end
end
