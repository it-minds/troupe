defmodule Troupe.Plane.BudgetLadderTest do
  @moduledoc """
  A cap is a ceiling at any scope, and the tightest one wins.

  A budget belonged to a team and to nothing else, which left the two things people
  actually ask for unsayable: "this contractor may spend a hundred a month, whatever team
  they are in" and "nobody may take this deployment past a number". Adding a rung is
  easy; what is worth testing is everything around it — that a refusal says *which*
  ceiling, that a rung which refuses does not leave the wider ones holding the money, and
  that a scope nobody has set does not quietly become a ceiling of zero. That "a month"
  is the calendar month in UTC, and turns over on the 1st, is `BudgetPeriodTest`'s.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{
    Budget,
    FakePod,
    Harness,
    Identity,
    Ledger,
    PersonBudget,
    Sessions,
    Settings,
    TeamBudget,
    Triggers
  }

  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 60_000

  # A pound, in millionths, and change.
  @million 1_000_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :deployment_budget_micros)
    end)

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 100 * @million)
    ada = person("ada@example.test", ["engineering"])
    pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 12)

    %{team: team, ada: ada, pod: pod.worker_id}
  end

  describe "the ladder" do
    test "lists every ceiling that applies, narrowest first", context do
      {:ok, _} = set_person_cap(context.ada, 10 * @million)
      Application.put_env(:troupe_plane, :deployment_budget_micros, 1_000 * @million)

      assert [person, team, platform] = Budget.ceilings(context.team, context.ada.subject)

      assert person.scope == :person
      assert person.budget_micros == 10 * @million
      assert team.scope == :team
      assert team.budget_micros == 100 * @million

      # Two caps over one number are one rung, and the summary says which of the two the
      # tighter is — an operator told "over budget" needs to know whether to ask their
      # platform admin or the people who signed the contract.
      assert platform.scope == :platform
      assert platform.bound_by == :deployment
      assert platform.budget_micros == 1_000 * @million
    end

    test "leaves out the rungs that do not apply", _context do
      # No team, no person: a private session on somebody's laptop spends no team's money
      # and this is what the ladder is for it.
      assert [platform] = Budget.ceilings(nil, nil)
      assert platform.scope == :platform
      assert platform.remaining_micros == :unlimited
    end

    test "treats a cap nobody has set as no cap at all", context do
      # Absence means everything, exactly as an entitlement's absence does. A person who
      # has never been given a ceiling should not be unable to work.
      assert %{remaining_micros: :unlimited} = PersonBudget.inspect_state(context.ada.subject)

      assert {:ok, _} = Budget.reserve(context.team, "s-1", context.ada.subject, 99 * @million)
    end
  end

  describe "a stored ceiling" do
    test "only ever narrows what the deployment allowed", _context do
      Application.put_env(:troupe_plane, :deployment_budget_micros, 50 * @million)

      # Tighter: it binds.
      {:ok, _} = platform_cap(10 * @million)
      assert %{bound_by: :platform, budget_micros: budget} = Budget.ceilings(nil, nil) |> hd()
      assert budget == 10 * @million

      # Wider: it is ignored, and the deployment's still binds. An operator who could
      # raise this from inside the console could raise it past whatever the people paying
      # for this agreed to.
      {:ok, _} = platform_cap(500 * @million)
      assert %{bound_by: :deployment, budget_micros: budget} = Budget.ceilings(nil, nil) |> hd()
      assert budget == 50 * @million
    end
  end

  describe "a refusal" do
    test "names the person's own cap, inside a team that is under its ceiling", context do
      {:ok, _} = set_person_cap(context.ada, 5 * @million)

      # The team has a hundred and has spent nothing. The person has five.
      assert {:error, {:over_budget, :person, summary}} =
               Budget.reserve(context.team, "s-1", context.ada.subject, 6 * @million)

      assert summary.scope == :person
      assert summary.subject == context.ada.subject
      assert summary.budget_micros == 5 * @million

      assert %{remaining_micros: remaining} = TeamBudget.inspect_state(context.team)
      assert remaining == 100 * @million
    end

    test "leaves nothing held at the rungs that had already agreed", context do
      # Person: plenty. Team: nothing. So the person's rung agrees and the team's refuses,
      # and what must not happen is the person's slice staying held.
      {:ok, _} = set_person_cap(context.ada, 1_000 * @million)
      thin = team_with_grant("design", "ux", name: "design", budget_micros: 1 * @million)
      grace = person("grace@example.test", ["design"])
      {:ok, _} = set_person_cap(grace, 1_000 * @million)

      assert {:error, {:over_budget, :team, _summary}} =
               Budget.reserve(thin, "s-1", grace.subject, 5 * @million)

      # Without the unwind, a person who kept failing against their team's ceiling would
      # slowly eat their own — and nothing would say so until they could not start
      # anything anywhere.
      assert %{reserved_micros: 0} = PersonBudget.inspect_state(grace.subject)
      assert Ledger.open_reservations_for(grace.subject) == %{}
    end

    test "names the deployment when that is what bound", context do
      Application.put_env(:troupe_plane, :deployment_budget_micros, 2 * @million)

      assert {:error, {:over_budget, :deployment, summary}} =
               Budget.reserve(context.team, "s-1", context.ada.subject, 3 * @million)

      assert summary.budget_micros == 2 * @million
    end
  end

  describe "one promise" do
    test "is one row, and is counted once by every rung", context do
      {:ok, _} = set_person_cap(context.ada, 50 * @million)
      assert {:ok, _} = Budget.reserve(context.team, "s-1", context.ada.subject, 10 * @million)

      assert Ledger.open_reservations_for(context.ada.subject) == %{"s-1" => 10 * @million}

      # Ten held, not twenty: a row written by the first rung would be read by the rungs
      # after it as a promise somebody else had made.
      assert %{reserved_micros: 10_000_000} = PersonBudget.inspect_state(context.ada.subject)
      assert %{reserved_micros: 10_000_000} = TeamBudget.inspect_state(context.team)

      # And reserving again for the same session is a retry, not a second slice.
      assert {:ok, _} = Budget.reserve(context.team, "s-1", context.ada.subject, 10 * @million)
      assert %{reserved_micros: 10_000_000} = PersonBudget.inspect_state(context.ada.subject)
    end

    test "is given back at every rung when it is released", context do
      {:ok, _} = set_person_cap(context.ada, 50 * @million)
      {:ok, _} = Budget.reserve(context.team, "s-1", context.ada.subject, 10 * @million)

      :ok = Budget.release(context.team, "s-1", context.ada.subject)

      assert %{reserved_micros: 0} = PersonBudget.inspect_state(context.ada.subject)
      assert %{reserved_micros: 0} = TeamBudget.inspect_state(context.team)
      assert Ledger.open_reservations_for(context.ada.subject) == %{}
    end
  end

  describe "through session.create" do
    test "a person at their own cap is refused, and told it is theirs", context do
      {:ok, _} = set_person_cap(context.ada, 2 * @million)

      # Everything they have, held by a session that is already running.
      assert {:ok, _} = Budget.reserve(context.team, "s-already", context.ada.subject, 2 * @million)

      assert {:error, error} =
               Harness.call(
                 "session.create",
                 %{"profile" => "dev", "team" => "engineering", "prompt" => "hello"},
                 %{user: context.ada, platform_admin?: false}
               )

      assert error.message == "budget_exhausted"

      # The team is nowhere near its ceiling. Telling this person "budget exhausted" and
      # leaving them to guess whose would send them to a team admin who can do nothing
      # about it.
      assert error.data.scope == :person
      assert error.data.subject == context.ada.subject

      # And nothing was left behind by the refusal: the team still holds only the two
      # the running session promised, not four.
      assert %{remaining_micros: 98_000_000} = TeamBudget.inspect_state(context.team)
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "a slice is trimmed to the tightest ceiling, not only to the team's", context do
      {:ok, _} = set_person_cap(context.ada, 2 * @million)

      assert {:ok, _endpoint} =
               Harness.call(
                 "session.create",
                 %{
                   "profile" => "dev",
                   "team" => "engineering",
                   "prompt" => "hello",
                   "terms" => %{"budget_micros" => 5 * @million}
                 },
                 %{user: context.ada, platform_admin?: false}
               )

      assert_receive {:pushed, "session.activate", pushed}, 5_000

      # The team has a hundred left and the person has two. A slice trimmed only against
      # the team would have been five, and the person's rung would have refused it a line
      # later — a refusal the caller could have been spared, saying the wrong thing.
      assert pushed["terms"]["budget_micros"] == 2 * @million
    end

    test "a trigger's spend counts against the sponsor, not the principal", context do
      {:ok, principal, _secret} =
        principal!(context.team, %{name: "nightly", profiles: ["dev"], sponsor: context.ada.subject})

      trigger =
        trigger!(context, principal, %{"name" => "triage", "terms" => %{"budget_micros" => @million}})

      assert {:ok, _fired} = Triggers.fire(trigger, "schedule", "cron:1", %{}, "scheduler")
      assert_receive {:pushed, "session.activate", _}, 5_000

      # The person answerable for the run, not the credential that made it. A cap that
      # counted only what somebody typed into would be one they step around by writing a
      # trigger.
      assert map_size(Ledger.open_reservations_for(context.ada.subject)) == 1
      assert Ledger.open_reservations_for(principal.subject) == %{}
    end
  end

  # A pod's dormancy report gives back the slot and every rung's slice. A session that
  # ends some other way has to give back the same, because nothing else will: every rung
  # reloads the ledger's open reservations, so a row nobody closes is held for good.
  describe "a running session that ends" do
    test "because its team lost the grant gives back its slot and every slice", context do
      {:ok, _} = set_person_cap(context.ada, 50 * @million)
      id = running!(context, 10 * @million)

      :ok = Identity.revoke(context.team, "dev")

      assert Sessions.get(id).state == "read_only"
      assert_given_back(context)
    end

    test "because it was erased gives back its slot and every slice", context do
      {:ok, _} = set_person_cap(context.ada, 50 * @million)
      id = running!(context, 10 * @million)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(context.ada))

      # The pod's `session.erase` stops the session without reporting it dormant.
      assert_receive {:pushed, "session.erase", %{"session_id" => ^id}}, 5_000
      assert_given_back(context)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  defp running!(context, slice) do
    params = %{
      "profile" => "dev",
      "team" => "engineering",
      "terms" => %{"budget_micros" => slice}
    }

    assert {:ok, %{"session_id" => id}} = Harness.call("session.create", params, as(context.ada))
    assert_receive {:pushed, "session.activate", _}, 5_000

    assert %{reserved_micros: ^slice} = TeamBudget.inspect_state(context.team)
    assert %{reserved_micros: ^slice} = PersonBudget.inspect_state(context.ada.subject)
    assert slots(context) == 1
    id
  end

  # All four read before asserting, so a failure says which of them is still held.
  defp assert_given_back(context) do
    held = %{
      team: TeamBudget.inspect_state(context.team).reserved_micros,
      person: PersonBudget.inspect_state(context.ada.subject).reserved_micros,
      ledger: Ledger.open_reservations(),
      slots: slots(context)
    }

    assert held == %{team: 0, person: 0, ledger: %{}, slots: 0}
  end

  # What the placement actor holds for the pod, without the reload
  # `Placement.inspect_state/1` does first, which would hide a slot never given back.
  defp slots(context) do
    :global.whereis_name({Troupe.Plane.Placement, "dev"})
    |> :sys.get_state()
    |> Map.fetch!(:capacities)
    |> Map.get(context.pod, 0)
  end

  defp set_person_cap(user, micros), do: Identity.set_budget(user, micros)

  defp platform_cap(micros) do
    Settings.put("platform_budget_micros", micros, "root@example.test")
  end

  defp trigger!(context, principal, attrs) do
    base = %{
      "principal" => principal.subject,
      "profile" => "dev",
      "source" => %{"kind" => "webhook", "provider" => "generic"},
      "prompt_template" => "do the thing",
      "visibility" => "private"
    }

    {:ok, trigger} = Triggers.put(context.team, Map.merge(base, attrs), "root@example.test")
    trigger
  end
end
