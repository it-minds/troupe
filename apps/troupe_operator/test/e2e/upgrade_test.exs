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

  And the roll still finishes: a pod on an older revision that holds no session is
  drained by the plane and replaced by the operator, with nobody deleting it by hand.
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

    # The upgrade: a new release revision, with its pre-upgrade hooks run again. The value
    # set here, `commonLabels`, is one no template reads, so every object renders as it did
    # and nothing the chart deploys changes; what this tests is that an upgrade as such,
    # hooks included, leaves a running session where it was. It does not test a change to a
    # template being applied: no value every template renders exists to change, and a
    # change that rolled the plane or the operator would be a different test.
    #
    # On the release's own values, as a person upgrading keeps them. `scripts/remote-up`
    # installs with the model gateway's host set into the policy's allowed egress; an
    # upgrade from `dev/kind/values.yaml` alone put the placeholder back, the TroupePolicy
    # stopped allowing the endpoint the shared profile calls, and every later write to that
    # WorkerProfile (a scale-down, a finished drain) was refused at admission, leaving the
    # profile where it stood for every test after this one.
    assert {output, 0} = World.helm(["upgrade", "troupe", "charts/troupe", "--namespace", World.namespace(), "--reuse-values", "--set", "commonLabels.e2e=#{System.unique_integer([:positive])}", "--wait", "--timeout", "5m"]),
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

  # The other half of `OnDelete`: a pod on an older revision is replaced once it holds
  # nothing, and nobody deletes it (Decision 726). The plane drains it, since it holds no
  # session, and records the drain finished on the `WorkerProfile`; the operator deletes
  # it; the StatefulSet makes it again on the new revision.
  #
  # A profile of its own with one pod kept warm, so that replacing the pod replaces
  # nothing another test is using, and so this is the one-pod case: the pod rolls with
  # nowhere else for its sessions to go.
  @tag timeout: 1_500_000
  test "a worker upgrade finishes by itself once its pod holds no session", context do
    name = Plane.unique("e2e-roll")
    namespace = World.worker_namespace(name)

    Plane.ready!(profile: name, channel: context.channel)

    on_exit(fn ->
      Plane.call("admin.team.revoke", %{"name" => context.team, "profile" => name, "confirm" => name})
      Plane.call("admin.profile.delete", %{"name" => name, "confirm" => name})
    end)

    World.eventually(fn -> World.kubectl(["get", "ns", namespace]) |> elem(1) == 0 end,
      timeout: 120_000,
      what: "the operator to make #{namespace}"
    )

    World.eventually(fn -> ready?(namespace) end,
      timeout: 300_000,
      every: 5_000,
      what: "#{name}'s worker to be ready"
    )

    {uid, revision} = pod_revision(namespace)

    # A new revision: the profile follows another channel, which its pods are told in
    # their environment. What an image bump does to the template, without an image to
    # build for it.
    Plane.ready!(profile: name, channel: Plane.unique("e2e-roll"))

    World.eventually(fn -> update_revision(namespace, name) not in [nil, "", revision] end,
      timeout: 120_000,
      what: "a new revision of #{name}'s StatefulSet"
    )

    # The plane records the pod's drain finished, and the operator acts on that record at
    # once rather than at its next resync, half a minute later: the record is an
    # annotation, which no generation counts.
    World.eventually(fn -> drained?(name, revision) end,
      timeout: 600_000,
      every: 500,
      what: "the plane to record #{name}'s pod drained"
    )

    recorded = System.monotonic_time(:millisecond)

    # A pod still Ready when the record lands is not replaced yet, and its readiness
    # changing is no event the operator hears: that one waits for the resync, so the time
    # is claimed only for the ordinary order, in which the drain took it out of its
    # Service before the plane's next step recorded it.
    if ready?(namespace) do
      IO.puts(:stderr, """

      SKIPPED: #{name}'s pod was still Ready when the plane recorded its drain, so how soon
      the operator acted on the record was not timed.
      """)
    else
      World.eventually(fn -> replacing?(namespace, uid) end,
        timeout: 120_000,
        every: 500,
        what: "the operator to replace #{name}'s drained pod"
      )

      took = System.monotonic_time(:millisecond) - recorded
      assert took < 10_000, "the operator took #{took} ms to act on a drain the plane recorded"
    end

    # And then nothing is done by hand.
    World.eventually(
      fn ->
        {now_uid, now_revision} = pod_revision(namespace)

        now_uid not in [nil, uid] and now_revision == update_revision(namespace, name) and
          ready?(namespace)
      end,
      timeout: 600_000,
      every: 5_000,
      what: "#{name}'s pod to be replaced on the new revision"
    )

    World.eventually(fn -> upgrade_pending(name) == "False" end,
      timeout: 120_000,
      every: 5_000,
      what: "#{name} to say UpgradePending: False"
    )
  end

  # The profile's one pod, as `{uid, revision}`, or `{nil, nil}` in the moment it has none.
  defp pod_revision(namespace) do
    path = "jsonpath={.items[0].metadata.uid} {.items[0].metadata.labels.controller-revision-hash}"

    case World.kubectl(["get", "pods", "-n", namespace, "-l", "app.kubernetes.io/name=troupe-worker", "-o", path]) do
      {output, 0} ->
        case String.split(output, " ", trim: true) do
          [uid, revision] -> {uid, revision}
          _partial -> {nil, nil}
        end

      _no_pod ->
        {nil, nil}
    end
  end

  defp ready?(namespace) do
    path = ~s|jsonpath={.items[0].status.conditions[?(@.type=="Ready")].status}|

    match?(
      {"True", 0},
      World.kubectl(["get", "pods", "-n", namespace, "-l", "app.kubernetes.io/name=troupe-worker", "-o", path])
    )
  end

  defp update_revision(namespace, name) do
    case World.kubectl(["get", "statefulset", "-n", namespace, "troupe-w-" <> name, "-o", "jsonpath={.status.updateRevision}"]) do
      {output, 0} -> String.trim(output)
      _missing -> nil
    end
  end

  # Whether the plane's record of finished drains names a pod on `revision`.
  defp drained?(name, revision) do
    path = ~S|jsonpath={.metadata.annotations.troupe\.dev/drained}|

    with {output, 0} <- World.kubectl(["get", "workerprofile", name, "-n", World.namespace(), "-o", path]),
         {:ok, %{} = drained} <- Jason.decode(String.trim(output)) do
      revision in Map.values(drained)
    else
      _unrecorded -> false
    end
  end

  # The pod `uid` is being deleted, or is gone and another stands in its place.
  defp replacing?(namespace, uid) do
    path = "jsonpath={.items[0].metadata.uid} {.items[0].metadata.deletionTimestamp}"

    case World.kubectl(["get", "pods", "-n", namespace, "-l", "app.kubernetes.io/name=troupe-worker", "-o", path]) do
      {output, 0} ->
        case String.split(output, " ", trim: true) do
          [^uid] -> false
          _deleting_or_replaced -> true
        end

      _no_pod ->
        true
    end
  end

  defp upgrade_pending(name) do
    path = ~s|jsonpath={.status.conditions[?(@.type=="UpgradePending")].status}|

    case World.kubectl(["get", "workerprofile", name, "-n", World.namespace(), "-o", path]) do
      {output, 0} -> String.trim(output)
      _missing -> nil
    end
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
