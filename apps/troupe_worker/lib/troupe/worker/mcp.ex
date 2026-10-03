defmodule Troupe.Worker.MCP do
  @moduledoc """
  The MCP servers this pod's profile configured, and the tools they turn into.

  Discovery happens once at start and again whenever the config bundle changes, rather
  than per session: a pod runs one profile, its MCP servers are a property of that
  profile, and asking four servers for their tool list at the start of every session
  would put somebody else's latency on the path of every create.

  A server that cannot be reached costs its tools and nothing else. A profile with four
  MCP servers and one of them down should lose that server's tools and keep working.

  The configs arrive in the bundle's wire shape, `permission` and `tools` included;
  `Troupe.MCP.Server.from_config/1` carries both, discovery drops the tools the
  allowlist does not name, and the permission becomes each tool's default. Nothing
  here has to know either exists.

  The MCP sessions the servers issue are the pod's (Decision 746), kept in the
  application's `Troupe.MCP.Sessions` under each server and credential: one for the
  profile's, one for each person's on a person-mode server, reused by every session on
  the pod and ended when the pod stops, or when a bundle drops their server (Decision
  757).
  """

  use GenServer

  alias Troupe.MCP
  alias Troupe.MCP.{Server, Sessions}

  require Logger

  defstruct servers: [], tools: [], discovered_at: nil, sessions: __MODULE__.Sessions

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Discover again, because the bundle changed or a server came back."
  @spec refresh(GenServer.server()) :: {:ok, [String.t()]}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 60_000)

  @doc "Replace the configured servers and discover their tools."
  @spec put_servers(GenServer.server(), [map()]) :: {:ok, [String.t()]}
  def put_servers(server \\ __MODULE__, configs) do
    GenServer.call(server, {:put_servers, configs}, 60_000)
  end

  @doc "What this pod currently offers, for the heartbeat and for tests."
  @spec tools(GenServer.server()) :: [Troupe.MCP.Tool.t()]
  def tools(server \\ __MODULE__), do: GenServer.call(server, :tools)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe mcp")
    servers = Keyword.get_lazy(opts, :servers, &configured/0)
    sessions = Keyword.get(opts, :sessions, __MODULE__.Sessions)
    {:ok, %__MODULE__{servers: servers, sessions: sessions}, {:continue, :discover}}
  end

  @impl GenServer
  def handle_continue(:discover, state), do: {:noreply, discover(state)}

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    state = discover(state)
    {:reply, {:ok, Enum.map(state.tools, & &1.name)}, state}
  end

  def handle_call({:put_servers, configs}, _from, state) do
    servers = Enum.map(configs, &Server.from_config/1)
    # A server the new bundle dropped has its sessions ended now rather than when the pod
    # stops; the others' are kept, and discovery goes on in them.
    state.sessions |> Sessions.table() |> Sessions.retain(servers)
    state = discover(%{state | servers: servers})
    {:reply, {:ok, Enum.map(state.tools, & &1.name)}, state}
  end

  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  defp discover(state) do
    # Read at every discovery, so a holder that was restarted is found again.
    table = Sessions.table(state.sessions)
    state = %{state | servers: Enum.map(state.servers, &%{&1 | sessions: table})}
    tools = MCP.all_tools(state.servers)

    # Published as a list rather than a function, so the agent loop reads it without a
    # call into this process — a tool lookup happens on every model turn and must not
    # queue behind a discovery.
    Application.put_env(:troupe_core, :remote_tools, tools)

    # The servers themselves, for the one question a tool's name cannot answer: which
    # credential a call to it goes out as. Published the same way and for the same
    # reason.
    Application.put_env(:troupe_core, :mcp_servers, state.servers)

    if tools != [] do
      Logger.info(
        "troupe worker: #{length(tools)} MCP tool(s) from #{length(state.servers)} server(s)"
      )
    end

    %{state | tools: tools, discovered_at: System.system_time(:second)}
  end

  defp configured do
    :troupe_worker
    |> Application.get_env(:mcp_servers, [])
    |> Enum.map(&Server.from_config/1)
  end
end
