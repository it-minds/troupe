defmodule Troupe.Gateway.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_gateway,
      version: version(),
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

  # `VERSION` at the umbrella root, or `TROUPE_VERSION` when this app is a dependency of
  # another project — a sparse git checkout of `apps/troupe_gateway` has no root — and
  # never a plausible default: a consumer that pins this app says which version it is.
  defp version do
    case File.read("../../VERSION") do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> System.get_env("TROUPE_VERSION") || raise "TROUPE_VERSION is not set and ../../VERSION is not here"
    end
  end

  # A sibling app inside the umbrella, and an ordinary dependency the consuming project
  # supplies (`override: true`, from the same git ref) outside it.
  defp harness(app) do
    if File.dir?("../#{app}") and File.exists?("../../mix.exs"),
      do: {app, in_umbrella: true},
      else: {app, ">= 0.0.0"}
  end

  defp deps do
    [
      harness(:troupe_core),
      harness(:troupe_protocol),
      {:jason, "~> 1.4"},
      # The daemon calls a plane when a person has linked one. The same client the rest
      # of Troupe uses, rather than a second HTTP stack for four methods.
      {:req, "~> 0.7"},
      {:telemetry, "~> 1.3"},
      # The remote transport. A worker pod is reached through an Ingress, so its clients
      # arrive over HTTP and stay over a WebSocket; the same JSON-RPC either way.
      {:bandit, "~> 1.12"},
      {:plug, "~> 1.20"},
      {:websock_adapter, "~> 0.6"},
      {:stream_data, "~> 1.4", only: [:dev, :test]}]
  end
end
