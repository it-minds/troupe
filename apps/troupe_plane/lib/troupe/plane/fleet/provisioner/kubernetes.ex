defmodule Troupe.Plane.Fleet.Provisioner.Kubernetes do
  @moduledoc """
  The operator, as it stands, behind the provisioner interface.

  Nothing here is new. `ensure/2` is the `WorkerProfile` write the scaler has always made,
  `drain/2` is the sequence `Troupe.Plane.Drain` has always driven, and `describe/1` reads
  the workers the plane already records. Extracting them changes no behaviour, which is the
  point of doing it first: a second implementation is only cheap if the first one is the
  interface rather than a special case beside it.

  The plane writes the resource and the operator reconciles it — or the plane commits the
  manifest and Flux applies it, which is `Troupe.Plane.Provision`'s business and not a
  second provisioner. Direct and GitOps are two ways of delivering the same document to the
  same substrate; that is a different question from which substrate it is.

  ## Every guarantee where there is Cilium, and this is the only one that can say so

  A pod gets the admission policy, the NetworkPolicy and a disruption budget, because the
  cluster enforces them whether or not the plane is running. That is what the rest of the
  design leans on, and it is why a profile provisioned any other way has to say what it is
  missing rather than leave somebody to assume.

  Egress by hostname is Cilium's, and a cluster need not have it. Where the operator has
  none it writes no FQDN rules, the allowlist is checked at admission and at every
  reconcile, and a worker reaches any public host on 443 and 80. So that one is not
  assumed: it is claimed only where the operator's `EgressByHostname` condition on the
  profile says it wrote the rules and the cluster took them, and otherwise the profile has
  `egress_checked_at_admission` in its place.
  """

  @behaviour Troupe.Plane.Fleet.Provisioner

  alias Troupe.Plane.{Drain, Fleet, Provision}
  alias Troupe.Plane.Fleet.Profile

  @impl true
  def name, do: "kubernetes"

  @impl true
  def guarantees(%Profile{} = profile) do
    [:admission_policy, :network_policy, egress(profile), :disruption_budget]
  end

  # Asked of the operator, per profile, because only it knows whether it has Cilium and
  # whether the policy applied. Silence is the weaker answer: a profile not reconciled
  # yet, a plane with no cluster to ask, and a bare profile that stands for Kubernetes in
  # general, which has no `WorkerProfile` to ask about.
  defp egress(%Profile{name: nil}), do: :egress_checked_at_admission

  defp egress(%Profile{} = profile) do
    reported? =
      profile
      |> Provision.conditions()
      |> Enum.any?(&match?(%{"type" => "EgressByHostname", "status" => "True"}, &1))

    if reported?, do: :fqdn_egress, else: :egress_checked_at_admission
  end

  @doc """
  Write the profile's `WorkerProfile`, which is how a pod comes to exist.

  The row is written before this is called and this is written from the row, so the number
  the plane believes and the number it asked for cannot differ: an apply that failed leaves
  a row the next tick tries again from. That ordering is the scaler's and is kept here.
  """
  @impl true
  def ensure(%Profile{} = profile, opts) do
    actor = Keyword.get(opts, :actor, %{subject: "system:scaler", role: :platform_admin})
    Provision.apply(profile, actor)
  end

  @doc """
  Drain the pod, and leave removing it to the operator.

  Deliberately: removing a StatefulSet pod is done by scaling the set, and anything else
  puts it back. The plane's part is to make the pod safe to remove and to say so.
  """
  @impl true
  def drain(worker, opts), do: Drain.pod(worker, opts)

  @doc """
  The workers this profile has, oldest ordinal first.

  From the plane's own rows rather than from the API server. A pod that has not enrolled is
  not yet a worker in any sense placement cares about, and asking Kubernetes would answer a
  different question — what exists — at the cost of a round trip on a path that runs every
  fifteen seconds.
  """
  @impl true
  def describe(%Profile{} = profile) do
    {:ok,
     profile.name
     |> Fleet.list_workers()
     |> Enum.map(
       &%{name: &1.pod_name, profile: &1.profile, address: &1.endpoint, ordinal: &1.ordinal}
     )}
  end
end
