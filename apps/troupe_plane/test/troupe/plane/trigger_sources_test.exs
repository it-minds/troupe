defmodule Troupe.Plane.TriggerSourcesTest do
  @moduledoc """
  Seven ways to start a session, one shape in the log.

  A cron minute, an executor's webhook, a custom integration, a CI job, an API call, a
  person's "run now" and an agent starting a sibling all produced a session. What they
  did not produce was a session anybody could compare with the others: the fields each
  path wrote differed by more than the fact they were recording, so "show me everything
  that ran unattended last week" was a union of shapes a reader had to know to enumerate.

  The claim under test is narrow and is the whole of 2a: the origin of a firing is
  identical across all seven but for the discriminator and the key, one filter finds
  every one of them, and a caller may only name a source the door it came through can
  vouch for.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, FakePod, Harness, Principals, Triggers}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Triggers.{Run, Scheduler}
  alias Troupe.Protocol.Canonical

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    {:ok, principal, _secret} =
      principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

    # Room for all seven at once, because the claim is about seven live sessions being
    # one shape and a pod that filled up would prove it of four.
    pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 12)

    # The credential a caller at `/rpc` actually holds. `trigger.fire` is a principal's
    # method before it is an administrator's, and a test that drove it as a team admin
    # would leave the ordinary case uncovered.
    service = Principals.user_for(principal)

    %{team: team, ada: ada, principal: principal, service: service, pod: pod}
  end

  describe "every source" do
    test "produces an origin that differs only in the discriminator and the key", context do
      trigger = trigger!(context, %{"name" => "triage", "concurrency" => 7})
      event = %{"issue" => "OPS-12"}

      origins =
        for source <- Run.sources() do
          assert {:ok, _fired} = Triggers.fire(trigger, source, "k:#{source}", event, "whoever")
          assert_receive {:pushed, "session.activate", pushed}, 5_000
          {source, pushed["origin"]}
        end

      assert length(origins) == 7

      # Strip the two fields that are *meant* to differ. What is left has to be one map,
      # not seven that happen to agree: a reader comparing a cron run with a CI run
      # should have nothing to reconcile.
      rest =
        origins
        |> Enum.map(fn {_source, origin} -> Map.drop(origin, ["source", "idempotency_key"]) end)
        |> Enum.uniq()

      assert [common] = rest

      assert %{
               "kind" => "trigger",
               "trigger" => "triage",
               "revision" => "sha256:" <> _,
               "payload_digest" => digest,
               "principal" => %{"actor" => actor, "subject" => subject}
             } = common

      assert digest == Canonical.hash(event)
      assert actor == context.principal.subject
      assert subject == context.ada.subject

      # And the discriminator is in fact the discriminator.
      assert Enum.map(origins, fn {source, origin} -> {source, origin["source"]} end) ==
               Enum.map(Run.sources(), &{&1, &1})
    end

    test "is found by one filter, and each one by name", context do
      trigger =
        trigger!(context, %{"name" => "triage", "concurrency" => 7, "visibility" => "team"})

      for source <- Run.sources() do
        assert {:ok, _} = Triggers.fire(trigger, source, "k:#{source}", %{}, "whoever")
        assert_receive {:pushed, "session.activate", _}, 5_000
      end

      # A person's own session, which is the thing the filter has to leave out. Without
      # one in the table "everything automated" and "everything" are the same list and
      # the filter is untested.
      {:ok, _} =
        Harness.call(
          "session.create",
          %{"profile" => "dev", "prompt" => "by hand", "team" => "engineering"},
          %{user: context.ada, platform_admin?: false}
        )

      assert_receive {:pushed, "session.activate", _}, 5_000

      # Through the public method, because that is where a person asks the question.
      caller = %{user: context.ada, platform_admin?: false}
      assert {:ok, all} = Harness.call("sessions.list", %{}, caller)
      assert length(all["sessions"]) == 8

      # One filter, all seven, and the person's own session is not among them.
      assert {:ok, automated} = Harness.call("sessions.list", %{"source" => "any"}, caller)
      assert length(automated["sessions"]) == 7

      assert automated["sessions"]
             |> Enum.map(& &1["origin"]["source"])
             |> Enum.sort() == Enum.sort(Run.sources())

      for source <- Run.sources() do
        assert {:ok, one} = Harness.call("sessions.list", %{"source" => source}, caller)
        assert [%{"origin" => %{"source" => ^source}}] = one["sessions"]
      end
    end
  end

  describe "the source a caller may name" do
    test "is `api` when it names none, and `ci` or `integration` when it does", context do
      trigger!(context, %{"name" => "triage", "concurrency" => 3})
      caller = %{user: context.service, platform_admin?: false}

      for {given, expected} <- [{nil, "api"}, {"ci", "ci"}, {"integration", "integration"}] do
        params =
          %{"trigger" => "engineering/triage", "idempotency_key" => "rpc:#{expected}"}
          |> then(fn params -> if given, do: Map.put(params, "source", given), else: params end)

        assert {:ok, fired} = Harness.call("trigger.fire", params, caller)
        assert fired["run"]["source"] == expected
        assert_receive {:pushed, "session.activate", _}, 5_000
      end
    end

    test "is never one the door cannot vouch for", context do
      trigger!(context, %{"name" => "triage"})
      caller = %{user: context.service, platform_admin?: false}

      # The four that are not the caller's to claim. `schedule` is the argument for the
      # whole rule: an executor that could label its own runs `schedule` would disappear
      # into the cron rows, and the discriminator would stop discriminating.
      for source <- ["schedule", "manual", "webhook", "agent"] do
        params = %{
          "trigger" => "engineering/triage",
          "idempotency_key" => "rpc:#{source}",
          "source" => source
        }

        assert {:error, error} = Harness.call("trigger.fire", params, caller)
        assert error.message == "invalid_params"
      end

      # Refused, and nothing written: a run row for a refused claim would be a run with
      # no session that a listing shows as a failure.
      assert Triggers.runs(context.team) == []
      refute_receive {:pushed, "session.activate", _}, 300
    end

    test "is refused outright when it is not one of the seven", context do
      trigger = trigger!(context, %{"name" => "triage"})

      assert {:error, error} = Triggers.fire(trigger, "telepathy", "k-1", %{}, "whoever")
      assert error.message == "invalid_params"
      assert error.data.field == "source"
    end
  end

  describe "the door names the source" do
    test "the scheduler says `schedule`", context do
      trigger!(context, %{
        "name" => "nightly",
        "source" => %{"kind" => "schedule", "cron" => "* * * * *"}
      })

      assert [{_trigger, _due, {:ok, _}}] = Scheduler.tick(~U[2026-09-16 03:00:30Z])
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["origin"]["source"] == "schedule"
    end

    test "the console says `manual`", context do
      trigger!(context, %{"name" => "triage"})
      actor = platform_admin()

      assert {:ok, fired} = Admin.trigger_run(actor, "engineering", "triage")
      assert fired["run"]["source"] == "manual"
      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["origin"]["source"] == "manual"
    end
  end

  describe "the payload digest" do
    test "is over what arrived, not over what the run kept", context do
      trigger = trigger!(context, %{"name" => "triage", "concurrency" => 2})

      # Two events that agree for the first several kilobytes and differ past them. A
      # digest taken after the 16 KiB cap would call these the same firing.
      long = String.duplicate("a", 8_000)
      first = %{"body" => long <> "one"}
      second = %{"body" => long <> "two"}

      assert {:ok, a} = Triggers.fire(trigger, "webhook", "k-1", first, "hatchet")
      assert {:ok, b} = Triggers.fire(trigger, "webhook", "k-2", second, "hatchet")

      assert a.run.payload_digest == Canonical.hash(first)
      assert b.run.payload_digest == Canonical.hash(second)
      refute a.run.payload_digest == b.run.payload_digest
    end

    test "is a digest and never the payload", context do
      trigger = trigger!(context, %{"name" => "triage"})
      secret = %{"authorization" => "Bearer hunter2"}

      assert {:ok, fired} = Triggers.fire(trigger, "webhook", "k-1", secret, "hatchet")
      assert_receive {:pushed, "session.activate", pushed}, 5_000

      # The origin travels to the pod and into a durable event that outlives the session.
      # Whatever else is in it, the body is not.
      refute pushed["origin"] |> Jason.encode!() |> String.contains?("hunter2")
      assert fired.run.payload_digest == Canonical.hash(secret)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp platform_admin do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)
    Admin.actor_for(person("root@example.test", ["platform"]))
  end

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
