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

  ## TLS, and the CA it trusts

  Given a CA (`:ca`, a PEM file: `TROUPE_PLANE_CA_PATH`), the link dials with TLS and
  trusts that CA and nothing else for the plane's certificate, checked against the name it
  dials or the one `:server_name` gives (`TROUPE_PLANE_SERVER_NAME`, for a tunnel or an
  address the certificate does not name). That is how a registered machine dials: its
  registration answered the CA, and the machine pins it. And how a pod dials: the operator
  puts the plane's CA in its namespace and mounts it, and the certificate is checked
  against the control Service's name the pod dials. The file is read again at each dial,
  so a CA the kubelet has replaced is the one the next dial trusts.

  A registered machine's secret is never sent without it. A link holding one (`twh_`) and
  no CA does not dial at all, and says so: the plane would refuse the secret in plaintext,
  but by then it would have crossed the network. A pod, whose token is projected for the
  plane's audience and expires within the hour, dials the control Service in plaintext
  where it was given no CA, and a plane that requires TLS closes that connection.
  """

  use GenServer

  alias Troupe.ObjectStore
  alias Troupe.Paths
  alias Troupe.Protocol.{Error, JSONRPC}
  alias Troupe.Worker.Auth
  alias Troupe.Worker.Bundles
  alias Troupe.Worker.Disk
  alias Troupe.Worker.Drain
  alias Troupe.Worker.Plane.Commands
  alias Troupe.Worker.Session.Restore
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
    :ca,
    :server_name,
    :refused,
    transport: :gen_tcp,
    buffer: "",
    next_id: 1,
    pending: %{},
    queue: [],
    status: :disconnected,
    profile: nil,
    worker_id: nil,
    object_store: nil,
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

  @doc """
  Report what a session's model calls cost, and learn how far the plane has got.

  A request rather than a notification, because the answer is the watermark: the
  sequence the plane has now recorded for this session, which is what lets the pod
  delete what it was holding and what it folds forward from next time. A batch is
  idempotent at the plane, so a retry after a timeout is safe and is the reason this
  may be sent again without checking first.
  """
  @spec usage_batch(GenServer.server(), String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def usage_batch(server \\ __MODULE__, session_id, records) do
    request(server, "usage.batch", %{"session_id" => session_id, "records" => records})
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
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def request(server \\ __MODULE__, method, params \\ %{}, timeout \\ 15_000) do
    GenServer.call(server, {:request, method, params}, timeout + 1_000)
  end

  # -- server -----------------------------------------------------------------

  # What the plane answers can be a credential: a key-manager assertion, a session's GitHub
  # token. A crash report shows neither the line half-read into the buffer nor the bytes
  # of the last message, and not the pod's own enrolment token either.
  @impl GenServer
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, fn
      %__MODULE__{} = state -> %{state | token: :redacted, buffer: byte_size(state.buffer)}
      state -> state
    end)
    |> Map.replace_lazy(:message, fn
      {tag, socket, _data} when tag in [:tcp, :ssl] -> {tag, socket, :redacted}
      message -> message
    end)
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.set_label("troupe plane link")

    configured = Application.get_env(:troupe_worker, :plane, [])

    state = %__MODULE__{
      host:
        opts
        |> Keyword.get(
          :host,
          Keyword.get(configured, :host, "troupe-plane-control.troupe-system.svc")
        )
        |> to_charlist(),
      port: Keyword.get(opts, :port, Keyword.get(configured, :port, 4001)),
      token:
        Keyword.get(opts, :token, Keyword.get(configured, :token, {:file, @default_token_path})),
      ca: Keyword.get(opts, :ca, Keyword.get(configured, :ca)),
      server_name: Keyword.get(opts, :server_name, Keyword.get(configured, :server_name)),
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
       port: state.port,
       object_store: state.object_store,
       tls: state.transport == :ssl,
       refused: state.refused
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

  def handle_info({tag, socket, data}, %{socket: socket} = state) when tag in [:tcp, :ssl] do
    state = consume(state.buffer <> data, state)
    :ok = setopts(state, active: :once)
    {:noreply, state}
  end

  def handle_info({tag, socket}, %{socket: socket} = state)
      when tag in [:tcp_closed, :ssl_closed] do
    {:noreply, disconnected(state, :closed)}
  end

  def handle_info({tag, socket, reason}, %{socket: socket} = state)
      when tag in [:tcp_error, :ssl_error] do
    {:noreply, disconnected(state, reason)}
  end

  def handle_info({:respond, id, result}, state), do: {:noreply, write_result(state, id, result)}

  def handle_info({:object_store, result}, state), do: {:noreply, %{state | object_store: result}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.socket, do: state.transport.close(state.socket)
    :ok
  end

  # -- connecting and enrolling -----------------------------------------------

  # The credential is read first, because which it is decides whether the link may dial
  # at all: a machine's secret goes over TLS or nowhere.
  defp connect(state) do
    with {:ok, token} <- token(state.token) |> no_token(),
         {:ok, transport, options} <- transport(state, token),
         {:ok, socket} <- dial(transport, state, options) do
      enrol(
        %{
          state
          | socket: socket,
            transport: transport,
            buffer: "",
            status: :connected,
            refused: nil,
            connects: state.connects + 1
        },
        token
      )
    else
      {:refused, why} ->
        if why != state.refused, do: Logger.error("troupe worker: not dialling the plane: #{why}")
        schedule_reconnect(%{state | socket: nil, status: :disconnected, refused: why}, :refused)

      {:error, reason} ->
        schedule_reconnect(%{state | socket: nil, status: :disconnected}, reason)
    end
  end

  defp no_token({:ok, token}), do: {:ok, token}
  defp no_token({:error, reason}), do: {:error, {:no_token, reason}}

  # TLS against the CA this link was given, and only that CA; plaintext where it was given
  # none, unless what it would send is a machine's secret.
  defp transport(%{ca: nil}, "twh_" <> _),
    do:
      {:refused,
       "a registered machine's secret is sent over TLS only, and this worker has no CA for " <>
         "the plane: set TROUPE_PLANE_CA_PATH to the CA its registration answered"}

  defp transport(%{ca: nil}, _token),
    do: {:ok, :gen_tcp, [:binary, active: false, packet: :raw, send_timeout: 5_000]}

  defp transport(state, _token) do
    with {:ok, cacerts} <- ca_certificates(state.ca) do
      name = to_charlist(state.server_name || state.host)

      {:ok, :ssl,
       [
         :binary,
         active: false,
         packet: :raw,
         send_timeout: 5_000,
         versions: [:"tlsv1.3", :"tlsv1.2"],
         verify: :verify_peer,
         cacerts: cacerts,
         server_name_indication: name,
         customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
       ]}
    end
  end

  # Read at each dial, so a CA put in place of the old one is the one the next dial trusts.
  defp ca_certificates(path) do
    with {:ok, pem} <- File.read(path),
         [_ | _] = certs <-
           for({:Certificate, der, :not_encrypted} <- :public_key.pem_decode(pem), do: der) do
      {:ok, certs}
    else
      [] ->
        {:refused, "the plane's CA, #{path}, holds no certificate"}

      {:error, reason} ->
        {:refused, "the plane's CA, #{path}, cannot be read (#{:file.format_error(reason)})"}
    end
  end

  defp dial(:gen_tcp, state, options),
    do: :gen_tcp.connect(state.host, state.port, options, 5_000)

  # A certificate this CA did not sign, or for another name, fails here: before a byte of
  # the credential is written. Said once, since it does not mend itself on the next dial.
  defp dial(:ssl, state, options) do
    case :ssl.connect(state.host, state.port, options, 5_000) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, {:tls_alert, {alert, _description}}} ->
        {:refused,
         "the plane's certificate was refused (#{alert}): it must be signed by the CA in " <>
           "#{state.ca} and name #{state.server_name || state.host}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Enrolment is synchronous on purpose: nothing else may be sent until the plane has
  # said which profile this pod is, and a queued report sent before that would be
  # refused and lost.
  defp enrol(state, token) do
    # Whether this pod is draining is the pod's own fact, and a fresh pod says no: that is
    # how a restart after a drain gets its flag lowered.
    params =
      state.claims
      |> with_bundle_hash()
      |> Map.put("draining", Drain.draining?())
      |> Map.put("token", token)

    case exchange(state, "enrol", params) do
      {:ok, result} ->
        Logger.info("troupe worker: enrolled with the plane as #{result["profile"]}")
        # Every token for this pod carries its worker id as the audience, so nothing can
        # be verified until the plane has said what that id is.
        announce_identity(result)
        apply_pending_erasures(result)
        check_object_store(state)

        %{
          state
          | status: :enrolled,
            profile: result["profile"],
            worker_id: result["worker_id"]
        }
        |> reset_backoff()
        |> activate_socket()
        |> flush_queue()
        |> schedule_heartbeat()

      {:error, reason} ->
        schedule_reconnect(close(state), {:enrol_failed, reason})
    end
  end

  # A blocking round trip, used only for enrolment: the socket is not yet active, so
  # this cannot race with anything.
  defp exchange(state, method, params) do
    frame = [JSONRPC.encode({:request, 0, method, params}), ?\n]

    with :ok <- state.transport.send(state.socket, frame),
         {:ok, line} <- recv_line(state, "", 10_000) do
      case JSONRPC.decode(String.trim(line)) do
        {:ok, {:result, _id, result}} -> {:ok, result}
        {:ok, {:error, _id, error}} -> {:error, error}
        other -> {:error, {:unexpected, other}}
      end
    end
  end

  defp recv_line(state, acc, timeout) do
    case state.transport.recv(state.socket, 0, timeout) do
      {:ok, data} ->
        case String.split(acc <> data, "\n", parts: 2) do
          [line, _rest] -> {:ok, line}
          [partial] -> recv_line(state, partial, timeout)
        end

      error ->
        error
    end
  end

  # A machine's own secret, handed over as a string. A pod's token is a file because the
  # projection rotates it in place; a machine has no projection and the secret does not
  # rotate on its own, so the two are different shapes on purpose rather than one shape
  # with a special case.
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

  defp announce_identity(%{"worker_id" => worker_id}) when is_binary(worker_id) do
    case Process.whereis(Auth) do
      nil -> :ok
      server -> Auth.put_worker_id(server, worker_id)
    end
  end

  defp announce_identity(_result), do: :ok

  # Before anything else this pod does. A cache of a session that has been erased is
  # exactly the residue erasure exists to remove, and serving one read from it would
  # undo the whole thing.
  defp apply_pending_erasures(result) do
    pending = Map.get(result, "pending_erasures") || []

    # Reported only once carried out: one the store refused in part stays the plane's to
    # hand out, to the next pod to enrol (Decision 804).
    applied =
      Enum.count(pending, fn erasure ->
        case Commands.handle("session.erase", erasure) do
          {:ok, _done} ->
            report(self(), %{"type" => "session.erased", "session_id" => erasure["session_id"]})
            true

          {:error, _not_yet} ->
            false
        end
      end)

    if pending != [],
      do:
        Logger.info("troupe worker: applied #{applied} of #{length(pending)} pending erasure(s)")
  end

  # Once per enrolment and off this process, which must not wait on storage: a pod that
  # cannot reach its object store restores and seals nothing, and the first anyone heard
  # of that was a person's session failing to start. The answer is in the pod's log and
  # in `info/1`; the next enrolment asks again.
  defp check_object_store(state) do
    store = Keyword.get_lazy(state.opts, :store, &ObjectStore.from_env/0)
    link = self()

    {:ok, _pid} =
      Task.start(fn -> send(link, {:object_store, Restore.check_reachable(store)}) end)

    :ok
  end

  defp activate_socket(state) do
    :ok = setopts(state, active: :once)
    state
  end

  defp setopts(%{transport: :ssl} = state, opts), do: :ssl.setopts(state.socket, opts)
  defp setopts(state, opts), do: :inet.setopts(state.socket, opts)

  defp close(state) do
    if state.socket, do: state.transport.close(state.socket)
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
    |> with_bundle_hash()
    |> Map.take(["capacity", "bundle_hash", "version"])
    |> Map.merge(%{
      "active_sessions" => Sessions.active_count(),
      "disk_used_bytes" => disk.used_bytes,
      "disk_total_bytes" => disk.total_bytes,
      "draining" => Drain.draining?()
    })
  end

  # The hash of the newest bundle this pod has materialised, asked for at the moment of
  # sending rather than remembered: it is what the plane's adoption view compares
  # against, and a claim fixed at boot would report the previous publish forever. A
  # caller's own `bundle_hash` claim — a test's — stands when there is no registry.
  defp with_bundle_hash(claims) do
    case Bundles.current_hash() do
      nil -> claims
      hash -> Map.put(claims, "bundle_hash", hash)
    end
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

  defp write(state, message),
    do: state.transport.send(state.socket, [JSONRPC.encode(message), ?\n])

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
