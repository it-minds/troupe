defmodule Troupe.Worker.Service do
  @moduledoc """
  A Kubernetes Service, in about eighty lines.

  Workers dial one address and the Service picks a replica; when that replica goes away
  the next dial goes to a survivor. That is the whole of why losing a plane replica is a
  reconnect rather than an outage, and it is the piece a test running two replicas in one
  machine would otherwise have to imagine.

  Connections already established are *not* moved, because a real Service does not move
  them either: a TCP connection to a pod that has gone is a connection that breaks, and
  the worker noticing and dialling again is the behaviour under test.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "The port clients dial."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "Replace the set of backends, as an endpoints controller would."
  @spec put_backends(GenServer.server(), [:inet.port_number()]) :: :ok
  def put_backends(server, ports), do: GenServer.call(server, {:put_backends, ports})

  @doc "How many connections this Service has forwarded, and to where."
  @spec stats(GenServer.server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @impl GenServer
  def init(opts) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    service = self()
    spawn_link(fn -> accept(listen, service) end)

    {:ok, %{listen: listen, port: port, backends: Keyword.get(opts, :backends, []), forwarded: []}}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call({:put_backends, ports}, _from, state), do: {:reply, :ok, %{state | backends: ports}}

  def handle_call(:stats, _from, state) do
    {:reply, %{backends: state.backends, forwarded: Enum.reverse(state.forwarded)}, state}
  end

  # Asked per connection rather than held, so a backend removed between two dials is
  # really gone for the second one.
  def handle_call(:pick, _from, state) do
    case reachable(state.backends) do
      nil -> {:reply, :none, state}
      port -> {:reply, port, %{state | forwarded: [port | state.forwarded]}}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  # A Service routes to *ready* endpoints. Probing the port is this test's readiness
  # check, and it is what makes a killed replica stop receiving connections.
  defp reachable(ports) do
    Enum.find(ports, fn port ->
      case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 100) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _reason} ->
          false
      end
    end)
  end

  defp accept(listen, service) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        pid = spawn(fn -> forward(client, service) end)
        :gen_tcp.controlling_process(client, pid)
        send(pid, :ready)
        accept(listen, service)

      {:error, _reason} ->
        :ok
    end
  end

  defp forward(client, service) do
    receive do
      :ready -> :ok
    after
      1_000 -> :ok
    end

    case GenServer.call(service, :pick) do
      :none ->
        :gen_tcp.close(client)

      port ->
        case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true, packet: :raw]) do
          {:ok, upstream} ->
            :inet.setopts(client, active: true)
            pump(client, upstream)

          {:error, _reason} ->
            :gen_tcp.close(client)
        end
    end
  end

  defp pump(client, upstream) do
    receive do
      {:tcp, ^client, data} ->
        :gen_tcp.send(upstream, data)
        pump(client, upstream)

      {:tcp, ^upstream, data} ->
        :gen_tcp.send(client, data)
        pump(client, upstream)

      {:tcp_closed, _socket} ->
        close(client, upstream)

      {:tcp_error, _socket, _reason} ->
        close(client, upstream)
    end
  end

  defp close(client, upstream) do
    :gen_tcp.close(client)
    :gen_tcp.close(upstream)
  end
end
