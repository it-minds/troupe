defmodule Troupe.Plane.IdentityTest do
  @moduledoc """
  Who exists, what they belong to, and what that lets them use.

  Two of the stage's done items live here: that SCIM and a login's groups claim produce
  the same teams, and that a user sees exactly the profiles their teams are granted —
  and that a user in no enabled team sees nothing at all.
  """

  use Troupe.Plane.DataCase, async: true

  alias Troupe.Plane.Identity

  describe "users and groups" do
    test "a user is identified by subject, not by email" do
      {:ok, first} = Identity.upsert_user(%{subject: "idp|alice", email: "alice@example.test"})

      {:ok, second} =
        Identity.upsert_user(%{subject: "idp|alice", email: "alice.smith@example.test"})

      assert first.id == second.id
      assert second.email == "alice.smith@example.test"
    end

    test "upserting is idempotent, because SCIM and login both call it" do
      {:ok, group} = Identity.upsert_group(%{external_id: "g-1", display_name: "Platform"})
      {:ok, again} = Identity.upsert_group(%{external_id: "g-1", display_name: "Platform team"})

      assert group.id == again.id
      assert again.display_name == "Platform team"
    end

    test "membership is replaced, not merged" do
      user = person("idp|alice", ["g-1", "g-2"])
      assert Identity.teams_for(user) == []

      team_one = team_with_grant("g-1", "dev")
      _team_two = team_with_grant("g-2", "ux")

      assert Identity.teams_for(user) |> Enum.map(& &1.name) |> Enum.sort() == ["g-1", "g-2"]

      # A login carrying only g-1 means the user has left g-2. Merging would let access
      # outlive the identity provider's decision to remove it.
      {:ok, _} = Identity.set_memberships(user, ["g-1"])

      assert Identity.teams_for(user) |> Enum.map(& &1.id) == [team_one.id]
    end
  end

  describe "teams" do
    test "enabling a group makes it a team, and enabling it twice makes one" do
      {:ok, group} = Identity.upsert_group(%{external_id: "g-1", display_name: "Platform"})

      {:ok, team} = Identity.enable_team(group)
      {:ok, again} = Identity.enable_team(group)

      assert team.id == again.id
      assert team.name == "platform"
      assert team.enabled_at
    end

    test "a team's members are the group's members" do
      team = team_with_grant("g-1", "dev")
      alice = person("idp|alice", ["g-1"])
      bob = person("idp|bob", [])

      assert Identity.teams_for(alice) |> Enum.map(& &1.id) == [team.id]
      assert Identity.teams_for(bob) == []
    end

    test "retention defaults are the team's, and the spec's" do
      team = team_with_grant("g-1", "dev")

      assert team.idle_timeout_seconds == 1800
      assert team.cache_eviction_days == 7
      assert team.erase_after_days == 365
      assert team.pins_allowed
    end
  end

  describe "grants" do
    test "a user sees exactly the profiles their teams are granted" do
      team_with_grant("g-dev", "dev")
      team_with_grant("g-ux", "ux")
      team_with_grant("g-secret", "secret")

      alice = person("idp|alice", ["g-dev", "g-ux"])

      assert alice |> Identity.profiles_for() |> Enum.map(& &1.profile) |> Enum.sort() ==
               ["dev", "ux"]

      assert Identity.may_use?(alice, "dev")
      assert Identity.may_use?(alice, "ux")
      refute Identity.may_use?(alice, "secret")
    end

    test "a user in no enabled team sees nothing and cannot create" do
      team_with_grant("g-dev", "dev")

      # In a group, but the group has not been enabled as a team.
      bob = person("idp|bob", ["g-other"])

      assert Identity.profiles_for(bob) == []
      refute Identity.may_use?(bob, "dev")
    end

    test "revoking a grant takes the profile away" do
      team = team_with_grant("g-dev", "dev")
      alice = person("idp|alice", ["g-dev"])

      assert Identity.may_use?(alice, "dev")

      :ok = Identity.revoke(team, "dev")

      refute Identity.may_use?(alice, "dev")
    end

    test "the same profile granted to two teams is one entry per team" do
      team_with_grant("g-dev", "shared", volume_mode: "rw")
      team_with_grant("g-ux", "shared", volume_mode: "ro")

      alice = person("idp|alice", ["g-dev", "g-ux"])
      entries = Identity.profiles_for(alice)

      assert length(entries) == 2
      assert entries |> Enum.map(& &1.volume_mode) |> Enum.sort() == ["ro", "rw"]

      # And the projection the plane writes into the WorkerProfile has both.
      assert "shared" |> Identity.grants_for_profile() |> length() == 2
    end
  end
end
