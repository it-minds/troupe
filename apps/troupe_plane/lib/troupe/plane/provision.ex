defmodule Troupe.Plane.Provision do
  @moduledoc """
  Turning a profile into a `WorkerProfile`, one of two ways.

  **Direct.** The plane writes the custom resource itself. Its ServiceAccount may create,
  update and delete `WorkerProfile` and `TeamVolume` in `troupe-system` and read
  `TroupePolicy` — and nothing else, which is a thing to confirm with `kubectl auth can-i`
  rather than to read off an RBAC file and believe.

  **GitOps.** The plane commits the same manifest to a repository and Flux applies it.
  The state is `Pending` until the CR's `observedGeneration` catches up with the
  generation that was committed, because a commit is not a deployment: showing it as one
  would make a failed apply invisible, which is the failure mode GitOps is supposed to
  remove rather than add.

  Both modes render the same manifest from the same profile and write the same audit
  record. What differs is where it goes.

  ## Policy is checked here for speed, not for safety

  `check/1` validates against `TroupePolicy` so a person editing a profile finds out
  immediately rather than after a round trip. It is not the enforcement: admission is,
  and the operator is again after that. A panel that was the only check would be a check
  anybody could bypass with `kubectl`.

  ## `release` is a reference, not an image

  A profile may give its image as the word `release`: the worker image of the release
  this plane is running, which the chart sets from its own version. The row keeps the
  word and the manifest gets the image, resolved here and nowhere else — so every write
  after an upgrade carries the upgrade's image, and the policy checks the image a pod will
  actually run rather than the word. `Troupe.Plane.Fleet.ReleaseImage` is what makes an
  upgraded plane write those profiles again when nothing else would.
  """

  alias Troupe.Plane.{ClusterPolicy, Fleet, Identity, Settings}
  alias Troupe.Plane.Fleet.{Profile, SizeClass}
  alias Troupe.Policy
  alias Troupe.Protocol.Error
  alias Troupe.WorkerProfile

  @release "release"

  @doc "Which way this plane provisions."
  @spec mode() :: :direct | :gitops
  def mode, do: Settings.get("provisioning_mode")

  @doc """
  Check a profile against the cluster policy, for fast feedback.

  Returns every violation rather than the first: a form that fixed one problem at a time
  would take four round trips to get right.
  """
  @spec check(map()) :: :ok | {:error, Error.t()}
  def check(attrs) do
    case violations(attrs) do
      [] ->
        :ok

      found ->
        # Described, not passed through. A violation is a tuple — `{:sessions_per_pod_above_maximum, 8, 4}`
        # — and `Jason` refuses tuples, so putting them in an error's data turned a
        # legitimate refusal into a 500 with an HTML body: the caller was told nothing at
        # all about the one thing they got wrong. `Policy.describe/1` exists for this and
        # says it in a sentence.
        {:error, Error.new(:invalid_params, %{policy_violations: Enum.map(found, &Policy.describe/1)})}
    end
  end

  @doc "What the policy makes of a profile, as the panel renders it."
  @spec verdict(Profile.t() | map()) :: map()
  def verdict(profile) do
    case violations(profile) do
      [] -> %{allowed?: true, violations: []}
      found -> %{allowed?: false, violations: found}
    end
  end

  # The same parser the operator uses, against the same document: the panel's check has
  # to be the check admission will make, or fast feedback becomes confident nonsense.
  defp violations(profile) do
    case policy() do
      nil -> []
      policy -> Policy.violations(WorkerProfile.from_resource(resource_of(profile)), policy)
    end
  end

  defp resource_of(profile) do
    %{"metadata" => %{"name" => name_of(profile)}, "spec" => spec_of(profile)}
  end

  defp name_of(%Profile{name: name}), do: name
  defp name_of(attrs), do: get(attrs, :name)

  # The cluster's `TroupePolicy`, read once per call rather than cached: it is a
  # cluster-admin's document and changing it should take effect without restarting the
  # plane. Read through `ClusterPolicy` so the bundle check and this one cannot be
  # looking at two different documents.
  defp policy, do: ClusterPolicy.current()

  defp spec_of(%Profile{} = profile), do: Map.merge(profile.spec || %{}, base_spec(profile))

  defp spec_of(%{} = attrs),
    do: attrs |> Map.get(:spec, Map.get(attrs, "spec", %{})) |> Map.merge(base_spec(attrs))

  # The seven fields that left the admin surface, written here from the one word that
  # replaced them. Merged *over* the profile's own `spec` map on purpose: a class is the
  # answer, and a hand-written `sessionsPerPod` kept beside it would be a profile with two
  # opinions about the same number.
  defp base_spec(source) do
    %{"image" => image_spec(get(source, :image)), "replicas" => get(source, :replicas)}
    |> Map.merge(SizeClass.spec(get(source, :size_class)))
    |> Map.put("storage", storage_spec(source))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The size is the class's and the *class of storage* is the cluster's. Merged rather
  # than replaced, because these are two answers to two questions that happen to live in
  # one object — and a class that overwrote the whole map would silently drop the storage
  # class, which on a cluster whose default is block storage is how granting a team access
  # to a profile takes that profile down.
  defp storage_spec(source) do
    existing = spec_map(source)["storage"] || %{}
    Map.merge(existing, SizeClass.spec(get(source, :size_class))["storage"])
  end

  defp spec_map(%Profile{} = profile), do: profile.spec || %{}
  defp spec_map(attrs), do: Map.get(attrs, :spec) || Map.get(attrs, "spec") || %{}

  # The plane records an image as the string a person types; the custom resource splits
  # it into a repository and a tag or digest, because that is what a policy matches
  # against. Converted here rather than stored twice: two fields that had to agree would
  # eventually not.
  defp image_spec(nil), do: nil
  defp image_spec(%{} = already), do: already

  # Resolved when the manifest is rendered rather than when the profile is saved, so the
  # row goes on saying what an administrator meant and the image moves when the plane
  # does. A plane that names no release image resolves it to nothing, and `apply/2`
  # refuses to write a resource without one.
  defp image_spec(@release) do
    case release_image() do
      nil -> nil
      image -> split_image(image)
    end
  end

  defp image_spec(image) when is_binary(image), do: split_image(image)

  defp split_image(image) do
    case String.split(image, "@", parts: 2) do
      [repository, digest] -> %{"repository" => repository, "digest" => digest}
      [_image] -> tagged(image)
    end
  end

  # The last colon, so a registry with a port — `registry:5000/troupe/worker:1` — is not
  # read as a repository called `registry` with a very odd tag.
  defp tagged(image) do
    case String.split(image, ":") do
      [repository] ->
        %{"repository" => repository}

      parts ->
        %{"repository" => parts |> Enum.drop(-1) |> Enum.join(":"), "tag" => List.last(parts)}
    end
  end

  defp get(%Profile{} = profile, key), do: Map.get(profile, key)
  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  # -- the release's image ----------------------------------------------------

  @doc """
  The worker image of the release this plane is running, or `nil` where it names none.

  `TROUPE_WORKER_IMAGE`, which the chart sets from `worker.image` and its own version. Read
  from configuration on every call rather than remembered, because it is a fact about the
  deployment and a test has to be able to change it.
  """
  @spec release_image() :: String.t() | nil
  def release_image do
    case Application.get_env(:troupe_plane, :worker_image) do
      image when is_binary(image) and image != "" -> image
      _unset -> nil
    end
  end

  @doc "Whether a profile's image is the word `release` rather than an image."
  @spec follows_release?(Profile.t() | map()) :: boolean()
  def follows_release?(profile), do: get(profile, :image) == @release

  @doc """
  The image a profile's `WorkerProfile` carries now, or `nil` where there is none yet.

  Direct mode asks the cluster, because the resource there is what the plane wrote. GitOps
  mode reads the manifest the plane last committed: the resource in the cluster lags the
  commit by however long Flux takes, and comparing against it would commit the same image
  again every time the plane restarted before Flux caught up.
  """
  @spec current_image(Profile.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def current_image(%Profile{} = profile) do
    case mode() do
      :direct -> live_image(profile)
      :gitops -> committed_image(profile)
    end
  end

  defp live_image(profile) do
    case live_resource(profile) do
      {:ok, resource} -> {:ok, image_of(resource)}
      # Never written, which is as different from any image as a resource can be.
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp committed_image(profile) do
    with {:ok, repo} <- repository() do
      repo.path |> Path.join(manifest_path(profile)) |> File.read() |> committed()
    end
  end

  # Never committed is no image at all, which is as different from any image as a
  # manifest can be.
  defp committed({:error, :enoent}), do: {:ok, nil}
  defp committed({:error, reason}), do: {:error, reason}

  defp committed({:ok, yaml}) do
    with {:ok, resource} <- YamlElixir.read_from_string(yaml), do: {:ok, image_of(resource)}
  end

  # Read back with the operator's own parser, so "the same image" means what the operator
  # would take it to mean — a digest winning over a tag included.
  defp image_of(resource) do
    case WorkerProfile.from_resource(resource).image do
      "" -> nil
      image -> image
    end
  end

  @doc """
  Put a profile into the cluster, whichever way this plane does that.

  Returns the state to show: `:applied` when the plane wrote the resource itself,
  `{:pending, generation}` when it was committed and is waiting for Flux.
  """
  @spec apply(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(%Profile{} = profile, actor) do
    with :ok <- resolvable(profile) do
      case mode() do
        :direct -> direct_apply(profile, actor)
        :gitops -> gitops_commit(profile, actor)
      end
    end
  end

  # `spec.image` is the one field the resource cannot be without, and a profile following
  # a release this plane cannot name would render without it. Refused here, by name, rather
  # than left for the API server to refuse as a schema error — or, in GitOps mode, for
  # Flux to refuse long after the commit said it had worked.
  defp resolvable(profile) do
    if follows_release?(profile) and is_nil(release_image()),
      do: {:error, :no_worker_image},
      else: :ok
  end

  @doc "Take one out again."
  @spec remove(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def remove(%Profile{} = profile, actor) do
    case mode() do
      :direct -> direct_delete(profile, actor)
      :gitops -> gitops_remove(profile, actor)
    end
  end

  @doc """
  Rewrite a profile's `teams` from the plane's grants.

  The plane is the only writer of that field, and it is a *projection* of plane state
  rather than a second source of truth: an operator reading it is reading what the plane
  believes about grants, which is the only thing it could correctly act on.
  """
  @spec sync_teams(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sync_teams(profile_name, actor) do
    case Fleet.get_profile(profile_name) do
      nil -> {:ok, %{profile: profile_name, synced: false}}
      profile -> __MODULE__.apply(profile, actor)
    end
  end

  @doc "The manifest a profile becomes, in either mode."
  @spec manifest(Profile.t()) :: map()
  def manifest(%Profile{} = profile) do
    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{
        "name" => profile.name,
        "namespace" => namespace(),
        # So a reader can tell a profile the plane wrote from one somebody applied by
        # hand, which is the difference between a bug and a deliberate override.
        "labels" => %{"troupe.dev/managed-by" => "plane"}
      },
      "spec" =>
        Map.merge(
          profile.spec || %{},
          base_spec(profile) |> Map.merge(%{"teams" => teams_of(profile)})
        )
    }
  end

  # `claimName`, which is what the resource declares and what `Troupe.WorkerProfile` reads
  # back. It said `volume` for a long time and nothing noticed, because `teams` is a
  # projection of grants and a profile with no grant projects an empty list: the first
  # grant anybody made turned every subsequent write of that profile into an API error —
  # `field not declared in schema` — and had the schema been permissive instead, the
  # operator would have read `claim_name: nil` and quietly never bound the volume.
  #
  # `ProvisionManifestTest` round-trips this through the parser, so the two cannot drift
  # again without a test saying so.
  # Only teams that were actually given a volume, and the volume they were given.
  #
  # A grant is not a volume. `volume_mode` is `ro` or `rw` and has no third value, so
  # every grant used to project a claim whether or not anybody had asked for storage —
  # and the class and the size, which live on the team, were not projected at all. The
  # operator therefore fell back to the cluster's default class, and an installation
  # whose default is block storage got a `ReadOnlyMany` claim that its CSI driver refuses
  # outright: `mode "MULTI_NODE_READER_ONLY" not supported`. The claim never binds, the
  # pod never schedules, and granting a team access to a profile is what took that
  # profile down.
  #
  # So the storage class is the switch. It is the field somebody has to fill in on
  # purpose, it is the one a `TroupePolicy` can allow or refuse, and a deployment with no
  # many-reader storage simply leaves it empty and gets no team volumes — rather than
  # unschedulable pods and a message about capacity.
  defp teams_of(profile) do
    profile.name
    |> Identity.grants_for_profile()
    |> Enum.filter(&volume?/1)
    |> Enum.map(fn grant ->
      %{
        "name" => grant.team.name,
        "claimName" => volume_name(grant.team.name),
        "mode" => grant.volume_mode,
        "storageClassName" => grant.team.volume_storage_class,
        "size" => grant.team.volume_size
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp volume?(%{team: %{volume_storage_class: class}}) when is_binary(class), do: class != ""
  defp volume?(_grant), do: false

  defp volume_name(team), do: "troupe-team-#{team}"

  # -- direct -----------------------------------------------------------------

  defp direct_apply(profile, _actor) do
    with {:ok, conn} <- connection() do
      operation = K8s.Client.apply(manifest(profile), field_manager: "troupe-plane", force: true)

      case K8s.Client.run(conn, operation) do
        {:ok, applied} ->
          {:ok, %{mode: :direct, state: :applied, generation: generation(applied)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp direct_delete(profile, _actor) do
    with {:ok, conn} <- connection() do
      operation =
        K8s.Client.delete("troupe.dev/v1alpha1", "WorkerProfile",
          namespace: namespace(),
          name: profile.name
        )

      case K8s.Client.run(conn, operation) do
        {:ok, _deleted} ->
          {:ok, %{mode: :direct, state: :deleted}}

        # Already gone is the outcome that was wanted.
        {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
          {:ok, %{mode: :direct, state: :deleted}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generation(resource), do: get_in(resource, ["metadata", "generation"])

  # A plane with no cluster is a plane under test or a plane whose panel is being used to
  # draft profiles. Saying so beats pretending it wrote something.
  defp connection do
    case Application.get_env(:troupe_plane, :k8s_conn) do
      nil -> {:error, :no_cluster}
      {module, function, args} -> Kernel.apply(module, function, args)
      conn -> {:ok, conn}
    end
  end

  defp namespace, do: Application.get_env(:troupe_plane, :namespace, "troupe-system")

  # -- gitops -----------------------------------------------------------------

  defp gitops_commit(profile, actor) do
    with {:ok, repo} <- repository() do
      path = Path.join(repo.path, manifest_path(profile))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Ymlr.document!(manifest(profile)))

      message = "troupe: #{profile.name} updated by #{actor.subject}"

      with {:ok, sha} <- commit(repo, path, message, actor) do
        {:ok, %{mode: :gitops, state: :pending, commit: sha, path: manifest_path(profile)}}
      end
    end
  end

  defp gitops_remove(profile, actor) do
    with {:ok, repo} <- repository() do
      path = Path.join(repo.path, manifest_path(profile))
      File.rm(path)

      with {:ok, sha} <-
             commit(repo, path, "troupe: #{profile.name} removed by #{actor.subject}", actor) do
        {:ok, %{mode: :gitops, state: :pending, commit: sha}}
      end
    end
  end

  defp manifest_path(profile), do: Path.join(["profiles", "#{profile.name}.yaml"])

  defp commit(repo, path, message, actor) do
    relative = Path.relative_to(path, repo.path)

    with {_output, 0} <- git(repo, ["add", "--all", relative]),
         {_output, 0} <-
           git(repo, [
             "-c",
             "user.name=troupe-plane",
             "-c",
             "user.email=#{actor.subject}",
             "commit",
             "--allow-empty",
             "-m",
             message
           ]),
         {sha, 0} <- git(repo, ["rev-parse", "HEAD"]) do
      push(repo)
      {:ok, String.trim(sha)}
    else
      {output, status} -> {:error, {:git_failed, status, String.trim(output)}}
    end
  end

  # A repository with no remote is a fixture, which is what a test uses.
  defp push(repo) do
    case git(repo, ["remote"]) do
      {"", 0} -> :ok
      {_remote, 0} -> git(repo, ["push", "origin", "HEAD"])
      _other -> :ok
    end
  end

  defp git(repo, args), do: System.cmd("git", ["-C", repo.path | args], stderr_to_stdout: true)

  defp repository do
    case Application.get_env(:troupe_plane, :gitops) do
      nil -> {:error, :no_repository_configured}
      config -> {:ok, %{path: config[:path]}}
    end
  end

  @doc """
  Whether a committed profile has actually been applied yet.

  `observedGeneration` is the operator saying it has seen this version. Comparing it with
  the generation the commit produced is what turns "we pushed it" into "it is running".
  """
  @spec pending?(Profile.t()) :: boolean()
  def pending?(%Profile{} = profile) do
    case live_resource(profile) do
      {:ok, resource} ->
        observed = get_in(resource, ["status", "observedGeneration"])
        observed != generation(resource)

      {:error, _reason} ->
        mode() == :gitops
    end
  end

  @doc """
  The conditions a panel shows for a profile.

  Read from the cluster where there is one, because the operator is what sets them and a
  plane inventing its own would be a second opinion about the same question.
  """
  @spec conditions(Profile.t()) :: [map()]
  def conditions(%Profile{} = profile) do
    case live_resource(profile) do
      {:ok, resource} -> get_in(resource, ["status", "conditions"]) || []
      {:error, _reason} -> []
    end
  end

  defp live_resource(profile) do
    with {:ok, conn} <- connection() do
      operation =
        K8s.Client.get("troupe.dev/v1alpha1", "WorkerProfile",
          namespace: namespace(),
          name: profile.name
        )

      K8s.Client.run(conn, operation)
    end
  end
end
