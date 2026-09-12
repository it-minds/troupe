defmodule Troupe.A2A.Router do
  @moduledoc """
  The facade's HTTP surface.

      GET  /healthz                                    liveness, for Kubernetes
      GET  /a2a/<profile>/.well-known/agent-card.json  the agent card; no token needed
      POST /a2a/<profile>                              A2A JSON-RPC, as the caller
      GET  /a2a/tasks/<id>/artifacts/<hash>            an artifact's bytes, as the caller

  Every request but the card and the health check carries a credential, and every
  such request is answered as the principal that credential names — exchanged at the
  plane, cached until shortly before it expires, never held for longer. There is no
  route the facade answers with a credential of its own.

  The card needs none, and without one it is rendered from the URL alone: the name,
  where to call, how to authenticate, and one skill named for the profile. With a
  credential — on the same `GET`, or through `agent/getAuthenticatedExtendedCard` — it
  carries the bundle's skills and version, which the plane will only describe to a
  principal that may use the profile. That is the A2A extended card, and it is what
  keeps "the card is public" and "the facade holds no credential" both true.
  """

  use Plug.Router

  alias Troupe.A2A.{Artifacts, Auth, Card, Error, HTTP, Plane, Stream, Tasks}
  alias Troupe.Protocol.JSONRPC

  require Logger

  plug(:match)

  # One mebibyte. An A2A message is a prompt and a few parts; a caller with a file to
  # hand the agent puts it somewhere the agent can fetch it and says where.
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason, length: 1_048_576)
  plug(:dispatch)

  get("/healthz", do: HTTP.json(conn, 200, %{"ok" => true}))

  get "/a2a/tasks/:task_id/artifacts/:hash" do
    as_caller(conn, nil, fn caller -> Artifacts.serve(conn, caller, task_id, hash) end)
  end

  get "/a2a/:profile/.well-known/agent-card.json" do
    case Auth.credential(conn) do
      :error ->
        HTTP.json(conn, 200, Card.public(profile))

      {:ok, _credential} ->
        as_caller(conn, nil, fn caller ->
          case Plane.profile(caller, profile) do
            {:ok, row} -> HTTP.json(conn, 200, Card.build(row))
            {:error, error} -> HTTP.json(conn, 404, Error.from_plane(error, nil))
          end
        end)
    end
  end

  post "/a2a/:profile" do
    as_caller(conn, id_of(conn.body_params), fn caller -> rpc(conn, caller, profile) end)
  end

  match _ do
    HTTP.json(conn, 404, %{"error" => "not found"})
  end

  # -- JSON-RPC -----------------------------------------------------------------

  defp rpc(conn, caller, profile) do
    case JSONRPC.from_map(conn.body_params) do
      {:ok, {:request, id, method, params}} ->
        handle(conn, caller, profile, id, method, params)

      {:ok, {:notification, method, _params}} ->
        HTTP.error(conn, nil, Error.invalid_request("#{method} was sent without an id"))

      {:ok, _response} ->
        HTTP.error(conn, nil, Error.invalid_request("expected a request"))

      {:error, error} ->
        HTTP.error(conn, id_of(conn.body_params), Error.invalid_request(error.message))
    end
  end

  defp handle(conn, caller, profile, id, "message/send", params),
    do: answer(conn, id, Tasks.send(caller, profile, params))

  defp handle(conn, caller, profile, id, "message/stream", params),
    do: Stream.serve_send(conn, caller, profile, id, params)

  defp handle(conn, caller, _profile, id, "tasks/get", params),
    do: answer(conn, id, Tasks.get(caller, params))

  defp handle(conn, caller, _profile, id, "tasks/cancel", params),
    do: answer(conn, id, Tasks.cancel(caller, params))

  defp handle(conn, caller, _profile, id, "tasks/resubscribe", params),
    do: Stream.serve_resubscribe(conn, caller, id, params)

  defp handle(conn, _caller, _profile, id, "tasks/pushNotificationConfig/" <> _rest, _params),
    do: HTTP.error(conn, id, Error.push_unsupported())

  defp handle(conn, caller, profile, id, "agent/getAuthenticatedExtendedCard", _params) do
    case Plane.profile(caller, profile) do
      {:ok, row} -> HTTP.result(conn, id, Card.build(row))
      {:error, error} -> HTTP.error(conn, id, Error.from_plane(error, nil))
    end
  end

  defp handle(conn, _caller, _profile, id, method, _params),
    do: HTTP.error(conn, id, Error.method_not_found(method))

  defp answer(conn, id, {:ok, result}), do: HTTP.result(conn, id, result)
  defp answer(conn, id, {:error, error}), do: HTTP.error(conn, id, error)

  # -- who is calling -----------------------------------------------------------

  defp as_caller(conn, id, fun) do
    with {:ok, credential} <- Auth.credential(conn),
         {:ok, caller} <- Plane.exchange(credential) do
      fun.(caller)
    else
      :error ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", ~s(Bearer realm="troupe-a2a"))
        |> HTTP.error(401, id, Error.unauthenticated("no credential"))

      {:error, :unauthenticated} ->
        HTTP.error(conn, 401, id, Error.unauthenticated("the plane refused the credential"))

      {:error, :unavailable} ->
        Logger.warning("troupe a2a: the plane did not answer /auth/exchange")
        HTTP.error(conn, 502, id, Error.plane_unavailable("the plane did not answer"))
    end
  end

  defp id_of(%{"id" => id}), do: id
  defp id_of(_params), do: nil
end
