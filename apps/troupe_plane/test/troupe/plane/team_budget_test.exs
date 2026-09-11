defmodule Troupe.Plane.TeamBudgetTest do
  @moduledoc """
  Whether a team has money left, decided in one place.

  The distinction that matters: a *reservation* is what a running session has promised
  to spend, and a *usage record* is what a model call actually cost. Reservations keep
  the plane from promising the same money twice; usage records are what the gateway
  reconciliation compares against.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Ledger, Singleton, TeamBudget}

  setup do
    start_supervised!(Singleton)
    :ok
  end

  defp team(budget_micros) do
    team_with_grant("g-#{System.unique_integer([:positive])}", "dev", budget_micros: budget_micros)
  end

  test "a reservation that fits is granted, and one that does not is refused" do
    team = team(1_000)

    assert {:ok, state} = TeamBudget.reserve(team, "s-1", 600)
    assert state.reserved_micros == 600
    assert state.remaining_micros == 400

    assert {:error, {:over_budget, state}} = TeamBudget.reserve(team, "s-2", 600)
    assert state.remaining_micros == 400
  end

  test "reserving twice for one session is a retry, not a second slice" do
    team = team(1_000)

    assert {:ok, _} = TeamBudget.reserve(team, "s-1", 600)
    assert {:ok, state} = TeamBudget.reserve(team, "s-1", 600)

    assert state.reserved_micros == 600
  end

  test "releasing gives the money back" do
    team = team(1_000)

    {:ok, _} = TeamBudget.reserve(team, "s-1", 900)
    assert {:error, _} = TeamBudget.reserve(team, "s-2", 900)

    :ok = TeamBudget.release(team, "s-1")

    assert {:ok, state} = TeamBudget.reserve(team, "s-2", 900)
    assert state.reserved_micros == 900
  end

  test "a budget of zero means no limit, not no money" do
    team = team(0)

    assert {:ok, state} = TeamBudget.reserve(team, "s-1", 10_000_000)
    assert state.remaining_micros == :unlimited
  end

  test "what a call cost is recorded once, however many times it is reported" do
    team = team(0)

    attrs = %{
      session_id: "s-1",
      owner_subject: "idp|alice",
      model: "claude-sonnet-5",
      input_tokens: 100,
      output_tokens: 50,
      cost_micros: 250,
      gateway_request_id: "req-abc"
    }

    assert {:ok, record} = TeamBudget.record(team, attrs)
    assert record.cost_micros == 250

    # A worker that lost the plane replays its reports when it comes back. Counting the
    # same request twice would make a team look over budget for having survived an
    # outage.
    assert {:ok, :already_recorded} = TeamBudget.record(team, attrs)
    assert Ledger.spent_micros(team.id) == 250
  end

  test "spending counts against the budget, and reservations sit on top of it" do
    team = team(1_000)

    {:ok, _} =
      TeamBudget.record(team, %{
        session_id: "s-1",
        owner_subject: "idp|alice",
        model: "m",
        cost_micros: 700,
        gateway_request_id: "req-1"
      })

    assert {:ok, state} = TeamBudget.reserve(team, "s-2", 200)
    assert state.spent_micros == 700
    assert state.remaining_micros == 100

    assert {:error, {:over_budget, _}} = TeamBudget.reserve(team, "s-3", 200)
  end

  test "the actor reloads what it promised, so a replica losing it changes nothing" do
    team = team(1_000)

    {:ok, _} = TeamBudget.reserve(team, "s-1", 800)

    pid = :global.whereis_name({TeamBudget, team.id})
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    # The reservation was written before it was granted, so the actor that comes back
    # knows about it.
    assert TeamBudget.inspect_state(team).reserved_micros == 800
    assert {:error, {:over_budget, _}} = TeamBudget.reserve(team, "s-2", 800)
  end

  test "concurrent reservations never exceed the budget" do
    team = team(1_000)

    results =
      1..50
      |> Task.async_stream(fn n -> TeamBudget.reserve(team, "s-#{n}", 100) end,
        max_concurrency: 50,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    granted = Enum.count(results, &match?({:ok, _}, &1))

    # Ten fit, forty do not, and the total promised is exactly the budget.
    assert granted == 10
    assert Enum.count(results, &match?({:error, {:over_budget, _}}, &1)) == 40

    assert TeamBudget.inspect_state(team).reserved_micros == 1_000
    assert Ledger.open_reservations(team.id) |> Map.values() |> Enum.sum() == 1_000
  end
end
