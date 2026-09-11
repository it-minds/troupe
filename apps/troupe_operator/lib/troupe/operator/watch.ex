defmodule Troupe.Operator.Watch do
  @moduledoc """
  The Bonny operator: what to watch, and what every event passes through.

  Bonny supplies the parts that are the same in every operator and easy to get subtly
  wrong — a watch that resumes from the right resource version, a periodic resync that
  catches what a missed watch event would have, leader election through a Kubernetes
  `Lease` so only one replica reconciles — and this says what to do with what it
  delivers.

  The pipeline is two steps: skip events that only restated a generation already
  handled, then hand the resource to its reconciler. Nothing is applied here — the
  reconciler does its own applying, because a pass can also be started by the resync or
  by one of the operator's own objects being deleted from under it, and all three want
  the same thing to happen.
  """

  use Bonny.Operator, default_watch_namespace: "troupe-system"

  alias Troupe.Operator.Controller

  step Bonny.Pluggable.SkipObservedGenerations
  step :delegate_to_controller

  @impl Bonny.Operator
  def controllers(namespace, _opts) do
    [
      %{
        query: K8s.Client.watch("troupe.dev/v1alpha1", "WorkerProfile", namespace: namespace),
        controller: Controller.WorkerProfile
      },
      %{
        query: K8s.Client.watch("troupe.dev/v1alpha1", "TeamVolume", namespace: namespace),
        controller: Controller.TeamVolume
      }
    ]
  end

  # The CRDs are in the Helm chart, hand-written, because they are read by people and
  # by a `ValidatingAdmissionPolicy` that has to agree with them field for field.
  # Generating them from here would give the chart a second author.
  @impl Bonny.Operator
  def crds, do: []
end
