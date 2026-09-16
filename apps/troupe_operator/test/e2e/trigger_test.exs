defmodule Troupe.E2E.TriggerTest do
  @moduledoc """
  A cron trigger fires on the minute, as a service principal, once.

  The scheduler is tested in the plane's own suite against a clock it controls. What only
  a cluster settles is that it fires at all when nobody is asking it to: a plane running
  as a deployment, a wall clock nobody has stubbed, a principal that is not a person, and
  a session that lands on a real pod at the end of it.

  "Once" is the part worth the trouble. A cron trigger firing every minute is a trigger
  whose idempotency key changes every minute and not within one — so the assertion is
  that a minute produces exactly one run, and the fault that would break it is a second
  plane replica, a retry, or a scheduler that re-reads its table and forgets what it did.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 900_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Plane.ready!()
  end

  setup context do
    name = Plane.unique("e2e-tick")
    principal = Plane.unique("e2e-runner")

    created =
      Plane.call!("admin.principal.create", %{
        "team" => context.team,
        # A principal names a person answerable for what it does, and the sponsor has to
        # be somebody in the team. This is the person the suite signs in as.
        "principal" => %{
          "name" => principal,
          "profiles" => [context.profile],
          "sponsor" => Plane.subject()
        }
      })

    on_exit(fn ->
      Plane.call("admin.trigger.delete", %{"team" => context.team, "name" => name})

      Plane.call("admin.principal.disable", %{
        "subject" => created["subject"],
        "confirm" => created["subject"]
      })
    end)

    %{trigger: name, principal: created}
  end

  test "it fires on the minute, once, and the session belongs to the principal", context do
    # Every minute, so the wait is bounded by one. The scheduler's own tests decide what
    # a cron expression means; this one only needs it to come round soon.
    Plane.call!("admin.trigger.put", %{
      "trigger" => %{
        "team" => context.team,
        "name" => context.trigger,
        "principal" => context.principal["subject"],
        "profile" => context.profile,
        "source" => %{"kind" => "schedule", "cron" => "* * * * *"},
        "prompt_template" => "A scheduled check, from the cluster suite.",
        "enabled" => true
      }
    })

    # Up to two minutes: one for the next tick, one so a tick that lands the instant the
    # trigger was written is not the only chance.
    #
    # Waited on the *session*, not on the run. The run row is written before the session
    # is created — that is what makes two callers racing on one key decide by the unique
    # index rather than by luck — so a test that waited for the row and then asserted a
    # session id was asserting against a moment in the middle of the firing. It passed for
    # as long as creating a session was instant, and stopped when a profile that had
    # scaled down made the create wait for a worker.
    World.eventually(fn -> Enum.any?(runs(context), & &1["session_id"]) end,
      timeout: 300_000,
      every: 5_000,
      what: "#{context.trigger} to fire and make a session"
    )

    [first | _] = Enum.filter(runs(context), & &1["session_id"])
    assert first["session_id"], "the run made no session: #{inspect(first)}"

    # The session is the principal's, not the person's who wrote the trigger. That is the
    # whole point of a trigger having a principal: what it does is attributable to the
    # thing that was configured to do it, and a person who leaves does not take it with
    # them.
    session = Plane.call!("session.get", %{"session_id" => first["session_id"]})
    assert session["owner"] == context.principal["subject"] or
             Plane.call!("admin.sessions.list")
             |> Enum.find(%{}, &(&1["id"] == first["session_id"]))
             |> Map.get("owner") == context.principal["subject"]

    on_exit(fn -> Plane.call("session.erase", %{"session_id" => first["session_id"]}) end)

    # And the minute it fired for produced one run, not two. Grouped by the key rather
    # than counted overall, because a run for the *next* minute arriving while this
    # assertion is made is correct behaviour and would break a plain count.
    by_key = Enum.group_by(runs(context), & &1["idempotency_key"])
    assert Enum.all?(by_key, fn {_key, for_key} -> length(for_key) == 1 end),
           "a minute fired more than once: #{inspect(by_key)}"
  end

  defp runs(context) do
    Plane.call!("admin.runs.list", %{
      "filter" => %{"team" => context.team, "trigger" => context.trigger}
    })
    |> List.wrap()
  end
end
