defmodule Troupe.Plane.BundlesTest do
  @moduledoc """
  Config bundles: what a new session gets, and what a running one keeps.

  Two promises. Publishing reaches every pod, and every pod says so by reporting the new
  hash. And a running session's configuration does not move under it — versions are
  immutable, a session is pinned at creation, and the only way its configuration ever
  changes is a deliberate upgrade at activation that lands in the log as an event.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, Fleet, Harness, Identity, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Fleet.Bundle

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &verify/1})

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
               "mcp_servers" => ["jira"]
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
          agents: [%{"name" => "reviewer", "definition" => "---\nmode: sideways\n---\nHi"}]
        )

      assert {:error, {:invalid_bundle, [message]}} =
               Bundles.publish("stable", content, announce: false)

      assert message =~ "reviewer"
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
               "agents" => ["reviewer", "helper"],
               "skills" => ["review-checklist"],
               "mcp_servers" => ["jira"]
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
                 %{"profile" => "dev", "agent" => "reviewer"},
                 context(user)
               )

      assert_receive {:pushed, ^pod, "session.activate", params}, 5_000
      assert params["agent"] == "reviewer"
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
      assert error.data.agents == ["reviewer", "build", "plan"]
      refute_receive {:pushed, ^pod, "session.activate", %{"agent" => "helper"}}, 200
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
          "name" => "reviewer",
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
          "token" => token,
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

  defp verify("dev-token") do
    {:ok,
     %{profile: "dev", namespace: "troupe-w-dev", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify("ux-token") do
    {:ok,
     %{profile: "ux", namespace: "troupe-w-ux", pod_name: nil, service_account: "troupe-worker"}}
  end

  defp verify(_token), do: {:error, :unauthenticated}
end
