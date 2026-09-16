defmodule Troupe.Plane.TriggersTest do
  @moduledoc """
  Sessions nobody starts by hand.

  The done items are about counting: one idempotency key is one session however many
  times it is fired, a trigger over its concurrency cap records a skipped run and no
  session, and a due cron minute fires once. The session itself is created through the
  same `session.create` a person uses, as the trigger's principal, which is what the
  first test proves by watching the pod.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.{FakePod, Harness, Identity, Principals, Repo, Sessions, Triggers}
  alias Troupe.Plane.Triggers.{Cron, Revision, Scheduler, Template}

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)

    {:ok, principal, _secret} =
      principal!(team, %{name: "nightly", profiles: ["dev"]})

    %{port: Listener.port(), team: team, principal: principal}
  end

  describe "the template" do
    test "looks paths up, and renders what is missing as nothing" do
      values = %{
        "event" => %{
          "issue" => %{
            "key" => "OPS-12",
            "title" => "Disk is full",
            "labels" => ["urgent", "ops"]
          },
          "count" => 3,
          "flag" => true
        }
      }

      assert Template.render("Triage {{event.issue.key}}: {{ event.issue.title }}", values) ==
               "Triage OPS-12: Disk is full"

      assert Template.render(
               "first label {{event.issue.labels.0}}, {{event.count}}, {{event.flag}}",
               values
             ) ==
               "first label urgent, 3, true"

      assert Template.render("[{{event.nothing.here}}] [{{nowhere}}]", values) == "[] []"
      assert Template.render("{{event.issue.labels}}", values) == ~s(["urgent","ops"])
    end

    test "escapes nothing and runs nothing" do
      values = %{"event" => %{"title" => "<b>&amp;</b> {{event.title}}"}}
      # A value that happens to contain a placeholder is text, not a second pass.
      assert Template.render("{{event.title}}", values) == "<b>&amp;</b> {{event.title}}"

      assert Template.render("{{#event}}x{{/event}} {{> partial}}", values) ==
               "{{#event}}x{{/event}} {{> partial}}"

      assert Template.render(nil, values) == ""
    end
  end

  describe "cron" do
    test "reads the five fields, and says which one it could not" do
      assert {:ok, _} = Cron.parse("0 3 * * 1-5")
      assert {:ok, _} = Cron.parse("*/15 9-17 1,15 * *")
      assert {:ok, _} = Cron.parse("30 2 * * 7")
      assert {:error, reason} = Cron.parse("0 3 * *")
      assert reason =~ "five fields"
      assert {:error, reason} = Cron.parse("60 3 * * *")
      assert reason =~ "minute"
      assert {:error, reason} = Cron.parse("0 3 * * mon")
      assert reason =~ "dow"
      assert {:error, _} = Cron.parse("*/0 * * * *")
      assert {:error, _} = Cron.parse("5-1 * * * *")
      assert {:error, _} = Cron.parse(nil)
    end

    test "matches minutes the way cron does" do
      {:ok, weekdays} = Cron.parse("0 3 * * 1-5")
      # 2026-09-14 is a Monday.
      assert Cron.matches?(weekdays, ~U[2026-09-14 03:00:30Z])
      refute Cron.matches?(weekdays, ~U[2026-09-14 03:01:00Z])
      refute Cron.matches?(weekdays, ~U[2026-09-13 03:00:00Z])

      {:ok, sunday} = Cron.parse("0 0 * * 7")
      assert Cron.matches?(sunday, ~U[2026-09-13 00:00:00Z])
      {:ok, sunday_too} = Cron.parse("0 0 * * 0")
      assert Cron.matches?(sunday_too, ~U[2026-09-13 00:00:00Z])

      # Both day fields restricted: either will do.
      {:ok, either} = Cron.parse("0 12 13 * 1")
      assert Cron.matches?(either, ~U[2026-09-13 12:00:00Z])
      assert Cron.matches?(either, ~U[2026-09-14 12:00:00Z])
      refute Cron.matches?(either, ~U[2026-09-15 12:00:00Z])

      {:ok, quarter} = Cron.parse("*/15 * * * *")
      assert Cron.matches?(quarter, ~U[2026-09-13 10:45:00Z])
      refute Cron.matches?(quarter, ~U[2026-09-13 10:50:00Z])
    end

    test "finds the latest matching minute at or before now" do
      {:ok, nightly} = Cron.parse("0 3 * * 1-5")
      # Sunday morning: the last weekday three o'clock was Friday's.
      assert Cron.previous(nightly, ~U[2026-09-13 10:07:00Z]) == ~U[2026-09-11 03:00:00Z]
      # Exactly on the minute counts, seconds and all.
      assert Cron.previous(nightly, ~U[2026-09-14 03:00:59Z]) == ~U[2026-09-14 03:00:00Z]

      {:ok, quarter} = Cron.parse("*/15 * * * *")
      assert Cron.previous(quarter, ~U[2026-09-13 10:07:00Z]) == ~U[2026-09-13 10:00:00Z]

      {:ok, leap} = Cron.parse("0 0 29 2 *")
      assert Cron.previous(leap, ~U[2026-09-13 10:07:00Z]) == ~U[2024-02-29 00:00:00Z]
    end
  end

  describe "firing" do
    test "creates the session as the principal, lets the notified in, and answers the same run to the same key",
         context do
      lead = person("lead@example.test", ["engineering"])
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      trigger =
        trigger!(context, %{
          "name" => "triage",
          "prompt_template" => "Triage {{event.issue.key}}: {{event.issue.title}}",
          "terms" => %{"max_turns" => 3, "approvals" => "deny"},
          "notify" => [lead.subject]
        })

      event = %{"issue" => %{"key" => "OPS-12", "title" => "Disk is full"}}
      assert {:ok, fired} = Triggers.fire(trigger, "hook:1", event, "hatchet")

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["owner_subject"] == "svc:engineering/nightly"
      assert pushed["prompt"] == "Triage OPS-12: Disk is full"
      assert pushed["terms"] == %{"max_turns" => 3, "approvals" => "deny"}
      # The origin names the revision as well as the trigger, so a session found six
      # weeks later says which wording made it without a join through the run.
      assert %{"kind" => "trigger", "trigger" => "triage", "run" => "hook:1"} =
               pushed["origin"]

      # Who fired it, and on whose authority. The principal is what acted; its sponsor is
      # the person answerable for what it did, and a run six weeks old is exactly when
      # somebody wants to know which human stands behind it.
      assert %{"actor" => "svc:engineering/nightly", "subject" => sponsor} =
               pushed["origin"]["principal"]

      assert sponsor == context.principal.sponsor_subject
      refute sponsor == "svc:engineering/nightly"

      assert pushed["origin"]["revision"] == fired.revision.hash

      session = fired.session
      assert session.owner_subject == "svc:engineering/nightly"
      assert session.origin["trigger"] == "triage"
      assert fired.run.session_id == session.id
      assert fired.run.event == event
      assert is_binary(fired.endpoint["token"])

      # The notified subject is a collaborator, through the public grant.
      assert Sessions.role_for(lead, session) == :control

      # The same key again: the same run, the same session, a token minted now.
      assert {:ok, again} = Triggers.fire(trigger, "hook:1", event, "hatchet")
      assert again.run.id == fired.run.id
      assert again.session.id == session.id
      assert is_binary(again.endpoint["token"])
      refute_receive {:pushed, "session.activate", _}, 300

      assert {:ok, %{"sessions" => sessions}} =
               Harness.call("sessions.list", %{"trigger" => "triage"}, context(lead))

      assert Enum.map(sessions, & &1["id"]) == [session.id]

      json = Triggers.fired_json(again)
      assert json["run"]["state"] == "running"
      assert json["session_id"] == session.id
    end

    test "over its concurrency cap, a run is recorded as skipped and no session is made",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      trigger = trigger!(context, %{"name" => "nightly", "concurrency" => 1})

      assert {:ok, first} = Triggers.fire(trigger, "cron:1", %{}, "scheduler")
      assert_receive {:pushed, "session.activate", _}, 5_000
      assert first.run.state == "created"

      assert {:ok, second} = Triggers.fire(trigger, "cron:2", %{}, "scheduler")
      assert second.run.state == "skipped"
      assert is_nil(second.session)
      assert is_nil(second.endpoint)
      refute_receive {:pushed, "session.activate", _}, 300

      # The first one finishes; the next firing is a session again.
      {:ok, _} =
        Sessions.put_status(first.session.id, %{"status" => "done", "done_reason" => "finished"})

      assert {:ok, third} = Triggers.fire(trigger, "cron:3", %{}, "scheduler")
      assert third.run.state == "created"
      assert_receive {:pushed, "session.activate", _}, 5_000

      runs = Triggers.runs(context.team, trigger: "nightly")

      assert Enum.map(runs, fn {run, _trigger, session} -> Triggers.state_of(run, session) end) ==
               ["running", "skipped", "done"]
    end

    test "a disabled trigger does not fire, and a key belongs to one trigger", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      a = trigger!(context, %{"name" => "a"})
      b = trigger!(context, %{"name" => "b"})

      assert {:ok, _} = Triggers.fire(a, "shared", %{}, "x")
      assert {:error, error} = Triggers.fire(b, "shared", %{}, "x")
      assert error.message == "conflict"

      {:ok, off} = Triggers.put(context.team, %{"name" => "b", "enabled" => false}, "root")
      assert {:error, error} = Triggers.fire(off, "b:1", %{}, "x")
      assert error.message == "forbidden"
    end

    test "trigger.fire is for the principal and the team's admins, and nobody else", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      trigger = trigger!(context, %{"name" => "triage"})
      robot = Identity.get_user(context.principal.subject)
      lead = person("lead@example.test", ["engineering"])
      member = person("member@example.test", ["engineering"])
      {:ok, _} = Identity.add_team_admin(context.team, lead.subject, "root")

      params = %{"trigger" => "triage", "idempotency_key" => "k-1", "event" => %{"n" => 1}}
      assert {:ok, fired} = Harness.call("trigger.fire", params, context(robot))
      assert fired["run"]["idempotency_key"] == "k-1"
      assert is_binary(fired["token"])
      assert_receive {:pushed, "session.activate", _}, 5_000

      assert {:ok, same} =
               Harness.call("trigger.fire", %{params | "trigger" => trigger.id}, context(lead))

      assert same["run"]["id"] == fired["run"]["id"]

      assert {:error, error} = Harness.call("trigger.fire", params, context(member))
      assert error.message == "not_found"
    end
  end

  describe "the scheduler" do
    test "fires a due trigger once, and not one that is not due", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      nightly =
        trigger!(context, %{
          "name" => "nightly",
          "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"}
        })

      hourly =
        trigger!(context, %{
          "name" => "hourly",
          "source" => %{"kind" => "schedule", "cron" => "0 * * * *"}
        })

      # Ten past three: the nightly is due and has never fired; the hourly's minute was
      # at three o'clock too. Both are within the window a never-fired trigger gets.
      assert fired = Scheduler.tick(~U[2026-09-14 03:00:40Z])

      assert fired |> Enum.map(fn {trigger, _due, _} -> trigger.name end) |> Enum.sort() == [
               "hourly",
               "nightly"
             ]

      assert_receive {:pushed, "session.activate", _}, 5_000
      assert_receive {:pushed, "session.activate", _}, 5_000

      assert DateTime.truncate(Triggers.fetch(nightly.id).last_fired_at, :second) ==
               ~U[2026-09-14 03:00:00Z]

      # Thirty seconds on, the same minute: nothing.
      assert Scheduler.tick(~U[2026-09-14 03:01:10Z]) == []
      refute_receive {:pushed, "session.activate", _}, 300

      # An hour on: the hourly fires; the nightly does not. Its three o'clock run has to
      # be over first, or the cap would make this a skipped run rather than a session.
      [{three, _, _}] = Triggers.runs(context.team, trigger: "hourly")

      {:ok, _} =
        Sessions.put_status(three.session_id, %{"status" => "done", "done_reason" => "finished"})

      assert [{fired, due, {:ok, _}}] = Scheduler.tick(~U[2026-09-14 04:00:05Z])
      assert fired.name == "hourly"
      assert due == ~U[2026-09-14 04:00:00Z]
      assert DateTime.truncate(Triggers.fetch(hourly.id).last_fired_at, :second) == due

      # The run carries the key the minute makes, so a second scheduler would have made
      # the same one.
      assert [{run, _, _} | _] = Triggers.runs(context.team, trigger: "hourly")
      assert run.idempotency_key == "cron:#{hourly.id}:2026-09-14T04:00:00Z"
    end

    test "a trigger that has never fired is not backfilled", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      _nightly =
        trigger!(context, %{
          "name" => "nightly",
          "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"}
        })

      # Enabled at ten in the morning: three o'clock was seven hours ago and is not run now.
      assert Scheduler.tick(~U[2026-09-14 10:00:00Z]) == []
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "a plane that was down fires once for the latest missed minute", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      quarter =
        trigger!(context, %{
          "name" => "quarter",
          "source" => %{"kind" => "schedule", "cron" => "*/15 * * * *"}
        })

      true = Triggers.mark_fired(quarter, ~U[2026-09-14 10:00:00Z])

      # Back at 11:07 after an hour away: 10:15, 10:30, 10:45 and 11:00 were missed. One
      # firing, for 11:00.
      assert [{_, due, {:ok, _}}] = Scheduler.tick(~U[2026-09-14 11:07:00Z])
      assert due == ~U[2026-09-14 11:00:00Z]
      assert_receive {:pushed, "session.activate", _}, 5_000
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "a schedule is checked when it is written" do
      team = team_with_grant("design", "ux", name: "design")
      {:ok, _principal, _} = principal!(team, %{name: "bot", profiles: ["ux"]})

      base = %{"name" => "bad", "principal" => "svc:design/bot", "profile" => "ux"}
      put = fn extra -> Triggers.put(team, Map.merge(base, extra), "root") end

      assert {:error, error} = put.(%{"source" => %{"kind" => "schedule", "cron" => "nope"}})
      assert error.message == "invalid_params"

      copenhagen = %{"kind" => "schedule", "cron" => "0 3 * * *", "tz" => "Europe/Copenhagen"}
      assert {:error, error} = put.(%{"source" => copenhagen})
      assert error.message == "invalid_params"
      assert error.data.reason =~ "UTC"

      assert {:error, error} = put.(%{"source" => %{"kind" => "carrier-pigeon"}})
      assert error.message == "invalid_params"

      assert {:error, error} =
               put.(%{"source" => %{"kind" => "webhook"}, "terms" => %{"budget" => 1}})

      assert error.message == "invalid_params"

      assert {:ok, _} = put.(%{"source" => %{"kind" => "webhook", "provider" => "github"}})
    end
  end

  describe "revisions" do
    test "an edit makes a revision; the previous run still reports the one it ran",
         context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      trigger = trigger!(context, %{"name" => "nightly", "prompt_template" => "check disks"})

      assert {:ok, first} = Triggers.fire(trigger, "run-1", %{}, "scheduler")
      assert first.revision.revision == 1
      assert first.revision.hash =~ ~r/^sha256:[0-9a-f]{64}$/

      {:ok, edited} =
        Triggers.put(context.team, %{"name" => "nightly", "prompt_template" => "check disks twice"}, "root")

      assert [second, _first] = Triggers.revisions(edited)
      assert second.revision == 2
      assert second.prompt_template == "check disks twice"

      # The run made before the edit still names revision 1, with its text.
      reread = Triggers.revision(first.run.revision_id)
      assert reread.revision == 1
      assert reread.prompt_template == "check disks"

      assert {:ok, next} = Triggers.fire(edited, "run-2", %{}, "scheduler")
      assert next.revision.revision == 2
    end

    test "editing back to the original text makes no third revision", context do
      trigger = trigger!(context, %{"name" => "backandforth", "prompt_template" => "one"})
      assert [%Revision{revision: 1}] = Triggers.revisions(trigger)

      {:ok, trigger} =
        Triggers.put(context.team, %{"name" => "backandforth", "prompt_template" => "two"}, "root")

      assert [%Revision{revision: 2}, %Revision{revision: 1}] = Triggers.revisions(trigger)

      {:ok, trigger} =
        Triggers.put(context.team, %{"name" => "backandforth", "prompt_template" => "one"}, "root")

      assert [%Revision{revision: 2}, %Revision{revision: 1}] = Triggers.revisions(trigger)
      assert {:ok, %Revision{revision: 1}} = Triggers.revise(trigger)
    end

    test "switching a trigger off is not a change to what a run would be", context do
      trigger = trigger!(context, %{"name" => "toggled"})
      assert [%Revision{revision: 1, hash: hash}] = Triggers.revisions(trigger)

      {:ok, off} = Triggers.put(context.team, %{"name" => "toggled", "enabled" => false}, "root")
      assert [%Revision{revision: 1, hash: ^hash}] = Triggers.revisions(off)

      {:ok, on} = Triggers.put(context.team, %{"name" => "toggled", "enabled" => true}, "root")
      assert [%Revision{revision: 1, hash: ^hash}] = Triggers.revisions(on)
    end

    test "the hash is over the document, not over the row", context do
      trigger = trigger!(context, %{"name" => "hashed"})

      # Two rows of two different triggers with the same document hash to the same
      # thing: nothing identifying the trigger is in it.
      other = trigger!(context, %{"name" => "hashed-too"})
      assert Revision.hash(trigger) == Revision.hash(%{other | name: trigger.name})

      # And the source is in it, so a webhook and a schedule are different documents
      # even where everything else matches — which is what makes one revision serve
      # every way a trigger is fired.
      schedule = %{"kind" => "schedule", "cron" => "0 3 * * *"}
      refute Revision.hash(trigger) == Revision.hash(%{trigger | source: schedule})
    end

    test "a firing that overlaps an edit names exactly one revision", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      trigger = trigger!(context, %{"name" => "racing", "prompt_template" => "before"})

      # The edit commits while the firing is in flight: `fire/4` resolved the revision
      # before it wrote the run, so the run has the document it read and not a mixture.
      task =
        Task.async(fn ->
          Repo.checkout(fn ->
            Triggers.put(
              context.team,
              %{"name" => "racing", "prompt_template" => "after"},
              "root"
            )
          end)
        end)

      assert {:ok, fired} = Triggers.fire(trigger, "race-1", %{}, "scheduler")
      {:ok, _} = Task.await(task)

      assert fired.run.revision_id == fired.revision.id
      named = Triggers.revision(fired.run.revision_id)
      assert named.prompt_template in ["before", "after"]

      # One, and it does not move afterwards.
      assert {:ok, again} = Triggers.fire(trigger, "race-1", %{}, "scheduler")
      assert again.run.revision_id == fired.run.revision_id
      assert again.revision.hash == named.hash
    end

    test "a run renders from its revision, and says which in the listing", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")

      trigger =
        trigger!(context, %{
          "name" => "rendered",
          "prompt_template" => "rev {{run.revision}} of {{trigger.name}}"
        })

      assert {:ok, fired} = Triggers.fire(trigger, "render-1", %{}, "scheduler")

      json = Triggers.fired_json(fired)
      assert json["run"]["revision"] == 1
      assert json["run"]["revision_hash"] == fired.revision.hash

      assert [{run, _trigger, _session}] = Triggers.runs(context.team, trigger: "rendered")
      assert %Revision{revision: 1} = run.revision
      assert Triggers.run_json(run, nil)["revision"] == 1
    end

    test "a trigger listing carries the revision its next firing would use", context do
      trigger = trigger!(context, %{"name" => "listed"})
      json = Triggers.trigger_json(trigger)

      assert json["revision"]["revision"] == 1
      assert json["revision"]["hash"] =~ ~r/^sha256:/
      refute json["revision"]["reconstructed"]
    end
  end

  describe "reviewing" do
    test "marks the session and its run, for anybody who can see it", context do
      _pod = FakePod.enrol(context.port, "dev-token", "troupe-w-dev-0")
      lead = person("lead@example.test", ["engineering"])
      trigger = trigger!(context, %{"name" => "nightly", "notify" => [lead.subject]})

      assert {:ok, fired} = Triggers.fire(trigger, "cron:1", %{}, "scheduler")
      assert_receive {:pushed, "session.activate", _}, 5_000

      assert {:ok, %{"sessions" => [_]}} =
               Harness.call("sessions.list", %{"needs_review" => true}, context(lead))

      assert {:ok, reviewed} =
               Harness.call("session.review", %{"session_id" => fired.session.id}, context(lead))

      assert reviewed["reviewed_by"] == lead.subject

      assert [{run, _, _}] = Triggers.runs(context.team, trigger: "nightly")
      assert run.reviewed_by == lead.subject
      assert run.reviewed_at

      assert {:ok, %{"sessions" => []}} =
               Harness.call("sessions.list", %{"needs_review" => true}, context(lead))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp context(user), do: %{user: user, platform_admin?: false}

  defp trigger!(context, attrs) do
    base = %{
      "principal" => context.principal.subject,
      "profile" => "dev",
      "source" => %{"kind" => "webhook", "provider" => "generic"},
      "prompt_template" => "do the thing",
      "visibility" => "private"
    }

    {:ok, trigger} = Triggers.put(context.team, Map.merge(base, attrs), "root@example.test")
    trigger
  end
end
