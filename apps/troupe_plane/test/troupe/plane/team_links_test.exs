defmodule Troupe.Plane.TeamLinksTest do
  @moduledoc """
  A team links to groups instead of being one.

  "A team is an identity-provider group somebody enabled" meant one group, one team, for
  ever, and the team had no identity of its own. The rigidity is what made "assign users
  to a profile" look necessary: if the only team you can have is whatever group your
  provider happens to hold, the shape of your access control is somebody else's org chart.

  The invariant is what to watch. "Membership always comes from the provider and is never
  edited in Troupe" said *derived, not typed* — and it is still derived, from a union of
  groups instead of from one. Nobody adds a person to a team here; they add a group.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Identity, Sessions}
  alias Troupe.Plane.Identity.TeamGroupLink

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    %{root: Admin.actor_for(person("root@example.test", ["platform"]))}
  end

  describe "two groups, one team" do
    test "a member of either gets the team's grants", context do
      team = team_with_grant("backend", "dev", name: "engineering")
      {:ok, platform} = Identity.upsert_group(%{external_id: "itm-platform", display_name: "Platform"})
      {:ok, _} = Admin.team_link(context.root, "engineering", "itm-platform")

      ada = person("ada@example.test", ["backend"])
      bea = person("bea@example.test", ["itm-platform"])
      cyd = person("cyd@example.test", ["backend", "itm-platform"])

      # The union. Everybody in either group is in the team, and the one in both is in it
      # once — without `distinct` they are in it twice and a listing shows their budget as
      # two budgets.
      members = team |> Identity.members_of_team() |> Enum.map(& &1.subject)
      assert Enum.sort(members) == Enum.sort([ada.subject, bea.subject, cyd.subject])

      assert Identity.teams_for(cyd) |> Enum.map(& &1.name) == ["engineering"]

      # And the grant reaches them all, which is the thing a team is for.
      for user <- [ada, bea, cyd] do
        assert Identity.profiles_for(user) |> Enum.map(& &1.profile) == ["dev"]
      end

      assert platform.external_id == "itm-platform"
    end

    test "unlinking removes only the people who had no other route", context do
      team = team_with_grant("backend", "dev", name: "engineering")
      {:ok, _} = Identity.upsert_group(%{external_id: "itm-platform", display_name: "Platform"})
      {:ok, _} = Admin.team_link(context.root, "engineering", "itm-platform")

      _ada = person("ada@example.test", ["backend"])
      bea = person("bea@example.test", ["itm-platform"])
      cyd = person("cyd@example.test", ["backend", "itm-platform"])

      # The count first, and it has to be the count. Somebody unlinking a group is usually
      # right about which group and often wrong about how many people are only in the team
      # through it.
      assert {:ok, effect} =
               Admin.team_unlink_preview(context.root, "engineering", "itm-platform")

      assert effect.in_group == 2
      assert effect.keep_access == 1
      assert effect.lose_access == 1
      assert effect.losing == [bea.subject]

      assert {:ok, ^effect} = Admin.team_unlink(context.root, "engineering", "itm-platform")

      # And what actually happened matches what was promised.
      members = team |> Identity.members_of_team() |> Enum.map(& &1.subject)
      refute bea.subject in members
      assert cyd.subject in members
      assert Identity.teams_for(bea) == []
    end

    test "the count names the sessions those people can open, and they do not move",
         context do
      team = team_with_grant("backend", "dev", name: "engineering")
      {:ok, _} = Identity.upsert_group(%{external_id: "itm-platform", display_name: "Platform"})
      {:ok, _} = Admin.team_link(context.root, "engineering", "itm-platform")

      bea = person("bea@example.test", ["itm-platform"])
      cyd = person("cyd@example.test", ["backend"])

      # Owned by somebody who stays, visible to the team. What bea loses is the team road
      # to it; a person's *own* session is theirs whatever team they are in, which is a
      # different question and not this one.
      {:ok, session} =
        Sessions.create(%{
          id: "s-1",
          owner_id: cyd.id,
          owner_subject: cyd.subject,
          team_id: team.id,
          profile: "dev",
          kind: "team",
          visibility: "team",
          state: "active",
          epoch: 1
        })

      assert {:ok, effect} =
               Admin.team_unlink_preview(context.root, "engineering", "itm-platform")

      assert effect.sessions_they_can_open == 1

      {:ok, _} = Admin.team_unlink(context.root, "engineering", "itm-platform")

      # The session stays with the team. Unlinking changes who may open it, not what it
      # belongs to — which is the thing people assume the other way round.
      assert Sessions.get(session.id).team_id == team.id
      assert is_nil(Sessions.role_for(bea, Sessions.get(session.id)))
    end
  end

  describe "one group, two teams" do
    test "puts a person in both, with their own budgets and retention", context do
      delivery = team_with_grant("itm-consultants", "dev", name: "delivery", budget_micros: 100)
      {:ok, group} = Identity.upsert_group(%{external_id: "itm-consultants"})

      {:ok, timesheets} =
        Identity.enable_team(group, %{"name" => "timesheets", "budget_micros" => 500})

      {:ok, _} = Identity.grant(timesheets, "dev", %{})
      ada = person("ada@example.test", ["itm-consultants"])

      assert Identity.teams_for(ada) |> Enum.map(& &1.name) |> Enum.sort() ==
               ["delivery", "timesheets"]

      # Independent. Two teams over one group are two Troupe objects, and everything a
      # team owns is the team's.
      assert delivery.budget_micros == 100
      assert timesheets.budget_micros == 500
      refute delivery.id == timesheets.id
    end
  end

  describe "the migration" do
    test "makes every existing team one link with the same members", context do
      # `team_with_grant` goes through `enable_team`, which is the path every team before
      # this took. What must be true is that its membership is unchanged.
      team = team_with_grant("backend", "dev", name: "engineering")
      ada = person("ada@example.test", ["backend"])

      assert [link] = Identity.links_of(team)
      assert link.group.external_id == "backend"
      assert link.team_id == team.id

      assert team |> Identity.members_of_team() |> Enum.map(& &1.subject) == [ada.subject]
      assert Identity.teams_for(ada) |> Enum.map(& &1.name) == ["engineering"]

      assert {:ok, [listed]} = Admin.teams_list(context.root)
      assert Enum.map(listed.groups, & &1.external_id) == ["backend"]
    end

    test "linking a group twice is one link, not a person counted twice", context do
      team = team_with_grant("backend", "dev", name: "engineering")
      ada = person("ada@example.test", ["backend"])

      {:ok, _} = Admin.team_link(context.root, "engineering", "backend")
      {:ok, _} = Admin.team_link(context.root, "engineering", "backend")

      assert Repo.aggregate(TeamGroupLink, :count) == 1
      assert team |> Identity.members_of_team() |> Enum.map(& &1.subject) == [ada.subject]
      assert Identity.teams_for(ada) |> length() == 1
    end
  end

  describe "membership" do
    test "still cannot be typed anywhere in Troupe", _context do
      # The invariant, asserted rather than asserted *about*. Two places to grant access
      # is one place too many to revoke it, and the change from one group to a union of
      # groups is a change to what membership is derived from and not to whether it is.
      refute function_exported?(Identity, :add_member, 2)
      refute function_exported?(Identity, :add_team_member, 2)
      refute function_exported?(Identity, :set_team_members, 2)
      refute function_exported?(Admin, :team_member_add, 3)
      refute function_exported?(Admin, :team_members_set, 3)

      # What a team *can* be told is which groups count, and that is all.
      assert function_exported?(Admin, :team_link, 3)
      assert function_exported?(Admin, :team_unlink, 3)
    end
  end

  describe "a team with no links" do
    test "has no members, and is valid rather than broken", context do
      team = team_with_grant("backend", "dev", name: "engineering")
      _ada = person("ada@example.test", ["backend"])

      {:ok, _} = Admin.team_unlink(context.root, "engineering", "backend")

      assert Identity.members_of_team(team) == []
      assert Identity.links_of(team) == []

      # Still a team: its grants, budget and retention are its own and are waiting for
      # somebody to decide which groups belong in it.
      assert {:ok, [listed]} = Admin.teams_list(context.root)
      assert listed.name == "engineering"
      assert listed.groups == []
    end
  end
end
