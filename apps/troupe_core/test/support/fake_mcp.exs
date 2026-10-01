# A streamable-HTTP MCP server that keeps a session per client, on one loopback port, for
# the suites that test the MCP lifecycle (Decision 746). A script rather than a compiled
# support module, so the worker's suite can `Code.require_file` it too, as the gateway's
# requires `fake_oauth.exs`.
#
# Shaped like the servers that keep state: `initialize` answers with an `Mcp-Session-Id`,
# and every other request without one is refused with `400`, one with an id it never
# issued (or has forgotten) with `404`, and one whose credential is not the one the
# session was opened with with `403`. It answers `initialize` with an older protocol
# version than Troupe asks for, as a server that does not speak the newer one does, so a
# test can see the version it chose carried afterwards. `DELETE` ends a session, or is
# refused with `405` when told to. Started `stateful: false`, it issues no session and
# takes every request, which is what a stateless server does. Every request is sent to
# the test process as `{:fake_mcp, request}`.
unless Code.ensure_loaded?(Troupe.Test.FakeMCP) do
  defmodule Troupe.Test.FakeMCP do
    @version "2025-03-26"

    def version, do: @version

    @doc "Start one. Options: `stateful` (true), `delete` (`:ok`, or `:not_allowed` for `405`)."
    def start(test, opts \\ []) do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

      {:ok, port} = :inet.port(listener)

      {:ok, agent} =
        Agent.start(fn ->
          %{
            test: test,
            stateful: Keyword.get(opts, :stateful, true),
            delete: Keyword.get(opts, :delete, :ok),
            sessions: %{},
            issued: 0
          }
        end)

      acceptor = spawn(fn -> serve(listener, agent) end)
      :ok = :gen_tcp.controlling_process(listener, acceptor)

      %{agent: agent, listener: listener, port: port, url: "http://127.0.0.1:#{port}/mcp"}
    end

    def stop(fake) do
      :gen_tcp.close(fake.listener)
      if Process.alive?(fake.agent), do: Agent.stop(fake.agent)
      :ok
    end

    @doc "Forget every session, as a server that restarted would."
    def forget(fake), do: Agent.update(fake.agent, &%{&1 | sessions: %{}})

    @doc "The sessions it holds, by id: the credential each was opened with."
    def sessions(fake), do: Agent.get(fake.agent, & &1.sessions)

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
           [method, _target, _version] <- String.split(request_line, " "),
           true <- Process.alive?(agent) do
        headers = headers(head)
        rpc = decode(body)
        {status, response} = route(method, rpc, headers, agent)

        send(
          Agent.get(agent, & &1.test),
          {:fake_mcp,
           %{
             method: method,
             rpc: rpc["method"],
             params: rpc["params"],
             session: headers["mcp-session-id"],
             version: headers["mcp-protocol-version"],
             authorization: headers["authorization"],
             status: status
           }}
        )

        :gen_tcp.send(socket, response)
      end

      :gen_tcp.close(socket)
    end

    defp route("POST", %{"method" => "initialize", "id" => id}, headers, agent) do
      state = Agent.get(agent, & &1)

      session =
        if state.stateful do
          n = Agent.get_and_update(agent, &{&1.issued + 1, %{&1 | issued: &1.issued + 1}})
          id = "session-#{n}"
          Agent.update(agent, &put_in(&1, [:sessions, id], headers["authorization"]))
          [{"mcp-session-id", id}]
        else
          []
        end

      result = %{
        "protocolVersion" => @version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fake", "version" => "1"}
      }

      {200, json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => result}, session)}
    end

    defp route("DELETE", _rpc, headers, agent) do
      state = Agent.get(agent, & &1)
      id = headers["mcp-session-id"]

      cond do
        state.delete == :not_allowed ->
          {405, respond(405, "text/plain", "", [])}

        Map.has_key?(state.sessions, id) ->
          Agent.update(agent, &%{&1 | sessions: Map.delete(&1.sessions, id)})
          {200, respond(200, "text/plain", "", [])}

        true ->
          {404, respond(404, "text/plain", "", [])}
      end
    end

    defp route("POST", rpc, headers, agent) do
      state = Agent.get(agent, & &1)
      id = headers["mcp-session-id"]

      cond do
        not state.stateful -> answer(rpc)
        id == nil -> refuse(400, "Bad Request: No valid session ID provided")
        not Map.has_key?(state.sessions, id) -> refuse(404, "Session not found")
        state.sessions[id] != headers["authorization"] -> refuse(403, "Not this session's")
        true -> answer(rpc)
      end
    end

    defp route(_method, _rpc, _headers, _agent), do: {405, respond(405, "text/plain", "", [])}

    defp answer(%{"method" => "notifications/" <> _}),
      do: {202, respond(202, "text/plain", "", [])}

    defp answer(%{"id" => id, "method" => "tools/list"}) do
      tools = [
        %{
          "name" => "search",
          "description" => "Search the team's notes.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"topic" => %{"type" => "string"}}
          }
        }
      ]

      {200, json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}, [])}
    end

    defp answer(%{"id" => id, "method" => "tools/call", "params" => %{"arguments" => args}}) do
      result = %{"content" => [%{"type" => "text", "text" => "three notes on #{args["topic"]}"}]}
      {200, json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => result}, [])}
    end

    defp answer(%{"id" => id}),
      do: {200, json(200, %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}, [])}

    defp answer(_other), do: refuse(400, "not JSON-RPC")

    defp refuse(status, message) do
      error = %{
        "jsonrpc" => "2.0",
        "id" => nil,
        "error" => %{"code" => -32_000, "message" => message}
      }

      {status, json(status, error, [])}
    end

    defp decode(""), do: %{}

    defp decode(body) do
      case Jason.decode(body) do
        {:ok, %{} = decoded} -> decoded
        _other -> %{}
      end
    end

    defp json(status, payload, headers),
      do: respond(status, "application/json", Jason.encode!(payload), headers)

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
