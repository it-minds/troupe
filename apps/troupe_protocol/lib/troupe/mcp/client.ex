defmodule Troupe.MCP.Client do
  @moduledoc """
  The wire half of MCP: JSON-RPC over streamable HTTP.

  One POST per request, with `Accept: application/json, text/event-stream` — a server
  may answer either way and the specification allows both, so both are handled rather
  than one being assumed. A single request/response is all Troupe needs: tool discovery
  and tool calls are both one round trip, and the parts of MCP that stream are the parts
  Troupe does not use.

  **Before the first request to a server, the handshake** (Decision 746). The MCP
  lifecycle opens with `initialize` and `notifications/initialized`, and a server that
  keeps state per client answers the first with an `Mcp-Session-Id` it then wants on every
  request, refusing one without it. So the first call to a server sends both, and what the
  server answered — its session id, if it gave one, and the protocol version it chose,
  which every request after carries — is kept in the caller's `Troupe.MCP.Sessions`, under
  the server and the credential that went out. A server that gives no session id keeps
  none, and is called as before once the handshake is done. A `404` to a request that
  carried a session id is the server having forgotten it: one new handshake, and the
  request once more. A call with nowhere to keep a session (a server tried before it is
  kept) opens one for that request and ends it after.

  Every request carries the server's service credential and nothing about the session
  except metadata for the server's own logs. That separation is the whole point of this
  module being the only place that talks to an MCP server.

  A *personal* connector — one a harness offers, running on somebody's own machine —
  goes through exactly this code with exactly these rules. The difference is whose
  credential it is and where the process runs, not what is sent.
  """

  alias Troupe.MCP.{Server, Sessions}

  @protocol_version "2025-06-18"

  @doc "Ask a server what it can do."
  @spec list_tools(Server.t()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(%Server{} = server) do
    with {:ok, result} <- request(server, "tools/list", %{}) do
      {:ok, Map.get(result, "tools", [])}
    end
  end

  @doc """
  Call one of a server's tools.

  `meta` is where the session's identity goes — as `_meta`, which MCP reserves for
  exactly this — so a server can log which session called it without ever being handed
  something it could present as that user.
  """
  @spec call_tool(Server.t(), String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(%Server{} = server, tool, args, meta \\ %{}) do
    params =
      %{"name" => tool, "arguments" => args}
      |> then(fn params -> if meta == %{}, do: params, else: Map.put(params, "_meta", meta) end)

    request(server, "tools/call", params)
  end

  @doc """
  `initialize` alone, keeping nothing: what a server answers before any session, which
  is where a sign-in's discovery starts (Decision 741). A session it issues anyway is
  ended at once.
  """
  @spec initialize(Server.t()) :: {:ok, map()} | {:error, term()}
  def initialize(%Server{} = server) do
    headers = Server.headers(server)
    response = post(server, headers, nil, message("initialize", hello()))

    with {:ok, result} <- answer(response) do
      end_session(%{opened(server, headers, response, result) | ends_with: headers})
      {:ok, result}
    end
  end

  @doc """
  End a session at its server, with a `DELETE`. Best-effort: a server may refuse it
  (`405`), and whatever it answers, the session is not used again.
  """
  @spec end_session(Sessions.session()) :: :ok
  def end_session(%{id: id, url: url, version: version, ends_with: headers})
      when is_binary(id) and is_list(headers) do
    _ =
      Req.request(
        method: :delete,
        url: url,
        headers: [{"mcp-session-id", id}, {"mcp-protocol-version", version}] ++ headers,
        receive_timeout: 3_000,
        connect_options: [timeout: 3_000],
        retry: false
      )

    :ok
  end

  def end_session(_session), do: :ok

  # -- the session ------------------------------------------------------------

  # The headers are read once per request, so the session it goes in and the request
  # itself carry the same credential.
  defp request(server, method, params) do
    headers = Server.headers(server)
    message = message(method, params)
    key = Sessions.key(server.url, headers)

    with {:ok, session, held} <- session(server, headers, key) do
      case answer(post(server, headers, session, message)) do
        {:error, {:unexpected_status, 404, _body}} when is_binary(session.id) ->
          Sessions.forget(server.sessions, key, session)
          again(server, headers, key, message)

        answer ->
          done(answer, session, held)
      end
    end
  end

  # Once, not in a loop: a server that forgets the session it has just issued will not
  # keep the next one either.
  defp again(server, headers, key, message) do
    with {:ok, session, held} <- session(server, headers, key) do
      server |> post(headers, session, message) |> answer() |> done(session, held)
    end
  end

  # The session kept for this server and credential, or a new one: kept, or used for this
  # one request when there is nowhere to keep it. Two calls that open one at once both
  # finish the handshake; the one whose session was not kept ends it.
  defp session(server, headers, key) do
    case Sessions.lookup(server.sessions, key) do
      %{} = session -> {:ok, session, :kept}
      nil -> open(server, headers, key)
    end
  end

  defp open(server, headers, key) do
    with {:ok, session} <- handshake(server, headers) do
      case Sessions.keep(server.sessions, key, session) do
        :kept ->
          {:ok, session, :kept}

        {:taken, theirs} ->
          end_session(%{session | ends_with: headers})
          {:ok, theirs, :kept}

        :not_kept ->
          {:ok, %{session | ends_with: headers}, :once}
      end
    end
  end

  defp done(answer, session, :once) do
    end_session(session)
    answer
  end

  defp done(answer, _session, :kept), do: answer

  defp handshake(server, headers) do
    response = post(server, headers, nil, message("initialize", hello()))

    with {:ok, result} <- answer(response) do
      session = opened(server, headers, response, result)
      # What it answers is not waited on for anything: a server that wants the session
      # it issued refuses the next request if this did not count, and says so there.
      initialized = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      _ = post(server, headers, session, initialized)
      {:ok, session}
    end
  end

  defp opened(server, headers, {:ok, response}, result) do
    %{
      id: session_id(response),
      version: negotiated(result),
      url: server.url,
      # A person's credential on a pod is held for as long as a call takes, and not kept
      # here for a `DELETE` later (`Troupe.MCP.Sessions`).
      ends_with: if(server.credential_mode == :person and headers != [], do: nil, else: headers)
    }
  end

  defp session_id(response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [id | _] when id != "" -> id
      _none -> nil
    end
  end

  # The version the server chose is the one every request after carries; a server that
  # names none is taken to speak the one asked for.
  defp negotiated(%{"protocolVersion" => version}) when is_binary(version) and version != "",
    do: version

  defp negotiated(_result), do: @protocol_version

  defp hello do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "troupe", "version" => version()}
    }
  end

  # -- transport --------------------------------------------------------------

  defp message(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => params
    }
  end

  defp post(server, headers, session, body) do
    Req.request(
      method: :post,
      url: server.url,
      json: body,
      headers:
        [
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", if(session, do: session.version, else: @protocol_version)}
        ] ++ session_header(session) ++ headers,
      receive_timeout: server.timeout_ms,
      retry: false
    )
  end

  defp session_header(%{id: id}) when is_binary(id), do: [{"mcp-session-id", id}]
  defp session_header(_none), do: []

  # A `401` comes back with what the server wants instead, its `WWW-Authenticate`,
  # which is where a person's sign-in starts (Decision 741).
  defp answer({:ok, %{status: status} = response}) when status in 200..299, do: decode(response)

  defp answer({:ok, %{status: 401} = response}),
    do: {:error, {:unauthorized, challenge(response)}}

  defp answer({:ok, %{status: status, body: body}}),
    do: {:error, {:unexpected_status, status, body}}

  defp answer({:error, reason}), do: {:error, reason}

  defp challenge(response) do
    case Req.Response.get_header(response, "www-authenticate") do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  # A server may answer with a JSON object or with an SSE stream carrying one. Both are
  # allowed, so both are read rather than one being assumed.
  defp decode(%{body: body} = response) do
    case content_type(response) do
      "text/event-stream" <> _rest -> body |> to_string() |> from_sse() |> unwrap()
      _other -> body |> as_map() |> unwrap()
    end
  end

  defp content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [value | _] -> value
      _ -> ""
    end
  end

  defp as_map(body) when is_map(body), do: body

  defp as_map(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp as_map(_body), do: %{}

  defp from_sse(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
    |> Enum.find_value(%{}, fn line ->
      case Jason.decode(line) do
        {:ok, %{"jsonrpc" => _} = decoded} -> decoded
        _ -> nil
      end
    end)
  end

  defp unwrap(%{"result" => result}), do: {:ok, result}
  defp unwrap(%{"error" => error}), do: {:error, {:mcp_error, error}}
  defp unwrap(other), do: {:error, {:unexpected_response, other}}

  defp version do
    case :application.get_key(:troupe_protocol, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
