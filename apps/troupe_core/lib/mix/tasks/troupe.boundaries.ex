defmodule Mix.Tasks.Troupe.Boundaries do
  @moduledoc """
  Cross-reference check: does any app reach into one it is not allowed to know about?

  The umbrella's architecture is a claim about coupling — the TUI is a protocol client
  with no private access, the plane does not run agents, the operator is not the plane.
  Claims like that decay the first time someone reaches for a convenient module, and
  they decay silently, because Elixir will happily compile a call into a sibling app
  whose beams are sitting in the same `_build`.

  So this reads the compiled beams and asks what each app *actually* calls, not what
  its `mix.exs` says it depends on. The two are checked separately and both have to
  hold: a declared dependency that nothing uses is dead weight, and an undeclared call
  is the coupling that mix.exs was supposed to prevent.

      mix troupe.boundaries

  Exits non-zero on the first violation, with the calling module and the module it
  called, so CI fails on the coupling rather than on its consequences months later.
  """

  use Mix.Task

  @shortdoc "Check that no umbrella app reaches into one it must not know about"

  @requirements ["compile"]

  # Written the way the spec states them, so the two can be compared by eye.
  @rules [
    {:troupe_tui, :only, [:troupe_protocol],
     "the TUI is a protocol client and gets no private access"},
    {:troupe_ctl, :only, [:troupe_protocol],
     "the CLI is a protocol client and gets no private access"},
    {:troupe_a2a, :only, [:troupe_protocol],
     "the A2A facade is a protocol client and gets no private access"},
    {:troupe_plane, :never, [:troupe_core, :troupe_gateway], "the plane does not run agents"},
    {:troupe_operator, :never, [:troupe_core, :troupe_gateway, :troupe_plane],
     "the operator holds cluster privileges and has no public surface"}
  ]

  # A rule about *modules* rather than apps: every module under the first prefix may call
  # only the listed modules among those under the second.
  #
  # The app-level rules say what an app may know about; this says what a part of an app
  # may. The panel is inside the plane and could reach anything in it, and the whole
  # arrangement of `Plane.Admin` rests on it not doing so: a LiveView that called `Fleet`
  # directly would be a private path into the plane that no other client has.
  @module_rules [
    {"Elixir.Troupe.Plane.Web.Live.", [Troupe.Plane.Admin], "Elixir.Troupe.Plane.",
     "a LiveView is an admin API client and gets no private access"}
  ]

  @impl Mix.Task
  def run(_args) do
    apps = umbrella_apps()
    owners = module_owners(apps)

    violations =
      Enum.flat_map(@rules, fn rule -> check(rule, apps, owners) end) ++
        Enum.flat_map(@module_rules, &check_modules(&1, apps)) ++
        undeclared(apps, owners)

    report(violations)
  end

  # Read the same way as the app rules: from the compiled beams, because what a module
  # declares it uses and what it calls are different questions and only the second one
  # matters.
  defp check_modules({prefix, allowed, scope, why}, apps) do
    allowed = MapSet.new(allowed)

    apps
    |> Enum.flat_map(&beams/1)
    |> Enum.flat_map(&module_calls(&1, prefix, scope))
    |> Enum.reject(fn {_from, to} -> MapSet.member?(allowed, to) end)
    |> Enum.map(fn {from, to} ->
      %{app: module_app(from), other: to, from: from, to: to, why: why}
    end)
    |> Enum.uniq()
  end

  # Reported as the app the calling module is in, so a violation reads like every other
  # one rather than like a different kind of thing.
  defp module_app(module),
    do: module |> Atom.to_string() |> String.split(".") |> Enum.take(3) |> Enum.join(".")

  defp module_calls(beam, prefix, scope) do
    with {:ok, {module, [imports: imports]}} <- :beam_lib.chunks(beam, [:imports]),
         true <- String.starts_with?(Atom.to_string(module), prefix) do
      imports
      |> Enum.map(fn {called, _fun, _arity} -> called end)
      |> Enum.uniq()
      |> Enum.filter(&in_scope?(&1, prefix, scope))
      |> Enum.map(&{module, &1})
    else
      _ -> []
    end
  end

  # Within the scope but not within the prefix itself: a LiveView calling another
  # LiveView is the panel talking to itself, which is not the coupling this is about.
  defp in_scope?(called, prefix, scope) do
    name = Atom.to_string(called)
    String.starts_with?(name, scope) and not String.starts_with?(name, prefix)
  end

  defp check({app, kind, others, why}, apps, owners) do
    if app in apps do
      forbidden = forbidden_set(kind, others, apps, app)

      app
      |> calls_out(owners)
      |> Enum.filter(fn {_from, _to, callee_app} -> callee_app in forbidden end)
      |> Enum.map(fn {from, to, callee_app} ->
        %{app: app, other: callee_app, from: from, to: to, why: why}
      end)
    else
      []
    end
  end

  defp forbidden_set(:only, allowed, apps, app), do: apps -- [app | allowed]
  defp forbidden_set(:never, denied, _apps, _app), do: denied

  # An app that calls a sibling it never declared is coupled to something nothing in
  # its build configuration knows about — which is how a release ends up missing an
  # application at boot rather than at compile time.
  defp undeclared(apps, owners) do
    Enum.flat_map(apps, fn app ->
      declared = declared_deps(app)

      app
      |> calls_out(owners)
      |> Enum.reject(fn {_from, _to, callee_app} -> callee_app in declared end)
      |> Enum.map(fn {from, to, callee_app} ->
        %{app: app, other: callee_app, from: from, to: to, why: "not declared in mix.exs"}
      end)
    end)
  end

  # Every remote call an app's beams make into another umbrella app, deduplicated to
  # one example per (caller module, callee module) pair — a list of every call site
  # would bury the one fact that matters.
  defp calls_out(app, owners) do
    app
    |> beams()
    |> Enum.flat_map(&beam_calls(&1, app, owners))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp beam_calls(beam, app, owners) do
    case :beam_lib.chunks(beam, [:imports]) do
      {:ok, {module, [imports: imports]}} ->
        imports
        |> Enum.map(fn {called, _fun, _arity} -> called end)
        |> Enum.uniq()
        |> Enum.flat_map(&crossing(&1, module, app, owners))

      _ ->
        []
    end
  end

  defp crossing(called, module, app, owners) do
    case Map.get(owners, called) do
      nil -> []
      ^app -> []
      other -> [{module, called, other}]
    end
  end

  defp report([]) do
    Mix.shell().info(
      "boundaries ok: #{length(@rules)} app rule(s), #{length(@module_rules)} module rule(s), no violations"
    )
  end

  defp report(violations) do
    for %{app: app, other: other, from: from, to: to, why: why} <- violations do
      Mix.shell().error(
        "#{app} must not depend on #{other} (#{why})\n" <>
          "    #{inspect(from)} calls #{inspect(to)}"
      )
    end

    Mix.raise("#{length(violations)} boundary violation(s)")
  end

  defp umbrella_apps do
    Mix.Project.apps_paths()
    |> Map.keys()
    |> Enum.sort()
  end

  # module -> owning app, from each app's generated `.app` file, which is the only
  # place that mapping is authoritative.
  defp module_owners(apps) do
    for app <- apps,
        {:ok, [{:application, ^app, keys}]} <- [consult_app_file(app)],
        module <- Keyword.get(keys, :modules, []),
        into: %{} do
      {module, app}
    end
  end

  defp consult_app_file(app) do
    path = Path.join([Mix.Project.build_path(), "lib", to_string(app), "ebin", "#{app}.app"])
    if File.exists?(path), do: :file.consult(String.to_charlist(path)), else: :error
  end

  defp beams(app) do
    [Mix.Project.build_path(), "lib", to_string(app), "ebin", "*.beam"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&String.to_charlist/1)
  end

  defp declared_deps(app) do
    path = Path.join(Map.fetch!(Mix.Project.apps_paths(), app), "mix.exs")

    case File.read(path) do
      {:ok, source} ->
        ~r/\{:(troupe_\w+),\s*in_umbrella:\s*true\}/
        |> Regex.scan(source)
        |> Enum.map(fn [_, name] -> String.to_atom(name) end)

      _ ->
        []
    end
  end
end
