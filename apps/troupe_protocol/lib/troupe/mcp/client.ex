defmodule Troupe.MCP.Client do
  @moduledoc """
  The wire half of MCP: JSON-RPC over streamable HTTP.

  One POST per request, with `Accept: application/json, text/event-stream` — a server
  may answer either way and the specification allows both, so both are handled rather
  than one being assumed. A single request/response is all Troupe needs: tool discovery
  and tool calls are both one round trip, and the parts of MCP that stream are the parts
  Troupe does not use.

  Every request carries the server's service credential and nothing about the session
  except metadata for the server's own logs. That separation is the whole point of this
  module being the only place that talks to an MCP server.

  A *personal* connector — one a harness offers, running on somebody's own machine —
  goes through exactly this code with exactly these rules. The difference is whose
  credential it is and where the process runs, not what is sent.
  """

  alias Troupe.MCP.Server

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

  @doc "The handshake, for a health check or a first connection."
  @spec initialize(Server.t()) :: {:ok, map()} | {:error, term()}
  def initialize(%Server{} = server) do
    request(server, "initialize", %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{},
      "clientInfo" => %{"name" => "troupe", "version" => version()}
    })
  end

  # -- transport --------------------------------------------------------------

  defp request(server, method, params) do
    body = %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive, :monotonic]),
      "method" => method,
      "params" => params
    }

    options = [
      method: :post,
      url: server.url,
      json: body,
      headers:
        [
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", @protocol_version}
        ] ++ Server.headers(server),
      receive_timeout: server.timeout_ms,
      retry: false
    ]

    case Req.request(options) do
      {:ok, %{status: status} = response} when status in 200..299 -> decode(response)
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected_status, status, body}}
      {:error, reason} -> {:error, reason}
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
