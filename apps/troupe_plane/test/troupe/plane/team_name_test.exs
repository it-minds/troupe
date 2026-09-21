defmodule Troupe.Plane.TeamNameTest do
  @moduledoc """
  A team's name is an identifier, and the plane refuses one that is not.

  Found on the live plane: a team named `Admin Buddies` was accepted, and every session
  create on it then failed at the pod — the worker put the name into an OpenBao URL and
  the space in it made the request invalid before it was sent. That worker predated the
  per-segment encoding, but encoding is not the fix: the name is also the Kubernetes
  claim `team-<name>`, which admits lowercase letters, digits and dashes and nothing else.
  The only place this can be stopped is where a team is made.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Identity, Repo}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Protocol.Error

  setup do
    # A team's detail reads its spend through the budget ladder, whose actors live under
    # this. Without it the first enable waits on a process that is never started.
    start_supervised!(Troupe.Plane.Singleton)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    {:ok, _} = Identity.upsert_group(%{external_id: "grp-buddies", display_name: "Admin Buddies"})
    %{root: Admin.actor_for(person("root@example.test", ["platform"]))}
  end

  test "a name with a space is refused, in words, and no team is made", context do
    assert {:error, %Error{message: "invalid_params", data: %{reason: reason, fields: [:name]}}} =
             Admin.team_enable(context.root, "grp-buddies", %{"name" => "Admin Buddies"})

    assert reason =~ "name: lowercase letters, digits and dashes"
    assert reason =~ "Kubernetes name and an OpenBao path"
    refute Identity.get_team("Admin Buddies")
  end

  test "so are the other shapes that cannot be part of a Kubernetes name", context do
    for bad <- ["Admin", "admin_buddies", "-admin", "admin-", "admin.buddies", String.duplicate("a", 59)] do
      assert {:error, %Error{message: "invalid_params"}} =
               Admin.team_enable(context.root, "grp-buddies", %{"name" => bad}),
             "#{inspect(bad)} should have been refused"
    end
  end

  test "a slug is accepted, up to the length that still fits team-<name>", context do
    assert {:ok, %{name: "admin-buddies"}} =
             Admin.team_enable(context.root, "grp-buddies", %{"name" => "admin-buddies"})

    longest = String.duplicate("a", 58)
    assert {:ok, %{name: ^longest}} = Admin.team_enable(context.root, "grp-buddies", %{"name" => longest})
    assert String.length("team-" <> longest) == 63
  end

  test "left blank, the group's display name becomes a name inside the rule", context do
    assert {:ok, %{name: "admin-buddies"}} = Admin.team_enable(context.root, "grp-buddies", %{})

    {:ok, long} =
      Identity.upsert_group(%{external_id: "grp-long", display_name: String.duplicate("Platform Team ", 8)})

    assert {:ok, team} = Identity.enable_team_if_new(long)
    assert String.length(team.name) <= 58
    assert team.name =~ ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/
  end

  test "an existing team with a bad name can still be edited, so it can be worked around", context do
    # Written past the changeset, the way a team made before this rule is in the database.
    group = Identity.get_group("grp-buddies")

    {:ok, legacy} =
      %Team{}
      |> Ecto.Changeset.change(%{name: "Admin Buddies", group_id: group.id, enabled_at: DateTime.utc_now()})
      |> Repo.insert()

    # A budget change does not touch the name, so it is not refused over it: a plane
    # upgrading into this rule must not find its old teams frozen.
    assert {:ok, updated} = Identity.update_team(legacy, %{budget_micros: 1_000_000})
    assert updated.budget_micros == 1_000_000

    # And it can be removed, which is the way out for a team the rule would now refuse.
    assert {:ok, _} = Admin.team_disable(context.root, "Admin Buddies")
    refute Identity.get_team("Admin Buddies")
  end
end
