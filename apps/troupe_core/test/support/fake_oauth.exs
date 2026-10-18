# An authorization server and an MCP server that wants a signed-in person, on one
# loopback port, for the suites that test a person's sign-in (Decision 741). A script
# rather than a compiled support module, so the gateway's suite can `Code.require_file`
# it too, as it runs `mcp_stub.exs`.
#
# Shaped like the deployments this is for: the MCP server answers a call without a token
# with `401` and a `WWW-Authenticate` naming its protected-resource metadata; the
# authorization server's issuer has a path (`/tenant`) and publishes OpenID Connect
# discovery only at the path-appended place, so discovery has to try the other two
# first; there is no dynamic registration unless asked for, so only the one
# pre-registered client id is taken; PKCE is S256 and checked; the resource indicator is checked against the server;
# refresh tokens rotate and a spent one is refused. A token carries the scopes its sign-in
# asked for, and the server's `write` tool wants `notes.write` on top of them, answering
# `403 insufficient_scope` without it (issue #586). The authorization server revokes a
# token at its `revocation_endpoint` (RFC 7009, issue #587), or refuses to, or is slow, or
# names none. With `registration`, it names a registration endpoint (RFC 7591) and takes
# the clients registered there, each with the redirects it was registered with, matched
# exactly; with `metadata_document`, it takes a client id that is the URL of a client ID
# metadata document, which it fetches, as one at that URL serves (issue #585). Every request
# is sent to the test process as `{:fake_oauth, request}`, so a test can read what crossed
# the wire.
unless Code.ensure_loaded?(Troupe.Test.FakeOAuth) do
  defmodule Troupe.Test.FakeOAuth do
    @client_id "troupe-test-client"
    @account "ada@example.test"

    def client_id, do: @client_id
    def account, do: @account

    @doc """
    Start one. Options: `expires_in` (seconds, 3600), `deny` (the person refuses),
    `challenge_metadata` (whether the 401 names the metadata, true, or a URL it names
    instead), `require_resource`
    (true), `write_tool` (whether `tools/list` names `write`, false; it can be called
    either way), `revocation` (`:ok`, `:refuse`, `:slow` or `:none`, which names no
    endpoint; `:ok`), `revocation_endpoint`, `token_endpoint` and `authorization_endpoint`
    (a URL the metadata names instead of its own), and `host` (the name its own URLs use
    for the loopback address it listens on, `127.0.0.1`; issue #618), `registration`
    (`false`; `true` names a registration endpoint that registers a public client,
    `:confidential` one that answers with a secret and `client_secret_basic`, `:refuse` one
    that refuses), and `metadata_document` (whether the metadata says it takes a client ID
    metadata document, false; the fake serves one at `/troupe-client.json`).
    """
    def start(test, opts \\ []) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      base = "http://#{Keyword.get(opts, :host, "127.0.0.1")}:#{port}"

      {:ok, agent} =
        Agent.start(fn ->
          %{
            base: base,
            test: test,
            expires_in: Keyword.get(opts, :expires_in, 3600),
            deny: Keyword.get(opts, :deny, false),
            challenge_metadata: Keyword.get(opts, :challenge_metadata, true),
            require_resource: Keyword.get(opts, :require_resource, true),
            write_tool: Keyword.get(opts, :write_tool, false),
            revocation: Keyword.get(opts, :revocation, :ok),
            revocation_endpoint: Keyword.get(opts, :revocation_endpoint),
            token_endpoint: Keyword.get(opts, :token_endpoint),
            authorization_endpoint: Keyword.get(opts, :authorization_endpoint),
            registration: Keyword.get(opts, :registration, false),
            metadata_document: Keyword.get(opts, :metadata_document, false),
            # Registered clients, by id, with the redirects each was registered with.
            clients: %{},
            codes: %{},
            # Each token with the scopes it was granted.
            access: %{},
            refresh: %{},
            refuse_refresh: false,
            issued: 0
          }
        end)

      acceptor = spawn(fn -> serve(listener, agent) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)

      %{
        agent: agent,
        listener: listener,
        port: port,
        base: base,
        mcp_url: base <> "/mcp",
        issuer: base <> "/tenant"
      }
    end

    def stop(fake) do
      :gen_tcp.close(fake.listener)
      if Process.alive?(fake.agent), do: Agent.stop(fake.agent)
      :ok
    end

    @doc "Every access token stops working, as a revocation or a clock would make it."
    def revoke_access(fake), do: Agent.update(fake.agent, &%{&1 | access: %{}})

    @doc "Whether the authorization server would still take this refresh token."
    def refresh_token?(fake, token), do: Agent.get(fake.agent, &Map.has_key?(&1.refresh, token))

    @doc "Refresh tokens are refused from now on: the person has to sign in again."
    def refuse_refresh(fake), do: Agent.update(fake.agent, &%{&1 | refuse_refresh: true})

    def set(fake, key, value), do: Agent.update(fake.agent, &Map.put(&1, key, value))

    @doc "The clients registered, by id, each with what it was registered with."
    def clients(fake), do: Agent.get(fake.agent, & &1.clients)

    @doc "The authorization server forgets every client registered with it."
    def forget_clients(fake), do: Agent.update(fake.agent, &%{&1 | clients: %{}})

    @doc "The URL of the client ID metadata document the fake serves."
    def metadata_document_url(fake), do: fake.base <> "/troupe-client.json"

    @doc """
    The person's part: open the URL (the authorization server sends the browser on to
    the redirect URI at once), then follow it to the daemon's loopback listener. Answers
    that last response's status and body.
    """
    def browse(url) do
      {:ok, %{status: 302} = response} = Req.get(url, redirect: false, retry: false)
      [location] = Req.Response.get_header(response, "location")
      {:ok, back} = Req.get(location, redirect: false, retry: false, decode_body: false)
      {back.status, back.body}
    end

    # -- the server -------------------------------------------------------------------

    defp serve(listener, agent) do
      case :gen_tcp.accept(listener) do
        {:ok, socket} ->
          spawn(fn -> handle(socket, agent) end)
          serve(listener, agent)

        {:error, _closed} ->
          :ok
      end
    end

    defp handle(socket, agent) do
      with {:ok, raw} <- read_request(socket, ""),
           [head, body] <- String.split(raw, "\r\n\r\n", parts: 2),
           [request_line | _] <- String.split(head, "\r\n"),
           [method, target, _version] <- String.split(request_line, " ") do
        headers = headers(head)
        uri = URI.parse(target)

        request = %{
          method: method,
          path: uri.path,
          query: uri.query,
          headers: headers,
          body: body,
          raw: raw
        }

        if Process.alive?(agent) do
          send(Agent.get(agent, & &1.test), {:fake_oauth, request})
          :gen_tcp.send(socket, route(request, agent))
        end
      end

      :gen_tcp.close(socket)
    end

    defp route(%{method: "GET", path: "/.well-known/oauth-protected-resource/mcp"}, agent) do
      base = Agent.get(agent, & &1.base)

      json(200, %{
        "resource" => base <> "/mcp",
        "authorization_servers" => [base <> "/tenant"],
        "scopes_supported" => ["notes.read"]
      })
    end

    defp route(%{method: "GET", path: "/tenant/.well-known/openid-configuration"}, agent) do
      state = Agent.get(agent, & &1)
      base = state.base

      revocation =
        case state do
          %{revocation: :none} -> %{}
          %{revocation_endpoint: url} when is_binary(url) -> %{"revocation_endpoint" => url}
          _named -> %{"revocation_endpoint" => base <> "/tenant/revoke"}
        end

      registration =
        if state.registration,
          do: %{"registration_endpoint" => base <> "/tenant/register"},
          else: %{}

      document =
        if state.metadata_document,
          do: %{"client_id_metadata_document_supported" => true},
          else: %{}

      json(
        200,
        Map.merge(
          %{
            "issuer" => base <> "/tenant",
            "authorization_endpoint" =>
              state.authorization_endpoint || base <> "/tenant/authorize",
            "token_endpoint" => state.token_endpoint || base <> "/tenant/token",
            "scopes_supported" => [
              "openid",
              "profile",
              "offline_access",
              "notes.read",
              "notes.write"
            ],
            "code_challenge_methods_supported" => ["S256"]
          },
          revocation |> Map.merge(registration) |> Map.merge(document)
        )
      )
    end

    # RFC 7591: a public client, with the redirects it asks for, each loopback.
    defp route(%{method: "POST", path: "/tenant/register", body: body}, agent) do
      metadata = Jason.decode!(body)
      redirects = List.wrap(metadata["redirect_uris"])

      cond do
        Agent.get(agent, & &1.registration) == :refuse ->
          json(400, %{
            "error" => "invalid_client_metadata",
            "error_description" => "registration is closed"
          })

        redirects == [] or not Enum.all?(redirects, &loopback?/1) ->
          json(400, %{"error" => "invalid_redirect_uri"})

        true ->
          id = "registered-" <> Integer.to_string(System.unique_integer([:positive]))
          Agent.update(agent, &put_in(&1, [:clients, id], metadata))

          answer =
            case Agent.get(agent, & &1.registration) do
              :confidential ->
                %{"client_secret" => "s3cret", "token_endpoint_auth_method" => "client_secret_basic"}

              _public ->
                %{"token_endpoint_auth_method" => "none"}
            end

          json(201, Map.merge(metadata, Map.put(answer, "client_id", id)))
      end
    end

    # A client ID metadata document, as one at its own URL serves it.
    defp route(%{method: "GET", path: "/troupe-client.json"}, agent) do
      base = Agent.get(agent, & &1.base)

      json(200, %{
        "client_id" => base <> "/troupe-client.json",
        "client_name" => "Troupe",
        "redirect_uris" => ["http://127.0.0.1/callback", "http://localhost/callback"],
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })
    end

    # What a `403` names as its metadata, pointing somewhere else: a step-up must not be
    # sent there (issue #586).
    defp route(%{method: "GET", path: "/.well-known/oauth-protected-resource/elsewhere"}, agent) do
      base = Agent.get(agent, & &1.base)

      json(200, %{"resource" => base <> "/mcp", "authorization_servers" => [base <> "/elsewhere"]})
    end

    defp route(%{method: "POST", path: "/tenant/revoke", body: body}, agent) do
      form = URI.decode_query(body)
      revoke(form, agent)
    end

    defp route(%{method: "GET", path: "/tenant/authorize", query: query}, agent) do
      params = URI.decode_query(query || "")

      case authorize_refusal(params, Agent.get(agent, & &1)) do
        nil -> grant(params, agent)
        refusal -> refusal
      end
    end

    defp route(%{method: "POST", path: "/tenant/token", body: body}, agent) do
      form = URI.decode_query(body)

      case form["grant_type"] do
        "authorization_code" -> redeem(form, agent)
        "refresh_token" -> refresh(form, agent)
        _other -> json(400, %{"error" => "unsupported_grant_type"})
      end
    end

    defp route(%{method: "POST", path: "/mcp"} = request, agent) do
      state = Agent.get(agent, & &1)

      case request.headers["authorization"] do
        "Bearer " <> token ->
          case Map.fetch(state.access, token) do
            {:ok, scopes} -> mcp(Jason.decode!(request.body), scopes, state)
            :error -> unauthorized(state, ~s(, error="invalid_token"))
          end

        _none ->
          unauthorized(state, "")
      end
    end

    defp route(_request, _agent), do: text(404, "not here")

    # Why the authorization endpoint turns a request away, or nil.
    defp authorize_refusal(params, state) do
      cond do
        not client?(params["client_id"], params["redirect_uri"], state) ->
          text(400, "unknown client")

        not pkce?(params) -> text(400, "PKCE with S256 is required")
        not loopback?(params["redirect_uri"]) -> text(400, "the redirect is not a loopback one")
        not resource?(params, state) -> text(400, "the resource is not this server")
        true -> nil
      end
    end

    # The pre-registered client; a registered one, at a redirect it was registered with
    # when there is one to check; or, where documents are taken, the URL of a document
    # whose own client_id it is and that lists the redirect, a loopback one on any port.
    defp client?(@client_id, _redirect, _state), do: true

    defp client?(id, redirect, %{clients: clients}) when is_map_key(clients, id),
      do: redirect == nil or redirect in List.wrap(clients[id]["redirect_uris"])

    defp client?("http" <> _ = url, redirect, %{metadata_document: true}) do
      case Req.get(url, retry: false) do
        {:ok, %{status: 200, body: %{"client_id" => ^url} = document}} ->
          redirect == nil or
            Enum.any?(List.wrap(document["redirect_uris"]), &(portless(&1) == portless(redirect)))

        _other ->
          false
      end
    end

    defp client?(_id, _redirect, _state), do: false

    defp portless(uri), do: URI.to_string(%{URI.parse(uri) | port: nil})

    defp pkce?(params) do
      params["response_type"] == "code" and params["code_challenge_method"] == "S256" and
        params["code_challenge"] not in [nil, ""]
    end

    defp loopback?(redirect),
      do: String.starts_with?(redirect || "", ["http://127.0.0.1:", "http://localhost:"])

    defp resource?(params, state),
      do: not state.require_resource or params["resource"] == state.base <> "/mcp"

    # The person's answer, sent straight back to the redirect: a refusal, or a code.
    defp grant(params, agent) do
      if Agent.get(agent, & &1.deny) do
        found(params["redirect_uri"], %{
          "error" => "access_denied",
          "error_description" => "the person said no",
          "state" => params["state"]
        })
      else
        code = "code-" <> Integer.to_string(System.unique_integer([:positive]))
        Agent.update(agent, &put_in(&1, [:codes, code], params))
        found(params["redirect_uri"], %{"code" => code, "state" => params["state"]})
      end
    end

    defp redeem(form, agent) do
      state = Agent.get(agent, & &1)

      case Map.pop(state.codes, form["code"]) do
        {nil, _codes} ->
          json(400, %{"error" => "invalid_grant", "error_description" => "no such code"})

        {issued, codes} ->
          Agent.update(agent, &%{&1 | codes: codes})

          case redeem_refusal(form, issued, state) do
            nil -> json(200, issue(agent, String.split(issued["scope"] || ""), id_token: true))
            refusal -> refusal
          end
      end
    end

    # Why the token endpoint will not redeem a code, or nil: the verifier, the request it
    # was issued for, and the resource are all checked.
    defp redeem_refusal(form, issued, state) do
      challenge =
        :sha256 |> :crypto.hash(form["code_verifier"] || "") |> Base.url_encode64(padding: false)

      cond do
        challenge != issued["code_challenge"] ->
          json(400, %{
            "error" => "invalid_grant",
            "error_description" => "the verifier does not match"
          })

        not client?(form["client_id"], nil, state) ->
          json(401, %{"error" => "invalid_client", "error_description" => "no such client"})

        form["redirect_uri"] != issued["redirect_uri"] or form["client_id"] != issued["client_id"] ->
          json(400, %{
            "error" => "invalid_grant",
            "error_description" => "not the request it was issued for"
          })

        not resource?(form, state) ->
          json(400, %{"error" => "invalid_target"})

        true ->
          nil
      end
    end

    defp refresh(form, agent) do
      state = Agent.get(agent, & &1)

      if client?(form["client_id"], nil, state),
        do: refresh_known(form, agent, state),
        else: json(401, %{"error" => "invalid_client", "error_description" => "no such client"})
    end

    defp refresh_known(form, agent, state) do
      if not state.refuse_refresh and Map.has_key?(state.refresh, form["refresh_token"]) do
        # Rotated: the token just spent is no good again. The new one has its scopes.
        scopes = state.refresh[form["refresh_token"]]
        Agent.update(agent, &%{&1 | refresh: Map.delete(&1.refresh, form["refresh_token"])})
        json(200, issue(agent, scopes, id_token: false))
      else
        json(400, %{
          "error" => "invalid_grant",
          "error_description" => "the refresh token is no good"
        })
      end
    end

    # Granted what was asked for.
    defp issue(agent, scopes, opts) do
      n = Agent.get_and_update(agent, &{&1.issued + 1, %{&1 | issued: &1.issued + 1}})
      access = "at-#{n}"
      refresh = "rt-#{n}"

      Agent.update(agent, fn state ->
        %{
          state
          | access: Map.put(state.access, access, scopes),
            refresh: Map.put(state.refresh, refresh, scopes)
        }
      end)

      %{
        "access_token" => access,
        "token_type" => "Bearer",
        "expires_in" => Agent.get(agent, & &1.expires_in),
        "refresh_token" => refresh,
        "scope" => Enum.join(scopes, " ")
      }
      |> then(&if(opts[:id_token], do: Map.put(&1, "id_token", id_token()), else: &1))
    end

    # RFC 7009: the client's own token goes, and the access token of the same grant with a
    # refresh token; an unknown token is answered 200 as well.
    defp revoke(form, agent) do
      case Agent.get(agent, & &1.revocation) do
        :refuse ->
          json(400, %{"error" => "invalid_request", "error_description" => "not today"})

        mode ->
          if mode == :slow, do: Process.sleep(2_000)

          if client?(form["client_id"], nil, Agent.get(agent, & &1)) do
            forget(agent, form["token"] || "")
            respond(200, "text/plain", "", [])
          else
            json(401, %{"error" => "invalid_client"})
          end
      end
    end

    defp forget(agent, token) do
      paired = String.replace_prefix(token, "rt-", "at-")

      Agent.update(agent, fn state ->
        %{
          state
          | refresh: Map.delete(state.refresh, token),
            access: state.access |> Map.delete(token) |> Map.delete(paired)
        }
      end)
    end

    defp id_token do
      encode = &(&1 |> Jason.encode!() |> Base.url_encode64(padding: false))

      encode.(%{"alg" => "none"}) <>
        "." <> encode.(%{"preferred_username" => @account, "sub" => "s-1"}) <> ".sig"
    end

    defp unauthorized(state, extra) do
      metadata =
        case state.challenge_metadata do
          true -> ~s(resource_metadata="#{state.base}/.well-known/oauth-protected-resource/mcp", )
          url when is_binary(url) -> ~s(resource_metadata="#{url}", )
          _none -> ""
        end

      respond(401, "application/json", ~s({"error":"unauthorized"}), [
        {"www-authenticate", ~s(Bearer #{metadata}scope="notes.read") <> extra}
      ])
    end

    # A notification is accepted with no body, as the specification has a server do: the
    # handshake sends one (Decision 746).
    defp mcp(%{"method" => "notifications/" <> _}, _scopes, _state),
      do: respond(202, "text/plain", "", [])

    defp mcp(%{"id" => id, "method" => "tools/list"}, _scopes, state) do
      topic = %{"type" => "object", "properties" => %{"topic" => %{"type" => "string"}}}
      search = %{"name" => "search", "description" => "Search my notes.", "inputSchema" => topic}
      write = %{"name" => "write", "description" => "Write a note.", "inputSchema" => topic}

      rpc(id, %{"tools" => if(state.write_tool, do: [search, write], else: [search])})
    end

    defp mcp(
           %{"id" => id, "method" => "tools/call", "params" => %{"name" => "write"} = params},
           scopes,
           state
         ) do
      if "notes.write" in scopes do
        text = "wrote a note on #{params["arguments"]["topic"]}, for #{@account}"
        rpc(id, %{"content" => [%{"type" => "text", "text" => text}]})
      else
        insufficient_scope(state)
      end
    end

    defp mcp(
           %{"id" => id, "method" => "tools/call", "params" => %{"arguments" => args}},
           _scopes,
           _state
         ) do
      rpc(id, %{
        "content" => [%{"type" => "text", "text" => "notes on #{args["topic"]}, for #{@account}"}]
      })
    end

    defp mcp(%{"id" => id}, _scopes, _state), do: rpc(id, %{})

    # The MCP authorization specification's step-up: the scope the call needs, and the
    # metadata, here pointing at an authorization server the sign-in never used.
    defp insufficient_scope(state) do
      elsewhere = state.base <> "/.well-known/oauth-protected-resource/elsewhere"

      respond(403, "application/json", ~s({"error":"insufficient_scope"}), [
        {"www-authenticate",
         ~s(Bearer error="insufficient_scope", scope="notes.write", ) <>
           ~s(resource_metadata="#{elsewhere}", error_description="writing needs notes.write")}
      ])
    end

    defp rpc(id, result), do: json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})

    defp found(redirect, params) do
      respond(302, "text/plain", "", [{"location", redirect <> "?" <> URI.encode_query(params)}])
    end

    defp json(status, payload),
      do: respond(status, "application/json", Jason.encode!(payload), [])

    defp text(status, message), do: respond(status, "text/plain", message, [])

    defp respond(status, type, body, headers) do
      [
        "HTTP/1.1 #{status} X\r\n",
        "content-type: #{type}\r\n",
        Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n\r\n",
        body
      ]
    end

    defp headers(head) do
      head
      |> String.split("\r\n")
      |> Enum.drop(1)
      |> Enum.flat_map(fn line ->
        case String.split(line, ":", parts: 2) do
          [name, value] -> [{String.downcase(name), String.trim(value)}]
          _ -> []
        end
      end)
      |> Map.new()
    end

    defp read_request(socket, acc) do
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} ->
          acc = acc <> data
          if complete?(acc), do: {:ok, acc}, else: read_request(socket, acc)

        {:error, _reason} ->
          :error
      end
    end

    defp complete?(request) do
      case String.split(request, "\r\n\r\n", parts: 2) do
        [head, body] -> byte_size(body) >= content_length(head)
        _ -> false
      end
    end

    defp content_length(head) do
      head
      |> String.split("\r\n")
      |> Enum.find_value(0, fn line ->
        case String.split(String.downcase(line), ":", parts: 2) do
          ["content-length", value] -> String.to_integer(String.trim(value))
          _ -> nil
        end
      end)
    end
  end
end
