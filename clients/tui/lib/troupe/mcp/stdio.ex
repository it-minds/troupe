defmodule Troupe.MCP.Stdio do
  @moduledoc "Stdio MCP transport: runs a server subprocess via reaper in stdio mode."
  @behaviour Troupe.MCP.Transport

  use GenServer

  defstruct [:owner, :port, :buffer]

  @impl Troupe.MCP.Transport
  def start_link(owner, config) do
    GenServer.start_link(__MODULE__, %{owner: owner, config: config})
  end

  @impl Troupe.MCP.Transport
  def send_message(pid, data), do: GenServer.cast(pid, {:send, data})

  @impl Troupe.MCP.Transport
  def close(pid), do: GenServer.call(pid, :close)

  @impl GenServer
  def init(%{owner: owner, config: config}) do
    exe = System.find_executable(config.command) || config.command
    args = Map.get(config, :args, [])
    env = Map.get(config, :env, %{})
    cd = Map.get(config, :cd)

    env_list =
      Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end) ++
        [{"TROUPE_REAPER_STDIO", "1"}]

    port_opts =
      [:binary, :exit_status, :hide, args: [exe | args], env: env_list] ++ cd_opt(cd)

    port = Port.open({:spawn_executable, Troupe.Reaper.path!()}, port_opts)
    {:ok, %__MODULE__{owner: owner, port: port, buffer: ""}}
  end

  @impl GenServer
  def handle_cast({:send, data}, %__MODULE__{port: port} = state) do
    Port.command(port, [data, "\n"])
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:close, _from, %__MODULE__{port: port} = state) do
    Port.close(port)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %__MODULE__{port: port, owner: owner} = state) do
    buffer = state.buffer <> data
    {lines, rest} = split_lines(buffer)

    for line <- lines do
      if line != "", do: send(owner, {:mcp_data, line})
    end

    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({port, {:exit_status, code}}, %__MODULE__{port: port, owner: owner} = state) do
    send(owner, {:mcp_closed, {:exit_status, code}})
    {:noreply, state}
  end

  # Ignore messages from other ports.
  def handle_info({_, _}, state), do: {:noreply, state}

  defp cd_opt(nil), do: []
  defp cd_opt(dir), do: [cd: to_charlist(dir)]

  defp split_lines(buffer) do
    buffer
    |> String.split("\n", parts: :infinity)
    |> case do
      [] ->
        {[], ""}

      parts ->
        {done, [rest]} = Enum.split(parts, -1)
        {done, rest}
    end
  end
end
