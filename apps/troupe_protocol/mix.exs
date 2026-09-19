defmodule Troupe.Protocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_protocol,
      version: version(),
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

  # `VERSION` at the umbrella root, or `TROUPE_VERSION` when this app is a dependency of
  # another project — a sparse git checkout of `apps/troupe_protocol` has no root — and
  # never a plausible default: a consumer that pins this app says which version it is.
  defp version do
    case File.read("../../VERSION") do
      {:ok, contents} -> String.trim(contents)
      {:error, _} -> System.get_env("TROUPE_VERSION") || raise "TROUPE_VERSION is not set and ../../VERSION is not here"
    end
  end

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
      # affordable. The it-minds fork of ezstd 1.2.4 adds the Windows build (a `win32`
      # rebar hook that compiles the NIF with Zig); upstream has hooks for Linux and
      # macOS only, and the daemon is released for Windows too. See DECISIONS.md 643.
      {:ezstd, git: "https://github.com/it-minds/ezstd.git", ref: "e3c9239fc1ead0fab110e82a9c3cf4ffb5add88d"},
      # Agent definitions and skills carry YAML frontmatter, and a bundle is checked by
      # the plane before it is published as well as by the worker that applies it, so
      # the parser sits where both can reach it.
      {:yaml_elixir, "~> 2.12"}
    ]
  end
end
