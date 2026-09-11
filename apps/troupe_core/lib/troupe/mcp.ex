defmodule Troupe.MCP do
  @moduledoc """
  Tools that live on somebody else's server.

  An MCP server is configured per profile: a name, a URL, and a *reference* to the
  secret holding its service credential. The worker resolves the reference, discovers
  the server's tools, and presents them as `mcp.<server>.<tool>` — ordinary tools from
  the agent loop's point of view, under the same allowlists, the same permission map and
  the same approval gate as `write_file`.

  Two rules about the credential, and both are Forbidden-list items rather than
  preferences.

  **A system MCP server sees the service credential and nothing else.** Not the session
  token, not the user's refresh token, not the subject's identity as an authorisation —
  the session's identity travels as *metadata* for the server's logs, never as
  something it could present elsewhere. A server that received a user token could act as
  that user against anything else that trusts the same issuer.

  **A secret reference is not a secret.** What is configured and what a panel shows is
  the name of a secret; the value is read from the environment the pod was given and
  never leaves it.
  """

  alias Troupe.MCP.{Client, Server, Tool}

  require Logger

  @doc """
  Discover a server's tools and present them as Troupe tools.

  A server that cannot be reached yields no tools rather than an error: a profile with
  four MCP servers and one of them down should lose that server's tools and keep
  working, not fail to start a session.
  """
  @spec tools(Server.t()) :: [Tool.t()]
  def tools(%Server{} = server) do
    case Client.list_tools(server) do
      {:ok, listed} ->
        Enum.map(listed, &Tool.new(server, &1))

      {:error, reason} ->
        Logger.warning("troupe: MCP server #{server.name} is unreachable: #{inspect(reason)}")
        []
    end
  end

  @doc "Every configured server's tools, for `Troupe.Tools`."
  @spec all_tools([Server.t()]) :: [Tool.t()]
  def all_tools(servers), do: Enum.flat_map(servers, &tools/1)

  @doc "The name a server's tool is called by."
  @spec tool_name(String.t(), String.t()) :: String.t()
  def tool_name(server, tool), do: "mcp.#{server}.#{tool}"
end
