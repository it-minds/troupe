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

  alias Troupe.Plane.{Admin, FakePod, Triggers}
  alias Troupe.Plane.Control.{Connections, Listener}
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

      # The window the plane supplies is the minute, so two POSTs either side of :00 are
      # two runs by design — and the second is then `skipped` under the cap, with no
      # session. It happened once in a release's soak. Both have to land in one minute.
      same_minute!()

      assert {:ok, first} = fire(context, trigger, key.key, %{"k" => "OPS-12"})
      assert {:ok, again} = fire(context, trigger, key.key, %{"k" => "OPS-12"})

      # Two POSTs in one minute against one revision are one run. The caller said nothing
      # about idempotency, so the plane supplies the window — which is what makes a retry
      # after a timeout safe for an executor that cannot know whether the first arrived.
      assert first.body["session_id"] == again.body["session_id"]
      assert length(Triggers.runs(context.team)) == 1
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

  # Waits out the last seconds of a minute, so a pair of requests made right after this
  # cannot straddle the boundary the plane's idempotency window is drawn on.
  defp same_minute! do
    second = DateTime.utc_now().second
    if second >= 55, do: Process.sleep((61 - second) * 1_000)
  end
end
