defmodule Troupe.Plane.ProfileBudgetTest do
  @moduledoc """
  A profile's own monthly ceiling on what its sessions spend (#655 slice 3), beside the
  person's, the team's and the platform's, and a child's that can only be lower.

  The month is the calendar month in UTC, as a person's and the platform's are
  (`BudgetPeriodTest` holds the turnover for all of them).
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{
    Admin,
    Budget,
    FakePod,
    Fleet,
    Harness,
    Identity,
    Ledger,
    ProfileBudget,
    Sessions,
    TeamBudget
  }

  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 60_000

  @million 1_000_000
  @image "ghcr.io/troupe/worker:1"

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(group, %{name: "platform"})
    root = person("root@example.test", ["platform"])

    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    team =
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 100 * @million)

    ada = person("ada@example.test", ["engineering"])

    %{actor: Admin.actor_for(root), team: team, ada: ada, port: Listener.port()}
  end

  describe "a profile's ceiling" do
    test "is a rung of the ladder, and refuses naming the profile", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => @image,
          "budget_micros" => 5 * @million
        })

      assert [profile, team, _platform] = Budget.ceilings(context.team, nil, "dev")
      assert profile.scope == :profile
      assert profile.profile == "dev"
      assert profile.budget_micros == 5 * @million
      assert profile.budget_period == "monthly"
      assert team.scope == :team

      assert {:ok, _} =
               Budget.reserve(context.team, "s-1", context.ada.subject, 3 * @million, "dev")

      # Three held of five: a second slice of three does not fit, and the refusal is the
      # profile's, though the team has ninety-seven left.
      assert {:error, {:over_budget, :profile, summary}} =
               Budget.reserve(context.team, "s-2", context.ada.subject, 3 * @million, "dev")

      assert summary.profile == "dev"
      assert summary.reserved_micros == 3 * @million

      # The rungs that agreed before it are not left holding the slice.
      assert %{reserved_micros: 3_000_000} = TeamBudget.inspect_state(context.team)

      # Released at every rung, the profile's included.
      :ok = Budget.release(context.team, "s-1", context.ada.subject, "dev")
      assert %{reserved_micros: 0} = ProfileBudget.inspect_state("dev")
    end

    test "counts what the profile's sessions spent this month", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => @image,
          "budget_micros" => 5 * @million
        })

      session = session!(context, "dev")

      {:ok, _} =
        TeamBudget.record(context.team, %{
          session_id: session.id,
          owner_subject: context.ada.subject,
          model: "m",
          cost_micros: 4 * @million,
          gateway_request_id: "r-1"
        })

      assert Ledger.profile_spent_micros("dev") == 4 * @million

      assert %{spent_micros: 4_000_000, remaining_micros: 1_000_000} =
               ProfileBudget.inspect_state("dev")
    end

    test "absent or zero is no ceiling, and the rung is left out", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => @image,
          "budget_micros" => 0
        })

      assert Fleet.get_profile("dev").budget_micros == nil
      assert [_team, _platform] = Budget.ceilings(context.team, nil, "dev")
      assert {:ok, _} = Budget.reserve(context.team, "s-1", nil, 50 * @million, "dev")
    end

    test "a session it refuses is told it is the profile's", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => @image,
          "budget_micros" => 2 * @million
        })

      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0", capacity: 8)

      assert {:ok, _} =
               Budget.reserve(context.team, "s-already", context.ada.subject, 2 * @million, "dev")

      assert {:error, error} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "team" => "engineering", "prompt" => "hello"},
                 %{user: context.ada, platform_admin?: false}
               )

      assert error.message == "budget_exhausted"
      assert error.data.scope == :profile
      assert error.data.profile == "dev"
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "admin.budget.explain names it when it binds", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "dev",
          "image" => @image,
          "budget_micros" => 2 * @million
        })

      assert {:ok, ceilings} =
               Admin.budget_explain(context.actor, context.ada.subject, "engineering", "dev")

      # After the person's, and before the team's, as the ladder asks them. The person has
      # no cap, so the profile's is the one that binds.
      assert Enum.map(ceilings, & &1.scope) == [:person, :profile, :team, :platform]
      profile = Enum.find(ceilings, &(&1.scope == :profile))
      assert profile.profile == "dev"
      assert profile.budget_micros == 2 * @million
      assert profile.set_by == "dev"

      bound =
        ceilings
        |> Enum.reject(&(&1.remaining_micros == :unlimited))
        |> Enum.min_by(& &1.remaining_micros)

      assert bound.scope == :profile

      assert {:ok, %{budget: budget}} = Admin.profile_get(context.actor, "dev")
      assert budget.budget_micros == 2 * @million
      assert budget.budget_period == "monthly"
    end
  end

  describe "a child's ceiling" do
    setup context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "standard",
          "image" => @image,
          "budget_micros" => 50 * @million
        })

      :ok
    end

    test "is its parent's where it sets none, and its own where it is lower", context do
      {:ok, _} =
        Admin.profile_put(context.actor, %{"name" => "data-team", "extends" => "standard"})

      assert Fleet.get_profile("data-team").budget_micros == 50 * @million

      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "data-team",
          "extends" => "standard",
          "budget_micros" => 20 * @million
        })

      assert Fleet.get_profile("data-team").budget_micros == 20 * @million

      assert {:ok, ceilings} =
               Admin.budget_explain(context.actor, context.ada.subject, nil, "data-team")

      assert Enum.find(ceilings, &(&1.scope == :profile)).set_by == "data-team"

      # The parent's own ceiling moving below the child's wins: lower wins.
      {:ok, _} =
        Admin.profile_put(context.actor, %{
          "name" => "standard",
          "image" => @image,
          "budget_micros" => 10 * @million
        })

      assert Fleet.get_profile("data-team").budget_micros == 10 * @million
      assert {:ok, %{effective: effective}} = Admin.profile_get(context.actor, "data-team", true)
      assert Enum.find(effective.fields, &(&1.path == "budget_micros")).from == "standard"
    end

    test "higher than its parent's is refused with a sentence", context do
      assert {:error, error} =
               Admin.profile_put(context.actor, %{
                 "name" => "data-team",
                 "extends" => "standard",
                 "budget_micros" => 80 * @million
               })

      assert error.message == "invalid_params"
      assert error.data.reason =~ "can only lower"
      assert error.data.reason =~ "standard"
      refute Fleet.get_profile("data-team")
    end
  end

  defp session!(context, profile) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: profile,
        state: "dormant",
        epoch: 1
      })

    session
  end
end
