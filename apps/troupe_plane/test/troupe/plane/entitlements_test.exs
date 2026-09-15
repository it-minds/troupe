defmodule Troupe.Plane.EntitlementsTest do
  @moduledoc """
  A grant may name which of a bundle's agents, skills and servers a team gets.

  The rule under every one of these is **absence means everything**: a grant with no
  rows behaves exactly as it did before the table existed, which is why the migration
  that added it needed no backfill. The rest is what happens once somebody writes one —
  an allowlist where anything is allowed, a subtraction where anything is denied, and
  deny winning where both name the same thing.

  Resolution lands where it can be audited: in the offering a person is shown, in the
  refusal `session.create` gives before it has spent anything, and in the set the pod is
  told and records in the session's log.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Bundles, FakePod, Fleet, Harness, Identity, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Identity.Entitlement

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    {:ok, _profile} =
      Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

    {:ok, bundle} = Bundles.publish("stable", bundle_content(), announce: false)

    %{port: Listener.port(), team: team, ada: ada, bundle: bundle}
  end

  describe "the rules" do
    test "no rows means everything, an allow row is an allowlist, a deny row subtracts" do
      assert Entitlement.resolve(~w(a b c), []) == ~w(a b c)

      assert Entitlement.resolve(~w(a b c), [row("a", "allow")]) == ~w(a)
      assert Entitlement.resolve(~w(a b c), [row("a", "deny")]) == ~w(b c)

      assert Entitlement.resolve(~w(a b c), [row("a", "allow"), row("b", "allow")]) == ~w(a b)
      assert Entitlement.resolve(~w(a b c), [row("a", "deny"), row("b", "deny")]) == ~w(c)
    end

    test "deny beats allow for the same name" do
      rows = [row("a", "allow"), row("a", "deny"), row("b", "allow")]
      assert Entitlement.resolve(~w(a b c), rows) == ~w(b)
    end

    test "kinds do not interact" do
      rows = [
        %{kind: "skill", name: "review", mode: "allow"},
        %{kind: "agent", name: "reviewer", mode: "deny"}
      ]

      assert Entitlement.resolve(~w(review other), Entitlement.of_kind(rows, "skill")) ==
               ~w(review)

      assert Entitlement.resolve(~w(reviewer build), Entitlement.of_kind(rows, "agent")) ==
               ~w(build)

      # An allowlist of skills says nothing about MCP servers, which is what lets an
      # admin narrow one list without enumerating the other two.
      assert Entitlement.resolve(~w(jira), Entitlement.of_kind(rows, "mcp_server")) == ~w(jira)
    end
  end

  describe "a grant with no rows" do
    test "offers exactly what the bundle has", context do
      assert {:ok, %{"profiles" => [profile]}} =
               Harness.call("profiles.list", %{}, as(context.ada))

      assert profile["agents"] == ["reviewer", "build", "plan"]

      assert profile["skills"] == [
               %{"name" => "review", "description" => "How we review"},
               %{"name" => "handbook", "description" => "How we work"}
             ]

      assert profile["mcp_servers"] == ["jira", "pager"]
      assert Identity.entitlements_for(context.team, "dev") == []
    end
  end

  describe "a narrowed grant" do
    test "shows one of two skills in the offering and none of the other", context do
      entitle(context.team, [%{"kind" => "skill", "name" => "review", "mode" => "allow"}])

      assert {:ok, %{"profiles" => [profile]}} =
               Harness.call("profiles.list", %{}, as(context.ada))

      assert profile["skills"] == [%{"name" => "review", "description" => "How we review"}]

      entitle(context.team, [%{"kind" => "skill", "name" => "handbook", "mode" => "allow"}])

      assert {:ok, %{"profiles" => [narrowed]}} =
               Harness.call("profiles.list", %{}, as(context.ada))

      assert narrowed["skills"] == [%{"name" => "handbook", "description" => "How we work"}]
    end

    test "refuses an agent the team may not run, before placing or budgeting", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      entitle(context.team, [%{"kind" => "agent", "name" => "build", "mode" => "allow"}])

      params = %{"profile" => "dev", "agent" => "reviewer", "team" => "engineering"}
      assert {:error, error} = Harness.call("session.create", params, as(context.ada))

      assert error.message == "invalid_params"
      assert error.data.reason == "no primary agent named reviewer"
      # And it says what could have been asked for, which is the whole point of
      # refusing here rather than on the pod.
      assert error.data.agents == ["build"]

      # Nothing was spent: no row, no placement, no reservation.
      assert Sessions.for_admin(platform_admin(), [context.team.id]) == []
      refute_received {:pushed, "session.activate", _}
    end

    test "a list that says allow and deny for one name stores the deny", context do
      entitle(context.team, [
        %{"kind" => "mcp_server", "name" => "jira", "mode" => "allow"},
        %{"kind" => "mcp_server", "name" => "jira", "mode" => "deny"}
      ])

      # One row per name is what the unique index holds; two ways of writing one intent
      # must not disagree, and the safe reading is the one that grants less.
      assert [%{kind: "mcp_server", name: "jira", mode: "deny"}] =
               Identity.entitlements_for(context.team, "dev")

      assert {:ok, %{"profiles" => [profile]}} =
               Harness.call("profiles.list", %{}, as(context.ada))

      assert profile["mcp_servers"] == ["pager"]
    end
  end

  describe "the session" do
    test "is told its set, and the set is what the log will record", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      entitle(context.team, [
        %{"kind" => "skill", "name" => "review", "mode" => "allow"},
        %{"kind" => "mcp_server", "name" => "pager", "mode" => "deny"}
      ])

      params = %{"profile" => "dev", "team" => "engineering"}
      assert {:ok, _endpoint} = Harness.call("session.create", params, as(context.ada))

      assert_receive {:pushed, "session.activate", pushed}, 5_000

      assert pushed["entitlements"] == %{
               "agents" => ["reviewer", "build", "plan"],
               "skills" => ["review"],
               "mcp_servers" => ["jira"]
             }
    end

    test "gets its own team's set, not the union of the person's teams", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      other = team_with_grant("platform", "dev", name: "platform", budget_micros: 0)
      bo = person("bo@example.test", ["engineering", "platform"])

      entitle(context.team, [%{"kind" => "skill", "name" => "review", "mode" => "allow"}])
      entitle(other, [%{"kind" => "skill", "name" => "handbook", "mode" => "allow"}])

      # The listing is the union: a person in two teams may use what either gives them,
      # and a listing showing an intersection would hide something they can have.
      assert {:ok, %{"profiles" => [profile]}} = Harness.call("profiles.list", %{}, as(bo))
      assert Enum.sort(Enum.map(profile["skills"], & &1["name"])) == ["handbook", "review"]

      # The session is narrower, and on purpose: it belongs to one team and gets that
      # team's set, the same rule that decides whose budget and whose volume it uses.
      params = %{"profile" => "dev", "team" => "platform"}
      assert {:ok, _} = Harness.call("session.create", params, as(bo))
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["entitlements"]["skills"] == ["handbook"]
    end
  end

  describe "the admin surface" do
    test "writes the rows, and the audit diff is a diff of names", context do
      root = platform_admin()

      assert {:ok, _} =
               Admin.team_grant(root, "engineering", "dev", %{
                 "entitlements" => [
                   %{"kind" => "skill", "name" => "review", "mode" => "allow"},
                   %{"kind" => "mcp_server", "name" => "pager", "mode" => "deny"}
                 ]
               })

      assert [%{kind: "mcp_server", name: "pager", mode: "deny"}, %{kind: "skill", name: "review"}] =
               Identity.entitlements_for(context.team, "dev")

      assert {:ok, events} = Admin.audit_list(root, limit: 5)
      assert %{detail: detail} = Enum.find(events, &(&1.action == "team.grant"))

      assert detail["entitlements"] == %{
               "mcp_server" => %{"from" => nil, "to" => ["deny:pager"]},
               "skill" => %{"from" => nil, "to" => ["allow:review"]}
             }
    end

    test "a row naming something the current bundle lacks is kept, not refused",
         context do
      # A bundle can be rolled back, and an entitlement that vanished with a publish and
      # did not come back with the revert would be a silent widening.
      entitle(context.team, [%{"kind" => "skill", "name" => "not-published-yet", "mode" => "allow"}])

      assert [%{name: "not-published-yet"}] = Identity.entitlements_for(context.team, "dev")

      assert {:ok, %{"profiles" => [profile]}} =
               Harness.call("profiles.list", %{}, as(context.ada))

      assert profile["skills"] == []
    end

    test "sending the key replaces the list; leaving it out changes nothing", context do
      entitle(context.team, [%{"kind" => "skill", "name" => "review", "mode" => "allow"}])

      {:ok, _} = Identity.grant(context.team, "dev", %{volume_mode: "rw"})
      assert [%{name: "review"}] = Identity.entitlements_for(context.team, "dev")

      entitle(context.team, [])
      assert Identity.entitlements_for(context.team, "dev") == []
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  # The platform admin group is what makes one, so a test that needs one makes a person
  # in it rather than a map with the right shape — `Admin.actor_for/1` is where the role
  # is decided and a test that went round it would be testing its own fixture.
  defp platform_admin do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform-admins")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    "root@example.test"
    |> person(["platform-admins"])
    |> Admin.actor_for()
  end

  defp row(name, mode), do: %{kind: "skill", name: name, mode: mode}

  defp entitle(team, rows) do
    {:ok, _} = Identity.grant(team, "dev", %{"entitlements" => rows})
    :ok
  end

  defp bundle_content do
    %{
      "schema" => 1,
      "agents" => [
        %{
          "name" => "reviewer",
          "definition" => "---\nmode: primary\nskills: [review]\n---\nReview."
        },
        %{"name" => "helper", "definition" => "You help."}
      ],
      "skills" => [
        %{
          "name" => "review",
          "description" => "How we review",
          "files" => %{
            "SKILL.md" => "---\nname: review\ndescription: How we review\n---\nCheck."
          }
        },
        %{
          "name" => "handbook",
          "description" => "How we work",
          "files" => %{
            "SKILL.md" => "---\nname: handbook\ndescription: How we work\n---\nRead."
          }
        }
      ],
      "mcp_servers" => [
        %{"name" => "jira", "url" => "https://mcp.jira.example/mcp"},
        %{"name" => "pager", "url" => "https://mcp.pager.example/mcp"}
      ]
    }
  end
end
