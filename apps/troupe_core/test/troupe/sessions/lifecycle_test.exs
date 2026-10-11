defmodule Troupe.Sessions.LifecycleTest do
  @moduledoc """
  A session's life after D117 (Decision 855): where its files are, how it stops, and what
  a command that arrives while it stops is told.

  - A session's files are under its own state directory, the one its config names, and
    nowhere else: its log, its blobs, its kept outputs. Erasing it leaves nothing behind
    there, running or dormant, and nothing is written under the platform's directory for a
    session that has one of its own.
  - A stop runs in its caller's process, so a tree that takes seconds to come down holds up
    no other session's start or stop.
  - A command for a session being stopped waits for the stop and starts the session afresh,
    and is refused in words when the stop runs past the wait.

  A held stop is a child of the session's supervisor that takes that long to terminate, as
  in `Troupe.Sessions.IndexTest`. Not async: a held stop held `Troupe.Sessions` too, before
  this, and no other test's session should wait on this one's on a tree without the fix.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Paths

  @big String.duplicate("a line of a very long test log\n", 2_000)

  # What a start or a stop that waits on nothing takes, with room to spare.
  @answers_within_ms 1_000

  defmodule Held do
    @moduledoc false
    use GenServer

    def start_link(ms), do: GenServer.start_link(__MODULE__, ms)

    @impl GenServer
    def init(ms) do
      Process.flag(:trap_exit, true)
      {:ok, ms}
    end

    @impl GenServer
    def terminate(_reason, ms), do: Process.sleep(ms)
  end

  describe "a session's files" do
    test "are under the state directory it was started with, and none under the platform's",
         context do
      write_file(context, "big.txt", @big)

      %{session: session} =
        start_session(context,
          steps: [{:tools, [{"read_file", %{"path" => "big.txt"}}]}, {:text, "read it"}]
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "read the log")
      await_state(session.id, [:idle, :done], 10_000)

      [completed] = events_of_type(session.id, "tool_call_completed")
      assert %{"blob" => digest} = completed.data["content"]

      assert [_blob] = dirs(context.state_dir, session.id, ["blobs", hex(digest)])
      assert {:ok, _bytes, _size} = Troupe.read_blob(session.id, digest)
      assert dirs(Paths.state_dir(nil), session.id) == []
    end

    test "are all gone once a running session with state_dir in config.yaml is erased",
         context do
      configure(context)
      write_file(context, "big.txt", @big)

      session =
        start_configured(context, [
          {:tools, [{"read_file", %{"path" => "big.txt"}}]},
          {:text, "read it"}
        ])

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "read the log")
      await_state(session.id, [:idle, :done], 10_000)

      assert [dir] = dirs(context.state_dir, session.id)
      assert File.exists?(Path.join(dir, "events.jsonl"))
      assert [_blobs] = dirs(context.state_dir, session.id, ["blobs"])

      :ok = Troupe.erase_session(session.id)

      assert dirs(context.state_dir, session.id) == []
      assert dirs(Paths.state_dir(nil), session.id) == []
      assert Troupe.get_session(session.id) == nil
    end

    test "are all gone once a dormant session with state_dir in config.yaml is erased",
         context do
      configure(context)
      write_file(context, "big.txt", @big)

      session =
        start_configured(context, [
          {:tools, [{"read_file", %{"path" => "big.txt"}}]},
          {:text, "read it"}
        ])

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "read the log")
      await_state(session.id, [:idle, :done], 10_000)
      :ok = Troupe.stop_session(session.id)

      assert %{state: :dormant} = eventually(fn -> Troupe.get_session(session.id) end)
      assert [_dir] = dirs(context.state_dir, session.id)

      :ok = Troupe.erase_session(session.id)

      assert dirs(context.state_dir, session.id) == []
      assert dirs(Paths.state_dir(nil), session.id) == []
    end
  end

  describe "a stop that takes seconds" do
    test "holds up no other session's start or stop", context do
      %{session: held} = start_session(context)
      hold(held.id, 6_000)

      Troupe.subscribe(held.id)
      stopper = Task.async(fn -> Troupe.stop_session(held.id) end)
      await_event(held.id, :session_dormant, 5_000)
      # Inside the held child's terminate by now.
      Process.sleep(200)

      assert {%{session: other}, ms} = timed(fn -> start_session(context) end)
      assert ms < @answers_within_ms, "a start took #{ms} ms behind a held stop"

      assert {:ok, ms} = timed(fn -> Troupe.stop_session(other.id) end)
      assert ms < @answers_within_ms, "a stop took #{ms} ms behind a held stop"
      refute Process.alive?(other.pid)

      assert Process.alive?(held.pid), "the held stop ended early"
      assert :ok = Task.await(stopper, 15_000)
      refute Process.alive?(held.pid)
    end
  end

  describe "a command for a session that is being stopped" do
    test "waits for the stop and starts the session afresh", context do
      configure(context)
      session = start_configured(context, [])
      hold(session.id, 1_500)

      Troupe.subscribe(session.id)
      stopper = Task.async(fn -> Troupe.stop_session(session.id) end)
      await_event(session.id, :session_dormant, 5_000)

      assert {:ok, pid} = Troupe.activate(session.id)
      refute pid == session.pid, "the command was handed the tree being stopped"
      refute Process.alive?(session.pid)
      assert Process.alive?(pid)

      assert :ok = Task.await(stopper, 10_000)
      assert "session_activated" in event_types(session.id)
    end

    test "is refused in words when the stop runs past the wait", context do
      configure(context)
      session = start_configured(context, [])
      hold(session.id, 8_000)

      Troupe.subscribe(session.id)
      stopper = Task.async(fn -> Troupe.stop_session(session.id) end)
      await_event(session.id, :session_dormant, 5_000)

      assert {{:error, :stopping}, ms} = timed(fn -> Troupe.activate(session.id) end)
      assert ms < 7_000, "the refusal took #{ms} ms"
      assert Process.alive?(session.pid)

      assert :ok = Task.await(stopper, 15_000)
    end
  end

  # -- helpers ----------------------------------------------------------------

  # The session's settings in the workspace's own `config.yaml`, `state_dir` among them,
  # so that what a session is started with and what it is woken with are the same.
  defp configure(context) do
    write_file(context, ".troupe/config.yaml", """
    version: 1
    provider: fake
    model: fake-model
    auto_approve: true
    state_dir: #{Jason.encode!(context.state_dir)}
    """)
  end

  # Started as a client starts one: from the files alone, with no `state_dir` override.
  defp start_configured(context, steps) do
    fake =
      start_supervised!(
        Supervisor.child_spec({Troupe.LLM.Fake, steps: steps, default: {:text, "done"}},
          id: {Troupe.LLM.Fake, make_ref()}
        )
      )

    {:ok, session} = Troupe.start_session(workspace: context.workspace, fake: fake)
    on_exit(fn -> Troupe.stop_session(session.id) end)
    session
  end

  # Appended to the session's supervisor, so it is the first child stopped and the rest of
  # the tree waits on it.
  defp hold(session_id, ms) do
    {:ok, _} =
      Supervisor.start_child(Registry.session(session_id), %{
        id: :held,
        start: {Held, :start_link, [ms]},
        shutdown: ms * 2
      })

    :ok
  end

  # Every directory named for the session under a state directory, or a path below one.
  defp dirs(state_dir, session_id, below \\ []) do
    [Paths.glob_escape(state_dir), "sessions", "*", Paths.glob_escape(session_id) | below]
    |> Path.join()
    |> Path.wildcard()
  end

  defp hex("sha256:" <> hex), do: hex

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {result, div(us, 1_000)}
  end

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 -> Process.sleep(100) && eventually(fun, tries - 1)
      %{state: :active} when tries > 0 -> Process.sleep(100) && eventually(fun, tries - 1)
      result -> result
    end
  end
end
