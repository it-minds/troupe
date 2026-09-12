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

  # `check` runs the test suite, so the whole of it belongs in the test environment —
  # otherwise `compile --warnings-as-errors` checks a different set of files than the
  # one the tests then run against.
  def cli, do: [preferred_envs: [check: :test]]

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

  # Five releases from one umbrella.
  #
  # `troupe` is the client binary — the TUI, the CLI, and the local daemon in one
  # executable, wrapped by Burrito so it needs nothing installed alongside it. The
  # other four are plain Mix releases built into OCI images: they run in a cluster
  # where an Erlang runtime is the container's business, not the user's.
  defp releases do
    [
      troupe_operator: [
        applications: [troupe_protocol: :permanent, troupe_operator: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      troupe_plane: [
        applications: [troupe_protocol: :permanent, troupe_plane: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      troupe_a2a: [
        applications: [troupe_protocol: :permanent, troupe_a2a: :permanent],
        include_executables_for: [:unix],
        steps: [:assemble, :tar]
      ],
      troupe_worker: [
        applications: [
          troupe_core: :permanent,
          troupe_protocol: :permanent,
          troupe_gateway: :permanent,
          troupe_worker: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, &Troupe.Release.build_reapers/1, :tar]
      ],
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
