defmodule Troupe.Plane.OwnTriggersTest do
  @moduledoc """
  A person's own triggers (#1235): the ones a yes of theirs made under their own sponsored
  principal, which they list, switch off and on, and remove without an administrator,
  audited as an administrator's put and delete are, and refused on a gitops plane as those
  are. Nobody else's trigger is theirs, an administrator's in the same team included.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Audit, Fleet, Harness, Identity, Principals, Proposals, Triggers}
  alias Troupe.Plane.Gitops.Report
  alias Troupe.Plane.Proposals.Made
  alias Troupe.Plane.Triggers.{Cron, Run}

  setup do
    {:ok, _} = Fleet.put_profile(%{name: "dev", replicas: 1, sessions_per_pod: 2})
    team = team_with_grant("eng", "dev", name: "eng")
    ada = person("ada@example.test", ["eng"])
    bea = person("bea@example.test", ["eng"])

    {:ok, robot, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

    {:ok, admins} =
      Triggers.put(
        team,
        %{
          "name" => "admins-nightly",
          "principal" => robot.subject,
          "profile" => "dev",
          "source" => %{"kind" => "schedule", "cron" => "0 3 * * *", "tz" => "UTC"}
        },
        "lead@example.test"
      )

    %{team: team, ada: ada, bea: bea, admins: admins, own: own_trigger(team, ada, "weekly")}
  end

  describe "trigger.own.list" do
    test "lists the caller's own, with the next run, the last run and the budget", %{
      ada: ada,
      own: own
    } do
      {:ok, revision} = Triggers.revise(own)

      {:ok, _} =
        Repo.insert(%Run{
          trigger_id: own.id,
          revision_id: revision.id,
          idempotency_key: "k-1",
          source: "schedule",
          state: "skipped",
          reason: "one at a time",
          fired_by: "scheduler",
          fired_at: ~U[2026-11-23 06:00:00.000000Z]
        })

      assert {:ok, %{"triggers" => [row], "most_per_team" => 5}} =
               call("trigger.own.list", %{}, ada)

      assert row["team"] == "eng"
      assert row["name"] == "weekly"
      assert row["principal"] == "svc:eng/own-ada-example-test"
      assert row["enabled"] == true
      assert row["cron"] == "0 6 * * 1"
      assert row["budget_micros"] == 1_000_000
      assert row["session_id"] == "s-weekly"
      assert row["artifact_id"] == "art-weekly"
      assert {:ok, next, 0} = DateTime.from_iso8601(row["next_run_at"])
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
      assert next.hour == 6 and Date.day_of_week(next) == 1

      assert %{
               "state" => "skipped",
               "reason" => "one at a time",
               "fired_at" => "2026-11-23T06:00:00" <> _
             } =
               row["last_run"]
    end

    test "is empty for a member with none, and never shows an administrator's", %{bea: bea} do
      assert {:ok, %{"triggers" => []}} = call("trigger.own.list", %{}, bea)
    end
  end

  describe "switching off and on" do
    test "the owner may, audited as trigger.put with them as actor and via own", %{
      ada: ada,
      team: team,
      own: own
    } do
      assert {:ok, %{"trigger" => off}} =
               call("trigger.own.disable", %{"trigger" => "weekly"}, ada)

      assert off["enabled"] == false
      assert off["next_run_at"] == nil
      refute Triggers.get(team, "weekly").enabled

      assert {:ok, %{"trigger" => on}} =
               call("trigger.own.enable", %{"trigger" => "eng/weekly"}, ada)

      assert on["enabled"] == true
      assert Triggers.get(team, own.name).enabled

      [disabled, enabled] = audited("trigger.put", "eng/weekly")
      assert disabled.actor == ada.subject
      assert disabled.detail["via"] == "own"
      assert disabled.detail["enabled"] == %{"from" => true, "to" => false}
      assert disabled.detail["principal"] == "svc:eng/own-ada-example-test"
      assert is_integer(disabled.detail["__revision__"])
      assert enabled.detail["enabled"] == %{"from" => false, "to" => true}
    end

    test "another member may not, saying whose it is", %{bea: bea, own: own} do
      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call("trigger.own.disable", %{"trigger" => own.id}, bea)

      assert reason =~
               "runs as svc:eng/own-ada-example-test, not as your own principal svc:eng/own-bea-example-test"

      assert Repo.get!(Triggers.Trigger, own.id).enabled
    end

    test "an administrator's trigger in the same team is not the member's own", %{
      ada: ada,
      admins: admins
    } do
      assert {:error, %{message: "forbidden", data: %{principal: "svc:eng/nightly"}}} =
               call("trigger.own.disable", %{"trigger" => "admins-nightly"}, ada)

      assert Repo.get!(Triggers.Trigger, admins.id).enabled
      assert audited("trigger.put", "eng/admins-nightly") == []
    end

    test "a trigger in a team the caller is not in is not found", %{ada: ada} do
      other = team_with_grant("ops", "dev", name: "ops")
      carl = person("carl@example.test", ["ops"])
      theirs = own_trigger(other, carl, "carls")

      assert {:error, %{message: "not_found"}} =
               call("trigger.own.disable", %{"trigger" => theirs.id}, ada)
    end

    test "switching on again waits for a team that lets members schedule", %{ada: ada, team: team} do
      {:ok, _} = call("trigger.own.disable", %{"trigger" => "weekly"}, ada)
      {:ok, _} = Identity.update_team(team, %{members_may_schedule: false})

      assert {:error,
              %{message: "forbidden", data: %{reason: "eng does not let members schedule" <> _}}} =
               call("trigger.own.enable", %{"trigger" => "weekly"}, ada)

      refute Triggers.get(team, "weekly").enabled
    end
  end

  describe "removing" do
    test "the owner may, audited as trigger.delete, and it frees a slot of the five", %{
      ada: ada,
      team: team
    } do
      for n <- 2..5, do: own_trigger(team, ada, "t#{n}")
      {:ok, _} = call("trigger.own.disable", %{"trigger" => "t2"}, ada)

      # Off or on, each counts.
      assert held(team, ada) == 5

      assert {:ok, %{"team" => "eng", "name" => "t2", "deleted" => true}} =
               call("trigger.own.delete", %{"trigger" => "t2"}, ada)

      assert Triggers.get(team, "t2") == nil
      assert held(team, ada) == 4

      [removed] = audited("trigger.delete", "eng/t2")
      assert removed.actor == ada.subject
      assert removed.detail["via"] == "own"
      assert removed.detail["enabled"] == false
    end

    test "another member and an administrator's trigger are refused", %{
      bea: bea,
      ada: ada,
      team: team
    } do
      assert {:error, %{message: "forbidden"}} =
               call("trigger.own.delete", %{"trigger" => "weekly"}, bea)

      assert {:error, %{message: "forbidden"}} =
               call("trigger.own.delete", %{"trigger" => "admins-nightly"}, ada)

      assert Triggers.get(team, "weekly")
      assert Triggers.get(team, "admins-nightly")
    end
  end

  describe "on a gitops plane" do
    setup do
      Application.put_env(:troupe_plane, :provisioning_mode, :gitops)
      on_exit(fn -> Application.delete_env(:troupe_plane, :provisioning_mode) end)
    end

    test "a switch and a removal are refused as an administrator's are, the attempt audited", %{
      ada: ada,
      team: team
    } do
      assert {:error, %{message: "managed_by_gitops", data: %{kind: "Trigger", reason: reason}}} =
               call("trigger.own.disable", %{"trigger" => "weekly"}, ada)

      assert reason =~ "this plane is in gitops mode: a Trigger is a resource a repository holds"

      assert {:error, %{message: "managed_by_gitops"}} =
               call("trigger.own.delete", %{"trigger" => "weekly"}, ada)

      assert Triggers.get(team, "weekly").enabled

      assert [%{detail: %{"outcome" => "refused", "via" => "own"}}] =
               audited("trigger.put", "eng/weekly")

      assert [%{detail: %{"outcome" => "refused"}}] = audited("trigger.delete", "eng/weekly")
    end

    test "a row the cluster has no resource for is removed, as an administrator's is", %{
      ada: ada,
      team: team
    } do
      Repo.insert!(%Report{kind: "Trigger", name: "eng.weekly", problem: "missing", reasons: []})

      assert {:ok, %{"deleted" => true}} =
               call("trigger.own.delete", %{"trigger" => "weekly"}, ada)

      assert Triggers.get(team, "weekly") == nil
    end
  end

  test "an administrator's listing marks an own trigger as the person's", %{
    ada: ada,
    own: own,
    admins: admins
  } do
    assert Triggers.trigger_json(own)["own_by"] == ada.subject
    assert Triggers.trigger_json(admins)["own_by"] == nil
  end

  test "the handshake says the plane has them" do
    assert {:ok, %{"capabilities" => %{"own_triggers" => true}}} =
             call("initialize", %{}, person("dan@example.test", ["eng"]))
  end

  test "a schedule's next minute is the first match after now" do
    {:ok, monday_six} = Cron.parse("0 6 * * 1")
    assert Cron.next(monday_six, ~U[2026-11-28 10:15:30Z]) == ~U[2026-11-30 06:00:00Z]
    assert Cron.next(monday_six, ~U[2026-11-30 06:00:00Z]) == ~U[2026-12-07 06:00:00Z]

    {:ok, quarter} = Cron.parse("*/15 * * * *")
    assert Cron.next(quarter, ~U[2026-11-28 23:59:00Z]) == ~U[2026-11-29 00:00:00Z]

    {:ok, leap} = Cron.parse("0 0 29 2 *")
    assert Cron.next(leap, ~U[2026-11-28 00:00:00Z]) == ~U[2028-02-29 00:00:00Z]
  end

  # A trigger as a yes makes it: under the person's own principal, with the row that counts
  # it against the five.
  defp own_trigger(team, user, name) do
    subject = Proposals.own_subject(team.name, user.subject)

    principal =
      Principals.get(subject) ||
        elem(
          Principals.create(
            team,
            %{
              "name" => String.replace_prefix(subject, "svc:#{team.name}/", ""),
              "profiles" => ["dev"],
              "sponsor" => user.subject
            },
            user.subject
          ),
          1
        )

    {:ok, trigger} =
      Triggers.put(
        team,
        %{
          "name" => name,
          "principal" => principal.subject,
          "profile" => "dev",
          "enabled" => true,
          "source" => %{"kind" => "schedule", "cron" => "0 6 * * 1", "tz" => "UTC"},
          "terms" => %{"budget_micros" => 1_000_000}
        },
        user.subject
      )

    Repo.insert_all(Made, [
      %{
        trigger_id: trigger.id,
        team_id: team.id,
        user_id: user.id,
        session_id: "s-#{name}",
        proposal: "proposal-1",
        artifact_id: "art-#{name}",
        inserted_at: DateTime.utc_now()
      }
    ])

    trigger
  end

  defp held(team, user),
    do:
      Repo.aggregate(
        from(m in Made, where: m.team_id == ^team.id and m.user_id == ^user.id),
        :count
      )

  defp audited(action, subject) do
    Repo.all(
      from(a in Audit.Event,
        where: a.action == ^action and a.subject_id == ^subject,
        order_by: a.occurred_at
      )
    )
  end

  defp call(method, params, user),
    do: Harness.call(method, params, %{user: user, platform_admin?: false})
end
