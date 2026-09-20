defmodule Troupe.Session.MCP do
  @moduledoc """
  The MCP servers a workspace's own configuration names (Decision 654).

  A pod's servers come from its bundle and are discovered pod-wide; a laptop has no
  bundle, and its `.troupe/config.yaml` (or the machine's) may say:

      mcp:
        filesystem:
          command: npx
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
        wiki:
          url: https://wiki.example/mcp

  A `command` server speaks over its standard streams and lives as long as the session
  (`Troupe.MCP.Stdio`); a `url` server is the same one-shot HTTP client the pod uses,
  discovered once when the session starts. Both kinds' tools are `mcp.<server>.<tool>`
  and go through the same gate as everything else; `permission: auto` on a server
  lowers its tools from the default `ask`.

  Supervised with the stdio servers as linked children, so a server that dies takes
  this holder with it and the supervisor brings the set back together.
  """

  use GenServer

  alias Troupe.MCP.{Client, Server, Stdio, Tool}

  require Logger

  defstruct [:session_id, :workspace, stdio: [], http: []]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.session_mcp(session_id))
  end

  @doc "Every local server's tools, for `Troupe.Tools.all/1`."
  @spec tools(String.t()) :: [Troupe.Tool.handle()]
  def tools(session_id), do: call(session_id, :tools, [])

  @doc "What a client shows about the servers: name, state, tool names, error."
  @spec status(String.t()) :: [map()]
  def status(session_id), do: call(session_id, :status, [])

  defp call(session_id, message, default) do
    GenServer.call(Troupe.Registry.session_mcp(session_id), message, 15_000)
  catch
    :exit, _ -> default
  end

  ## Server

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    servers = Keyword.get(opts, :servers, %{})
    Process.set_label("troupe session mcp #{session_id}")

    state = %__MODULE__{session_id: session_id, workspace: workspace}
    {:ok, state, {:continue, {:start, servers}}}
  end

  @impl GenServer
  def handle_continue({:start, servers}, state) do
    started = Enum.map(servers, fn {name, config} -> start_server(state, name, config) end)

    {:noreply,
     %{
       state
       | stdio: for({:stdio, name} <- started, do: name),
         http: for({:http, entry} <- started, do: entry)
     }}
  end

  defp start_server(state, name, %{command: command} = config) when is_binary(command) do
    case Stdio.start_link(session_id: state.session_id, name: name, config: config, cwd: state.workspace) do
      {:ok, _pid} ->
        {:stdio, name}

      {:error, reason} ->
        Logger.warning("troupe: MCP server #{name}: #{inspect(reason)}")
        :skipped
    end
  end

  defp start_server(_state, name, %{url: url} = config) when is_binary(url), do: {:http, http_server(name, config)}

  defp start_server(_state, name, _config) do
    Logger.warning("troupe: MCP server #{name} has neither command nor url; ignored")
    :skipped
  end

  @impl GenServer
  def handle_call(:tools, _from, state) do
    stdio = Enum.flat_map(state.stdio, &Stdio.tools(state.session_id, &1))
    http = Enum.flat_map(state.http, & &1.tools)
    {:reply, stdio ++ http, state}
  end

  def handle_call(:status, _from, state) do
    stdio = Enum.map(state.stdio, &Stdio.status(state.session_id, &1))

    http =
      Enum.map(state.http, fn entry ->
        %{
          name: entry.server.name,
          state: if(entry.error, do: :error, else: :ready),
          tools: Enum.map(entry.tools, & &1.remote_name),
          error: entry.error
        }
      end)

    {:reply, Enum.sort_by(stdio ++ http, & &1.name), state}
  end

  # Discovered once, here: a URL server's tools are a property of the server, and a
  # session asking on every prompt would put the server's latency on every turn.
  defp http_server(name, config) do
    server =
      Server.from_config(%{
        "name" => name,
        "url" => config[:url],
        "permission" => config[:permission] || :ask,
        "timeout_ms" => config[:timeout_ms] || 30_000
      })

    case Client.list_tools(server) do
      {:ok, listed} ->
        %{server: server, tools: Enum.map(listed, &Tool.new(server, &1)), error: nil}

      {:error, reason} ->
        %{server: server, tools: [], error: "unreachable: #{inspect(reason)}"}
    end
  end
end
