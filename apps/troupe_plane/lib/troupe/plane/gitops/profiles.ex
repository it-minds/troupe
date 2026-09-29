defmodule Troupe.Plane.Gitops.Profiles do
  @moduledoc """
  `WorkerProfile` resources, read into the rows the plane places sessions and scales by
  (Decision 736).

  What a row takes from its resource:

  | row | resource |
  | --- | --- |
  | `image` | `spec.image`, as `repository:tag`, or `repository@digest` where it pins one |
  | `size_class` | read off `spec.sessionsPerPod`: 4 (the CRD's default) is `standard`, 2 is `heavy` |
  | `max_sessions` | the annotation `troupe.dev/max-sessions`, no ceiling where absent |
  | `warm_workers` | the annotation `troupe.dev/warm-workers`, 0 where absent |
  | `provisioner` | the annotation `troupe.dev/provisioner`, `kubernetes` where absent |
  | `config_bundle_channel` | `spec.configBundleChannel`, `stable` where absent |
  | `spec` | the rest of the spec, which is what the operator reads |
  | `replicas` | `spec.replicas` when the row is made, and the scaler's after that |

  The class is read off the resource's number rather than written onto it, as it is for a
  profile from before there were classes: the numbers are the repository's here. The
  plane places sessions and scales by the class, so the number has to be one a class
  has; CPU, memory and disk are the repository's to size as the policy allows.

  ## The checks

  A resource is used only when the plane could have saved it itself: its annotations
  parse, it has an image, its `sessionsPerPod` is a class's, the cluster policy allows it
  (the check `Provision` makes, against the same document), and it does not set
  `replicas`, `teams` or `mcpServers`, which are the plane's to write. The last is read
  from who owns them, not whether they are there: every resource has them once the plane
  has written them.

  ## After a row is written

  The plane writes its three fields where the resource does not say them yet — a profile
  the repository has only just added gets the channel's servers and the teams' volumes at
  once — and only onto a resource the repository holds (`Provision.ownership/1`). One only
  the plane has ever written is a resource from direct mode nothing applies yet: it is
  used, reported as `plane_only`, and not written to, because a write of three fields
  would give up the rest.
  """

  @behaviour Troupe.Plane.Gitops

  alias Troupe.Plane.{Audit, ClusterPolicy, Fleet, Gitops, Provision}
  alias Troupe.Plane.Fleet.{Profile, Provisioner, SizeClass}
  alias Troupe.Policy
  alias Troupe.WorkerProfile

  require Logger

  @kind "WorkerProfile"

  # Not a person, and the trail says so: the change was a commit somebody reviewed and
  # Flux applied, and this is the plane recording that it saw it.
  @actor "system:gitops"

  # What an audit diff is taken over, as for an administrator's edit, with the plane's own
  # projection taken out: a repository never sets `mcpServers`, so a change in them is the
  # plane's and not the repository's.
  @compared [
    :image,
    :size_class,
    :sessions_per_pod,
    :max_sessions,
    :warm_workers,
    :provisioner,
    :config_bundle_channel,
    :spec
  ]

  @impl Gitops
  def kind, do: @kind

  @impl Gitops
  def api_version, do: "troupe.dev/v1alpha1"

  @impl Gitops
  def rows, do: Map.new(Fleet.list_profiles(), &{&1.name, &1})

  # Read once a pass rather than once a resource: the policy is one document, and a pass
  # over twenty profiles is not twenty questions to the API server about it.
  @impl Gitops
  def context, do: ClusterPolicy.current()

  # -- reading one --------------------------------------------------------------

  @impl Gitops
  def read(resource, policy) do
    spec = resource["spec"] || %{}
    annotations = get_in(resource, ["metadata", "annotations"]) || %{}
    per_pod = spec["sessionsPerPod"] || 4
    {answers, unreadable} = answers(annotations)

    attrs =
      Map.merge(answers, %{
        name: get_in(resource, ["metadata", "name"]),
        image: image(resource),
        sessions_per_pod: per_pod,
        size_class: SizeClass.of_sessions_per_pod(per_pod),
        config_bundle_channel: spec["configBundleChannel"] || "stable",
        # The image and the count have columns of their own and `teams` is the grants';
        # `mcpServers` stays, as what the resource carries, for a reader of the profile.
        spec: Map.drop(spec, ~w(image replicas teams)),
        resource_generation: get_in(resource, ["metadata", "generation"])
      })

    reasons =
      unreadable ++
        no_image(attrs) ++
        not_a_class(per_pod) ++
        written_elsewhere(resource) ++ violations(resource, policy) ++ invalid(attrs)

    if reasons == [], do: {:ok, attrs}, else: {:error, reasons}
  end

  defp answers(annotations) do
    %{max_sessions: max, warm_workers: warm, provisioner: provisioner} =
      Provision.answer_annotations()

    [
      {:max_sessions, whole(annotations[max], max, nil, &(&1 > 0), "a whole number above 0")},
      {:warm_workers,
       whole(annotations[warm], warm, 0, &(&1 in 0..10), "a whole number from 0 to 10")},
      {:provisioner, substrate(annotations[provisioner], provisioner)}
    ]
    |> Enum.reduce({%{}, []}, fn
      {key, {:ok, value}}, {attrs, errors} -> {Map.put(attrs, key, value), errors}
      {_key, {:error, reason}}, {attrs, errors} -> {attrs, errors ++ [reason]}
    end)
  end

  defp whole(nil, _annotation, default, _fits?, _expected), do: {:ok, default}

  defp whole(text, annotation, _default, fits?, expected) do
    with {number, ""} <- Integer.parse(String.trim(to_string(text))),
         true <- fits?.(number) do
      {:ok, number}
    else
      _no -> {:error, "#{annotation} must be #{expected}, not #{inspect(text)}"}
    end
  end

  defp substrate(nil, _annotation), do: {:ok, "kubernetes"}

  defp substrate(name, annotation) do
    if Provisioner.known?(name),
      do: {:ok, name},
      else:
        {:error,
         "#{annotation} must be one of #{Enum.join(Provisioner.names(), ", ")}, not #{inspect(name)}"}
  end

  # With the operator's parser, so the image is what the operator would run.
  defp image(resource) do
    case WorkerProfile.from_resource(resource).image do
      "" -> nil
      image -> image
    end
  end

  defp no_image(%{image: nil}), do: ["spec.image names no repository"]
  defp no_image(_attrs), do: []

  # A number no class has would be a profile the plane places by one number while its
  # workers are given another, which is the two opinions a class exists to prevent.
  defp not_a_class(per_pod) do
    classes = Enum.map(SizeClass.names(), &{&1, SizeClass.sessions_per_pod(&1)})

    if Enum.any?(classes, fn {_name, holds} -> holds == per_pod end) do
      []
    else
      [
        "spec.sessionsPerPod is #{inspect(per_pod)}, and the plane places sessions by size " <>
          "class: a worker holds " <>
          Enum.map_join(classes, " or ", fn {name, holds} -> "#{holds} (#{name})" end)
      ]
    end
  end

  defp written_elsewhere(resource) do
    case Provision.ownership(resource) do
      {:foreign, fields} ->
        writers =
          fields
          |> Enum.flat_map(&Gitops.managers(resource, String.split(&1, ".")))
          |> Enum.reject(&Gitops.plane?/1)
          |> Enum.uniq()

        [
          "#{Enum.join(fields, ", ")} #{if length(fields) == 1, do: "is", else: "are"} the plane's to write, " <>
            "and #{Enum.join(writers, ", ")} sets #{if length(fields) == 1, do: "it", else: "them"} too: " <>
            "take #{if length(fields) == 1, do: "it", else: "them"} out of the manifest"
        ]

      _held ->
        []
    end
  end

  # The resource as the cluster holds it, which is what admission judged and what the
  # operator will run: the same parser and the same policy the panel's check uses.
  defp violations(_resource, nil), do: []

  defp violations(resource, %Policy{} = policy) do
    resource
    |> WorkerProfile.from_resource()
    |> Policy.violations(policy)
    |> Enum.map(&("cluster policy: " <> Policy.describe(&1)))
  end

  # What the row's own schema refuses that the checks above do not already say. The CRD's
  # schema stops most of it before the resource exists; this is what keeps one the plane
  # could not have saved itself from becoming a row the next write of it would fail on.
  defp invalid(attrs) do
    for {field, {message, _details}} <- Profile.cluster_changeset(%Profile{}, attrs).errors,
        do: "#{field} #{message}"
  end

  # -- writing one --------------------------------------------------------------

  @impl Gitops
  def take(name, attrs, row, resource) do
    state = put(name, attrs, row, resource)
    {state, settle(Fleet.get_profile(name), resource)}
  end

  # The count is the resource's when the row is made — what the operator is running — and
  # the scaler's from then on, which is why a change to the resource does not touch it.
  defp put(name, attrs, nil, resource) do
    {:ok, profile} =
      attrs
      |> Map.put(:replicas, get_in(resource, ["spec", "replicas"]) || 1)
      |> Fleet.follow_profile()

    {:ok, _} = Audit.record(@actor, "profile.put", name, Audit.diff(%{}, comparable(profile)))

    Logger.info(
      "troupe plane: gitops: #{name} read from the cluster, generation #{profile.resource_generation}"
    )

    :created
  end

  defp put(name, attrs, row, _resource) do
    changes = Audit.diff(comparable(row), comparable(attrs))
    {:ok, _profile} = Fleet.follow_profile(attrs)

    if changes == %{} do
      :unchanged
    else
      {:ok, _} = Audit.record(@actor, "profile.put", name, changes)

      Logger.info(
        "troupe plane: gitops: #{name} changed in the cluster (#{Enum.join(Map.keys(changes), ", ")})"
      )

      :changed
    end
  end

  defp settle(profile, resource) do
    case Provision.ownership(resource) do
      :plane_only ->
        {"plane_only",
         [
           "only the plane has written this resource, so nothing applies it from a repository " <>
             "yet; until something does, the plane uses it as it is and writes none of its fields " <>
             "(replicas, teams, MCP servers)"
         ]}

      _held ->
        case Provision.project(profile, resource) do
          {:ok, _written} ->
            nil

          {:error, reason} ->
            {"unwritten",
             [
               "the plane could not write its own fields (replicas, teams, MCP servers): #{inspect(reason)}"
             ]}
        end
    end
  end

  # -- a row with no resource -----------------------------------------------------

  @impl Gitops
  def gone(%Profile{resource_generation: nil} = profile) do
    {:missing,
     [
       "the cluster has no WorkerProfile #{profile.name}, and the plane has had this row since " <>
         "before it read the cluster: commit its manifest (admin.profiles.export has it), or " <>
         "delete the row with admin.profile.delete"
     ]}
  end

  # Gone from the cluster, which in this mode is gone from the repository: what an
  # administrator's delete did in direct mode, recorded the same way, with the plane as
  # the actor. Its sessions become read-only, as they would have then.
  def gone(%Profile{} = profile) do
    {:ok, _} = Audit.record(@actor, "profile.delete", profile.name, comparable(profile))
    :ok = Fleet.delete_profile(profile.name)

    Logger.warning(
      "troupe plane: gitops: #{profile.name} is gone from the cluster, and its row with it"
    )

    :removed
  end

  # Normalised before it is compared, so that what differs is what somebody changed. A row
  # written in direct mode never held the numbers its class decides or its channel twice
  # (`spec.configBundleChannel` beside the column), and the same resource read back holds
  # all of them; neither is a change, and reading it as one would put an edit nobody made
  # in the trail the first time a plane reads what it wrote itself.
  defp comparable(source) do
    class = SizeClass.spec(Map.get(source, :size_class))

    source
    |> Map.take(@compared)
    |> Map.update(:spec, %{}, fn spec ->
      (spec || %{})
      |> Map.drop(["mcpServers", "configBundleChannel"])
      |> drop_if("sessionsPerPod", class["sessionsPerPod"])
      |> drop_if("resources", class["resources"])
      |> Map.update("storage", nil, &drop_if(&1 || %{}, "size", class["storage"]["size"]))
      |> Map.reject(fn {_key, value} -> value in [nil, %{}] end)
    end)
  end

  defp drop_if(map, key, value) do
    if Map.get(map, key) == value, do: Map.delete(map, key), else: map
  end

  # -- bootstrapping a repository -----------------------------------------------

  @doc """
  Every profile as a repository would hold it, with where it would go and what to know
  before committing it. Built from the rows (`Provision.repository_manifest/1`).
  """
  @spec export() :: [map()]
  def export do
    for profile <- Fleet.list_profiles() do
      notes = notes(profile)

      %{
        name: profile.name,
        path: "profiles/#{profile.name}.yaml",
        notes: notes,
        yaml: Gitops.yaml(Provision.repository_manifest(profile), notes)
      }
    end
  end

  @doc "What a repository's manifest leaves out, because the plane or the cluster writes it."
  @spec left_out() :: [String.t()]
  def left_out do
    Enum.map(Provision.projected_fields(), &("spec." <> &1)) ++
      ["metadata.annotations[#{WorkerProfile.drained_annotation()}]", "status"]
  end

  defp notes(profile) do
    cond do
      not Provision.follows_release?(profile) ->
        []

      image = Provision.release_image() ->
        [
          "image is release on the plane: pinned here to #{image}, the release it runs.",
          "A repository moves it with a commit."
        ]

      true ->
        [
          "image is release on the plane, and it was deployed without a worker image:",
          "give spec.image a repository and a tag before committing this."
        ]
    end
  end
end
