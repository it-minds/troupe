defmodule Troupe.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_core,
      version: version(),
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
      mod: {Troupe.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `VERSION` at the umbrella root, or `TROUPE_VERSION` when this app is a dependency of
  # another project — a sparse git checkout of `apps/troupe_core` has no root — and never
  # a plausible default: a consumer that pins this app says which version it is.
  defp version do
    case File.read("../../VERSION") do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> System.get_env("TROUPE_VERSION") || raise "TROUPE_VERSION is not set and ../../VERSION is not here"
    end
  end

  # A sibling app inside the umbrella, and an ordinary dependency the consuming project
  # supplies (`override: true`, from the same git ref) outside it. The daemon binary is
  # built from these three apps in another repository, and this is the one place that
  # has to know.
  defp harness(app) do
    if File.dir?("../#{app}") and File.exists?("../../mix.exs"),
      do: {app, in_umbrella: true},
      else: {app, ">= 0.0.0"}
  end

  defp deps do
    [
      harness(:troupe_protocol),
      {:req, "~> 0.7.4"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"},
      {:file_system, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"},
      {:stream_data, "~> 1.4", only: [:dev, :test]}]
  end
end
