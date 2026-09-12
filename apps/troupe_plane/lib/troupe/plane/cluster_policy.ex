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

  This is fast feedback, not enforcement. The operator applies the same policy to the
  `WorkerProfile` the plane writes, and Cilium applies it to the packets.
  """

  alias Troupe.Policy

  require Logger

  @doc """
  The policy, or `nil` when none can be read.

  `:policy` in the application environment wins, because it is how a test or a plane
  without a cluster says what the policy is; otherwise the named `TroupePolicy` is read
  from the cluster.
  """
  @spec current() :: Policy.t() | nil
  def current do
    case Application.get_env(:troupe_plane, :policy) do
      nil -> from_cluster()
      resource -> Policy.from_resource(resource)
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
        Policy.from_resource(resource)

      {:error, reason} ->
        Logger.warning(
          "troupe plane: no TroupePolicy #{policy_name()} could be read: #{inspect(reason)}"
        )

        nil
    end
  end

  defp read({:error, _reason}), do: nil

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
