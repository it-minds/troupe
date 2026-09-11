defmodule Troupe.Protocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_protocol,
      version: "0.2.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Wire format: JSON-RPC messages, events, schemas, and a client",
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      # Session tokens are verified by workers offline and minted by the plane, so the
      # JWT shape — and the rules about audience and expiry — belong where both can see
      # them. The plane signs through OpenBao; nothing here holds a private key.
      {:jose, "~> 1.11"},
      # For the key manager, which is a contract both the plane and the workers hold
      # and therefore has to live where both can see it. See DECISIONS.md.
      {:req, "~> 0.7"}]
  end
end
