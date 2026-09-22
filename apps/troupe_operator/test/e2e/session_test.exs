defmodule Troupe.E2E.SessionTest do
  @moduledoc """
  A session on a real pod, and what survives the pod going away.

  Everything here is the client path: sign in at the identity provider, exchange for a
  plane token, ask the plane for a session, and attach to the pod it names over a
  WebSocket through the cluster's ingress. No private door, because a suite that used one
  would prove something about our code rather than about what is deployed.

  The claim worth the trouble is the last one. A session's durability is *not* a property
  of the pod: the log is sealed into object storage, the plane holds the epoch, and a pod
  deleted under a running session should cost the process and nothing else. Every
  in-process test of that kills a supervisor child, which is a different fault — the BEAM
  is still there, the disk is still there, and the plane never noticed. `kubectl delete
  pod` is the real one.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}
  alias Troupe.Protocol.Event

  @moduletag :e2e
  @moduletag timeout: 600_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  test "a session is placed on a pod of its profile and answers as that person", context do
    created = Plane.call!("session.create", %{"profile" => context.profile})

    on_exit(fn -> erase(created["session_id"]) end)

    assert is_binary(created["session_id"])
    assert created["endpoint"], "no endpoint: #{inspect(created)}"
    assert created["token"]

    # The plane's row says which pod, and the cluster agrees that pod exists. Two
    # separate roads: one through the plane's API, one through the API server.
    session = Plane.call!("session.get", %{"session_id" => created["session_id"]})
    assert session["state"] == "active"
    assert session["kind"] == "team"

    pods = World.pods(World.worker_namespace(context.profile), "app.kubernetes.io/name=troupe-worker")
    assert pods != []
  end

  test "a session survives its pod being deleted", context do
    created = Plane.call!("session.create", %{"profile" => context.profile})
    id = created["session_id"]
    on_exit(fn -> erase(id) end)

    # Where it got to before the fault. `head_hash` is the log's own chain, which is the
    # only thing that can say "the same history continued" rather than "a session with
    # that id exists".
    World.eventually(fn -> sealed?(id) end, timeout: 180_000, what: "#{id} to seal something")
    before = Plane.call!("session.get", %{"session_id" => id})
    assert before["head_hash"], "nothing sealed: #{inspect(before)}"

    namespace = World.worker_namespace(context.profile)

    # The pod the plane placed the session on — never the first pod in a listing. The
    # profile has two pods by this point in the suite (the capacity tests scale it), and
    # placement picks the emptier one, so the first listed was the wrong pod one run in
    # three: it was deleted, the session on the other pod stayed active as it should, and
    # "the plane never noticed" was the verdict on a pod the session was never on.
    pod = created["pod"]
    assert pod in World.pods(namespace, "app.kubernetes.io/name=troupe-worker"),
           "the plane placed #{id} on #{inspect(pod)}, which the cluster does not list"

    # The fault. Not a supervisor child killed in-process: the whole pod, its BEAM, its
    # disk and its connection to the plane, all at once.
    World.kubectl!(["delete", "pod", "-n", namespace, pod, "--wait=true"])

    World.eventually(
      fn -> World.pods(namespace, "app.kubernetes.io/name=troupe-worker") != [] end,
      timeout: 300_000,
      what: "the StatefulSet to replace #{pod}"
    )

    World.kubectl!([
      "wait",
      "-n",
      namespace,
      "--for=condition=ready",
      "pod",
      "-l",
      "app.kubernetes.io/name=troupe-worker",
      "--timeout=300s"
    ])

    # The plane should have stopped believing the session is on a pod that is gone. A
    # session left `active` on a dead pod is the failure this is really about: opening it
    # takes the already-running branch, tells nobody to restore, and answers `not_found`
    # to every retry for ever.
    World.eventually(
      fn -> Plane.call!("session.get", %{"session_id" => id})["state"] != "active" end,
      timeout: 180_000,
      what: "the plane to notice #{pod} is gone"
    )

    World.eventually(fn -> placeable?(context.profile) end,
      timeout: 300_000,
      what: "a pod of #{context.profile} to enrol and have room"
    )

    # And reopening continues the same history: the same head hash, on a new epoch,
    # because the epoch is what stops the old pod appending if it ever came back.
    reopened = Plane.call!("session.open", %{"session_id" => id, "mode" => "activate"})
    assert reopened["endpoint"]

    after_restore = Plane.call!("session.get", %{"session_id" => id})
    assert after_restore["epoch"] > before["epoch"],
           "the epoch did not move; a pod that came back could append to this"

    assert after_restore["last_seq"] >= before["last_seq"]

    # And the log itself, read off the new pod, is the *same* log. Not "a session with
    # that id exists" — a chain whose events run from the original `session_created`
    # through to a `session_resumed` that names the head this session had before its pod
    # was deleted. That link is the whole claim.
    events = reopened |> Plane.attach!() |> Plane.history!(id)
    assert events != [], "the restored session replayed nothing"

    assert Enum.any?(events, &(&1.type == "session_created")),
           "the restored log does not start where the original did"

    assert Enum.any?(events, &(&1.prev_hash == before["head_hash"])),
           "no event continues from #{before["head_hash"]}; the chain was broken by the restore"

    # Every link, not only the one: a restore that spliced a plausible head onto a
    # different history would satisfy the line above and nothing else here.
    assert chained?(events), "the restored log's hash chain does not hold"
  end

  # -- helpers ----------------------------------------------------------------

  # A head hash *and* a sequence past zero. A row carries a hash before anything has been
  # sealed, so hash-alone would be satisfied by a session that has written nothing — and
  # the claim being made is that a history continued, which needs there to have been one.
  #
  # No model is involved and none is needed: a session's tree appends `session_created`,
  # `agent_started` and `mounts_resolved` on its way up, and the sealer puts them in
  # object storage at its own interval.
  defp sealed?(id) do
    case Plane.call("session.get", %{"session_id" => id}) do
      {:ok, %{"head_hash" => hash, "last_seq" => seq}} when is_binary(hash) and seq > 0 -> true
      _ -> false
    end
  end

  # A pod that is Ready is not a pod the plane will place on: readiness is Kubernetes'
  # word and enrolment is the plane's, and between them is exactly the window where a
  # reopen answers "every pod is full". The plane's own fleet view is what to wait for.
  defp placeable?(profile) do
    Enum.any?(Plane.call!("admin.profiles.list"), fn listed ->
      listed["name"] == profile and
        Enum.any?(listed["pods"] || [], fn worker ->
          worker["healthy"] and not worker["draining"] and
            (worker["active_sessions"] || 0) < (worker["capacity"] || 0)
        end)
    end)
  end

  # Each event names the hash of the one before it. Checked here rather than trusted,
  # because "the log continued" is exactly the claim and a chain is how a log says so.
  defp chained?(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [earlier, later] ->
      later.prev_hash == nil or later.prev_hash == Event.hash(earlier)
    end)
  end

  # These run against a cluster nobody resets, so a test owns what it made. Erasure
  # rather than delete: a session that ever ran is erased, which is the plane's own rule.
  defp erase(id) do
    Plane.call("session.erase", %{"session_id" => id})
  end
end
