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
  The session owner's credential for a person-mode server, or why there is not one.

  A function the host installs, the way `:remote_tools` is installed, because reading it
  needs a key-manager token scoped to that person and `troupe_core` is not where that
  lives. A host that installs nothing answers `not_connected`, which is what a laptop
  and a local session both mean.

  Never cached here. The value belongs to whoever owns the session and the pod holds it
  for exactly as long as a call takes.
  """
  @spec person_credential(Server.t(), Troupe.Tool.Ctx.t()) ::
          {:ok, String.t()} | {:error, :not_connected | term()}
  def person_credential(%Server{} = server, ctx) do
    case Application.get_env(:troupe_core, :person_credentials) do
      fun when is_function(fun, 2) -> fun.(server, ctx)
      _none -> {:error, :not_connected}
    end
  end

  @doc """
  Which identity a call to this server goes out as, for the log.

  `"profile"` or `"person:<subject>"`, so a reader can tell which credential a call used
  without knowing what the bundle said that day.
  """
  @spec identity(Server.t(), Troupe.Tool.Ctx.t()) :: String.t()
  def identity(%Server{credential_mode: :person}, ctx) do
    case owner_of(ctx) do
      nil -> "person:unknown"
      subject -> "person:" <> subject
    end
  end

  def identity(%Server{}, _ctx), do: "profile"

  @doc """
  The subject a session belongs to, from the attribution a pod was told at activation.

  A session has **one** identity. If two people are attached and the server is
  person-mode, calls go out as the session's *owner*, fixed at activation and recorded in
  `session_created` — a collaborator acting through somebody else's credential is a thing
  people should be told once rather than discover.
  """
  @spec owner_of(Troupe.Tool.Ctx.t()) :: String.t() | nil
  def owner_of(%{config: %{attribution: %{owner: owner}}}) when is_binary(owner), do: owner
  def owner_of(_ctx), do: nil

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
