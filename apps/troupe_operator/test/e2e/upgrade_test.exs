defmodule Troupe.E2E.UpgradeTest do
  @moduledoc """
  Upgrading the chart under a running session does not end it.

  This is the claim nothing in-process can make. A Helm upgrade re-applies every object
  in the release: Deployments roll, the operator reconciles what it finds, and a
  StatefulSet whose pod template changed would ordinarily replace its pods — which for a
  worker means ending every session on it. The promise is that it does not, and the
  mechanism is `updateStrategy: OnDelete`: a worker's pods are replaced when somebody
  deletes them and never because a rollout happened.

  Asserted against the pod's identity rather than against an absence of errors. The same
  pod, with the same uid and no restarts, still holding the session — a test that only
  checked the session was `active` afterwards would pass on a pod that had been replaced
  and the session restored, which is a different and much slower promise.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 900_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  test "helm upgrade leaves a running session where it was", context do
    created = Plane.call!("session.create", %{"profile" => context.profile})
    id = created["session_id"]
    on_exit(fn -> Plane.call("session.erase", %{"session_id" => id}) end)

    namespace = World.worker_namespace(context.profile)
    pod = World.pod(namespace, "app.kubernetes.io/name=troupe-worker")
    before = identity(namespace, pod)
    epoch = Plane.call!("session.get", %{"session_id" => id})["epoch"]

    # The upgrade. Not a no-op: a value is changed so that every template renders
    # differently and Helm has something to apply, which is what an upgrade in anger
    # looks like and what a no-op would not test.
    assert {output, 0} = World.helm(["upgrade", "troupe", "charts/troupe", "--namespace", World.namespace(), "--values", "dev/kind/values.yaml", "--set", "commonLabels.e2e=#{System.unique_integer([:positive])}", "--wait", "--timeout", "5m"]),
           "helm upgrade failed"

    assert output =~ "STATUS: deployed"

    # The same pod. Same uid, so it is not a replacement wearing the same name; no
    # restarts, so the container did not die and come back inside it.
    assert identity(namespace, pod) == before,
           "the worker pod was replaced by an upgrade; every session on it ended"

    # And the session is where it was, on the same epoch — a restore would have bumped it,
    # which is how this tells "it kept running" from "it was brought back".
    session = Plane.call!("session.get", %{"session_id" => id})
    assert session["state"] == "active"
    assert session["epoch"] == epoch

    # Reachable, which is the part a person would notice. The plane still hands back an
    # endpoint and the pod still answers on it.
    reopened = Plane.call!("session.open", %{"session_id" => id})
    assert reopened |> Plane.attach!() |> Plane.history!(id) != []
  end

  # uid and restart count together: one says it is the same object, the other says the
  # process inside it did not die.
  defp identity(namespace, pod) do
    World.kubectl!([
      "get",
      "pod",
      "-n",
      namespace,
      pod,
      "-o",
      "jsonpath={.metadata.uid}/{.status.containerStatuses[0].restartCount}"
    ])
  end
end
