defmodule Troupe.MCP.InProcess do
  @moduledoc "In-process MCP transport for tests. No OS process, no reaper."
  @behaviour Troupe.MCP.Transport

  use GenServer

  defstruct [:owner, :handler]

  @impl Troupe.MCP.Transport
  def start_link(owner, config),
    do: GenServer.start_link(__MODULE__, %{owner: owner, handler: config.handler})

  @impl Troupe.MCP.Transport
  def send_message(pid, data), do: GenServer.cast(pid, {:send, data})

  @impl Troupe.MCP.Transport
  def close(pid), do: GenServer.call(pid, :close)

  @impl GenServer
  def init(%{owner: owner, handler: handler}),
    do: {:ok, %__MODULE__{owner: owner, handler: handler}}

  @impl GenServer
  def handle_cast({:send, data}, %__MODULE__{owner: owner, handler: handler} = state) do
    handler.(owner, data)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:close, _from, state), do: {:reply, :ok, state}
end
