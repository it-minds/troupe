defmodule Troupe.Plane.Web.Router do
  @moduledoc """
  The plane's HTTP surface, which is deliberately small.

      GET  /healthz                    liveness, for Kubernetes
      GET  /.well-known/troupe         where to log in, and what to call this plane
      GET  /.well-known/jwks.json      the keys workers verify session tokens against
      POST /rpc                        the harness JSON-RPC (§ Plane API)
      *    /scim/v2/...                users and groups, pushed by the identity provider

  Everything a person's client does goes through `/rpc`, and everything `/rpc` does goes
  through `Troupe.Plane.Harness`. That is the "any client, including our own, uses
  nothing but public APIs" rule made structural: there is no second path into the plane
  for the TUI to take.

  **No session content passes through here.** `/rpc` lists sessions and hands out
  endpoints and tokens; the stream of what a session is doing goes straight to the pod.
  """

  use Plug.Router

  alias Troupe.Plane.{Harness, Identity, OIDC, SCIM, Tokens}
  alias Troupe.Protocol.{Error, JSONRPC, Token}

  require Logger

  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: Jason
  plug :dispatch

  get "/healthz", do: send_json(conn, 200, %{"ok" => true})

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
  post "/auth/exchange" do
    case OIDC.exchange(conn.body_params["id_token"] || "") do
      {:ok, session} ->
        send_json(conn, 200, session)

      {:error, reason} ->
        Logger.info("troupe plane: refused a login: #{inspect(reason)}")
        send_json(conn, 401, %{"error" => "unauthenticated", "reason" => to_string(inspect(reason))})
    end
  end

  post "/rpc" do
    case authenticate(conn) do
      {:ok, user} -> send_json(conn, 200, answer(conn.body_params, user))
      {:error, error} -> send_json(conn, 401, JSONRPC.encode({:error, id_of(conn.body_params), error}) |> Jason.decode!())
    end
  end

  # SCIM is pushed by the identity provider with its own bearer token, which is a
  # different credential from a person's: this endpoint never sees a user token and a
  # user token never reaches it.
  match "/scim/v2/*rest" do
    if scim_authorised?(conn) do
      scim(conn, rest)
    else
      send_json(conn, 401, %{"schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"], "status" => "401"})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  # -- the harness API --------------------------------------------------------

  defp answer(%{"method" => method} = request, user) do
    params = Map.get(request, "params", %{})
    context = %{user: user, platform_admin?: platform_admin?(user)}

    case Harness.call(method, params, context) do
      {:ok, result} -> encoded({:result, request["id"], result})
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

  # A plane token, minted at login, whose audience is this plane rather than a pod. The
  # same verifier workers use, because a token that two components disagree about is a
  # token nobody can reason about.
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

  defp platform_admin?(user) do
    group = Application.get_env(:troupe_plane, :platform_admin_group)

    group != nil and
      user |> Identity.teams_for() |> Enum.any?(&(&1.name == group))
  end

  # -- SCIM -------------------------------------------------------------------

  defp scim(conn, ["Users"]) do
    case conn.method do
      "POST" -> scim_put_user(conn)
      "GET" -> send_json(conn, 200, SCIM.render_list(Enum.map(Identity.list_users(), &SCIM.render_user/1)))
      _ -> send_json(conn, 405, %{"status" => "405"})
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
      "POST" -> scim_put_group(conn)
      "GET" -> send_json(conn, 200, SCIM.render_list(Enum.map(Identity.list_groups(), &SCIM.render_group/1)))
      _ -> send_json(conn, 405, %{"status" => "405"})
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
