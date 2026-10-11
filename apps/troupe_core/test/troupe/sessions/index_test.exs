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

  Not async: a held stop holds `Troupe.Sessions` too, whose `terminate_child` runs the whole
  shutdown, and no other test's session should wait on this one's.
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

  # -- helpers ----------------------------------------------------------------

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
