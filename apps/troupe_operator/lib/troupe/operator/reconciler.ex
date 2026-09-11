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

  alias Troupe.Operator.{Names, Policy, Profile, Resources, Settings, Status}

  require Logger

  # Only the kinds the operator creates. Listing everything in the namespace would make
  # the operator responsible for objects it never made.
  @prunable [
    {"v1", "Service"},
    {"v1", "PersistentVolumeClaim"},
    {"networking.k8s.io/v1", "Ingress"},
    {"networking.k8s.io/v1", "NetworkPolicy"},
    {"policy/v1", "PodDisruptionBudget"}
  ]

  @field_manager "troupe-operator"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

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

    # The namespace first and on its own: nothing else in the list can be created
    # before it exists. Everything after that is independent and goes out together.
    {namespace_resource, rest} = Enum.split_with(desired, &(&1["kind"] == "Namespace"))
    applied = Bonny.Resource.apply_async(namespace_resource, conn, apply_opts())
    applied = applied ++ Bonny.Resource.apply_async(rest, conn, apply_opts())

    failures = Enum.filter(applied, &match?({_resource, {:error, _}}, &1))
    pruned = prune(conn, profile, policy, desired)

    status = status_for(resource, desired, failures, pruned, namespace_of(desired))
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
