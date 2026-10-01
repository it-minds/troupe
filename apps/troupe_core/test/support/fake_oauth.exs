# An authorization server and an MCP server that wants a signed-in person, on one
# loopback port, for the suites that test a person's sign-in (Decision 741). A script
# rather than a compiled support module, so the gateway's suite can `Code.require_file`
# it too, as it runs `mcp_stub.exs`.
#
# Shaped like the deployments this is for: the MCP server answers a call without a token
# with `401` and a `WWW-Authenticate` naming its protected-resource metadata; the
# authorization server's issuer has a path (`/tenant`) and publishes OpenID Connect
# discovery only at the path-appended place, so discovery has to try the other two
# first; there is no dynamic registration, so only the one pre-registered client id is
# taken; PKCE is S256 and checked; the resource indicator is checked against the server;
# refresh tokens rotate and a spent one is refused. Every request is sent to the test
# process as `{:fake_oauth, request}`, so a test can read what crossed the wire.
unless Code.ensure_loaded?(Troupe.Test.FakeOAuth) do
  defmodule Troupe.Test.FakeOAuth do
    @client_id "troupe-test-client"
    @account "ada@example.test"

    def client_id, do: @client_id
    def account, do: @account

    @doc """
    Start one. Options: `expires_in` (seconds, 3600), `deny` (the person refuses),
    `challenge_metadata` (whether the 401 names the metadata, true), `require_resource`
    (true).
    """
    def start(test, opts \\ []) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)
      base = "http://127.0.0.1:#{port}"

      {:ok, agent} =
        Agent.start(fn ->
          %{
            base: base,
            test: test,
            expires_in: Keyword.get(opts, :expires_in, 3600),
            deny: Keyword.get(opts, :deny, false),
            challenge_metadata: Keyword.get(opts, :challenge_metadata, true),
            require_resource: Keyword.get(opts, :require_resource, true),
            codes: %{},
            access: MapSet.new(),
            refresh: MapSet.new(),
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
    def revoke_access(fake), do: Agent.update(fake.agent, &%{&1 | access: MapSet.new()})

    @doc "Refresh tokens are refused from now on: the person has to sign in again."
    def refuse_refresh(fake), do: Agent.update(fake.agent, &%{&1 | refuse_refresh: true})

    def set(fake, key, value), do: Agent.update(fake.agent, &Map.put(&1, key, value))

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
      base = Agent.get(agent, & &1.base)

      json(200, %{
        "issuer" => base <> "/tenant",
        "authorization_endpoint" => base <> "/tenant/authorize",
        "token_endpoint" => base <> "/tenant/token",
        "scopes_supported" => ["openid", "profile", "offline_access", "notes.read"],
        "code_challenge_methods_supported" => ["S256"]
      })
    end

    defp route(%{method: "GET", path: "/tenant/authorize", query: query}, agent) do
      params = URI.decode_query(query || "")
      state = Agent.get(agent, & &1)
      redirect = params["redirect_uri"]

      cond do
        params["client_id"] != @client_id ->
          text(400, "unknown client")

        params["response_type"] != "code" or params["code_challenge_method"] != "S256" or
            params["code_challenge"] in [nil, ""] ->
          text(400, "PKCE with S256 is required")

        not String.starts_with?(redirect || "", "http://127.0.0.1:") and
            not String.starts_with?(redirect || "", "http://localhost:") ->
          text(400, "the redirect is not a loopback one")

        state.require_resource and params["resource"] != state.base <> "/mcp" ->
          text(400, "the resource is not this server")

        state.deny ->
          found(redirect, %{
            "error" => "access_denied",
            "error_description" => "the person said no",
            "state" => params["state"]
          })

        true ->
          code = "code-" <> Integer.to_string(System.unique_integer([:positive]))
          Agent.update(agent, &put_in(&1, [:codes, code], params))
          found(redirect, %{"code" => code, "state" => params["state"]})
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
          if MapSet.member?(state.access, token),
            do: mcp(Jason.decode!(request.body)),
            else: unauthorized(state, ~s(, error="invalid_token"))

        _none ->
          unauthorized(state, "")
      end
    end

    defp route(_request, _agent), do: text(404, "not here")

    defp redeem(form, agent) do
      state = Agent.get(agent, & &1)

      case Map.pop(state.codes, form["code"]) do
        {nil, _codes} ->
          json(400, %{"error" => "invalid_grant", "error_description" => "no such code"})

        {issued, codes} ->
          Agent.update(agent, &%{&1 | codes: codes})

          challenge =
            :sha256
            |> :crypto.hash(form["code_verifier"] || "")
            |> Base.url_encode64(padding: false)

          cond do
            challenge != issued["code_challenge"] ->
              json(400, %{
                "error" => "invalid_grant",
                "error_description" => "the verifier does not match"
              })

            form["redirect_uri"] != issued["redirect_uri"] or form["client_id"] != @client_id ->
              json(400, %{
                "error" => "invalid_grant",
                "error_description" => "not the request it was issued for"
              })

            state.require_resource and form["resource"] != state.base <> "/mcp" ->
              json(400, %{"error" => "invalid_target"})

            true ->
              json(200, issue(agent, id_token: true))
          end
      end
    end

    defp refresh(form, agent) do
      state = Agent.get(agent, & &1)

      if not state.refuse_refresh and MapSet.member?(state.refresh, form["refresh_token"]) and
           form["client_id"] == @client_id do
        # Rotated: the token just spent is no good again.
        Agent.update(agent, &%{&1 | refresh: MapSet.delete(&1.refresh, form["refresh_token"])})
        json(200, issue(agent, id_token: false))
      else
        json(400, %{
          "error" => "invalid_grant",
          "error_description" => "the refresh token is no good"
        })
      end
    end

    defp issue(agent, opts) do
      n = Agent.get_and_update(agent, &{&1.issued + 1, %{&1 | issued: &1.issued + 1}})
      access = "at-#{n}"
      refresh = "rt-#{n}"

      Agent.update(agent, fn state ->
        %{
          state
          | access: MapSet.put(state.access, access),
            refresh: MapSet.put(state.refresh, refresh)
        }
      end)

      %{
        "access_token" => access,
        "token_type" => "Bearer",
        "expires_in" => Agent.get(agent, & &1.expires_in),
        "refresh_token" => refresh,
        "scope" => "notes.read offline_access"
      }
      |> then(&if(opts[:id_token], do: Map.put(&1, "id_token", id_token()), else: &1))
    end

    defp id_token do
      encode = &(&1 |> Jason.encode!() |> Base.url_encode64(padding: false))

      encode.(%{"alg" => "none"}) <>
        "." <> encode.(%{"preferred_username" => @account, "sub" => "s-1"}) <> ".sig"
    end

    defp unauthorized(state, extra) do
      metadata =
        if state.challenge_metadata,
          do: ~s(resource_metadata="#{state.base}/.well-known/oauth-protected-resource/mcp", ),
          else: ""

      respond(401, "application/json", ~s({"error":"unauthorized"}), [
        {"www-authenticate", ~s(Bearer #{metadata}scope="notes.read") <> extra}
      ])
    end

    defp mcp(%{"id" => id, "method" => "tools/list"}) do
      rpc(id, %{
        "tools" => [
          %{
            "name" => "search",
            "description" => "Search my notes.",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"topic" => %{"type" => "string"}}
            }
          }
        ]
      })
    end

    defp mcp(%{"id" => id, "method" => "tools/call", "params" => %{"arguments" => args}}) do
      rpc(id, %{
        "content" => [%{"type" => "text", "text" => "notes on #{args["topic"]}, for #{@account}"}]
      })
    end

    defp mcp(%{"id" => id}), do: rpc(id, %{})

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
