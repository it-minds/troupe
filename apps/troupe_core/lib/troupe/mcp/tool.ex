defmodule Troupe.MCP.Tool do
  @moduledoc """
  One MCP tool, as the agent loop sees it.

  A value rather than a module, because which tools exist is a property of a running
  server rather than of the code. Everything else about it is ordinary: it has a name
  the model calls, a schema, a default permission, and a `run` — and it goes through the
  same allowlist, the same permission map and the same approval gate as `shell` does.

  `ask` by default, deliberately. A built-in tool's blast radius is known and written
  down here; a tool on somebody else's server is whatever that server decided this
  morning, and the profile can lower it to `auto` for servers an operator trusts.
  """

  alias Troupe.MCP
  alias Troupe.MCP.{Client, Server}

  @enforce_keys [:name, :description, :schema, :run]
  defstruct [:name, :description, :schema, :run, :server, :remote_name, default_permission: :ask]

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          schema: map(),
          run: (map(), Troupe.Tool.Ctx.t() -> Troupe.Tool.result()),
          server: String.t(),
          remote_name: String.t(),
          default_permission: :auto | :ask | :deny
        }

  @doc "Build a Troupe tool from one entry of a server's `tools/list`."
  @spec new(Server.t(), map()) :: t()
  def new(%Server{} = server, listed) do
    remote_name = listed["name"]

    %__MODULE__{
      name: MCP.tool_name(server.name, remote_name),
      remote_name: remote_name,
      server: server.name,
      description: description_of(server, listed),
      schema: listed["inputSchema"] || %{"type" => "object", "properties" => %{}},
      default_permission: :ask,
      run: fn args, ctx -> call(server, remote_name, args, ctx) end
    }
  end

  defp description_of(server, listed) do
    text = listed["description"] || "A tool provided by the #{server.name} MCP server."
    String.trim(text) <> "\n\nProvided by the #{server.name} MCP server."
  end

  # The session's identity goes as metadata, for the server's logs. Never as a token: a
  # server that received one could act as that user against anything else trusting the
  # same issuer, and it has no need to act as anyone.
  defp call(server, remote_name, args, ctx) do
    meta = %{
      "troupe/session" => ctx.session_id,
      "troupe/agent" => Enum.join(ctx.agent_path, "/")
    }

    case Client.call_tool(server, remote_name, args, meta) do
      {:ok, result} -> {:ok, render(result)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  # MCP returns content blocks. Text is what a model can read; anything else is named
  # rather than dumped, because a base64 image in a tool result is a wasted context
  # window.
  defp render(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map_join("\n", fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => type} -> "[#{type} content]"
      other -> inspect(other)
    end)
    |> String.trim()
    |> case do
      "" -> "(no output)"
      text -> text
    end
  end

  defp render(result), do: Jason.encode!(result)

  defp describe({:mcp_error, %{"message" => message}}), do: "the MCP server refused: #{message}"
  defp describe({:unexpected_status, status, _body}), do: "the MCP server answered #{status}"
  defp describe(reason), do: "the MCP server could not be reached: #{inspect(reason)}"
end
