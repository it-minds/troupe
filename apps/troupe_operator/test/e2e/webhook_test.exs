defmodule Troupe.E2E.WebhookTest do
  @moduledoc """
  The trigger's own door, and the request the plane must not make.

  Both halves need a cluster for the same reason: they are about a credential and a
  network position that only exist when the plane is a deployment behind an ingress. A
  key that fires one trigger is only worth anything if holding it gets you nothing else,
  and "nothing else" is a property of the deployed surface rather than of the router
  module. A notification target that must not reach loopback is only refused for real
  when the process refusing it is a pod with a loopback of its own — one running a plane
  that answers `/rpc` on it.
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
    name = "e2e-hook-#{System.unique_integer([:positive])}"
    principal = "e2e-hooker-#{System.unique_integer([:positive])}"

    created =
      Plane.call!("admin.principal.create", %{
        "team" => context.team,
        "principal" => %{"name" => principal, "profiles" => [context.profile]}
      })

    Plane.call!("admin.trigger.put", %{
      "trigger" => %{
        "team" => context.team,
        "name" => name,
        "principal" => created["subject"],
        "profile" => context.profile,
        "source" => %{"kind" => "webhook", "provider" => "generic"},
        "prompt_template" => "Triage {{event.issue}}, from the cluster suite.",
        "enabled" => true
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

  describe "POST /trigger/<id>" do
    test "fires with the trigger's own key and nothing else", context do
      minted =
        Plane.call!("admin.trigger.key.rotate", %{
          "team" => context.team,
          "name" => context.trigger
        })

      # A real POST through the ingress with no credential but the key. Nothing here
      # holds a person's token: this is what a CI job has.
      response = hook(minted, %{"issue" => "OPS-12"})
      assert response.status == 202, "the ingress refused: #{inspect(response.body)}"
      assert response.body["run"]["source"] == "webhook"

      session_id = response.body["session_id"]
      assert is_binary(session_id), "no session: #{inspect(response.body)}"
      on_exit(fn -> Plane.call("session.erase", %{"session_id" => session_id}) end)

      # The session is the principal's and it is real: a pod has it.
      World.eventually(
        fn ->
          case Plane.call("admin.sessions.list", %{}) do
            {:ok, sessions} -> Enum.any?(List.wrap(sessions), &(&1["id"] == session_id))
            _other -> false
          end
        end,
        timeout: 120_000,
        every: 5_000,
        what: "the webhook's session to appear in the fleet"
      )

      # And the key opens exactly this one door. `/rpc` is where everything else lives,
      # and the key is not a credential there — which is the whole argument for having a
      # key at all rather than handing CI a principal's secret.
      assert {:error, _refused} =
               Plane.call("sessions.list", %{}, token: minted["key"])
    end

    test "does not double-fire when an executor retries blindly", context do
      minted =
        Plane.call!("admin.trigger.key.rotate", %{
          "team" => context.team,
          "name" => context.trigger
        })

      first = hook(minted, %{"issue" => "OPS-13"})
      again = hook(minted, %{"issue" => "OPS-13"})

      assert first.status == 202
      assert again.status == 202

      # Two POSTs, one session. An executor that retries after a timeout cannot know
      # whether the first arrived, and a plane that answered it with a second session
      # would be a plane nobody could retry against.
      assert first.body["session_id"] == again.body["session_id"]

      on_exit(fn ->
        Plane.call("session.erase", %{"session_id" => first.body["session_id"]})
      end)
    end

    test "says the same thing to every key that is not the key", context do
      Plane.call!("admin.trigger.key.rotate", %{
        "team" => context.team,
        "name" => context.trigger
      })

      [trigger] =
        Plane.call!("admin.triggers.list", %{"team" => context.team})
        |> List.wrap()
        |> Enum.filter(&(&1["name"] == context.trigger))

      wrong = post("/trigger/#{trigger["id"]}", %{}, "twk_not_the_key")
      invented = post("/trigger/00000000-0000-4000-8000-000000000000", %{}, "twk_not_the_key")

      assert wrong.status == 401
      assert invented.status == 401

      # One answer to two questions. Two answers would let anybody holding nothing walk
      # the id space and learn which triggers this plane has.
      assert wrong.body == invented.body
    end
  end

  describe "an outbound notification target" do
    test "that resolves to loopback is refused by the plane in the pod", context do
      # `/rpc` relative, and loopback spelled out: the plane's own API on the plane's own
      # interface. This is the 2026 LangGraph advisory's shape, and the reason it is
      # asserted here rather than only in a unit test is that here the loopback in
      # question is real — there is a plane listening on it, in this pod, that would
      # answer.
      for url <- [
            "/rpc",
            "http://127.0.0.1:4000/rpc",
            "http://localhost:4000/rpc",
            "http://[::1]:4000/rpc",
            "http://169.254.169.254/latest/meta-data/"
          ] do
        assert {:error, error} =
                 Plane.call("admin.trigger.put", %{
                   "trigger" => %{
                     "team" => context.team,
                     "name" => context.trigger,
                     "notify_url" => url
                   }
                 }),
               "#{url} was accepted"

        assert error["message"] == "invalid_params"
      end

      # And the trigger is unchanged: a refused save leaves nothing behind.
      [trigger] =
        Plane.call!("admin.triggers.list", %{"team" => context.team})
        |> List.wrap()
        |> Enum.filter(&(&1["name"] == context.trigger))

      assert is_nil(trigger["notify_url"])
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp hook(minted, body), do: post(minted["url"], body, minted["key"])

  defp post(path, body, key) do
    Req.post!(World.plane_url() <> path,
      json: body,
      headers: [{"authorization", "Bearer " <> key}],
      retry: false,
      receive_timeout: 30_000
    )
  end
end
