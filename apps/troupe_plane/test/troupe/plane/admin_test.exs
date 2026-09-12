defmodule Troupe.Plane.AdminTest do
  @moduledoc """
  What each administrator can see and do, and what neither can.

  The done items here are mostly refusals: a team admin who sees another team's sessions,
  or any admin who can read what a session said, is a breach rather than a bug. So every
  test that grants something also checks the thing next to it is still refused.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Bundles, Fleet, Identity, Sessions}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    engineering =
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)

    design = team_with_grant("design", "ux", name: "design", budget_micros: 500_000)

    {:ok, platform_group} =
      Identity.upsert_group(%{external_id: "platform", display_name: "platform"})

    {:ok, _platform_team} = Identity.enable_team(platform_group, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    member = person("member@example.test", ["engineering"])

    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    {:ok, _} =
      Fleet.put_profile(%{
        name: "dev",
        replicas: 2,
        sessions_per_pod: 4,
        image: "ghcr.io/troupe/worker:1"
      })

    {:ok, _} = Fleet.put_profile(%{name: "ux", replicas: 1, sessions_per_pod: 2})

    %{
      engineering: engineering,
      design: design,
      root: Admin.actor_for(root),
      lead: Admin.actor_for(lead),
      member: Admin.actor_for(member)
    }
  end

  describe "who is an administrator" do
    test "a platform admin is one by group membership", context do
      assert context.root.role == :platform_admin
      assert Admin.admin?(context.root)
    end

    test "a team admin is one by assignment, and only for their team", context do
      assert context.lead.role == :team_admin
      assert context.lead.teams == ["engineering"]
    end

    test "an ordinary member is not an administrator at all", context do
      assert context.member.role == :none
      refute Admin.admin?(context.member)

      assert {:error, error} = Admin.overview(context.member)
      assert error.message == "forbidden"
      assert error.data.required_role == "team_admin"
    end
  end

  describe "service principals and triggers" do
    test "a team admin makes a principal for their team, and the secret is shown once", context do
      assert {:ok, made} =
               Admin.principal_create(context.lead, "engineering", %{
                 "name" => "nightly-deps",
                 "description" => "the nightly dependency update",
                 "profiles" => ["dev"]
               })

      assert made.subject == "svc:engineering/nightly-deps"
      assert is_binary(made.secret)
      assert made.enabled

      assert {:ok, [listed]} = Admin.principals_list(context.lead, "engineering")
      refute Map.has_key?(listed, :secret)
      assert listed.profiles == ["dev"]

      # Audited, without the secret.
      assert [event] = Audit.list(kind: "principal")
      assert event.action == "principal.create"
      assert event.actor == "lead@example.test"
      refute inspect(event.detail) =~ made.secret

      # Not for another team, and not for a profile the team is not granted.
      assert {:error, error} =
               Admin.principal_create(context.lead, "design", %{
                 "name" => "x",
                 "profiles" => ["ux"]
               })

      assert error.message == "not_found"

      assert {:error, error} =
               Admin.principal_create(context.lead, "engineering", %{
                 "name" => "x",
                 "profiles" => ["ux"]
               })

      assert error.message == "invalid_params"

      assert {:error, error} =
               Admin.principal_create(context.member, "engineering", %{
                 "name" => "x",
                 "profiles" => ["dev"]
               })

      assert error.message == "forbidden"

      # Rotating gives a new secret; disabling ends it, and both are audited.
      assert {:ok, rotated} = Admin.principal_rotate(context.lead, made.subject)
      assert rotated.secret != made.secret

      assert {:ok, disabled} = Admin.principal_disable(context.lead, made.subject)
      refute disabled.enabled
      assert is_nil(Identity.get_user(made.subject))

      actions = Audit.list(kind: "principal") |> Enum.map(& &1.action) |> Enum.sort()
      assert actions == ["principal.create", "principal.disable", "principal.rotate"]

      # And the platform admin reaches every team's.
      assert {:ok, [_]} = Admin.principals_list(context.root, "engineering")
      assert {:ok, []} = Admin.principals_list(context.root, "design")
    end

    test "a trigger is put by team and name, updated in part, run by hand, and deleted",
         context do
      # Running one places a session, and placement is the singleton's business.
      start_supervised!(Troupe.Plane.Singleton)

      {:ok, principal} =
        Admin.principal_create(context.lead, "engineering", %{
          "name" => "bot",
          "profiles" => ["dev"]
        })

      definition = %{
        "team" => "engineering",
        "name" => "nightly-deps",
        "principal" => principal.subject,
        "profile" => "dev",
        "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"},
        "prompt_template" => "Update every dependency with a patch release available.",
        "terms" => %{"max_turns" => 25, "approvals" => "deny"},
        "notify" => ["lead@example.test"]
      }

      assert {:ok, %{trigger: trigger, changes: changes}} =
               Admin.trigger_put(context.lead, definition)

      assert trigger["name"] == "nightly-deps"
      assert trigger["enabled"]
      assert trigger["principal"] == principal.subject
      assert changes["prompt_template"]["to"] =~ "patch release"

      # A partial put keeps the rest.
      assert {:ok, %{trigger: off, changes: changes}} =
               Admin.trigger_put(context.lead, %{
                 "team" => "engineering",
                 "name" => "nightly-deps",
                 "enabled" => false
               })

      refute off["enabled"]
      assert off["prompt_template"] =~ "patch release"
      assert changes == %{"enabled" => %{"from" => true, "to" => false}}

      assert {:ok, [listed]} = Admin.triggers_list(context.lead, "engineering")
      assert listed["name"] == "nightly-deps"

      # Disabled, it will not run by hand either; enabled, with no pod, the run is
      # recorded as failed and the reason comes back.
      assert {:error, error} = Admin.trigger_run(context.lead, "engineering", "nightly-deps")
      assert error.message == "forbidden"

      {:ok, _} =
        Admin.trigger_put(context.lead, %{
          "team" => "engineering",
          "name" => "nightly-deps",
          "enabled" => true
        })

      assert {:error, error} = Admin.trigger_run(context.lead, "engineering", "nightly-deps")
      assert error.message in ["capacity", "unavailable"]

      assert {:ok, [run]} =
               Admin.runs_list(context.lead, team: "engineering", trigger: "nightly-deps")

      assert run["state"] == "failed"
      assert run["fired_by"] == "lead@example.test"
      assert run["trigger"] == "nightly-deps"

      # Another team's admin sees none of it.
      assert {:error, error} = Admin.triggers_list(context.lead, "design")
      assert error.message == "not_found"
      assert {:error, error} = Admin.trigger_put(context.member, definition)
      assert error.message == "forbidden"

      assert {:ok, %{deleted: true}} =
               Admin.trigger_delete(context.lead, "engineering", "nightly-deps")

      assert {:ok, []} = Admin.triggers_list(context.lead, "engineering")

      actions = Audit.list(kind: "trigger") |> Enum.map(& &1.action) |> Enum.sort()

      assert actions == [
               "trigger.delete",
               "trigger.put",
               "trigger.put",
               "trigger.put",
               "trigger.run",
               "trigger.run"
             ]
    end

    test "the admin session listing takes the queue's filters", context do
      {:ok, _} =
        Sessions.create(%{
          id: "s-run",
          owner_subject: "svc:engineering/bot",
          team_id: context.engineering.id,
          profile: "dev",
          origin: %{"kind" => "trigger", "trigger" => "nightly-deps"},
          status: "waiting",
          pending_approvals: 1
        })

      _other = session!("s-person", context.engineering, "dev")

      assert {:ok, [queued]} = Admin.sessions_list(context.lead, needs_review: true)
      assert queued.id == "s-run"
      assert {:ok, [_]} = Admin.sessions_list(context.lead, status: "waiting")
      assert {:ok, [_]} = Admin.sessions_list(context.lead, trigger: "nightly-deps")
      assert {:ok, []} = Admin.sessions_list(context.lead, origin: "a2a")
    end
  end

  describe "what a team admin sees" do
    test "their own team's sessions and no others", context do
      mine = session!("s-mine", context.engineering, "dev")
      theirs = session!("s-theirs", context.design, "ux")

      assert {:ok, sessions} = Admin.sessions_list(context.lead)
      ids = Enum.map(sessions, & &1.id)

      assert mine.id in ids
      refute theirs.id in ids

      # The platform admin sees both, which is what makes the above a scoping test rather
      # than an empty database.
      assert {:ok, all} = Admin.sessions_list(context.root)
      assert theirs.id in Enum.map(all, & &1.id)
    end

    test "their own team's spend and no others", context do
      assert {:ok, overview} = Admin.overview(context.lead)
      assert Enum.map(overview.teams, & &1.name) == ["engineering"]

      assert {:ok, everything} = Admin.overview(context.root)
      assert "design" in Enum.map(everything.teams, & &1.name)
    end

    test "only the profiles their team is granted", context do
      assert {:ok, profiles} = Admin.profiles_list(context.lead)
      assert Enum.map(profiles, & &1.name) == ["dev"]

      assert {:ok, all} = Admin.profiles_list(context.root)
      assert Enum.sort(Enum.map(all, & &1.name)) == ["dev", "ux"]
    end

    test "another team is not found rather than forbidden", context do
      # Whether a team exists is itself something a person who may not see it should not
      # learn.
      assert {:error, error} = Admin.team_update(context.lead, "design", %{budget_micros: 0})
      assert error.message == "not_found"
    end

    test "their own team's settings are theirs to change", context do
      assert {:ok, %{team: team, changes: changes}} =
               Admin.team_update(context.lead, "engineering", %{budget_micros: 2_000_000})

      assert team.budget_micros == 2_000_000
      assert changes["budget_micros"] == %{"from" => 1_000_000, "to" => 2_000_000}
    end

    test "but a grant is not", context do
      assert {:error, error} = Admin.team_grant(context.lead, "engineering", "ux")
      assert error.data.required_role == "platform_admin"

      assert {:error, profile} = Admin.profile_put(context.lead, %{name: "new", replicas: 1})
      assert profile.data.required_role == "platform_admin"
    end
  end

  describe "what no administrator can do" do
    test "read what a session said", context do
      session = session!("s-private", context.engineering, "dev")

      assert {:ok, listed} = Admin.sessions_list(context.root)
      rendered = Enum.find(listed, &(&1.id == session.id))
      assert rendered

      # Metadata, and the absence of everything else. A field that carried content would
      # show up here as a key nobody expected.
      assert rendered.id == session.id
      assert Map.keys(rendered) |> Enum.sort() == expected_session_keys()
      refute Map.has_key?(rendered, :events)
      refute Map.has_key?(rendered, :content)
    end

    test "edit who is in a team", context do
      assert {:ok, [team]} = Admin.teams_list(context.lead)

      # Members are shown and are read-only: the list comes from the identity provider.
      assert "member@example.test" in team.members
      refute function_exported?(Admin, :team_members_set, 3)
      refute function_exported?(Admin, :team_member_add, 3)
    end
  end

  describe "the audit trail" do
    test "every change is recorded with the actor and a diff", context do
      {:ok, _} = Admin.team_update(context.lead, "engineering", %{budget_micros: 42})
      {:ok, _} = Admin.team_grant(context.root, "engineering", "ux")

      assert {:ok, events} = Admin.audit_list(context.root)
      actions = Enum.map(events, & &1.action)

      assert "team.update" in actions
      assert "team.grant" in actions

      update = Enum.find(events, &(&1.action == "team.update"))
      assert update.actor == "lead@example.test"
      assert update.subject_id == "engineering"
      assert update.detail["budget_micros"]["to"] == 42

      grant = Enum.find(events, &(&1.action == "team.grant"))
      assert grant.actor == "root@example.test"
      assert grant.detail["profile"] == "ux"
    end

    test "a refused change records nothing", context do
      before = length(Audit.list())

      assert {:error, _} = Admin.team_update(context.lead, "design", %{budget_micros: 0})
      assert {:error, _} = Admin.team_grant(context.lead, "engineering", "ux")

      assert length(Audit.list()) == before
    end

    test "it is newest first, and can be narrowed", context do
      {:ok, _} = Admin.team_update(context.root, "engineering", %{budget_micros: 1})
      {:ok, _} = Admin.team_update(context.root, "design", %{budget_micros: 2})

      assert {:ok, [newest | _]} = Admin.audit_list(context.root)
      assert newest.subject_id == "design"

      assert {:ok, narrowed} = Admin.audit_list(context.root, subject_id: "engineering")
      assert Enum.all?(narrowed, &(&1.subject_id == "engineering"))
    end

    test "a field set from nothing, or cleared to nothing, is in the diff", _context do
      # The case an assignment-as-filter silently dropped: both directions of nil.
      assert Audit.diff(%{"image" => nil}, %{"image" => "ghcr.io/x:1"}) == %{
               "image" => %{"from" => nil, "to" => "ghcr.io/x:1"}
             }

      assert Audit.diff(%{"image" => "ghcr.io/x:1"}, %{"image" => nil}) == %{
               "image" => %{"from" => "ghcr.io/x:1", "to" => nil}
             }

      # And a key only one side has at all.
      assert Audit.diff(%{}, %{"replicas" => 3}) == %{"replicas" => %{"from" => nil, "to" => 3}}
      assert Audit.diff(%{"replicas" => 3}, %{}) == %{"replicas" => %{"from" => 3, "to" => nil}}
    end

    test "atom keys and string keys are the same field", _context do
      # A struct on one side and a form's params on the other is the normal case, and a
      # diff that called those different fields would report every field as changed.
      assert Audit.diff(%{replicas: 2}, %{"replicas" => 2}) == %{}

      assert Audit.diff(%{replicas: 2}, %{"replicas" => 5}) == %{
               "replicas" => %{"from" => 2, "to" => 5}
             }
    end

    test "a secret value that reached a detail is redacted", _context do
      # The plane does not hold secret values, so this should never fire. It firing is a
      # bug report — and it is better for it to be a redacted one.
      {:ok, event} =
        Audit.record("someone@example.test", "profile.put", "dev", %{
          "image" => "ghcr.io/x:1",
          "llm_api_key" => "sk-the-real-thing",
          "llm_secret_ref" => "troupe-llm-key"
        })

      assert event.detail["image"] == "ghcr.io/x:1"
      assert event.detail["llm_api_key"] == "[redacted]"

      # A *reference* is a name, not a value, and is left alone: redacting it would hide
      # the thing an operator most needs to see.
      assert event.detail["llm_secret_ref"] == "troupe-llm-key"
    end
  end

  describe "config bundles" do
    test "a platform admin publishes and retires; a team admin does neither", context do
      assert {:ok, published} =
               Admin.bundle_publish(context.root, "stable", %{"agents" => ["build"]})

      assert published.version == 1

      assert {:ok, [listed]} = Admin.bundles_list(context.lead, "stable")
      assert listed.hash == published.hash

      assert {:error, error} = Admin.bundle_publish(context.lead, "stable", %{})
      assert error.data.required_role == "platform_admin"

      assert {:ok, retired} = Admin.bundle_retire(context.root, "stable", 1)
      assert retired.retired_at
      assert Bundles.current("stable") == nil
    end

    test "an invalid bundle is refused with every error, and can be checked first", context do
      bad = %{
        "schema" => 1,
        "agents" => [
          %{"name" => "Reviewer!", "definition" => "Hi"},
          %{"name" => "odd", "definition" => "---\nmode: sideways\n---\nHi"}
        ]
      }

      assert {:error, error} = Admin.bundle_validate(context.root, bad)
      assert error.message == "invalid_params"
      assert error.data.reason == "invalid bundle"
      assert length(error.data.errors) == 2
      assert Enum.any?(error.data.errors, &(&1 =~ "Reviewer!"))
      assert Enum.any?(error.data.errors, &(&1 =~ "bad_mode"))

      # Checking publishes nothing, and publishing the same document fails the same way.
      assert Admin.bundles_list(context.root, "stable") == {:ok, []}
      assert {:error, ^error} = Admin.bundle_publish(context.root, "stable", bad)

      good = %{
        "schema" => 1,
        "mcp_servers" => [%{"name" => "jira", "url" => "https://mcp.jira.example/mcp"}]
      }

      assert {:ok, checked} = Admin.bundle_validate(context.root, good)
      assert checked.ok
      assert checked.summary["mcp_servers"] == ["jira"]

      # A team admin cannot check, because they cannot publish.
      assert {:error, refused} = Admin.bundle_validate(context.lead, good)
      assert refused.data.required_role == "platform_admin"
    end

    test "one version comes back in full, with its summary and who has it", context do
      good = %{
        "schema" => 1,
        "agents" => [
          %{
            "name" => "reviewer",
            "definition" => "---\nmode: primary\ndescription: Reviews\n---\nGo."
          }
        ],
        "mcp_servers" => [
          %{
            "name" => "jira",
            "url" => "https://mcp.jira.example/mcp",
            "credential_ref" => "JIRA_TOKEN"
          }
        ]
      }

      assert {:ok, published} = Admin.bundle_publish(context.root, "stable", good)
      assert published.summary["agents"] == ["reviewer"]

      assert {:ok, shown} = Admin.bundle_get(context.lead, "stable", published.version)
      assert shown.hash == published.hash
      assert shown.content == good
      assert [%{name: "reviewer", mode: :primary, description: "Reviews"}] = shown.detail.agents

      assert [%{name: "jira", secret: "troupe-mcp-jira", credential_ref: "JIRA_TOKEN"}] =
               shown.detail.mcp_servers

      assert [%{profile: "dev"}, %{profile: "ux"}] = shown.adoption

      assert {:error, missing} = Admin.bundle_get(context.root, "stable", 9)
      assert missing.message == "not_found"
    end

    test "an MCP host is checked against the same policy publishing uses", context do
      Application.put_env(:troupe_plane, :egress_allowed, fn host ->
        host == "mcp.jira.example"
      end)

      on_exit(fn -> Application.delete_env(:troupe_plane, :egress_allowed) end)

      assert {:ok, %{host: "mcp.jira.example", allowed: true}} =
               Admin.mcp_check(context.lead, "https://mcp.jira.example/mcp")

      assert {:ok, %{host: "mcp.other.example", allowed: false}} =
               Admin.mcp_check(context.root, "https://mcp.other.example/mcp")

      assert {:error, error} = Admin.mcp_check(context.root, "not a url")
      assert error.message == "invalid_params"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp session!(id, team, profile) do
    {:ok, session} =
      Sessions.create(%{
        id: id <> "-#{System.unique_integer([:positive])}",
        owner_subject: "someone@example.test",
        team_id: team.id,
        profile: profile,
        state: "active",
        epoch: 1
      })

    session
  end

  defp expected_session_keys do
    ~w(epoch id last_active_at last_seq object_bytes owner pinned pinned_by profile state visibility workspace_bytes)a
  end
end
