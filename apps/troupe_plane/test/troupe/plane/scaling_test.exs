defmodule Troupe.Plane.ScalingTest do
  @moduledoc """
  Capacity, without a capacity question.

  `Placement` has always been a per-profile capacity controller with exactly the data an
  autoscaler would want, and its own documentation said what should happen when it
  refused: *it means the profile needs more replicas, and the caller should say so*. The
  system knew it needed another worker and its answer was to tell a person to go and type
  a number — and the refusal landed on whoever created the thirty-third session, for a
  number their administrator had guessed three weeks earlier.

  The claims are what the arithmetic is, that a full-but-growing profile makes somebody
  wait rather than refusing them, that a refusal survives only where a person set a
  ceiling and quotes them, and that a profile with nothing running ends up with no
  workers — which at this scale is worth more than scaling up.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{FakePod, Fleet, Harness, Sessions}
  alias Troupe.Plane.Fleet.{Scaler, SizeClass}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    {:ok, profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 0})

    %{team: team, ada: ada, profile: profile, caller: %{user: ada, platform_admin?: false}}
  end

  describe "the size class" do
    test "decides the seven numbers that left the admin surface", context do
      {:ok, standard} = Fleet.put_profile(%{name: "dev", size_class: "standard"})
      assert standard.sessions_per_pod == 4

      {:ok, heavy} = Fleet.put_profile(%{name: "dev", size_class: "heavy"})
      assert heavy.sessions_per_pod == 2

      # Resources and storage follow it into the custom resource, where they belong. An
      # administrator answers one question and the plane writes seven fields.
      spec = SizeClass.spec("heavy")
      assert spec["sessionsPerPod"] == 2
      assert get_in(spec, ["resources", "limits", "cpu"]) == "4"
      assert spec["storage"]["size"] == "100Gi"

      # And both classes sit under the policy this release ships, so a deployment that
      # has never written a TroupePolicy gets both.
      assert get_in(SizeClass.spec("heavy"), ["resources", "limits", "memory"]) == "8Gi"
    end

    test "is refused when it is not one of the two", _context do
      assert {:error, changeset} = Fleet.put_profile(%{name: "dev", size_class: "isolated"})
      assert changeset.errors[:size_class]
    end
  end

  describe "the arithmetic" do
    test "asks for the workers the sessions need, and no more", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard"})

      assert %{want: 0, active: 0, pending: 0} = plan(context)

      # Four fit on one worker; the fifth needs a second.
      seed(context, active: 4)
      assert %{want: 1} = plan(context)

      seed(context, active: 5)
      assert %{want: 2} = plan(context)

      # Sessions that are waiting count too. A count of the active alone would settle at
      # exactly the capacity that is already full.
      seed(context, active: 4, pending: 4)
      assert %{want: 2, pending: 4} = plan(context)
    end

    test "keeps a warm worker where somebody asked for one", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard", warm_workers: 1})

      assert %{want: 1} = plan(context)

      seed(context, active: 5)
      assert %{want: 3} = plan(context)
    end

    test "stops at the ceiling, and says which one", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard", max_sessions: 10})

      seed(context, active: 40)

      # Ten sessions at a time is three workers of four. The ceiling is in *sessions*,
      # because that is the number an administrator chose and the number a refusal quotes.
      assert %{want: 3, capped_by: :max_sessions, max_sessions: 10} = plan(context)
    end
  end

  describe "a profile with nothing running" do
    test "goes to zero, but not before the grace period", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard", replicas: 2})

      # First tick: found empty, clock started, worker kept. A profile whose last session
      # went dormant a minute ago is very often one somebody is about to wake.
      now = ~U[2026-09-16 12:00:00.000000Z]
      assert [%{want: want}] = Scaler.tick(now)
      assert want > 0
      assert Fleet.get_profile("dev").idle_since == now

      # Three minutes later, nothing has happened here.
      assert [%{want: 0, changed: _}] = Scaler.tick(DateTime.add(now, 180, :second))
      assert Fleet.get_profile("dev").replicas == 0
    end

    test "and the clock is cleared the moment something runs", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard", replicas: 1})

      now = ~U[2026-09-16 12:00:00.000000Z]
      Scaler.tick(now)
      assert Fleet.get_profile("dev").idle_since == now

      seed(context, active: 1)
      Scaler.tick(DateTime.add(now, 30, :second))
      assert is_nil(Fleet.get_profile("dev").idle_since)

      # And it does not go to zero while that session is running, however long it waits.
      assert [%{want: 1}] = Scaler.tick(DateTime.add(now, 600, :second))
    end

    test "keeps its worker where somebody asked for one warm", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", warm_workers: 1, replicas: 1})

      now = ~U[2026-09-16 12:00:00.000000Z]
      Scaler.tick(now)
      assert [%{want: 1}] = Scaler.tick(DateTime.add(now, 600, :second))
    end
  end

  describe "a session on a full profile" do
    test "waits, and is given no endpoint to pretend with", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard"})
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)

      assert {:ok, first} = create(context)
      assert_receive {:pushed, "session.activate", _}, 5_000
      assert is_binary(first["token"])

      # The pod is full and the profile has no ceiling, so the plane is already asking
      # for another worker rather than refusing the person in front of it.
      assert {:ok, second} = create(context)
      assert second["state"] == "pending"
      assert is_binary(second["session_id"])
      refute Map.has_key?(second, "token")
      refute Map.has_key?(second, "endpoint")
      assert second["retry_after_ms"] > 0

      # The wait is visible: the session exists and says what it is doing.
      assert {:ok, listed} =
               Harness.call("session.get", %{"session_id" => second["session_id"]}, context.caller)

      assert listed["state"] == "pending"

      # And asking again gets the same answer rather than an error to special-case.
      assert {:ok, again} =
               Harness.call("token.mint", %{"session_id" => second["session_id"]}, context.caller)

      assert again["state"] == "pending"

      # The scaler sees the demand: one running, one waiting, two workers' worth.
      assert %{active: 1, pending: 1} = plan(context)
    end

    test "is placed when the room arrives, and is then indistinguishable", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard"})
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)

      {:ok, _first} = create(context)
      assert_receive {:pushed, "session.activate", _}, 5_000

      {:ok, waiting} = create(context, prompt: "the thing I asked for")
      assert waiting["state"] == "pending"

      # A second worker arrives, as the scaler asked for.
      _second_pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-1", capacity: 1)
      Scaler.tick()

      assert_receive {:pushed, "session.activate", pushed}, 5_000

      # The same push a session that never waited would have got, prompt included: a wait
      # that dropped the prompt would produce a session that started and then sat there.
      assert pushed["session_id"] == waiting["session_id"]
      assert pushed["prompt"] == "the thing I asked for"

      placed = Sessions.get(waiting["session_id"])
      assert placed.state == "active"
      assert is_nil(placed.pending_prompt)
      assert placed.worker_id

      # And now there is a token, from the same method that answered `pending` a moment
      # ago.
      assert {:ok, endpoint} =
               Harness.call("token.mint", %{"session_id" => placed.id}, context.caller)

      assert is_binary(endpoint["token"])
    end

    test "is refused only at a ceiling a person set, and told the number", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard", max_sessions: 1})
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)

      assert {:ok, _first} = create(context)
      assert_receive {:pushed, "session.activate", _}, 5_000

      assert {:error, error} = create(context)
      assert error.message == "capacity"

      # The refusal names the decision rather than the machine that noticed it. "Every
      # pod is full, ask your administrator to add replicas" is not something anybody can
      # act on; this is.
      assert error.data.max_sessions == 1
      assert error.data.reason =~ "allows 1 session"

      # Refused means nothing left behind: no row and no budget held.
      assert Sessions.demand_for("dev") == %{active: 1, pending: 0}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp plan(_context), do: Scaler.plan(Fleet.get_profile("dev"))

  defp create(context, opts \\ []) do
    Harness.call(
      "session.create",
      %{
        "profile" => "dev",
        "team" => "engineering",
        "prompt" => Keyword.get(opts, :prompt, "hello")
      },
      context.caller
    )
  end

  # Rows straight into the index. What is under test here is the arithmetic over a count,
  # and driving it through `session.create` would need as many pods as sessions.
  defp seed(context, counts) do
    Repo.delete_all(Troupe.Plane.Sessions.Session)

    for state <- [:active, :pending], n <- 1..Keyword.get(counts, state, 0)//1 do
      {:ok, _} =
        Sessions.create(%{
          id: "s-#{state}-#{n}",
          owner_id: context.ada.id,
          owner_subject: context.ada.subject,
          team_id: context.team.id,
          profile: "dev",
          kind: "team",
          visibility: "private",
          state: to_string(state),
          epoch: 1
        })
    end
  end
end
