defmodule Troupe.Worker.RecordingProxy do
  @moduledoc """
  A TCP relay that keeps a copy of everything that crosses it.

  The Forbidden list says no session content in the control channel, and the only
  honest way to check that is to look at the bytes. Asserting on the worker's own idea
  of what it sent would prove nothing: the question is precisely whether the code is
  wrong about that.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The port to point a client at."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Everything that has crossed, in both directions, as one blob."
  @spec captured(GenServer.server()) :: binary()
  def captured(server), do: GenServer.call(server, :captured)

  @impl GenServer
  def init(opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    relay = self()
    spawn_link(fn -> accept(listen, upstream, relay) end)

    {:ok, %{listen: listen, port: port, captured: []}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:captured, _from, state) do
    {:reply, state.captured |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  @impl GenServer
  def handle_info({:captured, data}, state), do: {:noreply, %{state | captured: [data | state.captured]}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  defp accept(listen, upstream, relay) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        # The accepting process owns the socket until it says otherwise, and a relay
        # that never takes ownership would sit waiting for messages delivered to
        # somebody else.
        pid = spawn(fn -> pair(client, upstream, relay) end)
        :gen_tcp.controlling_process(client, pid)
        send(pid, :socket_ready)
        accept(listen, upstream, relay)

      {:error, _reason} ->
        :ok
    end
  end

  defp pair(client, upstream, relay) do
    receive do
      :socket_ready -> :ok
    after
      5_000 -> :ok
    end

    case :gen_tcp.connect(~c"127.0.0.1", upstream, [:binary, active: true, packet: :raw]) do
      {:ok, server} ->
        :inet.setopts(client, active: true)
        pump(client, server, relay)

      {:error, _reason} ->
        :gen_tcp.close(client)
    end
  end

  defp pump(client, server, relay) do
    receive do
      {:tcp, ^client, data} ->
        send(relay, {:captured, data})
        :gen_tcp.send(server, data)
        pump(client, server, relay)

      {:tcp, ^server, data} ->
        send(relay, {:captured, data})
        :gen_tcp.send(client, data)
        pump(client, server, relay)

      {:tcp_closed, _socket} ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)

      {:tcp_error, _socket, _reason} ->
        :gen_tcp.close(client)
        :gen_tcp.close(server)
    end
  end
end
