defmodule Troupe.Plane.MixProject do
  use Mix.Project

  def project do
    [
      app: :troupe_plane,
      version: File.read!("../../VERSION") |> String.trim(),
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: "Control plane: identity, placement, budgets, admin (stage 2)",
      package: [licenses: ["Apache-2.0"]],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Troupe.Plane.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:troupe_protocol, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      # The admin panel. LiveView rather than a JSON front end because every page here is
      # a view of live cluster state — pods coming and going, a drain in progress — and
      # polling it from a browser would be a second event system beside the one the plane
      # already has.
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      # What `Phoenix.LiveViewTest` parses rendered pages with.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:bandit, "~> 1.12"},
      # The plane's HTTP surface is a handful of routes, so it is `Plug.Router` rather
      # than Phoenix. Stage 3's admin panel is what brings Phoenix in.
      {:plug, "~> 1.16"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      # Replicas find each other through the Kubernetes API; Erlang distribution
      # between them is confined to plane pods by NetworkPolicy.
      {:libcluster, "~> 3.5"},
      {:oidcc, "~> 3.9"},
      # For TokenReview at enrolment, and for writing the two custom resources the
      # plane is allowed to write. Its RBAC is those two resources and its own
      # endpoints; it cannot read a TroupePolicy, let alone write one.
      {:k8s, "~> 2.8"},
      # JWTs are signed by OpenBao's transit engine, but the header and payload are
      # assembled here and clients verify against the published JWKS.
      {:jose, "~> 1.11"},
      # GitOps mode commits the same manifest the direct mode applies, and a manifest in
      # a repository is YAML because that is what Flux reads.
      {:ymlr, "~> 5.1"},
      # And reads back what it committed, to tell whether a profile following the
      # release already carries the release's image.
      {:yaml_elixir, "~> 2.12"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"}]
  end
end
