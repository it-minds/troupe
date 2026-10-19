defmodule Troupe.Plane.TriggerIngressTest do
  @moduledoc """
  `POST /trigger/<id>`: a door wide enough for one trigger and nothing else.

  Until now, firing a trigger from outside meant holding a credential that could do
  everything else too — a person's token, or a principal's secret, which administers
  every trigger in its team and starts sessions besides. Giving that to a CI job to call
  one webhook is giving it the team.

  The claim is that the key is narrow, that it produces exactly the run a schedule or a
  console click produces, and that the two things a webhook door gets wrong are not
  wrong here: a blind retry does not double-fire, and a wrong key cannot be used to find
  out which triggers exist.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, FakePod, Fleet, Repo, Triggers}
  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Triggers.{Run, Trigger}
  alias Troupe.Plane.Web.Router

  @moduletag timeout: 60_000

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    {:ok, listener} =
      start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])

    {:ok, principal, _secret} =
      principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

    _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0", capacity: 12)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)
    actor = Admin.actor_for(person("root@example.test", ["platform"]))

    %{
      url: "http://127.0.0.1:#{port}",
      team: team,
      ada: ada,
      principal: principal,
      actor: actor
    }
  end

  describe "the key" do
    # Before, a webhook trigger had no key until somebody found the button that made one on
    # its row, and a trigger that cannot be fired was half made.
    test "is minted when a webhook trigger is made, answered once, and fires it", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev"})

      attrs = %{
        "team" => "engineering",
        "name" => "deploys",
        "principal" => context.principal.subject,
        "profile" => "dev",
        "source" => %{"kind" => "webhook", "provider" => "generic"},
        "prompt_template" => "Deploy {{event.k}}",
        "visibility" => "private"
      }

      assert {:ok, made} = Admin.trigger_put(context.actor, attrs)
      assert "twk_" <> _rest = made.key
      trigger = Triggers.get(context.team, "deploys")
      assert made.url == "/trigger/" <> trigger.id
      assert made.trigger["has_key"]
      assert made.trigger["key_rotated_by"] == context.actor.subject

      # In no listing and no audit row: the answer to the create is the one place it is.
      {:ok, [listed]} = Admin.triggers_list(context.actor, "engineering")
      refute listed |> Jason.encode!() |> String.contains?(made.key)
      {:ok, rows} = Admin.audit_list(context.actor, subject_id: "engineering/deploys")
      refute rows |> Jason.encode!() |> String.contains?(made.key)

      assert Enum.any?(
               rows,
               &(&1.action == "trigger.put" and &1.detail["__key_minted__"] == true)
             )

      assert {:ok, %{status: 202}} = fire(context, trigger, made.key, %{"k" => "v2"})

      # A change to it mints nothing: its key is rotated as it always was.
      assert {:ok, changed} =
               Admin.trigger_put(context.actor, %{
                 "team" => "engineering",
                 "name" => "deploys",
                 "prompt_template" => "Deploy {{event.k}} now"
               })

      refute Map.has_key?(changed, :key)
      assert {:ok, %{status: 202}} = fire(context, trigger, made.key, %{"k" => "v3"}, "again")

      # A schedule has no door for a key to open, and gets none.
      assert {:ok, scheduled} =
               Admin.trigger_put(context.actor, %{
                 attrs
                 | "name" => "nightly",
                   "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"}
               })

      refute Map.has_key?(scheduled, :key)
      refute scheduled.trigger["has_key"]
    end

    test "is legible once, and the listing says only that there is one", context do
      trigger!(context, %{"name" => "triage"})

      assert {:ok, minted} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")
      assert "twk_" <> _rest = minted.key
      assert minted.url == "/trigger/" <> Triggers.get(context.team, "triage").id

      assert {:ok, [listed]} = Admin.triggers_list(context.actor, "engineering")
      assert listed["has_key"]
      assert listed["key_rotated_by"] == context.actor.subject

      # The whole of what the row says about the key. A listing that carried it would put
      # a credential into every console, every log of a response and every audit row that
      # quoted one.
      refute listed |> Jason.encode!() |> String.contains?(minted.key)
    end

    test "stops working the moment it is rotated", context do
      trigger = trigger!(context, %{"name" => "triage"})
      assert {:ok, first} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")
      assert {:ok, second} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      refute first.key == second.key

      # No overlap window, on purpose: a rotation is usually somebody reacting to a leak,
      # and a window would mean the leaked key went on firing for as long as it lasted.
      assert {:ok, %{status: 401}} = fire(context, trigger, first.key, %{})
      assert {:ok, %{status: 202}} = fire(context, trigger, second.key, %{})
    end

    test "fires one trigger and nothing else", context do
      triage = trigger!(context, %{"name" => "triage"})
      other = trigger!(context, %{"name" => "deploys"})

      assert {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, %{status: 202}} = fire(context, triage, key.key, %{})
      assert {:ok, %{status: 401}} = fire(context, other, key.key, %{})
    end

    test "tells a caller holding the wrong one nothing about what exists", context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, _} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      real = %{"id" => trigger.id, "key" => "twk_wrong"}
      invented = %{"id" => Ecto.UUID.generate(), "key" => "twk_wrong"}
      no_key_at_all = trigger!(context, %{"name" => "keyless"})

      answers =
        for %{"id" => id, "key" => key} <- [
              real,
              invented,
              %{"id" => no_key_at_all.id, "key" => "twk_wrong"},
              %{"id" => "not-a-uuid", "key" => "twk_wrong"}
            ] do
          {:ok, response} = post(context, "/trigger/#{id}", %{}, key)
          {response.status, response.body}
        end

      # One answer to four different questions. Two answers would be an oracle: a caller
      # holding nothing could walk the id space and learn which triggers a plane has.
      assert [one] = Enum.uniq(answers)
      assert {401, _body} = one
    end

    # A key is the webhook's door. On a schedule, a GitHub repository's trigger or a manual
    # one it would be a second door nobody asked for, through which whoever held it fired the
    # trigger with any event body they liked.
    test "is minted for a plain webhook only, and opens nothing on any other", context do
      {:ok, _} = Fleet.put_profile(%{name: "dev"})

      for {name, source, said} <- [
            {"nightly", %{"kind" => "schedule", "cron" => "0 3 * * *"},
             "is fired by its schedule"},
            {"by-hand", %{"kind" => "manual"}, "is run by hand"},
            {"fixes",
             %{
               "kind" => "webhook",
               "provider" => "github",
               "repository" => "acme/widgets",
               "label" => "troupe"
             }, "is fired by the GitHub App's signed deliveries for acme/widgets"}
          ] do
        trigger = trigger!(context, %{"name" => name, "source" => source})

        assert {:error, refused} = Admin.trigger_key_rotate(context.actor, "engineering", name)
        assert refused.message == "invalid_params"
        assert refused.data.reason =~ said
        assert refused.data.reason =~ "so it has no key"
        refute Triggers.get(context.team, name).key_hash

        assert {:ok, %{status: 401}} = fire(context, trigger, "twk_anything", %{})
      end

      # A webhook keyed once, then made a schedule: its key goes, and opened nothing anyway.
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")
      assert {:ok, %{status: 202}} = fire(context, trigger, key.key, %{}, "before")

      {:ok, scheduled} =
        Triggers.put(
          context.team,
          %{"name" => "triage", "source" => %{"kind" => "schedule", "cron" => "0 3 * * *"}},
          "root@example.test"
        )

      refute scheduled.key_hash
      refute Triggers.get(context.team, "triage").key_hash
      refute Triggers.trigger_json(scheduled)["has_key"]
      assert {:ok, %{status: 401}} = fire(context, trigger, key.key, %{}, "after")
      assert {:error, _refused} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")
      assert length(Triggers.runs(context.team)) == 1

      # Made a webhook again, it has no key until a rotation gives it a new one.
      {:ok, webhook} =
        Triggers.put(
          context.team,
          %{"name" => "triage", "source" => %{"kind" => "webhook", "provider" => "generic"}},
          "root@example.test"
        )

      refute Triggers.trigger_json(webhook)["has_key"]
      assert {:ok, %{status: 401}} = fire(context, trigger, key.key, %{}, "again")
    end

    test "a key a trigger kept from before it took none is no key in its listing", context do
      trigger!(context, %{"name" => "kept"})
      {:ok, _key} = Admin.trigger_key_rotate(context.actor, "engineering", "kept")

      # As a row from before the plane dropped a key on a change of source is.
      {:ok, kept} =
        context.team
        |> Triggers.get("kept")
        |> Trigger.changeset(%{"source" => %{"kind" => "manual"}})
        |> Repo.update()

      assert is_binary(kept.key_hash)
      refute Triggers.trigger_json(kept)["has_key"]
    end

    test "is refused when it is absent altogether", context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, _} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, response} =
               Req.request(
                 method: :post,
                 url: context.url <> "/trigger/#{trigger.id}",
                 json: %{},
                 decode_body: true,
                 retry: false
               )

      assert response.status == 401
    end
  end

  describe "the run it makes" do
    test "is the run a schedule makes, but for its source", context do
      trigger = trigger!(context, %{"name" => "triage", "prompt_template" => "Triage {{event.k}}"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, response} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert response.status == 202
      assert response.body["run"]["source"] == "webhook"
      assert is_binary(response.body["session_id"])

      assert_receive {:pushed, "session.activate", pushed}, 5_000
      assert pushed["prompt"] == "Triage OPS-12"
      assert pushed["owner_subject"] == context.principal.subject
      assert pushed["origin"]["source"] == "webhook"
      assert pushed["origin"]["principal"]["subject"] == context.ada.subject

      # Every check a principal's own create meets, met: the grant, the profile and the
      # terms came from the revision, and the run names it.
      assert pushed["origin"]["revision"] == response.body["run"]["revision_hash"]
    end

    test "does not double-fire when an executor retries blindly", context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, first} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert {:ok, again} = fire(context, trigger, key.key, %{"k" => "OPS-12"})

      # Two POSTs in one minute against one revision are one run. The caller said nothing
      # about idempotency, so the plane supplies the window — which is what makes a retry
      # after a timeout safe for an executor that cannot know whether the first arrived.
      assert first.body["session_id"] == again.body["session_id"]
      assert length(Triggers.runs(context.team)) == 1
    end

    # The window was the clock's minute, so a retry a second after a POST at :59 was a
    # firing of its own, `skipped` under the cap with no session: the cluster suite's
    # retry failed so on a release.
    test "is the run already made for a retry on the other side of the minute's turn",
         context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, first} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert is_binary(first.body["session_id"])

      # As the first would be had it come in at the last moment of the minute before.
      backdate!(first.body["run"], before_the_turn!())

      assert {:ok, again} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert again.status == 202
      assert again.body["session_id"] == first.body["session_id"]
      assert length(Triggers.runs(context.team)) == 1

      # A minute on from the firing it would repeat, a POST is a firing of its own, which
      # the cap the first still holds skips.
      backdate!(first.body["run"], DateTime.add(DateTime.utc_now(), -61, :second))

      assert {:ok, later} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert later.status == 202
      assert later.body["state"] == "skipped"
      assert length(Triggers.runs(context.team)) == 2
    end

    test "is one run with one session however many blind retries race", context do
      for n <- 1..4 do
        trigger = trigger!(context, %{"name" => "triage-#{n}"})
        {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage-#{n}")

        answers =
          1..3
          |> Enum.map(fn _ ->
            Task.async(fn -> fire(context, trigger, key.key, %{"k" => n}) end)
          end)
          |> Task.await_many(30_000)

        assert [session_id] =
                 answers
                 |> Enum.map(fn {:ok, answer} -> answer.body["session_id"] end)
                 |> Enum.uniq()

        assert is_binary(session_id), "an answer without the session: #{inspect(answers)}"
        assert length(Triggers.runs(context.team, trigger: "triage-#{n}")) == 1
      end
    end

    test "is one run for two that race on either side of a minute's turn", context do
      for n <- 1..4 do
        trigger = trigger!(context, %{"name" => "triage-#{n}"})
        turn = DateTime.utc_now() |> Map.merge(%{second: 0, microsecond: {0, 6}})

        # The one read the clock later may take the lock first, and either order is one run.
        answers =
          [-1, 1]
          |> Enum.shuffle()
          |> Enum.map(fn ms ->
            at = DateTime.add(turn, ms, :millisecond)

            Task.async(fn ->
              Triggers.fire_in_window(trigger, "webhook", %{"k" => n}, "trigger-key", at)
            end)
          end)
          |> Task.await_many(30_000)

        assert [{:ok, a}, {:ok, b}] = answers
        assert is_binary(a.session.id)
        assert a.session.id == b.session.id
        assert a.run.id == b.run.id
        assert length(Triggers.runs(context.team, trigger: "triage-#{n}")) == 1
      end
    end

    test "a repeat that overtakes the firing still starting its session waits for it",
         context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, first} = fire(context, trigger, key.key, %{}, "delivery-1")
      session_id = first.body["session_id"]

      # The run as it is between its row being written and its session being made.
      making =
        Repo.update!(
          Ecto.Changeset.change(Repo.get!(Run, first.body["run"]["id"]), session_id: nil)
        )

      repeat = Task.async(fn -> fire(context, trigger, key.key, %{}, "delivery-1") end)
      Process.sleep(300)
      run = Repo.update!(Ecto.Changeset.change(making, session_id: session_id))

      assert {:ok, %{status: 202} = again} = Task.await(repeat, 30_000)
      assert again.body["session_id"] == session_id

      # One whose session never comes is a duplicate, and the answer names the run.
      Repo.update!(Ecto.Changeset.change(run, session_id: nil))

      assert {:ok, %{status: 409} = stuck} = fire(context, trigger, key.key, %{}, "delivery-1")
      assert stuck.body["data"]["run"] == run.id
      assert stuck.body["data"]["reason"] =~ "still starting its session"
    end

    test "fires twice when the caller says they are two", context do
      trigger = trigger!(context, %{"name" => "triage", "concurrency" => 2})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      assert {:ok, a} = fire(context, trigger, key.key, %{}, "delivery-1")
      assert {:ok, b} = fire(context, trigger, key.key, %{}, "delivery-2")

      refute a.body["session_id"] == b.body["session_id"]
      assert length(Triggers.runs(context.team)) == 2

      # And the caller's own key still means one run when it repeats, which is the half
      # a provider with at-least-once delivery depends on.
      assert {:ok, repeat} = fire(context, trigger, key.key, %{}, "delivery-1")
      assert repeat.body["session_id"] == a.body["session_id"]
      assert length(Triggers.runs(context.team)) == 2
    end

    test "refuses a disabled trigger, and a body too large to be a record", context do
      trigger = trigger!(context, %{"name" => "triage"})
      {:ok, key} = Admin.trigger_key_rotate(context.actor, "engineering", "triage")

      big = %{"body" => String.duplicate("a", Triggers.max_event_bytes() + 1)}
      assert {:ok, %{status: 413}} = fire(context, trigger, key.key, big)

      {:ok, _} = Triggers.put(context.team, %{"name" => "triage", "enabled" => false}, "root")
      assert {:ok, %{status: 403}} = fire(context, trigger, key.key, %{})

      assert Triggers.runs(context.team) == []
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp fire(context, trigger, key, body, idempotency_key \\ nil) do
    post(context, "/trigger/#{trigger.id}", body, key, idempotency_key)
  end

  defp post(context, path, body, key, idempotency_key \\ nil) do
    headers =
      [{"authorization", "Bearer " <> key}] ++
        if idempotency_key, do: [{"idempotency-key", idempotency_key}], else: []

    Req.request(
      method: :post,
      url: context.url <> path,
      json: body,
      headers: headers,
      decode_body: true,
      retry: false
    )
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

  # The last tenth of a second of the minute before this one, which is less than a minute
  # ago once the clock is short of :58; it waits for the next minute where it is not.
  defp before_the_turn! do
    second = DateTime.utc_now().second
    if second >= 58, do: Process.sleep((60 - second) * 1_000)

    DateTime.utc_now()
    |> Map.merge(%{second: 0, microsecond: {0, 6}})
    |> DateTime.add(-100, :millisecond)
  end

  # A run moved back to `at`, under the key a firing without one was given then.
  defp backdate!(%{"id" => id, "revision_hash" => hash, "trigger_id" => trigger_id}, at) do
    Run
    |> Repo.get!(id)
    |> Ecto.Changeset.change(
      fired_at: at,
      idempotency_key: "webhook:#{trigger_id}:#{hash}:#{DateTime.to_iso8601(at)}"
    )
    |> Repo.update!()
  end
end
