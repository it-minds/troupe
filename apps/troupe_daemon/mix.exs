defmodule Troupe.Daemon.MixProject do
  use Mix.Project

  # The daemon is the harness — `troupe_core`, `troupe_gateway` and `troupe_protocol` — and
  # a command line, released on its own as `troupe-daemon` (the `troupe_daemon` release in
  # the root `mix.exs`). It used to be a project in another repository that pinned those
  # three apps by git ref; as their sibling it is built from the same commit by
  # construction, and its version is the umbrella's (Decision 667).
  def project do
    [
      app: :troupe_daemon,
      version: File.read!("../../VERSION") |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: "The local daemon: the harness on a laptop, under the TUI and the GUI",
      package: [licenses: ["Apache-2.0"]],
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Troupe.Daemon.Application, []}
    ]
  end

  # The whole of what the daemon may know about, and `mix troupe.boundaries` holds it to
  # these three: nothing of the plane, the worker, the operator or the A2A facade reaches a
  # laptop.
  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      {:troupe_core, in_umbrella: true},
      {:troupe_gateway, in_umbrella: true}
    ]
  end

  # The laptop harness, released from this directory (`MIX_ENV=prod mix release`): built
  # here, it compiles the three harness apps and nothing else of the umbrella, which on a
  # Windows or macOS runner is the difference between building the harness and building
  # the plane's Postgres and Kubernetes clients for a machine that will never run them.
  #
  # A plain Mix release with the build host's ERTS, one per platform, as a tarball — not a
  # Burrito binary, because a daemon must not have Burrito's launcher halting the VM when
  # the arguments are handled (DECISIONS.md here, 1). Three steps between `:assemble` and
  # `:tar`: the reaper for the build host's triple into `troupe_core`'s `priv/`, the
  # `troupe-daemon` wrapper into `bin/`, and LICENSE, NOTICE and THIRD-PARTY-NOTICES.txt
  # into the root, which the archive must carry. Its runtime configuration is its own
  # (`config/runtime.exs` here): the platform's reads a pod's environment, and a laptop
  # has none of it.
  defp releases do
    [
      troupe_daemon: [
        applications: [
          troupe_protocol: :permanent,
          troupe_core: :permanent,
          troupe_gateway: :permanent,
          troupe_daemon: :permanent
        ],
        include_executables_for: [:unix, :windows],
        runtime_config_path: "config/runtime.exs",
        steps: [
          :assemble,
          &Troupe.Daemon.Release.reaper/1,
          &Troupe.Daemon.Release.wrapper/1,
          &Troupe.Release.licences/1,
          :tar
        ]
      ]
    ]
  end
end
