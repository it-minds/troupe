defmodule Troupe.Worker.Plane.Link do
  @moduledoc """
  The worker's end of the control channel.

  Workers dial the plane, not the other way round: a pod's address is a property of the
  cluster and a plane replica's is not, so the worker needs one Service name and the
  plane learns where the worker is when it arrives. That also means reconnection is
  entirely the worker's business, which is what makes losing a plane replica a
  sub-second event rather than an outage — the Service sends the next dial to a
  survivor.

  What crosses this link is presence, the session *index*, usage records, and pushes
  back the other way. **No session content, ever.** The reports a sealer makes carry
  sequence numbers, hashes, key paths and byte counts, and a done item greps captured
  traffic for a marker string sent as session input.

  A link that cannot reach the plane is not an error the rest of the worker hears about.
  Sealing carries on, dormancy carries on, and the reports queue: durability must not
  depend on the plane being up.
  """

  use GenServer

  alias Troupe.Paths
  alias Troupe.Protocol.{Error, JSONRPC}
  alias Troupe.Worker.Disk
  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Sessions

  require Logger

  # Fast enough that losing a plane replica is measured in hundreds of milliseconds,
  # backed off far enough that a plane which is genuinely down is not hammered.
  @reconnect_floor_ms 250
  @reconnect_ceiling_ms 2_000
  @heartbeat_ms 5_000
  # Reports made while the link is down. Bounded, because a worker that cannot reach the
  # plane for an hour must not spend its memory remembering that.
  @max_queue 10_000
  @default_token_path "/var/run/secrets/troupe/token"

  defstruct [
    :socket,
    :host,
    :port,
    :token,
    :claims,
    :opts,
    :heartbeat_timer,
    :reconnect_timer,
    buffer: "",
    next_id: 1,
    pending: %{},
    queue: [],
    status: :disconnected,
    profile: nil,
    worker_id: nil,
    backoff_ms: @reconnect_floor_ms,
    connects: 0
  ]

  # -- api --------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Report something a sealer or a dormancy produced.

  The payload's `type` says which method it becomes; everything else is passed through.
  A cast, because a sealer must never block on the plane.
  """
  @spec report(GenServer.server(), map()) :: :ok
  def report(server \\ __MODULE__, payload), do: GenServer.cast(server, {:report, payload})

  @doc "A reporter function to hand to a sealer."
  @spec reporter(GenServer.server()) :: (map() -> :ok)
  def reporter(server \\ __MODULE__), do: &report(server, &1)

  @doc "Record token usage against the session's team."
  @spec usage(GenServer.server(), map()) :: :ok
  def usage(server \\ __MODULE__, payload) do
    GenServer.cast(server, {:notify, "usage.record", payload})
  end

  @doc "Send the whole session index, which is what a reconnect owes the plane."
  @spec index(GenServer.server(), [map()]) :: :ok
  def index(server \\ __MODULE__, entries) do
    GenServer.cast(server, {:notify, "session.index", %{"sessions" => entries}})
  end

  @doc "Whether the link is up and enrolled."
  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__), do: info(server).status == :enrolled

  @doc "What the link is doing, for the heartbeat's sake and for tests."
  @spec info(GenServer.server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc "Ask the plane something and wait. Used by activation to obtain an epoch."
  @spec request(GenServer.server(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(server \\ __MODULE__, method, params \\ %{}, timeout \\ 15_000) do
    GenServer.call(server, {:request, method, params}, timeout + 1_000)
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.set_label("troupe plane link")

    state = %__MODULE__{
      host: Keyword.get(opts, :host, "troupe-plane-control.troupe-system.svc") |> to_charlist(),
      port: Keyword.get(opts, :port, 4001),
      token: Keyword.get(opts, :token, {:file, @default_token_path}),
      claims: Keyword.get(opts, :claims, %{}),
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       status: state.status,
       profile: state.profile,
       worker_id: state.worker_id,
       queued: length(state.queue),
       connects: state.connects,
       port: state.port
     }, state}
  end

  def handle_call({:request, method, params}, from, %{status: :enrolled} = state) do
    {:noreply, send_request(state, method, params, from)}
  end

  def handle_call({:request, _method, _params}, _from, state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl GenServer
  def handle_cast({:report, payload}, state) do
    method = Map.get(payload, "type", "session.sealed")
    {:noreply, notify(state, method, Map.delete(payload, "type"))}
  end

  def handle_cast({:notify, method, params}, state), do: {:noreply, notify(state, method, params)}

  @impl GenServer
  def handle_info(:reconnect, state), do: {:noreply, connect(%{state | reconnect_timer: nil})}

  def handle_info(:heartbeat, %{status: :enrolled} = state) do
    {:noreply, state |> notify("heartbeat", heartbeat_params(state)) |> schedule_heartbeat()}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = consume(state.buffer <> data, state)
    :ok = :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:noreply, disconnected(state, :closed)}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:noreply, disconnected(state, reason)}
  end

  def handle_info({:respond, id, result}, state), do: {:noreply, write_result(state, id, result)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  # -- connecting and enrolling -----------------------------------------------

  defp connect(state) do
    options = [:binary, active: false, packet: :raw, send_timeout: 5_000]

    case :gen_tcp.connect(state.host, state.port, options, 5_000) do
      {:ok, socket} ->
        enrol(%{state | socket: socket, buffer: "", status: :connected, connects: state.connects + 1})

      {:error, reason} ->
        schedule_reconnect(%{state | socket: nil, status: :disconnected}, reason)
    end
  end

  # Enrolment is synchronous on purpose: nothing else may be sent until the plane has
  # said which profile this pod is, and a queued report sent before that would be
  # refused and lost.
  defp enrol(state) do
    case token(state.token) do
      {:ok, token} ->
        params = Map.merge(state.claims, %{"token" => token})

        case exchange(state, "enrol", params) do
          {:ok, result} ->
            Logger.info("troupe worker: enrolled with the plane as #{result["profile"]}")

            %{state | status: :enrolled, profile: result["profile"], worker_id: result["worker_id"]}
            |> reset_backoff()
            |> activate_socket()
            |> flush_queue()
            |> schedule_heartbeat()

          {:error, reason} ->
            schedule_reconnect(close(state), {:enrol_failed, reason})
        end

      {:error, reason} ->
        schedule_reconnect(close(state), {:no_token, reason})
    end
  end

  # A blocking round trip, used only for enrolment: the socket is not yet active, so
  # this cannot race with anything.
  defp exchange(state, method, params) do
    frame = [JSONRPC.encode({:request, 0, method, params}), ?\n]

    with :ok <- :gen_tcp.send(state.socket, frame),
         {:ok, line} <- recv_line(state.socket, "", 10_000) do
      case JSONRPC.decode(String.trim(line)) do
        {:ok, {:result, _id, result}} -> {:ok, result}
        {:ok, {:error, _id, error}} -> {:error, error}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defp recv_line(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        case String.split(acc <> data, "\n", parts: 2) do
          [line, _rest] -> {:ok, line}
          [partial] -> recv_line(socket, partial, timeout)
        end

      error ->
        error
    end
  end

  defp token({:file, path}) do
    # Re-read on every connect: a projected ServiceAccount token is rotated in place,
    # and one cached at boot expires while the pod is still running.
    case File.read(path) do
      {:ok, contents} -> {:ok, String.trim(contents)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token(fun) when is_function(fun, 0), do: fun.()
  defp token(value) when is_binary(value), do: {:ok, value}

  defp activate_socket(state) do
    :ok = :inet.setopts(state.socket, active: :once)
    state
  end

  defp close(state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    %{state | socket: nil, status: :disconnected}
  end

  defp disconnected(state, reason) do
    Logger.info("troupe worker: control link down (#{inspect(reason)}), reconnecting")

    # Everything in flight fails now rather than timing out one by one: a caller waiting
    # for an epoch would otherwise sit there for fifteen seconds after the answer became
    # impossible.
    Enum.each(state.pending, fn {_id, from} -> GenServer.reply(from, {:error, :disconnected}) end)

    state |> close() |> Map.put(:pending, %{}) |> schedule_reconnect(reason)
  end

  defp schedule_reconnect(state, reason) do
    if state.reconnect_timer do
      state
    else
      delay = state.backoff_ms
      if state.connects == 0, do: Logger.debug("troupe worker: no plane yet (#{inspect(reason)})")

      %{
        state
        | reconnect_timer: Process.send_after(self(), :reconnect, jitter(delay)),
          backoff_ms: min(delay * 2, @reconnect_ceiling_ms),
          status: :disconnected
      }
    end
  end

  defp reset_backoff(state), do: %{state | backoff_ms: @reconnect_floor_ms}

  # Spread out, so a plane coming back does not take every worker's reconnect in the
  # same millisecond.
  defp jitter(delay), do: delay + :rand.uniform(max(div(delay, 2), 1))

  defp schedule_heartbeat(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    interval = Keyword.get(state.opts, :heartbeat_ms, @heartbeat_ms)
    %{state | heartbeat_timer: Process.send_after(self(), :heartbeat, interval)}
  end

  defp heartbeat_params(state) do
    disk = Disk.usage(Keyword.get(state.opts, :disk_path, Paths.state_dir()))

    state.claims
    |> Map.take(["capacity", "bundle_hash", "version"])
    |> Map.merge(%{
      "active_sessions" => Sessions.active_count(),
      "disk_used_bytes" => disk.used_bytes,
      "disk_total_bytes" => disk.total_bytes
    })
  end

  # -- sending ----------------------------------------------------------------

  defp notify(%{status: :enrolled} = state, method, params) do
    case write(state, {:notification, method, params}) do
      :ok -> state
      {:error, reason} -> state |> queue(method, params) |> disconnected(reason)
    end
  end

  defp notify(state, method, params), do: queue(state, method, params)

  # Bounded, and it is the oldest that goes. A worker out of touch with the plane for an
  # hour has a session index that says everything the dropped reports would have, and
  # the plane asks for one on reconnect.
  defp queue(state, method, params) do
    queue = Enum.take([{method, params} | state.queue], @max_queue)
    %{state | queue: queue}
  end

  defp flush_queue(state) do
    queued = Enum.reverse(state.queue)

    Enum.reduce(queued, %{state | queue: []}, fn {method, params}, acc ->
      notify(acc, method, params)
    end)
  end

  defp send_request(state, method, params, from) do
    id = state.next_id

    case write(state, {:request, id, method, params}) do
      :ok ->
        %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}

      {:error, reason} ->
        GenServer.reply(from, {:error, reason})
        disconnected(state, reason)
    end
  end

  defp write_result(state, id, {:ok, result}), do: write(state, {:result, id, result}) && state

  defp write_result(state, id, {:error, %Error{} = error}) do
    write(state, {:error, id, error}) && state
  end

  defp write_result(state, id, {:error, reason}) do
    write(state, {:error, id, Error.new(:internal_error, %{reason: inspect(reason)})}) && state
  end

  defp write(%{socket: nil}, _message), do: {:error, :disconnected}
  defp write(state, message), do: :gen_tcp.send(state.socket, [JSONRPC.encode(message), ?\n])

  # -- receiving --------------------------------------------------------------

  defp consume(buffer, state) do
    case String.split(buffer, "\n", parts: 2) do
      [partial] -> %{state | buffer: partial}
      [line, rest] -> consume(rest, handle_line(String.trim(line), state))
    end
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case JSONRPC.decode(line) do
      {:ok, message} -> handle_message(message, state)
      # A frame the worker cannot parse is dropped rather than fatal: the plane is on
      # the other end of this socket and a link that hung up on a new method would make
      # every protocol addition a flag day.
      {:error, _error} -> state
    end
  end

  defp handle_message({:result, id, result}, state), do: reply(state, id, {:ok, result})
  defp handle_message({:error, id, error}, state), do: reply(state, id, {:error, error})

  defp handle_message({:request, id, method, params}, state) do
    # Handled off the link, because activating a session can take seconds and the link
    # has heartbeats to send and other pushes to receive in the meantime.
    link = self()

    spawn(fn -> send(link, {:respond, id, Commands.handle(method, params)}) end)

    state
  end

  defp handle_message({:notification, method, params}, state) do
    spawn(fn -> Commands.handle(method, params) end)
    state
  end

  defp reply(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {from, pending} -> GenServer.reply(from, response) && %{state | pending: pending}
    end
  end
end
