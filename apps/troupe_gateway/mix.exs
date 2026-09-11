defmodule Troupe.Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_gateway,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "The daemon: transports, connections, subscriptions, scopes",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Troupe.Gateway.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_core, in_umbrella: true},
      {:troupe_protocol, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:stream_data, "~> 1.4", only: [:dev, :test]}]
  end
end
