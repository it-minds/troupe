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
      extra_applications: [:logger, :crypto, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      # A client attaches to a worker pod over a WebSocket, because a pod is reached
      # through an Ingress. Mint's is the one already underneath `req`, so this adds a
      # framing layer rather than a second HTTP stack.
      {:mint_web_socket, "~> 1.0"},
      # Session tokens are verified by workers offline and minted by the plane, so the
      # JWT shape — and the rules about audience and expiry — belong where both can see
      # them. The plane signs through OpenBao; nothing here holds a private key.
      {:jose, "~> 1.11"},
      # For the key manager and the object store, which are contracts both the plane
      # and the workers hold and therefore have to live where both can see them. See
      # DECISIONS.md.
      {:req, "~> 0.7"},
      # SigV4 only. The HTTP is Req's, which the rest of Troupe already uses, and an S3
      # client with its own opinions about retries and streaming would be a second HTTP
      # stack to reason about.
      {:aws_signature, "~> 0.4"},
      # Segments are zstd JSONL, as the spec says. A NIF rather than gzip because a
      # session log is highly repetitive and the ratio is what keeps the object tier
      # affordable.
      {:ezstd, "~> 1.2"},
      # Agent definitions and skills carry YAML frontmatter, and a bundle is checked by
      # the plane before it is published as well as by the worker that applies it, so
      # the parser sits where both can reach it.
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
