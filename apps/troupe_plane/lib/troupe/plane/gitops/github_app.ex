defmodule Troupe.Plane.Gitops.GitHubApp do
  @moduledoc """
  The plane's GitHub App, as a `GitHubApp` resource a repository holds, in GitOps mode
  (#653): its App ID, its API URL, the installations it may use, and each team's GitHub
  repositories and caps. Never its private key or its webhook secret: those are only ever in
  OpenBao's transit engine, put there through the console or `admin.github.put`, and a
  repository holds neither.

  ## One resource, named `github`

  A plane has one App, so the pass reads one resource of the kind, `github` in the plane's
  namespace; another is refused, saying so.

  | the plane's | the resource's |
  | --- | --- |
  | the App's `app_id` | `spec.appId` |
  | its `api_url` | `spec.apiUrl`, GitHub's own where absent |
  | its `installations` | `spec.installations`, each `{owner, installationId}` |
  | a team's `github` | `spec.teams.<team>`: `repositories`, `maxPushes`, `maxRuns`, `maxAttempts` |

  The resource is the whole of it: a field it leaves out is that field's default, and a team
  it does not name lists no repository. A team it names that the plane does not have is
  reported, and its entry is used at the first pass after the team is enabled.

  ## The checks

  What `admin.github.put` and `admin.team.update` check, asked without writing anything: an
  App ID GitHub would show, an API URL that is GitHub's, an Enterprise Cloud's or an
  Enterprise Server's, one installation per owner, repositories as `owner/name` or
  `owner/*`, caps from 1 to 1000. A key of the spec the kind does not have is refused too. A
  resource that fails is not used: the App stays as the last version that passed.

  ## While it is in the repository

  The console shows the App's settings and every team's GitHub tab locked, with where they
  come from, and `admin.github.put` refuses `app_id`, `api_url` and `installations` and
  `admin.team.update` refuses `github`, as `managed_by_gitops`. The key and the webhook
  secret are still sent through either, since no repository holds them.

  ## Gone

  A resource the App followed that is gone from the cluster takes the App's settings and
  every team's repositories with it, as a removed trigger takes its row; the key and the
  secret stay in transit for the App the repository names next. An App set through the admin
  API before the plane read the cluster is reported `missing` and goes on working until a
  manifest says what it is (`admin.profiles.export` has one).
  """

  @behaviour Troupe.Plane.Gitops

  alias Troupe.Plane.{Audit, GitHub, Gitops, Identity, Provision, Repo}
  alias Troupe.Plane.GitHub.{App, Policy}
  alias Troupe.Plane.Identity.Team

  require Logger

  @kind "GitHubApp"
  @name "github"
  @actor "system:gitops"

  @spec_keys ~w(appId apiUrl installations teams)

  # A team's entry, spelt as a resource spells it, and the team's `github` key each is.
  @team_keys [
    {"repositories", "repositories"},
    {"maxPushes", "max_pushes"},
    {"maxRuns", "max_runs"},
    {"maxAttempts", "max_attempts"}
  ]

  @impl Gitops
  def kind, do: @kind

  @impl Gitops
  def api_version, do: "troupe.dev/v1alpha1"

  @doc "The one resource of the kind the pass reads: `github`."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The spec's keys."
  @spec spec_keys() :: [String.t()]
  def spec_keys, do: @spec_keys

  # The App's row, where it has settings or once followed a resource. A row that holds only
  # a key has nothing a repository would hold.
  @impl Gitops
  def rows do
    case GitHub.app() do
      %App{app_id: id, resource_generation: generation} = row
      when not is_nil(id) or not is_nil(generation) ->
        %{@name => row}

      _none ->
        %{}
    end
  end

  @impl Gitops
  def context, do: %{teams: Map.new(Identity.list_teams(), &{&1.name, &1})}

  # -- reading one --------------------------------------------------------------

  @impl Gitops
  def read(resource, context) do
    name = get_in(resource, ["metadata", "name"])
    spec = resource["spec"] || %{}

    if name == @name do
      {installations, not_installations} = installations(spec["installations"])
      {settings, not_settings} = settings(spec, installations)
      {teams, not_teams} = teams(spec["teams"])
      reasons = unknown(spec) ++ not_installations ++ not_settings ++ not_teams

      if reasons == [] do
        {:ok,
         %{
           settings: settings,
           teams: teams,
           unknown_teams: Enum.reject(Map.keys(teams), &Map.has_key?(context.teams, &1)),
           generation: get_in(resource, ["metadata", "generation"])
         }}
      else
        {:error, reasons}
      end
    else
      {:error,
       [
         "a plane has one GitHub App, which it reads from the GitHubApp named #{@name}, and " <>
           "this one is named #{inspect(name)}: rename it, or remove it"
       ]}
    end
  end

  defp unknown(spec) do
    case Map.keys(spec) -- @spec_keys do
      [] ->
        []

      extra ->
        [
          "#{Enum.map_join(extra, ", ", &("spec." <> &1))} " <>
            "#{if length(extra) == 1, do: "is not a field", else: "are not fields"} of a " <>
            "GitHubApp, which has #{Enum.join(@spec_keys, ", ")}: its key and its webhook " <>
            "secret are never in a resource, and go to OpenBao with admin.github.put"
        ]
    end
  end

  defp installations(nil), do: {[], []}

  defp installations(list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn
      {%{} = entry, index}, {read, reasons} ->
        case Map.keys(entry) -- ["owner", "installationId"] do
          [] ->
            {[%{"owner" => entry["owner"], "installation_id" => entry["installationId"]} | read],
             reasons}

          [key | _] ->
            {read,
             reasons ++
               ["spec.installations[#{index}] takes owner and installationId, not #{key}"]}
        end

      {_other, index}, {read, reasons} ->
        {read, reasons ++ ["spec.installations[#{index}] is {owner, installationId}"]}
    end)
    |> then(fn {read, reasons} -> {Enum.reverse(read), reasons} end)
  end

  defp installations(_other),
    do: {[], ["spec.installations is a list of {owner, installationId}"]}

  defp settings(spec, installations) do
    given = %{
      "app_id" => spec["appId"],
      "api_url" => spec["apiUrl"],
      "installations" => installations
    }

    case GitHub.read_settings(given) do
      {:ok, changes} -> {changes, []}
      {:error, %{field: field, reason: reason}} -> {%{}, ["#{spelled(field)}: #{reason}"]}
    end
  end

  defp spelled("app_id"), do: "spec.appId"
  defp spelled("api_url"), do: "spec.apiUrl"
  defp spelled("installations"), do: "spec.installations"
  defp spelled(field), do: "spec.#{field}"

  defp teams(nil), do: {%{}, []}

  defp teams(%{} = teams) do
    Enum.reduce(teams, {%{}, []}, fn {team, entry}, {read, reasons} ->
      case team_entry(entry) do
        {:ok, github} ->
          {Map.put(read, team, github), reasons}

        {:error, reason} ->
          {read, reasons ++ ["spec.teams.#{team}: #{reason}"]}
      end
    end)
  end

  defp teams(_other),
    do: {%{}, ["spec.teams is a map of a team's name to {repositories, maxPushes, ...}"]}

  defp team_entry(%{} = entry) do
    known = Map.new(@team_keys)

    case Map.keys(entry) -- Map.keys(known) do
      [] ->
        sent = Map.new(entry, fn {key, value} -> {known[key], value} end)

        case Policy.read_team(nil, sent) do
          {:ok, github} -> {:ok, github}
          {:error, %{reason: reason}} -> {:error, reason}
        end

      [key | _] ->
        {:error,
         "a team's entry takes #{Enum.map_join(@team_keys, ", ", &elem(&1, 0))}, not #{key}"}
    end
  end

  defp team_entry(_other), do: {:error, "a team's entry is {repositories, maxPushes, ...}"}

  # -- writing one --------------------------------------------------------------

  @impl Gitops
  def take(_name, attrs, row, _resource) do
    {:ok, %{before: before, now: now}} = GitHub.follow(attrs.settings, attrs.generation, @actor)
    app_changes = Audit.diff(app_fields(before), app_fields(now))

    if app_changes != %{},
      do: {:ok, _} = Audit.record(@actor, "github.put", "app", app_changes)

    team_changes = follow_teams(attrs.teams)

    state =
      cond do
        is_nil(row) or is_nil(row.resource_generation) -> :created
        app_changes == %{} and team_changes == 0 -> :unchanged
        true -> :changed
      end

    if state != :unchanged do
      Logger.info(
        "troupe plane: gitops: the GitHub App #{if state == :created, do: "read from", else: "changed in"} " <>
          "the cluster, generation #{attrs.generation}"
      )
    end

    {state, unknown_teams(attrs.unknown_teams)}
  end

  # Every team's `github` is what the resource says of it, and none for a team it does not
  # name. Answers how many teams changed.
  defp follow_teams(teams) do
    Identity.list_teams()
    |> Enum.map(fn team -> follow_team(team, Map.get(teams, team.name)) end)
    |> Enum.count(& &1)
  end

  defp follow_team(%Team{github: same}, same), do: false
  defp follow_team(%Team{github: nil}, empty) when empty == %{}, do: false

  defp follow_team(%Team{} = team, github) do
    # Read again: an update on a stale struct whose `github` already holds the value writes
    # nothing, and this one may be a pass behind.
    fresh = Repo.get(Team, team.id)
    {:ok, updated} = Identity.update_team(fresh, %{github: github})

    {:ok, _} =
      Audit.record(
        @actor,
        "team.update",
        team.name,
        Audit.diff(%{github: fresh.github}, %{github: updated.github})
      )

    true
  end

  defp unknown_teams([]), do: nil

  defp unknown_teams(names) do
    {"unknown_teams",
     [
       "spec.teams names #{Enum.join(Enum.sort(names), ", ")}, which this plane does not " <>
         "have: what it lists for #{if length(names) == 1, do: "it", else: "them"} is used " <>
         "once the team is enabled (admin.team.enable)"
     ]}
  end

  # -- the App with no resource -------------------------------------------------

  @impl Gitops
  def gone(%App{resource_generation: nil}) do
    {:missing,
     [
       "the cluster has no GitHubApp #{@name}, and the plane had its App before it read the " <>
         "cluster, so the App goes on as it is: commit its manifest (admin.profiles.export " <>
         "has it), or remove the App with admin.github.delete"
     ]}
  end

  def gone(%App{}) do
    {:ok, %{before: before, now: now}} = GitHub.unfollow(@actor)

    {:ok, _} =
      Audit.record(@actor, "github.put", "app", Audit.diff(app_fields(before), app_fields(now)))

    follow_teams(%{})

    Logger.warning(
      "troupe plane: gitops: the GitHubApp #{@name} is gone from the cluster, and the App's " <>
        "settings and the teams' repositories with it; its key and webhook secret stay in OpenBao"
    )

    :removed
  end

  defp app_fields(app), do: Map.take(app, [:app_id, :api_url, :installations])

  # -- bootstrapping a repository -----------------------------------------------

  @doc """
  The App as a repository would hold it, for `admin.profiles.export`: its settings and
  every team's repositories and caps, and never its key or its webhook secret. Nothing
  where the plane has no App.
  """
  @spec export() :: [map()]
  def export do
    case GitHub.app() do
      %App{app_id: id} = app when not is_nil(id) ->
        notes = [
          "The App's private key and webhook secret are not in this file and never are:",
          "they stay in OpenBao, set with admin.github.put or on the console."
        ]

        [
          %{
            name: @name,
            path: "github/#{@name}.yaml",
            notes: notes,
            yaml: Gitops.yaml(manifest(app), notes)
          }
        ]

      _none ->
        []
    end
  end

  @doc "The App and the teams' GitHub settings as a `GitHubApp` resource."
  @spec manifest(App.t()) :: map()
  def manifest(%App{} = app) do
    spelled = Map.new(@team_keys, fn {key, field} -> {field, key} end)

    teams =
      for team <- Identity.list_teams(),
          is_map(team.github) and team.github != %{},
          into: %{},
          do: {team.name, Map.new(team.github, fn {k, v} -> {Map.get(spelled, k, k), v} end)}

    spec =
      %{
        "appId" => app.app_id,
        "apiUrl" => app.api_url,
        "installations" =>
          Enum.map(
            app.installations || [],
            &%{"owner" => &1["owner"], "installationId" => &1["installation_id"]}
          ),
        "teams" => teams
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
      |> Map.new()

    %{
      "apiVersion" => api_version(),
      "kind" => @kind,
      "metadata" => %{"name" => @name, "namespace" => Provision.namespace()},
      "spec" => spec
    }
  end
end
