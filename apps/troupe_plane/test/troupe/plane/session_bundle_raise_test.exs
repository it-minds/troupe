defmodule Troupe.Plane.SessionBundleRaiseTest do
  @moduledoc """
  A pod session's owner raises it to its channel's current bundle version (#1177).

  The owner's, or a holder of the owner role's, as archiving is; audited; answered as
  `session.get` answers, which says the version it is on, its channel and the channel's
  current one. A dormant session takes the raise at its next wake; a running one has its
  tree started again on its pod (`session.restart`), at once when it is at rest and when
  its root next comes to rest when it is not. The row's pin moves only once a pod has
  started the session on the new version, so a start that fails leaves the raise owed.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Bundles, FakePod, Fleet, Harness, Identity, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Protocol.{Error, SessionId}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})
    {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

    team = team_with_grant("eng", "dev", name: "eng")
    ada = person("ada@example.test", ["eng"])
    {:ok, v1} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)

    %{team: team, ada: ada, v1: v1}
  end

  describe "a dormant session" do
    test "takes the raise at its next wake, and its pin moves only when the pod took it",
         %{team: team, ada: ada, v1: v1} do
      session = session(ada, team, "dormant", v1.version)
      {:ok, v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)

      assert {:ok, row} = raise_it(session, ada)
      assert row["bundle_version"] == v1.version
      assert row["bundle_current"] == v2.version
      assert row["bundle_channel"] == "stable"
      assert row["bundle_raise_to"] == v2.version

      assert [audit] = audit_rows(session)
      assert audit.actor == ada.subject
      assert audit.detail == %{"from" => v1.version, "to" => v2.version}

      # A wake the pod refuses: the pin stays and the raise is still owed.
      _refusing =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0",
          refuse: %{"session.activate" => %{"code" => -32_603, "message" => "internal_error"}}
        )

      assert {:error, _} = wake(session, ada)
      assert_receive {:pushed, "session.activate", refused}, 5_000
      assert refused["bundle_version"] == v2.version
      assert refused["bundle_upgraded_from"] == v1.version
      assert refused["bundle_upgrade_reason"] == "raised"
      assert refused["bundle_upgraded_by"] == ada.subject
      assert refused["bundle_upgraded_by_name"] == ada.display_name

      after_refusal = Sessions.get(session.id)
      assert after_refusal.bundle_version == v1.version
      assert after_refusal.bundle_raise_to == v2.version
    end

    test "the wake a pod accepts moves the pin and takes the raise",
         %{team: team, ada: ada, v1: v1} do
      session = session(ada, team, "dormant", v1.version)
      {:ok, v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)
      {:ok, _} = raise_it(session, ada)
      _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

      assert {:ok, _} = wake(session, ada)
      assert_receive {:pushed, "session.activate", %{"bundle_upgrade_reason" => "raised"}}, 5_000

      woken = Sessions.get(session.id)
      assert woken.bundle_version == v2.version
      assert woken.bundle_channel == "stable"
      assert woken.bundle_raise_to == nil
    end

    test "a retired pin moves at the wake the pod accepts, and not before the push",
         %{team: team, ada: ada, v1: v1} do
      session = session(ada, team, "dormant", v1.version)
      {:ok, v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)
      {:ok, _} = Bundles.retire("stable", v1.version)

      _refusing =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0",
          refuse: %{"session.activate" => %{"code" => -32_603, "message" => "internal_error"}}
        )

      assert {:error, _} = wake(session, ada)
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["bundle_upgrade_reason"] == "retired"
      assert pushed["bundle_version"] == v2.version
      assert Sessions.get(session.id).bundle_version == v1.version
    end
  end

  describe "a running session" do
    test "at rest is started again on its pod, and its pin moves on the answer",
         %{team: team, ada: ada, v1: v1} do
      pod =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0",
          answers: %{"session.restart" => %{"restarted" => true}}
        )

      session = running(ada, team, pod, v1.version)
      {:ok, v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)

      assert {:ok, row} = raise_it(session, ada)
      assert row["bundle_version"] == v2.version
      assert row["bundle_current"] == v2.version
      assert row["bundle_raise_to"] == nil

      assert_receive {:pushed, "session.restart", pushed}, 5_000
      assert pushed["session_id"] == session.id
      assert pushed["epoch"] == session.epoch
      assert pushed["bundle_version"] == v2.version
      assert pushed["bundle_hash"] == v2.hash
      assert pushed["bundle_upgraded_from"] == v1.version
      assert pushed["bundle_upgraded_by_name"] == ada.display_name
      assert pushed["agent"] == "pr-reviewer"
      assert %{"agents" => agents} = pushed["entitlements"]
      assert "pr-reviewer" in agents
      assert is_list(pushed["memory"])

      # Asked again: it is current, nothing is written or pushed.
      assert {:ok, %{"bundle_version" => version}} = raise_it(session, ada)
      assert version == v2.version
      assert [_one] = audit_rows(session)
      refute_receive {:pushed, "session.restart", _}, 300
    end

    test "while its agent works is answered conflict, and the raise lands with the pod's next report",
         %{team: team, ada: ada, v1: v1} do
      pod =
        FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0",
          answers: %{"session.restart" => %{"pending" => true, "status" => "acting"}}
        )

      session = running(ada, team, pod, v1.version)
      {:ok, v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)

      assert {:error, %Error{message: "conflict", data: data}} = raise_it(session, ada)
      assert data.status == "acting"
      assert data.raise_to == v2.version
      assert data.reason =~ "when it is done"

      kept = Sessions.get(session.id)
      assert kept.bundle_version == v1.version
      assert kept.bundle_raise_to == v2.version

      # The pod took it at the root's rest and says what it runs on now.
      :ok =
        FakePod.say(pod, "session.status", %{
          "session_id" => session.id,
          "epoch" => session.epoch,
          "status" => "idle",
          "bundle_version" => v2.version
        })

      eventually(fn ->
        taken = Sessions.get(session.id)
        taken.bundle_version == v2.version and is_nil(taken.bundle_raise_to)
      end)
    end
  end

  describe "refused" do
    test "when the current version drops the agent the session runs as, naming the agents it has",
         %{team: team, ada: ada, v1: v1} do
      session = session(ada, team, "dormant", v1.version)
      {:ok, _v2} = Bundles.publish("stable", bundle(["pr-writer"]), announce: false)

      assert {:error, %Error{message: "invalid_params", data: data}} = raise_it(session, ada)
      assert data.field == "agent"
      assert data.agent == "pr-reviewer"
      assert "pr-writer" in data.agents
      refute "pr-reviewer" in data.agents
      assert Sessions.get(session.id).bundle_raise_to == nil
      assert audit_rows(session) == []
    end

    test "for a session on a computer, one pending, read-only or erased, and anybody but its owner",
         %{team: team, ada: ada, v1: v1} do
      {:ok, _v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)
      bea = person("bea@example.test", ["eng"])

      private = SessionId.generate()

      {:ok, _row} =
        Harness.call("session.register", %{"session_id" => private, "device" => "laptop"}, as(ada))

      assert {:error, %Error{message: "conflict", data: %{reason: reason}}} =
               Harness.call("session.bundle.raise", %{"session_id" => private}, as(ada))

      assert reason =~ "computer"

      for state <- ["pending", "read_only"] do
        assert {:error, %Error{message: "conflict"}} =
                 raise_it(session(ada, team, state, v1.version), ada)
      end

      erased = session(ada, team, "dormant", v1.version)
      {:ok, _} = Sessions.put_state(erased.id, "erased")
      assert {:error, %Error{message: "not_found"}} = raise_it(erased, ada)

      given = session(ada, team, "dormant", v1.version, visibility: "team")
      assert {:error, %Error{message: "forbidden", data: %{required_role: "owner"}}} = raise_it(given, bea)
    end

    test "when nothing is published on the channel, or the grant is gone",
         %{team: team, ada: ada, v1: v1} do
      {:ok, _} = Fleet.put_profile(%{name: "ux", config_bundle_channel: "beta", replicas: 1})
      {:ok, _} = Identity.grant(team, "ux", %{})
      bare = session(ada, team, "dormant", nil, profile: "ux")

      assert {:error, %Error{message: "conflict", data: %{channel: "beta"}}} = raise_it(bare, ada)

      {:ok, _v2} = Bundles.publish("stable", bundle(["pr-reviewer"]), announce: false)
      revoked = session(ada, team, "dormant", v1.version)
      :ok = revoke(team, "dev")
      assert {:error, %Error{message: "forbidden"}} = raise_it(revoked, ada)
    end
  end

  # The migration's backfill, run over rows as they were before it: one pinned takes its
  # profile's channel, one pinned to nothing and one whose profile is gone keep none.
  test "a session pinned before the channel was recorded takes its profile's channel",
       %{team: team, ada: ada, v1: v1} do
    pinned = session(ada, team, "dormant", v1.version)
    unpinned = session(ada, team, "dormant", nil)
    orphan = session(ada, team, "dormant", v1.version, profile: "gone")

    {3, _} =
      Repo.update_all(
        from(s in Sessions.Session, where: s.id in ^[pinned.id, unpinned.id, orphan.id]),
        set: [bundle_channel: nil]
      )

    [migration] =
      Path.wildcard(Path.expand("../../../priv/repo/migrations/*_session_bundle_raise.exs", __DIR__))

    [_whole, statement] = Regex.run(~r/execute\("""\n(.*?)"""\)/s, File.read!(migration))
    Repo.query!(statement)

    assert Sessions.get(pinned.id).bundle_channel == "stable"
    assert Sessions.get(unpinned.id).bundle_channel == nil
    assert Sessions.get(orphan.id).bundle_channel == nil
  end

  # The grant row gone without the revoke's parking, as a row that got past it would be.
  defp revoke(team, profile) do
    Repo.delete_all(
      from(g in Identity.Grant, where: g.team_id == ^team.id and g.profile == ^profile)
    )

    :ok
  end

  defp raise_it(session, user),
    do: Harness.call("session.bundle.raise", %{"session_id" => session.id}, as(user))

  defp wake(session, user),
    do:
      Harness.call("session.open", %{"session_id" => session.id, "mode" => "activate"}, as(user))

  defp audit_rows(session) do
    Repo.all(
      from(a in Audit.Event,
        where: a.action == "session.bundle.raise" and a.subject_id == ^session.id
      )
    )
  end

  defp as(user), do: %{user: user, platform_admin?: false}

  defp bundle(agents) do
    %{
      "schema" => 1,
      "agents" =>
        for name <- agents do
          %{"name" => name, "definition" => "---\ndescription: #{name}\nmode: primary\n---\nYou #{name}."}
        end,
      "skills" => [],
      "mcp_servers" => []
    }
  end

  defp session(owner, team, state, version, opts \\ []) do
    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: Keyword.get(opts, :profile, "dev"),
        visibility: Keyword.get(opts, :visibility, "private"),
        state: state,
        epoch: 1,
        agent: "pr-reviewer",
        bundle_version: version,
        bundle_channel: version && "stable"
      })

    session
  end

  defp running(owner, team, pod, version) do
    session = session(owner, team, "active", version)
    {:ok, placed} = Sessions.place(session.id, Fleet.get_worker(pod.worker_id))
    placed
  end
end
