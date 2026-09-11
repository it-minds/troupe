defmodule Troupe.Plane.SCIMTest do
  @moduledoc """
  The two ways identity gets in, and the requirement that they agree.

  A done item: a SCIM push creates users and groups, enabling a group makes it a team,
  and with SCIM disabled the JIT groups claim yields the same teams. The point is that
  an installation can turn SCIM off without its teams changing shape underneath it.
  """

  use Troupe.Plane.DataCase, async: true

  alias Troupe.Plane.{Identity, Login, SCIM}

  @alice %{
    "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
    "externalId" => "idp|alice",
    "userName" => "alice@example.test",
    "name" => %{"givenName" => "Alice", "familyName" => "Ng"},
    "emails" => [
      %{"value" => "old@example.test", "primary" => false},
      %{"value" => "alice@example.test", "primary" => true}
    ],
    "active" => true
  }

  describe "a SCIM push" do
    test "creates a user, keyed on the subject a token will carry" do
      assert {:ok, user} = SCIM.put_user(@alice)

      assert user.subject == "idp|alice"
      assert user.email == "alice@example.test"
      assert user.display_name == "Alice Ng"
      assert user.active
    end

    test "falls back to userName when the provider sends no externalId" do
      assert {:ok, user} = SCIM.put_user(Map.delete(@alice, "externalId"))
      assert user.subject == "alice@example.test"
    end

    test "creates a group and its membership" do
      {:ok, alice} = SCIM.put_user(@alice)

      {:ok, group} =
        SCIM.put_group(%{
          "id" => "scim-group-1",
          "externalId" => "g-platform",
          "displayName" => "Platform",
          "members" => [%{"value" => alice.id}]
        })

      assert group.external_id == "g-platform"
      assert Identity.members_of(group) |> Enum.map(& &1.id) == [alice.id]
    end

    test "replaces membership rather than merging it" do
      {:ok, alice} = SCIM.put_user(@alice)
      {:ok, bob} = SCIM.put_user(%{@alice | "externalId" => "idp|bob", "userName" => "bob"})

      resource = %{
        "id" => "scim-group-1",
        "externalId" => "g-platform",
        "displayName" => "Platform",
        "members" => [%{"value" => alice.id}, %{"value" => bob.id}]
      }

      {:ok, group} = SCIM.put_group(resource)
      assert length(Identity.members_of(group)) == 2

      # Bob left. The push carries the whole list, so his absence is his removal.
      {:ok, group} = SCIM.put_group(%{resource | "members" => [%{"value" => alice.id}]})
      assert Identity.members_of(group) |> Enum.map(& &1.id) == [alice.id]
    end

    test "a deactivated user stays, because an audit trail outlives an account" do
      {:ok, alice} = SCIM.put_user(@alice)

      assert {:ok, deactivated} = SCIM.deactivate_user(alice.id)
      refute deactivated.active
      assert Identity.get_user("idp|alice")
    end

    test "renders resources the way SCIM expects to read them" do
      {:ok, alice} = SCIM.put_user(@alice)
      rendered = SCIM.render_user(alice)

      assert rendered["schemas"] == ["urn:ietf:params:scim:schemas:core:2.0:User"]
      assert rendered["id"] == alice.id
      assert rendered["userName"] == "idp|alice"
      assert [%{"value" => "alice@example.test", "primary" => true}] = rendered["emails"]
      assert rendered["meta"]["resourceType"] == "User"

      list = SCIM.render_list([rendered])
      assert list["totalResults"] == 1
      assert list["Resources"] == [rendered]
    end
  end

  describe "SCIM and a login agree" do
    test "the same person in the same groups gets the same teams either way" do
      # One installation with SCIM on.
      {:ok, alice} = SCIM.put_user(@alice)

      {:ok, platform} =
        SCIM.put_group(%{
          "id" => "s1",
          "externalId" => "g-platform",
          "displayName" => "Platform",
          "members" => [%{"value" => alice.id}]
        })

      {:ok, design} =
        SCIM.put_group(%{
          "id" => "s2",
          "externalId" => "g-design",
          "displayName" => "Design",
          "members" => [%{"value" => alice.id}]
        })

      {:ok, platform_team} = Identity.enable_team(platform)
      {:ok, design_team} = Identity.enable_team(design)
      {:ok, _} = Identity.grant(platform_team, "dev")
      {:ok, _} = Identity.grant(design_team, "ux")

      from_scim = alice |> Identity.teams_for() |> Enum.map(& &1.name) |> Enum.sort()
      profiles_from_scim = alice |> Identity.profiles_for() |> Enum.map(& &1.profile) |> Enum.sort()

      assert from_scim == ["design", "platform"]
      assert profiles_from_scim == ["dev", "ux"]

      # Now the same person arrives at login, with SCIM off. The teams are already
      # enabled; nothing about them changes.
      {:ok, same_alice, teams} =
        Login.from_claims(%{
          "sub" => "idp|alice",
          "email" => "alice@example.test",
          "name" => "Alice Ng",
          "groups" => ["g-platform", "g-design"]
        })

      assert same_alice.id == alice.id
      assert teams |> Enum.map(& &1.name) |> Enum.sort() == from_scim

      assert same_alice |> Identity.profiles_for() |> Enum.map(& &1.profile) |> Enum.sort() ==
               profiles_from_scim
    end

    test "a login creates groups it has never seen, so an admin can enable them" do
      {:ok, user, teams} =
        Login.from_claims(%{"sub" => "idp|bob", "groups" => ["g-new", "g-other"]})

      # Knowing a group exists is not access. There is no team yet, so nothing is
      # granted — but an admin can now enable one without asking the provider for a
      # list.
      assert teams == []
      assert Identity.get_group("g-new")

      {:ok, team} = Identity.enable_team(Identity.get_group("g-new"))
      {:ok, _} = Identity.grant(team, "dev")

      assert user |> Identity.profiles_for() |> Enum.map(& &1.profile) == ["dev"]
    end

    test "a groups claim that is a string rather than a list is read the same way" do
      {:ok, user, _} = Login.from_claims(%{"sub" => "idp|carol", "groups" => "g-a g-b"})

      assert user |> Identity.teams_for() == []
      assert Identity.get_group("g-a")
      assert Identity.get_group("g-b")
    end

    test "a login without a subject is refused" do
      assert {:error, :no_subject} = Login.from_claims(%{"email" => "nobody@example.test"})
    end

    test "leaving a group at login removes the team it gave" do
      team_with_grant("g-dev", "dev")

      {:ok, user, teams} = Login.from_claims(%{"sub" => "idp|dave", "groups" => ["g-dev"]})
      assert teams |> Enum.map(& &1.name) == ["g-dev"]

      {:ok, _user, teams} = Login.from_claims(%{"sub" => "idp|dave", "groups" => []})
      assert teams == []
      assert Identity.profiles_for(user) == []
    end
  end
end
