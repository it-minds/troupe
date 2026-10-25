defmodule Troupe.Plane.MemoryReadTest do
  @moduledoc """
  Which memory each running session read at its last turn (#55), and who is
  behind.

  A pod's session says what it holds as its turn begins (`session.memory.read`), and is
  answered with the documents in force where it is behind, so a push lost between turns
  cannot leave a turn on stale memory. A laptop's daemon says the same of its sessions with
  its poll of `me.memory`. The console reads both: per document, the sessions it reaches,
  the version each ran under at its last turn, and who is behind; a nudge tells a pod's
  session again. Rollback and the comparison of two versions are the editor's.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, FakePod, Fleet, Harness, Memory, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})
    root = Admin.actor_for(person("root@example.test", ["platform"]))

    %{port: Listener.port(), root: root}
  end

  describe "a pod's session, as its turn begins" do
    test "is answered with the documents in force when a push was lost, and recorded", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")

      ada = person("ada@example.test", [])
      {:ok, %{now: v1}} = Memory.put(:organisation, "Everyone.", "root@example.test", 0)
      {:ok, _} = Sessions.create(%{id: "s-read", owner_subject: ada.subject, owner_id: ada.id, profile: "dev"})
      {:ok, _} = Sessions.place("s-read", pod)

      # Its first turn read version 1, as its activation carried it: current, and kept.
      assert {:ok, %{"current" => true} = first} =
               call(worker, "session.memory.read", %{"session_id" => "s-read", "documents" => [read_of(v1)]})

      refute Map.has_key?(first, "memory")

      # Version 2 is saved; the push to the pod is lost (nothing here reads it). The next
      # turn still says version 1, and is answered with version 2 to read before it starts.
      {:ok, %{now: v2}} = Memory.put(:organisation, "Everyone, now.", "root@example.test", 1)

      assert {:ok, %{"current" => false, "memory" => [document]}} =
               call(worker, "session.memory.read", %{"session_id" => "s-read", "documents" => [read_of(v1)]})

      assert document["version"] == 2
      assert document["text"] == "Everyone, now."

      # What the plane keeps is what that turn runs under: version 2.
      assert [%{"scope" => "organisation", "version" => 2, "hash" => hash}] = Memory.read_of("s-read").documents
      assert hash == v2.hash
    end

    test "is refused for a session the pod does not hold or at another epoch", context do
      mine = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(mine, [])
      theirs = enrolled(context.port, "dev-token", "troupe-w-dev-1")
      answer_index(theirs, [])
      [here, other] = Enum.sort_by(Fleet.list_workers("dev"), & &1.pod_name)

      {:ok, _} = Sessions.create(%{id: "s-mine", owner_subject: "idp|ada", profile: "dev"})
      {:ok, _} = Sessions.place("s-mine", here)
      {:ok, _} = Sessions.create(%{id: "s-theirs", owner_subject: "idp|bo", profile: "dev"})
      {:ok, _} = Sessions.place("s-theirs", other)

      assert {:error, %{"message" => "not_found"}} =
               call(mine, "session.memory.read", %{"session_id" => "s-theirs", "documents" => []})

      assert {:error, %{"message" => "conflict"}} =
               call(mine, "session.memory.read", %{"session_id" => "s-mine", "epoch" => 9, "documents" => []})

      assert Memory.read_of("s-mine") == nil
      assert Memory.read_of("s-theirs") == nil
    end
  end

  describe "the console sees who is behind" do
    test "per session, the version it ran under at its last turn, then current after the next", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")

      team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])
      {:ok, %{now: v1}} = Memory.put(:organisation, "Everyone.", "root@example.test", 0)

      {:ok, _} =
        Sessions.create(%{
          id: "s-pod",
          owner_subject: ada.subject,
          owner_id: ada.id,
          team_id: team.id,
          profile: "dev"
        })

      {:ok, _} = Sessions.place("s-pod", pod)
      {:ok, _} = call(worker, "session.memory.read", %{"session_id" => "s-pod", "documents" => [read_of(v1)]})

      # Her laptop's daemon says, with its poll, what its one running session read.
      laptop = [%{"session_id" => "laptop-1", "turn_at" => "2026-10-25T09:00:00Z", "documents" => [read_of(v1)]}]
      assert {:ok, _} = Harness.call("me.memory", %{"sessions" => laptop}, %{user: ada, platform_admin?: false})

      {:ok, doc} = Admin.memory_get(context.root, "organisation", nil, nil, nil)
      assert doc.readers.behind == 0
      assert Enum.map(doc.readers.sessions, &{&1.session_id, &1.where, &1.version, &1.behind}) == [
               {"laptop-1", "machine", 1, false},
               {"s-pod", "pod", 1, false}
             ]

      # A save: both are behind until their next turn.
      {:ok, _} = Admin.memory_put(context.root, "organisation", nil, "Everyone, now.", 1)
      {:ok, doc} = Admin.memory_get(context.root, "organisation", nil, nil, nil)
      assert doc.readers.behind == 2
      assert doc.readers.version == 2

      pod_row = Enum.find(doc.readers.sessions, &(&1.session_id == "s-pod"))
      assert pod_row.owner == ada.subject
      assert pod_row.profile == "dev"
      assert pod_row.team == "engineering"
      assert pod_row.version == 1
      assert pod_row.behind
      assert pod_row.turn_at

      # The preview names the same sessions.
      {:ok, preview} = Admin.memory_preview(context.root, "organisation", nil, "Everyone, again.")
      assert preview.readers.behind == 2

      # The session list marks the pod's session.
      {:ok, listed} = Admin.sessions_list(context.root)
      assert Enum.find(listed, &(&1.id == "s-pod")).memory == "behind"

      # The pod's next turn reads version 2.
      {:ok, %{"current" => false}} =
        call(worker, "session.memory.read", %{"session_id" => "s-pod", "documents" => [read_of(v1)]})

      {:ok, doc} = Admin.memory_get(context.root, "organisation", nil, nil, nil)
      assert doc.readers.behind == 1
      assert Enum.find(doc.readers.sessions, &(&1.session_id == "s-pod")).version == 2
      {:ok, listed} = Admin.sessions_list(context.root)
      assert Enum.find(listed, &(&1.id == "s-pod")).memory == "current"
    end

    test "a team's document lists its sessions and its members' machines, not another team's", context do
      eng = team_with_grant("engineering", "dev", name: "engineering")
      _design = team_with_grant("design", "dev", name: "design")
      ada = person("ada@example.test", ["engineering"])
      bo = person("bo@example.test", ["design"])
      {:ok, %{now: v1}} = Memory.put(eng, "Engineers.", "root@example.test", 0)

      for {user, id} <- [{ada, "ada-laptop"}, {bo, "bo-laptop"}] do
        sessions = [%{"session_id" => id, "documents" => [read_of(v1, "engineering")]}]
        {:ok, _} = Harness.call("me.memory", %{"sessions" => sessions}, %{user: user, platform_admin?: false})
      end

      {:ok, doc} = Admin.memory_get(context.root, "team", "engineering", nil, nil)
      assert Enum.map(doc.readers.sessions, & &1.session_id) == ["ada-laptop"]
    end

    test "a nudge tells a pod's session again, and says a laptop's hears at its next poll", context do
      worker = enrolled(context.port, "dev-token", "troupe-w-dev-0")
      answer_index(worker, [])
      [pod] = Fleet.list_workers("dev")

      ada = person("ada@example.test", [])
      {:ok, %{now: v1}} = Memory.put(:organisation, "Everyone.", "root@example.test", 0)
      {:ok, _} = Sessions.create(%{id: "s-nudge", owner_subject: ada.subject, owner_id: ada.id, profile: "dev"})
      {:ok, _} = Sessions.place("s-nudge", pod)
      {:ok, _} = call(worker, "session.memory.read", %{"session_id" => "s-nudge", "documents" => [read_of(v1)]})

      sessions = [%{"session_id" => "laptop-2", "documents" => [read_of(v1)]}]
      {:ok, _} = Harness.call("me.memory", %{"sessions" => sessions}, %{user: ada, platform_admin?: false})

      assert {:ok, %{told: true, where: "pod"}} = Admin.memory_nudge(context.root, "organisation", nil, "s-nudge")
      assert %{"params" => %{"session_id" => "s-nudge", "memory" => [_]}} = push(worker, "session.memory")

      assert {:ok, %{told: false, where: "machine", reason: reason}} =
               Admin.memory_nudge(context.root, "organisation", nil, "laptop-2")

      assert reason =~ "next poll"

      assert {:error, %{message: "not_found"}} = Admin.memory_nudge(context.root, "organisation", nil, "s-nowhere")
    end
  end

  describe "the editor" do
    test "rolls back to a version as a new version, audited as rolled back", context do
      for {text, base} <- [{"One.", 0}, {"Two.", 1}, {"Three.", 2}, {"Four.", 3}] do
        {:ok, _} = Admin.memory_put(context.root, "organisation", nil, text, base)
      end

      assert {:ok, %{document: %{"version" => 5}}} =
               Admin.memory_rollback(context.root, "organisation", nil, 3, 4)

      assert Memory.current(:organisation).text == "Three."
      [row | _] = Enum.filter(Audit.list(), &(&1.action == "memory.put"))
      assert row.detail["rolled_back_to"] == 3
      assert row.detail["note"] == "rolled back to v3"

      # Over a version somebody replaced since, a conflict, as any save is.
      assert {:error, %{message: "conflict"}} = Admin.memory_rollback(context.root, "organisation", nil, 1, 4)
      # And to a version that does not exist, not found.
      assert {:error, %{message: "not_found"}} = Admin.memory_rollback(context.root, "organisation", nil, 9, 5)
    end

    test "compares any two versions line by line", context do
      for {text, base} <- [{"a\nb\nc", 0}, {"a\nB\nc", 1}, {"a\nB\nc\nd", 2}] do
        {:ok, _} = Admin.memory_put(context.root, "organisation", nil, text, base)
      end

      {:ok, doc} = Admin.memory_get(context.root, "organisation", nil, 3, 1)
      assert doc.against == 1

      assert doc.diff == [
               %{"op" => "same", "text" => "a"},
               %{"op" => "del", "text" => "b"},
               %{"op" => "add", "text" => "B"},
               %{"op" => "same", "text" => "c"},
               %{"op" => "add", "text" => "d"}
             ]

      assert {:error, %{message: "not_found"}} = Admin.memory_get(context.root, "organisation", nil, 3, 7)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp read_of(document, name \\ nil),
    do: %{"scope" => document.scope, "name" => name, "version" => document.version, "hash" => document.hash}

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :line])
    %{socket: socket, id: :counters.new(1, [])}
  end

  defp enrolled(port, token, pod_name) do
    worker = connect(port)

    {:ok, _} =
      call(worker, "enrol", %{
        "token" => FakePod.token(token),
        "pod_name" => pod_name,
        "capacity" => 4,
        "disk_total_bytes" => 1000
      })

    worker
  end

  defp answer_index(worker, sessions, attempts \\ 8)
  defp answer_index(_worker, _sessions, 0), do: flunk("no session.index request arrived")

  defp answer_index(worker, sessions, attempts) do
    case read(worker) do
      %{"method" => "session.index", "id" => id} ->
        :ok =
          :gen_tcp.send(worker.socket, [
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessions" => sessions}}),
            "\n"
          ])

      _other ->
        answer_index(worker, sessions, attempts - 1)
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

  defp push(worker, method, attempts \\ 5)
  defp push(_worker, method, 0), do: flunk("no #{method} push arrived")

  defp push(worker, method, attempts) do
    case read(worker) do
      %{"method" => ^method} = message -> message
      _other -> push(worker, method, attempts - 1)
    end
  end

  defp answer(worker, id) do
    case read(worker) do
      %{"method" => _method} -> answer(worker, id)
      %{"id" => ^id} = message -> message
      other -> other
    end
  end

  defp read(worker, timeout \\ 5_000) do
    {:ok, line} = :gen_tcp.recv(worker.socket, 0, timeout)
    line |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
  end
end
