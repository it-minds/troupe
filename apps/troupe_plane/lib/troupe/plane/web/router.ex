defmodule Troupe.Plane.Web.Router do
  @moduledoc """
  The plane's HTTP surface, which is deliberately small.

      GET  /                           the connection guide, for a browser
      GET  /docs                       what Troupe is, for a browser
      GET  /healthz                    liveness, for Kubernetes
      GET  /.well-known/troupe         where to log in, and what to call this plane
      GET  /.well-known/jwks.json      the keys workers verify session tokens against
      GET  /.well-known/troupe-signing-key
                                       the key this plane signs what it tells clients with
      GET  /downloads/v<version>/<file>
                                       a release's files, from the object store
      GET  /.well-known/oauth-protected-resource
                                       which provider an MCP client should authenticate to
      POST /rpc                        the harness JSON-RPC (§ Plane API)
      POST /trigger/<id>               fire one trigger, with that trigger's own key
      POST /webhook/github             the GitHub App's events, signed with its webhook secret
      POST /mcp                        the same admin methods, as MCP tools
      POST /mcp/session                four of them, for an agent already inside
      *    /scim/v2/...                users and groups, pushed by the identity provider
      GET  /v1/relay                   a laptop's connection while it offers sessions
      GET  /v1/relay/session           a person steering one of them from another device
      POST /auth/relay                 a laptop daemon's own grant, for that connection's token
      POST /auth/relay/release         the daemon letting the grant go

  Everything a person's client does goes through `/rpc`, and everything `/rpc` does goes
  through `Troupe.Plane.Harness`. That is the "any client, including our own, uses
  nothing but public APIs" rule made structural: there is no second path into the plane
  for the TUI to take.

  **No pod session's content passes through here.** `/rpc` lists sessions and hands out
  endpoints and tokens; the stream of what a session is doing goes straight to the pod.
  The one exception is a laptop's session its person offered for steering from another
  device: the laptop dials out and nothing can dial in, so the plane relays its messages
  between the two sockets under `/v1/relay`, checks each, and keeps none
  (`Troupe.Plane.Remote`).
  """

  use Plug.Router

  alias Troupe.ObjectStore

  alias Troupe.Plane.{
    Admin,
    Build,
    Harness,
    Identity,
    OIDC,
    Principals,
    Remote,
    SCIM,
    Settings,
    Signing,
    Tokens,
    Triggers
  }

  alias Troupe.Plane.Admin.API, as: AdminAPI
  alias Troupe.Plane.GitHub.Webhook, as: GitHubWebhook
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Web.{BodyLimit, Docs, Index, RawBody}
  alias Troupe.Protocol.{ClientUpdate, Error, JSONRPC, Token}

  require Logger

  # Before `:match`, so a preflight is answered without ever reaching a route — there
  # is no `options` route to reach, and the 404 it would otherwise get is what a browser
  # reports as a CORS failure.
  plug(Troupe.Plane.Web.CORS)
  plug(:match)

  # Behind the endpoint the body is read already, under the plane's one limit
  # (`BodyLimit`); this is for the router mounted alone, under the same one.
  #
  # Read through `RawBody`, which keeps the bytes as they came for the GitHub App's
  # webhook, whose signature is over them.
  plug(BodyLimit)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: BodyLimit.bytes(),
    body_reader: {Troupe.Plane.Web.RawBody, :read_body, []}
  )

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
      Index.render(
        name: config(:plane_name, "troupe"),
        url: base_url(conn),
        app_url: app_url(),
        cli_url: cli_url(),
        console_url: Index.console_url()
      )
    )
  end

  # The other half of the front door. `/` says what this host is and how to point a client
  # at it; this says what any of that means, in pictures, for the person who was handed
  # the URL and has not decided to read anything yet. It discloses nothing `/` does not —
  # the concepts are the product's, and the only surface it names is the one the endpoint
  # table on `/` already lists.
  get "/docs" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(
      200,
      Docs.render(name: config(:plane_name, "troupe"), url: base_url(conn), app_url: app_url())
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
        # The key what it tells clients is signed with (#657), which they pin at sign-in.
        "signing_key" => "/.well-known/troupe-signing-key",
        # Where the web app is, for `troupe-daemon open` (Decision 802): null without one.
        "app" => app_address(conn),
        "protocol_version" => Troupe.Protocol.version(),
      # The same facts the footer shows, so a deploy check and a browser cannot disagree.
      "build" => Build.to_json()
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

  # The plane's own signing key, which a client pins at sign-in and holds every signed
  # answer to after (`Signing`): its public half and fingerprint, made on first use.
  get "/.well-known/troupe-signing-key" do
    case Signing.published() do
      {:ok, key} -> send_json(conn, 200, key)
      {:error, reason} -> send_json(conn, 503, %{"error" => inspect(reason)})
    end
  end

  # A release's files, for machines that cannot reach GitHub: the plane names
  # `<this plane>/downloads` as where releases are (`client_release_url`), and the files are
  # copied into its object store under `releases/v<version>/` (`Releases.mirror/2`).
  # Answered with a short-lived presigned URL rather than the bytes, so the plane stays out
  # of the path of a download as it is of a session's; anybody may fetch one, as from
  # GitHub, because the release key's signature is the check.
  #
  # A file that is there is handed out and anything else is a bare 404, whatever the version
  # policy says of it: a 404 that differed for a blocked version would tell anybody without
  # a sign-in which versions are refused, which only the signed, signed-in answer says. A
  # client never installs a version the policy it holds refuses.
  get "/downloads/:tag/:file" do
    key = "releases/#{tag}/#{file}"
    store = ObjectStore.from_env()

    with "v" <> version <- tag,
         true <- ClientUpdate.version?(version),
         true <- file =~ ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/,
         true <- ObjectStore.exists?(store, key) do
      conn
      |> put_resp_header("location", ObjectStore.presign(store, :get, key, ttl: 300))
      |> send_resp(302, "")
    else
      _not_here -> send_resp(conn, 404, "")
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

  # A laptop's daemon's own sign-in for steering (#58): the grant `remote.grant` gave it,
  # for a token of the laptop's door alone, `/v1/relay`. A grant the plane does not hold,
  # one released or idle too long, is 401; one whose person's team forbids offering, 403.
  post "/auth/relay" do
    case Remote.redeem(conn.body_params["grant"]) do
      {:ok, answer} ->
        send_json(conn, 200, answer)

      {:error, %Error{message: message, data: data}} ->
        status =
          case message do
            "forbidden" -> 403
            "unavailable" -> 503
            _unauthenticated -> 401
          end

        send_json(conn, status, %{"error" => message, "reason" => (data || %{})[:reason]})
    end
  end

  # The daemon lets its grant go. Always 204: a grant the plane does not hold has nothing
  # left to release, and saying which would answer whether a guess was a grant.
  post "/auth/relay/release" do
    :ok = Remote.release(conn.body_params["grant"])
    send_resp(conn, 204, "")
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

  # The other projection: four methods for the agent that is already inside the system,
  # rather than forty for the person administering it. The same bearer token, resolved to
  # the same person or principal, dispatched through `Harness` — so what an agent may do
  # here is exactly what its credential may do at `/rpc`, and there is no second opinion
  # about that anywhere.
  post "/mcp/session" do
    case authenticate(conn) do
      {:ok, user} ->
        # The door vouches for the source. An agent calling `trigger_fire` here is an
        # `agent` firing, which a caller at `/rpc` may not claim for itself.
        context = %{
          user: user,
          platform_admin?: platform_admin?(user),
          vouched_source: "agent"
        }

        case Harness.MCP.handle(conn.body_params, context) do
          {:reply, message} -> send_json(conn, 200, message)
          :noreply -> send_resp(conn, 202, "")
        end

      {:error, error} ->
        conn
        |> put_resp_header("www-authenticate", www_authenticate())
        |> send_json(401, %{"error" => "unauthenticated", "reason" => error.message})
    end
  end

  get("/mcp/session", do: send_json(conn, 405, %{"error" => "this server does not stream"}))

  delete("/mcp/session",
    do: send_json(conn, 405, %{"error" => "this server has no sessions to end"})
  )

  # No server-initiated stream and no session to end. Both are optional in the transport,
  # and answering them with a 405 is how a client is told so.
  get("/mcp", do: send_json(conn, 405, %{"error" => "this server does not stream"}))
  delete("/mcp", do: send_json(conn, 405, %{"error" => "this server has no sessions to end"}))

  # A trigger's own door. The credential is the trigger's key and nothing else: it fires
  # this one trigger and can do nothing at all besides, which is what makes it the thing
  # to put in a CI secret store. Everything a person's token can do stays at `/rpc`.
  #
  # Stateless, so any replica answers — the scheduler is the singleton, this is not.
  #
  # `202`, not `200`: what this returns is a run, and a run is a session somebody else
  # will finish. A caller that waited for a result would be waiting for a model.
  post "/trigger/:id" do
    case fire_from_webhook(conn, id) do
      {:ok, fired} -> send_json(conn, 202, fired)
      {:error, error} -> send_json(conn, webhook_status(error), error_json(error))
    end
  end

  # The GitHub App's webhook (`GitHub.Webhook`). The credential is the signature over the
  # body, under the App's webhook secret; nothing else is asked of the caller. A delivery is
  # answered as soon as it is checked and recorded, `202`, and worked afterwards; one already
  # taken is `200`, and does nothing again.
  post "/webhook/github" do
    {body, conn} = raw_body(conn)

    case GitHubWebhook.take(body, Map.new(conn.req_headers)) do
      {:ok, :accepted} ->
        send_json(conn, 202, %{"accepted" => true})

      {:ok, :duplicate} ->
        send_json(conn, 200, %{"accepted" => true, "duplicate" => true})

      {:error, reason} when reason in [:unsigned, :mismatch] ->
        send_json(conn, 401, %{"error" => "unauthenticated"})

      {:error, :malformed} ->
        send_json(conn, 400, %{"error" => "invalid_request"})

      {:error, _unverifiable} ->
        send_json(conn, 503, %{"error" => "unavailable"})
    end
  end

  # SCIM is pushed by the identity provider with its own bearer token, which is a
  # different credential from a person's: this endpoint never sees a user token and a
  # user token never reaches it.
  match "/scim/v2/*rest" do
    if scim_authorised?(conn) do
      # After the door and never before it: "last sync" is when the provider was heard
      # from, and somebody with the wrong token is not the provider.
      Connector.seen(conn.method <> " /" <> Enum.join(rest, "/"))
      scim(conn, rest)
    else
      send_json(conn, 401, %{
        "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
        "status" => "401"
      })
    end
  end

  # A laptop's one connection while it offers sessions for steering from another device
  # (#58). A daemon is not a browser and names no origin; a page that does is not a
  # laptop, whatever token it holds.
  get "/v1/relay" do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        conn
        |> WebSockAdapter.upgrade(Remote.Laptop, [bearer: bearer_or_nil(conn)],
          timeout: :timer.hours(24),
          # A viewer's message is at most a pod socket's ceiling, carried as a string.
          max_frame_size: 64 * 1024 * 1024
        )
        |> halt()

      _browser ->
        send_json(conn, 403, %{"error" => "origin not allowed"})
    end
  end

  # A person steering an offered session, with the token `remote.open` gave them. A page
  # is admitted from this plane's own origin, the desktop app's and those the CORS list
  # names, as `/rpc` answers them; a client that is not a browser names none.
  get "/v1/relay/session" do
    if relay_origin_allowed?(conn) do
      conn
      |> WebSockAdapter.upgrade(Remote.Viewer, [bearer: bearer_or_nil(conn)],
        timeout: :timer.hours(24),
        # A pod socket's ceiling, which the laptop's connection says at `initialize`.
        max_frame_size: 16 * 1024 * 1024
      )
      |> halt()
    else
      send_json(conn, 403, %{"error" => "origin not allowed"})
    end
  end

  # A person's watch on what is offered to them: the desktop app's and the console's list
  # of laptop sessions, told as it changes rather than asked again. The same pages are
  # admitted as at a viewer's door.
  get "/v1/relay/watch" do
    if relay_origin_allowed?(conn) do
      conn
      |> WebSockAdapter.upgrade(Remote.Watch, [bearer: bearer_or_nil(conn)],
        timeout: :timer.hours(24),
        max_frame_size: 64 * 1024
      )
      |> halt()
    else
      send_json(conn, 403, %{"error" => "origin not allowed"})
    end
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  @desktop_origins ["tauri://localhost", "http://tauri.localhost"]

  defp relay_origin_allowed?(conn) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        true

      [origin | _] ->
        own = conn |> base_url() |> URI.parse() |> then(&"#{&1.scheme}://#{&1.authority}")

        origin in [own | @desktop_origins] or
          origin in Application.get_env(:troupe_plane, :cors_origins, [])
    end
  end

  defp bearer_or_nil(conn) do
    case bearer(conn) do
      {:ok, token} -> token
      _none -> nil
    end
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

  # The same, as an address a program can open: resolved against this plane's own URL, as
  # a browser resolves the index's door.
  defp app_address(conn) do
    case app_url() do
      nil -> nil
      url -> URI.to_string(URI.merge(base_url(conn) <> "/", url))
    end
  end

  # Where the terminal client is published, which this host does not build and cannot
  # serve: it runs in a cluster and has no binary for anyone's laptop. Unset by default,
  # because a wrong guess here is a download link that 404s.
  defp cli_url do
    case Application.get_env(:troupe_plane, :cli_url, "") do
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
        # Plus the scopes a sign-in asks for, so the token an MCP client is minted carries
        # what a login's does — the groups claim above all. A client asks for what is
        # advertised and nothing else; advertised without `groups`, the token carried no
        # groups claim, and the plane read that as a person in no groups (`Login`).
        # `offline_access` so the client is given a refresh token: without it a session
        # ends in an hour and the operator is sent back to a browser mid-task.
        Enum.uniq([scope | List.wrap(config(:scopes))] ++ ["offline_access"])
    end
  end

  defp default_mcp_scope do
    case plane_url() do
      nil -> nil
      base -> "#{base}/mcp/admin"
    end
  end

  # -- SCIM -------------------------------------------------------------------

  # A provider asks with a filter before it creates anybody and changes what it pushed
  # with PATCH, and addresses a resource by the `id` this plane gave it (Decision 754).
  defp scim(conn, ["Users"]) do
    case conn.method do
      "POST" ->
        scim_put_user(conn, 201)

      "GET" ->
        case SCIM.find_users(conn.query_params["filter"]) do
          {:ok, users} ->
            send_json(conn, 200, SCIM.render_list(Enum.map(users, &SCIM.render_user/1)))

          {:error, reason} ->
            scim_error(conn, reason)
        end

      _ ->
        send_json(conn, 405, %{"status" => "405"})
    end
  end

  defp scim(conn, ["Users", id]) do
    case conn.method do
      "DELETE" ->
        scim_no_content(conn, SCIM.delete_user(id))

      "GET" ->
        case Identity.get_user_by_id(id) do
          nil -> scim_error(conn, :not_found)
          user -> send_json(conn, 200, SCIM.render_user(user))
        end

      "PATCH" ->
        case SCIM.patch_user(id, conn.body_params) do
          {:ok, user} -> send_json(conn, 200, SCIM.render_user(user))
          {:error, reason} -> scim_error(conn, reason)
        end

      _ ->
        scim_replace_user(conn, id)
    end
  end

  defp scim(conn, ["Groups"]) do
    case conn.method do
      "POST" ->
        scim_put_group(conn, 201)

      "GET" ->
        case SCIM.find_groups(conn.query_params["filter"]) do
          {:ok, groups} ->
            groups = Enum.map(groups, &SCIM.render_group_for(&1, conn.query_params))
            send_json(conn, 200, SCIM.render_list(groups))

          {:error, reason} ->
            scim_error(conn, reason)
        end

      _ ->
        send_json(conn, 405, %{"status" => "405"})
    end
  end

  defp scim(conn, ["Groups", id]) do
    case conn.method do
      "GET" -> scim_get_group(conn, id)
      "PATCH" -> scim_no_content(conn, SCIM.patch_group(id, conn.body_params))
      "DELETE" -> scim_no_content(conn, SCIM.delete_group(id))
      _ -> scim_put_group(conn, 200)
    end
  end

  defp scim(conn, _rest), do: send_json(conn, 404, %{"status" => "404"})

  defp scim_get_group(conn, id) do
    case Identity.get_group_by_id(id) do
      nil -> scim_error(conn, :not_found)
      group -> send_json(conn, 200, SCIM.render_group_for(group, conn.query_params))
    end
  end

  # A change to a group answers nothing but that it was made, as Entra's documented
  # responses do; a group's members are most of it. So does a delete, and an id the plane
  # does not have is a 404 either way (RFC 7644 §3.6).
  defp scim_no_content(conn, {:ok, _resource}), do: send_resp(conn, 204, "")
  defp scim_no_content(conn, {:error, reason}), do: scim_error(conn, reason)

  # SCIM's error body (RFC 7644 §3.12). Whatever a request asked that the plane cannot do
  # is a 400 that says so, never a 500 a provider would retry forever.
  defp scim_error(conn, :not_found),
    do: send_json(conn, 404, SCIM.render_error(404, nil, "no such resource"))

  # A value another resource holds is a conflict (§3.12).
  defp scim_error(conn, {"uniqueness", detail}),
    do: send_json(conn, 409, SCIM.render_error(409, "uniqueness", detail))

  defp scim_error(conn, {scim_type, detail}),
    do: send_json(conn, 400, SCIM.render_error(400, scim_type, detail))

  defp scim_error(conn, %Ecto.Changeset{} = changeset),
    do: send_json(conn, 400, SCIM.render_error(400, "invalidValue", inspect(changeset.errors)))

  # `201` for a `POST`, `200` for a `PUT` (RFC 7644 §3.3, §3.5.1). A push upserts on the
  # subject, so a `POST` of somebody the plane already has, who signed in first, is a
  # create as well: the provider asked for a resource, and it is where `Location` says.
  defp scim_put_user(conn, status) do
    case SCIM.put_user(conn.body_params) do
      {:ok, user} -> scim_resource(conn, status, SCIM.render_user(user))
      {:error, reason} -> scim_error(conn, reason)
    end
  end

  # A replace of the person at this id (RFC 7644 §3.5.1), so an id that names nobody is a
  # 404, as a GET of it is, and a body naming somebody else is refused rather than applied
  # to them. Without the first a provider replacing a person it had deleted made them
  # again; without the second its body chose whom it changed.
  defp scim_replace_user(conn, id) do
    case SCIM.replace_user(id, conn.body_params) do
      {:ok, user} -> send_json(conn, 200, SCIM.render_user(user))
      {:error, reason} -> scim_error(conn, reason)
    end
  end

  defp scim_put_group(conn, status) do
    case SCIM.put_group(conn.body_params) do
      {:ok, group} ->
        scim_resource(conn, status, SCIM.render_group(group, Identity.members_of(group)))

      {:error, reason} ->
        detail = if is_binary(reason), do: reason, else: inspect(reason)
        send_json(conn, 400, %{"status" => "400", "detail" => detail})
    end
  end

  # A create says where the resource now is, in `Location` and in its `meta.location`,
  # which are the same path.
  defp scim_resource(conn, 201, %{"meta" => %{"location" => location}} = resource) do
    conn
    |> put_resp_header("location", location)
    |> send_json(201, resource)
  end

  defp scim_resource(conn, status, resource), do: send_json(conn, status, resource)

  # Two doors, either of which opens: the token rotated from the console, kept as a hash
  # on the connector row, and the deployed `TROUPE_SCIM_TOKEN`, which stays the floor so
  # a plane provisioned before the row existed keeps working with no row at all.
  defp scim_authorised?(conn) do
    case bearer(conn) do
      {:ok, presented} -> Connector.authorised?(presented) or deployed_scim_token?(presented)
      _ -> false
    end
  end

  defp deployed_scim_token?(presented) do
    case Application.get_env(:troupe_plane, :scim_token) do
      nil -> false
      expected -> constant_time_equal?(expected, presented)
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

  # The provider's values are settings now — stored override, deployment as the floor —
  # so what this document publishes is what the console shows and what the check tested.
  # `:plane_name` is the one key here that was never about the provider and stays where
  # the deployment put it.
  @provider_settings ~w(issuer client_id authorization_endpoint device_authorization_endpoint token_endpoint scopes mcp_scope)a

  defp config(key, default \\ nil)

  defp config(key, default) when key in @provider_settings,
    do: Settings.get(Atom.to_string(key)) || default

  defp config(key, default), do: Application.get_env(:troupe_plane, :oidc, [])[key] || default

  # -- the GitHub App's webhook ---------------------------------------------

  # The bytes `Plug.Parsers` read and `RawBody` kept, for a JSON delivery; for any other
  # content type the parsers left the body unread, and it is read here, as large as they
  # would have taken.
  defp raw_body(conn) do
    case RawBody.of(conn) do
      nil ->
        case Plug.Conn.read_body(conn, length: BodyLimit.bytes()) do
          {:ok, body, conn} -> {body, conn}
          {_more_or_error, _partial, conn} -> {"", conn}
          {:error, _reason} -> {"", conn}
        end

      body ->
        {body, conn}
    end
  end

  # -- the trigger ingress ----------------------------------------------------

  defp fire_from_webhook(conn, id) do
    with {:ok, key} <- trigger_key(conn),
         {:ok, trigger} <- trigger_for(id, key),
         {:ok, event} <- webhook_event(conn.body_params) do
      case fire_webhook(conn, trigger, event) do
        {:ok, fired} -> {:ok, Triggers.fired_json(fired)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  # The caller's own key where it sends one, and the minute from the firing it repeats
  # where it does not. An executor that retries a failed POST blindly gets the run it
  # already made.
  defp fire_webhook(conn, trigger, event) do
    case get_req_header(conn, "idempotency-key") do
      [key | _rest] when byte_size(key) > 0 ->
        Triggers.fire(trigger, "webhook", "webhook:#{trigger.id}:#{key}", event, "trigger-key")

      _none ->
        Triggers.fire_in_window(trigger, "webhook", event, "trigger-key")
    end
  end

  # The same header a person's token arrives in, and never a query parameter: a
  # credential in a URL is a credential in every access log between here and the caller.
  defp trigger_key(conn) do
    case bearer(conn) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _none -> {:error, Error.new(:unauthenticated, %{reason: "no trigger key"})}
    end
  end

  # One answer for "no such trigger" and "wrong key", because two answers are an oracle:
  # a caller holding nothing could walk the id space and learn which triggers exist.
  defp trigger_for(id, key) do
    case Triggers.by_key(id, key) do
      nil -> {:error, Error.new(:unauthenticated, %{reason: "no trigger answers that key"})}
      trigger -> {:ok, trigger}
    end
  end

  # A body is an object or it is nothing. A provider that posts an array or a bare string
  # is refused rather than having its payload wrapped in a shape the template cannot
  # address — `{{event.issue.key}}` has to mean something.
  defp webhook_event(%{} = params) when not is_struct(params), do: {:ok, params}
  defp webhook_event(_other), do: {:error, Error.new(:invalid_params, %{field: "body"})}

  defp webhook_status(%Error{message: "unauthenticated"}), do: 401
  defp webhook_status(%Error{message: "forbidden"}), do: 403
  defp webhook_status(%Error{message: "not_found"}), do: 404
  defp webhook_status(%Error{message: "conflict"}), do: 409
  defp webhook_status(%Error{message: "payload_too_large"}), do: 413
  defp webhook_status(%Error{message: "capacity"}), do: 503
  defp webhook_status(%Error{message: "budget_exhausted"}), do: 402
  defp webhook_status(%Error{}), do: 400

  defp error_json(%Error{} = error) do
    %{"error" => error.message} |> put_present("data", error.data)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
