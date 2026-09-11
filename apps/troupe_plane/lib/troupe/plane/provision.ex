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
  """

  alias Troupe.Plane.{Fleet, Identity}
  alias Troupe.Plane.Fleet.Profile
  alias Troupe.Policy
  alias Troupe.Protocol.Error
  alias Troupe.WorkerProfile

  @doc "Which way this plane provisions."
  @spec mode() :: :direct | :gitops
  def mode, do: Application.get_env(:troupe_plane, :provisioning_mode, :direct)

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
        {:error, Error.new(:invalid_params, %{policy_violations: found})}
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
  # plane.
  defp policy do
    case Application.get_env(:troupe_plane, :policy) do
      nil -> nil
      resource -> Policy.from_resource(resource)
    end
  end

  defp spec_of(%Profile{} = profile), do: Map.merge(profile.spec || %{}, base_spec(profile))
  defp spec_of(%{} = attrs), do: attrs |> Map.get(:spec, Map.get(attrs, "spec", %{})) |> Map.merge(base_spec(attrs))

  defp base_spec(source) do
    %{
      "image" => image_spec(get(source, :image)),
      "replicas" => get(source, :replicas),
      "sessionsPerPod" => get(source, :sessions_per_pod)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # The plane records an image as the string a person types; the custom resource splits
  # it into a repository and a tag or digest, because that is what a policy matches
  # against. Converted here rather than stored twice: two fields that had to agree would
  # eventually not.
  defp image_spec(nil), do: nil
  defp image_spec(%{} = already), do: already

  defp image_spec(image) when is_binary(image) do
    case String.split(image, "@", parts: 2) do
      [repository, digest] -> %{"repository" => repository, "digest" => digest}
      [_image] -> tagged(image)
    end
  end

  # The last colon, so a registry with a port — `registry:5000/troupe/worker:1` — is not
  # read as a repository called `registry` with a very odd tag.
  defp tagged(image) do
    case String.split(image, ":") do
      [repository] -> %{"repository" => repository}
      parts -> %{"repository" => parts |> Enum.drop(-1) |> Enum.join(":"), "tag" => List.last(parts)}
    end
  end

  defp get(%Profile{} = profile, key), do: Map.get(profile, key)
  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))

  @doc """
  Put a profile into the cluster, whichever way this plane does that.

  Returns the state to show: `:applied` when the plane wrote the resource itself,
  `{:pending, generation}` when it was committed and is waiting for Flux.
  """
  @spec apply(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(%Profile{} = profile, actor) do
    case mode() do
      :direct -> direct_apply(profile, actor)
      :gitops -> gitops_commit(profile, actor)
    end
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
      "spec" => Map.merge(profile.spec || %{}, base_spec(profile) |> Map.merge(%{"teams" => teams_of(profile)}))
    }
  end

  defp teams_of(profile) do
    profile.name
    |> Identity.grants_for_profile()
    |> Enum.map(fn grant ->
      %{"name" => grant.team.name, "volume" => volume_name(grant.team.name), "mode" => grant.volume_mode}
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp volume_name(team), do: "troupe-team-#{team}"

  # -- direct -----------------------------------------------------------------

  defp direct_apply(profile, _actor) do
    with {:ok, conn} <- connection() do
      operation = K8s.Client.apply(manifest(profile), field_manager: "troupe-plane", force: true)

      case K8s.Client.run(conn, operation) do
        {:ok, applied} -> {:ok, %{mode: :direct, state: :applied, generation: generation(applied)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp direct_delete(profile, _actor) do
    with {:ok, conn} <- connection() do
      operation =
        K8s.Client.delete("troupe.dev/v1alpha1", "WorkerProfile", namespace: namespace(), name: profile.name)

      case K8s.Client.run(conn, operation) do
        {:ok, _deleted} -> {:ok, %{mode: :direct, state: :deleted}}
        # Already gone is the outcome that was wanted.
        {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:ok, %{mode: :direct, state: :deleted}}
        {:error, reason} -> {:error, reason}
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

      with {:ok, sha} <- commit(repo, path, "troupe: #{profile.name} removed by #{actor.subject}", actor) do
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
        K8s.Client.get("troupe.dev/v1alpha1", "WorkerProfile", namespace: namespace(), name: profile.name)

      K8s.Client.run(conn, operation)
    end
  end
end
