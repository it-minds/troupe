defmodule Troupe.Plane.Gitops.Triggers do
  @moduledoc """
  `Trigger` resources, read into the rows the scheduler fires and `trigger.fire` finds
  (Decision 737).

  ## One resource per trigger, named `<team>.<trigger>`

  A trigger's name is unique within its team and a resource's within its namespace, and
  every resource lives in the plane's namespace, as the profiles do. So the team is the
  first part of the resource's name and the trigger's name the rest:
  `platform.nightly-digest` is `nightly-digest` of the team `platform`. A dot is in
  neither a team's name nor a trigger's, so the split is never ambiguous, and a team said
  once has no second place to disagree with.

  What a row takes from its resource:

  | row | resource |
  | --- | --- |
  | `team`, `name` | `metadata.name`, split at its dot |
  | `principal_id` | `spec.principal`: the subject of a service principal of that team |
  | `profile`, `agent` | `spec.profile`, `spec.agent` |
  | `enabled` | `spec.enabled`, `true` where absent |
  | `source` | `spec.source` as it is: `{kind: schedule, cron, tz}`, `{kind: webhook, provider}` or `{kind: manual}` |
  | `prompt_template` | `spec.promptTemplate` |
  | `terms` | `spec.terms`, whose keys are `budgetMicros`, `maxTurns`, `wallClockSeconds` and `approvals` |
  | `visibility`, `review`, `notify`, `concurrency` | the same names |
  | `notify_url` | `spec.notifyUrl` |

  A field the resource leaves out is that field's default, not what the row said before:
  the resource is the whole trigger.

  ## The checks

  A resource is used only when an administrator could have saved it with
  `admin.trigger.put`, and when what it names is here: a team, a service principal of that
  team, and a profile. `put`'s own checks — the name, the source and its cron, the keys of
  the terms, the visibility, the review, the cap, the notification target — are the row's
  changeset, asked without writing anything. A key of the spec a trigger does not have is
  refused too, so that a misspelt `promptTemplate` is reported rather than read as a
  trigger that asks for nothing. A new resource that fails gets no row; a changed one
  leaves its row as the last version that passed, and it goes on firing as that.

  ## What stays the plane's

  The trigger's key, which `admin.trigger.key.rotate` mints and the row holds only as a
  salted hash; when it last fired; its revisions and its runs. None of them is in a
  resource. The row is changed in place, so none of them moves when the repository changes
  the trigger. A resource that goes takes its row with it, runs and key included, as
  `admin.trigger.delete` did.
  """

  @behaviour Troupe.Plane.Gitops

  alias Troupe.Plane.{Audit, Fleet, Gitops, Identity, Principals, Provision, Triggers}
  alias Troupe.Plane.Triggers.Trigger

  require Logger

  @kind "Trigger"

  # Not a person, and the trail says so: the change was a commit somebody reviewed and an
  # applier applied, and this is the plane recording that it saw it.
  @actor "system:gitops"

  # The spec's keys, in the order a reader would want them, and the row's field each is.
  @fields [
    {"principal", :principal_id},
    {"profile", :profile},
    {"agent", :agent},
    {"enabled", :enabled},
    {"source", :source},
    {"promptTemplate", :prompt_template},
    {"terms", :terms},
    {"visibility", :visibility},
    {"review", :review},
    {"notify", :notify},
    {"notifyUrl", :notify_url},
    {"concurrency", :concurrency}
  ]

  # A resource spells a term as Kubernetes spells a field; the row keeps what
  # `session.create` reads.
  @terms [
    {"budgetMicros", "budget_micros"},
    {"maxTurns", "max_turns"},
    {"wallClockSeconds", "wall_clock_seconds"},
    {"approvals", "approvals"}
  ]

  # What an audit diff is taken over: what `admin.trigger.put`'s is, and the notification
  # target, which a commit changes as surely as anything else in the manifest.
  @compared [
    :principal_id,
    :profile,
    :agent,
    :enabled,
    :source,
    :prompt_template,
    :terms,
    :visibility,
    :review,
    :notify,
    :notify_url,
    :concurrency
  ]

  @impl Gitops
  def kind, do: @kind

  @impl Gitops
  def api_version, do: "troupe.dev/v1alpha1"

  @impl Gitops
  def rows, do: Map.new(Triggers.list_all(), &{resource_name(&1.team.name, &1.name), &1})

  # Read once a pass: the teams and the profiles are the same for every resource. This runs
  # after the pass has read the `WorkerProfile`s, so a profile and a trigger added in one
  # commit are both here at the pass that sees them.
  @impl Gitops
  def context do
    %{
      teams: Map.new(Identity.list_teams(), &{&1.name, &1}),
      profiles: MapSet.new(Fleet.list_profiles(), & &1.name)
    }
  end

  @doc "The name of a trigger's resource: `<team>.<trigger>`."
  @spec resource_name(String.t(), String.t()) :: String.t()
  def resource_name(team, name), do: team <> "." <> name

  @doc "The team and the trigger a resource's name says, or `:error` where it says neither."
  @spec split(term()) :: {:ok, String.t(), String.t()} | :error
  def split(name) when is_binary(name) do
    case String.split(name, ".") do
      [team, trigger] when team != "" and trigger != "" -> {:ok, team, trigger}
      _other -> :error
    end
  end

  def split(_name), do: :error

  @doc "The spec's keys a resource spells a trigger with."
  @spec spec_keys() :: [String.t()]
  def spec_keys, do: Enum.map(@fields, &elem(&1, 0))

  # -- reading one --------------------------------------------------------------

  @impl Gitops
  def read(resource, context) do
    name = get_in(resource, ["metadata", "name"])
    spec = resource["spec"] || %{}

    with {:ok, team, trigger} <- placed(name, context) do
      {principal_id, not_principal} = principal(spec["principal"], team)
      {terms, not_terms} = terms(spec["terms"])

      attrs =
        spec
        |> fields()
        |> Map.merge(%{
          team_id: team.id,
          name: trigger,
          principal_id: principal_id,
          terms: terms,
          resource_generation: get_in(resource, ["metadata", "generation"])
        })

      reasons =
        unknown(spec) ++
          not_principal ++ no_profile(attrs.profile, context) ++ not_terms ++ invalid(attrs)

      if reasons == [], do: {:ok, Map.put(attrs, :team, team)}, else: {:error, reasons}
    end
  end

  defp placed(name, context) do
    case split(name) do
      {:ok, team_name, trigger} ->
        case Map.fetch(context.teams, team_name) do
          {:ok, team} ->
            {:ok, team, trigger}

          :error ->
            {:error,
             [
               "metadata.name names the team #{team_name}, which this plane does not have: " <>
                 "enable the team (admin.team.enable) or name one it has"
             ]}
        end

      :error ->
        {:error,
         [
           "metadata.name is <team>.<trigger>, the team's name and the trigger's joined by one " <>
             "dot, and #{inspect(name)} is not"
         ]}
    end
  end

  # Every field the row has, from the spec or from the field's own default.
  defp fields(spec) do
    defaults = %Trigger{}

    for {key, field} <- @fields, field not in [:principal_id, :terms], into: %{} do
      case spec[key] do
        nil -> {field, Map.fetch!(defaults, field)}
        value -> {field, value}
      end
    end
  end

  defp unknown(spec) do
    case Map.keys(spec) -- spec_keys() do
      [] ->
        []

      extra ->
        [
          "#{Enum.map_join(extra, ", ", &("spec." <> &1))} " <>
            "#{if length(extra) == 1, do: "is not a field", else: "are not fields"} of a Trigger, " <>
            "which has #{Enum.join(spec_keys(), ", ")}"
        ]
    end
  end

  defp principal(subject, team) when is_binary(subject) do
    case Principals.get(subject) do
      %{team_id: team_id, id: id} when team_id == team.id ->
        {id, []}

      nil ->
        {nil,
         [
           "spec.principal #{subject} is not a service principal this plane has: make it in " <>
             "the team #{team.name} first (admin.principal.create)"
         ]}

      _elsewhere ->
        {nil,
         [
           "spec.principal #{subject} is not a service principal of the team #{team.name}, " <>
             "and a trigger runs as one of its own team's"
         ]}
    end
  end

  defp principal(nil, _team) do
    {nil, ["spec.principal is missing: a trigger runs as a service principal of its team"]}
  end

  defp principal(other, _team) do
    {nil, ["spec.principal is a subject, svc:<team>/<name>, not #{inspect(other)}"]}
  end

  # Checked here because nothing else would: `put` takes any name, and a trigger on a
  # profile the plane does not have is one that fails at every firing.
  defp no_profile(name, context) when is_binary(name) do
    if MapSet.member?(context.profiles, name),
      do: [],
      else: ["spec.profile #{name} is not a profile this plane has"]
  end

  defp no_profile(_name, _context), do: []

  defp terms(nil), do: {%{}, []}

  defp terms(terms) when is_map(terms) do
    known = Map.new(@terms)
    {kept, extra} = Enum.split_with(terms, fn {key, _value} -> Map.has_key?(known, key) end)

    reasons =
      case extra do
        [] ->
          []

        extra ->
          [
            "spec.terms takes #{Enum.map_join(@terms, ", ", &elem(&1, 0))}, not " <>
              Enum.map_join(extra, ", ", &elem(&1, 0))
          ]
      end

    {Map.new(kept, fn {key, value} -> {known[key], value} end), reasons}
  end

  defp terms(other), do: {%{}, ["spec.terms is an object, not #{inspect(other)}"]}

  # What the row's own changeset refuses, which is `put`'s check. The principal is left
  # out: where it could not be found that is already said, and better.
  defp invalid(attrs) do
    %Trigger{}
    |> Trigger.changeset(Map.drop(attrs, [:resource_generation]))
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.reject(fn {field, _messages} -> field in [:principal_id, :team_id] end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{spelled(field)} #{&1}")
    end)
  end

  defp interpolate({message, opts}) do
    values = Map.new(opts, fn {name, value} -> {to_string(name), value} end)

    Regex.replace(~r/%{(\w+)}/, message, fn whole, key ->
      values |> Map.get(key, whole) |> to_string()
    end)
  end

  defp spelled(:name), do: "metadata.name"

  defp spelled(field) do
    case List.keyfind(@fields, field, 1) do
      {key, _field} -> "spec." <> key
      nil -> to_string(field)
    end
  end

  # -- writing one --------------------------------------------------------------

  @impl Gitops
  def take(_name, attrs, row, _resource) do
    {team, attrs} = Map.pop!(attrs, :team)
    {:ok, trigger, revision} = Triggers.follow(team, attrs, @actor)
    changes = Audit.diff(comparable(row), comparable(trigger))

    state =
      cond do
        is_nil(row) -> :created
        changes == %{} -> :unchanged
        true -> :changed
      end

    if state != :unchanged do
      # Named with the revision, as an administrator's put is, so the trail and the
      # revision a run names point at each other.
      detail =
        Map.merge(changes, %{
          "__revision__" => revision.revision,
          "__revision_hash__" => revision.hash
        })

      {:ok, _} = Audit.record(@actor, "trigger.put", "#{team.name}/#{trigger.name}", detail)

      Logger.info(
        "troupe plane: gitops: trigger #{team.name}/#{trigger.name} " <>
          "#{if state == :created, do: "read from", else: "changed in"} the cluster, " <>
          "revision #{revision.revision}"
      )
    end

    {state, nil}
  end

  # -- a row with no resource -----------------------------------------------------

  @impl Gitops
  def gone(%Trigger{resource_generation: nil} = trigger) do
    {:missing,
     [
       "the cluster has no Trigger #{resource_name(trigger.team.name, trigger.name)}, and the " <>
         "plane has had this trigger since before it read the cluster, so it goes on firing: " <>
         "commit its manifest (admin.profiles.export has it), or delete it with " <>
         "admin.trigger.delete"
     ]}
  end

  # Gone from the cluster, which in this mode is gone from the repository: what an
  # administrator's delete did, recorded the same way, with the plane as the actor. It
  # stops firing, its runs go with it, and the sessions they made stay.
  def gone(%Trigger{} = trigger) do
    subject = "#{trigger.team.name}/#{trigger.name}"
    {:ok, _} = Audit.record(@actor, "trigger.delete", subject, comparable(trigger))
    :ok = Triggers.delete(trigger)

    Logger.warning(
      "troupe plane: gitops: trigger #{subject} is gone from the cluster, and its row with it"
    )

    :removed
  end

  defp comparable(nil), do: %{}
  defp comparable(trigger), do: Map.take(trigger, @compared)

  # -- bootstrapping a repository -----------------------------------------------

  @doc """
  Every trigger as a repository would hold it: the resource's name, the team, where the
  file would go, what to know before committing it, and the YAML.
  """
  @spec export() :: [map()]
  def export do
    for trigger <- Triggers.list_all() do
      notes = notes(trigger)

      %{
        name: resource_name(trigger.team.name, trigger.name),
        team: trigger.team.name,
        path: "triggers/#{trigger.team.name}/#{trigger.name}.yaml",
        notes: notes,
        yaml: Gitops.yaml(manifest(trigger), notes)
      }
    end
  end

  @doc """
  A trigger as its resource: the document, and nothing the plane keeps of its own — not
  the key, not when it last fired, not who made it. An empty field is left out, which
  reads back as the same empty default.
  """
  @spec manifest(Trigger.t()) :: map()
  def manifest(%Trigger{} = trigger) do
    principal = Principals.fetch(trigger.principal_id)

    spec =
      @fields
      |> Enum.map(fn {key, field} -> {key, spec_value(field, trigger, principal)} end)
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> Map.new()

    %{
      "apiVersion" => api_version(),
      "kind" => @kind,
      "metadata" => %{
        "name" => resource_name(trigger.team.name, trigger.name),
        "namespace" => Provision.namespace()
      },
      "spec" => spec
    }
  end

  defp spec_value(:principal_id, _trigger, principal), do: principal && principal.subject

  defp spec_value(:terms, trigger, _principal) do
    spelled = Map.new(@terms, fn {key, term} -> {term, key} end)
    Map.new(trigger.terms || %{}, fn {term, value} -> {Map.get(spelled, term, term), value} end)
  end

  defp spec_value(field, trigger, _principal), do: Map.fetch!(trigger, field)

  defp blank?(value), do: value in [nil, "", [], %{}]

  defp notes(trigger) do
    key_note(trigger) ++ name_note(trigger)
  end

  defp key_note(%Trigger{key_hash: hash}) when is_binary(hash) do
    [
      "This trigger has a key of its own, which stays with the plane and is not in this file.",
      "It goes on working after the switch, as long as the trigger keeps its team and name."
    ]
  end

  defp key_note(_trigger), do: []

  # A trigger's name may end in a dash and a Kubernetes name may not.
  defp name_note(trigger) do
    if String.ends_with?(trigger.name, "-"),
      do: [
        "metadata.name must end in a letter or a digit to be a Kubernetes name:",
        "the trigger needs another name before this is committed."
      ],
      else: []
  end
end
