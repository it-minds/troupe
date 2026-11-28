defmodule Troupe.Plane.SessionSensitiveTest do
  @moduledoc """
  A sensitive session on the plane (#1239): the pod's `session.status` marks the row once,
  audited as the harness with the tool and the rule; its owner may mark it by hand
  (`session.sensitive.set`, `session.create sensitive: true`), audited as theirs, the pod
  told; nothing clears it; every row says it and every activation carries it. On its own
  side the plane refuses a sensitive session's proposals for shared memory and its
  publications where the profile denies `publish_artifact`, and holds its sharing beyond
  its present readers to the profile's `sensitive.sharing`: allow, ask (a team
  administrator's yes) or deny.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Audit, Bundles, FakePod, Fleet, Harness, Identity, Memory, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Sessions.Sensitive
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :base_url, "https://plane.example.test")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :base_url)
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    team = team_with_grant("eng", "dev", name: "eng", budget_micros: 0)
    ada = person("ada@example.test", ["eng"])
    bea = person("bea@example.test", ["eng"])
    lead = person("lead@example.test", [])
    {:ok, _} = Identity.add_team_admin(team, lead.subject, "root@example.test")

    {:ok, _bundle} =
      Bundles.publish(
        "stable",
        %{"schema" => 1, "agents" => [], "skills" => [], "mcp_servers" => []},
        announce: false
      )

    profile("allow")
    pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

    %{team: team, ada: ada, bea: bea, lead: lead, pod: pod}
  end

  defp profile(sharing) do
    {:ok, _profile} =
      Fleet.put_profile(%{
        name: "dev",
        config_bundle_channel: "stable",
        replicas: 1,
        spec: %{
          "sensitive" => %{
            "markedBy" => ["mcp(records.*)"],
            "deny" => ["publish_artifact", "web_fetch"],
            "sharing" => sharing
          }
        }
      })
  end

  defp status(session, extra) do
    Map.merge(%{"session_id" => session.id, "epoch" => session.epoch, "status" => "idle"}, extra)
  end

  defp marked_by_pod(session) do
    :ok =
      Sensitive.reported(
        session.id,
        status(session, %{
          "sensitive_at" => "2026-11-28T10:14:00Z",
          "sensitive_by" => "mcp.records.lookup",
          "sensitive_rule" => "mcp(records.*)"
        })
      )

    Sessions.get(session.id)
  end

  describe "the mark" do
    test "the pod's report marks the row once, audited as the harness with the tool and rule",
         %{ada: ada, team: team, pod: pod} do
      session = running(ada, team, pod)
      assert Sensitive.json(session) == nil
      assert {:ok, %{"sensitive" => nil}} = get(session.id, ada)

      marked = marked_by_pod(session)
      assert %{"how" => "call", "by" => "mcp.records.lookup", "at" => at} = Sensitive.json(marked)
      assert at =~ "2026-11-28T10:14:00"

      assert [row] = audited(session, "session.sensitive")
      assert row.actor == "system:harness"
      assert row.detail["tool"] == "mcp.records.lookup"
      assert row.detail["rule"] == "mcp(records.*)"

      # Again, and later: the first holds and nothing more is written.
      :ok =
        Sensitive.reported(
          session.id,
          status(session, %{
            "sensitive_at" => "2026-11-28T11:00:00Z",
            "sensitive_by" => "read_file"
          })
        )

      assert Sensitive.json(Sessions.get(session.id))["by"] == "mcp.records.lookup"
      assert [_one] = audited(session, "session.sensitive")

      assert {:ok, %{"sensitive" => %{"by" => "mcp.records.lookup", "how" => "call"}}} =
               get(session.id, ada)

      assert {:ok, %{"sessions" => [%{"sensitive" => %{"how" => "call"}}]}} =
               Harness.call("sessions.list", %{}, as(ada))
    end

    test "comes through the pod's session.status", %{ada: ada, team: team, pod: pod} do
      session = running(ada, team, pod)

      :ok =
        FakePod.say(
          pod,
          "session.status",
          status(session, %{
            "sensitive_at" => "2026-11-28T10:14:00Z",
            "sensitive_by" => "mcp.records.lookup"
          })
        )

      assert eventually(fn -> Sensitive.sensitive?(Sessions.get(session.id)) end)
    end

    test "the owner marks one by hand: audited as theirs, the pod told, and false refused",
         %{ada: ada, bea: bea, team: team, pod: pod} do
      session = running(ada, team, pod, visibility: "team")

      assert {:error, %{message: "forbidden"}} = mark(session, bea)

      assert {:ok, %{"sensitive" => %{"how" => "person", "by" => "ada@example.test"}}} =
               mark(session, ada)

      assert [row] = audited(session, "session.sensitive")
      assert row.actor == ada.subject

      assert_receive {:pushed, "sensitive.changed", pushed}, 5_000
      assert pushed["session_id"] == session.id
      assert pushed["by"] == ada.subject

      # Nothing clears it: not false, not its owner, and asking again writes nothing.
      assert {:error, %{message: "invalid_params", data: data}} =
               Harness.call(
                 "session.sensitive.set",
                 %{"session_id" => session.id, "sensitive" => false},
                 as(ada)
               )

      assert data.reason =~ "nothing clears a sensitive session's mark"
      assert {:ok, %{"sensitive" => %{"how" => "person"}}} = mark(session, ada)
      assert [_one] = audited(session, "session.sensitive")
    end

    test "the activation carries it, from the pod's mark and from session.create's",
         %{ada: ada} do
      assert {:ok, %{"session_id" => id}} = create(ada, %{"sensitive" => true})
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["session_id"] == id
      assert %{"how" => "person", "by" => "ada@example.test", "at" => _} = pushed["sensitive"]
      assert pushed["sensitive_rules"]["markedBy"] == ["mcp(records.*)"]
      assert pushed["sensitive_rules"]["profile"] == "dev"

      assert {:ok, %{"session_id" => plain}} = create(ada)
      assert_receive {:pushed, "session.activate", unmarked}, 5_000
      assert unmarked["session_id"] == plain
      refute Map.has_key?(unmarked, "sensitive")

      assert {:error, %{message: "invalid_params"}} = create(ada, %{"sensitive" => "yes"})
    end

    test "a session spawned from a sensitive one is sensitive as it is", %{
      ada: ada,
      team: team,
      pod: pod
    } do
      parent = marked_by_pod(running(ada, team, pod))

      assert {:ok, %{"session_id" => child}} =
               Harness.call(
                 "session.spawn",
                 %{"parent" => parent.id, "prompt" => "go on"},
                 as(ada)
               )

      assert Sensitive.json(Sessions.get(child)) == Sensitive.json(parent)
      assert [row] = audited(Sessions.get(child), "session.sensitive")
      assert row.detail["from"] == parent.id

      assert_receive {:pushed, "session.activate",
                      %{"session_id" => ^child, "sensitive" => %{"how" => "call"}}},
                     5_000
    end

    test "initialize says the plane knows it", %{ada: ada} do
      assert {:ok, %{"capabilities" => %{"sensitive" => true}}} =
               Harness.call("initialize", %{"client_info" => %{"name" => "test"}}, as(ada))
    end
  end

  describe "what the plane refuses of a sensitive session" do
    test "a proposal for a team's memory, in words, and none kept", %{
      ada: ada,
      team: team,
      pod: pod
    } do
      session = marked_by_pod(running(ada, team, pod))

      assert {:error, :sensitive} =
               Memory.Proposals.propose(ada, "team", team, "Ann is allergic", session: session.id)

      assert Memory.Proposals.sensitive_reason() =~ "a sensitive session proposes nothing"
      assert Memory.Proposals.pending(%{role: :platform_admin}) == []
    end

    test "a publication, where its profile denies publish_artifact", %{
      ada: ada,
      team: team,
      pod: pod
    } do
      session = marked_by_pod(running(ada, team, pod))

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} = publish(ada, session.id)
      assert reason =~ "this session is sensitive, and dev refuses publish_artifact"

      # One that is not sensitive publishes as before.
      other = running(ada, team, pod)
      assert {:ok, %{"id" => _}} = publish(ada, other.id)
    end
  end

  describe "sharing it beyond its present readers" do
    test "allow lets it be given to the team", %{ada: ada, team: team, pod: pod} do
      session = marked_by_pod(running(ada, team, pod))
      assert {:ok, %{"visibility" => "team"}} = visibility(session, ada)
    end

    test "deny refuses giving it to the team, inviting, granting and a link, naming who reads it",
         %{ada: ada, lead: lead, team: team, pod: pod} do
      profile("deny")
      session = marked_by_pod(running(ada, team, pod))

      assert {:error, %{message: "forbidden", data: data}} = visibility(session, ada)

      assert data.reason ==
               "This session is sensitive and dev does not allow sharing it outside the people who already read it"

      assert data.setting == "sensitive.sharing"

      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => "bea@example.test"},
                 as(ada)
               )

      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.grant",
                 %{
                   "session_id" => session.id,
                   "subject" => "bea@example.test",
                   "role" => "viewer"
                 },
                 as(lead)
               )

      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "observe"},
                 as(ada)
               )

      assert Sessions.get(session.id).visibility == "private"

      # One the team reads already is named, and taking it back is never refused.
      {:ok, _} = Sessions.set_visibility(session.id, "team")
      team_session = Sessions.get(session.id)

      assert {:error, %{data: %{reason: reason}}} =
               Harness.call(
                 "session.share",
                 %{"session_id" => team_session.id, "role" => "observe"},
                 as(ada)
               )

      assert reason =~ "outside the team that already reads it, eng"

      assert {:ok, %{"visibility" => "private"}} =
               Harness.call(
                 "session.visibility.set",
                 %{"session_id" => session.id, "visibility" => "private"},
                 as(ada)
               )
    end

    test "ask holds giving it to the team for a team administrator, whose yes applies it",
         %{ada: ada, lead: lead, team: team, pod: pod} do
      profile("ask")
      session = marked_by_pod(running(ada, team, pod))

      assert {:ok, %{"waiting" => true, "reason" => reason, "share_request" => request}} =
               visibility(session, ada)

      assert reason =~ "waiting on a team administrator"
      assert request["kind"] == "visibility"
      assert Sessions.get(session.id).visibility == "private"
      assert [held] = audited(session, "session.share_request")
      assert held.actor == ada.subject

      # Its owner cannot say yes to their own; the team's administrator sees it and can.
      assert {:error, %{message: "not_found"}} = decide(request["id"], ada, "approve")

      assert {:ok, %{"requests" => [%{"id" => id}]}} =
               Harness.call("session.share_requests", %{}, as(lead))

      assert id == request["id"]

      assert {:ok,
              %{
                "share_request" => %{"state" => "approved"},
                "applied" => %{"visibility" => "team"}
              }} =
               decide(id, lead, "approve")

      assert Sessions.get(session.id).visibility == "team"
      assert [decided] = audited(session, "session.share_request.decide")
      assert decided.actor == lead.subject
      assert [applied] = audited(session, "session.visibility.set")
      assert applied.actor == ada.subject

      assert {:error, %{message: "conflict"}} = decide(id, lead, "approve")
    end

    test "ask holds an invitation, and a decline applies nothing; a link cannot wait",
         %{ada: ada, lead: lead, team: team, pod: pod} do
      profile("ask")
      session = marked_by_pod(running(ada, team, pod))

      assert {:ok, %{"waiting" => true, "share_request" => request}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => "bea@example.test"},
                 as(ada)
               )

      assert request["params"] == %{"subject" => "bea@example.test"}

      assert {:ok, %{"share_request" => %{"state" => "declined"}, "applied" => %{}}} =
               decide(request["id"], lead, "decline")

      assert Sessions.role_for(Identity.get_user("bea@example.test"), Sessions.get(session.id)) ==
               nil

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               Harness.call(
                 "session.share",
                 %{"session_id" => session.id, "role" => "observe"},
                 as(ada)
               )

      assert reason =~ "a link cannot wait for one"

      # A team administrator's own grant is the yes it would wait for.
      assert {:ok, %{"subject" => "bea@example.test"}} =
               Harness.call(
                 "session.grant",
                 %{
                   "session_id" => session.id,
                   "subject" => "bea@example.test",
                   "role" => "viewer"
                 },
                 as(lead)
               )
    end

    test "an artifact the session published is held to the same rule", %{
      ada: ada,
      lead: lead,
      team: team,
      pod: pod
    } do
      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          config_bundle_channel: "stable",
          replicas: 1,
          spec: %{
            "sensitive" => %{
              "markedBy" => ["mcp(records.*)"],
              "deny" => ["web_fetch"],
              "sharing" => "ask"
            }
          }
        })

      session = running(ada, team, pod)
      assert {:ok, %{"id" => artifact, "version" => version}} = publish(ada, session.id)
      _ = marked_by_pod(session)

      # With a new version's files, the move cannot wait, and nothing is written.
      files = [%{"path" => "index.html", "bytes" => Base.encode64("<h1>New</h1>")}]

      assert {:error, %{message: "forbidden", data: %{reason: why}}} =
               Harness.call(
                 "artifact.put",
                 %{"id" => artifact, "visibility" => "organisation", "files" => files},
                 as(ada)
               )

      assert why =~ "publish the new version first, then move it on its own"

      assert {:ok, %{"waiting" => true, "share_request" => request}} =
               Harness.call(
                 "artifact.put",
                 %{"id" => artifact, "visibility" => "organisation", "base" => version},
                 as(ada)
               )

      assert request["kind"] == "artifact"

      assert {:error, %{message: "forbidden"}} =
               Harness.call("artifact.share", %{"id" => artifact, "role" => "view"}, as(ada))

      assert {:ok, %{"applied" => %{"visibility" => "organisation"}}} =
               decide(request["id"], lead, "approve")
    end

    test "deny refuses adding a team or a person to who reads its artifact; taking one off is the owner's",
         %{ada: ada, bea: bea, team: team, pod: pod} do
      sharing_profile("deny")
      session = running(ada, team, pod)
      assert {:ok, %{"id" => artifact}} = publish(ada, session.id)
      _ = marked_by_pod(session)

      for change <- [%{"teams" => ["eng"]}, %{"people" => [%{"subject" => bea.subject, "role" => "view"}]}] do
        assert {:error, %{message: "forbidden", data: %{setting: "sensitive.sharing"}}} =
                 Harness.call("artifact.access.set", Map.put(change, "id", artifact), as(ada))
      end

      assert {:error, %{message: "forbidden"}} =
               Harness.call("artifact.share", %{"id" => artifact, "team" => "eng"}, as(ada))

      assert {:ok, %{"teams" => [], "people" => []}} =
               Harness.call("artifact.access.set", %{"id" => artifact, "teams" => [], "people" => []}, as(ada))

      assert {:error, %{message: "not_found"}} = Harness.call("artifact.get", %{"id" => artifact}, as(bea))
    end

    test "ask holds adding a team to who reads its artifact, whole, until a team administrator's yes",
         %{ada: ada, bea: bea, lead: lead, team: team, pod: pod} do
      sharing_profile("ask")
      session = running(ada, team, pod)
      assert {:ok, %{"id" => artifact}} = publish(ada, session.id)
      _ = marked_by_pod(session)

      assert {:ok, %{"waiting" => true, "share_request" => request}} =
               Harness.call("artifact.access.set", %{"id" => artifact, "teams" => ["eng"]}, as(ada))

      assert request["kind"] == "artifact"
      assert {:ok, %{"teams" => []}} = Harness.call("artifact.access.get", %{"id" => artifact}, as(ada))
      assert {:error, %{message: "not_found"}} = Harness.call("artifact.get", %{"id" => artifact}, as(bea))

      assert {:ok, %{"applied" => %{"teams" => [%{"name" => "eng"}]}}} =
               decide(request["id"], lead, "approve")

      assert {:ok, %{"role" => "view"}} = Harness.call("artifact.get", %{"id" => artifact}, as(bea))
    end
  end

  # A profile whose sensitive sessions may still publish, sharing as `sharing` says.
  defp sharing_profile(sharing) do
    {:ok, _profile} =
      Fleet.put_profile(%{
        name: "dev",
        config_bundle_channel: "stable",
        replicas: 1,
        spec: %{"sensitive" => %{"markedBy" => ["mcp(records.*)"], "deny" => ["web_fetch"], "sharing" => sharing}}
      })
  end

  defp publish(user, session_id) do
    Harness.call(
      "artifact.publish",
      %{
        "title" => "Report",
        "kind" => "html",
        "visibility" => "private",
        "session_id" => session_id,
        "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Hi</h1>")}]
      },
      as(user)
    )
  end

  defp create(user, extra \\ %{}) do
    Harness.call(
      "session.create",
      Map.merge(%{"profile" => "dev", "team" => "eng"}, extra),
      as(user)
    )
  end

  defp mark(session, user),
    do:
      Harness.call(
        "session.sensitive.set",
        %{"session_id" => session.id, "sensitive" => true},
        as(user)
      )

  defp visibility(session, user),
    do:
      Harness.call(
        "session.visibility.set",
        %{"session_id" => session.id, "visibility" => "team"},
        as(user)
      )

  defp decide(id, user, decision),
    do:
      Harness.call(
        "session.share_request.decide",
        %{"id" => id, "decision" => decision},
        as(user)
      )

  defp get(session_id, user),
    do: Harness.call("session.get", %{"session_id" => session_id}, as(user))

  defp audited(session, action) do
    Repo.all(
      from(a in Audit.Event,
        where: a.action == ^action and a.subject_id == ^session.id,
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
end
