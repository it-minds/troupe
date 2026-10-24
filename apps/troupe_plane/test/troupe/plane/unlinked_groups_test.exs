defmodule Troupe.Plane.UnlinkedGroupsTest do
  @moduledoc """
  A group the provider has started sending is one the console can name (#765).

  A sign-in that carries a group the plane has never seen makes it, under the identifier
  the token carries, which for most providers is not the name anybody knows it by.
  `admin.groups.list` says of each whether a team draws on it and when it last arrived in
  a sign-in, so linking a new group is choosing it rather than guessing how it is spelled.
  Being listed grants nothing.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Identity, Login}

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}

  test "a group seen in a sign-in that no team links is listed so, with when it was seen" do
    _engineering = team_with_grant("eng", "dev", name: "engineering")
    before = DateTime.utc_now()

    {:ok, _ada, teams} =
      Login.from_claims(%{
        "sub" => "idp|ada",
        "email" => "ada@example.test",
        "groups" => ["eng", "b1df014a-managers"]
      })

    assert {:ok, groups} = Admin.groups_list(@root)
    by_id = Map.new(groups, &{&1.external_id, &1})

    managers = by_id["b1df014a-managers"]
    refute managers.linked
    assert DateTime.compare(managers.last_seen_at, before) != :lt

    assert by_id["eng"].linked
    assert DateTime.compare(by_id["eng"].last_seen_at, before) != :lt

    # And nothing reaches anybody through it: the person's teams are the linked one's.
    assert Enum.map(teams, & &1.name) == ["engineering"]
  end

  test "a group only SCIM pushed has not been seen in a sign-in" do
    {:ok, _} = Identity.upsert_group(%{external_id: "scim-only", display_name: "People Managers"})

    assert {:ok, groups} = Admin.groups_list(@root)
    pushed = Enum.find(groups, &(&1.external_id == "scim-only"))

    refute pushed.linked
    assert is_nil(pushed.last_seen_at)
  end

  test "linking a listed group makes it linked, and a later sign-in moves when it was seen" do
    {:ok, _ada, _} = Login.from_claims(%{"sub" => "idp|ada", "groups" => ["managers"]})
    first = Identity.get_group("managers").last_seen_at

    {:ok, _team} = Identity.enable_team(Identity.get_group("managers"), %{name: "managers"})
    {:ok, _ada, _} = Login.from_claims(%{"sub" => "idp|ada", "groups" => ["managers"]})

    assert {:ok, groups} = Admin.groups_list(@root)
    managers = Enum.find(groups, &(&1.external_id == "managers"))
    assert managers.linked
    assert DateTime.compare(managers.last_seen_at, first) == :gt
  end
end
