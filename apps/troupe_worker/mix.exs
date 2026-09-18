defmodule Troupe.Worker.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_worker,
      version: File.read!("../../VERSION") |> String.trim(),
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
      # Test-only, and in this direction only. The end-to-end control-channel test needs
      # a real plane on the other end of the socket, and the worker is the client in
      # that relationship — the plane never links against this app. No `lib` code here
      # calls it, which is what `mix troupe.boundaries` checks.
      {:troupe_plane, in_umbrella: true, only: :test},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"}]
  end
end
