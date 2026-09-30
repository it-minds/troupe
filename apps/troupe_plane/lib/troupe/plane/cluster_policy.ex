defmodule Troupe.Plane.ClusterPolicy do
  @moduledoc """
  The cluster's `TroupePolicy`, as the plane reads it.

  Two callers want it: `Troupe.Plane.Provision` checks a profile against it for fast
  feedback, and `Troupe.Plane.Bundles` refuses a bundle naming an MCP host the policy
  would not let a pod reach. Both read it here so there is one answer to "what does the
  policy say", and one place that knows where the document comes from.

  It comes from configuration when something has put it there — the tests, a plane
  drafting profiles without a cluster — and otherwise from the API server through the
  same client provisioning uses, read on every call rather than cached: it is a
  cluster-admin's document and a change to it should take effect without restarting
  the plane. A plane with no cluster and no configured policy has nothing to check
  against; it allows every host and says so once, because a check that silently
  refused everything would make a development plane unable to publish anything.

  In GitOps mode there is one answer and it is the resource (Decision 736): the
  repository holds the policy as it holds the profiles, and a document in the plane's
  configuration would be a second one nobody reviewed.

  This is fast feedback, not enforcement. The operator applies the same policy to the
  `WorkerProfile` the plane writes, and Cilium applies it to the packets.
  """

  alias Troupe.Plane.{Gitops, Provision}
  alias Troupe.Policy

  require Logger

  @doc """
  The policy, or `nil` when none can be read.

  `:policy` in the application environment wins in direct mode, because it is how a test
  or a plane without a cluster says what the policy is; otherwise, and always in GitOps
  mode, the named `TroupePolicy` is read from the cluster.
  """
  @spec current() :: Policy.t() | nil
  def current do
    case resource() do
      nil -> nil
      resource -> Policy.from_resource(resource)
    end
  end

  @doc """
  The policy document itself, from wherever `current/0` reads it, or `nil`: what the
  export turns into a manifest.
  """
  @spec resource() :: map() | nil
  def resource do
    case {Provision.mode(), Application.get_env(:troupe_plane, :policy)} do
      {:gitops, _configured} -> from_cluster()
      {_direct, nil} -> from_cluster()
      {_direct, resource} -> resource
    end
  end

  @doc """
  The policy as a repository would hold it, or `nil` where this plane can read none: a
  `TroupePolicy` with nothing in it the cluster or Helm keeps (`Gitops.strip/1`).

  For a repository that holds the policy as a manifest, which is a chart installed with
  `policy.install: false`. One installed by the chart's own template holds it in the
  chart's values instead, and those are already the repository's.
  """
  @spec export() :: map() | nil
  def export do
    case resource() do
      nil ->
        nil

      resource ->
        manifest =
          resource
          |> Map.put("apiVersion", "troupe.dev/v1alpha1")
          |> Map.put("kind", "TroupePolicy")
          |> Map.update(
            "metadata",
            %{"name" => policy_name()},
            &Map.put_new(&1, "name", policy_name())
          )
          |> Gitops.strip()

        name = manifest["metadata"]["name"]
        %{name: name, path: "policy/#{name}.yaml", notes: [], yaml: Gitops.yaml(manifest, [])}
    end
  end

  @doc """
  Whether the policy lets a pod reach `host`.

  `:egress_allowed` in the application environment, a function of a hostname, replaces
  the policy entirely when set — the seam a test uses to say "nothing is allowed"
  without building a policy document. Without a policy at all, every host is allowed
  and a warning is logged the first time.
  """
  @spec egress_allowed?(String.t()) :: boolean()
  def egress_allowed?(host) when is_binary(host) do
    case Application.get_env(:troupe_plane, :egress_allowed) do
      fun when is_function(fun, 1) -> fun.(host)
      nil -> allowed_by_policy?(host, current())
    end
  end

  defp allowed_by_policy?(_host, nil) do
    warn_once()
    true
  end

  defp allowed_by_policy?(host, %Policy{allowed_egress: patterns}) do
    Enum.any?(patterns, &Policy.matches?(host, &1))
  end

  defp from_cluster do
    case Application.get_env(:troupe_plane, :k8s_conn) do
      nil -> nil
      {module, function, args} -> module |> Kernel.apply(function, args) |> read()
      conn -> read({:ok, conn})
    end
  end

  defp read({:ok, conn}) do
    operation = K8s.Client.get("troupe.dev/v1alpha1", "TroupePolicy", name: policy_name())

    case K8s.Client.run(conn, operation) do
      {:ok, resource} ->
        readable()
        resource

      {:error, reason} ->
        unreadable(reason)
        nil
    end
  end

  defp read({:error, _reason}), do: nil

  # Said when it changes, not at every read. A GitOps plane reads the policy at every
  # pass, every fifteen seconds, and a warning each time buried the first — the one that
  # said something — under four a minute saying it again. A read that fails for another
  # reason than the last one did is a change too.
  @read {__MODULE__, :read}

  defp readable do
    if :persistent_term.get(@read, :readable) != :readable do
      :persistent_term.put(@read, :readable)
      Logger.info("troupe plane: the TroupePolicy #{policy_name()} can be read again")
    end
  end

  defp unreadable(reason) do
    state = {:unreadable, kind_of(reason)}

    if :persistent_term.get(@read, :readable) != state do
      :persistent_term.put(@read, state)

      Logger.warning(
        "troupe plane: no TroupePolicy #{policy_name()} could be read: #{inspect(reason)}"
      )
    end
  end

  # What kind of failure, rather than all of it, so that a reason carrying one request's
  # own details is not a new state at every read.
  defp kind_of(%K8s.Client.APIError{reason: reason}), do: reason
  defp kind_of(%{__struct__: module}), do: module
  defp kind_of(reason), do: reason

  # The same name the operator reads, from the same variable, so the plane and the
  # operator cannot be checking against two different documents.
  defp policy_name do
    System.get_env("TROUPE_POLICY_NAME") ||
      Application.get_env(:troupe_plane, :policy_name, "default")
  end

  defp warn_once do
    if not :persistent_term.get({__MODULE__, :warned}, false) do
      :persistent_term.put({__MODULE__, :warned}, true)

      Logger.warning(
        "troupe plane: no TroupePolicy is configured or reachable; every MCP host is allowed"
      )
    end
  end
end
