defmodule Troupe.MixProject do
  use Mix.Project

  # The umbrella's version: the TUI, the daemon, the images and the chart are released
  # together from one `VERSION` (Decision 668).
  @version "../../VERSION" |> File.read!() |> String.trim()

  def project do
    [
      app: :troupe,
      version: @version,
      package: [licenses: ["Apache-2.0"]],
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
      {:mint_web_socket, "~> 1.0.6"},
      {:mint, "~> 1.10.1"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_ratatui, "~> 0.13"},
      {:burrito, "~> 1.6", runtime: false},
      {:stream_data, "~> 1.4", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  # The harness: `troupe_core`, `troupe_gateway` and `troupe_protocol`, the same three
  # applications the worker pod and `troupe-daemon` run, from the umbrella this project sits
  # in. A path, so the TUI is always built against the harness of its own commit; there is
  # no pin to move and nothing to fetch. `override: true` because the three also name each
  # other, as siblings, and this is what says the two are the same place.
  defp harness(app) do
    {app, path: "../../apps/#{app}", override: true}
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
            linux_x86_64: [os: :linux, cpu: :x86_64] ++ custom_erts(),
            linux_aarch64: [os: :linux, cpu: :aarch64] ++ custom_erts(),
            macos_x86_64: [os: :darwin, cpu: :x86_64] ++ custom_erts(),
            macos_aarch64: [os: :darwin, cpu: :aarch64] ++ custom_erts(),
            windows_x86_64: [os: :windows, cpu: :x86_64] ++ custom_erts()
          ]
        ]
      ]
    ]
  end

  # An ERTS already on this machine, instead of the one Burrito downloads for the target.
  # `BURRITO_CUSTOM_ERTS` is a directory holding an unpacked OTP tree; CI never sets it
  # and builds exactly as before.
  #
  # It is what makes a build from source possible on Windows, where the precompiled ERTS
  # is an NSIS installer and unpacking one needs 7-Zip — which the GitHub runners have
  # and a laptop, without administrator rights, may not. Whoever sets it is saying this
  # tree is the right ERTS for the target being built, so set it only for the host's own
  # target (`scripts\install-local.ps1` does).
  defp custom_erts do
    case System.get_env("BURRITO_CUSTOM_ERTS") do
      path when is_binary(path) and path != "" -> [custom_erts: path]
      _ -> []
    end
  end
end
