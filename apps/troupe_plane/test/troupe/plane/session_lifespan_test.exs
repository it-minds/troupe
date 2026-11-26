defmodule Troupe.Plane.SessionLifespanTest do
  @moduledoc """
  A session has a lifespan, `throwaway`, `normal` or `persistent` (#1209).

  Asked for at `session.create` (absent is normal), named on every row, a filter on the
  list, and changed later by the owner alone with `session.lifespan.set`: audited, answered
  as `session.get` answers, the pod holding it told so the log has
  `session_lifespan_changed`. A throwaway session proposes nothing for a team's memory.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Bundles, FakePod, Fleet, Harness, Memory, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("eng", "dev", name: "eng", budget_micros: 0)
    ada = person("ada@example.test", ["eng"])
    bea = person("bea@example.test", ["eng"])
    {:ok, _bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1, spec: %{}})

    pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

    %{team: team, ada: ada, bea: bea, pod: pod}
  end

  describe "session.create" do
    test "makes a normal session unless asked, and says so on its row and to its pod", %{ada: ada} do
      assert {:ok, created} = create(ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["lifespan"] == "normal"
      assert Sessions.get(created["session_id"]).lifespan == "normal"
      assert {:ok, %{"lifespan" => "normal"}} = get(created["session_id"], ada)
    end

    test "takes each of the three words", %{ada: ada} do
      for word <- ["throwaway", "normal", "persistent"] do
        assert {:ok, created} = create(ada, %{"lifespan" => word})
        assert_receive {:pushed, "session.activate", %{"lifespan" => ^word}}, 5_000
        assert Sessions.get(created["session_id"]).lifespan == word
      end
    end

    test "refuses another word before anything is spent", %{ada: ada} do
      assert {:error, error} = create(ada, %{"lifespan" => "kept"})
      assert error.message == "invalid_params"
      assert error.data.field == "lifespan"
      refute_received {:pushed, "session.activate", _}
      assert Sessions.visible_to(ada) == []
    end

    test "a fork is normal unless asked, whatever its parent is", %{ada: ada} do
      {:ok, parent} = create(ada, %{"lifespan" => "throwaway"})
      assert_receive {:pushed, "session.activate", _}, 5_000

      {1, _} =
        Repo.update_all(
          from(s in Troupe.Plane.Sessions.Session, where: s.id == ^parent["session_id"]),
          set: [last_seq: 4, head_hash: "sha256:" <> String.duplicate("a", 64)]
        )

      parent = Sessions.get(parent["session_id"])

      assert {:ok, %{"session_id" => fork}} = fork(parent, ada)
      assert Sessions.get(fork).lifespan == "normal"

      assert {:ok, %{"session_id" => kept}} = fork(parent, ada, %{"lifespan" => "persistent"})
      assert Sessions.get(kept).lifespan == "persistent"
    end
  end

  test "the list filters on it", %{ada: ada} do
    {:ok, %{"session_id" => quick}} = create(ada, %{"lifespan" => "throwaway"})
    {:ok, %{"session_id" => _usual}} = create(ada)

    assert {:ok, %{"sessions" => [%{"id" => ^quick, "lifespan" => "throwaway"}]}} =
             Harness.call("sessions.list", %{"lifespan" => "throwaway"}, as(ada))

    assert {:ok, %{"sessions" => [_, _]}} = Harness.call("sessions.list", %{}, as(ada))
  end

  test "initialize says the plane knows the words", %{ada: ada} do
    assert {:ok, %{"capabilities" => %{"lifespans" => true}}} =
             Harness.call("initialize", %{"client_info" => %{"name" => "test"}}, as(ada))
  end

  describe "session.lifespan.set" do
    test "the owner changes it: answered as session.get, audited, the pod told",
         %{ada: ada, team: team, pod: pod} do
      session = running(ada, team, pod)

      assert {:ok, answer} = set(session, "throwaway", ada)
      assert answer["id"] == session.id
      assert answer["lifespan"] == "throwaway"
      assert {:ok, ^answer} = get(session.id, ada)

      assert [row] = audit_rows(session)
      assert row.actor == ada.subject
      assert row.detail == %{"from" => "normal", "to" => "throwaway"}

      assert_receive {:pushed, "lifespan.changed", pushed}, 5_000

      assert pushed == %{
               "session_id" => session.id,
               "from" => "normal",
               "to" => "throwaway",
               "actor" => ada.subject
             }

      # Asked again for what it already is: nothing written, nothing told.
      assert {:ok, %{"lifespan" => "throwaway"}} = set(session, "throwaway", ada)
      assert [_one] = audit_rows(session)
      refute_receive {:pushed, "lifespan.changed", _}, 300
    end

    test "a dormant session's change is its row, and no pod is told", %{ada: ada, team: team, pod: pod} do
      session = running(ada, team, pod)
      {:ok, _} = Sessions.dormant(session.id)

      assert {:ok, %{"lifespan" => "persistent"}} = set(session, "persistent", ada)
      assert Sessions.get(session.id).lifespan == "persistent"
      refute_receive {:pushed, "lifespan.changed", _}, 300
    end

    test "a private session's is its row's, which this plane's sweep reads", %{ada: ada} do
      private = SessionId.generate()

      {:ok, _row} =
        Harness.call(
          "session.register",
          %{"session_id" => private, "device" => "laptop", "lifespan" => "throwaway"},
          as(ada)
        )

      assert Sessions.get(private).lifespan == "throwaway"

      assert {:ok, %{"lifespan" => "normal"}} =
               Harness.call(
                 "session.lifespan.set",
                 %{"session_id" => private, "lifespan" => "normal"},
                 as(ada)
               )
    end

    test "nobody but the owner may: a member of its team and a platform administrator are refused",
         %{ada: ada, bea: bea, team: team, pod: pod} do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      root = person("root@example.test", ["platform"])
      stranger = person("stranger@example.test", [])
      session = running(ada, team, pod, visibility: "team")

      assert {:error, %{message: "forbidden", data: %{required_role: "owner"} = data}} =
               set(session, "throwaway", bea)

      assert data.reason =~ "how long it lasts"

      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.lifespan.set",
                 %{"session_id" => session.id, "lifespan" => "throwaway"},
                 %{user: root, platform_admin?: true}
               )

      # Somebody who may not see it is not told it is there.
      assert {:error, %{message: "not_found"}} = set(session, "throwaway", stranger)

      assert Sessions.get(session.id).lifespan == "normal"
      assert audit_rows(session) == []
    end

    test "what it may be, and of which sessions", %{ada: ada, team: team, pod: pod} do
      session = running(ada, team, pod)

      assert {:error, %{message: "invalid_params", data: %{field: "lifespan"}}} =
               set(session, "forever", ada)

      assert {:error, %{message: "invalid_params"}} =
               Harness.call("session.lifespan.set", %{"session_id" => session.id}, as(ada))

      {:ok, _} = Sessions.put_state(session.id, "erased")
      assert {:error, %{message: "not_found"}} = set(session, "persistent", ada)
    end
  end

  test "a throwaway session's proposal for its team's memory is refused in words, and none kept",
       %{ada: ada, team: team, pod: pod} do
    session = running(ada, team, pod)
    {:ok, _} = Sessions.set_lifespan(session.id, "throwaway")

    assert {:error, :throwaway} =
             Memory.Proposals.propose(ada, "team", team, "Use the staging cluster",
               session: session.id
             )

    assert Memory.Proposals.throwaway_reason() =~ "level me"
    assert Memory.Proposals.pending(%{role: :platform_admin}) == []

    {:ok, _} = Sessions.set_lifespan(session.id, "normal")

    assert {:ok, _proposal} =
             Memory.Proposals.propose(ada, "team", team, "Use the staging cluster",
               session: session.id
             )
  end

  defp create(user, extra \\ %{}) do
    params = Map.merge(%{"profile" => "dev", "team" => "eng"}, extra)
    Harness.call("session.create", params, as(user))
  end

  defp fork(parent, user, extra \\ %{}) do
    params = Map.merge(%{"session_id" => parent.id, "reason" => "branch"}, extra)
    Harness.call("session.fork", params, as(user))
  end

  defp set(session, lifespan, user) do
    Harness.call(
      "session.lifespan.set",
      %{"session_id" => session.id, "lifespan" => lifespan},
      as(user)
    )
  end

  defp get(session_id, user), do: Harness.call("session.get", %{"session_id" => session_id}, as(user))

  defp audit_rows(session) do
    Repo.all(
      from(a in Audit.Event,
        where: a.action == "session.lifespan.set" and a.subject_id == ^session.id,
        order_by: a.inserted_at
      )
    )
  end

  defp as(user), do: %{user: user, platform_admin?: false}

  defp running(owner, team, pod, opts \\ []) do
    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        visibility: Keyword.get(opts, :visibility, "private"),
        state: "active",
        epoch: 1
      })

    {:ok, placed} = Sessions.place(session.id, Fleet.get_worker(pod.worker_id))
    placed
  end

  defp bundle_content do
    %{"schema" => 1, "agents" => [], "skills" => [], "mcp_servers" => []}
  end
end
