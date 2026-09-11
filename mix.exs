defmodule Troupe.Umbrella.MixProject do
  use Mix.Project

  @version "0.2.0"

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # Umbrella-wide dependencies. Each app declares the ones it actually uses; these
  # are the tools that run across all of them.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:burrito, "~> 1.6", runtime: false}
    ]
  end

  defp aliases do
    [
      check: [
        "compile --force --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "troupe.boundaries",
        "test"
      ]
    ]
  end

  # `troupe` is the client binary: the TUI, the CLI, and the local daemon in one
  # executable. The server-side releases (worker, plane, operator) are plain mix
  # releases built into OCI images and are defined in their own apps.
  defp releases do
    [
      troupe: [
        applications: [
          troupe_core: :permanent,
          troupe_protocol: :permanent,
          troupe_gateway: :permanent,
          troupe_tui: :permanent,
          troupe_ctl: :permanent
        ],
        include_executables_for: [:unix, :windows],
        steps: [
          :assemble,
          &Troupe.Release.build_reapers/1,
          &Troupe.Release.verify_linux_nif/1,
          &Burrito.wrap/1
        ],
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
