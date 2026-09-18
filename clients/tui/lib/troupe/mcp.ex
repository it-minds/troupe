defmodule Troupe.MCP do
  @moduledoc """
  Public API for MCP (Model Context Protocol) servers. Per-session: a
  `Troupe.MCP.Supervisor` child of `Troupe.Session` starts one
  `Troupe.MCP.Server` per configured server. MCP tools are namespaced
  `mcp__<server>__<tool>` and flow through the existing Tool seam
  (`%{name, description, input_schema}`), so providers/UI/approvals are unchanged.
  """

  alias Troupe.MCP.{Server, Supervisor}

  @doc "Starts the per-session MCP supervisor and all configured servers."
  @spec start_session(String.t(), map()) :: :ok | {:error, term()}
  def start_session(session_id, servers) when is_binary(session_id) do
    case Troupe.Session.whereis(session_id, :mcp) do
      nil ->
        case DynamicSupervisor.start_link(Supervisor, %{session_id: session_id},
               name: Troupe.Session.via(session_id, :mcp)
             ) do
          {:ok, _pid} ->
            if map_size(servers) > 0, do: Supervisor.start_servers(session_id, servers)
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _pid ->
        :ok
    end
  end

  @doc "Stops all MCP servers for a session."
  @spec stop_session(String.t()) :: :ok
  def stop_session(session_id) do
    Supervisor.stop_servers(session_id)
  end

  @doc """
  Aggregated tool specs for the LLM. Namespaced `mcp__<server>__<tool>`.
  Returns `[]` if no MCP supervisor is running.
  """
  @spec tool_specs(String.t()) :: [
          %{name: String.t(), description: String.t(), input_schema: map()}
        ]
  def tool_specs(session_id) do
    for {name, _config} <- servers_for(session_id),
        pid = Troupe.Session.whereis(session_id, {:mcp_server, to_string(name)}),
        pid != nil,
        spec <- Server.specs(pid) do
      spec
    end
  end

  @doc "Calls an MCP tool by its namespaced name. Routes to the owning server."
  @spec call(String.t(), String.t(), map(), timeout()) :: {:ok, String.t()} | {:error, String.t()}
  def call(session_id, name, args, timeout) do
    case parse_name(name) do
      {:ok, server_name, tool_name} ->
        case Troupe.Session.whereis(session_id, {:mcp_server, server_name}) do
          nil -> {:error, "MCP server #{server_name} is not running"}
          pid -> Server.call_tool(pid, tool_name, args, timeout)
        end

      :error ->
        {:error, "not an MCP tool: #{name}"}
    end
  end

  @doc "Effective permission for an MCP tool. Default `:ask` (reuses the existing approval door)."
  @spec permission(String.t(), String.t()) :: :auto | :ask | :deny
  def permission(_session_id, name) do
    if mcp?(name), do: :ask, else: :deny
  end

  @doc "Is this name an MCP tool? (prefix `mcp__`)"
  @spec mcp?(String.t()) :: boolean()
  def mcp?(name) when is_binary(name), do: String.starts_with?(name, "mcp__")

  @doc "Server statuses for the UI."
  @spec status(String.t()) :: [
          %{name: String.t(), state: atom(), tools: non_neg_integer(), error: String.t() | nil}
        ]
  def status(session_id) do
    for {name, _config} <- servers_for(session_id),
        pid = Troupe.Session.whereis(session_id, {:mcp_server, to_string(name)}),
        pid != nil do
      Server.status(pid)
    end
  end

  ## Internals

  # We don't have the original config map here; instead, discover running servers
  # by querying the supervisor's children.
  defp servers_for(session_id) do
    case Troupe.Session.whereis(session_id, :mcp) do
      nil ->
        []

      sup ->
        case DynamicSupervisor.which_children(sup) do
          children ->
            Enum.map(children, fn {_, pid, _, _} ->
              if is_pid(pid) and Process.alive?(pid) do
                %{name: name} = Server.status(pid)
                {name, %{}}
              else
                {"", %{}}
              end
            end)
        end
    end
  end

  defp parse_name("mcp__" <> rest) do
    case String.split(rest, "__", parts: 2) do
      [server, tool] when server != "" and tool != "" -> {:ok, server, tool}
      _ -> :error
    end
  end

  defp parse_name(_), do: :error
end
