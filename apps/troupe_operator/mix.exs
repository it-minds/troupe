defmodule Troupe.Operator.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_operator,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Kubernetes operator (stage 2)",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Troupe.Operator.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      # Bonny over the k8s client. Spiked on Elixir 1.20 / OTP 28 first, as the spec
      # asks: both compile and run there, so the fallback of hand-written
      # watch-and-reconcile GenServers was not needed. See DECISIONS.md.
      {:bonny, "~> 1.5"},
      {:k8s, "~> 2.8"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"}]
  end
end
