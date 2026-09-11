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
      extra_applications: [:logger, :crypto],
      mod: {Troupe.Worker.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_core, in_umbrella: true},
      {:troupe_protocol, in_umbrella: true},
      {:troupe_gateway, in_umbrella: true},
      {:req, "~> 0.7"},
      # SigV4 only. The HTTP is Req's, which the rest of Troupe already uses, and an
      # S3 client with its own opinions about retries and streaming would be a second
      # HTTP stack to reason about.
      {:aws_signature, "~> 0.4"},
      # Segments are zstd JSONL, as the spec says. A NIF rather than gzip because a
      # session log is highly repetitive and the ratio is what keeps the object tier
      # affordable.
      {:ezstd, "~> 1.2"},
      {:jason, "~> 1.4"}]
  end
end
