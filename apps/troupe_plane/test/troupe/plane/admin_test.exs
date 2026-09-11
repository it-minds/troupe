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

    engineering = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 1_000_000)
    design = team_with_grant("design", "ux", name: "design", budget_micros: 500_000)
    {:ok, platform_group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _platform_team} = Identity.enable_team(platform_group, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    member = person("member@example.test", ["engineering"])

    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 2, sessions_per_pod: 4, image: "ghcr.io/troupe/worker:1"})
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
      assert {:ok, published} = Admin.bundle_publish(context.root, "stable", %{"agents" => ["build"]})
      assert published.version == 1

      assert {:ok, [listed]} = Admin.bundles_list(context.lead, "stable")
      assert listed.hash == published.hash

      assert {:error, error} = Admin.bundle_publish(context.lead, "stable", %{})
      assert error.data.required_role == "platform_admin"

      assert {:ok, retired} = Admin.bundle_retire(context.root, "stable", 1)
      assert retired.retired_at
      assert Bundles.current("stable") == nil
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
