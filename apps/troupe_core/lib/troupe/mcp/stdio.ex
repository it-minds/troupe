defmodule Troupe.MCP.Stdio do
  @moduledoc """
  One local MCP server on its standard streams (Decision 654).

  The server is a subprocess speaking newline-delimited JSON-RPC: `initialize`, then
  `tools/list`, then `tools/call` for as long as the session lives. It runs under the
  reaper in its stdio mode, so the owner's bytes reach it and the owner dying takes it
  down; on Windows, where the reaper has no such mode, it runs as a plain port and
  exits on its own when its stdin closes, which is what the MCP contract asks of it.

  The tools it advertises become `Troupe.MCP.Tool` values named `mcp.<server>.<tool>`,
  which is how every other MCP tool is spelled here, and go through the same allowlist,
  permission map and approval gate as a built-in.
  """

  use GenServer

  alias Troupe.MCP
  alias Troupe.MCP.Tool
  alias Troupe.Reaper

  require Logger

  @protocol_version "2025-06-18"
  @call_timeout 60_000

  defstruct [
    :session_id,
    :name,
    :config,
    :port,
    state: :connecting,
    error: nil,
    buffer: "",
    next_id: 1,
    pending: %{},
    tools: []
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.mcp_server(session_id, name))
  end

  @doc "The tools the server advertised, as `Troupe.MCP.Tool` values; `[]` until ready."
  @spec tools(String.t(), String.t()) :: [Tool.t()]
  def tools(session_id, name), do: call(session_id, name, :tools, [])

  @doc "What a client shows: `%{name, state, tools, error}`."
  @spec status(String.t(), String.t()) :: map()
  def status(session_id, name),
    do: call(session_id, name, :status, %{name: name, state: :stopped, tools: [], error: "not running"})

  @doc "Call one of the server's tools; the text of its content blocks, or the error."
  @spec call_tool(String.t(), String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def call_tool(session_id, name, tool, args) do
    GenServer.call(Troupe.Registry.mcp_server(session_id, name), {:call_tool, tool, args}, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, "the MCP server #{name} did not answer in time"}
    :exit, _ -> {:error, "the MCP server #{name} is not running"}
  end

  defp call(session_id, name, message, default) do
    GenServer.call(Troupe.Registry.mcp_server(session_id, name), message)
  catch
    :exit, _ -> default
  end

  ## Server

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    name = Keyword.fetch!(opts, :name)
    config = Keyword.fetch!(opts, :config)
    Process.set_label("troupe mcp #{name} #{session_id}")

    state = %__MODULE__{session_id: session_id, name: name, config: config}

    case open(config, Keyword.get(opts, :cwd)) do
      {:ok, port} ->
        {:ok, %{state | port: port}, {:continue, :initialize}}

      {:error, reason} ->
        Logger.warning("troupe: MCP server #{name} could not start: #{inspect(reason)}")
        {:ok, %{state | state: :error, error: "could not start: #{inspect(reason)}"}}
    end
  end

  @impl GenServer
  def handle_continue(:initialize, state) do
    {:noreply,
     request(state, "initialize", %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{},
       "clientInfo" => %{"name" => "troupe", "version" => version()}
     })}
  end

  @impl GenServer
  def handle_call(:tools, _from, state), do: {:reply, state.tools, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{name: state.name, state: state.state, tools: Enum.map(state.tools, & &1.remote_name), error: state.error},
     state}
  end

  def handle_call({:call_tool, tool, args}, from, %{state: :ready} = state) do
    id = state.next_id
    state = request(state, "tools/call", %{"name" => tool, "arguments" => args})
    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  def handle_call({:call_tool, _tool, _args}, _from, state) do
    {:reply, {:error, "the MCP server #{state.name} is #{state.state}: #{state.error || "still connecting"}"}, state}
  end

  @impl GenServer
  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    {:noreply, handle_line(state.buffer <> chunk, %{state | buffer: ""})}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    for {_id, from} <- state.pending, do: GenServer.reply(from, {:error, "the MCP server #{state.name} exited"})
    {:noreply, %{state | state: :stopped, error: "exited with status #{code}", pending: %{}, port: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Protocol

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id} = message} -> handle_reply(message, id, state)
      # Notifications and requests from the server: nothing this side acts on.
      {:ok, _} -> state
      {:error, _} -> state
    end
  end

  defp handle_reply(message, id, state) do
    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {:initialize, pending} -> after_initialize(message, %{state | pending: pending})
      {:tools_list, pending} -> after_tools_list(message, %{state | pending: pending})
      {from, pending} -> reply_tool(from, message, %{state | pending: pending})
    end
  end

  defp after_initialize(%{"result" => _}, state) do
    state
    |> notify("notifications/initialized", %{})
    |> request("tools/list", %{})
  end

  defp after_initialize(%{"error" => error}, state), do: fail(state, "initialize refused: #{describe(error)}")

  defp after_tools_list(%{"result" => %{"tools" => listed}}, state) when is_list(listed) do
    tools = Enum.map(listed, &tool(state, &1))
    Logger.debug("troupe: MCP server #{state.name} offers #{length(tools)} tools")
    %{state | tools: tools, state: :ready, error: nil}
  end

  defp after_tools_list(%{"error" => error}, state), do: fail(state, "tools/list refused: #{describe(error)}")
  defp after_tools_list(_other, state), do: fail(state, "tools/list answered without tools")

  defp reply_tool(from, %{"result" => %{"isError" => true} = result}, state) do
    GenServer.reply(from, {:error, render(result)})
    state
  end

  defp reply_tool(from, %{"result" => result}, state) do
    GenServer.reply(from, {:ok, render(result)})
    state
  end

  defp reply_tool(from, %{"error" => error}, state) do
    GenServer.reply(from, {:error, "the MCP server refused: #{describe(error)}"})
    state
  end

  defp tool(state, listed) do
    session_id = state.session_id
    name = state.name
    remote = listed["name"]

    %Tool{
      name: MCP.tool_name(name, remote),
      remote_name: remote,
      server: name,
      description: String.trim(listed["description"] || "A tool of the #{name} MCP server.") <> "\n\nProvided by the #{name} MCP server.",
      schema: listed["inputSchema"] || %{"type" => "object", "properties" => %{}},
      default_permission: Map.get(state.config, :permission, :ask),
      run: fn args, _ctx -> call_tool(session_id, name, remote, args) end
    }
  end

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

  defp describe(%{"message" => message}), do: message
  defp describe(error), do: inspect(error)

  defp fail(state, error) do
    Logger.warning("troupe: MCP server #{state.name}: #{error}")
    %{state | state: :error, error: error}
  end

  defp request(%{port: nil} = state, _method, _params), do: state

  defp request(state, method, params) do
    id = state.next_id
    send_json(state.port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})

    pending =
      case method do
        "initialize" -> Map.put(state.pending, id, :initialize)
        "tools/list" -> Map.put(state.pending, id, :tools_list)
        _ -> state.pending
      end

    %{state | next_id: id + 1, pending: pending}
  end

  defp notify(%{port: nil} = state, _method, _params), do: state

  defp notify(state, method, params) do
    send_json(state.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    state
  end

  defp send_json(port, message), do: Port.command(port, [Jason.encode!(message), "\n"])

  ## Process

  defp open(config, cwd) do
    config = Map.new(config, fn {key, value} -> {to_string(key), value} end)
    command = config["command"]
    env = Enum.map(config["env"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end)
    dir = config["cd"] || cwd || File.cwd!()

    case System.find_executable(command) do
      nil -> {:error, {:not_found, command}}
      exe -> Reaper.open_stdio(dir, [exe | List.wrap(config["args"])], env: env)
    end
  end

  defp version, do: to_string(Application.spec(:troupe_core, :vsn) || "dev")
end
