defmodule Troupe.Plane.PolicyLadderTest do
  @moduledoc """
  Five rungs, and the rule that a lower one may only narrow.

  Settings had two rungs: what the plane was deployed with, and what a platform admin
  stored over it. A team's own values sat *beside* them rather than under them, so a team
  admin could lengthen a retention the platform had shortened and nothing said so — the
  quiet kind of failure, where the policy is written down and is not in force.

  The claims are the two halves of a usable ladder. That the tighter rung wins whichever
  one wrote it, and that a team is refused rather than clamped when it tries to widen,
  with the ceiling quoted. And that the view names the losers as well as the winner,
  because "30 days" tells an administrator nothing about why their 365 is not in force.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Identity, Settings}
  alias Troupe.Plane.Settings.Ladder

  setup do
    on_exit(fn ->
      for key <- Map.keys(Ladder.laddered()), do: Settings.reset(key, "root@example.test")
      Application.delete_env(:troupe_plane, :default_erase_after_days)
      Application.delete_env(:troupe_plane, :pins_allowed)
      Application.delete_env(:troupe_plane, :members_may_control)
      Settings.invalidate()
    end)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    team = team_with_grant("engineering", "dev", name: "engineering")
    root = Admin.actor_for(person("root@example.test", ["platform"]))

    %{team: team, root: root}
  end

  describe "the tighter rung wins" do
    test "whichever one wrote it, and the team's own row is left alone", context do
      # The deployment says a year; the platform says thirty days; the team asks for
      # ninety. Thirty is what runs.
      Application.put_env(:troupe_plane, :default_erase_after_days, 365)
      {:ok, _} = Settings.put("default_erase_after_days", "30", context.root.subject)
      {:ok, team} = Identity.update_team(context.team, %{erase_after_days: 90})

      assert %{value: 30, decided_by: :platform} =
               Ladder.effective("default_erase_after_days", team)

      # And what anything acting on it reads.
      assert Ladder.resolve(team).erase_after_days == 30

      # The team's own row still says ninety. An administrator who widens the platform
      # again should find their setting where they left it, not rewritten to somebody
      # else's number behind their back.
      assert Identity.get_team("engineering").erase_after_days == 90

      {:ok, _} = Settings.put("default_erase_after_days", "180", context.root.subject)
      assert %{value: 90, decided_by: :team} = Ladder.effective("default_erase_after_days", team)
    end

    test "and a deny at any rung is a deny below it", context do
      # A permission narrows to `false`, and `false` at the deployment is `false` for
      # every team whatever their own row says.
      {:ok, team} = Identity.update_team(context.team, %{pins_allowed: true})
      assert Ladder.resolve(team).pins_allowed

      Application.put_env(:troupe_plane, :pins_allowed, false)

      assert %{value: false, decided_by: :deployment} = Ladder.effective("pins_allowed", team)
      refute Ladder.resolve(team).pins_allowed
    end

    test "and a rung with no opinion does not participate", context do
      # Nothing stored, nothing deployed: the fallback this release ships is the only
      # opinion, and the team's own value is tighter and wins.
      {:ok, team} = Identity.update_team(context.team, %{idle_timeout_seconds: 300})

      assert %{value: 300, decided_by: :team, opinions: opinions} =
               Ladder.effective("default_idle_timeout_seconds", team)

      refute Enum.any?(opinions, &(&1.rung == :platform))
    end
  end

  describe "a team that tries to widen" do
    test "is refused, and the refusal quotes the ceiling and who set it", context do
      {:ok, _} = Settings.put("default_erase_after_days", "30", context.root.subject)

      assert {:error, error} =
               Admin.team_update(context.root, "engineering", %{"erase_after_days" => 90})

      assert error.message == "forbidden"
      assert error.data.field == "erase_after_days"
      assert error.data.asked == 90
      assert error.data.ceiling == 30
      assert error.data.decided_by == :platform

      # Refused, not clamped. A form that accepted ninety over a system running thirty
      # would be a system that knew better and said nothing.
      assert Identity.get_team("engineering").erase_after_days == 365
    end

    test "is refused for a permission the platform has turned off", context do
      {:ok, _} = Settings.put("pins_allowed", "false", context.root.subject)

      assert {:error, error} =
               Admin.team_update(context.root, "engineering", %{"pins_allowed" => true})

      assert error.data.field == "pins_allowed"
      assert error.data.ceiling == false
    end

    test "may still narrow, which is the whole point of having its own rung", context do
      {:ok, _} = Settings.put("default_erase_after_days", "90", context.root.subject)

      assert {:ok, _} = Admin.team_update(context.root, "engineering", %{"erase_after_days" => 30})
      assert Identity.get_team("engineering").erase_after_days == 30
    end
  end

  describe "the effective-value view" do
    test "names the winner and both losers", context do
      Application.put_env(:troupe_plane, :default_erase_after_days, 365)
      {:ok, _} = Settings.put("default_erase_after_days", "30", context.root.subject)
      {:ok, _} = Identity.update_team(context.team, %{erase_after_days: 60})

      assert {:ok, view} =
               Admin.setting_effective(context.root, "default_erase_after_days", "engineering")

      assert view.value == 30
      assert view.decided_by == :platform

      # The losers are in the answer, not only the winner. An administrator looking at
      # thirty where they set three hundred and sixty-five needs to know *who* said
      # thirty, and a view that showed only the winner leaves them guessing between three
      # rungs.
      assert Enum.sort_by(view.opinions, & &1.rung) == [
               %{rung: :deployment, value: 365},
               %{rung: :platform, value: 30},
               %{rung: :team, value: 60}
             ]
    end

    test "answers for the rungs above every team when no team is named", context do
      {:ok, _} = Settings.put("default_erase_after_days", "30", context.root.subject)

      assert {:ok, view} = Admin.setting_effective(context.root, "default_erase_after_days", nil)
      assert view.value == 30
      refute Enum.any?(view.opinions, &(&1.rung == :team))
    end

    test "refuses a setting no ladder decides, and says which ones it does", context do
      assert {:error, error} = Admin.setting_effective(context.root, "issuer", nil)
      assert error.message == "not_found"
      assert "default_erase_after_days" in error.data.laddered
    end
  end
end
