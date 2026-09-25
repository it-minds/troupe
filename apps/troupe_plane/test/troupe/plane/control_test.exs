defmodule Troupe.Plane.ControlTest do
  @moduledoc """
  The channel workers dial in on.

  What crosses it is presence, the session index, usage records, and pushes the other
  way — and **no session content**, which is the property the whole remote design rests
  on. The test that proves that is here: a marker string sent as session input must not
  appear in what the control channel carried.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, Drain, Fleet, Placement, SCIM, Sessions, TeamBudget}
  alias Troupe.Plane.Control.{Connection, Connections, Listener}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    # Going dormant releases the pod slot the session was holding, which is the
    # placement actor's business.
    start_supervised!(Troupe.Plane.Singleton)

    # Enrolment is a TokenReview in a pod. Here the verification is stubbed so the
    # channel itself can be tested without a cluster; `Troupe.Plane.EnrolmentTest`
    # proves the real thing against a real API server.
    verify = fn
      "dev-token" ->
        {:ok,
         %{
           profile: "dev",
           namespace: "troupe-w-dev",
           pod_name: nil,
           service_account: "troupe-worker"
         }}

      "ux-token" ->
        {:ok,
         %{
           profile: "ux",
           namespace: "troupe-w-ux",
           pod_name: nil,
           service_account: "troupe-worker"
         }}

      _ ->
        {:error, :unauthenticated}
    end

    start_supervised!({Listener, port: 0, verify: verify})
    %{port: Listener.port()}
  end

  describe "enrolling" do
    test "a worker enrols and is placed under the profile its token proved", %{port: port} do
      worker = connect(port)

      assert {:ok, result} =
               call(worker, "enrol", %{
                 "token" => "dev-token",
                 "pod_name" => "troupe-w-dev-0",
                 "capacity" => 4,
                 "disk_total_bytes" => 1000
               })

      assert result["profile"] == "dev"
      assert [recorded] = Fleet.list_workers("dev")
      assert recorded.pod_name == "troupe-w-dev-0"
      assert recorded.healthy
    end

    test "an unknown token is refused and the connection closes", %{port: port} do
      worker = connect(port)

      assert {:error, error} =
               call(worker, "enrol", %{"token" => "nonsense", "pod_name" => "x-0"})

      assert error["message"] == "unauthenticated"

      # A socket that has not proved which pod it is has nothing to say, and leaving it
      # open is an invitation to keep trying.
      assert closed?(worker)
    end

    test "anything before enrolling is refused", %{port: port} do
      worker = connect(port)

      assert {:error, error} = call(worker, "heartbeat", %{"capacity" => 4})
      assert error["message"] == "not_initialized"
      assert closed?(worker)
    end

    test "enrolling twice on one connection is refused", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      assert {:error, error} =
               call(worker, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})

      assert error["message"] == "invalid_request"
    end
  end

  describe "presence" do
    test "a heartbeat records capacity, load and the loaded bundle", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, %{"ok" => true}} =
               call(worker, "heartbeat", %{
                 "capacity" => 4,
                 "active_sessions" => 2,
                 "disk_used_bytes" => 300,
                 "disk_total_bytes" => 1000,
                 "bundle_hash" => "sha256:abc",
                 "version" => "0.2.0"
               })

      assert [recorded] = Fleet.list_workers("dev")
      assert recorded.active_sessions == 2
      assert recorded.bundle_hash == "sha256:abc"
      assert recorded.disk_used_bytes == 300
    end

    test "a pod says whether it is draining; only enrolling again lowers the flag", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      assert [%{draining: false}] = Fleet.list_workers("dev")

      # The pod's own word raises the flag…
      assert {:ok, _} = call(worker, "heartbeat", %{"capacity" => 4, "draining" => true})
      assert [%{draining: true}] = Fleet.list_workers("dev")

      # …a heartbeat cannot lower it, because the plane may have raised it first…
      assert {:ok, _} = call(worker, "heartbeat", %{"capacity" => 4, "draining" => false})
      assert [%{draining: true}] = Fleet.list_workers("dev")

      # …and a pod that enrols not draining is a pod that restarted after the drain.
      _fresh = enrolled(port, "dev-token", "troupe-w-dev-0")
      assert [%{draining: false}] = Fleet.list_workers("dev")
    end

    test "the plane can find a worker by pod and a profile's workers together", %{port: port} do
      enrolled(port, "dev-token", "troupe-w-dev-0")
      enrolled(port, "dev-token", "troupe-w-dev-1")
      enrolled(port, "ux-token", "troupe-w-ux-0")

      assert Connections.for_pod("troupe-w-dev", "troupe-w-dev-0")
      assert length(Connections.for_profile("dev")) == 2
      assert length(Connections.for_profile("ux")) == 1
    end

    test "a worker fetches a bundle by hash, or by channel and version", %{port: port} do
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable"})
      content = %{"schema" => 1, "agents" => [], "skills" => [], "mcp_servers" => []}
      {:ok, bundle} = Bundles.publish("stable", content, announce: false)

      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      assert {:ok, fetched} = call(worker, "bundle.fetch", %{"hash" => bundle.hash})
      assert fetched["content"] == content
      assert fetched["hash"] == bundle.hash
      assert fetched["channel"] == "stable"
      assert fetched["version"] == bundle.version

      assert {:ok, by_version} =
               call(worker, "bundle.fetch", %{"channel" => "stable", "version" => 1})

      assert by_version["hash"] == bundle.hash

      assert {:error, error} = call(worker, "bundle.fetch", %{"hash" => "sha256:nothing"})
      assert error["message"] == "not_found"
    end

    test "the plane can push to a worker", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      pid = Connections.for_pod("troupe-w-dev", "troupe-w-dev-0")

      Connection.notify(pid, "config.updated", %{"channel" => "stable", "version" => 2})

      assert %{"params" => %{"version" => 2}} = push(worker, "config.updated")
    end
  end

  describe "an assertion for a session's owner" do
    test "names the owner off the row, whatever the pod asks for", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])

      [pod] = Fleet.list_workers("dev")
      {:ok, _} = Sessions.create(%{id: "s-ada", owner_subject: "idp|ada", profile: "dev"})
      {:ok, _} = Sessions.place("s-ada", pod)

      assert {:ok, %{"assertion" => assertion, "expires_at" => expires_at}} =
               call(worker, "kms.assertion", %{"session_id" => "s-ada"})

      # The subject is not the pod's to choose: it is read off the session row, so the
      # only thing a pod can influence is *which of its own sessions* it asks about.
      assert %{"sub" => "idp|ada", "aud" => "troupe-kms"} = payload_of(assertion)
      assert is_integer(expires_at)
    end

    test "is refused once the session's owner is deactivated", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])

      [pod] = Fleet.list_workers("dev")
      ada = person("ada@example.test", ["engineering"])
      {:ok, _} = Sessions.create(%{id: "s-ada2", owner_subject: ada.subject, profile: "dev"})
      {:ok, _} = Sessions.place("s-ada2", pod)

      assert {:ok, %{"assertion" => _}} = call(worker, "kms.assertion", %{"session_id" => "s-ada2"})

      {:ok, _} = SCIM.deactivate_user(ada.id)

      # The door that needs nobody to sign in. A running session would otherwise keep
      # lending a deprovisioned person's credentials for as long as it kept running; now
      # the pod's existing key-manager token outlives this by its own lease and no longer.
      assert {:error, error} = call(worker, "kms.assertion", %{"session_id" => "s-ada2"})
      assert error["message"] == "forbidden"
      assert error["data"]["reason"] =~ "deactivated"

      # The session is not stopped. Its history is the team's, and what it may still do is
      # a different question from what it may do *as them*.
      assert Sessions.get("s-ada2").state == "active"
    end

    test "refuses a session this pod is not holding", %{port: port} do
      mine = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(mine, [])

      theirs = enrolled(port, "dev-token", "troupe-w-dev-1")
      answer_index(theirs, [])

      [_, other] = Enum.sort_by(Fleet.list_workers("dev"), & &1.pod_name)
      {:ok, _} = Sessions.create(%{id: "s-theirs", owner_subject: "idp|bo", profile: "dev"})
      {:ok, _} = Sessions.place("s-theirs", other)

      # A pod holds what the index says it holds. Asking for somebody else's session is
      # how one pod would read another's person's credentials, and the plane is the only
      # thing in a position to refuse it.
      assert {:error, error} = call(mine, "kms.assertion", %{"session_id" => "s-theirs"})
      assert error["message"] == "not_found"

      assert {:error, missing} = call(mine, "kms.assertion", %{"session_id" => "s-nowhere"})
      assert missing["message"] == "not_found"

      # A session with no owner is not a case that has to be handled here: the index
      # requires one, so there is no row this could be asked about.
      assert {:error, changeset} = Sessions.create(%{id: "s-nobody", profile: "dev"})
      assert changeset.errors[:owner_subject]
    end

  end

  describe "a pod that restarted" do
    test "gives up the sessions the plane still thought it was holding", %{port: port} do
      first = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(first, [%{"id" => "s-live"}])

      [pod] = Fleet.list_workers("dev")
      {:ok, _} = Sessions.create(%{id: "s-live", owner_subject: "idp|alice", profile: "dev"})
      {:ok, session} = Sessions.place("s-live", pod)
      assert session.state == "active"
      assert session.worker_id == pod.id

      # The pod goes, and comes back with nothing — which is what a restart looks like
      # from here.
      :gen_tcp.close(first.socket)

      second = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(second, [])

      # Without this the session is unreachable for good: the plane keeps saying it is
      # already running, hands out an endpoint, never tells the pod to restore, and the
      # client's `subscribe` answers `not_found` however long anybody retries.
      assert until(fn -> Sessions.get("s-live").state == "dormant" end),
             "the session stayed active on a pod that no longer has it"

      assert is_nil(Sessions.get("s-live").worker_id)
    end

    test "replaced under its own name before its old connection closed", %{port: port} do
      first = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(first, [])

      [pod] = Fleet.list_workers("dev")
      {:ok, _} = Sessions.create(%{id: "s-stranded", owner_subject: "idp|alice", profile: "dev"})
      {:ok, _} = Sessions.place("s-stranded", pod)

      # The first socket is *not* closed. A worker deleted with `kubectl delete pod` is
      # recreated by its StatefulSet in seconds, and a kill sends no FIN, so the plane
      # still holds the dead pod's connection when the new pod enrols under the same
      # name. With two connections registered, the index question used to reach neither,
      # and the session stayed active on a pod that no longer had it.
      second = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(second, [])

      assert until(fn -> Sessions.get("s-stranded").state == "dormant" end),
             "the session stayed active on a pod replaced under its own name"

      # The predecessor's connection is closed from the plane's side. That the session
      # went dormant is already the proof the question reached the new pod.
      assert until(fn -> match?({:error, :closed}, :gen_tcp.recv(first.socket, 0, 100)) end),
             "the old connection was left open"
    end

    test "leaves alone what the pod says it still holds", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])

      [pod] = Fleet.list_workers("dev")
      {:ok, _} = Sessions.create(%{id: "s-kept", owner_subject: "idp|alice", profile: "dev"})
      {:ok, _} = Sessions.place("s-kept", pod)

      # A control link that dropped and came back is not a restart, and the pod is still
      # running everything it was. Reading a reconnect as an empty pod would dormant a
      # healthy fleet every time the network hiccupped — which it did, eight times in one
      # day on the deployment this was found on.
      :gen_tcp.close(worker.socket)

      again = enrolled(port, "dev-token", "troupe-w-dev-0")
      answer_index(again, [%{"id" => "s-kept"}])

      refute until(fn -> Sessions.get("s-kept").state == "dormant" end, 12),
             "a session the pod still holds was dormanted"

      assert Sessions.get("s-kept").state == "active"
    end
  end

  describe "the session index" do
    test "a sealed segment is anchored, and the index moves with it", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      {:ok, _} = Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev"})

      assert {:ok, %{"ok" => true}} =
               call(worker, "session.sealed", %{
                 "session_id" => "s-1",
                 "epoch" => 1,
                 "first_seq" => 1,
                 "last_seq" => 40,
                 "head_hash" => "sha256:deadbeef",
                 "object_key" => "sessions/s-1/segments/1-1-40.seg",
                 "bytes" => 900
               })

      assert [anchor] = Sessions.anchors("s-1")
      assert anchor.last_seq == 40
      assert anchor.head_hash == "sha256:deadbeef"
      assert Sessions.get("s-1").last_seq == 40
    end

    test "a seal report from a stale epoch is refused", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      {:ok, _} =
        Sessions.create(%{
          id: "s-1",
          owner_subject: "idp|alice",
          profile: "dev",
          state: "dormant"
        })

      # The session was activated somewhere else, which is what bumps the epoch.
      {:ok, session} = Sessions.activate("s-1")
      assert session.epoch == 2

      # A pod presumed lost comes back and tries to append under the old epoch.
      assert {:error, error} =
               call(worker, "session.sealed", %{
                 "session_id" => "s-1",
                 "epoch" => 1,
                 "first_seq" => 41,
                 "last_seq" => 60,
                 "head_hash" => "sha256:stale",
                 "object_key" => "sessions/s-1/segments/1-41-60.seg"
               })

      assert error["message"] == "conflict"
      assert Sessions.anchors("s-1") == []
      assert Sessions.get("s-1").last_seq == 0
    end

    test "going dormant frees the slot it was holding", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      {:ok, _} = Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev"})

      assert {:ok, _} =
               call(worker, "session.dormant", %{
                 "session_id" => "s-1",
                 "last_seq" => 12,
                 "head_hash" => "sha256:x",
                 "object_bytes" => 500
               })

      session = Sessions.get("s-1")
      assert session.state == "dormant"
      assert is_nil(session.worker_id)
      assert session.last_seq == 12
    end

    test "a pod's own dormancy report gives its slot back, and the pod has room again at once",
         %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      [pod] = Fleet.list_workers("dev")

      # Full: the pod enrolled with room for four.
      for n <- 1..4, do: placed("s-#{n}")
      full = placement("dev")
      assert full.capacities[pod.id] == 4

      assert {:ok, _} =
               call(worker, "session.dormant", %{"session_id" => "s-1", "last_seq" => 12})

      # The report marked the row dormant first, which clears the `worker_id` a release
      # gives the slot back by, so the pod stayed charged for four. Nothing put that right
      # until a reserve was about to be refused and the actor counted the profile again.
      assert placement("dev").capacities[pod.id] == 3

      placed("s-5")
      refilled = placement("dev")
      assert refilled.capacities[pod.id] == 4
      assert refilled.loaded_at == full.loaded_at, "the slot came back only by counting again"
    end

    test "a slot is given back once, however many times its session is put to sleep",
         %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      [pod] = Fleet.list_workers("dev")
      placed("s-1")
      placed("s-2")

      # The plane gives a session back itself when a pod it asked to archive answers
      # without having reported it, and the pod's own report can still arrive after that.
      Drain.strand(pod, "s-1")
      assert {:ok, _} = call(worker, "session.dormant", %{"session_id" => "s-1"})
      assert {:ok, _} = call(worker, "session.dormant", %{"session_id" => "s-1"})

      assert placement("dev").capacities[pod.id] == 1
    end

    test "a session its pod parks read-only gives its slot back", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      [pod] = Fleet.list_workers("dev")
      placed("s-1")
      placed("s-2")

      assert {:ok, _} =
               call(worker, "session.unrestorable", %{
                 "session_id" => "s-1",
                 "epoch" => Sessions.get("s-1").epoch,
                 "reason" => "workspace_gone"
               })

      assert Sessions.get("s-1").state == "read_only"
      assert placement("dev").capacities[pod.id] == 1
    end

    test "a pod that cannot put a tree back parks the session read-only, fenced on the epoch", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      {:ok, _} = Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev", epoch: 2})

      # A pod still on epoch 1 has nothing to say about it.
      assert {:error, %{"message" => "conflict"}} =
               call(worker, "session.unrestorable", %{"session_id" => "s-1", "epoch" => 1, "reason" => "workspace_gone"})

      assert Sessions.get("s-1").state == "active"

      assert {:ok, _} =
               call(worker, "session.unrestorable", %{
                 "session_id" => "s-1",
                 "reason" => "workspace_gone",
                 "detail" => "/var/lib/troupe/erased"
               })

      session = Sessions.get("s-1")
      assert session.state == "read_only"
      assert is_nil(session.worker_id)

      # Saying it again is not an error, and neither is saying it about nothing.
      assert {:ok, _} = call(worker, "session.unrestorable", %{"session_id" => "s-1", "reason" => "workspace_gone"})
      assert {:ok, _} = call(worker, "session.unrestorable", %{"session_id" => "s-none", "reason" => "workspace_gone"})
    end

    test "a status report lands on the row, and one from a stale epoch does not", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      {:ok, _} =
        Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev", epoch: 2})

      assert {:ok, _} =
               call(worker, "session.status", %{
                 "session_id" => "s-1",
                 "epoch" => 2,
                 "status" => "waiting",
                 "done_reason" => nil,
                 "pending_approvals" => 1,
                 "pending_questions" => 2,
                 "cost_micros" => 1234
               })

      session = Sessions.get("s-1")
      assert session.status == "waiting"
      assert session.pending_approvals == 1
      assert session.pending_questions == 2
      assert session.cost_micros == 1234
      assert is_nil(session.done_reason)

      # A pod presumed lost, still running epoch 1, has nothing to say about this session.
      assert {:error, %{"message" => "conflict"}} =
               call(worker, "session.status", %{
                 "session_id" => "s-1",
                 "epoch" => 1,
                 "status" => "done",
                 "done_reason" => "finished"
               })

      assert Sessions.get("s-1").status == "waiting"

      # Finishing clears the counts and names the reason.
      assert {:ok, _} =
               call(worker, "session.status", %{
                 "session_id" => "s-1",
                 "epoch" => 2,
                 "status" => "done",
                 "done_reason" => "budget_exhausted",
                 "pending_approvals" => 0,
                 "pending_questions" => 0,
                 "cost_micros" => 2000
               })

      session = Sessions.get("s-1")
      assert session.status == "done"
      assert session.done_reason == "budget_exhausted"
      assert session.pending_approvals == 0
      assert session.pending_questions == 0
    end

    test "going dormant applies the last status and gives the budget slice back", %{port: port} do
      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 10_000_000)
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")

      {:ok, _} =
        Sessions.create(%{
          id: "s-1",
          owner_subject: "idp|alice",
          profile: "dev",
          team_id: team.id
        })

      {:ok, _} = TeamBudget.reserve(team, "s-1", 5_000_000)
      assert TeamBudget.inspect_state(team).reserved_micros == 5_000_000

      assert {:ok, _} =
               call(worker, "session.dormant", %{
                 "session_id" => "s-1",
                 "epoch" => 1,
                 "last_seq" => 12,
                 "status" => "done",
                 "done_reason" => "finished",
                 "pending_approvals" => 0,
                 "cost_micros" => 4200
               })

      session = Sessions.get("s-1")
      assert session.state == "dormant"
      assert session.status == "done"
      assert session.done_reason == "finished"
      assert session.cost_micros == 4200

      # The slice is back with the team, as the module doc always said it would be.
      assert TeamBudget.inspect_state(team).reserved_micros == 0
    end
  end

  test "no session content crosses the channel", %{port: port} do
    worker = enrolled(port, "dev-token", "troupe-w-dev-0")
    {:ok, _} = Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev"})

    marker = "CANARY-#{System.unique_integer([:positive])}-NEVER-LEAVES-THE-POD"

    # Everything a worker is allowed to say about a session, said at once. None of the
    # methods take content, and that is the point: there is no field to put it in.
    sent = [
      call(worker, "session.index", %{
        "sessions" => [%{"id" => "s-1", "last_seq" => 3, "head_hash" => "sha256:h"}]
      }),
      call(worker, "session.sealed", %{
        "session_id" => "s-1",
        "epoch" => 1,
        "first_seq" => 1,
        "last_seq" => 3,
        "head_hash" => "sha256:h",
        "object_key" => "sessions/s-1/segments/1-1-3.seg"
      }),
      call(worker, "heartbeat", %{"capacity" => 4, "active_sessions" => 1})
    ]

    assert Enum.all?(sent, &match?({:ok, _}, &1))

    # The database holds the index and the anchors, and nothing that could carry the
    # marker even if a worker tried.
    dump = database_dump()
    refute dump =~ marker
    refute dump =~ "NEVER-LEAVES-THE-POD"
  end

  # -- a worker, as a socket --------------------------------------------------

  defp connect(port) do
    # `packet: :line`, so one `recv` is one message. With `:raw` two messages arriving in
    # one segment meant the second was read and thrown away — which is exactly what
    # happens now that the plane pushes `jwks.updated` the moment a worker enrols.
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    %{socket: socket, id: :counters.new(1, [])}
  end

  defp enrolled(port, token, pod_name) do
    worker = connect(port)

    {:ok, _} =
      call(worker, "enrol", %{
        "token" => token,
        "pod_name" => pod_name,
        "capacity" => 4,
        "disk_total_bytes" => 1000
      })

    worker
  end

  # A session created and given a slot the way `session.create` gives one.
  defp placed(id) do
    {:ok, _} = Sessions.create(%{id: id, owner_subject: "idp|alice", profile: "dev"})
    {:ok, _} = Placement.reserve("dev", id)
  end

  # What the placement actor holds, read without making it count again:
  # `Placement.inspect_state/1` reloads from the database first, which is exactly what
  # would hide a slot that was never given back.
  defp placement(profile), do: :sys.get_state(:global.whereis_name({Placement, profile}))

  # The plane asks every pod what it holds the moment it enrols. A fake pod that never
  # answered would leave the plane waiting, so this reads past the pushes to the request
  # and replies with whatever the test says the pod has.
  defp answer_index(worker, sessions, attempts \\ 8)

  defp answer_index(_worker, _sessions, 0), do: flunk("no session.index request arrived")

  defp answer_index(worker, sessions, attempts) do
    case read(worker) do
      %{"method" => "session.index", "id" => id} ->
        :ok =
          :gen_tcp.send(worker.socket, [
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessions" => sessions}}),
            "
"
          ])

        :ok

      _other ->
        answer_index(worker, sessions, attempts - 1)
    end
  end

  # The reconciliation runs off the enrolment, so it lands a moment after the answer.
  defp until(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && until(check, attempts - 1)
    end
  end

  defp call(worker, method, params) do
    :counters.add(worker.id, 1, 1)
    id = :counters.get(worker.id, 1)

    :ok =
      :gen_tcp.send(worker.socket, [
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}),
        "\n"
      ])

    case answer(worker, id) do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
      other -> {:error, other}
    end
  end

  # The next push of one kind, skipping the others. `jwks.updated` arrives the moment a
  # worker enrols, so a test waiting for a different push has to read past it.
  defp push(worker, method, attempts \\ 5)

  defp push(_worker, method, 0), do: flunk("no #{method} push arrived")

  defp push(worker, method, attempts) do
    case read(worker) do
      %{"method" => ^method} = message -> message
      _other -> push(worker, method, attempts - 1)
    end
  end

  # The plane pushes notifications down this channel — `jwks.updated` the moment a
  # worker enrols — so a reply is the message carrying *this* id, not the next message
  # to arrive. A client that assumed otherwise would read a push as its own answer.
  defp answer(worker, id) do
    case read(worker) do
      %{"id" => ^id} = message -> message
      %{"method" => _method} -> answer(worker, id)
      other -> other
    end
  end

  defp read(worker, timeout \\ 5_000) do
    {:ok, line} = :gen_tcp.recv(worker.socket, 0, timeout)
    line |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
  end

  defp closed?(worker) do
    case :gen_tcp.recv(worker.socket, 0, 2_000) do
      {:error, :closed} -> true
      _ -> false
    end
  end

  defp database_dump do
    tables = ~w(sessions anchors workers usage_records session_acls audit_events)

    Enum.map_join(tables, "\n", fn table ->
      %{rows: rows} = Repo.query!("select * from #{table}")
      inspect(rows)
    end)
  end
  # The claims, without verifying the signature: what is being checked here is which
  # subject the plane put in, and OpenBao is what checks the rest.
  defp payload_of(jwt) do
    [_header, payload, _signature] = String.split(jwt, ".")
    padded = payload <> String.duplicate("=", rem(4 - rem(byte_size(payload), 4), 4))
    padded |> Base.url_decode64!() |> Jason.decode!()
  end
end
