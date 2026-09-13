defmodule Troupe.Operator.Names do
  @moduledoc """
  Every name and address the operator produces, in one place.

  Names are an interface. A pod's DNS name is what a client connects to, its namespace
  is what its enrolment token proves, and its PVC name is what survives a rescheduling
  — so a name invented in three places is three chances to invent it differently. They
  are derived here, from the profile and the policy, and nowhere else.
  """

  @doc "The namespace a profile's workers live in, `<prefix><profile>`."
  @spec namespace(String.t(), String.t()) :: String.t()
  def namespace(prefix, profile), do: prefix <> profile

  @doc "The StatefulSet, headless Service and NetworkPolicy all share the profile's name."
  @spec workload(String.t(), String.t()) :: String.t()
  def workload(prefix, profile), do: prefix <> profile

  @doc "The ServiceAccount every pod of a profile runs as."
  @spec service_account() :: String.t()
  def service_account, do: "troupe-worker"

  @doc "One pod, by ordinal: the StatefulSet's own naming."
  @spec pod(String.t(), String.t(), non_neg_integer()) :: String.t()
  def pod(prefix, profile, ordinal), do: "#{workload(prefix, profile)}-#{ordinal}"

  @doc "The per-pod Service and Ingress, which are addressed by ordinal rather than by pod name."
  @spec pod_service(String.t(), non_neg_integer()) :: String.t()
  def pod_service(profile, ordinal), do: "#{profile}-#{ordinal}"

  @doc """
  Where a client reaches one pod: `<ordinal>-<profile>.workers.<domain>`.

  Per pod rather than per profile because a session lives on exactly one of them, and a
  load balancer that sent the second connection somewhere else would split a session's
  clients across pods that cannot see each other's state.

  **One label, joined by a hyphen, and that is the whole reason for the hyphen.** A DNS
  wildcard matches exactly one label, so `*.workers.<domain>` covers `0-dev.workers…`
  and would not have covered `0.dev.workers…`. With a dot, every new profile needs its
  own DNS record and its own certificate before any of its pods can be reached — which
  turns creating a profile in the panel into a change request. With a hyphen, one record
  and one wildcard certificate cover every profile there will ever be.

  `config/runtime.exs` composes the same name for the endpoint a pod reports to the
  plane. The two must agree, and they cannot share a function: `troupe_worker` does not
  depend on `troupe_operator` and must not start to.
  """
  @spec host(String.t(), non_neg_integer(), String.t()) :: String.t()
  def host(profile, ordinal, domain), do: "#{ordinal}-#{profile}.#{domain}"

  @doc """
  The audience a pod's key-manager token is projected for.

  Separate from the enrolment audience on purpose: a token minted for the key manager
  must not be presentable to the plane, and a token minted for the plane must not open
  a session key. Each is good in exactly one place.
  """
  @spec kms_audience() :: String.t()
  def kms_audience, do: "troupe-kms"

  @doc "The PVC a pod keeps its working copies on. One per pod, from the StatefulSet template."
  @spec data_volume() :: String.t()
  def data_volume, do: "data"

  @doc "The claim binding a team's shared volume into a profile's namespace."
  @spec team_claim(String.t()) :: String.t()
  def team_claim(team), do: "team-" <> team

  @doc "The claim binding the organisation-wide read-only volume."
  @spec org_claim() :: String.t()
  def org_claim, do: "org"

  @doc "The audience of the projected token a pod presents when it enrols."
  @spec enrolment_audience() :: String.t()
  def enrolment_audience, do: "troupe-plane"

  @doc """
  The labels that select a profile's pods.

  Also on everything else the operator creates, because a listing has to be able to
  find a profile's objects. Kept separate from `managed_labels/1` because a
  StatefulSet's selector is immutable: adding a label here later would mean deleting
  and recreating every workload.
  """
  @spec labels(String.t()) :: %{String.t() => String.t()}
  def labels(profile) do
    %{
      "app.kubernetes.io/name" => "troupe-worker",
      "app.kubernetes.io/instance" => profile,
      "app.kubernetes.io/managed-by" => "troupe-operator",
      "troupe.dev/profile" => profile
    }
  end

  @doc """
  The labels on objects the operator creates *directly*, which is what pruning selects.

  The distinction is not decorative. A StatefulSet copies its selector onto the PVCs it
  makes from its volume claim templates, so a pod's data volume — holding the working
  copies of live sessions — carries `labels/1` too. Pruning on that alone deleted one,
  once. This marker is on what the operator wrote and on nothing Kubernetes wrote for
  it.
  """
  @spec managed_labels(String.t()) :: %{String.t() => String.t()}
  def managed_labels(profile), do: Map.put(labels(profile), managed_label(), "operator")

  @doc "The label pruning selects on."
  @spec managed_label() :: String.t()
  def managed_label, do: "troupe.dev/managed"
end
