defmodule Troupe.Plane.AdminTest do
  @moduledoc """
  What each administrator can see and do, and what neither can.

  The done items here are mostly refusals: a team admin who sees another team's sessions,
  or any admin who can read what a session said, is a breach rather than a bug. So every
  test that grants something also checks the thing next to it is still refused.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{
    Admin,
    Audit,
    Bundles,
    FakeWorkerProfiles,
    Fleet,
    Identity,
    Ledger,
    Sessions,
    Triggers
  }

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
                 "profiles" => ["dev"],
                 "sponsor" => "lead@example.test"
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
                 "profiles" => ["dev"],
                 "sponsor" => "lead@example.test"
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
          "profiles" => ["dev"],
                 "sponsor" => "lead@example.test"
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

      # Whichever refuses first. This team has a pound and a session reserves five, so
      # the budget is the honest answer — it used to be `capacity`, because placement ran
      # first and there were no pods, which was the right refusal for the wrong reason.
      assert error.message in ["capacity", "unavailable", "budget_exhausted"]

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

    # The overview renders reserved spend, and every earlier test here ran against a team
    # with nothing reserved — where the bug was invisible, because `Enum.map` over an
    # empty map is `[]` and sums to zero. One open reservation is all it took: the page
    # answered 500 for every admin as soon as a single session was running.
    test "spend is still readable once a team has budget reserved", context do
      {:ok, _reservation} =
        Ledger.reserve(context.engineering.id, "s-running", "lead@example.test", 5_000_000)

      assert {:ok, overview} = Admin.overview(context.lead)
      assert [%{name: "engineering", reserved_micros: 5_000_000}] = overview.teams

      # And it is a sum over the open ones, not the first or the last.
      {:ok, _second} =
        Ledger.reserve(context.engineering.id, "s-also-running", "lead@example.test", 2_500_000)
      assert {:ok, more} = Admin.overview(context.lead)
      assert [%{reserved_micros: 7_500_000}] = more.teams

      # A released promise is not an outstanding one.
      :ok = Ledger.release(context.engineering.id, "s-running")
      assert {:ok, after_release} = Admin.overview(context.lead)
      assert [%{reserved_micros: 2_500_000}] = after_release.teams
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

  describe "what a team update takes" do
    # `admin.team.update` declares a team's settings, and the team's changeset casts the
    # whole row: its name, the group it was enabled from, when and by whom. The method
    # takes the settings it declares and leaves the rest of the row as it was, for either
    # role, the way every admin method leaves a key it does not declare.
    test "the settings it declares, and nothing else of the row", context do
      before = Identity.get_team("engineering")

      for actor <- [context.lead, context.root] do
        assert {:ok, %{team: team}} =
                 Admin.team_update(actor, "engineering", %{
                   "budget_micros" => 3_000_000,
                   "name" => "renamed",
                   "group_id" => context.design.group_id,
                   "enabled_at" => ~U[2020-01-01 00:00:00.000000Z],
                   "enabled_by" => "someone-else@example.test"
                 })

        assert team.name == "engineering"
        assert team.budget_micros == 3_000_000
      end

      after_update = Identity.get_team("engineering")
      assert after_update.group_id == before.group_id
      assert after_update.enabled_at == before.enabled_at
      assert after_update.enabled_by == before.enabled_by
      assert Identity.get_team("renamed") == nil
    end

    test "and the same by atom keys, as the console sends them", context do
      assert {:ok, %{team: team}} =
               Admin.team_update(context.lead, "engineering", %{
                 pins_allowed: false,
                 name: "renamed"
               })

      assert team.name == "engineering"
      refute team.pins_allowed
      assert Identity.get_team("renamed") == nil
    end

    test "which are the ones its schema declares" do
      alias Troupe.Plane.Admin.API

      declared =
        for argument <- API.method("admin.team.update").arguments,
            argument.name == "attrs",
            property <- argument.properties,
            do: property.name

      assert declared -- Admin.team_keys() == []
      refute Enum.any?(~w(name group_id enabled_at enabled_by), &(&1 in Admin.team_keys()))
    end

    test "and enabling one sets its name and settings, not its record", context do
      {:ok, group} = Identity.upsert_group(%{external_id: "research", display_name: "research"})

      assert {:ok, team} =
               Admin.team_enable(context.root, "research", %{
                 "name" => "research",
                 "budget_micros" => 7_000_000,
                 "group_id" => context.design.group_id,
                 "enabled_at" => ~U[2020-01-01 00:00:00.000000Z]
               })

      assert team.name == "research"
      assert team.budget_micros == 7_000_000

      row = Identity.get_team("research")
      assert row.group_id == group.id
      assert DateTime.compare(row.enabled_at, ~U[2020-01-01 00:00:00.000000Z]) == :gt
      assert row.enabled_by == context.root.subject
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

      # Members are shown and the list is read-only: it comes from the identity provider.
      # Each carries their own spend ceiling, which is Troupe's and not the provider's.
      assert "member@example.test" in Enum.map(team.members, & &1.subject)
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

  describe "a profile as it is written" do
    # The pods follow `spec.configBundleChannel`; bundles, adoption and the servers a
    # profile carries follow the row. A channel set in the editor reached the first only.
    test "its bundle channel is the one in its spec, for the row as for the pods", context do
      beta = %{
        "name" => "beta-dev",
        "image" => "ghcr.io/troupe/worker:1",
        "spec" => %{"configBundleChannel" => "beta"}
      }

      assert {:ok, %{profile: summary}} = Admin.profile_put(context.root, beta)
      assert summary.channel == "beta"
      assert Fleet.get_profile("beta-dev").config_bundle_channel == "beta"
      assert "beta-dev" in Fleet.profiles_on_channel("beta")

      # A spec that names none follows `stable`, which is what the pods are given then.
      assert {:ok, %{profile: summary, changes: changes}} =
               Admin.profile_put(context.root, Map.put(beta, "spec", %{}))

      assert summary.channel == "stable"
      assert changes["config_bundle_channel"] == %{"from" => "beta", "to" => "stable"}

      # And the row's own field is not a second place to say it, which the pods would not
      # hear about.
      assert {:error, error} =
               Admin.profile_put(context.root, Map.put(beta, "config_bundle_channel", "beta"))

      assert error.message == "invalid_params"
      assert error.data.reason =~ "spec.configBundleChannel"
    end

    # Whether a repository's agents and skills may replace the bundle's on the profile's pods
    # (Decision 826): kept in the spec, and refused as anything but true or false, since a
    # pod reads only `true` as on and a "true" saved as text would be on in nobody's eyes
    # but the admin's.
    test "repositoryOverridesBundle is kept when it is a boolean and refused otherwise",
         context do
      profile = %{"name" => "repo-dev", "image" => "ghcr.io/troupe/worker:1"}

      allowed = Map.put(profile, "spec", %{"repositoryOverridesBundle" => true})
      assert {:ok, _} = Admin.profile_put(context.root, allowed)
      assert Fleet.get_profile("repo-dev").spec["repositoryOverridesBundle"] == true

      for value <- ["true", 1, "yes"] do
        sent = Map.put(profile, "spec", %{"repositoryOverridesBundle" => value})
        assert {:error, error} = Admin.profile_put(context.root, sent)
        assert error.message == "invalid_params"
        assert error.data.reason =~ "repositoryOverridesBundle must be true or false"
      end

      assert Fleet.get_profile("repo-dev").spec["repositoryOverridesBundle"] == true
    end

    # Who the profile is at a server its bundle calls with client credentials (Decision
    # 747): the owner's to write, and nothing in it secret, so the plane keeps it as it keeps
    # the rest of the spec and says what is missing rather than refusing.
    test "its identities are kept, and what they lack is said", context do
      {:ok, _} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "mcp_servers" => [
              %{
                "name" => "jira",
                "url" => "https://mcp.jira.example/mcp",
                "credential_mode" => "client_credentials"
              }
            ]
          },
          announce: false
        )

      incomplete = %{
        "server" => "jira",
        "clientId" => "client-dev",
        "certificateThumbprint" => String.duplicate("A", 43)
      }

      dev = %{
        "name" => "identity-dev",
        "image" => "ghcr.io/troupe/worker:1",
        "spec" => %{"mcpIdentities" => [incomplete]}
      }

      assert {:ok, %{identity_problems: [problem]}} = Admin.profile_put(context.root, dev)
      assert problem =~ "mcp server jira: the identity has no transitKey"

      complete = Map.put(incomplete, "transitKey", "troupe-w-identity-dev.jira")

      assert {:ok, %{identity_problems: []}} =
               Admin.profile_put(context.root, put_in(dev, ["spec", "mcpIdentities"], [complete]))

      assert {:ok, %{spec: spec, identity_problems: []}} =
               Admin.profile_get(context.root, "identity-dev")

      assert spec["mcpIdentities"] == [complete]
    end

    # Its workers are machines somebody registers; a `WorkerProfile` would have the
    # operator run pods for it as well.
    test "one whose workers are machines is not written to the cluster", context do
      FakeWorkerProfiles.start(%{})

      image = "ghcr.io/troupe/worker:1"
      laptops = %{"name" => "laptops", "image" => image, "provisioner" => "ssh"}

      assert {:ok, %{provisioning: provisioning}} = Admin.profile_put(context.root, laptops)
      assert provisioning.state == :not_in_cluster
      refute_received {FakeWorkerProfiles, :applied, "laptops", _resource, _query}

      # A profile on Kubernetes still is, which is what makes the refutation mean something.
      assert {:ok, _} = Admin.profile_put(context.root, %{"name" => "pods", "image" => image})
      assert_received {FakeWorkerProfiles, :applied, "pods", _resource, _query}
    end

    test "its audit row says what an administrator changed", context do
      {:ok, _} =
        Admin.profile_put(context.root, %{
          "name" => "dev",
          "size_class" => "heavy",
          "max_sessions" => 6,
          "warm_workers" => 1,
          "provisioner" => "ssh"
        })

      [event | _] = Audit.list(kind: "profile")
      assert event.action == "profile.put"
      assert event.detail["size_class"] == %{"from" => "standard", "to" => "heavy"}
      assert event.detail["max_sessions"] == %{"from" => nil, "to" => 6}
      assert event.detail["warm_workers"] == %{"from" => 0, "to" => 1}
      assert event.detail["provisioner"] == %{"from" => "kubernetes", "to" => "ssh"}
    end
  end

  describe "a trigger as it is written" do
    setup context do
      {:ok, principal} =
        Admin.principal_create(context.lead, "engineering", %{
          "name" => "bot",
          "profiles" => ["dev"],
          "sponsor" => "lead@example.test"
        })

      definition = %{
        "team" => "engineering",
        "name" => "nightly",
        "principal" => principal.subject,
        "profile" => "dev",
        "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"}
      }

      %{definition: definition}
    end

    # A trigger on a profile the plane has not got fails at every firing, and nothing
    # said so when it was saved. The GitOps pass refused it already.
    test "names a profile the plane has", context do
      assert {:error, error} =
               Admin.trigger_put(context.lead, Map.put(context.definition, "profile", "nowhere"))

      assert error.message == "invalid_params"
      assert error.data.reason =~ "nowhere is not a profile this plane has"
      assert Triggers.get(context.engineering, "nightly") == nil

      assert {:ok, _} = Admin.trigger_put(context.lead, context.definition)

      # Switching it off names no profile and is not asked about one.
      assert {:ok, _} =
               Admin.trigger_put(context.lead, %{
                 "team" => "engineering",
                 "name" => "nightly",
                 "enabled" => false
               })
    end

    test "its audit row says where its outcome goes", context do
      {:ok, _} = Admin.trigger_put(context.lead, context.definition)

      {:ok, _} =
        Admin.trigger_put(context.lead, %{
          "team" => "engineering",
          "name" => "nightly",
          "notify_url" => "https://hooks.example.com/troupe"
        })

      [event | _] = Audit.list(kind: "trigger")
      assert event.action == "trigger.put"

      assert event.detail["notify_url"] == %{
               "from" => nil,
               "to" => "https://hooks.example.com/troupe"
             }
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
