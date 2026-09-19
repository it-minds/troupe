defmodule Troupe.Umbrella.MixProject do
  use Mix.Project

  # One string, in a file both `mix.exs` and the compiler can read. `mix.exs` runs before
  # any application is compiled, so it cannot call `Troupe.Release.version/0` — and seven
  # copies with a convention is how a chart at 0.2.0 comes to deploy images built from
  # 0.3.0 with nothing saying so.
  @version "VERSION" |> File.read!() |> String.trim()

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
  # `troupe.e2e` is here for the same reason and was not, which is why the cluster job had
  # never run green: the task carries `@preferred_cli_env :test`, and Elixir stopped reading
  # that attribute — the project's `cli/0` is the only thing that decides now. So the task
  # ran in `dev`, called `mix test`, and Mix refused with "mix test is running in the dev
  # environment" rather than anything about a cluster.
  #
  # It stayed hidden because this job only runs after the test job passes, and the test job
  # had been red for a fortnight over two flakes.
  def cli, do: [preferred_envs: [check: :test, "troupe.e2e": :test]]

  # Umbrella-wide dependencies. Each app declares the ones it actually uses; these
  # are the tools that run across all of them.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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

  # Four releases from one umbrella, and every one of them is a container image.
  #
  # This repository is the remote: it is deployed to Kubernetes by `charts/troupe` and
  # it is not installed on anybody's machine. So there is no packaged executable here,
  # no target matrix, and nothing cross-built — each release is a plain Mix release
  # that runs where an Erlang runtime is the container's business rather than the
  # user's. Clients live in their own repositories and reach a plane over the protocol.
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
      ]
    ]
  end
end
