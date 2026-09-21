defmodule Troupe.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_core,
      version: File.read!("../../VERSION") |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      # `:reaper` runs after `:elixir` because the compiler task itself lives in lib/.
      compilers: Mix.compilers() ++ [:reaper],
      start_permanent: Mix.env() == :prod,
      description: "Session actor trees: agents, tools, providers, and the log",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Troupe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:file_system, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"},
      {:stream_data, "~> 1.4", only: [:dev, :test]}
    ]
  end
end
