defmodule Troupe.Client.Daemon.Link do
  @moduledoc """
  This process's connection to the local daemon — and the daemon itself, when none is
  running.

  On the first call it finds a daemon the way any client does (`Troupe.Protocol.Daemon`:
  `daemon.json`, a socket that answers) and, finding none, starts one *in this VM*: the
  same `Troupe.Gateway.Daemon` supervision tree the `troupe-daemon` binary runs, under
  `Troupe.Client.Daemons`, with the loopback WebSocket on. The TUI then talks to it over
  that socket like anything else would; embedding saves a process, not a protocol. The
  embedded daemon lives as long as this VM does and never idles out from under the UI.

  Fleet-level calls (`session.list`, `session.create`, `agents.list`, `worktree.list`,
  `identity.get`) go over one `Troupe.Protocol.Client` on the native transport; each
  attached session has its own `Troupe.Remote.Worker` on the WebSocket, so a session's
  stream never queues behind a listing.
  """

  use GenServer

  alias Troupe.Protocol.{Client, Endpoint}

  require Logger

  @name __MODULE__
  @call_timeout 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "Call a daemon method, starting or finding the daemon first."
  @spec call(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call(method, params),
    do: GenServer.call(@name, {:call, method, params}, @call_timeout + 5_000)

  @doc "The loopback WebSocket the daemon serves, for a per-session worker connection."
  @spec websocket() :: {:ok, %{port: :inet.port_number(), token: String.t()}} | {:error, term()}
  def websocket, do: GenServer.call(@name, :websocket, @call_timeout)

  @doc "Make sure a daemon is answering; say where."
  @spec ensure() :: {:ok, Endpoint.t()} | {:error, term()}
  def ensure, do: GenServer.call(@name, :ensure, @call_timeout)

  @spec up?() :: boolean()
  def up? do
    GenServer.call(@name, :up?)
  catch
    :exit, _ -> false
  end

  @spec error() :: term() | nil
  def error do
    GenServer.call(@name, :error)
  catch
    :exit, _ -> :not_started
  end

  @doc "Remember what `watch.set` answered for a session, for the status line."
  @spec put_watch(String.t(), boolean(), String.t() | nil) :: :ok
  def put_watch(sid, enabled?, backend), do: GenServer.cast(@name, {:watch, sid, enabled?, backend})

  @spec watch_status(String.t()) :: map()
  def watch_status(sid) do
    GenServer.call(@name, {:watch_status, sid})
  catch
    :exit, _ -> %{enabled: false, backend: nil}
  end

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{client: nil, endpoint: nil, embedded: nil, error: nil, watch: %{}}}
  end

  @impl true
  def handle_call(:up?, _from, state), do: {:reply, state.client != nil, state}
  def handle_call(:error, _from, state), do: {:reply, state.error, state}

  def handle_call({:watch_status, sid}, _from, state),
    do: {:reply, Map.get(state.watch, sid, %{enabled: false, backend: nil}), state}

  def handle_call(:ensure, _from, state) do
    case ensure_daemon(state) do
      {:ok, state} -> {:reply, {:ok, state.endpoint}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:websocket, _from, state) do
    case ensure_daemon(state) do
      {:ok, state} ->
        case Endpoint.discover_ws() do
          {:ok, ws} -> {:reply, {:ok, ws}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:call, method, params}, _from, state) do
    case ensure_client(state) do
      {:ok, state} ->
        case Client.call(state.client, method, params, @call_timeout) do
          {:ok, result} -> {:reply, {:ok, result}, state}
          {:error, %{} = error} -> {:reply, {:error, error_message(error)}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:watch, sid, enabled?, backend}, state) do
    {:noreply, %{state | watch: Map.put(state.watch, sid, %{enabled: enabled?, backend: backend})}}
  end

  # The protocol client reports its socket going away; the next call reconnects.
  @impl true
  def handle_info({:troupe_disconnected, reason}, state) do
    Logger.debug("daemon link: disconnected (#{inspect(reason)})")
    {:noreply, %{state | client: nil, error: reason}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Finding or starting the daemon

  defp ensure_daemon(%{endpoint: %Endpoint{} = endpoint} = state) do
    if Troupe.Protocol.Daemon.running?(endpoint: endpoint),
      do: {:ok, state},
      else: ensure_daemon(%{state | endpoint: nil, client: nil})
  end

  defp ensure_daemon(state) do
    case Troupe.Protocol.Daemon.ensure_running(spawn: false) do
      {:ok, endpoint} ->
        {:ok, %{state | endpoint: endpoint, error: nil}}

      {:error, :not_running} ->
        embed(state)
    end
  end

  # No daemon on this machine: run one here. Idle shutdown is off — the UI in front of
  # it is what keeps it up, and the UI going away takes the VM with it.
  defp embed(state) do
    spec =
      {Troupe.Gateway.Daemon, loopback: [enabled: true], idle_shutdown_ms: :timer.hours(24 * 365)}

    case DynamicSupervisor.start_child(Troupe.Client.Daemons, spec) do
      {:ok, pid} -> discovered(%{state | embedded: pid})
      {:error, {:already_started, pid}} -> discovered(%{state | embedded: pid})
      {:error, reason} -> {:error, {:daemon_failed, reason}, %{state | error: reason}}
    end
  end

  defp discovered(state) do
    case Endpoint.discover() do
      {:ok, endpoint} -> {:ok, %{state | endpoint: endpoint, error: nil}}
      {:error, reason} -> {:error, reason, %{state | error: reason}}
    end
  end

  defp ensure_client(%{client: client} = state) when is_pid(client) do
    if Process.alive?(client), do: {:ok, state}, else: ensure_client(%{state | client: nil})
  end

  defp ensure_client(state) do
    with {:ok, state} <- ensure_daemon(state),
         {address, port} = Endpoint.connect_args(state.endpoint),
         {:ok, client} <-
           Client.connect(
             address: address,
             port: port,
             token: state.endpoint.token,
             owner: self(),
             client_info: %{"name" => "troupe", "version" => version()},
             capabilities: %{"blobs" => true}
           ) do
      {:ok, %{state | client: client, error: nil}}
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, %{state | error: reason}}
    end
  end

  defp version, do: to_string(Application.spec(:troupe, :vsn) || "dev")

  defp error_message(%{message: message, data: %{"reason" => reason}}) when is_binary(reason),
    do: "#{message}: #{reason}"

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error)
end
