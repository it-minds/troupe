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
      mod: {Troupe.Ctl.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      {:jason, "~> 1.4"}]
  end
end
