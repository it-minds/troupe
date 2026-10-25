defmodule Troupe.Plane.BundlesTest do
  @moduledoc """
  Config bundles: what a new session gets, and what a running one keeps.

  Two promises. Publishing reaches every pod, and every pod says so by reporting the new
  hash. And a running session's configuration does not move under it — versions are
  immutable, a session is pinned at creation, and the only way its configuration ever
  changes is a deliberate upgrade at activation that lands in the log as an event.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Bundles, FakePod, Fleet, Harness, Identity, Memory, Provision, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Fleet.Bundle

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})
    {:ok, _} = Fleet.put_profile(%{name: "ux", config_bundle_channel: "beta", replicas: 1})

    %{port: Listener.port()}
  end

  describe "publishing" do
    test "assigns the next version and hashes the content" do
      assert {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)

      assert {:ok, v2} =
               Bundles.publish("stable", %{"agents" => ["build", "plan"]}, announce: false)

      assert v1.version == 1
      assert v2.version == 2
      assert v1.hash != v2.hash
      assert v1.hash == Bundle.hash(%{"agents" => ["build"]})

      # The same content hashes the same wherever it was built, which is what lets a pod
      # check what it fetched against what a heartbeat reported.
      assert Bundle.hash(%{"a" => 1, "b" => 2}) == Bundle.hash(%{"b" => 2, "a" => 1})
      assert Bundles.current("stable").version == 2
    end

    test "reaches every pod on the channel, and no others", context do
      dev = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      ux = fake_pod(context.port, "ux-token", "troupe-w-ux-0")

      assert {:ok, bundle} = Bundles.publish("stable", %{"agents" => ["build"]})

      assert_receive {:pushed, ^dev, "config.updated", params}, 5_000
      assert params["bundle_hash"] == bundle.hash
      assert params["version"] == 1
      assert params["channel"] == "stable"

      # `ux` follows `beta`, so it hears nothing.
      refute_receive {:pushed, ^ux, "config.updated", _}, 500
    end

    test "adoption names the pods that have not caught up" do
      assert {:ok, bundle} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)

      {:ok, ahead} = enrol("dev", "troupe-w-dev-0")
      {:ok, behind} = enrol("dev", "troupe-w-dev-1")

      {:ok, _} = Fleet.heartbeat(ahead, %{bundle_hash: bundle.hash})
      {:ok, _} = Fleet.heartbeat(behind, %{bundle_hash: "sha256:the-old-one"})

      report = Bundles.adoption("dev", bundle.hash)

      refute report.adopted?
      assert report.current == ["troupe-w-dev-0"]
      assert report.stale == [%{pod: "troupe-w-dev-1", reported: "sha256:the-old-one"}]

      {:ok, _} = Fleet.heartbeat(behind, %{bundle_hash: bundle.hash})
      assert Bundles.adoption("dev", bundle.hash).adopted?
    end

    test "a pod on a retired newer version is ahead, not behind" do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      {:ok, v2} = Bundles.publish("stable", %{"agents" => ["build", "plan"]}, announce: false)
      {:ok, _} = Bundles.retire("stable", v2.version)

      {:ok, pod} = enrol("dev", "troupe-w-dev-0")
      {:ok, _} = Fleet.heartbeat(pod, %{bundle_hash: v2.hash})

      # v1 is current again. The pod materialised v2 before it was retired and keeps
      # every version it has been told about, so it can still serve v1.
      report = Bundles.adoption("dev", Bundles.current("stable").hash)
      assert Bundles.current("stable").version == v1.version
      assert report.ahead == ["troupe-w-dev-0"]
      assert report.stale == []
      assert report.adopted?
    end

    test "a legacy bundle without a schema still publishes and announces", context do
      dev = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      servers = [%{"name" => "jira", "url" => "https://mcp.jira.example/mcp"}]

      assert {:ok, bundle} = Bundles.publish("stable", %{"mcp_servers" => servers})

      assert bundle.summary == %{
               "schema" => 0,
               "agents" => [],
               "skills" => [],
               "mcp_servers" => ["jira"],
               "acp_agents" => []
             }

      # An old worker applies `mcp_servers` from the push and fetches nothing, so the
      # push still carries them for one release.
      assert_receive {:pushed, ^dev, "config.updated", params}, 5_000
      assert params["bundle_hash"] == bundle.hash
      assert params["mcp_servers"] == servers
    end
  end

  describe "what publishing checks" do
    setup do
      on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)
    end

    test "a definition that does not parse is refused with the reason" do
      content =
        schema_1(
          agents: [%{"name" => "pr-reviewer", "definition" => "---\nmode: sideways\n---\nHi"}]
        )

      assert {:error, {:invalid_bundle, [message]}} =
               Bundles.publish("stable", content, announce: false)

      assert message =~ "pr-reviewer"
      assert message =~ "bad_mode"
      assert Bundles.current("stable") == nil
    end

    test "an MCP host the policy would not let a pod reach is refused, naming the host" do
      Application.put_env(:troupe_plane, :egress_allowed, fn host ->
        host == "mcp.jira.example"
      end)

      allowed =
        schema_1(mcp_servers: [%{"name" => "jira", "url" => "https://mcp.jira.example/mcp"}])

      refused =
        schema_1(
          mcp_servers: [%{"name" => "other", "url" => "https://mcp.elsewhere.example/mcp"}]
        )

      assert {:ok, _} = Bundles.publish("stable", allowed, announce: false)

      assert {:error, {:invalid_bundle, [message]}} =
               Bundles.publish("stable", refused, announce: false)

      assert message =~ "mcp.elsewhere.example"
    end

    # Only four of them were guarded once, by a list somebody kept by hand, and a bundle
    # replaced `reviewer` without a word.
    test "a bundle replaces an agent troupe_core ships only with override: true, whichever it is" do
      shipped =
        "../../../../troupe_core/priv/agents/*.md"
        |> Path.expand(__DIR__)
        |> Path.wildcard()
        |> Enum.map(&Path.basename(&1, ".md"))

      assert "reviewer" in shipped
      assert Enum.sort(Bundles.builtin_agents()) == Enum.sort(shipped)

      for name <- shipped do
        replacing = schema_1(agents: [%{"name" => name, "definition" => "---\nmode: primary\n---\nHi"}])

        assert {:error, {:invalid_bundle, [message]}} = Bundles.validate(replacing), name
        assert message =~ name
        assert message =~ "override: true"

        meant = schema_1(agents: [%{"name" => name, "definition" => "---\nmode: primary\noverride: true\n---\nHi"}])
        assert {:ok, _} = Bundles.validate(meant), name
      end
    end

    test "with no policy at all every host is allowed" do
      Application.delete_env(:troupe_plane, :egress_allowed)
      Application.delete_env(:troupe_plane, :policy)

      content =
        schema_1(mcp_servers: [%{"name" => "any", "url" => "https://mcp.anywhere.example/mcp"}])

      assert {:ok, _} = Bundles.publish("stable", content, announce: false)
    end

    test "the summary is written at publish and comes back with the row" do
      assert {:ok, bundle} = Bundles.publish("stable", full_bundle(), announce: false)

      assert bundle.summary == %{
               "schema" => 1,
               "agents" => ["pr-reviewer", "helper"],
               "skills" => ["review-checklist"],
               "mcp_servers" => ["jira"],
               "acp_agents" => []
             }

      assert Bundles.get("stable", bundle.version).summary == bundle.summary
      assert Bundles.by_hash(bundle.hash).version == bundle.version
    end
  end

  describe "the profiles' mcpServers" do
    test "are rewritten from the current bundle on publish and on retire" do
      {:ok, _} =
        Fleet.put_profile(%{name: "dev", spec: %{"image" => %{"repository" => "ghcr.io/x"}}})

      assert {:ok, bundle} = Bundles.publish("stable", full_bundle(), announce: false)

      assert Fleet.get_profile("dev").spec["mcpServers"] == [
               %{
                 "name" => "jira",
                 "url" => "https://mcp.jira.example/mcp",
                 "header" => "authorization",
                 "timeoutMs" => 30_000,
                 "credentialRef" => "JIRA_MCP_TOKEN",
                 "secretRef" => %{"name" => "troupe-mcp-jira", "key" => "token"}
               }
             ]

      # The rest of the spec is untouched, and `ux` follows another channel.
      assert Fleet.get_profile("dev").spec["image"] == %{"repository" => "ghcr.io/x"}
      refute Map.has_key?(Fleet.get_profile("ux").spec, "mcpServers")

      # A server without a credential is listed for egress, with nothing to inject.
      no_credential =
        schema_1(mcp_servers: [%{"name" => "docs", "url" => "https://docs.example/mcp"}])

      assert {:ok, v2} = Bundles.publish("stable", no_credential, announce: false)
      assert [%{"name" => "docs"} = entry] = Fleet.get_profile("dev").spec["mcpServers"]
      refute Map.has_key?(entry, "secretRef")

      # Retiring recomputes from what is current afterwards.
      {:ok, _} = Bundles.retire("stable", v2.version)
      assert [%{"name" => "jira"}] = Fleet.get_profile("dev").spec["mcpServers"]

      {:ok, _} = Bundles.retire("stable", bundle.version)
      assert Fleet.get_profile("dev").spec["mcpServers"] == []
    end

    test "a person-mode server carries a slot and no Secret at all" do
      {:ok, _} = Fleet.put_profile(%{name: "dev", spec: %{}})

      content =
        schema_1(
          mcp_servers: [
            %{
              "name" => "jira",
              "url" => "https://mcp.jira.example/mcp",
              "credential_mode" => "person"
            }
          ]
        )

      assert {:ok, _} = Bundles.publish("stable", content, announce: false)
      assert [entry] = Fleet.get_profile("dev").spec["mcpServers"]

      # The slot defaults to the server's own name: "connect Jira as yourself" should
      # not need a second name invented for it.
      assert entry["credentialMode"] == "person"
      assert entry["credentialSlot"] == "jira"

      # Nothing for the operator to mount, and no environment variable. A `secretRef`
      # here would be a pod failing to start over a credential nobody configured.
      refute Map.has_key?(entry, "secretRef")
      refute Map.has_key?(entry, "credentialRef")

      # And it is still listed, because egress has to see the host either way.
      assert entry["url"] == "https://mcp.jira.example/mcp"
    end

    test "a server with a Secret and a person's credential is refused at publish" do
      content =
        schema_1(
          mcp_servers: [
            %{
              "name" => "jira",
              "url" => "https://mcp.jira.example/mcp",
              "credential_mode" => "person",
              "secret_ref" => "JIRA_MCP_TOKEN"
            }
          ]
        )

      assert {:error, {:invalid_bundle, [reason]}} =
               Bundles.publish("stable", content, announce: false)

      assert reason =~ "two credentials"
      assert reason =~ "which code path ran"
    end

    test "a server called as the profile's own identity is marked, with no Secret, and the profile says who it is" do
      {:ok, _} = Fleet.put_profile(%{name: "dev", spec: %{}})

      content =
        schema_1(
          mcp_servers: [
            %{
              "name" => "jira",
              "url" => "https://mcp.jira.example/mcp",
              "credential_mode" => "client_credentials"
            }
          ]
        )

      assert {:ok, _} = Bundles.publish("stable", content, announce: false)
      assert [entry] = Fleet.get_profile("dev").spec["mcpServers"]

      assert entry["credentialMode"] == "client_credentials"
      refute Map.has_key?(entry, "secretRef")
      refute Map.has_key?(entry, "credentialRef")

      # The profile has no identity for it yet, which is reported and not refused (Decision
      # 747): the bundle and the profile are written by different people.
      assert [problem] = Provision.identity_problems(Fleet.get_profile("dev"))
      assert problem =~ "mcp server jira is called with client credentials"

      identity = %{
        "server" => "jira",
        "clientId" => "client-dev",
        "transitKey" => "troupe-w-dev.jira",
        "certificateThumbprint" => String.duplicate("A", 43)
      }

      {:ok, _} = Fleet.put_profile(%{name: "dev", spec: %{"mcpIdentities" => [identity]}})
      assert Provision.identity_problems(Fleet.get_profile("dev")) == []
    end
  end

  describe "what a session runs on" do
    test "a new session records the current version and a running one keeps it", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      user = granted_user()
      assert {:ok, created} = Harness.call("session.create", %{"profile" => "dev"}, context(user))

      session = Sessions.get(created["session_id"])
      assert session.bundle_version == v1.version

      # v2 is published while it runs. The running session does not move.
      {:ok, v2} = Bundles.publish("stable", %{"agents" => ["build", "plan"]}, announce: false)
      assert Sessions.get(session.id).bundle_version == v1.version

      # A new session gets v2.
      assert {:ok, later} = Harness.call("session.create", %{"profile" => "dev"}, context(user))
      assert Sessions.get(later["session_id"]).bundle_version == v2.version

      # And a client can see all of that. Until this was on `session.get`, the pin was a
      # promise nothing outside the plane's own database could check — which is the same
      # as no promise, for anybody trying to explain why a session is behaving like a
      # bundle that was replaced an hour ago.
      assert {:ok, pinned} =
               Harness.call("session.get", %{"session_id" => session.id}, context(user))

      assert pinned["bundle_version"] == v1.version

      assert {:ok, moved} =
               Harness.call("session.get", %{"session_id" => later["session_id"]}, context(user))

      assert moved["bundle_version"] == v2.version
    end

    test "activating on a retired version upgrades, and says so", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      user = granted_user()
      session = dormant_session(user, "dev", v1.version)

      {:ok, v2} = Bundles.publish("stable", %{"agents" => ["build", "plan"]}, announce: false)
      {:ok, _} = Bundles.retire("stable", v1.version)

      assert {:ok, _} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "activate"},
                 context(user)
               )

      assert_receive {:pushed, ^pod, "session.activate", params}, 5_000
      assert params["bundle_version"] == v2.version
      assert params["bundle_upgraded_from"] == v1.version
      assert params["bundle_hash"] == v2.hash

      # And the pin moved, so the next activation is not an upgrade again.
      assert Sessions.get(session.id).bundle_version == v2.version
    end

    test "a session may start as a primary the bundle defines or a built-in, and nothing else",
         context do
      {:ok, _} = Bundles.publish("stable", full_bundle(), announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()

      assert {:ok, _} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "agent" => "pr-reviewer"},
                 context(user)
               )

      assert_receive {:pushed, ^pod, "session.activate", params}, 5_000
      assert params["agent"] == "pr-reviewer"
      assert params["bundle_version"] == 1

      assert {:ok, _} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "agent" => "build"},
                 context(user)
               )

      assert_receive {:pushed, ^pod, "session.activate", %{"agent" => "build"}}, 5_000

      # A subagent is not something a session starts as, and an unknown name is refused
      # before anything is placed or budgeted.
      assert {:error, error} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "agent" => "helper"},
                 context(user)
               )

      assert error.message == "invalid_params"
      assert error.data.agents == ["pr-reviewer", "build", "plan"]
      refute_receive {:pushed, ^pod, "session.activate", %{"agent" => "helper"}}, 200
    end

    # Decision 826: the bundle's agents and skills win on a pod unless the profile lets a
    # repository's replace them. The switch rides with the pin and is read from the profile
    # at every activation, so turning it on or off reaches a session the next time it wakes.
    test "the push says whether the profile lets a repository's files replace the bundle's",
         context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()
      before = dormant_session(user, "dev", v1.version)
      later = dormant_session(user, "dev", v1.version)

      assert pushed(pod, before, user)["repository_overrides_bundle"] == false

      spec = Map.put(Fleet.get_profile("dev").spec, "repositoryOverridesBundle", true)
      {:ok, _} = Fleet.put_profile(%{name: "dev", spec: spec})

      assert pushed(pod, later, user)["repository_overrides_bundle"] == true
    end

    # Decision 862: whether a person may offer the session their own tools rides the same
    # way, read from the profile at every activation, `allow` unless it says `forbid`.
    test "the push says whether the profile takes a person's own tools", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()
      before = dormant_session(user, "dev", v1.version)
      later = dormant_session(user, "dev", v1.version)

      assert pushed(pod, before, user)["personal_tools"] == "allow"

      spec = Map.put(Fleet.get_profile("dev").spec, "personalTools", "forbid")
      {:ok, _} = Fleet.put_profile(%{name: "dev", spec: spec})

      assert pushed(pod, later, user)["personal_tools"] == "forbid"
    end

    # Issue #55: the memory documents a session reads ride the same way, the organisation's,
    # its team's and its profile's, none of another team's, so a save reaches a session at
    # its next wake and restarts no pod.
    test "the push carries the organisation's, the team's and the profile's memory", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()
      before = dormant_session(user, "dev", v1.version)
      later = dormant_session(user, "dev", v1.version)

      assert pushed(pod, before, user)["memory"] == []

      _design = team_with_grant("design", "dev", name: "design")
      {:ok, _} = Memory.put(:organisation, "Everyone.", "root@example.test")
      {:ok, _} = Memory.put(Identity.get_team("engineering"), "Engineering.", "root@example.test")
      {:ok, _} = Memory.put(Identity.get_team("design"), "Design only.", "root@example.test")
      {:ok, _} = Memory.put("dev", "On dev.", "root@example.test")

      assert Enum.map(pushed(pod, later, user)["memory"], &{&1["scope"], &1["name"], &1["text"]}) ==
               [
                 {"organisation", nil, "Everyone."},
                 {"team", "engineering", "Engineering."},
                 {"profile", "dev", "On dev."}
               ]
    end

    # Issue #55, slice 2: a save while a session runs reaches it without waiting for its next
    # activation. The pod holding it is told `session.memory` with every document the
    # session now reads, and a save a session's scope does not cover tells it nothing.
    test "a save tells the pod holding a running session in its scope, with what it now reads",
         context do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)
      {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
      {:ok, _team} = Identity.enable_team(group, %{name: "platform"})
      root = Admin.actor_for(person("root@example.test", ["platform"]))

      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()
      _design = team_with_grant("design", "dev", name: "design")
      session = dormant_session(user, "dev", v1.version)
      id = session.id
      assert pushed(pod, session, user)["memory"] == []

      {:ok, _} = Admin.memory_put(root, "organisation", nil, "Everyone.", 0)

      assert_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id} = told}, 5_000
      assert told["epoch"] == Sessions.get(id).epoch
      assert Enum.map(told["memory"], &{&1["scope"], &1["text"]}) == [{"organisation", "Everyone."}]

      # Another team's save is not this session's.
      {:ok, _} = Admin.memory_put(root, "team", "design", "Design only.", 0)
      refute_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id}}, 500

      # A profile's reaches the sessions of every profile that extends it, read before the
      # child's own.
      {:ok, _} = Fleet.put_profile(%{name: "standard", image: "ghcr.io/troupe/worker:1"})
      dev = Fleet.get_profile("dev")
      {:ok, _} = Fleet.put_profile(%{name: "dev", extends: "standard", own: %{}, spec: dev.spec})
      {:ok, _} = Admin.memory_put(root, "profile", "dev", "On dev.", 0)
      assert_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id}}, 5_000
      {:ok, _} = Admin.memory_put(root, "profile", "standard", "On every standard pod.", 0)

      assert_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id} = told}, 5_000

      assert Enum.map(told["memory"], &{&1["scope"], &1["name"], &1["text"]}) == [
               {"organisation", nil, "Everyone."},
               {"profile", "standard", "On every standard pod."},
               {"profile", "dev", "On dev."}
             ]
    end

    # Issue #55's user level: a person's own memory rides with their sessions' activation,
    # after the organisation's levels, and a save of it tells the pods holding their running
    # sessions and nobody else's.
    test "a person's own memory reaches their sessions on a pod, last, and nobody else's",
         context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      ada = granted_user()
      bo = person("bo@example.test", ["engineering"])
      hers = dormant_session(ada, "dev", v1.version)
      his = dormant_session(bo, "dev", v1.version)

      {:ok, _} = Memory.put(:organisation, "Everyone.", "root@example.test")
      {:ok, _} = Memory.save_own(ada, "I write British English.", 0)

      assert Enum.map(pushed(pod, hers, ada)["memory"], &{&1["scope"], &1["text"]}) == [
               {"organisation", "Everyone."},
               {"user", "I write British English."}
             ]

      assert Enum.map(pushed(pod, his, bo)["memory"], & &1["scope"]) == ["organisation"]

      # Running now; her next save reaches her session at its next turn, not his.
      id = hers.id
      theirs = his.id
      {:ok, _} = Memory.append_own(ada, "Prefers small pull requests.", session: id)

      assert_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id} = told}, 5_000
      assert [%{"scope" => "organisation"}, %{"scope" => "user", "text" => text}] = told["memory"]
      assert text =~ "I write British English.\n\n## "
      assert text =~ "- Prefers small pull requests."
      refute_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^theirs}}, 500

      # And an organisation's save keeps her own in what her session is told it reads.
      {:ok, _} = Memory.put(:organisation, "Everyone, v2.", "root@example.test")
      _told = Memory.announce(:organisation)
      assert_receive {:pushed, ^pod, "session.memory", %{"session_id" => ^id} = again}, 5_000
      assert Enum.map(again["memory"], & &1["scope"]) == ["organisation", "user"]
    end

    # Issue #724: the profile's per-tool rules ride the same way, each with the profile that
    # wrote it, those of a profile it extends first, so a rule reaches a session at its next
    # wake and restarts no pod.
    test "the push carries the profile's per-tool rules and its parent's", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")
      user = granted_user()
      before = dormant_session(user, "dev", v1.version)
      later = dormant_session(user, "dev", v1.version)

      assert pushed(pod, before, user)["permission_rules"] == []

      {:ok, _} =
        Fleet.put_profile(%{
          name: "standard",
          image: "ghcr.io/troupe/worker:1",
          spec: %{"permissions" => %{"deny" => ["shell(curl)"]}}
        })

      dev = Fleet.get_profile("dev")

      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          extends: "standard",
          own: %{"spec" => %{"permissions" => %{"ask" => ["mcp(issues.delete)"]}}},
          spec: Map.put(dev.spec, "permissions", %{"ask" => ["mcp(issues.delete)"]})
        })

      assert pushed(pod, later, user)["permission_rules"] == [
               %{"action" => "deny", "rule" => "shell(curl)", "profile" => "standard"},
               %{"action" => "ask", "rule" => "mcp(issues.delete)", "profile" => "dev"}
             ]
    end

    test "activating on a version that is still live is not an upgrade", context do
      {:ok, v1} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      user = granted_user()
      session = dormant_session(user, "dev", v1.version)

      assert {:ok, _} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "activate"},
                 context(user)
               )

      assert_receive {:pushed, ^pod, "session.activate", params}, 5_000
      assert params["bundle_version"] == v1.version
      refute params["bundle_upgraded_from"]
    end
  end

  describe "losing a grant" do
    test "makes the team's sessions read-only, and activation is refused", context do
      {:ok, _} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)
      _pod = fake_pod(context.port, "dev-token", "troupe-w-dev-0")

      user = granted_user()
      team = Identity.get_team("engineering")
      session = dormant_session(user, "dev", 1)

      :ok = Identity.revoke(team, "dev")

      assert Sessions.get(session.id).state == "read_only"

      # Reads still work: history is history.
      assert {:ok, read} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "read"},
                 context(user)
               )

      assert read["mode"] == "read"

      assert {:error, error} =
               Harness.call(
                 "session.open",
                 %{"session_id" => session.id, "mode" => "activate"},
                 context(user)
               )

      assert error.message == "forbidden"
      assert error.data.reason =~ "read-only"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp context(user), do: %{user: user, platform_admin?: false}

  defp schema_1(parts) do
    %{
      "schema" => 1,
      "agents" => Keyword.get(parts, :agents, []),
      "skills" => Keyword.get(parts, :skills, []),
      "mcp_servers" => Keyword.get(parts, :mcp_servers, [])
    }
  end

  # One of everything: a primary that lists a skill, a subagent, the skill, and a server
  # with a credential.
  defp full_bundle do
    schema_1(
      agents: [
        %{
          "name" => "pr-reviewer",
          "definition" =>
            "---\ndescription: Reviews code\nmode: primary\nskills: [review-checklist]\n---\nYou review."
        },
        %{"name" => "helper", "definition" => "---\nmode: subagent\n---\nYou help."}
      ],
      skills: [
        %{
          "name" => "review-checklist",
          "description" => "How we review",
          "files" => %{
            "SKILL.md" => "---\nname: review-checklist\ndescription: How we review\n---\nCheck.",
            "list.md" => "- tests"
          }
        }
      ],
      mcp_servers: [
        %{
          "name" => "jira",
          "url" => "https://mcp.jira.example/mcp",
          "credential_ref" => "JIRA_MCP_TOKEN"
        }
      ]
    )
  end

  # A dormant session opened to activate, and the push its pod was sent for it.
  defp pushed(pod, session, user) do
    id = session.id
    open = %{"session_id" => id, "mode" => "activate"}
    assert {:ok, _} = Harness.call("session.open", open, context(user))
    assert_receive {:pushed, ^pod, "session.activate", %{"session_id" => ^id} = params}, 5_000
    params
  end

  defp granted_user do
    _team = team_with_grant("engineering", "dev", name: "engineering")
    person("ada@example.test", ["engineering"])
  end

  defp dormant_session(user, profile, bundle_version) do
    team = Identity.get_team("engineering")

    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_id: user.id,
        owner_subject: user.subject,
        team_id: team.id,
        profile: profile,
        state: "dormant",
        epoch: 1,
        bundle_version: bundle_version
      })

    session
  end

  defp enrol(profile, pod_name) do
    Fleet.enrol(%{
      profile: profile,
      namespace: "troupe-w-#{profile}",
      pod_name: pod_name,
      ordinal: pod_name |> String.split("-") |> List.last() |> String.to_integer(),
      capacity: 4,
      disk_total_bytes: 1_000_000
    })
  end

  defp fake_pod(port, token, pod_name) do
    test = self()
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 0,
        "method" => "enrol",
        "params" => %{
          "token" => FakePod.token(token),
          "pod_name" => pod_name,
          "capacity" => 4,
          "disk_total_bytes" => 1_000_000
        }
      })

    :ok = :gen_tcp.send(socket, [request, ?\n])
    {:ok, _line} = :gen_tcp.recv(socket, 0, 5_000)

    pid = spawn_link(fn -> serve(socket, test, pod_name) end)
    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, :ready)
    ExUnit.Callbacks.on_exit(fn -> :gen_tcp.close(socket) end)

    pod_name
  end

  defp serve(socket, test, pod_name) do
    receive do
      :ready -> :inet.setopts(socket, active: true)
    after
      1_000 -> :ok
    end

    loop(socket, test, pod_name)
  end

  defp loop(socket, test, pod_name) do
    receive do
      {:tcp, ^socket, data} ->
        data
        |> String.split("\n", trim: true)
        |> Enum.each(&handle_line(&1, socket, test, pod_name))

        loop(socket, test, pod_name)

      {:tcp_closed, ^socket} ->
        :ok
    end
  end

  defp handle_line(line, socket, test, pod_name) do
    case Jason.decode(line) do
      {:ok, %{"method" => method, "params" => params} = message} ->
        send(test, {:pushed, pod_name, method, params})
        answer(socket, message["id"])

      _ ->
        :ok
    end
  end

  defp answer(_socket, nil), do: :ok

  defp answer(socket, id) do
    :gen_tcp.send(socket, [
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"ok" => true}}),
      ?\n
    ])
  end
end
