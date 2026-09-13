defmodule Troupe.Plane.Web.Router do
  @moduledoc """
  The plane's HTTP surface, which is deliberately small.

      GET  /healthz                    liveness, for Kubernetes
      GET  /.well-known/troupe         where to log in, and what to call this plane
      GET  /.well-known/jwks.json      the keys workers verify session tokens against
      POST /rpc                        the harness JSON-RPC (§ Plane API)
      POST /mcp                        the same admin methods, as MCP tools
      *    /scim/v2/...                users and groups, pushed by the identity provider

  Everything a person's client does goes through `/rpc`, and everything `/rpc` does goes
  through `Troupe.Plane.Harness`. That is the "any client, including our own, uses
  nothing but public APIs" rule made structural: there is no second path into the plane
  for the TUI to take.

  **No session content passes through here.** `/rpc` lists sessions and hands out
  endpoints and tokens; the stream of what a session is doing goes straight to the pod.
  """

  use Plug.Router

  alias Troupe.Plane.{Admin, Harness, Identity, OIDC, Principals, SCIM, Tokens}
  alias Troupe.Plane.Admin.API, as: AdminAPI
  alias Troupe.Protocol.{Error, JSONRPC, Token}

  require Logger

  # Before `:match`, so a preflight is answered without ever reaching a route — there
  # is no `options` route to reach, and the 404 it would otherwise get is what a browser
  # reports as a CORS failure.
  plug(Troupe.Plane.Web.CORS)
  plug(:match)

  # Four mebibytes. The largest legitimate body here is not a `session.create` with a
  # long prompt, which is kilobytes, but `admin.bundle.publish`: a config bundle carries
  # its agent definitions and skills inline, and one with a few skills' worth of text
  # runs well past 256 KiB. Anything larger than this is not a request the plane has a
  # method for, and reading it before finding that out would be the plane buffering a
  # stranger's upload.
  plug(Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason, length: 4_194_304)
  plug(:dispatch)

  get("/healthz", do: send_json(conn, 200, %{"ok" => true}))

  # What a client needs to know before it has an identity: which provider to talk to,
  # which client id to use, and what this plane calls itself.
  get "/.well-known/troupe" do
    send_json(conn, 200, %{
      "issuer" => config(:issuer),
      "client_id" => config(:client_id),
      "device_authorization_endpoint" => config(:device_authorization_endpoint),
      "token_endpoint" => config(:token_endpoint),
      "scopes" => config(:scopes, ["openid", "profile", "email", "offline_access", "groups"]),
      "plane" => %{
        "name" => config(:plane_name, "troupe"),
        "rpc" => "/rpc",
        "jwks" => "/.well-known/jwks.json",
        "protocol_version" => Troupe.Protocol.version()
      }
    })
  end

  get "/.well-known/jwks.json" do
    case Tokens.jwks() do
      {:ok, jwks} -> send_json(conn, 200, jwks)
      {:error, reason} -> send_json(conn, 503, %{"error" => inspect(reason)})
    end
  end

  # A provider token in, a plane token out. The plane never sees the user's provider
  # credentials: the device grant runs against the identity provider directly and only
  # its result comes here.
  #
  # Two body shapes, one answer. `{"id_token"}` is a person; `{"client_id",
  # "client_secret"}` is a service principal presenting the secret the plane minted for
  # it. Both come out as the same plane token, so nothing downstream cares which.
  post "/auth/exchange" do
    case exchange(conn.body_params) do
      {:ok, session} ->
        send_json(conn, 200, session)

      {:error, reason} ->
        Logger.info("troupe plane: refused a login: #{inspect(reason)}")

        send_json(conn, 401, %{
          "error" => "unauthenticated",
          "reason" => to_string(inspect(reason))
        })
    end
  end

  post "/rpc" do
    case authenticate(conn) do
      {:ok, user} ->
        send_json(conn, 200, answer(conn.body_params, user))

      {:error, error} ->
        send_json(
          conn,
          401,
          JSONRPC.encode({:error, id_of(conn.body_params), error}) |> Jason.decode!()
        )
    end
  end

  # The admin surface as MCP tools. The same token as `/rpc`, resolved to the same actor,
  # dispatched through the same table — an operator's model gets exactly what an operator
  # gets, and a principal's token administers exactly what that principal may.
  #
  # Streamable HTTP with no session: a notification is answered with 202 and no body,
  # which is what the transport asks for, and everything else with one JSON object.
  post "/mcp" do
    case authenticate(conn) do
      {:ok, user} ->
        case Admin.MCP.handle(conn.body_params, Admin.actor_for(user)) do
          {:reply, message} -> send_json(conn, 200, message)
          :noreply -> send_resp(conn, 202, "")
        end

      {:error, error} ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="troupe-plane"))
        |> send_json(401, %{"error" => "unauthenticated", "reason" => error.message})
    end
  end

  # No server-initiated stream and no session to end. Both are optional in the transport,
  # and answering them with a 405 is how a client is told so.
  get("/mcp", do: send_json(conn, 405, %{"error" => "this server does not stream"}))
  delete("/mcp", do: send_json(conn, 405, %{"error" => "this server has no sessions to end"}))

  # SCIM is pushed by the identity provider with its own bearer token, which is a
  # different credential from a person's: this endpoint never sees a user token and a
  # user token never reaches it.
  match "/scim/v2/*rest" do
    if scim_authorised?(conn) do
      scim(conn, rest)
    else
      send_json(conn, 401, %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
        "status" => "401"
      })
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  # -- the harness API --------------------------------------------------------

  defp answer(%{"method" => method} = request, user) do
    params = Map.get(request, "params", %{})

    # One endpoint, two contexts. An admin method is answered by `Plane.Admin` with an
    # admin actor; everything else by `Plane.Harness` as the person. A client that used
    # `/rpc` for both is a client using public APIs for both, which is the rule.
    result =
      if AdminAPI.admin_method?(method) do
        AdminAPI.call(method, params, Admin.actor_for(user))
      else
        Harness.call(method, params, %{user: user, platform_admin?: platform_admin?(user)})
      end

    case result do
      {:ok, answer} -> encoded({:result, request["id"], answer})
      {:error, %Error{} = error} -> encoded({:error, request["id"], error})
    end
  end

  defp answer(request, _user) do
    encoded({:error, id_of(request), Error.new(:invalid_request, %{reason: "no method"})})
  end

  defp encoded(message), do: message |> JSONRPC.encode() |> Jason.decode!()

  defp id_of(params) when is_map(params), do: Map.get(params, "id")
  defp id_of(_params), do: nil

  # -- who is calling ---------------------------------------------------------

  defp exchange(%{"client_id" => client_id} = body) when is_binary(client_id) do
    Principals.exchange(client_id, body["client_secret"] || "")
  end

  defp exchange(body) when is_map(body), do: OIDC.exchange(body["id_token"] || "")
  defp exchange(_body), do: {:error, :no_token}

  # A plane token, minted at login, whose audience is this plane rather than a pod. The
  # same verifier workers use, because a token that two components disagree about is a
  # token nobody can reason about. The subject is resolved on every request — a person
  # to their row, a `svc:` subject to its principal — so a principal disabled a minute
  # ago is refused now rather than when its token expires.
  defp authenticate(conn) do
    with {:ok, jwt} <- bearer(conn),
         {:ok, jwks} <- Tokens.jwks(),
         {:ok, claims} <- Token.verify(jwt, jwks, audience: plane_audience()),
         %Identity.User{} = user <- Identity.get_user(claims["sub"]) do
      {:ok, user}
    else
      nil -> {:error, Error.new(:unauthenticated, %{reason: "no such user"})}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:unauthenticated, %{reason: to_string(reason)})}
    end
  end

  defp bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, token}
      ["bearer " <> token | _] -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end

  defp platform_admin?(user), do: Admin.actor_for(user).role == :platform_admin

  # -- SCIM -------------------------------------------------------------------

  defp scim(conn, ["Users"]) do
    case conn.method do
      "POST" ->
        scim_put_user(conn)

      "GET" ->
        send_json(
          conn,
          200,
          SCIM.render_list(Enum.map(Identity.list_users(), &SCIM.render_user/1))
        )

      _ ->
        send_json(conn, 405, %{"status" => "405"})
    end
  end

  defp scim(conn, ["Users", id]) do
    case conn.method do
      "DELETE" ->
        SCIM.deactivate_user(id)
        send_resp(conn, 204, "")

      "GET" ->
        case Identity.get_user(id) do
          nil -> send_json(conn, 404, %{"status" => "404"})
          user -> send_json(conn, 200, SCIM.render_user(user))
        end

      _ ->
        scim_put_user(conn)
    end
  end

  defp scim(conn, ["Groups"]) do
    case conn.method do
      "POST" ->
        scim_put_group(conn)

      "GET" ->
        send_json(
          conn,
          200,
          SCIM.render_list(Enum.map(Identity.list_groups(), &SCIM.render_group/1))
        )

      _ ->
        send_json(conn, 405, %{"status" => "405"})
    end
  end

  defp scim(conn, ["Groups", _id]), do: scim_put_group(conn)
  defp scim(conn, _rest), do: send_json(conn, 404, %{"status" => "404"})

  defp scim_put_user(conn) do
    case SCIM.put_user(conn.body_params) do
      {:ok, user} -> send_json(conn, 200, SCIM.render_user(user))
      {:error, reason} -> send_json(conn, 400, %{"status" => "400", "detail" => inspect(reason)})
    end
  end

  defp scim_put_group(conn) do
    case SCIM.put_group(conn.body_params) do
      {:ok, group} -> send_json(conn, 200, SCIM.render_group(group, Identity.members_of(group)))
      {:error, reason} -> send_json(conn, 400, %{"status" => "400", "detail" => inspect(reason)})
    end
  end

  defp scim_authorised?(conn) do
    case {Application.get_env(:troupe_plane, :scim_token), bearer(conn)} do
      {nil, _} -> false
      {expected, {:ok, presented}} -> constant_time_equal?(expected, presented)
      _ -> false
    end
  end

  defp constant_time_equal?(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp constant_time_equal?(_a, _b), do: false

  # -- plumbing ---------------------------------------------------------------

  @doc false
  @spec plane_audience() :: String.t()
  def plane_audience, do: OIDC.audience()

  defp config(key, default \\ nil) do
    Application.get_env(:troupe_plane, :oidc, [])[key] || default
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
