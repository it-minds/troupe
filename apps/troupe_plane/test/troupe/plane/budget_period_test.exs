defmodule Troupe.Plane.BudgetPeriodTest do
  @moduledoc """
  A `monthly` ceiling turns over at midnight UTC on the 1st; a `never` one does not. A
  person's cap and the platform's turn over then too, whatever their teams' periods.

  It used to be `never` whatever the team said: the ledger summed a team's spend over all
  time and nothing read the period, so a team that reached its ceiling stayed refused
  until somebody raised it — while Overview told them the period would turn over. A
  person's cap and the platform's stayed that way longer (#132), while the console called
  them "a hundred a month".

  The clock is set either side of the boundary rather than waited for. The charges are
  dated by the calls they record, as a pod's are, so what crosses midnight is the clock
  and not the ledger.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}

  alias Troupe.Plane.{
    FakePod,
    Harness,
    Identity,
    Ledger,
    PersonBudget,
    PlatformBudget,
    Settings,
    Singleton,
    TeamBudget
  }

  alias Troupe.Plane.Ledger.Cache

  @moduletag timeout: 60_000

  @million 1_000_000

  # The last second of September and the first of October, in UTC.
  @september ~U[2026-09-30 23:59:59.000000Z]
  @october ~U[2026-10-01 00:00:00.000000Z]

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Singleton)
    start_supervised!(Cache)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    on_exit(fn -> Application.delete_env(:troupe_plane, :budget_clock) end)

    team =
      team_with_grant("engineering", "dev", name: "engineering", budget_micros: 10 * @million)

    ada = person("ada@example.test", ["engineering"])
    _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 12)

    %{team: team, ada: ada}
  end

  test "a monthly team at its ceiling gets a session again on the 1st", context do
    at(@september)
    spend_the_budget_in_september(context)

    assert {:error, error} = create(context.ada)
    assert error.message == "budget_exhausted"
    assert error.data.scope == :team

    at(@october)

    assert {:ok, _endpoint} = create(context.ada)
    assert_receive {:pushed, "session.activate", _}, 5_000
  end

  test "a team whose ceiling is never stays at it in the next month", context do
    {:ok, _} = Identity.update_team(context.team, %{budget_period: "never"})

    at(@september)
    spend_the_budget_in_september(context)
    assert {:error, %{message: "budget_exhausted"}} = create(context.ada)

    at(@october)

    assert {:error, error} = create(context.ada)
    assert error.message == "budget_exhausted"
    assert error.data.spent_micros == 10 * @million
  end

  test "what is remembered about a month is not the answer for the next", context do
    at(@september)
    spend_the_budget_in_september(context)

    # Asked, and remembered, in September — by the ledger's cache and by the team's actor.
    assert Ledger.spent_micros(context.team.id) == 10 * @million
    assert TeamBudget.inspect_state(context.team).spent_micros == 10 * @million

    # Nothing is written at midnight, so nothing throws either of them away. The first
    # read in October has to be a question about October.
    at(@october)

    assert Ledger.spent_micros(context.team.id) == 0
    assert TeamBudget.inspect_state(context.team).spent_micros == 0
    assert TeamBudget.inspect_state(context.team).remaining_micros == 10 * @million

    # And September's total is still September's.
    at(@september)
    assert Ledger.spent_micros(context.team.id) == 10 * @million
  end

  describe "a person's cap" do
    # In a team with room to spare that never turns over, so the only rung that can refuse
    # is the person's own, and whatever gives them a session in October is not the team.
    setup context do
      {:ok, team} =
        Identity.update_team(context.team, %{
          budget_period: "never",
          budget_micros: 100 * @million
        })

      {:ok, _} = Identity.set_budget(context.ada, 10 * @million)

      %{team: team}
    end

    test "turns over on the 1st, in a team that never does", context do
      at(@september)
      spend_the_budget_in_september(context)

      assert {:error, error} = create(context.ada)
      assert error.message == "budget_exhausted"
      assert error.data.scope == :person

      at(@october)

      assert {:ok, _endpoint} = create(context.ada)
      assert_receive {:pushed, "session.activate", _}, 5_000
    end

    test "is this month's spend, to the ledger and to the person's actor", context do
      at(@september)
      spend_the_budget_in_september(context)

      assert Ledger.spent_micros_for(context.ada.subject) == 10 * @million
      assert PersonBudget.inspect_state(context.ada.subject).spent_micros == 10 * @million

      at(@october)

      assert Ledger.spent_micros_for(context.ada.subject) == 0
      assert %{spent_micros: 0} = PersonBudget.inspect_state(context.ada.subject)
      assert PersonBudget.inspect_state(context.ada.subject).remaining_micros == 10 * @million

      # One charge, two periods: the team's ceiling never turns over and still counts it.
      assert Ledger.spent_micros(context.team) == 10 * @million
    end
  end

  describe "the platform's ceiling" do
    setup context do
      {:ok, team} =
        Identity.update_team(context.team, %{
          budget_period: "never",
          budget_micros: 100 * @million
        })

      {:ok, _} = Settings.put("platform_budget_micros", 10 * @million, "root@example.test")
      on_exit(&Settings.invalidate/0)

      %{team: team}
    end

    test "turns over on the 1st", context do
      at(@september)
      spend_the_budget_in_september(context)

      assert {:error, error} = create(context.ada)
      assert error.message == "budget_exhausted"
      assert error.data.scope == :platform
      assert PlatformBudget.inspect_state().spent_micros == 10 * @million

      at(@october)

      assert %{spent_micros: 0} = PlatformBudget.inspect_state()
      assert {:ok, _endpoint} = create(context.ada)
      assert_receive {:pushed, "session.activate", _}, 5_000
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp at(now), do: Application.put_env(:troupe_plane, :budget_clock, fn -> now end)

  # All of it, through the team's actor as a pod's report would arrive, dated in the
  # middle of September.
  defp spend_the_budget_in_september(context) do
    {:ok, _} =
      TeamBudget.record(context.team, %{
        session_id: "september",
        owner_subject: context.ada.subject,
        model: "fake-model",
        cost_micros: 10 * @million,
        gateway_request_id: "september-1",
        occurred_at: ~U[2026-09-12 09:00:00.000000Z]
      })
  end

  defp create(user) do
    Harness.call(
      "session.create",
      %{"profile" => "dev", "team" => "engineering", "prompt" => "hello"},
      %{user: user, platform_admin?: false}
    )
  end
end
