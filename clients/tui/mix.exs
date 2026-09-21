defmodule Troupe.MixProject do
  use Mix.Project

  @version "0.1.0"

  # The harness: `troupe_core`, `troupe_gateway` and `troupe_protocol` from `troupe-remote`,
  # at one commit, as sparse git dependencies — the same three applications the worker pod
  # and `troupe-daemon` run. One ref for all three. Each reads `TROUPE_VERSION` for the
  # version it has no `VERSION` file for (a sparse checkout has no repository root), so it
  # is set here, before Mix evaluates them. `TROUPE_HARNESS_GIT` points a local build at a
  # checkout on disk.
  @harness_git System.get_env("TROUPE_HARNESS_GIT", "https://github.com/it-minds/troupe-remote.git")
  @harness_ref System.get_env("TROUPE_HARNESS_REF", "c39e2317ab9282b97213a7eb8dde156f7531d1b2")
  @harness_version "0.2.0"

  System.put_env("TROUPE_VERSION", @harness_version)

  def project do
    [
      app: :troupe,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def cli do
    [preferred_envs: [check: :test]]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Troupe.TUI.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      harness(:troupe_protocol),
      harness(:troupe_core),
      harness(:troupe_gateway),
      {:req, "~> 0.7"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_ratatui, "~> 0.13"},
      {:burrito, "~> 1.6", runtime: false},
      {:stream_data, "~> 1.4", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # `override: true` because the apps declare each other as ordinary dependencies when
  # they are not siblings in an umbrella, and this project is what says where they are.
  defp harness(app) do
    {app, git: @harness_git, sparse: "apps/#{app}", ref: @harness_ref, override: true}
  end

  defp aliases do
    [
      check: [
        "compile --force --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "troupe.xref",
        "test"
      ]
    ]
  end

  def releases do
    [
      troupe: [
        include_executables_for: [:unix],
        steps: [:assemble, &ExRatatui.Burrito.verify_linux_nif/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
