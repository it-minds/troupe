defmodule Troupe.Sessions.LifespanTest do
  @moduledoc """
  How long a session on this computer lasts (#1209): a mark beside its log, absent for
  normal, set on a dormant session as on a running one; and the daemon's sweep, which
  erases a local throwaway session once its window has passed since it last worked, asleep
  with nothing waiting and not kept at the top, and nothing else: never a normal or a
  persistent one, never a private one (the plane's), never one still in its window.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Sessions.{Index, Lifespan}

  @now ~U[2026-11-25 12:00:00Z]

  defp row(fields) do
    Map.merge(
      %{
        id: "s-#{System.unique_integer([:positive])}",
        kind: "local",
        state: :dormant,
        lifespan: "throwaway",
        pinned: false,
        pending_approvals: 0,
        pending_questions: 0,
        last_active_at: DateTime.to_iso8601(DateTime.add(@now, -25 * 3600, :second))
      },
      Map.new(fields)
    )
  end

  defp swept(rows, hours \\ 24) do
    test = self()

    Lifespan.sweep(rows,
      now: @now,
      hours: hours,
      erase: fn id ->
        send(test, {:erased, id})
        :ok
      end
    )
  end

  test "a local throwaway session asleep past its window is erased, and nothing else is" do
    gone = row([])

    kept = [
      row(lifespan: "normal"),
      row(lifespan: "persistent"),
      row(kind: "private"),
      row(state: :active),
      row(pinned: true),
      row(pending_questions: 1),
      row(pending_approvals: 1),
      row(last_active_at: DateTime.to_iso8601(DateTime.add(@now, -23 * 3600, :second)))
    ]

    assert swept([gone | kept]) == [gone.id]
    assert_received {:erased, id} when id == gone.id
    refute_received {:erased, _}

    # A persistent one survives however far the clock runs.
    far = row(lifespan: "persistent", last_active_at: "2000-01-01T00:00:00Z")
    assert swept([far], 1) == []
  end

  test "the window is the configuration's, 1 to 168 hours, 24 where it says none" do
    assert Lifespan.hours(%{throwaway_erase_after_hours: 2}) == 2
    assert Lifespan.hours(%{throwaway_erase_after_hours: 1_000}) == 168
    assert Lifespan.hours(nil) == 24
    assert swept([row([])], 26) == []
  end

  test "the mark is set on a running session and read while it is dormant; normal is none",
       context do
    %{session: session} = start_session(context)
    assert Lifespan.of(session.id) == "normal"
    assert :ok = Troupe.lifespan_session(session.id, "throwaway", "someone")
    assert Lifespan.of(session.id) == "throwaway"

    :ok = Troupe.stop_session(session.id)

    eventually(fn -> match?(%{state: :dormant, lifespan: "throwaway"}, Index.get(session.id)) end)
    assert :ok = Troupe.lifespan_session(session.id, "normal", "someone")
    eventually(fn -> match?(%{lifespan: "normal"}, Index.get(session.id)) end)

    assert {:error, :invalid} = Lifespan.put(session.id, "forever")
    assert {:error, :not_found} = Lifespan.put("20000101T000000-nobody", "normal")
  end

  test "a real throwaway session past its window is erased, its directory with it", context do
    %{session: session} = start_session(context)
    :ok = Troupe.lifespan_session(session.id, "throwaway", "someone")
    :ok = Troupe.stop_session(session.id)
    eventually(fn -> match?(%{state: :dormant}, Index.get(session.id)) end)

    listed = Troupe.list_live_sessions(%{"lifespan" => "throwaway", "state" => ["dormant"]})
    assert [%{id: id}] = Enum.filter(listed, &(&1.id == session.id))

    later = DateTime.add(DateTime.utc_now(), 25 * 3600, :second)
    assert Lifespan.sweep(listed, now: later, hours: 24) == [id]
    assert Index.get(id) == nil
    assert {:error, :not_found} = Troupe.erase_session(id)
  end
end
