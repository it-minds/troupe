defmodule Troupe.MCP.Tool do
  @moduledoc """
  One MCP tool, as the agent loop sees it.

  A value rather than a module, because which tools exist is a property of a running
  server rather than of the code. Everything else about it is ordinary: it has a name
  the model calls, a schema, a default permission, and a `run` — and it goes through the
  same allowlist, the same permission map and the same approval gate as `shell` does.

  `ask` by default, deliberately. A built-in tool's blast radius is known and written
  down here; a tool on somebody else's server is whatever that server decided this
  morning. The bundle that configured the server may lower it to `auto` for servers an
  admin trusts, and a profile's `permissions:` map may still tighten it from there.
  """

  alias Troupe.MCP
  alias Troupe.MCP.{Client, OAuth, Server}

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
      default_permission: server.permission,
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
  defp call(%Server{credential_mode: :person} = server, remote_name, args, ctx) do
    case MCP.person_credential(server, ctx) do
      {:ok, credential} ->
        dispatch(%{server | credential: credential}, remote_name, args, ctx)

      {:error, :not_connected} ->
        # A structured refusal the model can read and relay, not a 401 it will retry four
        # times. `{:ok, …}` on purpose: nobody has connected this server, which is a fact
        # about the session's owner rather than a failure of the call, and the session
        # carries on.
        {:ok, not_connected(server)}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  # A person's own server that wants them signed in (Decision 741): the daemon's token,
  # refreshed and tried again once on a `401`. A sign-in that has run out is, like an
  # unconnected person-mode server, a fact the model can relay rather than a failure to
  # retry: the person signs in again and the next call works.
  defp call(%Server{oauth: %{}} = server, remote_name, args, ctx) do
    case OAuth.authorized(server, &Client.call_tool(&1, remote_name, args, meta(ctx))) do
      {:ok, result} -> {:ok, render(result)}
      {:error, :sign_in_required} -> {:ok, sign_in_required(server)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  # The profile's own identity (Decision 747): its token, renewed before it runs out, and
  # a new one tried once on a `401`.
  defp call(%Server{credential_mode: :client_credentials} = server, remote_name, args, ctx) do
    case MCP.authorized(server, &Client.call_tool(&1, remote_name, args, meta(ctx))) do
      {:ok, result} -> {:ok, render(result)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp call(server, remote_name, args, ctx), do: dispatch(server, remote_name, args, ctx)

  defp dispatch(server, remote_name, args, ctx) do
    case Client.call_tool(server, remote_name, args, meta(ctx)) do
      {:ok, result} -> {:ok, render(result)}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp meta(ctx) do
    %{
      "troupe/session" => ctx.session_id,
      "troupe/agent" => Enum.join(ctx.agent_path, "/")
    }
  end

  defp sign_in_required(server) do
    Jason.encode!(%{
      "error" => "sign_in_required",
      "server" => server.name,
      "hint" =>
        "#{server.name} acts as the person who runs this session, and their sign-in to it " <>
          "has run out or was never made: they sign in with /mcp sign-in #{server.name} in " <>
          "the terminal, or Sign in on the desktop app's Servers and skills panel, then ask again"
    })
  end

  defp not_connected(server) do
    Jason.encode!(%{
      "error" => "not_connected",
      "server" => server.name,
      "hint" =>
        "connect #{server.name} in Troupe under Connections, then ask again — " <>
          "this server acts as you, and nobody has given it a credential of yours"
    })
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

  defp describe({:unauthorized, _challenge}),
    do: "the MCP server answered 401: it wants a credential it was not given"

  defp describe(reason) when is_binary(reason), do: reason

  defp describe({:unexpected_status, 403, _body}),
    do: "the MCP server answered 403: the identity this call went out as may not use this tool"

  defp describe({:unexpected_status, status, _body}), do: "the MCP server answered #{status}"
  defp describe(reason), do: "the MCP server could not be reached: #{inspect(reason)}"
end
