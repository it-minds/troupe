defmodule Troupe.Gateway.Listener do
  @moduledoc """
  Accepts client connections and hands each socket to its own process.

  Two transports, one framing. A Unix socket at `$XDG_RUNTIME_DIR/troupe/daemon.sock`
  with mode `0600`, where the file permissions *are* the authentication: if you can
  open it you are the user who owns it. Where `AF_UNIX` is unavailable — Windows, on
  OTP builds without it — loopback TCP with a random token in a user-only file, which
  is the same trust boundary expressed differently.

  A stale socket file from a daemon that was killed is removed only after checking
  that nothing answers on it, so two daemons can never both think they own it.
  """

  use GenServer

  alias Troupe.Gateway.Connections
  alias Troupe.Protocol.Endpoint

  require Logger

  @enforce_keys [:socket, :endpoint]
  defstruct [:socket, :endpoint, :acceptor, connection_opts: []]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where this daemon is listening."
  @spec endpoint() :: Endpoint.t()
  def endpoint, do: GenServer.call(__MODULE__, :endpoint)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.set_label("troupe listener")

    endpoint = Keyword.get_lazy(opts, :endpoint, &Endpoint.default/0)

    case listen(endpoint) do
      {:ok, socket} ->
        state = %__MODULE__{
          socket: socket,
          endpoint: endpoint,
          connection_opts: Keyword.take(opts, [:outbound_bound, :durable_bound])
        }
        Endpoint.publish!(endpoint)
        {:ok, %{state | acceptor: spawn_acceptor(socket)}}

      {:error, reason} ->
        {:stop, {:listen_failed, Endpoint.describe(endpoint), reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{} = state) do
    :gen_tcp.close(state.socket)
    Endpoint.retract(state.endpoint)
    :ok
  end

  @impl GenServer
  def handle_call(:endpoint, _from, state), do: {:reply, state.endpoint, state}

  @impl GenServer
  def handle_info({:accepted, socket}, state) do
    attach_opts = [socket: socket, endpoint: state.endpoint] ++ state.connection_opts

    case Connections.attach(attach_opts) do
      {:ok, pid} ->
        # The connection must own the socket before it can read from it: a passive
        # socket read by a process that does not own it is not guaranteed to deliver.
        #
        # The hand-off can fail, and routinely does: a client probing whether anyone
        # is listening connects and closes immediately, so by the time we get here the
        # port may already be gone. That is an ordinary event, not a listener fault —
        # crashing on it would let anyone take the daemon down by knocking on the door
        # five times.
        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            send(pid, :socket_ready)

          {:error, _reason} ->
            :gen_tcp.close(socket)
            GenServer.stop(pid, :normal)
        end

      {:error, reason} ->
        Logger.warning("troupe: refusing a connection: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    # The acceptor only exits when the listen socket closes, which is a shutdown.
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp spawn_acceptor(socket) do
    parent = self()
    spawn_link(fn -> accept_loop(parent, socket) end)
  end

  defp accept_loop(parent, socket) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        # The acceptor owns what it accepts, so it hands the socket to the listener
        # before announcing it; otherwise the listener cannot pass it on again.
        :ok = :gen_tcp.controlling_process(client, parent)
        send(parent, {:accepted, client})
        accept_loop(parent, socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("troupe: accept failed: #{inspect(reason)}")
        accept_loop(parent, socket)
    end
  end

  # Reads are raw and buffered by the connection rather than framed by `packet: :line`,
  # because a line may legitimately be megabytes and `:line` splits those across
  # deliveries anyway — buffering once, in one place, is simpler than reassembling.
  # No `send_timeout`: writes happen in `Gateway.Writer`, which can afford to block on
  # a client that has stopped reading, and a timed-out send leaves an unspecified
  # amount of a message on the wire — a half-written line that the next write would
  # append to. Blocking one writer process costs nothing; a corrupted stream costs the
  # client its session view. A peer that is truly gone reaches the connection as
  # `tcp_closed` instead.
  @socket_opts [
    :binary,
    active: false,
    packet: :raw,
    reuseaddr: true,
    # Ten terminals starting at once is a normal morning, and the default backlog of
    # five turns the eleventh into a reset connection rather than a queued one.
    backlog: 256
  ]

  defp listen(%Endpoint{kind: :unix, path: path}) do
    File.mkdir_p!(Path.dirname(path))
    clear_stale_socket(path)

    with {:ok, socket} <- :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | @socket_opts]),
         :ok <- File.chmod(path, 0o600) do
      {:ok, socket}
    end
  end

  defp listen(%Endpoint{kind: :tcp, port: port}) do
    :gen_tcp.listen(port, [{:ip, {127, 0, 0, 1}} | @socket_opts])
  end

  # A socket file left by a killed daemon has to go, but only once we know nothing is
  # answering on it — otherwise two daemons race for the same path and clients split
  # between them.
  defp clear_stale_socket(path) do
    if File.exists?(path) do
      case :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 250) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          raise "a troupe daemon is already listening on #{path}"

        {:error, _} ->
          File.rm(path)
      end
    end
  end
end
