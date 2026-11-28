defmodule Troupe.Plane.SessionLifespanSweepTest do
  @moduledoc """
  The plane erases a throwaway session once its window has passed since it last worked
  (#1209): asleep, with nothing waiting, not awaiting review and not kept at the top;
  through the erasure every session has, with a tombstone and an audit row as
  `system:lifespan`. Nothing else is ever erased by it: a normal session, a persistent one
  however far the clock runs, a throwaway one still in its window or kept by any of those.
  The window is the setting `throwaway_erase_after_hours`, and every row says when.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Erasure, Harness, Sessions, Settings}
  alias Troupe.Plane.Sessions.{Lifespan, Tombstone}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Troupe.Plane.Control.Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Task.Supervisor, name: Erasure.Tasks})

    team = team_with_grant("eng", "dev", name: "eng")
    ada = person("ada@example.test", ["eng"])
    now = DateTime.utc_now()

    %{team: team, ada: ada, now: now}
  end

  test "a throwaway session asleep past its window is erased, as system:lifespan", context do
    gone = session(context, lifespan: "throwaway", quiet_hours: 25)

    assert %{erased: 1, failed: []} = Lifespan.sweep(context.now)

    assert Sessions.get(gone).state in ["erasure_pending", "erased"]
    assert %Tombstone{actor: "system:lifespan", reason: "throwaway"} = Repo.get_by(Tombstone, session_id: gone)

    assert [row] = Repo.all(from(a in Audit.Event, where: a.action == "session.erase" and a.subject_id == ^gone))
    assert row.actor == "system:lifespan"
    assert row.detail["by"] == "lifespan"
    assert row.detail["hours"] == 24

    # Taken once: the next pass finds nothing.
    assert %{erased: 0} = Lifespan.sweep(context.now)
  end

  test "nothing that is not throwaway is ever erased, however far the clock runs", context do
    persistent = session(context, lifespan: "persistent", quiet_hours: 25)
    normal = session(context, lifespan: "normal", quiet_hours: 25)

    far = DateTime.add(context.now, 3650 * 86_400, :second)
    assert %{erased: 0} = Lifespan.sweep(far)

    for id <- [persistent, normal] do
      assert Sessions.get(id).state == "dormant"
      refute Repo.get_by(Tombstone, session_id: id)
    end
  end

  test "a throwaway session is kept while anything says to keep it", context do
    kept = [
      within_window: session(context, lifespan: "throwaway", quiet_hours: 23),
      awake: session(context, lifespan: "throwaway", quiet_hours: 25, state: "active"),
      waits_on_a_question: session(context, lifespan: "throwaway", quiet_hours: 25, pending_questions: 1),
      waits_on_an_approval: session(context, lifespan: "throwaway", quiet_hours: 25, pending_approvals: 1),
      kept_at_the_top: session(context, lifespan: "throwaway", quiet_hours: 25, pinned: true),
      unreviewed_trigger_run:
        session(context,
          lifespan: "throwaway",
          quiet_hours: 25,
          origin: %{"kind" => "trigger", "trigger" => "nightly"}
        )
    ]

    assert %{erased: 0} = Lifespan.sweep(context.now)

    for {why, id} <- kept do
      refute Repo.get_by(Tombstone, session_id: id), "#{why} was erased"
    end

    # Reviewed, the trigger's run goes at the next pass.
    {:ok, _} = Sessions.review(kept[:unreviewed_trigger_run], context.ada.subject)
    assert %{erased: 1} = Lifespan.sweep(context.now)
    assert Repo.get_by(Tombstone, session_id: kept[:unreviewed_trigger_run])
  end

  test "a throwaway run of a trigger that asks for no review is erased without one", context do
    none = %{"kind" => "trigger", "trigger" => "routine", "review" => "none"}
    required = %{"kind" => "trigger", "trigger" => "careful", "review" => "required"}
    before_reviews = %{"kind" => "trigger", "trigger" => "old"}

    routine = session(context, lifespan: "throwaway", quiet_hours: 25, origin: none)
    careful = session(context, lifespan: "throwaway", quiet_hours: 25, origin: required)
    old = session(context, lifespan: "throwaway", quiet_hours: 25, origin: before_reviews)

    assert %{erased: 1} = Lifespan.sweep(context.now)

    assert Repo.get_by(Tombstone, session_id: routine)
    refute Repo.get_by(Tombstone, session_id: careful)
    refute Repo.get_by(Tombstone, session_id: old)
  end

  test "a private throwaway session is erased from its row, its last seal being when it last worked",
       context do
    private = SessionId.generate()

    {:ok, _row} =
      Harness.call(
        "session.register",
        %{"session_id" => private, "device" => "laptop", "lifespan" => "throwaway"},
        %{user: context.ada, platform_admin?: false}
      )

    assert %{erased: 0} = Lifespan.sweep(context.now)

    later = DateTime.add(context.now, 25 * 3600, :second)
    assert %{erased: 1} = Lifespan.sweep(later)
    assert %Tombstone{actor: "system:lifespan"} = Repo.get_by(Tombstone, session_id: private)
  end

  test "the window is the setting, and every row says when it ends", context do
    {:ok, _} = Settings.put("throwaway_erase_after_hours", "2", "root@example.test")
    on_exit(fn -> Settings.reset("throwaway_erase_after_hours", "root@example.test") end)

    assert {:error, {:invalid, _}} = Settings.put("throwaway_erase_after_hours", "0", "root@example.test")
    assert {:error, {:invalid, _}} = Settings.put("throwaway_erase_after_hours", "169", "root@example.test")
    assert Lifespan.hours() == 2

    soon = session(context, lifespan: "throwaway", quiet_hours: 1)
    _normal = session(context, lifespan: "normal", quiet_hours: 1)

    assert {:ok, %{"sessions" => rows}} =
             Harness.call("sessions.list", %{}, %{user: context.ada, platform_admin?: false})

    by_id = Map.new(rows, &{&1["id"], &1})
    at = Sessions.get(soon).last_active_at |> DateTime.add(2 * 3600, :second) |> DateTime.to_iso8601()
    assert by_id[soon]["erases_at"] == at
    assert [nil] = rows |> Enum.reject(&(&1["id"] == soon)) |> Enum.map(& &1["erases_at"])

    assert %{erased: 0} = Lifespan.sweep(context.now)
    assert %{erased: 1} = Lifespan.sweep(DateTime.add(context.now, 3600 + 60, :second))
  end

  test "a session put to sleep is counted from then: it was active until it slept", context do
    id = session(context, lifespan: "throwaway", quiet_hours: 30, state: "active")
    {:ok, _} = Sessions.dormant(id)

    assert %{erased: 0} = Lifespan.sweep(context.now)
    assert %{erased: 1} = Lifespan.sweep(DateTime.add(context.now, 25 * 3600, :second))
  end

  defp session(context, opts) do
    quiet = Keyword.fetch!(opts, :quiet_hours)

    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: "dev",
        visibility: "private",
        lifespan: Keyword.fetch!(opts, :lifespan),
        state: Keyword.get(opts, :state, "dormant"),
        epoch: 1,
        last_active_at: DateTime.add(context.now, -quiet * 3600, :second),
        pending_questions: Keyword.get(opts, :pending_questions, 0),
        pending_approvals: Keyword.get(opts, :pending_approvals, 0),
        pinned: Keyword.get(opts, :pinned, false),
        origin: Keyword.get(opts, :origin)
      })

    session.id
  end
end
