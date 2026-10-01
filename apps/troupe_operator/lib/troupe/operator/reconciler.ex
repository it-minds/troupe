defmodule Troupe.Operator.Reconciler do
  @moduledoc """
  One resource's reconciler, and the whole of one pass.

  Level-triggered and idempotent: every pass reads the policy, computes what the
  resource implies, applies it, deletes what is no longer wanted, and writes what it
  found into the resource's status. Nothing here remembers what it did last time, which
  is why a crash costs a reconcile rather than a repair, and why two passes cannot
  produce two of anything.

  Self-contained on purpose. A pass can be started by a watch event, by the periodic
  resync, or by something the operator manages being deleted from under it — and all
  three want the same thing to happen, so none of them should have to assemble a
  pipeline first.

  What it keeps between passes is the little that reconciliation cannot see: how many
  passes there have been, and when the last one was. Those are about the history of a
  profile rather than its current state.
  """

  use GenServer

  alias Troupe.Operator.{Names, Resources, Settings, Status}
  alias Troupe.Policy
  alias Troupe.WorkerProfile, as: Profile
  alias Troupe.WorkerProfile.Reach

  require Logger

  # Only the kinds the operator creates. Listing everything in the namespace would make
  # the operator responsible for objects it never made.
  #
  # The `CiliumNetworkPolicy` is written only while `ciliumAvailable` is set, so switching
  # it off has to take the policy away, or the profile says `NoCilium` beside FQDN rules
  # that are still there. A cluster that never had Cilium has no such kind, and listing it
  # fails: `list_managed/4` takes that as nothing to prune, like any listing that fails.
  @prunable [
    {"v1", "Service"},
    {"v1", "PersistentVolumeClaim"},
    {"v1", "ConfigMap"},
    {"networking.k8s.io/v1", "Ingress"},
    {"networking.k8s.io/v1", "NetworkPolicy"},
    {"policy/v1", "PodDisruptionBudget"},
    {"cilium.io/v2", "CiliumNetworkPolicy"}
  ]

  @field_manager "troupe-operator"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The kinds a pass deletes once a profile no longer implies them, as `{apiVersion, kind}`."
  @spec prunable() :: [{String.t(), String.t()}]
  def prunable, do: @prunable

  @doc "What this reconciler has done, for tests and diagnostics."
  @spec info(GenServer.server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @impl GenServer
  def init(opts) do
    key = Keyword.fetch!(opts, :key)
    Process.set_label("troupe reconcile #{inspect(key)}")
    {:ok, %{key: key, kind: Keyword.fetch!(opts, :kind), passes: 0, last_result: nil}}
  end

  @impl GenServer
  def handle_call({:reconcile, conn, resource}, _from, state) do
    result = run(conn, resource)
    {:reply, result, %{state | passes: state.passes + 1, last_result: result}}
  end

  def handle_call(:info, _from, state), do: {:reply, Map.take(state, [:key, :kind, :passes, :last_result]), state}

  # -- one pass ---------------------------------------------------------------

  defp run(conn, %{"kind" => "WorkerProfile"} = resource) do
    profile = Profile.from_resource(resource)

    case load_policy(conn) do
      {:ok, policy} -> reconcile_profile(conn, resource, profile, policy)
      {:error, reason} -> policy_missing(conn, resource, reason)
    end
  end

  # A TeamVolume is a declaration that a team has shared storage. The claims that bind
  # it into a namespace belong to the profiles that mount it — several profiles may be
  # granted the same team — so this records the name and leaves the binding to them.
  defp run(conn, %{"kind" => "TeamVolume"} = resource) do
    team = get_in(resource, ["spec", "team"])

    status =
      resource
      |> current_status()
      |> Map.put("claimName", Names.team_claim(team))
      |> Status.put("Ready", true, "Declared", "team volume for #{team} is declared")

    write_status(conn, resource, status)
    {:ok, :declared}
  end

  defp run(_conn, _resource), do: {:ok, :ignored}

  defp reconcile_profile(conn, resource, profile, policy) do
    case Policy.violations(profile, policy) do
      [] -> apply_profile(conn, resource, profile, policy)
      violations -> refuse(conn, resource, violations)
    end
  end

  # The operator's own copy of the policy check. Not redundant with admission: this is
  # the one that still holds when admission is unavailable, when the policy tightened
  # after a profile was already admitted, or when someone edited the resource while the
  # policy was absent. Nothing is created — a profile outside policy gets no namespace,
  # no pods, and no chance to run.
  defp refuse(conn, resource, violations) do
    message = Enum.map_join(violations, "; ", &Policy.describe/1)
    Logger.warning("troupe operator: refusing #{name_of(resource)}: #{message}")

    status =
      resource
      |> current_status()
      |> Status.put("PolicyViolation", true, "OutsidePolicy", message, generation(resource))
      |> Status.put("Ready", false, "PolicyViolation", message, generation(resource))

    write_status(conn, resource, status)
    {:error, {:policy_violation, violations}}
  end

  defp apply_profile(conn, resource, profile, policy) do
    settings = Settings.from_env()
    desired = Resources.for_profile(profile, policy, settings)
    namespace = namespace_of(desired)
    missing = missing_secrets(conn, profile, settings, namespace)
    upgrade = upgrade(conn, policy, profile, Profile.drained(resource))

    # The namespace first and on its own: nothing else in the list can be created
    # before it exists. Everything after that is independent and goes out together.
    {namespace_resource, rest} = Enum.split_with(desired, &(&1["kind"] == "Namespace"))
    applied = Bonny.Resource.apply_async(namespace_resource, conn, apply_opts())
    applied = applied ++ Bonny.Resource.apply_async(rest, conn, apply_opts())

    failures = Enum.filter(applied, &match?({_resource, {:error, _}}, &1))
    pruned = prune(conn, profile, policy, desired)

    status =
      resource
      |> status_for(desired, failures, pruned, namespace)
      |> egress_status(desired, failures, generation(resource))
      |> secret_status(missing, generation(resource))
      |> identity_status(Profile.identity_problems(profile), generation(resource))
      |> upgrade_status(upgrade, generation(resource))
      |> endpoint_status(profile, settings, generation(resource))

    write_status(conn, resource, status)

    if failures == [] do
      {:ok, %{applied: length(applied), pruned: length(pruned)}}
    else
      {:error, {:apply_failed, Enum.map(failures, fn {r, e} -> {name_of(r), e} end)}}
    end
  end

  defp apply_opts, do: [field_manager: @field_manager, force: true]

  defp status_for(resource, desired, [], pruned, namespace) do
    resource
    |> current_status()
    |> Map.put("namespace", namespace)
    |> Map.put("observedGeneration", generation(resource))
    |> Status.put("PolicyViolation", false, "WithinPolicy", "within TroupePolicy", generation(resource))
    |> Status.put(
      "Ready",
      true,
      "Reconciled",
      "#{length(desired)} resources reconciled#{pruned_suffix(pruned)}",
      generation(resource)
    )
  end

  defp status_for(resource, _desired, failures, _pruned, namespace) do
    message =
      Enum.map_join(failures, "; ", fn {r, {:error, error}} ->
        "#{r["kind"]}/#{name_of(r)}: #{inspect(error)}"
      end)

    resource
    |> current_status()
    |> Map.put("namespace", namespace)
    |> Status.put("Ready", false, "ApplyFailed", message, generation(resource))
  end

  # Whether the allowlist is enforced on the wire or only checked, which the plane reads
  # to say which guarantee a profile's workers have. Its own condition rather than part of
  # `Ready`: a profile without Cilium reconciled perfectly well, and what it lacks is a
  # guarantee, not a resource.
  defp egress_status(status, desired, failures, generation) do
    failed = Enum.map(failures, fn {resource, _error} -> resource end)
    {holds?, reason, message} = Resources.egress_by_hostname(desired, failed)
    Status.put(status, "EgressByHostname", holds?, reason, message, generation)
  end

  # One of the profile's own endpoints that its workers cannot reach: without Cilium the
  # NetworkPolicy reaches outside the cluster only public addresses on 443 and 80. Reported
  # rather than refused, and beside `Ready`, as a missing secret is: the profile reconciled,
  # and in gitops mode it was applied by something nothing here can refuse, so this is how
  # it reads as broken rather than as a session's first call timing out (Decision 749).
  defp endpoint_status(status, _profile, %Settings{cilium_available: true}, generation) do
    message = "with Cilium a worker reaches each endpoint the profile names, by name or address"
    Status.put(status, "EndpointUnreachable", false, "Cilium", message, generation)
  end

  defp endpoint_status(status, profile, _settings, generation) do
    case Reach.unreachable(profile) do
      [] ->
        message =
          "the worker's NetworkPolicy admits every endpoint the profile names, as far as " <>
            "their URLs say"

        Status.put(status, "EndpointUnreachable", false, "Reachable", message, generation)

      found ->
        message = Reach.explain(found)
        Status.put(status, "EndpointUnreachable", true, "NoCilium", message, generation)
    end
  end

  # A secret the profile refers to and the cluster does not have. Reported rather than
  # refused: the reference may be right and the secret on its way, and a profile that
  # would not reconcile until every secret existed could not be created before them.
  # What it must not be is invisible — a pod that will not start because a Secret is
  # missing is a mystery unless somebody says so here.
  #
  # Looked for in the *worker's* namespace, because that is the only namespace a pod can
  # mount from. Checking the plane's namespace instead asked a question about a different
  # cluster object that merely shares a name: it called a secret sitting correctly beside
  # its pods missing, and would have called a genuinely absent one present the moment
  # something of that name existed in `troupe-system`. Both halves of that happened here.
  #
  # The object store is on the list for the same reason the pods are: a worker signs
  # every read and write of a session's log with those credentials, and one without them
  # signs with `nil` and dies inside the signer, a long way from the mistake.
  defp missing_secrets(conn, profile, settings, namespace) do
    [settings.object_store_secret_name | Profile.secret_names(profile)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&secret_exists?(conn, namespace, &1))
  end

  defp secret_exists?(conn, namespace, name) do
    operation = K8s.Client.get("v1", "Secret", namespace: namespace, name: name)
    match?({:ok, _secret}, K8s.Client.run(conn, operation))
  end

  defp secret_status(status, [], generation) do
    Status.put(status, "SecretMissing", false, "SecretsPresent", "every referenced secret exists", generation)
  end

  # `SecretMissing` and not `Ready: False`. The spec gives these separate conditions
  # because they are separate facts: `Ready` is the operator saying it reconciled what it
  # was asked to, and it did — the namespace, the StatefulSet and the rest all exist.
  # Whether the pods can *start* is the secret's business, and merging the two would make
  # a missing secret indistinguishable from an apply that failed.
  defp secret_status(status, missing, generation) do
    message = "missing secret(s): #{Enum.join(missing, ", ")}"
    Status.put(status, "SecretMissing", true, "SecretsMissing", message, generation)
  end

  # A server the bundle marks `client_credentials` that the profile gives no usable
  # identity (Decision 747). Reported beside `SecretMissing` and for the same reasons: the
  # bundle and the profile are written separately and either may come first, and the pods
  # run regardless, without that server's tools, until both are there.
  defp identity_status(status, [], generation) do
    Status.put(
      status,
      "MCPIdentityMissing",
      false,
      "IdentitiesPresent",
      "every server called with client credentials has an identity",
      generation
    )
  end

  defp identity_status(status, problems, generation) do
    Status.put(
      status,
      "MCPIdentityMissing",
      true,
      "IdentityMissing",
      Enum.join(problems, "; "),
      generation
    )
  end

  # A pod takes an image, config or volume change only when it is deleted, and it should
  # be deleted only once a drain has made its sessions dormant, so a profile whose pods
  # are on an older revision is *waiting* rather than broken. Saying which is the
  # difference between "give it a minute" and "something is wrong", so the message names
  # each pod and how far it has got; `podsBehind` is the same list for the plane, which
  # drains them (Decision 726).
  defp upgrade_status(status, %{behind: []}, generation) do
    status
    |> Map.put("podsBehind", [])
    |> Status.put("UpgradePending", false, "UpToDate", "every pod is on the current revision", generation)
  end

  defp upgrade_status(status, %{behind: behind} = upgrade, generation) do
    message =
      "#{length(behind)} pod(s) run an older revision: " <>
        Enum.map_join(behind, ", ", &"#{name_of(&1)} #{stage(&1, upgrade)}")

    status
    |> Map.put("podsBehind", for(pod <- behind, not replacing?(pod, upgrade), do: behind_entry(pod)))
    |> Status.put("UpgradePending", true, "WaitingForIdle", message, generation)
  end

  # Not Ready is taken for draining: a running worker's readiness says only that, and it
  # fails the moment a drain starts. Ready is a pod the plane has not drained yet, which it
  # does once the pod holds no active session.
  defp stage(pod, upgrade) do
    cond do
      replacing?(pod, upgrade) -> "is being replaced"
      drained?(pod, upgrade.drained) and not ready?(pod) -> "is drained and waits its turn"
      not ready?(pod) -> "is draining"
      true -> "waits to be drained"
    end
  end

  # The uid as well as the name, so the plane drains the pod this was written about and
  # not its replacement, which has the same name and may enrol before the next pass.
  defp behind_entry(pod) do
    %{"pod" => name_of(pod)}
    |> put_unless_nil("uid", get_in(pod, ["metadata", "uid"]))
    |> put_unless_nil("revision", revision(pod))
  end

  defp replacing?(pod, upgrade), do: name_of(pod) == upgrade.replaced or terminating?(pod)

  # A StatefulSet on `OnDelete` reports the revision it wants, and each of its pods
  # carries the revision it was made from. Comparing them is how the operator knows a
  # restart is outstanding without tracking one itself.
  #
  # Against `updateRevision` alone. `currentRevision` is a rolling update's bookkeeping,
  # which `OnDelete` does not do, so it says nothing about the pods: a template put back
  # to the revision the StatefulSet still calls current makes the two equal while every
  # pod runs a later one.
  defp upgrade(conn, policy, profile, drained) do
    namespace = Names.namespace(policy.namespace_prefix, profile.name)
    name = Names.workload(policy.namespace_prefix, profile.name)
    operation = K8s.Client.get("apps/v1", "StatefulSet", namespace: namespace, name: name)

    with {:ok, set} <- K8s.Client.run(conn, operation),
         wanted when is_binary(wanted) <- get_in(set, ["status", "updateRevision"]),
         %{} = selector <- get_in(set, ["spec", "selector", "matchLabels"]),
         {:ok, pods} <- set_pods(conn, namespace, selector) do
      behind = Enum.reject(pods, &(revision(&1) == wanted))
      replaced = replace(conn, namespace, pods, behind, drained, get_in(set, ["spec", "replicas"]))
      %{behind: behind, drained: drained, replaced: replaced}
    else
      _ -> %{behind: [], drained: drained, replaced: nil}
    end
  end

  # The StatefulSet's own pods, by its own selector: the labels its template gives them.
  # They were once listed by the operator's marker, which only what the operator writes
  # itself carries and a pod does not, so the listing was always empty and the condition
  # said every pod was current while one still ran the old image.
  defp set_pods(conn, namespace, selector) do
    operation =
      "v1"
      |> K8s.Client.list("Pod", namespace: namespace)
      |> K8s.Operation.put_selector(K8s.Selector.label(selector))

    case K8s.Client.run(conn, operation) do
      {:ok, %{"items" => pods}} -> {:ok, Enum.sort_by(pods, &ordinal/1)}
      other -> other
    end
  end

  # Finishing the roll, which nothing else does: `OnDelete` recreates a pod on the new
  # revision, with the same volume, once it is deleted. Only a pod the plane has said is
  # empty is deleted, because only the plane knows that; the operator can see a pod that is
  # not Ready, which it is from the moment a drain starts, while its sessions are still
  # being sealed. So a pod goes when it is behind, the plane has recorded its drain
  # finished at the revision it still runs, and it is not Ready — a pod that restarted
  # since is Ready again, and may have been given a session.
  #
  # One at a time, and never while one is still going or has not been made again, so a
  # profile never has more than one pod missing; the highest ordinal first, as a
  # StatefulSet takes them. The disruption budget is not asked, because the pods deleted
  # here hold nothing it protects.
  defp replace(conn, namespace, pods, behind, drained, replicas) do
    settled? = not Enum.any?(pods, &terminating?/1) and length(pods) >= (replicas || 0)

    candidate =
      behind
      |> Enum.filter(&(drained?(&1, drained) and not ready?(&1)))
      |> Enum.max_by(&ordinal/1, fn -> nil end)

    if settled? and candidate do
      name = name_of(candidate)
      Logger.info("troupe operator: replacing #{namespace}/#{name}, drained on #{revision(candidate)}")

      case K8s.Client.run(conn, K8s.Client.delete("v1", "Pod", namespace: namespace, name: name)) do
        {:ok, _deleted} ->
          name

        {:error, reason} ->
          Logger.warning("troupe operator: could not replace #{namespace}/#{name}: #{inspect(reason)}")
          nil
      end
    end
  end

  defp drained?(pod, drained) do
    revision = revision(pod)
    is_binary(revision) and Map.get(drained, name_of(pod)) == revision
  end

  defp ready?(pod) do
    pod
    |> get_in(["status", "conditions"])
    |> List.wrap()
    |> Enum.any?(&match?(%{"type" => "Ready", "status" => "True"}, &1))
  end

  defp terminating?(pod), do: get_in(pod, ["metadata", "deletionTimestamp"]) != nil

  defp revision(pod), do: get_in(pod, ["metadata", "labels", "controller-revision-hash"])

  # `<set>-<ordinal>`, which is how a StatefulSet names its pods.
  defp ordinal(pod) do
    case pod |> name_of() |> to_string() |> String.split("-") |> List.last() |> Integer.parse() do
      {ordinal, ""} -> ordinal
      _other -> -1
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp pruned_suffix([]), do: ""
  defp pruned_suffix(pruned), do: ", #{length(pruned)} removed"

  # -- pruning ----------------------------------------------------------------

  # Delete what carries this operator's marker and is no longer wanted. This is how
  # scaling down removes the Ingress of a pod that no longer exists, and how dropping a
  # team removes the claim that bound its volume — neither of which an owner reference
  # could do, because owner references may not cross namespaces and these objects live
  # in a different one from the profile.
  defp prune(conn, profile, policy, desired) do
    namespace = Names.namespace(policy.namespace_prefix, profile.name)
    wanted = Resources.identities(desired)

    @prunable
    |> Enum.flat_map(&list_managed(conn, &1, namespace, profile.name))
    |> Enum.reject(&MapSet.member?(wanted, identity(&1)))
    |> Enum.map(fn resource ->
      Logger.info("troupe operator: pruning #{resource["kind"]}/#{name_of(resource)}")
      K8s.Client.run(conn, K8s.Client.delete(resource))
      identity(resource)
    end)
  end

  defp list_managed(conn, {api_version, kind}, namespace, profile) do
    selector =
      # The marker the operator puts on what it wrote itself. A StatefulSet copies its
      # selector onto the PVCs it creates for pods, so selecting on the profile label
      # alone would offer a live session's working copy for pruning.
      K8s.Selector.label({Names.managed_label(), "operator"})
      |> K8s.Selector.label({"troupe.dev/profile", profile})

    operation =
      api_version
      |> K8s.Client.list(kind, namespace: namespace)
      |> K8s.Operation.put_selector(selector)

    case K8s.Client.run(conn, operation) do
      {:ok, %{"items" => items}} ->
        Enum.map(items, &Map.merge(%{"apiVersion" => api_version, "kind" => kind}, &1))

      _ ->
        []
    end
  end

  # -- the policy -------------------------------------------------------------

  # Read on every pass rather than cached: an admin tightening the policy must take
  # effect on the next reconcile, not on the next restart.
  defp load_policy(conn) do
    name = System.get_env("TROUPE_POLICY_NAME") || "default"

    case K8s.Client.run(conn, K8s.Client.get("troupe.dev/v1alpha1", "TroupePolicy", name: name)) do
      {:ok, resource} -> {:ok, Policy.from_resource(resource)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Without a policy nothing is allowed, because "no policy" and "a policy that permits
  # everything" must not look the same.
  defp policy_missing(conn, resource, reason) do
    message = "no TroupePolicy could be read: #{inspect(reason)}"

    status =
      resource
      |> current_status()
      |> Status.put("PolicyViolation", true, "NoPolicy", message, generation(resource))
      |> Status.put("Ready", false, "NoPolicy", message, generation(resource))

    write_status(conn, resource, status)
    {:error, :no_policy}
  end

  # -- helpers ----------------------------------------------------------------

  defp write_status(conn, resource, status) do
    resource
    |> Map.put("status", status)
    |> Bonny.Resource.apply_status(conn, apply_opts())
  end

  defp current_status(resource), do: Map.get(resource, "status") || %{}

  defp namespace_of(resources) do
    resources |> Enum.find(&(&1["kind"] == "Namespace")) |> get_in(["metadata", "name"])
  end

  defp identity(resource) do
    {resource["apiVersion"], resource["kind"], name_of(resource)}
  end

  defp name_of(resource), do: get_in(resource, ["metadata", "name"])
  defp generation(resource), do: get_in(resource, ["metadata", "generation"])
end
