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
      deps: deps()
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
end
