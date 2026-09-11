defmodule Troupe.UI.TUI.Connectors do
  @moduledoc """
  The harness side of client-hosted tools: personal MCP connections, offered per session.

  A person's own MCP servers — their notes, their calendar, a thing running on localhost
  — are not a property of a worker pod and must never be configured into one. They live
  in this person's config file, on this person's machine, and are offered to *one*
  session, *when they say so*, and to nothing else.

  Three things make that true rather than intended.

  **Nothing is offered by default.** Servers are read at start and sit there. `/connect`
  lists them; `/connect <name>` offers one.

  **Consent is a round trip through the session.** The worker answers the first
  registration with a challenge and the words to show. This prints them and stops. Only
  `/connect yes` registers, carrying what was confirmed. A client that could register
  without this step would be consenting on its user's behalf, which is not consent.

  **The call runs here.** `tool.invoke` arrives over this connection, is served against
  the person's own MCP server with the person's own credential, and is answered on the
  same connection. Nothing about the session's identity is sent as an authorisation —
  only as `_meta`, for the server's logs — which is the same rule a worker's system MCP
  servers follow, for the same reason.
  """

  alias Troupe.MCP.{Client, Server}
  alias Troupe.Protocol.Client, as: Protocol

  require Logger

  @doc """
  The personal MCP servers this machine has configured.

  `$TROUPE_MCP_CONFIG`, else `$XDG_CONFIG_HOME/troupe/mcp.json`, else
  `~/.config/troupe/mcp.json`. Missing is the normal case and means no connectors, not
  an error: most people have none.

      {"servers": [{"name": "notes", "url": "http://127.0.0.1:7331/mcp",
                    "credential_ref": "NOTES_TOKEN"}]}

  `credential_ref` names an environment variable, so the file holds a reference and the
  value stays in the shell that started the client — the same rule the worker follows
  for a profile's servers.
  """
  @spec load() :: [Server.t()]
  def load do
    with path when is_binary(path) <- config_path(),
         {:ok, contents} <- File.read(path),
         {:ok, %{"servers" => servers}} when is_list(servers) <- Jason.decode(contents) do
      Enum.map(servers, &Server.from_config/1)
    else
      nil ->
        []

      {:error, :enoent} ->
        []

      other ->
        Logger.warning("troupe: could not read personal MCP config: #{inspect(other)}")
        []
    end
  end

  @doc "Where `load/0` looks, or `nil` when this machine has no config directory."
  @spec config_path() :: Path.t() | nil
  def config_path do
    cond do
      path = env("TROUPE_MCP_CONFIG") -> path
      base = env("XDG_CONFIG_HOME") -> Path.join([base, "troupe", "mcp.json"])
      home = env("HOME") -> Path.join([home, ".config", "troupe", "mcp.json"])
      true -> nil
    end
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc """
  Discover one server's tools, in the shape `tools.register` takes.

  A server that cannot be reached yields no tools, and the caller says so: offering a
  connector that is down should cost that connector and nothing else.
  """
  @spec offer(Server.t()) :: {:ok, [map()]} | {:error, term()}
  def offer(%Server{} = server) do
    case Client.list_tools(server) do
      {:ok, tools} ->
        {:ok,
         Enum.map(tools, fn tool ->
           %{
             "name" => "#{server.name}.#{tool["name"]}",
             "description" => tool["description"] || "A tool on #{server.name}.",
             "schema" => tool["inputSchema"] || %{"type" => "object"}
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Serve one `tool.invoke`, in a task, and answer on the connection it arrived on.

  In a task because the UI process must not block on somebody's laptop: a connector
  that takes thirty seconds would otherwise stop the screen redrawing, and a connector
  that never answers would stop it forever.
  """
  @spec serve(pid(), [Server.t()], term(), map(), String.t()) :: pid()
  def serve(client, servers, id, params, session_id) do
    spawn(fn ->
      case resolve(servers, params["name"]) do
        {:ok, server, tool} ->
          meta = %{"troupe" => %{"session_id" => session_id}}

          case Client.call_tool(server, tool, params["arguments"] || %{}, meta) do
            {:ok, result} -> Protocol.respond(client, id, result)
            {:error, reason} -> Protocol.respond_error(client, id, describe(reason))
          end

        :error ->
          Protocol.respond_error(client, id, "no connector serves #{params["name"]}")
      end
    end)
  end

  # `client.notes.search` is this harness's `notes` server and its `search` tool. The
  # prefix is the session's bookkeeping and is stripped before anything is sent.
  defp resolve(servers, "client." <> rest), do: resolve(servers, rest)

  defp resolve(servers, name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [server_name, tool] ->
        case Enum.find(servers, &(&1.name == server_name)) do
          nil -> :error
          server -> {:ok, server, tool}
        end

      _other ->
        :error
    end
  end

  defp resolve(_servers, _name), do: :error

  defp describe({:mcp_error, %{"message" => message}}), do: message
  defp describe(reason), do: inspect(reason)
end
