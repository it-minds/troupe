defmodule Mix.Tasks.Compile.Reaper do
  @moduledoc """
  Cross-compiles `native/reaper/reaper.zig` into `priv/reaper/<target>/reaper[.exe]`.

  Builds the host target by default; `TROUPE_REAPER_TARGETS=all` (or a
  comma-separated list of target names) builds more, which the release
  pipeline uses so every wrapped binary carries its own reaper.
  """
  use Mix.Task.Compiler

  @targets %{
    "linux_x86_64" => "x86_64-linux-musl",
    "linux_aarch64" => "aarch64-linux-musl",
    "macos_x86_64" => "x86_64-macos",
    "macos_aarch64" => "aarch64-macos",
    "windows_x86_64" => "x86_64-windows-gnu"
  }

  def targets, do: @targets

  @impl true
  def run(_args) do
    source = Path.join(["native", "reaper", "reaper.zig"])

    names =
      case System.get_env("TROUPE_REAPER_TARGETS") do
        nil -> [host_target()]
        "all" -> Map.keys(@targets)
        list -> String.split(list, ",", trim: true)
      end

    results = Enum.map(names, &build(source, &1))

    if Enum.all?(results, &(&1 == :ok)), do: {:ok, []}, else: {:error, []}
  end

  @impl true
  def clean do
    File.rm_rf!(Path.join("priv", "reaper"))
    :ok
  end

  defp build(source, name) do
    triple = Map.fetch!(@targets, name)
    ext = if String.starts_with?(name, "windows"), do: ".exe", else: ""
    out_dir = Path.join(["priv", "reaper", name])
    out = Path.join(out_dir, "reaper" <> ext)
    File.mkdir_p!(out_dir)

    if stale?(source, out) do
      Mix.shell().info("Compiling reaper for #{name} (#{triple})")

      args = [
        "build-exe",
        source,
        "-target",
        triple,
        "-O",
        "ReleaseSmall",
        "-lc",
        "-fstrip",
        "--name",
        "reaper",
        "-femit-bin=#{out}"
      ]

      case System.cmd("zig", args, stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          Mix.shell().error("zig failed (#{status}) for #{name}:\n#{output}")
          :error
      end
    else
      :ok
    end
  end

  defp stale?(source, out) do
    case {File.stat(source, time: :posix), File.stat(out, time: :posix)} do
      {{:ok, s}, {:ok, o}} -> s.mtime > o.mtime
      _ -> true
    end
  end

  def host_target do
    os =
      case :os.type() do
        {:unix, :darwin} -> "macos"
        {:unix, _} -> "linux"
        {:win32, _} -> "windows"
      end

    arch = to_string(:erlang.system_info(:system_architecture))
    cpu = if arch =~ ~r/aarch64|arm64/, do: "aarch64", else: "x86_64"
    "#{os}_#{cpu}"
  end
end

defmodule Troupe.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :troupe,
      version: @version,
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:reaper] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {Troupe.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.7"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.4"},
      {:file_system, "~> 1.1"},
      {:yaml_elixir, "~> 2.12"},
      {:ex_ratatui, "~> 0.13"},
      {:burrito, "~> 1.6", runtime: false},
      {:stream_data, "~> 1.4", only: [:test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
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
