defmodule Troupe.Plane.Control.Listener do
  @moduledoc """
  Where workers dial in.

  Never exposed through ingress. A worker's NetworkPolicy allows exactly this port on
  exactly the plane's namespace, and nothing outside the cluster can reach it — which is
  why the enrolment token is the whole of the authentication and there is no second
  factor to get wrong.

  Workers dial the plane rather than the other way round because a pod's address is a
  property of the cluster and a plane replica's is not: the worker knows where the
  plane is from one Service name, and the plane learns where the worker is when it
  arrives.
  """

  use GenServer

  alias Troupe.Plane.Control.Connections

  require Logger

  @enforce_keys [:socket]
  defstruct [:socket, :acceptor, :port, options: []]

  @socket_opts [
    :binary,
    active: false,
    packet: :raw,
    reuseaddr: true,
    backlog: 128
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The port this listener is on, which is useful when it was asked for port 0."
  @spec port() :: :inet.port_number()
  def port, do: GenServer.call(__MODULE__, :port)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.set_label("troupe control listener")

    port = Keyword.get(opts, :port, Application.get_env(:troupe_plane, :control_port, 4001))

    case :gen_tcp.listen(port, @socket_opts) do
      {:ok, socket} ->
        {:ok, actual} = :inet.port(socket)
        Logger.info("troupe plane: control listener on #{actual}")

        state = %__MODULE__{socket: socket, port: actual, options: opts}
        {:ok, %{state | acceptor: spawn_acceptor(socket)}}

      {:error, reason} ->
        {:stop, {:listen_failed, port, reason}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def handle_info({:accepted, socket}, state) do
    case Connections.attach(Keyword.put(state.options, :socket, socket)) do
      {:ok, pid} ->
        case :gen_tcp.controlling_process(socket, pid) do
          :ok ->
            send(pid, :socket_ready)

          {:error, _reason} ->
            # A worker that hung up between accept and hand-off. Ordinary.
            :gen_tcp.close(socket)
            GenServer.stop(pid, :normal)
        end

      {:error, reason} ->
        Logger.warning("troupe plane: refusing a control connection: #{inspect(reason)}")
        :gen_tcp.close(socket)
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

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
        Logger.warning("troupe plane: control accept failed: #{inspect(reason)}")
        accept_loop(parent, socket)
    end
  end
end

defmodule Troupe.Plane.Control.Connections do
  @moduledoc """
  One process per attached worker, and a way to find them.

  Registered by pod so the plane can push to a particular worker — `drain`,
  `session.restore`, `session.erase` — and by profile so it can push to all of a
  profile's pods at once, which is what publishing a config bundle does.

  Registration happens at *enrolment*, not at connection: a socket that has not proved
  which pod it is has no name worth registering.
  """

  use DynamicSupervisor

  @registry Troupe.Plane.Control.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 512)

  @doc "Start a connection process owning an accepted socket."
  @spec attach(keyword()) :: DynamicSupervisor.on_start_child()
  def attach(opts), do: DynamicSupervisor.start_child(__MODULE__, {Troupe.Plane.Control.Connection, opts})

  @doc "The registry connections register themselves in once they have enrolled."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  The connection for one pod, or `nil`.

  The newest, when there is more than one: a pod replaced under its own name enrols
  before its predecessor's socket has closed, and for a moment both are registered. The
  older is on its way out — `Connection.register/1` drops it — and a question sent to it
  would never be answered. Accepting exactly one, as this used to, answered nobody.
  """
  @spec for_pod(String.t(), String.t()) :: pid() | nil
  def for_pod(namespace, pod_name) do
    case lookup({:pod, namespace, pod_name}) do
      [] -> nil
      entries -> entries |> Enum.max_by(fn {_pid, {_worker_id, since}} -> since end) |> elem(0)
    end
  end

  @doc "Every connected pod of a profile."
  @spec for_profile(String.t()) :: [pid()]
  def for_profile(profile), do: {:profile, profile} |> lookup() |> Enum.map(&elem(&1, 0))

  # A plane whose control listener is not running has no workers attached, which is the
  # same answer as "none are". Asking who is connected must not be a way to crash a
  # caller that had no reason to care whether the listener was up.
  defp lookup(key) do
    Registry.lookup(@registry, key)
  rescue
    ArgumentError -> []
  end

  @doc "How many workers are attached to this replica."
  @spec count() :: non_neg_integer()
  def count, do: DynamicSupervisor.count_children(__MODULE__).active
end
