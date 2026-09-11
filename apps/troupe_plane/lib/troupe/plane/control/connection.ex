defmodule Troupe.Plane.Control.Connection do
  @moduledoc """
  One worker's control connection.

  The same JSON-RPC framing as everything else in Troupe, over a socket workers dial.
  What crosses it is presence, the session *index*, usage records, and pushes back the
  other way. **No session content**, ever — a done item looks for a marker string sent
  as session input in captured control-channel traffic, and finding it would mean this
  file is wrong.

  The first message must be `enrol`, carrying the pod's projected ServiceAccount token.
  Until Kubernetes has said which namespace that token belongs to, the connection has
  no identity and every other method is refused.
  """

  use GenServer, restart: :temporary

  alias Troupe.Plane.Control.Connections
  alias Troupe.Plane.{Enrolment, Fleet, Placement, Sessions, TeamBudget}
  alias Troupe.Protocol.{Error, JSONRPC}

  require Logger

  @max_message_bytes 8 * 1024 * 1024

  @enforce_keys [:socket]
  defstruct [:socket, :identity, :worker, buffer: "", next_id: 1, pending: %{}, verify: nil]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Send a request to this worker and wait for its answer."
  @spec request(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def request(pid, method, params \\ %{}, timeout \\ 15_000) do
    GenServer.call(pid, {:request, method, params}, timeout + 1_000)
  end

  @doc "Tell this worker something, without waiting."
  @spec notify(pid(), String.t(), map()) :: :ok
  def notify(pid, method, params \\ %{}), do: GenServer.cast(pid, {:notify, method, params})

  @doc "What this connection is, for tests and diagnostics."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe control connection")

    {:ok,
     %__MODULE__{
       socket: Keyword.fetch!(opts, :socket),
       # Injectable so the tests can drive enrolment without a cluster; in a pod this
       # is a TokenReview against the API server and nothing else.
       verify: Keyword.get(opts, :verify, &Enrolment.verify/1)
     }}
  end

  @impl GenServer
  def handle_info(:socket_ready, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    case consume(state.buffer <> data, state) do
      {:ok, state} ->
        :ok = :inet.setopts(socket, active: :once)
        {:noreply, state}

      {:stop, state} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    if state.worker do
      Logger.info("troupe plane: #{state.worker.namespace}/#{state.worker.pod_name} disconnected")
    end

    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call({:request, method, params}, from, state) do
    id = state.next_id

    case write(state, {:request, id, method, params}) do
      :ok -> {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, from)}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply, %{identity: state.identity, worker: state.worker, enrolled?: not is_nil(state.worker)},
     state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, state) do
    write(state, {:notification, method, params})
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    :ok
  end

  # -- framing ----------------------------------------------------------------

  defp consume(buffer, state) do
    case String.split(buffer, "\n", parts: 2) do
      [partial] ->
        if byte_size(partial) > @max_message_bytes do
          write(state, {:error, nil, Error.new(:payload_too_large, %{limit: @max_message_bytes})})
          {:stop, state}
        else
          {:ok, %{state | buffer: partial}}
        end

      [line, rest] ->
        case handle_line(String.trim(line), state) do
          {:ok, state} -> consume(rest, state)
          {:stop, state} -> {:stop, state}
        end
    end
  end

  defp handle_line("", state), do: {:ok, state}

  defp handle_line(line, state) do
    case JSONRPC.decode(line) do
      {:ok, message} ->
        handle_message(message, state)

      {:error, %Error{} = error} ->
        write(state, {:error, nil, error})
        {:ok, state}
    end
  end

  # -- messages ---------------------------------------------------------------

  defp handle_message({:request, id, "enrol", params}, %{worker: nil} = state) do
    case enrol(params, state) do
      {:ok, worker, identity} ->
        register(worker)

        Logger.info(
          "troupe plane: #{worker.namespace}/#{worker.pod_name} enrolled as #{worker.profile}"
        )

        write(state, {:result, id, %{"profile" => worker.profile, "worker_id" => worker.id}})
        {:ok, %{state | worker: worker, identity: identity}}

      {:error, reason} ->
        write(state, {:error, id, error_for(reason)})
        # A connection that failed to enrol has no identity and nothing to say. Closing
        # it is what keeps an unauthenticated socket from sitting there trying again.
        {:stop, state}
    end
  end

  defp handle_message({:request, id, "enrol", _params}, state) do
    write(state, {:error, id, Error.new(:invalid_request, %{reason: "already enrolled"})})
    {:ok, state}
  end

  defp handle_message({:request, id, _method, _params}, %{worker: nil} = state) do
    write(state, {:error, id, Error.new(:not_initialized)})
    {:stop, state}
  end

  defp handle_message({:request, id, method, params}, state) do
    case dispatch(method, params, state) do
      {:ok, result, state} ->
        write(state, {:result, id, result})
        {:ok, state}

      {:error, error, state} ->
        write(state, {:error, id, error})
        {:ok, state}
    end
  end

  defp handle_message({:notification, method, params}, state) do
    case dispatch(method, params, state) do
      {:ok, _result, state} -> {:ok, state}
      {:error, _error, state} -> {:ok, state}
    end
  end

  defp handle_message({:result, id, result}, state), do: {:ok, reply(state, id, {:ok, result})}
  defp handle_message({:error, id, error}, state), do: {:ok, reply(state, id, {:error, error})}

  defp reply(state, id, response) do
    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {from, pending} -> GenServer.reply(from, response) && %{state | pending: pending}
    end
  end

  # -- what a worker may say --------------------------------------------------

  defp dispatch("heartbeat", params, state) do
    attrs = %{
      capacity: params["capacity"] || state.worker.capacity,
      active_sessions: params["active_sessions"] || 0,
      disk_used_bytes: params["disk_used_bytes"] || 0,
      disk_total_bytes: params["disk_total_bytes"] || state.worker.disk_total_bytes,
      bundle_hash: params["bundle_hash"],
      version: params["version"]
    }

    case Fleet.heartbeat(state.worker, attrs) do
      {:ok, worker} -> {:ok, %{"ok" => true}, %{state | worker: worker}}
      {:error, reason} -> {:error, Error.new(:internal_error, %{reason: inspect(reason)}), state}
    end
  end

  # Metadata only. What the session *said* is not here and never will be.
  defp dispatch("session.index", params, state) do
    for entry <- params["sessions"] || [] do
      Sessions.seal(entry["id"], %{
        last_seq: entry["last_seq"],
        head_hash: entry["head_hash"],
        object_bytes: entry["object_bytes"],
        workspace_bytes: entry["workspace_bytes"]
      })
    end

    {:ok, %{"accepted" => length(params["sessions"] || [])}, state}
  end

  defp dispatch("session.sealed", params, state) do
    case Sessions.record_anchor(params, state.worker) do
      {:ok, _anchor} -> {:ok, %{"ok" => true}, state}
      {:error, :stale_epoch} -> {:error, Error.new(:conflict, %{reason: "stale epoch"}), state}
      {:error, reason} -> {:error, Error.new(:invalid_params, %{reason: inspect(reason)}), state}
    end
  end

  defp dispatch("session.dormant", params, state) do
    session_id = params["session_id"]

    Sessions.dormant(session_id, %{
      last_seq: params["last_seq"],
      head_hash: params["head_hash"],
      object_bytes: params["object_bytes"],
      workspace_bytes: params["workspace_bytes"]
    })

    Placement.release(state.worker.profile, session_id)
    {:ok, %{"ok" => true}, state}
  end

  defp dispatch("usage.record", params, state) do
    session = Sessions.get(params["session_id"])

    attrs = %{
      session_id: params["session_id"],
      owner_subject: params["owner_subject"] || (session && session.owner_subject),
      model: params["model"],
      input_tokens: params["input_tokens"] || 0,
      output_tokens: params["output_tokens"] || 0,
      cost_micros: params["cost_micros"] || 0,
      gateway_request_id: params["gateway_request_id"]
    }

    case session && session.team_id do
      nil -> {:ok, %{"recorded" => false, "reason" => "no team"}, state}
      team_id -> record_usage(team_id, attrs, state)
    end
  end

  defp dispatch(method, _params, state) do
    {:error, Error.new(:method_not_found, %{method: method}), state}
  end

  defp record_usage(team_id, attrs, state) do
    case TeamBudget.record(team_id, attrs) do
      {:ok, _} -> {:ok, %{"recorded" => true}, state}
      {:error, reason} -> {:error, Error.new(:invalid_params, %{reason: inspect(reason)}), state}
    end
  end

  # -- enrolling --------------------------------------------------------------

  defp enrol(params, state) do
    with {:ok, token} <- fetch(params, "token"),
         {:ok, identity} <- state.verify.(token),
         {:ok, worker} <- Enrolment.enrol(identity, params) do
      {:ok, worker, identity}
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing, key}}
    end
  end

  defp register(worker) do
    registry = Connections.registry()
    Registry.register(registry, {:pod, worker.namespace, worker.pod_name}, worker.id)
    Registry.register(registry, {:profile, worker.profile}, worker.id)
  end

  defp error_for({:missing, key}), do: Error.new(:invalid_params, %{missing: key})
  defp error_for(:unauthenticated), do: Error.new(:unauthenticated)
  defp error_for(:wrong_audience), do: Error.new(:unauthenticated, %{reason: "wrong audience"})

  defp error_for({:wrong_service_account, name}),
    do: Error.new(:forbidden, %{reason: "service account #{name} may not enrol"})

  defp error_for({:not_a_worker_namespace, namespace}),
    do: Error.new(:forbidden, %{reason: "#{namespace} is not a worker namespace"})

  defp error_for(reason), do: Error.new(:invalid_params, %{reason: inspect(reason)})

  defp write(state, message) do
    :gen_tcp.send(state.socket, [JSONRPC.encode(message), ?\n])
  end
end
