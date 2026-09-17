defmodule Troupe.E2E.A2ATest do
  @moduledoc """
  The A2A facade, in the cluster, reaching a pod.

  The facade is a client of the plane and of worker pods over their public APIs, with no
  database and no cluster privileges of its own — that is the claim its whole design
  rests on, and it is only true if the thing deployed can actually get there. In-process
  tests give it a plane and a worker in the same BEAM; here it is three deployments, an
  ingress, a token exchanged at the plane, and a WebSocket to a pod.

  `message/send` is the one that proves the path end to end, because it is the method
  that has to do all of it: authenticate the caller at the plane, create a session,
  attach to the pod holding it, and answer with a task.
  """

  use ExUnit.Case, async: false

  alias Troupe.E2E.{Plane, World}

  @moduletag :e2e
  @moduletag timeout: 600_000

  setup_all do
    case World.ready?() do
      :ok -> :ok
      {:error, message} -> raise message
    end

    Map.put(Plane.ready!(), :facade, World.reachable(World.a2a_url()))
  end

  test "the facade serves a profile's agent card to a caller the plane knows", context do
    # Unauthenticated, the card is the public one: a name and nothing about what a
    # particular caller may do with it.
    public = get!("#{context.facade}/a2a/#{context.profile}/.well-known/agent-card.json")
    assert public["name"]

    # With a credential, the facade asks the plane who this is and answers the card that
    # caller's own grants earn. That it can ask at all is the claim: it reaches the plane
    # from inside the cluster, with the caller's token and none of its own.
    card = get!("#{context.facade}/a2a/#{context.profile}/.well-known/agent-card.json", bearer())
    assert card["name"]
    assert card["url"] =~ context.profile
  end

  test "message/send creates a session on a pod and answers a task", context do
    answer =
      post!("#{context.facade}/a2a/#{context.profile}", bearer(), %{
        "jsonrpc" => "2.0",
        "id" => "e2e-1",
        "method" => "message/send",
        "params" => %{
          "message" => %{
            "role" => "user",
            "parts" => [%{"kind" => "text", "text" => "A message from the cluster suite."}],
            "messageId" => "e2e-#{System.unique_integer([:positive])}"
          }
        }
      })

    assert %{"result" => task} = answer, "the facade answered #{inspect(answer)}"
    assert task["id"], "no task id: #{inspect(task)}"
    assert task["status"]["state"] in ~w(submitted working input-required completed failed)

    on_exit(fn -> Plane.call("admin.session.erase", %{"session_id" => task["id"], "confirm" => task["id"]}) end)

    # A task is a session. The plane has a row for it, on a pod of this profile — which is
    # the half that says the facade really went through the front door rather than
    # inventing a task of its own.
    session =
      Plane.call!("admin.sessions.list", %{"filter" => %{"profile" => context.profile}})
      |> List.wrap()
      |> Enum.find(&(&1["id"] == task["id"]))

    assert session, "the plane has no session for task #{task["id"]}"
  end

  test "an artifact of a task the caller has no claim on is not served", context do
    # No task, no artifact. The facade asks the plane whether this caller may see the
    # task at all before it goes looking for bytes, which is what stops one caller
    # reading another's artifacts by guessing a task id.
    assert {status, body} =
             get("#{context.facade}/a2a/tasks/no-such-task/artifacts/#{String.duplicate("a", 64)}", bearer())

    assert status in [404, 502], inspect(body)
    assert body["error"] || body["message"], inspect(body)
    _ = context
  end

  # What is *not* claimed here: an artifact fetched and its hash checked. The facade
  # replays a task's events by attaching to the worker pod at the endpoint the plane
  # names — the pod's public one, `ws://<ordinal>-<profile>.workers.<domain>` — and on a
  # real cluster that hostname resolves inside as well as outside. On kind it does not:
  # `localtest.me` is 127.0.0.1 everywhere, which inside a pod is the pod, and the
  # CoreDNS rewrite `scripts/remote-up` installs covers the one name Dex needs and not a
  # wildcard. So the facade answers `unavailable` for anything that needs the pod, and
  # producing an artifact to corrupt would need a model besides. The hash check itself is
  # covered in `troupe_a2a`'s own suite, where a mismatch can be injected.

  # -- helpers ----------------------------------------------------------------

  # The identity provider's token, not the plane's. The facade exchanges the caller's own
  # credential at the plane on every request and holds nothing between them — which is
  # the whole reason it needs no privileges of its own.
  defp bearer, do: [{"authorization", "Bearer " <> Plane.id_token!()}]

  defp get!(url, headers \\ []) do
    {200, body} = get(url, headers)
    body
  end

  defp get(url, headers) do
    response = Req.get!(url, headers: headers, retry: false, receive_timeout: 60_000)
    {response.status, response.body}
  end

  defp post!(url, headers, body) do
    Req.post!(url, json: body, headers: headers, retry: false, receive_timeout: 120_000).body
  end
end
