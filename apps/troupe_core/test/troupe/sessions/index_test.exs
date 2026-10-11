defmodule Troupe.Sessions.IndexTest do
  @moduledoc """
  The index never waits on a session (Decision 848). The sweep stopped each session
  it found asleep inside the index's own process, and a stop is the session's whole tree
  coming down, up to thirty seconds of it; every caller of the index waited behind it, and
  a 5-second call timed out. A listing likewise asked each live session's summary from
  inside the index.

  Here a session's stop is held for several seconds by a child that takes that long to
  terminate, and the index is asked meanwhile. The sweeping is a private
  `Troupe.Sessions.Index` on short clocks, as in `Troupe.Session.SleepTest`, and the test
  follows the session's events as `:internal`, so that nobody counts as watching.

  Not async: a held stop held `Troupe.Sessions` too, whose `terminate_child` ran the whole
  shutdown until Decision 855, and on a tree without that no other test's session should
  wait on this one's. The rest of the index's life after D117 is Decision 855's: an agent
  slow to answer, the state directories it reads, and the rows it keeps between listings.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Events
  alias Troupe.Session.Log
  alias Troupe.Sessions.Index

  # Longer than a call's default five seconds, so a caller that waited on the stop would
  # time out, as the callers under load did.
  @hold_ms 6_000

  # What a call that waits on nothing takes, with room to spare.
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

  describe "while the sweep stops a session whose tree takes seconds to come down" do
    test "the index answers at once, says the session is not running, and stops it once",
         context do
      %{session: held} = start_session(context)
      sid = held.id

      # Appended to the session's supervisor, so it is the first child stopped and the rest
      # of the tree waits on it.
      {:ok, _} =
        Supervisor.start_child(Registry.session(sid), %{
          id: :held,
          start: {Held, :start_link, [@hold_ms]},
          shutdown: @hold_ms * 2
        })

      follow(sid)
      index = sweep(context, [held])
      await_event(sid, :session_dormant, 10_000)

      # The stop has begun and is held. Every kind of call answers in its usual time.
      assert {ids, ms} = timed(fn -> GenServer.call(index, :live_ids) end)
      assert ms < @answers_within_ms, "live_ids took #{ms} ms"
      refute sid in ids, "a session being stopped was handed out as running"

      assert {%{state: :dormant}, ms} = timed(fn -> GenServer.call(index, {:get, sid}) end)
      assert ms < @answers_within_ms, "get took #{ms} ms"

      assert {listed, ms} = timed(fn -> GenServer.call(index, {:list, %{}}) end)
      assert ms < @answers_within_ms, "list took #{ms} ms"
      assert %{state: :dormant} = Enum.find(listed, &(&1.id == sid))

      # Dozens of sweeps go by while it is held, and none of them stops it again.
      Process.sleep(500)
      assert dormant_marks(context, sid) == 1

      gone(sid, @hold_ms + 5_000)
      assert dormant_marks(context, sid) == 1
      refute sid in GenServer.call(index, :live_ids)
    end
  end

  describe "a live session that does not answer" do
    test "holds up no other caller of the index", context do
      %{session: stuck} = start_session(context)
      %{session: other} = start_session(context)
      index = listing(context, [stuck, other])

      summary = Registry.whereis({:summary, stuck.id})
      :ok = :sys.suspend(summary)

      # Reading the stuck session waits on its summary for as long as a call does.
      spawn(fn -> GenServer.call(index, {:get, stuck.id}) end)
      Process.sleep(100)

      assert {%{id: id, state: :active}, ms} =
               timed(fn -> GenServer.call(index, {:get, other.id}) end)

      assert id == other.id
      assert ms < @answers_within_ms, "get took #{ms} ms"

      assert {ids, ms} = timed(fn -> GenServer.call(index, :live_ids) end)
      assert ms < @answers_within_ms, "live_ids took #{ms} ms"
      assert Enum.sort(ids) == Enum.sort([stuck.id, other.id])

      :sys.resume(summary)
    end
  end

  # Decision 855: an agent that does not answer its snapshot within five seconds is busy
  # with something, not gone. Taken for gone, its entry was dropped while its tree ran on:
  # listed as dormant, and never swept again.
  describe "an agent slow to answer the sweep" do
    test "is kept as running, and put to sleep once it answers", context do
      %{session: slow} = start_session(context)
      follow(slow.id)

      agent = Registry.agent_pid(slow.id, ["root"])
      :ok = :sys.suspend(agent)
      index = sweep(context, [slow])

      # Longer than a snapshot's five seconds, and many sweeps' worth.
      Process.sleep(6_500)
      assert slow.id in GenServer.call(index, :live_ids)
      assert %{state: :active} = GenServer.call(index, {:get, slow.id})

      :ok = :sys.resume(agent)
      await_event(slow.id, :session_dormant, 15_000)
      gone(slow.id, 10_000)
    end
  end

  # Decision 855: the index reads the state directory `config.yaml` names as well as the
  # platform's, and every one a session it was told of was started with.
  describe "a dormant session outside the platform's state directory" do
    test "is listed and found when it is in the state directory config.yaml names", context do
      configured = Path.join(context.base, "configured")
      user = Path.join(context.base, "user/config.yaml")
      File.mkdir_p!(Path.dirname(user))
      File.write!(user, "version: 1\nstate_dir: #{Jason.encode!(configured)}\n")
      recorded(configured, context.workspace, "configured-open", "open")

      index =
        index(context, [],
          session_idle_ms: :infinity,
          detached_idle_ms: :infinity,
          user_path: user
        )

      assert %{state: :dormant, status: :waiting} =
               index |> GenServer.call({:list, %{}}) |> Enum.find(&(&1.id == "configured-open"))

      assert %{state: :dormant} = GenServer.call(index, {:get, "configured-open"})
    end

    test "is listed once it stops when it was started with a state directory of its own",
         context do
      %{session: session} = start_session(context)
      elsewhere = Path.join(context.base, "elsewhere")
      File.mkdir_p!(elsewhere)

      opts = [state_dir: elsewhere, session_idle_ms: :infinity, detached_idle_ms: :infinity]

      index =
        start_supervised!(%{
          id: {Index, make_ref()},
          start: {GenServer, :start_link, [Index, opts]}
        })

      GenServer.cast(
        index,
        {:register, session.id, session.pid,
         %{workspace: context.workspace, profile: "build", state_dir: context.state_dir}}
      )

      assert session.id in GenServer.call(index, :live_ids)
      :ok = Troupe.stop_session(session.id)
      gone(session.id, 5_000)

      assert %{state: :dormant} =
               index |> GenServer.call({:list, %{}}) |> Enum.find(&(&1.id == session.id))
    end
  end

  # Decision 855: a listing reads a dormant session's log when the log is new to it or has
  # changed since, by its size and modification time, and otherwise uses what it read then.
  describe "a dormant session's row" do
    test "is read from its log once, and again when the log changes", context do
      path = recorded(context.state_dir, context.workspace, "recorded-open", "open")
      index = listing(context, [])

      assert %{status: :waiting} = row(index, "recorded-open")

      # Other bytes of the same size at the same time: not read again.
      %File.Stat{mtime: mtime, size: size} = File.stat!(path, time: :posix)
      File.write!(path, String.duplicate(" ", size))
      File.touch!(path, mtime)
      assert %{status: :waiting} = row(index, "recorded-open")

      # Another log: read again.
      File.cp!(fixture("decided"), path)
      assert %{status: :idle} = row(index, "recorded-open")
    end

    # A reader that comes and goes within a second rewrites the mark with as many digits
    # at the same time; what is unseen follows the mark's value.
    test "follows the seen mark beside the log, rewritten within the same second", context do
      path = recorded(context.state_dir, context.workspace, "recorded-seen", "open")
      seen = Path.join(Path.dirname(path), "seen")
      File.write!(seen, "1")
      index = listing(context, [])

      assert %{unseen: %{approvals: 1}} = row(index, "recorded-seen")

      %File.Stat{mtime: mtime} = File.stat!(seen, time: :posix)
      File.write!(seen, "8")
      File.touch!(seen, mtime)
      assert %{unseen: %{approvals: 0}} = row(index, "recorded-seen")
    end
  end

  # #589: every file operation in the VM that takes a name is a call to one process, the
  # file server, and a listing's glob was one call for every directory under every state
  # directory. Under the full suite's load each waited behind everyone else's, and `list`
  # took longer than its fifteen seconds. Here the file server is held while a listing that
  # has read nothing yet, a `get` and a log's search are asked: each answers without it.
  describe "with the file server held" do
    test "a listing, a get and the search for a log answer without it", context do
      ids = for i <- 1..20, do: "held-#{i}"

      for {id, i} <- Enum.with_index(ids),
          do: recorded(context.state_dir, Path.join(context.base, "ws-#{rem(i, 4)}"), id, "open")

      # Everything a listing runs, loaded before the file server is held, on an index of its
      # own: the one asked below has read no log yet.
      _ = context |> listing([]) |> GenServer.call({:list, %{}})
      index = listing(context, [])
      server = Process.whereis(:file_server_2)
      :ok = :sys.suspend(server)

      try do
        assert {rows, ms} = timed(fn -> GenServer.call(index, {:list, %{}}, 5_000) end)
        assert ms < @answers_within_ms, "list took #{ms} ms"
        assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort(ids)

        assert {%{state: :dormant, status: :waiting}, ms} =
                 timed(fn -> GenServer.call(index, {:get, "held-7"}, 5_000) end)

        assert ms < @answers_within_ms, "get took #{ms} ms"

        # In a task: a search that waited on the file server would wait for as long as it is
        # held, and this test must get to let it go.
        search = Task.async(fn -> timed(fn -> Log.locate("held-7", context.state_dir) end) end)
        assert {:ok, {path, ms}} = Task.yield(search, 5_000) || Task.shutdown(search)
        assert ms < @answers_within_ms, "locate took #{ms} ms"
        assert Path.basename(Path.dirname(path)) == "held-7"
      after
        :sys.resume(server)
      end
    end
  end

  # -- helpers ----------------------------------------------------------------

  @fixtures Path.expand(Path.join([File.cwd!(), "..", "..", "test", "fixtures", "approvals"]))

  defp fixture(name), do: Path.join(@fixtures, name <> ".jsonl")

  # A session real sessions recorded, put in a state directory as its log.
  defp recorded(state_dir, workspace, id, name) do
    dir = Troupe.Paths.session_dir(workspace, id, state_dir)
    File.mkdir_p!(dir)
    path = Path.join(dir, "events.jsonl")
    File.cp!(fixture(name), path)
    path
  end

  defp row(index, id), do: index |> GenServer.call({:list, %{}}) |> Enum.find(&(&1.id == id))

  # Seeing the session's events without counting as somebody watching it.
  defp follow(sid), do: :ok = Events.subscribe(sid, :internal)

  # A private index over this test's state directory, on clocks short enough to test.
  defp sweep(context, sessions) do
    clocks = [session_idle_ms: :timer.hours(1), detached_idle_ms: 100, sweep_ms: 20]
    index(context, sessions, clocks)
  end

  # One that only lists.
  defp listing(context, sessions) do
    index(context, sessions, session_idle_ms: :infinity, detached_idle_ms: :infinity)
  end

  defp index(context, sessions, opts) do
    index =
      start_supervised!(%{
        id: {Index, make_ref()},
        start: {GenServer, :start_link, [Index, [state_dir: context.state_dir] ++ opts]}
      })

    for session <- sessions do
      GenServer.cast(
        index,
        {:register, session.id, session.pid, %{workspace: context.workspace, profile: "build"}}
      )
    end

    index
  end

  # Each stop writes one before its tree comes down.
  defp dormant_marks(context, sid) do
    sid |> Log.read_session(context.state_dir) |> Enum.count(&(&1.type == "session_dormant"))
  end

  defp timed(fun) do
    {us, result} = :timer.tc(fun)
    {result, div(us, 1_000)}
  end

  defp gone(sid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(fn -> is_nil(Registry.whereis({:session, sid})) end, deadline)
  end

  defp poll(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("the session never stopped")
      true -> Process.sleep(50) && poll(fun, deadline)
    end
  end
end
