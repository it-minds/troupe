defmodule Troupe.Worker.ReaderLogTest do
  @moduledoc """
  A reader takes the log it restored away with it, and nothing else.

  `session.read` restores a dormant session's log into the pod's state directory so the
  pod's harness can serve it, and nothing removed it: it stayed there, in plaintext, until
  the session was next activated on the pod and put to sleep there, which for a session
  that goes on to run elsewhere is never. These pin that the log goes when the reader does,
  however it stops, and not before the last client reading it has gone; and that it stays
  where it is not the reader's to take: a log that was on the pod before the read, and one
  an activation of the session has, is putting back or has written to.
  """

  use Troupe.Worker.SessionCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Session.Log
  alias Troupe.Worker.RecordingProxy
  alias Troupe.Worker.Session.{Reader, Restore}

  @moduletag timeout: 120_000

  describe "the log goes with the reader" do
    test "when its last follower leaves, when it is closed, and when nobody came", context do
      context = requires_tier(context)
      a_dormant_session(context)

      follower = held(context)
      assert File.exists?(log_path(context))
      let_go(follower)
      eventually(fn -> Reader.whereis(context.session_id) == nil end)
      refute File.exists?(log_dir(context))

      assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
      assert File.exists?(log_path(context))
      assert :ok = Reader.close(context.session_id)
      refute File.exists?(log_dir(context))

      # Opened by a command that went away, and nobody followed it or read through the
      # harness.
      assert {:ok, %{source: :storage}} =
               Reader.open(context.session_id, reading(context, idle_grace_ms: 50))

      eventually(fn -> Reader.whereis(context.session_id) == nil end)
      refute File.exists?(log_dir(context))
    end

    test "when the pod shuts down", context do
      context = requires_tier(context)
      a_dormant_session(context)

      assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
      assert File.exists?(log_path(context))

      stop_supervised!(Sessions)

      refute File.exists?(log_dir(context))
    end

    test "not while a client reads the session through the harness", context do
      context = requires_tier(context)
      a_dormant_session(context)

      follower = held(context, idle_grace_ms: 50)
      history = Troupe.replay_from(context.session_id, 0)
      assert history != []

      # What the gateway does for a subscription that names the session. The client reads
      # the log from disk, and follows neither the reader nor any process of its own.
      client = a_client_reading(context.session_id)
      let_go(follower)

      Process.sleep(300)
      assert Reader.whereis(context.session_id)
      assert Troupe.replay_from(context.session_id, 0) == history

      send(client, :stop)
      eventually(fn -> Reader.whereis(context.session_id) == nil end)
      refute File.exists?(log_dir(context))
    end
  end

  describe "what is not the reader's stays" do
    test "a log that was on the pod before the read", context do
      context = requires_tier(context)
      a_dormant_session(context)

      # Left by a pod that stopped without putting the session to sleep, or by a reader of
      # a build that did not take its log away.
      {:ok, restore} = Restore.open_context(context.session_id, reading(context))
      assert {:ok, _log} = Restore.events(restore, context.workspace)
      before = File.read!(log_path(context))

      assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
      assert :ok = Reader.close(context.session_id)

      assert File.read!(log_path(context)) == before
    end

    test "a log an activation has taken over, whether it is running or has gone", context do
      context = requires_tier(context)
      a_dormant_session(context)

      follower = held(context, idle_grace_ms: 50)
      client = a_client_reading(context.session_id)
      let_go(follower)

      # The plane activates the session here while somebody is reading it. The activation
      # writes to the log, and the reader, with nothing left to serve or to take away,
      # goes, though the client is still there: it reads the live log now.
      assert {:ok, _summary} = activate(context, epoch: 2)
      eventually(fn -> Reader.whereis(context.session_id) == nil end)

      assert File.exists?(log_path(context))
      events = Troupe.replay_from(context.session_id, 0)
      assert Enum.any?(events, &(&1.type == "session_activated"))
      send(client, :stop)

      # An activation that has gone without putting the session to sleep leaves a log that
      # may hold events storage does not have yet, and a reader closed after it leaves it.
      assert {:ok, _summary} = Sessions.dormant(context.session_id)
      assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
      assert {:ok, _summary} = activate(context, epoch: 3)
      :ok = GenServer.stop(Sessions.whereis(context.session_id))

      assert :ok = Reader.close(context.session_id)
      assert File.exists?(log_path(context))
    end

    test "a log an activation is putting back, until it fails", context do
      context = requires_tier(context)
      a_dormant_session(context)

      # A manager holds the session's name from the moment it starts, before it has
      # restored anything.
      follower = held(context, idle_grace_ms: 50)
      starting = a_starting_activation(context.session_id)
      let_go(follower)

      Process.sleep(300)
      assert Reader.whereis(context.session_id)
      assert File.exists?(log_path(context))

      # It failed: the log it found was the reader's, and the reader takes it away.
      send(starting, :stop)
      eventually(fn -> Reader.whereis(context.session_id) == nil end)
      refute File.exists?(log_dir(context))

      # A reader closed while an activation is starting leaves the log to it.
      assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context))
      starting = a_starting_activation(context.session_id)
      assert :ok = Reader.close(context.session_id)
      assert File.exists?(log_path(context))
      send(starting, :stop)
    end

    test "an activation that failed after restoring the events leaves the log to the reader",
         context do
      context = requires_tier(context)
      a_dormant_session(context)
      follower = held(context, idle_grace_ms: 50)

      # Storage answers for the events and then not for the tree. The activation wrote the
      # log again and, having found the reader's there, leaves it (Decision 725); the
      # reader takes it away once its last follower has gone.
      proxy =
        start_supervised!(
          {RecordingProxy,
           upstream: URI.parse(context.store.endpoint).port,
           drop:
             "prefix=" <> URI.encode_www_form(Storage.prefix(context.session_id) <> "workspace/")}
        )

      endpoint = "http://127.0.0.1:#{RecordingProxy.port(proxy)}"

      capture_log(fn ->
        assert {:error, {:object_store_unreachable, ^endpoint, _reason}} =
                 activate(%{context | store: %{context.store | endpoint: endpoint}}, epoch: 2)
      end)

      assert File.exists?(log_path(context))
      let_go(follower)
      eventually(fn -> Reader.whereis(context.session_id) == nil end)
      refute File.exists?(log_dir(context))
    end
  end

  describe "a read racing an activation" do
    test "a reader that starts as the session is activated writes nothing over its log",
         context do
      context = requires_tier(context)
      a_dormant_session(context)

      assert {:ok, _summary} = activate(context, epoch: 2, report: reporter_to(self()))
      await_sealed()

      # What the plane's `share.changed` records between turns: until the next seal, only
      # this log has it.
      {:ok, seq} =
        Log.append(context.session_id, [], :share_created, %{"id" => "s1", "role" => "viewer"})

      live = File.read!(log_path(context))

      # A `session.read` that looked for a manager before this one registered, and starts
      # its reader now.
      started =
        DynamicSupervisor.start_child(
          Troupe.Worker.Session.Supervisor,
          {Reader, reading(context)}
        )

      assert File.read!(log_path(context)) == live
      assert Enum.any?(Troupe.replay_from(context.session_id, 0), &(&1.seq == seq))
      assert started == :ignore
      assert Reader.whereis(context.session_id) == nil
    end

    test "a read whose reader meets an activation as it writes is answered by the activation",
         context do
      context = requires_tier(context)
      a_dormant_session(context)
      holder = holding_the_log(context.session_id)

      reading = Task.async(fn -> Reader.open(context.session_id, reading(context)) end)
      eventually(fn -> Reader.whereis(context.session_id) end)

      # The reader has looked, and is fetching the segments or waiting to write them, when
      # an activation registers and puts its log back.
      starting = a_starting_activation(context.session_id)
      File.mkdir_p!(log_dir(context))
      File.write!(log_path(context), "the activation's\n")
      send(holder, :release)

      answer = Task.await(reading)
      assert File.read!(log_path(context)) == "the activation's\n"
      assert {:ok, %{source: :active}} = answer
      send(starting, :stop)
    end

    test "a reader whose log an activation took over and erased does not answer from it",
         context do
      context = requires_tier(context)
      a_dormant_session(context)

      follower = held(context)
      assert {:ok, %{last_seq: read}} = Reader.open(context.session_id, reading(context))

      # Activated here and put back to sleep while the reader is still up: the activation
      # took the log over, and its dormancy erased it.
      assert {:ok, _summary} = activate(context, epoch: 2)
      assert {:ok, _summary} = Sessions.dormant(context.session_id)
      assert Reader.whereis(context.session_id)
      refute File.exists?(log_dir(context))

      # Read again from storage, which has what the activation added.
      assert {:ok, %{source: :storage, last_seq: last_seq}} =
               Reader.open(context.session_id, reading(context))

      assert File.exists?(log_path(context))
      assert last_seq > read
      assert Enum.any?(Troupe.replay_from(context.session_id, 0), &(&1.type == "session_dormant"))
      let_go(follower)
    end
  end

  test "a restore waits for a reader that is taking its log away", context do
    context = requires_tier(context)
    a_dormant_session(context)
    holder = holding_the_log(context.session_id)

    {:ok, restore} = Restore.open_context(context.session_id, reading(context))
    task = Task.async(fn -> Restore.events(restore, context.workspace) end)

    refute Task.yield(task, 500)
    refute File.exists?(log_path(context))

    send(holder, :release)
    assert {:ok, _log} = Task.await(task)
    assert File.exists?(log_path(context))
  end

  # -- helpers ----------------------------------------------------------------

  # A session that ran on this pod and went to sleep here, so a reader has to fetch it.
  defp a_dormant_session(context) do
    assert {:ok, _} = activate(context)
    run_turn(context.session_id, "something worth reading")
    assert {:ok, _} = Sessions.dormant(context.session_id)
    refute File.exists?(log_dir(context))
  end

  # A reader kept open by a follower, until `let_go/1`.
  defp held(context, opts \\ []) do
    assert {:ok, %{source: :storage}} = Reader.open(context.session_id, reading(context, opts))
    follower = spawn(fn -> receive do: (:stop -> :ok) end)
    assert :ok = Reader.follow(context.session_id, follower)
    follower
  end

  defp let_go(follower), do: send(follower, :stop)

  # `Restore.with_log/2`'s lock on the session, held until `:release`.
  defp holding_the_log(session_id) do
    test = self()

    holder =
      spawn(fn ->
        Restore.with_log(session_id, fn ->
          send(test, :holding)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :holding
    holder
  end

  defp a_client_reading(session_id) do
    stand_in(fn -> Troupe.attach(session_id) end)
  end

  # Holds the session's manager name, as an activation does from its start.
  defp a_starting_activation(session_id) do
    stand_in(fn ->
      {:ok, _owner} = Registry.register(Troupe.Worker.Session.Registry, session_id, nil)
    end)
  end

  defp stand_in(fun) do
    test = self()

    pid =
      spawn(fn ->
        fun.()
        send(test, {:standing_in, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:standing_in, ^pid}
    pid
  end

  defp log_path(context),
    do: Restore.log_path(context.session_id, context.workspace, context.state_dir)

  defp log_dir(context), do: Path.dirname(log_path(context))

  # What the plane's `session.read` hands a reader on this pod.
  defp reading(context, opts \\ []) do
    [
      session_id: context.session_id,
      team: context.team,
      epoch: 1,
      store: context.store,
      state_dir: context.state_dir,
      workspace: context.workspace
    ] ++ opts
  end
end
