defmodule Troupe.Plane.GrantEnforcementTest do
  @moduledoc """
  A team's grant on a profile is what lets its sessions run there, and taking it away
  holds everywhere a session could still be running or be started from.

  Revoking parks the team's sessions on the profile read-only (Decision 694), which is
  the plane's row. The rest is here: the pod that is running one, a session still waiting
  for room, the owner waking one, and the scaler starting one that waited. Each of them
  could otherwise run a session the grant no longer covers (Decision 697).
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{FakePod, Fleet, Harness, Identity, Ledger, Sessions, TeamBudget}
  alias Troupe.Plane.Fleet.Scaler
  alias Troupe.Plane.Identity.Grant

  @moduletag timeout: 60_000

  # What a session reserves against its team when its terms name no slice.
  @slice 5_000_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 100 * @slice)
    ada = person("ada@example.test", ["engineering"])
    {:ok, _} = Fleet.put_profile(%{name: "dev", size_class: "standard"})

    %{team: team, ada: ada, caller: %{user: ada, platform_admin?: false}}
  end

  describe "revoking a grant" do
    test "tells the pod running a session of the team's to put it to sleep", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 4)
      id = running!(context)

      :ok = Identity.revoke(context.team, "dev")

      assert Sessions.get(id).state == "read_only"
      assert_receive {:pushed, "session.dormant", %{"session_id" => ^id}}, 5_000
    end

    test "parks a session waiting for room, and gives back what it holds", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)
      _running = running!(context)

      assert {:ok, %{"state" => "pending", "session_id" => waiting}} =
               create(context, "the thing I asked for")

      assert TeamBudget.inspect_state(context.team).reserved_micros == 2 * @slice

      :ok = Identity.revoke(context.team, "dev")

      parked = Sessions.get(waiting)
      assert parked.state == "read_only"
      assert is_nil(parked.pending_prompt)
      assert TeamBudget.inspect_state(context.team).reserved_micros == 0
      assert Ledger.open_reservations() == %{}

      # Room arrives, and the scaler has nothing of the team's left to start there.
      _second = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-1", capacity: 1)
      Scaler.tick()

      refute_receive {:pushed, "session.activate", %{"session_id" => ^waiting}}, 500
      assert Sessions.get(waiting).state == "read_only"
    end
  end

  describe "waking a session" do
    test "is refused when its team no longer holds the grant, whatever the row says", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 4)
      session = dormant!(context, context.team.id)

      # The grant gone and the row still dormant: what a pod's late dormancy report used
      # to leave behind a revoke.
      Repo.delete_all(from(g in Grant, where: g.team_id == ^context.team.id))

      assert {:error, error} = open(session, context)
      assert error.message == "forbidden"

      assert Sessions.get(session.id).state == "dormant"
      assert Sessions.get(session.id).epoch == 1
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "is refused when its team is gone", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 4)
      session = dormant!(context, context.team.id)

      # The team's row goes and the session's `team_id` with it.
      {:ok, _} = Identity.disable_team(context.team)
      assert is_nil(Sessions.get(session.id).team_id)

      assert {:error, %{message: "forbidden"}} = open(session, context)
      assert Sessions.get(session.id).epoch == 1
      refute_receive {:pushed, "session.activate", _}, 300
    end
  end

  describe "a session that waited for room" do
    test "is parked rather than started once its team no longer holds the grant", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)
      _running = running!(context)
      {:ok, %{"state" => "pending", "session_id" => waiting}} = create(context, "later")

      Repo.delete_all(from(g in Grant, where: g.team_id == ^context.team.id))

      %{worker_id: room} =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-1", capacity: 1)

      assert {:error, :no_grant} = Harness.admit(Sessions.get(waiting))

      parked = Sessions.get(waiting)
      assert parked.state == "read_only"
      assert is_nil(parked.worker_id)
      assert TeamBudget.inspect_state(context.team).reserved_micros == @slice
      assert Map.get(placement("dev").capacities, room, 0) == 0
      refute_receive {:pushed, "session.activate", %{"session_id" => ^waiting}}, 300
    end

    test "is parked rather than put on a pod once its team is gone", context do
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)
      _running = running!(context)
      {:ok, %{"state" => "pending", "session_id" => waiting}} = create(context, "later")

      {:ok, _} = Identity.disable_team(context.team)

      %{worker_id: room} =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-1", capacity: 1)

      assert {:error, :no_team} = Harness.admit(Sessions.get(waiting))

      # Not active on a pod nobody told: no slot held there and no row naming it.
      parked = Sessions.get(waiting)
      assert parked.state == "read_only"
      assert is_nil(parked.worker_id)
      assert Map.get(placement("dev").capacities, room, 0) == 0
      refute_receive {:pushed, "session.activate", %{"session_id" => ^waiting}}, 300
    end

    test "that is parked does not hold up the ones behind it", context do
      other = team_with_grant("design", "dev", name: "design", budget_micros: 100 * @slice)
      bea = person("bea@example.test", ["design"])

      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 1)
      _running = running!(context)
      {:ok, %{"session_id" => first}} = create(context, "first in line")

      {:ok, %{"state" => "pending", "session_id" => second}} =
        Harness.call(
          "session.create",
          %{"profile" => "dev", "team" => other.name, "prompt" => "second in line"},
          %{user: bea, platform_admin?: false}
        )

      Repo.delete_all(from(g in Grant, where: g.team_id == ^context.team.id))
      _room = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-1", capacity: 1)

      Scaler.tick()

      assert_receive {:pushed, "session.activate", %{"session_id" => ^second}}, 5_000
      assert Sessions.get(first).state == "read_only"
      assert Sessions.get(second).state == "active"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp create(context, prompt) do
    Harness.call(
      "session.create",
      %{"profile" => "dev", "team" => "engineering", "prompt" => prompt},
      context.caller
    )
  end

  defp running!(context) do
    assert {:ok, %{"session_id" => id, "token" => token}} = create(context, "hello")
    assert is_binary(token)
    assert_receive {:pushed, "session.activate", %{"session_id" => ^id}}, 5_000
    id
  end

  defp dormant!(context, team_id) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-dormant-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: team_id,
        profile: "dev",
        state: "dormant",
        epoch: 1
      })

    session
  end

  defp open(session, context) do
    Harness.call(
      "session.open",
      %{"session_id" => session.id, "mode" => "activate"},
      context.caller
    )
  end

  # What the placement actor holds, without the reload `Placement.inspect_state/1` does
  # first, which would hide a slot that was never given back.
  defp placement(profile) do
    :sys.get_state(:global.whereis_name({Troupe.Plane.Placement, profile}))
  end
end
