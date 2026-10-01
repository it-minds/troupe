defmodule Troupe.Worker.FakeIdentityProvider do
  @moduledoc """
  An identity provider's token endpoint and an MCP server that takes its tokens, on one
  loopback port, for the tests of a profile's own identity (Decision 747).

  The token endpoint does what one that takes a private key JWT (RFC 7523) does, and
  refuses with `invalid_client` what one would refuse: an unknown client, an assertion
  whose `iss` or `sub` is not the client, whose `aud` is not this endpoint, which has run
  out or lives too long, whose `jti` was seen before, whose `x5t#S256` names no
  certificate registered for the client, or whose signature does not verify against that
  certificate's key with the algorithm the header names (RS256, or PS256 with a salt as
  long as the hash). Each client has its own certificates, scope and tools.

  The MCP server answers only a bearer the token endpoint issued and that has not run out
  or been revoked, lists the tools of the client that token was issued to, and answers
  `403` for a tool that client does not have. Without a bearer it answers `401` naming its
  protected-resource metadata, which names this same origin as the authorization server,
  so a pod that is given no `tokenUrl` finds the token endpoint as RFC 9728 and RFC 8414
  say.

  Everything that crosses is sent to the test process: `{:fake_idp, :issued, entry}` for a
  token issued, `{:fake_idp, :refused, error, description}` for a refusal, and
  `{:fake_mcp, method, bearer}` for every MCP request.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn.Query

  @doc "Start one under the test's supervisor. Options: `:expires_in` (seconds, 3600)."
  def start(opts \\ []) do
    test = self()

    agent =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               test: test,
               base: nil,
               expires_in: Keyword.get(opts, :expires_in, 3600),
               clients: %{},
               tokens: %{},
               jtis: MapSet.new(),
               refuse_tokens: false
             }
           end},
          id: {__MODULE__, :agent}
        )
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: {__MODULE__, agent}, port: 0, ip: {127, 0, 0, 1}, startup_log: false},
          id: {__MODULE__, :server}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://127.0.0.1:#{port}"
    Agent.update(agent, &%{&1 | base: base})

    %{agent: agent, base: base, token_url: base <> "/token", mcp_url: base <> "/mcp"}
  end

  @doc """
  Register a client: its certificates as `%{thumbprint => public key PEM}`, the scope it
  must ask for, and the tools it may see.
  """
  def register(fake, client_id, certificates, opts \\ []) do
    keys = Map.new(certificates, fn {thumbprint, pem} -> {thumbprint, public_key(pem)} end)

    client = %{
      certificates: keys,
      scope: Keyword.get(opts, :scope),
      tools: Keyword.get(opts, :tools, ["search"])
    }

    Agent.update(fake.agent, &put_in(&1, [:clients, client_id], client))
  end

  @doc "Add a certificate to a registered client, as an administrator does before a rotation."
  def add_certificate(fake, client_id, thumbprint, pem) do
    Agent.update(
      fake.agent,
      &put_in(&1, [:clients, client_id, :certificates, thumbprint], public_key(pem))
    )
  end

  @doc "Forget a client: the identity provider now refuses it."
  def unregister(fake, client_id),
    do: Agent.update(fake.agent, &%{&1 | clients: Map.delete(&1.clients, client_id)})

  @doc "Every token issued so far stops working at the MCP server, as a revocation would make it."
  def revoke_all(fake) do
    Agent.update(fake.agent, fn state ->
      %{
        state
        | tokens:
            Map.new(state.tokens, fn {token, entry} -> {token, %{entry | revoked: true}} end)
      }
    end)
  end

  @doc "From now on the MCP server refuses every token, however new."
  def refuse_tokens(fake), do: Agent.update(fake.agent, &%{&1 | refuse_tokens: true})

  def set(fake, key, value), do: Agent.update(fake.agent, &Map.put(&1, key, value))

  # -- Plug -------------------------------------------------------------------

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(%{method: "POST", request_path: "/token"} = conn, agent), do: token(conn, agent)
  def call(%{request_path: "/mcp"} = conn, agent), do: mcp(conn, agent)

  def call(
        %{method: "GET", request_path: "/.well-known/oauth-protected-resource" <> _} = conn,
        agent
      ) do
    base = Agent.get(agent, & &1.base)
    json(conn, 200, %{"resource" => base <> "/mcp", "authorization_servers" => [base]})
  end

  def call(
        %{method: "GET", request_path: "/.well-known/oauth-authorization-server"} = conn,
        agent
      ) do
    base = Agent.get(agent, & &1.base)

    json(conn, 200, %{
      "issuer" => base,
      "authorization_endpoint" => base <> "/authorize",
      "token_endpoint" => base <> "/token",
      "grant_types_supported" => ["client_credentials"],
      "token_endpoint_auth_methods_supported" => ["private_key_jwt"]
    })
  end

  def call(conn, _agent), do: send_resp(conn, 404, "")

  # -- the token endpoint -----------------------------------------------------

  defp token(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    form = Query.decode(body)
    state = Agent.get(agent, & &1)

    case check(form, state) do
      {:ok, client_id, header, claims} ->
        token = "at-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        now = System.monotonic_time(:millisecond)

        entry = %{
          token: token,
          client_id: client_id,
          alg: header["alg"],
          thumbprint: header["x5t#S256"],
          scope: form["scope"],
          aud: claims["aud"],
          issued_at: now,
          expires_at: now + state.expires_in * 1000,
          revoked: false
        }

        Agent.update(agent, fn state ->
          %{
            state
            | tokens: Map.put(state.tokens, token, entry),
              jtis: MapSet.put(state.jtis, claims["jti"])
          }
        end)

        send(state.test, {:fake_idp, :issued, entry})

        json(conn, 200, %{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => state.expires_in
        })

      {:error, error, description} ->
        send(state.test, {:fake_idp, :refused, error, description})
        status = if error == "invalid_client", do: 401, else: 400
        json(conn, status, %{"error" => error, "error_description" => description})
    end
  end

  defp check(form, state) do
    now = System.system_time(:second)

    with :ok <-
           expect(
             form["grant_type"] == "client_credentials",
             "unsupported_grant_type",
             "not client credentials"
           ),
         :ok <-
           expect(
             form["client_assertion_type"] ==
               "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
             "invalid_request",
             "the assertion is not a JWT bearer assertion"
           ),
         {:ok, client} <- client(state, form["client_id"]),
         {:ok, header, claims, input, signature} <- parse(form["client_assertion"]),
         :ok <-
           expect(claims["iss"] == form["client_id"], "invalid_client", "iss is not the client"),
         :ok <-
           expect(claims["sub"] == form["client_id"], "invalid_client", "sub is not the client"),
         :ok <-
           expect(
             claims["aud"] == state.base <> "/token",
             "invalid_client",
             "aud is not this endpoint"
           ),
         :ok <-
           expect(
             is_integer(claims["exp"]) and claims["exp"] > now,
             "invalid_client",
             "the assertion has run out"
           ),
         :ok <-
           expect(claims["exp"] <= now + 600, "invalid_client", "the assertion lives too long"),
         :ok <- expect(is_binary(claims["jti"]), "invalid_client", "no jti"),
         :ok <-
           expect(
             not MapSet.member?(state.jtis, claims["jti"]),
             "invalid_client",
             "a jti seen before"
           ),
         {:ok, key} <- certificate(client, header["x5t#S256"]),
         :ok <-
           expect(
             verified?(header["alg"], input, signature, key),
             "invalid_client",
             "the signature does not verify"
           ),
         :ok <-
           expect(
             is_nil(client.scope) or form["scope"] == client.scope,
             "invalid_scope",
             "not this client's scope"
           ) do
      {:ok, form["client_id"], header, claims}
    end
  end

  defp expect(true, _error, _description), do: :ok
  defp expect(_false, error, description), do: {:error, error, description}

  defp client(state, client_id) do
    case Map.fetch(state.clients, client_id || "") do
      {:ok, client} -> {:ok, client}
      :error -> {:error, "invalid_client", "no such client"}
    end
  end

  defp certificate(client, thumbprint) do
    case Map.fetch(client.certificates, thumbprint || "") do
      {:ok, key} -> {:ok, key}
      :error -> {:error, "invalid_client", "no certificate registered with that thumbprint"}
    end
  end

  defp parse(assertion) when is_binary(assertion) do
    with [header, claims, signature] <- String.split(assertion, "."),
         {:ok, header_json} <- Base.url_decode64(header, padding: false),
         {:ok, claims_json} <- Base.url_decode64(claims, padding: false),
         {:ok, raw} <- Base.url_decode64(signature, padding: false),
         {:ok, header_map} <- Jason.decode(header_json),
         {:ok, claims_map} <- Jason.decode(claims_json) do
      {:ok, header_map, claims_map, header <> "." <> claims, raw}
    else
      _ -> {:error, "invalid_client", "the assertion is not a JWT"}
    end
  end

  defp parse(_assertion), do: {:error, "invalid_client", "no assertion"}

  defp verified?("RS256", input, signature, key),
    do: :public_key.verify(input, :sha256, signature, key)

  defp verified?("PS256", input, signature, key) do
    :public_key.verify(input, :sha256, signature, key, [
      {:rsa_padding, :rsa_pkcs1_pss_padding},
      {:rsa_pss_saltlen, 32}
    ])
  end

  defp verified?(_alg, _input, _signature, _key), do: false

  defp public_key(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  # -- the MCP server ---------------------------------------------------------

  defp mcp(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    request = Jason.decode!(body)
    state = Agent.get(agent, & &1)
    bearer = bearer(conn)
    send(state.test, {:fake_mcp, request["method"], bearer})

    case holder(state, bearer) do
      {:ok, client_id} ->
        answer(conn, request, client_id, state)

      :error ->
        conn
        |> put_resp_header(
          "www-authenticate",
          ~s(Bearer error="invalid_token", resource_metadata="#{state.base}/.well-known/oauth-protected-resource")
        )
        |> send_resp(401, "")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end

  defp holder(%{refuse_tokens: true}, _bearer), do: :error

  defp holder(state, bearer) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.tokens, bearer || "") do
      %{revoked: false, expires_at: at, client_id: client_id} when now < at -> {:ok, client_id}
      _ -> :error
    end
  end

  defp answer(conn, %{"method" => "initialize", "id" => id}, _client_id, _state) do
    conn
    |> put_resp_header("mcp-session-id", "fake-session")
    |> rpc(id, %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "fake", "version" => "1"}
    })
  end

  defp answer(conn, %{"method" => "tools/list", "id" => id}, client_id, state) do
    tools =
      for name <- state.clients[client_id].tools do
        %{
          "name" => name,
          "description" => "#{name}, for #{client_id}",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"query" => %{"type" => "string"}}
          }
        }
      end

    rpc(conn, id, %{"tools" => tools})
  end

  defp answer(
         conn,
         %{"method" => "tools/call", "id" => id, "params" => %{"name" => tool}},
         client_id,
         state
       ) do
    if tool in state.clients[client_id].tools do
      rpc(conn, id, %{"content" => [%{"type" => "text", "text" => "#{tool} as #{client_id}"}]})
    else
      send_resp(conn, 403, "")
    end
  end

  defp answer(conn, %{"id" => id}, _client_id, _state) when not is_nil(id),
    do:
      json(conn, 200, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_601, "message" => "no such method"}
      })

  defp answer(conn, _notification, _client_id, _state), do: send_resp(conn, 202, "")

  defp rpc(conn, id, result),
    do: json(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
