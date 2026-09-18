defmodule Troupe.A2A.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_a2a,
      version: File.read!("../../VERSION") |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "The A2A facade: a profile as an agent other agents can call",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Troupe.A2A.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The whole of what the facade may know about Troupe. It is a client of the plane
      # and of worker pods, over the same public APIs the TUI uses, and `mix
      # troupe.boundaries` holds it to this one app.
      {:troupe_protocol, in_umbrella: true},
      # Its own HTTP face: an agent card, one JSON-RPC route per profile, and a
      # server-sent event stream. Bandit, because the rest of the umbrella already
      # serves HTTP with it and a second server would be a second thing to reason about.
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.12"},
      # The plane is reached over HTTP. Req is what `troupe_protocol` already carries
      # for the object store, and the plane's own clients use it for `/rpc`.
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"}
    ]
  end
end
