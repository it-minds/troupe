defmodule Troupe.Plane.Web.Router do
  @moduledoc """
  The plane's HTTP surface, which is deliberately small.

      GET  /                           the connection guide, for a browser
      GET  /healthz                    liveness, for Kubernetes
      GET  /.well-known/troupe         where to log in, and what to call this plane
      GET  /.well-known/jwks.json      the keys workers verify session tokens against
      GET  /.well-known/oauth-protected-resource
                                       which provider an MCP client should authenticate to
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
  alias Troupe.Plane.Web.Index
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

  # The root, which every other route is a poor answer for. A person handed this URL and
  # told it is their plane arrives here first, and a `404` is the least it could say: the
  # page names the three clients and writes their commands against this plane's own URL.
  # Anything a machine wants is at `/.well-known/troupe`, which is what the page points at.
  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      Index.render(name: config(:plane_name, "troupe"), url: base_url(conn), app_url: app_url())
    )
  end

  get("/healthz", do: send_json(conn, 200, %{"ok" => true}))

  # What a client asks the provider for, and nothing beyond it.
  #
  # These four are OIDC's own scopes, which every provider understands. Group membership
  # is *not* among them: a group claim is a property of the token the provider is
  # configured to issue, not something a client asks for. Microsoft Entra says so by
  # refusing the request outright — `AADSTS650053: the application asked for scope
  # 'groups' that doesn't exist on the resource` — which fails every sign-in, the CLI's
  # device grant included, before anybody types a password. Whichever claim carries
  # groups is `TROUPE_GROUPS_CLAIM`, and it is read from the token.
  #
  # `TROUPE_OIDC_SCOPES` overrides this for a provider that wants something else.
  @default_scopes ["openid", "profile", "email", "offline_access"]

  # What a client needs to know before it has an identity: which provider to talk to,
  # which client id to use, and what this plane calls itself.
  get "/.well-known/troupe" do
    send_json(conn, 200, %{
      "issuer" => config(:issuer),
      "client_id" => config(:client_id),
      "device_authorization_endpoint" => config(:device_authorization_endpoint),
      "token_endpoint" => config(:token_endpoint),
      "scopes" => config(:scopes, @default_scopes),
      "plane" => %{
        "name" => config(:plane_name, "troupe"),
        "rpc" => "/rpc",
        "jwks" => "/.well-known/jwks.json",
        "protocol_version" => Troupe.Protocol.version()
      }
    })
  end

  # RFC 9728, which is how an MCP client finds out where to authenticate. It asks this
  # plane; this plane names the identity provider and gets out of the way. Troupe is a
  # resource server here and deliberately not an authorization server: running one would
  # mean holding a second set of credentials for the same people, and the whole identity
  # arrangement is that the provider is the only thing that authenticates anybody.
  #
  # Two paths for one document. A client derives the location from the resource URL by
  # inserting the well-known segment before the path — `/mcp` becomes
  # `/.well-known/oauth-protected-resource/mcp` — and the bare path is what a client that
  # has only the origin asks for. Both answer, because a client that guesses wrong should
  # not be told there is no metadata when there is.
  get("/.well-known/oauth-protected-resource", do: send_json(conn, 200, resource_metadata()))
  get("/.well-known/oauth-protected-resource/mcp", do: send_json(conn, 200, resource_metadata()))

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
    case authenticate_tool_caller(conn) do
      {:ok, user} ->
        case Admin.MCP.handle(conn.body_params, Admin.actor_for(user)) do
          {:reply, message} -> send_json(conn, 200, message)
          :noreply -> send_resp(conn, 202, "")
        end

      {:error, error} ->
        # The `resource_metadata` parameter is what turns a 401 into an instruction: a
        # client that has never seen this server reads it, fetches the document, and knows
        # which provider to authenticate to. Without it the only thing a 401 says is no.
        conn
        |> put_resp_header("www-authenticate", www_authenticate())
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

  # -- who is calling /mcp ------------------------------------------------------

  # Two kinds of caller, one endpoint. `troupe mcp` bridges a *plane* token, because the
  # CLI already holds credentials and exchanging them is what it does. Any other MCP
  # client does OAuth against the identity provider, the way the specification says a
  # client should, and arrives with what the provider gave it — there is no step in that
  # flow where it could obtain a plane token, and inventing one would mean this server
  # running an authorization server of its own.
  #
  # A plane token is tried first because it is the cheaper check and the commoner caller.
  # Both are verified in full; the difference is who signed them, not how much is trusted.
  defp authenticate_tool_caller(conn) do
    case bearer(conn) do
      {:ok, jwt} ->
        case authenticate(conn) do
          {:ok, user} -> {:ok, user}
          {:error, _plane_token} -> from_provider(jwt)
        end

      {:error, :no_token} ->
        {:error, Error.new(:unauthenticated, %{reason: "no token"})}
    end
  end

  defp from_provider(jwt) do
    case OIDC.authenticate(jwt) do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, Error.new(:unauthenticated, %{reason: inspect(reason)})}
    end
  end

  defp www_authenticate do
    case plane_url() do
      nil ->
        ~s(Bearer realm="troupe-plane")

      base ->
        ~s(Bearer realm="troupe-plane", resource_metadata="#{base}/.well-known/oauth-protected-resource")
    end
  end

  # What an MCP client needs and nothing it does not: the resource it is talking to, the
  # provider that issues tokens for it, and the scope to ask for. The scope is the API this
  # registration exposes rather than a plain OIDC scope, because an access token addressed
  # to Microsoft Graph is not a token this plane will accept, and asking for `openid` alone
  # is how a client ends up with one.
  defp resource_metadata do
    base = plane_url()

    %{
      "resource" => "#{base}/mcp",
      "authorization_servers" => List.wrap(config(:issuer)),
      "scopes_supported" => scopes_supported(),
      "bearer_methods_supported" => ["header"],
      "resource_documentation" => "#{base}/admin"
    }
    |> Map.reject(fn {_key, value} -> value in [nil, [], ""] end)
  end

  # The plane's own URL, which is not one of the provider's settings: `config/2` reads
  # the `:oidc` list and this lives beside it.
  defp plane_url, do: Application.get_env(:troupe_plane, :base_url)

  # -- the index page ---------------------------------------------------------

  # What the index writes its commands against. `TROUPE_BASE_URL` where a deployment set
  # one, because that is the name the plane is reached by and the one behind the Ingress
  # knows nothing about; the request's own scheme and host otherwise, so a plane run
  # without it still prints a URL that works rather than `nil`.
  defp base_url(conn) do
    case plane_url() do
      nil -> "#{conn.scheme}://#{host_with_port(conn)}"
      base -> String.trim_trailing(base, "/")
    end
  end

  defp host_with_port(%Plug.Conn{scheme: :http, port: 80} = conn), do: conn.host
  defp host_with_port(%Plug.Conn{scheme: :https, port: 443} = conn), do: conn.host
  defp host_with_port(conn), do: "#{conn.host}:#{conn.port}"

  # Where the GUI is mounted, which is a *separate* release: the plane cannot tell whether
  # one is there. `/app` is where its chart mounts it by default, and `TROUPE_APP_URL=""`
  # is how a plane that ships without one says so rather than offering a door to a 404.
  defp app_url do
    case Application.get_env(:troupe_plane, :app_url, "/app") do
      "" -> nil
      url -> url
    end
  end

  # The scope a client asks for, named after the *resource* rather than after the client.
  #
  # MCP's authorization specification obliges a client to send RFC 8707's `resource`
  # parameter set to this server's canonical URI, and a provider checks that against the
  # resource the scopes belong to. Advertising `api://<client-id>/admin` while the client
  # is required to send `https://<plane>/mcp` is a pair no provider will accept — Entra
  # refuses it with AADSTS9010010 — so the scope is addressed by the same name as the
  # resource, and the registration carries that name too.
  #
  # `TROUPE_OIDC_MCP_SCOPE` is for a deployment whose registration names it something else.
  defp scopes_supported do
    case config(:mcp_scope) || default_mcp_scope() do
      nil ->
        []

      scope ->
        # `offline_access` so the client is given a refresh token: without it a session
        # ends in an hour and the operator is sent back to a browser mid-task.
        [scope, "offline_access"]
    end
  end

  defp default_mcp_scope do
    case plane_url() do
      nil -> nil
      base -> "#{base}/mcp/admin"
    end
  end

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
