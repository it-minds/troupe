defmodule Troupe.Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_worker,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Remote worker runtime (stage 2)",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_core, in_umbrella: true},
      {:troupe_protocol, in_umbrella: true}]
  end
end
