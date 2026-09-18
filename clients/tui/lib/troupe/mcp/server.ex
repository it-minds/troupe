defmodule Troupe.MCP.Server do
  @moduledoc """
  One MCP server connection. Negotiates initialize/tools/list on startup, then
  serves `tools/call` requests routed from `Troupe.MCP`.
  """

  use GenServer

  alias Troupe.Events
  alias Troupe.MCP.{InProcess, JSONRPC, SSE, Stdio}

  defstruct [
    :session_id,
    :name,
    :transport_mod,
    :transport_pid,
    tools: [],
    state: :connecting,
    error: nil,
    id: 0,
    pending: %{}
  ]

  ## API

  def start_link(%{session_id: sid, name: name, config: config}) do
    GenServer.start_link(__MODULE__, %{session_id: sid, name: name, config: config},
      name: Troupe.Session.via(sid, {:mcp_server, name})
    )
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts.name},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @spec call_tool(pid(), String.t(), map(), timeout()) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_tool(pid, tool_name, args, timeout) do
    GenServer.call(pid, {:call_tool, tool_name, args}, timeout)
  catch
    :exit, reason -> {:error, "server call failed: #{inspect(reason)}"}
  end

  @spec specs(pid()) :: [%{name: String.t(), description: String.t(), input_schema: map()}]
  def specs(pid) do
    GenServer.call(pid, :specs)
  end

  @spec status(pid()) :: %{
          name: String.t(),
          state: atom(),
          tools: non_neg_integer(),
          error: String.t() | nil
        }
  def status(pid) do
    GenServer.call(pid, :status)
  end

  ## Server

  @impl GenServer
  def init(%{session_id: sid, name: name, config: config}) do
    transport_mod = pick_transport(config)
    {:ok, transport_pid} = transport_mod.start_link(self(), config)

    Events.notify(sid, "mcp", :mcp_status, %{
      server: name,
      state: :connecting,
      tools: [],
      error: nil
    })

    state = %__MODULE__{
      session_id: sid,
      name: name,
      transport_mod: transport_mod,
      transport_pid: transport_pid
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl GenServer
  def handle_continue(:initialize, %__MODULE__{} = state) do
    params = %{
      protocolVersion: "2024-11-05",
      capabilities: %{},
      clientInfo: %{name: "troupe", version: "1.0.0"}
    }

    {state, _id} = send_request(state, "initialize", params)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:call_tool, tool_name, args}, from, %__MODULE__{} = state) do
    case state.state do
      :error ->
        {:reply, {:error, state.error || "server error"}, state}

      :connecting ->
        {:reply, {:error, "server is still connecting"}, state}

      :ready ->
        params = %{name: tool_name, arguments: args}
        {state, id} = send_request(state, "tools/call", params)

        state = %{
          state
          | pending: Map.put(state.pending, to_string(id), %{from: from, method: "tools/call"})
        }

        {:noreply, state}
    end
  end

  def handle_call(:specs, _from, %__MODULE__{} = state) do
    {:reply, state.tools, state}
  end

  def handle_call(:status, _from, %__MODULE__{} = state) do
    {:reply,
     %{name: state.name, state: state.state, tools: length(state.tools), error: state.error}, state}
  end

  @impl GenServer
  def handle_info({:mcp_data, binary}, %__MODULE__{} = state) do
    case JSONRPC.decode(binary) do
      {:ok, msg} when is_map(msg) ->
        handle_message(msg, state)

      {:ok, _} ->
        {:noreply, state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_closed, reason}, %__MODULE__{} = state) do
    state = set_error(state, to_string(reason))

    # Reply to anyone waiting on a tool call.
    state =
      Enum.reduce(state.pending, state, fn {_id, %{from: from}}, st ->
        GenServer.reply(from, {:error, "server closed"})
        st
      end)

    {:noreply, %{state | pending: %{}}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp handle_message(%{"id" => id} = msg, %__MODULE__{} = state) do
    id_str = to_string(id)

    case Map.get(state.pending, id_str) do
      %{lifecycle: method} ->
        state = handle_lifecycle(msg, method, state)
        {:noreply, state}

      nil ->
        # A response we did not expect, or a lifecycle reply whose id we already dropped.
        state = handle_lifecycle(msg, nil, state)
        {:noreply, state}

      %{from: from, method: method} ->
        case msg do
          %{"result" => %{"isError" => true} = result} ->
            text = extract_text(Map.get(result, "content", []))
            GenServer.reply(from, {:error, text})
            {:noreply, drop_pending(state, id_str)}

          %{"result" => result} when method == "tools/call" ->
            text = extract_text(Map.get(result, "content", []))
            GenServer.reply(from, {:ok, text})
            {:noreply, drop_pending(state, id_str)}

          %{"result" => _result} ->
            # Generic success for non-tools/call calls (shouldn't happen, but be safe).
            GenServer.reply(from, {:ok, "ok"})
            {:noreply, drop_pending(state, id_str)}

          %{"error" => %{"message" => message}} ->
            GenServer.reply(from, {:error, message})
            {:noreply, drop_pending(state, id_str)}

          %{"error" => error} ->
            GenServer.reply(from, {:error, inspect(error)})
            {:noreply, drop_pending(state, id_str)}
        end
    end
  end

  defp handle_message(_msg, state), do: {:noreply, state}

  # The initialize response: send initialized notification, then tools/list.
  defp handle_lifecycle(%{"result" => _result} = msg, "initialize", %__MODULE__{} = state) do
    state = drop_pending(state, to_string(msg["id"]))
    state = send_notification(state, "notifications/initialized", %{})
    {state, _id} = send_request(state, "tools/list", %{})
    state
  end

  # The tools/list response: map tools to namespaced specs, mark :ready, emit :mcp_status.
  defp handle_lifecycle(
         %{"result" => %{"tools" => tools}} = msg,
         "tools/list",
         %__MODULE__{} = state
       ) do
    state = drop_pending(state, to_string(msg["id"]))

    specs =
      Enum.map(tools, fn t ->
        %{
          name: "mcp__#{state.name}__#{t["name"]}",
          description: Map.get(t, "description", ""),
          input_schema: Map.get(t, "inputSchema", %{}) || %{}
        }
      end)

    state = %{state | tools: specs, state: :ready}

    Events.notify(state.session_id, "mcp", :mcp_status, %{
      server: state.name,
      state: :ready,
      tools: specs,
      error: nil
    })

    state
  end

  defp handle_lifecycle(%{"error" => %{"message" => message}}, _method, %__MODULE__{} = state) do
    set_error(state, message)
  end

  defp handle_lifecycle(_msg, _method, state), do: state

  defp set_error(%__MODULE__{} = state, message) do
    state = %{state | state: :error, error: message}

    Events.notify(state.session_id, "mcp", :mcp_status, %{
      server: state.name,
      state: :error,
      tools: state.tools,
      error: message
    })

    state
  end

  defp drop_pending(%__MODULE__{} = state, id_str) do
    %{state | pending: Map.delete(state.pending, id_str)}
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", fn %{"text" => text} -> text end)
  end

  defp extract_text(_), do: ""

  defp send_request(%__MODULE__{} = state, method, params) do
    id = state.id + 1
    json = JSONRPC.request(id, method, params)
    state.transport_mod.send_message(state.transport_pid, json)

    pending =
      if method in ["initialize", "tools/list"] do
        Map.put(state.pending, to_string(id), %{lifecycle: method})
      else
        state.pending
      end

    {%{state | id: id, pending: pending}, id}
  end

  defp send_notification(%__MODULE__{} = state, method, params) do
    json = JSONRPC.notification(method, params)
    state.transport_mod.send_message(state.transport_pid, json)
    state
  end

  defp pick_transport(%{command: _}), do: Stdio
  defp pick_transport(%{url: _}), do: SSE
  defp pick_transport(%{handler: _}), do: InProcess
end
