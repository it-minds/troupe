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

  The server's `tools` allowlist is applied here, at discovery, so a tool the bundle
  did not list is never built and never offered — absent from what the model can see
  rather than present and denied.
  """
  @spec tools(Server.t()) :: [Tool.t()]
  def tools(%Server{} = server) do
    case Client.list_tools(server) do
      {:ok, listed} ->
        listed
        |> Enum.filter(&Server.offers?(server, &1["name"]))
        |> Enum.map(&Tool.new(server, &1))

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

  @doc """
  Which server a tool name belongs to, or `nil` when it belongs to none.

      iex> Troupe.MCP.server_of("mcp.jira.create_issue")
      "jira"
      iex> Troupe.MCP.server_of("write_file")
      nil

  The inverse of `tool_name/2`, and the reason a session's entitlement filter can work
  on names rather than on the tool values: a client-hosted tool and a built-in are not
  an MCP server's and must not be narrowed by a set that never names them.
  """
  @spec server_of(String.t()) :: String.t() | nil
  def server_of("mcp." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [server, _tool] -> server
      _ -> nil
    end
  end

  def server_of(_name), do: nil
end
