defmodule Troupe.Plane.Provision do
  @moduledoc """
  Turning a profile into a `WorkerProfile`, or reading one, depending on who holds it.

  **Direct.** The plane writes the custom resource itself, from its row. Its
  ServiceAccount may create, update and delete `WorkerProfile` and `TeamVolume` in
  `troupe-system` and read `TroupePolicy` — and nothing else, which is a thing to confirm
  with `kubectl auth can-i` rather than to read off an RBAC file and believe.

  **GitOps.** A repository holds the resources and something else — Flux — applies them;
  the plane never writes git (Decision 736). Its rows follow the cluster
  (`Troupe.Plane.Gitops.Profiles`), and it writes only the three fields that are
  projections of its own state and that no repository could know: `spec.replicas` (the
  scaler), `spec.teams` (the grants) and `spec.mcpServers` (the channel's bundle). It
  writes them with server-side apply as the same field manager direct mode uses, so the
  first such write gives up every other field the plane once wrote, and the repository's
  applier is left the only owner of the rest. A repository manifest leaves the three out;
  `repository_manifest/1` is what one looks like.

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
  upgraded plane write those profiles again when nothing else would. Direct mode only: a
  repository pins its images, and a release reaches its workers by a commit.
  """

  alias Troupe.Plane.{Bundles, ClusterPolicy, Fleet, Gitops, Identity, Settings}
  alias Troupe.Plane.Fleet.{Profile, Provisioner, SizeClass}
  alias Troupe.Policy
  alias Troupe.Protocol.Error
  alias Troupe.WorkerProfile

  @release "release"

  # Who the plane is to the API server when it writes a profile: the whole resource in
  # direct mode, its three fields in GitOps mode. One name for both, so the first GitOps
  # write gives up what direct mode took (Decision 736).
  @manager "troupe-plane"
  @upgrade_manager "troupe-plane-upgrade"

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

  @doc """
  What keeps a profile from calling the servers its bundle marks `client_credentials` as
  itself (Decision 747), one sentence each: such a server with no identity in the
  profile's `mcpIdentities`, and an identity missing its client or key or otherwise broken.

  Reported, as the operator's `MCPIdentityMissing` says it, and not refused: the bundle
  and the profile are written by different people at different times, and either may be
  first. The servers are the channel's current bundle's rather than the resource's, so the
  answer is the same before the projection has been written. The plane holds nothing here
  that is secret, because there is nothing secret in either.
  """
  @spec identity_problems(Profile.t() | map()) :: [String.t()]
  def identity_problems(profile) do
    spec = Map.put(spec_map(profile), "mcpServers", Bundles.mcp_servers(channel_of(profile)))
    WorkerProfile.identity_problems(WorkerProfile.from_resource(%{"spec" => spec}))
  end

  defp channel_of(%Profile{config_bundle_channel: channel}), do: channel

  defp channel_of(attrs) do
    get(attrs, :config_bundle_channel) || spec_map(attrs)["configBundleChannel"] || "stable"
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

  # A row read from a resource in GitOps mode already carries the resource's numbers, and
  # a class merged over them would be the plane's opinion of a document it does not own:
  # the verdict would judge sizes the cluster is not running. So there the class decides
  # nothing and the spec is the resource's, with the image and the scaler's count.
  defp spec_of(%Profile{} = profile) do
    case mode() do
      :gitops -> Map.merge(profile.spec || %{}, own_spec(profile))
      :direct -> Map.merge(profile.spec || %{}, base_spec(profile))
    end
  end

  defp spec_of(%{} = attrs),
    do: attrs |> Map.get(:spec, Map.get(attrs, "spec", %{})) |> Map.merge(base_spec(attrs))

  # The seven fields that left the admin surface, written here from the one word that
  # replaced them. Merged *over* the profile's own `spec` map on purpose: a class is the
  # answer, and a hand-written `sessionsPerPod` kept beside it would be a profile with two
  # opinions about the same number.
  defp base_spec(source) do
    source
    |> own_spec()
    |> Map.merge(SizeClass.spec(get(source, :size_class)))
    |> Map.put("storage", storage_spec(source))
  end

  defp own_spec(source) do
    %{"image" => image_spec(get(source, :image)), "replicas" => get(source, :replicas)}
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

  Asked of the cluster, because the resource there is what the plane wrote. Only direct
  mode asks: in GitOps mode the repository names the image and the plane moves nothing.
  """
  @spec current_image(Profile.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def current_image(%Profile{} = profile) do
    case live_resource(profile) do
      {:ok, resource} -> {:ok, image_of(resource)}
      # Never written, which is as different from any image as a resource can be.
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
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
  Whether a profile's workers are pods, which a `WorkerProfile` in the cluster makes.

  A profile whose workers are machines (`ssh`) needs nothing there: they are registered,
  and the worker on each dials the plane. A resource for it would have the operator run
  pods for it as well, on a profile whose workers are meant to be elsewhere.
  """
  @spec in_cluster?(Profile.t()) :: boolean()
  def in_cluster?(%Profile{} = profile), do: Provisioner.for(profile) == Provisioner.Kubernetes

  @doc """
  Put a profile into the cluster, whichever way this plane does that.

  Direct mode applies the whole resource and answers `:applied`. GitOps mode writes the
  plane's three fields onto the resource the repository put there and answers
  `:projected`, or `:unchanged` where the resource already says what the plane would
  write; it never makes a resource, so a profile with none is `{:error, :no_resource}`.

  A profile whose workers are not pods (`in_cluster?/1`) has no resource in direct mode:
  one left from before it was a machine's, or from before this was asked, is taken away,
  and the answer is `:not_in_cluster`. In GitOps mode the repository holds its resource like
  any other's, and the count the plane writes onto it is none (`projection/1`). Decision
  738.
  """
  @spec apply(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(%Profile{} = profile, actor) do
    case {mode(), in_cluster?(profile)} do
      {:direct, false} ->
        direct_elsewhere(profile, actor)

      {:direct, true} ->
        with :ok <- resolvable(profile), do: direct_apply(profile, actor)

      {:gitops, _pods} ->
        with :ok <- resolvable(profile), do: gitops_project(profile)
    end
  end

  # `spec.image` is the one field the resource cannot be without, and a profile following
  # a release this plane cannot name would render without it. Refused here, by name, rather
  # than left for the API server to refuse as a schema error.
  defp resolvable(profile) do
    if follows_release?(profile) and is_nil(release_image()),
      do: {:error, :no_worker_image},
      else: :ok
  end

  @doc """
  Take one out again. Direct mode only: in GitOps mode a profile goes when its manifest
  leaves the repository, and the plane deletes nothing a repository put in the cluster.
  """
  @spec remove(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def remove(%Profile{} = profile, actor) do
    case mode() do
      :direct -> direct_delete(profile, actor)
      :gitops -> {:error, :managed_by_gitops}
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

  @doc "The manifest a profile becomes in direct mode: the whole resource, from the row."
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

  # -- what a repository holds ------------------------------------------------

  # The fields that are projections of the plane's own state: how many workers the
  # sessions need, which teams' volumes the grants give, and the MCP servers the channel's
  # bundle names. No repository could know them, so in GitOps mode they are the plane's
  # to write and a manifest leaves them out.
  @projected ~w(replicas teams mcpServers)

  # The plane's answers that the resource has no field for, carried as annotations so a
  # repository can give them. The operator reads none of them.
  @max_sessions "troupe.dev/max-sessions"
  @warm_workers "troupe.dev/warm-workers"
  @provisioner "troupe.dev/provisioner"

  @doc "The spec fields the plane writes in GitOps mode, and a repository leaves out."
  @spec projected_fields() :: [String.t()]
  def projected_fields, do: @projected

  @doc "The annotations a repository gives the plane's own answers in: ceiling, warm, substrate."
  @spec answer_annotations() :: %{atom() => String.t()}
  def answer_annotations,
    do: %{max_sessions: @max_sessions, warm_workers: @warm_workers, provisioner: @provisioner}

  @doc """
  The three projected fields as the plane would write them now.

  `mcpServers` from the channel's current bundle rather than from the row: the bundle is
  their one source (Decision 736 keeps it so), and reading it here means a profile a
  repository has only just added gets its servers without waiting for the next publish.

  `replicas` is none for a profile whose workers are machines: the operator makes a
  StatefulSet of whatever the resource says, and the row's count is of machines.
  """
  @spec projection(Profile.t()) :: map()
  def projection(%Profile{} = profile) do
    %{
      "replicas" => if(in_cluster?(profile), do: profile.replicas, else: 0),
      "teams" => teams_of(profile),
      "mcpServers" => Bundles.mcp_servers(profile.config_bundle_channel)
    }
  end

  @doc """
  The manifest a repository would hold for a profile: what bootstrapping one from a
  running plane commits (`admin.profiles.export`).

  The resource without anything the plane writes or the cluster keeps — no `replicas`,
  `teams` or `mcpServers`, no status, no labels of the plane's — and with the plane's own
  answers as annotations. An image of `release` is written as the image it resolves to,
  because a repository pins what it runs and moves it by a commit.
  """
  @spec repository_manifest(Profile.t()) :: map()
  def repository_manifest(%Profile{} = profile) do
    spec =
      profile
      |> spec_of()
      |> Map.drop(@projected)
      |> Map.put_new("configBundleChannel", profile.config_bundle_channel)

    metadata =
      %{"name" => profile.name, "namespace" => namespace()}
      |> then(fn metadata ->
        case answers(profile) do
          empty when empty == %{} -> metadata
          annotations -> Map.put(metadata, "annotations", annotations)
        end
      end)

    %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => metadata,
      "spec" => spec
    }
  end

  # Only the ones that say something: no ceiling, none kept warm and the Kubernetes
  # provisioner are what a profile with no annotation already is.
  defp answers(profile) do
    %{
      @max_sessions => profile.max_sessions && to_string(profile.max_sessions),
      @warm_workers => if((profile.warm_workers || 0) > 0, do: to_string(profile.warm_workers)),
      @provisioner => if(profile.provisioner not in [nil, "kubernetes"], do: profile.provisioner)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # -- direct -----------------------------------------------------------------

  defp direct_apply(profile, _actor) do
    with {:ok, conn} <- connection() do
      operation = K8s.Client.apply(manifest(profile), field_manager: @manager, force: true)

      case K8s.Client.run(conn, operation) do
        {:ok, applied} ->
          {:ok, %{mode: :direct, state: :applied, generation: generation(applied)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Nothing to write, and nothing to leave behind: a plane with no cluster has none to
  # take away either.
  defp direct_elsewhere(profile, actor) do
    case direct_delete(profile, actor) do
      {:ok, _deleted} -> {:ok, %{mode: :direct, state: :not_in_cluster}}
      {:error, :no_cluster} -> {:ok, %{mode: :direct, state: :not_in_cluster}}
      {:error, reason} -> {:error, reason}
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

  @doc """
  How the plane reaches the API server, or `{:error, :no_cluster}`.

  A plane with no cluster is a plane under test or a plane whose panel is being used to
  draft profiles. Saying so beats pretending it wrote something.
  """
  @spec connection() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def connection do
    case Application.get_env(:troupe_plane, :k8s_conn) do
      nil -> {:error, :no_cluster}
      {module, function, args} -> Kernel.apply(module, function, args)
      conn -> {:ok, conn}
    end
  end

  @doc "The namespace the plane's `WorkerProfile` resources live in."
  @spec namespace() :: String.t()
  def namespace, do: Application.get_env(:troupe_plane, :namespace, "troupe-system")

  # -- gitops -----------------------------------------------------------------

  defp gitops_project(profile) do
    case live_resource(profile) do
      {:ok, resource} -> project(profile, resource)
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> {:error, :no_resource}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Write the plane's three fields onto a profile's resource, where they are not what it
  already says.

  Only onto a resource something else holds, and only where nothing else writes those
  three (`ownership/1`): the first is what keeps a write of three fields from taking the
  rest away, and the second is what keeps the plane and a repository from putting back
  each other's number at every apply.
  """
  @spec project(Profile.t(), map()) :: {:ok, map()} | {:error, term()}
  def project(%Profile{} = profile, resource) do
    wanted = projection(profile)

    with :ok <- writable(resource) do
      if projected?(resource, wanted),
        do: {:ok, %{mode: :gitops, state: :unchanged, generation: generation(resource)}},
        else: write_projection(profile, wanted)
    end
  end

  defp write_projection(profile, wanted) do
    patch = %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => profile.name, "namespace" => namespace()},
      "spec" => wanted
    }

    with {:ok, conn} <- connection(),
         {:ok, applied} <-
           K8s.Client.run(conn, K8s.Client.apply(patch, field_manager: @manager, force: true)) do
      {:ok, %{mode: :gitops, state: :projected, generation: generation(applied)}}
    end
  end

  defp writable(resource) do
    case ownership(resource) do
      :held -> :ok
      :plane_only -> {:error, :not_held_by_repository}
      {:foreign, fields} -> {:error, {:written_elsewhere, fields}}
    end
  end

  # Compared as the operator reads them, so a default the API server filled in — a team's
  # `mode`, a server's `credentialMode` — is not a difference, and the plane does not write
  # the same three fields on every pass for ever.
  defp projected?(resource, wanted), do: parsed(resource["spec"] || %{}) == parsed(wanted)

  defp parsed(spec) do
    profile = WorkerProfile.from_resource(%{"spec" => Map.take(spec, @projected)})
    {profile.replicas, profile.teams, profile.mcp_servers}
  end

  @doc """
  Who holds a profile's resource, as far as a write of the plane's three fields cares.

    * `:held` — something other than the plane owns its image: the repository's applier,
      or a person with `kubectl`. A write of three fields leaves the rest to them.
    * `:plane_only` — only the plane ever wrote it: a resource from direct mode that no
      repository has taken over yet. Writing three fields would give up the rest, and with
      nobody else owning them the API server would take them away — which for `image` is
      a write it refuses, and for anything optional is a field that silently goes.
    * `{:foreign, fields}` — something else writes one of the plane's three, and would put
      its own value back at every apply, and the plane its own after.

  Read from `metadata.managedFields`. A resource that carries none is not what an API
  server answers, and is taken as held.
  """
  @spec ownership(map()) :: :held | :plane_only | {:foreign, [String.t()]}
  def ownership(resource) do
    foreign =
      for field <- @projected,
          Enum.any?(Gitops.managers(resource, ["spec", field]), &(not Gitops.plane?(&1))),
          do: "spec." <> field

    cond do
      foreign != [] -> {:foreign, foreign}
      not Gitops.tracked?(resource) -> :held
      Enum.any?(Gitops.managers(resource, ["spec", "image"]), &(not Gitops.plane?(&1))) -> :held
      true -> :plane_only
    end
  end

  @doc """
  The conditions a panel shows for a profile, or `nil` where they are unknown.

  Read from the cluster where there is one, because the operator is what sets them and a
  plane inventing its own would be a second opinion about the same question. None is an
  answer: a plane with no cluster, or a profile the operator has not reconciled yet. A
  cluster that could not be asked is not, and says so rather than looking like none.
  """
  @spec conditions(Profile.t()) :: [map()] | nil
  def conditions(%Profile{} = profile) do
    case live_resource(profile) do
      {:ok, resource} -> get_in(resource, ["status", "conditions"]) || []
      {:error, :no_cluster} -> []
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> []
      {:error, _reason} -> nil
    end
  end

  @doc """
  The count a profile's resource asks for, read as the operator reads it, or the error that
  kept it from being read: none where the cluster has no such resource, or the plane no
  cluster.
  """
  @spec replicas(Profile.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def replicas(%Profile{} = profile) do
    with {:ok, resource} <- live_resource(profile) do
      {:ok, WorkerProfile.from_resource(resource).replicas}
    end
  end

  @doc """
  Where a profile's upgrade stands, as the cluster holds it: the pods the operator reports
  on an older revision (`status.podsBehind`), and the drains the plane has recorded as
  finished (the `troupe.dev/drained` annotation). Decision 726.
  """
  @spec upgrade(Profile.t()) ::
          {:ok, %{behind: [map()], drained: %{String.t() => String.t()}}} | {:error, term()}
  def upgrade(%Profile{} = profile) do
    with {:ok, resource} <- live_resource(profile) do
      {:ok, %{behind: WorkerProfile.pods_behind(resource), drained: WorkerProfile.drained(resource)}}
    end
  end

  @doc """
  Record which of a profile's pods have finished draining, with the revision each ran,
  replacing what was recorded before. The operator deletes such a pod and the StatefulSet
  makes it again on the new revision.

  Its own field manager, so the annotation is this record's alone: `apply/2` writes the
  resource as the plane's `troupe-plane` and would otherwise take it away again on every
  write, and an empty record takes it away here. An annotation and not the status,
  because the status is the operator's and the plane's grant is on the resource.

  The same holds when a repository's applier holds the resource (Decision 736). Flux
  applies server-side as its own field manager and owns only the fields its manifest
  names, so an annotation the manifest leaves out is nobody's but this record's and
  survives every apply. A manifest that names it would make Flux its co-owner and put the
  committed value back at every reconcile, which is why `repository_manifest/1` and the
  export never carry it.
  """
  @spec record_drained(Profile.t(), %{String.t() => String.t()}) :: :ok | {:error, term()}
  def record_drained(%Profile{} = profile, drained) do
    annotations =
      if drained == %{},
        do: %{},
        else: %{WorkerProfile.drained_annotation() => WorkerProfile.encode_drained(drained)}

    patch = %{
      "apiVersion" => "troupe.dev/v1alpha1",
      "kind" => "WorkerProfile",
      "metadata" => %{"name" => profile.name, "namespace" => namespace(), "annotations" => annotations}
    }

    with {:ok, conn} <- connection(),
         {:ok, _applied} <-
           K8s.Client.run(conn, K8s.Client.apply(patch, field_manager: @upgrade_manager, force: true)) do
      :ok
    end
  end

  # An exit is an answer too. The client calls processes of its own, and one that is not
  # there exits in whoever asked, which is the Workers page once a second: caught here, it
  # is a cluster that did not answer rather than a page that goes down.
  defp live_resource(profile) do
    with {:ok, conn} <- connection() do
      operation =
        K8s.Client.get("troupe.dev/v1alpha1", "WorkerProfile",
          namespace: namespace(),
          name: profile.name
        )

      K8s.Client.run(conn, operation)
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
