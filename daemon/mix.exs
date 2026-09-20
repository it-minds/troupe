defmodule Troupe.Daemon.MixProject do
  use Mix.Project

  # The daemon's own version — what `troupe-daemon version` prints and what the release
  # asset is named after. Separate from the harness version it is built from, which is the
  # `troupe-remote` commit pinned below and reported by `Troupe.Version.version/0`.
  @version "VERSION" |> File.read!() |> String.trim()

  # The harness: `troupe_core`, `troupe_gateway` and `troupe_protocol` from `troupe-remote`,
  # at one commit, as sparse git dependencies. One ref for all three, because they are one
  # thing that happens to be three OTP applications; pinning them separately is how a daemon
  # ends up with a gateway one commit ahead of its core.
  #
  # Each of those apps reads `TROUPE_VERSION` for the version it has no `VERSION` file for
  # (a sparse checkout has no repository root), so it is set here, before Mix evaluates them.
  # `TROUPE_HARNESS_GIT` points a local build at a checkout on disk instead of GitHub.
  @harness_git System.get_env("TROUPE_HARNESS_GIT", "https://github.com/it-minds/troupe-remote.git")
  @harness_ref System.get_env("TROUPE_HARNESS_REF", "3ad89e2a01b28b2a1f9afcaf6357e5bf47db99d1")
  @harness_version "0.2.0"

  System.put_env("TROUPE_VERSION", @harness_version)

  def project do
    [
      app: :troupe_daemon,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Troupe.Daemon.Application, []}
    ]
  end

  # `override: true` because the apps declare each other as ordinary dependencies when
  # they are not siblings in an umbrella, and this project is what says where they are.
  defp deps do
    [
      harness(:troupe_protocol),
      harness(:troupe_core),
      harness(:troupe_gateway),
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp harness(app) do
    {app, git: @harness_git, sparse: "apps/#{app}", ref: @harness_ref, override: true}
  end

  defp aliases do
    [
      check: [
        "compile --force --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "test"
      ]
    ]
  end

  # A plain Mix release with the build host's ERTS, one per platform, as a tarball — not a
  # Burrito binary. Burrito's launcher runs Elixir's command line over the arguments and
  # halts the VM when it is done with them, which is what a command-line tool wants and
  # exactly what a daemon must not have (daemon/DECISIONS.md 1). A release's `start` is the
  # entry point a daemon wants, and `eval` and `remote` come with it.
  #
  # Two steps between `:assemble` and `:tar`: the reaper for the build host's triple goes
  # into `troupe_core`'s `priv/`, and the `troupe-daemon` wrapper — the user-facing command
  # line — goes into `bin/`.
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
        steps: [:assemble, &Troupe.Daemon.Release.reaper/1, &Troupe.Daemon.Release.wrapper/1, :tar]
      ]
    ]
  end
end
