defmodule Troupe.Plane.TeamDisableTest do
  @moduledoc """
  A team can be removed, and the removal says first what it takes and what it leaves.

  `Identity.disable_team/1` existed and nothing in `Admin` called it, so the console had
  *enable a team* and no way back — an administrator who enabled the wrong group kept it
  for ever, or asked for a database write. The way back is destructive in a way "delete
  team" does not sound: the team is what its grants, administrators, principals, triggers
  and group links hang off. So the preview lists them, the deed matches the preview, and
  the one thing that survives — the sessions — is named as kept rather than left out.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Audit, Identity, Principals, Sessions, Triggers}
  alias Troupe.Protocol.Error

  setup do
    start_supervised!(Troupe.Plane.Singleton)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["backend"])

    team = team_with_grant("backend", "dev", name: "engineering")
    {:ok, _} = Identity.grant(team, "review")
    {:ok, _} = Identity.add_team_admin(team, lead.subject, root.subject)

    {:ok, _} = Identity.upsert_group(%{external_id: "org-platform", display_name: "Platform"})
    _bea = person("bea@example.test", ["org-platform"])

    actor = Admin.actor_for(root)
    {:ok, _} = Admin.team_link(actor, "engineering", "org-platform")

    {:ok, principal, _secret} =
      principal!(team, %{name: "bot", profiles: ["dev"], sponsor: lead.subject}, root.subject)

    {:ok, _trigger} =
      Triggers.put(
        team,
        %{
          "name" => "nightly-deps",
          "principal" => principal.subject,
          "profile" => "dev",
          "source" => %{"kind" => "schedule", "cron" => "0 3 * * 1-5"},
          "prompt_template" => "Update every dependency with a patch release available."
        },
        root.subject
      )

    {:ok, session} =
      Sessions.create(%{
        id: "s-1",
        owner_id: lead.id,
        owner_subject: lead.subject,
        team_id: team.id,
        profile: "dev",
        kind: "team",
        visibility: "team",
        state: "active",
        epoch: 1
      })

    %{
      root: actor,
      lead: Admin.actor_for(lead),
      team: team,
      principal: principal,
      session: session
    }
  end

  describe "the preview" do
    test "counts what goes and names what stays", context do
      assert {:ok, effect} = Admin.team_disable_preview(context.root, "engineering")

      assert effect.team == "engineering"
      assert Enum.sort(effect.groups) == ["backend", "org-platform"]
      assert effect.members == 2
      assert Enum.sort(effect.grants) == ["dev", "review"]
      assert effect.admins == ["lead@example.test"]
      assert effect.principals == [context.principal.subject]
      assert effect.triggers == ["nightly-deps"]
      assert effect.sessions_kept == 1
      # What the typed confirmation has to match, carried in the answer.
      assert effect.confirm == "engineering"
    end

    test "is a platform administrator's, not a team admin's", context do
      assert {:error, %Error{message: "forbidden"}} =
               Admin.team_disable_preview(context.lead, "engineering")

      assert {:error, %Error{message: "forbidden"}} =
               Admin.team_disable(context.lead, "engineering")

      assert Identity.get_team("engineering")
    end

    test "a team that does not exist is not found", context do
      assert {:error, %Error{message: "not_found"}} =
               Admin.team_disable_preview(context.root, "nobody")
    end
  end

  describe "the deed" do
    test "matches the preview, and the sessions survive with no team", context do
      assert {:ok, preview} = Admin.team_disable_preview(context.root, "engineering")
      assert {:ok, ^preview} = Admin.team_disable(context.root, "engineering")

      refute Identity.get_team("engineering")

      # Gone with the row: what hung off the team. The triggers go first, because a
      # principal cannot be removed while a trigger revision names it.
      refute Principals.get(context.principal.subject)
      assert Triggers.list(context.team) == []
      assert Identity.grants_for_team(context.team) == []
      assert Identity.links_of(context.team) == []

      # Kept: the people, the groups, and the session — with no team, and read-only,
      # because the grant that allowed it is gone.
      assert Identity.get_user("lead@example.test")
      assert Identity.get_group("backend")
      assert Identity.get_group("org-platform")

      session = Sessions.get(context.session.id)
      assert is_nil(session.team_id)
      assert session.state == "read_only"
    end

    test "is in the audit trail with the counts", context do
      {:ok, _} = Admin.team_disable(context.root, "engineering")

      assert [event] = Enum.filter(Audit.list(), &(&1.action == "team.disable"))
      assert event.actor == "root@example.test"
      assert event.subject_id == "engineering"
      assert event.detail["members"] == 2
      assert event.detail["triggers"] == ["nightly-deps"]
      assert event.detail["sessions_kept"] == 1
    end
  end
end
