defmodule Troupe.Operator.Controller.WorkerProfile do
  @moduledoc """
  Where a `WorkerProfile` event enters the operator.

  Thin on purpose: it hands the resource to that resource's own reconciler and returns
  what comes back. Everything interesting — the policy check, the manifests, the
  conditions — is in the reconciler, and the reconciler is level-triggered, so this
  does not care which action brought the event.

  Deletion is the exception. A profile's objects live in their own namespace and cannot
  carry an owner reference back to it — owner references may not cross namespaces — so
  deleting the profile deletes the namespace, and Kubernetes takes the rest with it.
  """

  use Bonny.ControllerV2

  alias Troupe.Operator.{Names, Reconcilers}
  alias Troupe.Policy

  require Logger

  step :handle_event

  @spec handle_event(Bonny.Axn.t(), keyword()) :: Bonny.Axn.t()
  def handle_event(%Bonny.Axn{action: :delete} = axn, _opts) do
    delete_namespace(axn)
    Reconcilers.forget(axn.resource)
    axn
  end

  def handle_event(axn, _opts) do
    Reconcilers.reconcile(axn.conn, axn.resource)
    axn
  end

  # The prefix comes from the policy, so a namespace is only deleted when the policy
  # that named it can still be read. Guessing it would be a way to delete the wrong
  # namespace on the day the policy changed.
  defp delete_namespace(axn) do
    name = get_in(axn.resource, ["metadata", "name"])
    policy_name = System.get_env("TROUPE_POLICY_NAME") || "default"
    query = K8s.Client.get("troupe.dev/v1alpha1", "TroupePolicy", name: policy_name)

    case K8s.Client.run(axn.conn, query) do
      {:ok, resource} ->
        policy = Policy.from_resource(resource)
        namespace = Names.namespace(policy.namespace_prefix, name)
        Logger.info("troupe operator: #{name} was deleted, removing namespace #{namespace}")
        K8s.Client.run(axn.conn, K8s.Client.delete("v1", "Namespace", name: namespace))

      {:error, reason} ->
        Logger.warning("troupe operator: cannot remove #{name}'s namespace: #{inspect(reason)}")
    end
  end
end
