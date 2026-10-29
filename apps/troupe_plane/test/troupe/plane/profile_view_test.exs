defmodule Troupe.Plane.ProfileViewTest do
  @moduledoc """
  `profile.get` tells a person what a profile gives a session of theirs before they start
  one, from the plane's own composition: the agents the profile's rule and their team's
  grant leave, and those they take away with whose word it was; the skills; each MCP
  server with whose access a call goes out as and whether the grant offers it; the
  profile's per-tool rules; the model; the hosts the operator lets the pods reach; the
  limits and budgets; and the team a session would belong to, picked as `session.create`
  picks it. A person who may not use the profile is told it is not found; a platform admin
  in no team that may use it sees the profile's own view, no team and no grant narrowing.

  Against the database only: no pod is needed, since nothing is placed.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, Fleet, Harness, Identity}
  alias Troupe.Protocol.AgentDefinition

  setup do
    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 50_000_000)
    ada = person("ada@example.test", ["engineering"])
    {:ok, ada} = Identity.set_budget(ada, 20_000_000)

    {:ok, _profile} =
      Fleet.put_profile(%{
        name: "dev",
        config_bundle_channel: "stable",
        replicas: 1,
        sessions_per_pod: 4,
        max_sessions: 6,
        budget_micros: 100_000_000,
        spec: spec()
      })

    {:ok, _bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    {:ok, _} =
      Identity.grant(team, "dev", %{
        "entitlements" => [
          %{"kind" => "agent", "name" => "plan", "mode" => "deny"},
          %{"kind" => "skill", "name" => "notes", "mode" => "deny"},
          %{"kind" => "mcp_server", "name" => "warehouse", "mode" => "deny"}
        ]
      })

    {:ok, _worker} =
      Fleet.enrol(%{
        profile: "dev",
        ordinal: 0,
        pod_name: "troupe-w-dev-0",
        namespace: "troupe-w-dev",
        capacity: 4,
        active_sessions: 1
      })

    %{team: team, ada: ada}
  end

  describe "a member" do
    test "sees the agents a session gets, and those it does not with whose word it was", ctx do
      view = view!(ctx.ada)

      assert names(view["agents"]) ==
               ~w(build orchestrate pr-reviewer general helper implementer reviewer)

      assert %{"mode" => "primary", "from" => "bundle", "description" => "Reviews code"} =
               find(view["agents"], "pr-reviewer")

      assert %{"mode" => "subagent", "from" => "builtin"} = find(view["agents"], "reviewer")

      assert view["agents_not_here"] == [
               %{
                 "name" => "plan",
                 "mode" => "primary",
                 "from" => "builtin",
                 "why" => "grant",
                 "description" => find_builtin_description("plan")
               },
               %{
                 "name" => "explore",
                 "mode" => "subagent",
                 "from" => "builtin",
                 "why" => "profile",
                 "description" => find_builtin_description("explore")
               },
               %{
                 "name" => "librarian",
                 "mode" => "function",
                 "from" => "builtin",
                 "why" => "profile",
                 "description" => find_builtin_description("librarian")
               }
             ]
    end

    test "sees the function agents the harness may run there, less those the rule denies", ctx do
      view = view!(ctx.ada)

      # The harness's own jobs are in neither list a session picks from, and the
      # librarian the profile's rule denies is not among them.
      assert view["functions"] == [
               %{
                 "name" => "answer",
                 "from" => "builtin",
                 "description" => find_builtin_description("answer")
               },
               %{
                 "name" => "ask",
                 "from" => "builtin",
                 "description" => find_builtin_description("ask")
               },
               %{
                 "name" => "quick",
                 "from" => "builtin",
                 "description" => find_builtin_description("quick")
               }
             ]

      for name <- ~w(answer ask quick librarian), do: refute(find(view["agents"], name))
    end

    test "is shown the primaries profiles.list offers them, which are the ones a create allows",
         ctx do
      assert {:ok, %{"profiles" => [listed]}} = Harness.call("profiles.list", %{}, as(ctx.ada))
      view = view!(ctx.ada)

      primaries = for %{"mode" => "primary", "name" => name} <- view["agents"], do: name
      assert Enum.sort(primaries) == Enum.sort(listed["agents"])
    end

    test "sees each MCP server with whose access it calls as, and one the grant withholds", ctx do
      assert view!(ctx.ada)["tools"]["mcp"] == [
               %{
                 "name" => "jira",
                 "host" => "mcp.jira.example",
                 "access" => "yours",
                 "permission" => "ask",
                 "tools" => "all",
                 "offered" => true,
                 "why" => nil
               },
               %{
                 "name" => "tracker",
                 "host" => "tracker.example.test",
                 "access" => "profile",
                 "permission" => "auto",
                 "tools" => ["search", "get"],
                 "offered" => true,
                 "why" => nil
               },
               %{
                 "name" => "warehouse",
                 "host" => "warehouse.example.test",
                 "access" => "system",
                 "permission" => "ask",
                 "tools" => "all",
                 "offered" => false,
                 "why" => "grant"
               }
             ]
    end

    test "sees the profile's rules as tool, pattern and access, and the skills the grant leaves",
         ctx do
      view = view!(ctx.ada)

      assert view["tools"]["rules"] == [
               %{
                 "tool" => "shell",
                 "pattern" => "git push",
                 "access" => "deny",
                 "from" => "profile"
               },
               %{"tool" => "mcp", "pattern" => "tracker", "access" => "ask", "from" => "profile"},
               %{"tool" => "web_fetch", "pattern" => nil, "access" => "ask", "from" => "profile"},
               %{
                 "tool" => "shell",
                 "pattern" => "mix test",
                 "access" => "allow",
                 "from" => "profile"
               }
             ]

      assert view["skills"] == ["review-checklist"]
    end

    test "sees the model, and the hosts the pods may reach, deduplicated and sorted", ctx do
      view = view!(ctx.ada)

      assert view["model"] == %{
               "model" => "big",
               "small_model" => "small",
               "provider" => "openai",
               "host" => "llm.example.test",
               "key" => "profile"
             }

      assert view["reach"] == [
               "api.github.com",
               "docs.example.test",
               "llm.example.test",
               "login.example.test",
               "mcp.jira.example",
               "tracker.example.test",
               "warehouse.example.test"
             ]
    end

    test "sees the limits and the three budgets that apply to them, and the bundle pinned", ctx do
      view = view!(ctx.ada)

      assert view["limits"] == %{
               "sessions_per_pod" => 4,
               "max_sessions" => 6,
               "capacity" => 4,
               "active_sessions" => 1,
               "budgets" => %{"profile" => 100_000_000, "team" => 50_000_000, "you" => 20_000_000}
             }

      bundle = Bundles.current("stable")

      assert %{"name" => "dev", "channel" => "stable", "terms" => nil} = view
      assert view["bundle_version"] == bundle.version
      assert view["bundle_hash"] == bundle.hash
    end

    test "has the team picked as session.create picks it: theirs alone, or the one named", ctx do
      assert %{"team" => "engineering", "teams" => ["engineering"]} = view!(ctx.ada)

      _research = team_with_grant("research", "dev", name: "research")
      both = person("ada@example.test", ["engineering", "research"])

      # Two teams may pay, and a create would ask which: no team, and the listing's set.
      assert %{"team" => nil, "teams" => ["engineering", "research"]} = view = view!(both)
      assert {:ok, %{"profiles" => [listed]}} = Harness.call("profiles.list", %{}, as(both))
      primaries = for %{"mode" => "primary", "name" => name} <- view["agents"], do: name
      assert Enum.sort(primaries) == Enum.sort(listed["agents"])
      assert view["limits"]["budgets"]["team"] == nil

      # Named, research's grant narrows nothing.
      assert {:ok, %{"team" => "research"} = research} =
               Harness.call("profile.get", %{"name" => "dev", "team" => "research"}, as(both))

      assert "plan" in names(research["agents"])

      # Named, it is that team's grant, as the session's would be.
      assert {:ok, %{"team" => "engineering"} = engineering} =
               Harness.call("profile.get", %{"name" => "dev", "team" => "engineering"}, as(both))

      refute "plan" in names(engineering["agents"])

      assert {:error, %{message: "not_found"}} =
               Harness.call("profile.get", %{"name" => "dev", "team" => "sales"}, as(both))
    end
  end

  describe "anybody else" do
    test "a person who may not use the profile is told it is not found" do
      bob = person("bob@example.test", [])

      assert {:error, %{message: "not_found", data: %{profile: "dev"}}} =
               Harness.call("profile.get", %{"name" => "dev"}, as(bob))
    end

    test "a platform admin in no team that may use it sees the profile's own view" do
      root = person("root@example.test", ["platform-admins"])
      context = %{user: root, platform_admin?: true}

      assert {:ok, view} = Harness.call("profile.get", %{"name" => "dev"}, context)
      assert %{"team" => nil, "teams" => []} = view

      # No grant narrows it, so what the grant took from a member is there.
      assert "plan" in names(view["agents"])
      assert Enum.all?(view["tools"]["mcp"], & &1["offered"])
      assert view["agents_not_here"] |> names() == ["explore", "librarian"]
      assert view["limits"]["budgets"]["team"] == nil

      assert {:error, %{message: "not_found"}} =
               Harness.call("profile.get", %{"name" => "nowhere"}, context)
    end

    test "a call without a name is refused saying so", ctx do
      assert {:error, %{message: "invalid_params", data: %{missing: "name"}}} =
               Harness.call("profile.get", %{}, as(ctx.ada))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  defp view!(user) do
    assert {:ok, view} = Harness.call("profile.get", %{"name" => "dev"}, as(user))
    view
  end

  defp names(agents), do: Enum.map(agents, & &1["name"])
  defp find(agents, name), do: Enum.find(agents, &(&1["name"] == name))

  defp find_builtin_description(name) do
    {:ok, parsed} =
      AgentDefinition.parse(name, Bundles.builtin_definitions()[name])

    parsed.description
  end

  defp spec do
    %{
      "agents" => %{"deny" => ["explore", "librarian"]},
      "permissions" => %{
        "deny" => ["shell(git push)"],
        "ask" => ["mcp(tracker)", "web_fetch"],
        "allow" => ["shell(mix test)"]
      },
      "llm" => %{
        "endpoint" => "https://llm.example.test/v1",
        "model" => "big",
        "smallModel" => "small",
        "secretRef" => %{"name" => "dev-llm", "key" => "api-key"}
      },
      "egress" => %{"fqdns" => ["docs.example.test", "api.github.com", "llm.example.test"]},
      "mcpIdentities" => [
        %{
          "server" => "warehouse",
          "clientId" => "dev-client",
          "tokenUrl" => "https://login.example.test/oauth2/token",
          "transitKey" => "troupe-w-dev.warehouse",
          "certificateThumbprint" => String.duplicate("A", 43)
        }
      ]
    }
  end

  defp bundle_content do
    %{
      "schema" => 1,
      "agents" => [
        %{
          "name" => "pr-reviewer",
          "definition" => "---\ndescription: Reviews code\nmode: primary\n---\nYou review."
        },
        %{"name" => "helper", "definition" => "---\nmode: subagent\n---\nYou help."}
      ],
      "skills" => [skill("review-checklist"), skill("notes")],
      "mcp_servers" => [
        %{
          "name" => "jira",
          "url" => "https://mcp.jira.example/mcp",
          "credential_mode" => "person"
        },
        %{
          "name" => "tracker",
          "url" => "https://tracker.example.test/mcp",
          "credential_ref" => "TRACKER_TOKEN",
          "permission" => "auto",
          "tools" => ["search", "get"]
        },
        %{
          "name" => "warehouse",
          "url" => "https://warehouse.example.test/mcp",
          "credential_mode" => "client_credentials"
        }
      ]
    }
  end

  defp skill(name) do
    %{
      "name" => name,
      "description" => "The #{name} skill",
      "files" => %{
        "SKILL.md" => "---\nname: #{name}\ndescription: The #{name} skill\n---\nDo it."
      }
    }
  end
end
