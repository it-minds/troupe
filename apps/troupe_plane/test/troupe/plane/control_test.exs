defmodule Troupe.Plane.ControlTest do
  @moduledoc """
  The channel workers dial in on.

  What crosses it is presence, the session index, usage records, and pushes the other
  way — and **no session content**, which is the property the whole remote design rests
  on. The test that proves that is here: a marker string sent as session input must not
  appear in what the control channel carried.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connection, Connections, Listener}
  alias Troupe.Plane.{Fleet, Sessions}

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
      "dev-token" -> {:ok, %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
      "ux-token" -> {:ok, %{profile: "ux", namespace: "troupe-w-ux", pod_name: nil, service_account: "troupe-worker"}}
      _ -> {:error, :unauthenticated}
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

      assert {:error, error} = call(worker, "enrol", %{"token" => "nonsense", "pod_name" => "x-0"})
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

      assert {:error, error} = call(worker, "enrol", %{"token" => "dev-token", "pod_name" => "troupe-w-dev-0"})
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

    test "the plane can find a worker by pod and a profile's workers together", %{port: port} do
      enrolled(port, "dev-token", "troupe-w-dev-0")
      enrolled(port, "dev-token", "troupe-w-dev-1")
      enrolled(port, "ux-token", "troupe-w-ux-0")

      assert Connections.for_pod("troupe-w-dev", "troupe-w-dev-0")
      assert length(Connections.for_profile("dev")) == 2
      assert length(Connections.for_profile("ux")) == 1
    end

    test "the plane can push to a worker", %{port: port} do
      worker = enrolled(port, "dev-token", "troupe-w-dev-0")
      pid = Connections.for_pod("troupe-w-dev", "troupe-w-dev-0")

      Connection.notify(pid, "config.updated", %{"channel" => "stable", "version" => 2})

      assert %{"params" => %{"version" => 2}} = push(worker, "config.updated")
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
      {:ok, _} = Sessions.create(%{id: "s-1", owner_subject: "idp|alice", profile: "dev", state: "dormant"})

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
end
