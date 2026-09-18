defmodule Troupe.MCP.SSE do
  @moduledoc "SSE/HTTP MCP transport (secondary). Connects to a server event stream."
  @behaviour Troupe.MCP.Transport

  use GenServer
  require Logger

  defstruct [:owner, :url, :req_pid]

  @impl Troupe.MCP.Transport
  def start_link(owner, config) do
    GenServer.start_link(__MODULE__, %{owner: owner, url: config.url})
  end

  @impl Troupe.MCP.Transport
  def send_message(pid, data), do: GenServer.cast(pid, {:send, data})

  @impl Troupe.MCP.Transport
  def close(pid), do: GenServer.call(pid, :close)

  @impl GenServer
  def init(%{owner: owner, url: url}) do
    send(self(), :connect)
    {:ok, %__MODULE__{owner: owner, url: url}}
  end

  @impl GenServer
  def handle_info(:connect, %__MODULE__{owner: _owner, url: url} = state) do
    parent = self()

    pid =
      spawn(fn ->
        case Req.get(req(url),
               into: fn {:data, data}, acc ->
                 parent_pid = parent
                 send(parent_pid, {:sse_data, data})
                 {:cont, acc}
               end
             ) do
          {:ok, _} -> send(parent, {:mcp_closed, :stream_end})
          {:error, reason} -> send(parent, {:mcp_closed, reason})
        end
      end)

    {:noreply, %{state | req_pid: pid}}
  end

  def handle_info({:sse_data, data}, %__MODULE__{owner: owner} = state) do
    for line <- String.split(data, "\n") do
      line = String.trim(line)

      if String.starts_with?(line, "data:") do
        payload = String.trim(String.slice(line, 5, String.length(line)))

        if payload != "", do: send(owner, {:mcp_data, payload})
      end
    end

    {:noreply, state}
  end

  def handle_info({:mcp_closed, reason}, %__MODULE__{owner: owner} = state) do
    send(owner, {:mcp_closed, reason})
    {:noreply, %{state | req_pid: nil}}
  end

  @impl GenServer
  def handle_cast({:send, data}, %__MODULE__{url: url} = state) do
    case Req.post(req(url), json: Jason.decode!(data)) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("MCP SSE post failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:close, _from, %__MODULE__{req_pid: pid} = state) do
    if pid, do: Process.exit(pid, :kill)
    {:reply, :ok, %{state | req_pid: nil}}
  end

  defp req(url), do: Req.new(url: url)
end
