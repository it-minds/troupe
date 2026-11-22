defmodule Troupe.Plane.SessionVisibilityTest do
  @moduledoc """
  A pod session's owner gives it to the team after it started, or takes it back (#1169).

  The owner alone, audited, answered as `session.get` answers. The pod holding it is told
  the role each member of the team now holds, so an open connection meets the change at
  its next command, and writes `session_visibility_changed` in the log. Invitations stay as
  they are, and somebody both invited and a member holds the stronger of the two.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, FakePod, Fleet, Harness, Identity, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("eng", "dev", name: "eng")
    ada = person("ada@example.test", ["eng"])
    bea = person("bea@example.test", ["eng"])
    pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

    %{team: team, ada: ada, bea: bea, session: running(ada, team, pod)}
  end

  test "the owner gives it to the team: answered as session.get, audited, the pod told",
       %{ada: ada, bea: bea, session: session} do
    assert {:error, %{message: "not_found"}} = get(session, bea)

    assert {:ok, answer} = set(session, "team", ada)
    assert answer["id"] == session.id
    assert answer["visibility"] == "team"
    assert answer["team"] == "eng"
    assert answer["your_role"] == "owner"
    assert {:ok, ^answer} = get(session, ada)

    assert [row] = audit_rows(ada, session)
    assert row.detail == %{"from" => "private", "to" => "team"}

    # The member's role on the pod's mirror, and the log's line.
    assert_receive {:pushed, "acl.changed", %{"changes" => changes}}, 5_000
    assert %{"session_id" => session.id, "subject" => bea.subject, "role" => "viewer"} in changes
    refute Enum.any?(changes, &(&1["subject"] == ada.subject))

    assert_receive {:pushed, "visibility.changed", pushed}, 5_000

    assert pushed == %{
             "session_id" => session.id,
             "visibility" => "team",
             "by" => ada.subject,
             "by_name" => ada.display_name
           }

    # Asked again for what it already is: nothing written, nothing told.
    assert {:ok, %{"visibility" => "team"}} = set(session, "team", ada)
    assert [_one] = audit_rows(ada, session)
    refute_receive {:pushed, "visibility.changed", _}, 300
  end

  test "a member's role follows it: none, then the team's, then none again",
       %{team: team, ada: ada, bea: bea, session: session} do
    assert Sessions.role_for(bea, Sessions.get(session.id)) == nil

    {:ok, _} = set(session, "team", ada)
    assert {:ok, %{"your_role" => "viewer"}} = get(session, bea)
    assert_receive {:pushed, "acl.changed", %{"changes" => [%{"role" => "viewer"}]}}, 5_000

    # Where the team lets its members steer, they steer it, read through the ladder.
    {:ok, _} = Identity.update_team(team, %{members_may_control: true})
    assert {:ok, %{"your_role" => "collaborator"}} = get(session, bea)

    {:ok, _} = set(session, "private", ada)
    assert {:error, %{message: "not_found"}} = get(session, bea)
    assert Sessions.role_for(bea, Sessions.get(session.id)) == nil

    # Taken back, the pod's mirror refuses her next command on a connection already open.
    assert_receive {:pushed, "acl.changed", %{"changes" => changes}}, 5_000
    assert %{"session_id" => session.id, "subject" => bea.subject, "role" => nil} in changes
    assert_receive {:pushed, "visibility.changed", %{"visibility" => "private"}}, 5_000

    assert [_, _] = audit_rows(ada, session)
  end

  test "an invitee keeps their invitation, holding the stronger of it and the team's",
       %{team: team, ada: ada, bea: bea, session: session} do
    {:ok, team} = Identity.update_team(team, %{members_may_control: true})

    # Invited first, then given to the team: the team's role is the stronger.
    {:ok, _} = invite(session, bea, "observe", ada)
    assert {:ok, %{"your_role" => "viewer"}} = get(session, bea)
    {:ok, _} = set(session, "team", ada)
    assert {:ok, %{"your_role" => "collaborator"}} = get(session, bea)
    {:ok, _} = set(session, "private", ada)
    assert {:ok, %{"your_role" => "viewer"}} = get(session, bea)

    # Given to the team, then invited to steer where the team only lets her follow: the
    # invitation is the stronger.
    {:ok, _} = Identity.update_team(team, %{members_may_control: false})
    {:ok, _} = set(session, "team", ada)
    assert {:ok, %{"your_role" => "viewer"}} = get(session, bea)
    {:ok, _} = invite(session, bea, "control", ada)
    assert {:ok, %{"your_role" => "collaborator"}} = get(session, bea)
    {:ok, _} = set(session, "private", ada)
    assert {:ok, %{"your_role" => "collaborator"}} = get(session, bea)

    assert {:ok, %{"invites" => [%{"subject" => subject}]}} =
             Harness.call("session.invites", %{"session_id" => session.id}, as(ada))

    assert subject == bea.subject
  end

  test "nobody but the owner may: a member, an invitee and a platform administrator are refused",
       %{ada: ada, bea: bea, session: session} do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    cy = person("cy@example.test", ["eng"])
    root = person("root@example.test", ["platform"])
    stranger = person("stranger@example.test", [])

    {:ok, _} = invite(session, cy, "control", ada)
    {:ok, _} = set(session, "team", ada)

    for who <- [bea, cy] do
      assert {:error, %{message: "forbidden", data: %{required_role: "owner"}}} =
               set(session, "private", who)
    end

    assert {:error, %{message: "forbidden"}} =
             Harness.call(
               "session.visibility.set",
               %{"session_id" => session.id, "visibility" => "private"},
               %{user: root, platform_admin?: true}
             )

    # Somebody who may not see it is not told it is there.
    assert {:error, %{message: "not_found"}} = set(session, "private", stranger)

    assert Sessions.get(session.id).visibility == "team"
    assert [_only_the_owners] = Repo.all(from(a in Audit.Event, where: a.action == "session.visibility.set"))
  end

  test "what it may be, and of which sessions", %{team: team, ada: ada, session: session} do
    assert {:error, %{message: "invalid_params"}} = set(session, "everyone", ada)

    assert {:error, %{message: "invalid_params"}} =
             Harness.call("session.visibility.set", %{"visibility" => "team"}, as(ada))

    private = SessionId.generate()

    {:ok, _row} =
      Harness.call("session.register", %{"session_id" => private, "device" => "laptop"}, as(ada))

    assert {:error, %{message: "conflict"}} =
             Harness.call(
               "session.visibility.set",
               %{"session_id" => private, "visibility" => "team"},
               as(ada)
             )

    # One with no team has nobody to be given to; an erased one is not there.
    {1, _} =
      Repo.update_all(from(s in Troupe.Plane.Sessions.Session, where: s.id == ^session.id),
        set: [team_id: nil]
      )

    assert {:error, %{message: "conflict"}} = set(session, "team", ada)

    {:ok, _} = Sessions.put_state(session.id, "erased")
    assert {:error, %{message: "not_found"}} = set(session, "team", ada)
    assert team.id
  end

  defp set(session, visibility, user) do
    Harness.call(
      "session.visibility.set",
      %{"session_id" => session.id, "visibility" => visibility},
      as(user)
    )
  end

  defp get(session, user), do: Harness.call("session.get", %{"session_id" => session.id}, as(user))

  defp invite(session, invitee, role, by) do
    Harness.call(
      "session.invite",
      %{"session_id" => session.id, "subject" => invitee.subject, "role" => role},
      as(by)
    )
  end

  defp audit_rows(actor, session) do
    Repo.all(
      from(a in Audit.Event,
        where:
          a.actor == ^actor.subject and a.action == "session.visibility.set" and
            a.subject_id == ^session.id,
        order_by: a.inserted_at
      )
    )
  end

  defp as(user), do: %{user: user, platform_admin?: false}

  defp running(owner, team, pod) do
    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        visibility: "private",
        state: "active",
        epoch: 1
      })

    {:ok, placed} = Sessions.place(session.id, Fleet.get_worker(pod.worker_id))
    placed
  end
end
