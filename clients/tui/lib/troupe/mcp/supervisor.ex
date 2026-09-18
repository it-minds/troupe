defmodule Troupe.MCP.Supervisor do
  @moduledoc """
  Per-session supervisor for MCP server connections. A DynamicSupervisor child
  of `Troupe.Session` (started last, so its crashes don't restart the
  Dispatcher/Watcher). Each MCP server runs as a `Troupe.MCP.Server` with
  `:transient` restart.
  """

  use DynamicSupervisor

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{session_id: sid, servers: servers} = opts) do
    case DynamicSupervisor.start_link(__MODULE__, opts, name: Troupe.Session.via(sid, :mcp)) do
      {:ok, _pid} = result ->
        if is_map(servers) and map_size(servers) > 0, do: start_servers(sid, servers)
        result

      other ->
        other
    end
  end

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Starts one `Troupe.MCP.Server` child per configured server. `servers` is a map of name => config."
  @spec start_servers(String.t(), map()) :: :ok
  def start_servers(sid, servers) when is_map(servers) do
    for {name, config} <- servers do
      child_spec = %{
        id: {Troupe.MCP.Server, name},
        start:
          {Troupe.MCP.Server, :start_link,
           [%{session_id: sid, name: to_string(name), config: config}]},
        restart: :transient
      }

      DynamicSupervisor.start_child(Troupe.Session.via(sid, :mcp), child_spec)
    end

    :ok
  end

  @doc "Stops all MCP servers for a session."
  @spec stop_servers(String.t()) :: :ok
  def stop_servers(sid) do
    case Troupe.Session.whereis(sid, :mcp) do
      nil -> :ok
      sup -> DynamicSupervisor.stop(sup, :normal)
    end
  end
end
