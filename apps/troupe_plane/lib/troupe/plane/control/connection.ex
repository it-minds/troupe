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

  alias Troupe.Plane.{
    Budget,
    Bundles,
    Enrolment,
    Erasure,
    Fleet,
    Identity,
    Placement,
    Sessions,
    TeamBudget,
    Tokens,
    Triggers
  }

  alias Troupe.Plane.Control.{Connections, Router}
  alias Troupe.Plane.Fleet.Bundle
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.{Error, JSONRPC}

  require Logger

  @max_message_bytes 8 * 1024 * 1024
  # Short: this runs on every enrolment, and a pod that cannot answer promptly is
  # better left alone than waited on.
  @index_timeout_ms 10_000

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
       # is a TokenReview against the API server and nothing else. Configuration is the
       # third way in, for a replica started as a whole application rather than as a
       # listener with options — which is what a second node in a failover test is.
       verify: Keyword.get_lazy(opts, :verify, &default_verifier/0)
     }}
  end

  defp default_verifier do
    Application.get_env(:troupe_plane, :enrolment_verifier, &Enrolment.verify/1)
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
    gone(state)
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    gone(state)
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
    {:reply,
     %{identity: state.identity, worker: state.worker, enrolled?: not is_nil(state.worker)},
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

  # The pod is not there any more, so stop placing sessions on it — now, rather than when
  # its heartbeat lease expires. That was enough when a pod only went away because
  # somebody drained it; the plane scales profiles itself now, so workers come and go on
  # their own and a placeable row for one that has gone is a create that fails with "the
  # pod did not accept the session".
  defp gone(%{worker: nil}), do: :ok

  defp gone(%{worker: worker}) do
    Logger.info("troupe plane: #{worker.namespace}/#{worker.pod_name} disconnected")
    Fleet.disconnected(worker.namespace, worker.pod_name, worker.enrolled_at)
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

        # Erasures this pod missed go out with the enrolment answer. It applies them
        # before it serves anything: a pod holding an encrypted cache of a session that
        # no longer exists must not answer a single read from it.
        write(
          state,
          {:result, id,
           %{
             "profile" => worker.profile,
             "worker_id" => worker.id,
             "pending_erasures" => Erasure.pending_for(worker.profile, worker.pod_name)
           }}
        )

        # And the keys the pod verifies session tokens against. Pushed rather than
        # fetched, because the plane is not in the data path of a live session: a pod
        # that had to reach the plane to check a token would make every attach depend on
        # the plane being up, which is exactly what this channel exists to avoid.
        state = push_jwks(%{state | worker: worker, identity: identity})

        reconcile_index(worker)

        {:ok, state}

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
      version: params["version"],
      # A heartbeat may raise the flag, never lower it: the plane raises it first when
      # it orders a drain, and a heartbeat sent a moment before would otherwise undo
      # that. Lowering is enrolment's job, because only a restarted pod is not draining.
      draining: state.worker.draining or params["draining"] == true
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

  # Lifecycle, not content: what the session is doing, whether it finished and why, how
  # many approvals wait, and what it has cost. Fenced on the epoch in `put_status/2`, so
  # a pod still running an older epoch cannot overwrite what the new one reports.
  defp dispatch("session.status", params, state) do
    case Sessions.put_status(params["session_id"], params) do
      {:ok, _count} ->
        announce(params)
        {:ok, %{"ok" => true}, state}

      {:error, :stale_epoch} ->
        {:error, Error.new(:conflict, %{reason: "stale epoch"}), state}
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

    # The dormancy report is the last word on the session until it wakes, and carries
    # the same lifecycle fields a `session.status` would.
    if Map.has_key?(params, "status"), do: Sessions.put_status(session_id, params)

    # Both reservations go back: the slot, and the slice of the team's budget. A dormant
    # session spends nothing, and a fleet of triggers whose slices were held through
    # dormancy would pin a team's budget with sessions that are not running.
    Placement.release(state.worker.profile, session_id)
    release_budget(session_id)
    {:ok, %{"ok" => true}, state}
  end

  # A pod that could not put a session's tree back and says the directory it was
  # recorded in is gone. Not a storage blip worth another try: the session is parked
  # read-only — history readable, nothing activates it again — rather than every client
  # that opens it meeting the same failure (Decision 661). Fenced on the epoch like a
  # status report, and the slot and the budget slice go back as they do at dormancy.
  defp dispatch("session.unrestorable", params, state) do
    session_id = params["session_id"]

    case Sessions.unrestorable(session_id, params["epoch"]) do
      {:ok, _count} ->
        Placement.release(state.worker.profile, session_id)
        release_budget(session_id)
        {:ok, %{"ok" => true}, state}

      {:error, :stale_epoch} ->
        {:error, Error.new(:conflict, %{reason: "stale epoch"}), state}
    end
  end

  # A pod confirming it has carried an erasure out on its own disk.
  defp dispatch("session.erased", params, state) do
    Erasure.applied(params["session_id"], state.worker.pod_name)
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

  # What a session's model calls cost, as a batch, with the watermark in the answer.
  #
  # The pod holds these in a table it may lose, so the reply is the contract: the
  # sequence the ledger has now recorded for this session, which is what the pod deletes
  # up to and folds forward from. A record already in the ledger counts towards it —
  # a duplicate is a success, and a watermark that refused to move past one would ask
  # the pod to send it forever.
  defp dispatch("usage.batch", params, state) do
    with %{} = session <- Sessions.get(params["session_id"]),
         team_id when is_binary(team_id) <- session.team_id,
         {:ok, records} <- usage_records(session, params["records"]) do
      case TeamBudget.record_batch(team_id, records) do
        {:ok, tally} ->
          usage_seq = Sessions.advance_usage_seq(session.id, tally.seq)

          {:ok,
           %{
             "recorded" => tally.recorded,
             "duplicates" => tally.duplicates,
             "usage_seq" => usage_seq
           }, state}

        {:error, reason} ->
          {:error, Error.new(:invalid_params, %{reason: inspect(reason)}), state}
      end
    else
      nil ->
        # No session, or no team: nothing to charge and nothing for the pod to keep
        # sending. The watermark it gets back is the one it sent, so it stops.
        {:ok, %{"recorded" => 0, "duplicates" => 0, "usage_seq" => high_seq(params)}, state}

      {:error, reason} ->
        {:error, Error.new(:invalid_params, %{reason: reason}), state}
    end
  end

  # A pod fetching a bundle: by hash, which is what `config.updated` announced and what
  # the pod verifies the document against before materialising it, or by channel and
  # version for a session pinned to one the pod has never been told about. The document
  # is configuration an admin published, not session content, so it may cross here.
  # An assertion a pod exchanges for the key-manager token of a session's *owner*.
  #
  # Asked for rather than pushed, because the token it buys is short-lived and a session
  # can outlive it: a pod that had been handed one at activation would lose its person's
  # credentials twenty minutes in and have no way to ask for another. The plane is the
  # only thing that can sign one, so this is the only way to ask.
  #
  # The subject is **not** the pod's to choose. It is read from the session row, so a pod
  # asking for a session it is not holding — or naming somebody else — gets the owner of
  # the session it actually has, or nothing.
  defp dispatch("kms.assertion", params, state) do
    case session_of(params["session_id"], state.worker) do
      %Session{owner_subject: owner} when is_binary(owner) ->
        mint_for(owner, state)

      nil ->
        {:error, Error.new(:not_found, %{session_id: params["session_id"]}), state}
    end
  end

  defp dispatch("bundle.fetch", params, state) do
    case fetch_bundle(params, state.worker) do
      %Bundle{} = bundle ->
        {:ok,
         %{
           "content" => bundle.content,
           "hash" => bundle.hash,
           "channel" => bundle.channel,
           "version" => bundle.version
         }, state}

      nil ->
        asked = Map.take(params, ~w(hash channel version))
        {:error, Error.new(:not_found, %{reason: "no such bundle", asked: asked}), state}
    end
  end

  defp dispatch(method, _params, state) do
    {:error, Error.new(:method_not_found, %{method: method}), state}
  end

  # A trigger's run has ended, so whoever asked to be told is told. Off this process and
  # unsupervised on purpose: a pod reporting that a session finished must not wait on
  # somebody else's HTTP server, and a notification lost because the node went down is a
  # better outcome than a status report that did not land because one was in flight.
  defp announce(%{"session_id" => session_id, "status" => status})
       when status in ["done", "interrupted"] and is_binary(session_id) do
    Task.start(fn -> Triggers.announce(session_id, %{"state" => status}) end)
    :ok
  end

  defp announce(_params), do: :ok

  # A person the identity provider has deactivated stops being able to lend their
  # credentials to a pod, and this is where that takes effect. It matters more here than
  # at the harness: a running session needs nobody to sign in, so refusing a deprovisioned
  # person at the front door would leave their credentials reachable for as long as
  # anything they started kept running. The pod's existing key-manager token outlives this
  # by its own lease and no longer.
  #
  # The session is not stopped. What it may still do is the session's question — its
  # history is the team's, and a person leaving is not a reason to lose it — and what it
  # may do *as them* is this one.
  defp mint_for(owner, state) do
    case Identity.get_user(owner) do
      %User{active: false} ->
        {:error, Error.new(:forbidden, %{reason: "the session's owner is deactivated"}), state}

      _active ->
        case Tokens.mint_kms_assertion(owner) do
          {:ok, assertion, claims} ->
            {:ok, %{"assertion" => assertion, "expires_at" => claims["exp"]}, state}

          {:error, reason} ->
            {:error, Error.new(:unavailable, %{reason: inspect(reason)}), state}
        end
    end
  end

  # A pod may ask about the sessions it is holding and no others. Enrolment decided which
  # pod this is; the index decides which sessions are its.
  defp session_of(session_id, worker) when is_binary(session_id) do
    case Sessions.get(session_id) do
      %Session{worker_id: held} = session when held == worker.id -> session
      _other -> nil
    end
  end

  defp session_of(_session_id, _worker), do: nil

  defp fetch_bundle(%{"hash" => hash}, worker) when is_binary(hash) do
    Bundles.by_hash(hash, channel: channel_of(worker))
  end

  defp fetch_bundle(%{"channel" => channel, "version" => version}, _worker)
       when is_binary(channel) and (is_integer(version) or is_binary(version)) do
    Bundles.get(channel, version)
  end

  defp fetch_bundle(_params, _worker), do: nil

  defp channel_of(worker) do
    case Fleet.get_profile(worker.profile) do
      nil -> nil
      profile -> profile.config_bundle_channel
    end
  end

  # Every rung, not only the team's. A release that gave back the team's slice and left
  # the person's held would make somebody's own cap drift upward with every session they
  # ever put to sleep, and nothing would say so until they could not start one.
  defp release_budget(session_id) do
    case Sessions.get(session_id) do
      %{} = session -> Budget.release(session.team_id, session_id, answerable_for(session))
      _none -> :ok
    end
  end

  # Whose cap this session's spend counts against: the sponsor behind a trigger's run,
  # and otherwise the owner. The same answer the plane gave when it reserved, because a
  # release that named a different person would give back somebody else's slice.
  defp answerable_for(%{origin: %{"principal" => %{"subject" => subject}}})
       when is_binary(subject),
       do: subject

  defp answerable_for(%{owner_subject: subject}), do: subject

  # Turned into the ledger's shape here rather than trusted as sent: a worker names the
  # call and its cost, and the plane names whose session it was. Nothing a pod says about
  # ownership is read, which is the same rule enrolment follows.
  defp usage_records(session, records) when is_list(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case record do
        %{"gateway_request_id" => id} when is_binary(id) and id != "" ->
          {:cont,
           {:ok,
            [
              %{
                seq: non_negative(record["seq"]),
                session_id: session.id,
                owner_subject: session.owner_subject,
                model: record["model"] || "unknown",
                input_tokens: non_negative(record["input_tokens"]),
                output_tokens: non_negative(record["output_tokens"]),
                cost_micros: non_negative(record["cost_micros"]),
                gateway_request_id: id,
                occurred_at: occurred_at(record["occurred_at"])
              }
              | acc
            ]}}

        _other ->
          {:halt, {:error, "every usage record needs a gateway_request_id"}}
      end
    end)
  end

  defp usage_records(_session, _records), do: {:error, "records is a list"}

  defp non_negative(n) when is_integer(n) and n >= 0, do: n
  defp non_negative(_other), do: 0

  # The event's own timestamp, so a record folded out of a log an hour later lands in
  # the window the call actually happened in — but never later than now. A pod whose
  # clock is ahead would otherwise write charges into a future no report asks about, and
  # a charge nobody can see is worse than one dated a few seconds early.
  defp occurred_at(ts) when is_binary(ts) do
    now = DateTime.utc_now()

    case DateTime.from_iso8601(ts) do
      {:ok, at, _offset} -> if DateTime.compare(at, now) == :gt, do: now, else: at
      _error -> now
    end
  end

  defp occurred_at(_other), do: DateTime.utc_now()

  # The highest sequence the pod claimed, for the case where there is nothing to charge.
  defp high_seq(%{"records" => records}) when is_list(records) do
    records |> Enum.map(&non_negative(&1["seq"])) |> Enum.max(fn -> 0 end)
  end

  defp high_seq(_params), do: 0

  defp record_usage(team_id, attrs, state) do
    case TeamBudget.record(team_id, attrs) do
      {:ok, _} -> {:ok, %{"recorded" => true}, state}
      {:error, reason} -> {:error, Error.new(:invalid_params, %{reason: inspect(reason)}), state}
    end
  end

  # -- enrolling --------------------------------------------------------------

  # A pod that has just enrolled is the authority on what it is holding. The plane's
  # record of that is a belief, and after a pod restarts the belief is a whole process
  # lifetime out of date: the pod comes back with nothing, while the plane still has every
  # session marked `active` on it.
  #
  # Left alone, those sessions are unreachable for good. Opening one takes the
  # already-running branch — it hands the client an endpoint and never tells the pod to
  # restore, because as far as the plane knows there is nothing to restore — and the
  # client's `subscribe` answers `not_found` for as long as anybody cares to retry. No
  # timeout expires and no retry helps.
  #
  # Dormant is exactly the right answer. The session's log is sealed in object storage and
  # the next open replays it onto a pod; what is lost is the process that was running it,
  # which was already lost when the pod went. A pod that merely reconnected still lists
  # everything it holds, so nothing of its is touched.
  #
  # Only ever on an answer. A pod that cannot be reached has said nothing about what it
  # holds, and reading silence as "holding none" would dormant a healthy fleet.
  #
  # Asked once, and not again on failure. This is the only thing that rescues the
  # sessions of a pod that came back under its own name — the sweeper cannot, because the
  # row they point at is that pod's row, healthy again — which is why `register/1` makes
  # sure the question reaches the pod that just enrolled. A retry from this task would
  # outlive the connection it was asked on and could reach whatever was registered under
  # the name by then, which in the suite was the next test's pod.
  defp reconcile_index(worker) do
    # In a task because the answer arrives on this socket, which this process is the one
    # reading: asking from inside the handler would deadlock waiting on its own reply.
    Task.start(fn ->
      case Router.push(worker, "session.index", %{}, @index_timeout_ms) do
        {:ok, %{"sessions" => held}} ->
          orphans(worker, held) |> Enum.each(&strand(worker, &1))

        {:ok, _other} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "troupe plane: #{worker.pod_name} did not say what it holds: #{inspect(reason)}"
          )
      end
    end)
  end

  defp orphans(worker, held) do
    on_pod = MapSet.new(List.wrap(held), &(is_map(&1) && &1["id"]))

    worker.id
    |> Sessions.on_worker()
    |> Enum.reject(&MapSet.member?(on_pod, &1))
  end

  defp strand(worker, session_id) do
    Logger.info(
      "troupe plane: #{session_id} is not on #{worker.pod_name} any more, marking it dormant"
    )

    # The order is load-bearing and lives in one place now — `Drain.strand/1` — because it
    # was fixed here once and was still the wrong way round in the other two callers.
    Placement.release(worker.profile, session_id)
    Sessions.dormant(session_id)
    release_budget(session_id)
  end

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

  # A pod name is one pod at a time, so a connection already registered under this one
  # belongs to a pod that is gone: killed and replaced under its own name faster than its
  # socket closed, which a StatefulSet does in seconds, and a kill sends no FIN, so the
  # socket stays open for the whole lease. Left registered, it made `for_pod` answer
  # nobody, the index question after enrolment went unanswered, and every session the
  # plane believed on the old pod stayed `active` for good — the sweeper never looks at a
  # row that is healthy again. Dropping it costs nothing: the fence in
  # `Fleet.disconnected/3` keeps its teardown off the row this enrolment just wrote.
  #
  # The value carries when this connection enrolled, which is how `for_pod` picks the
  # newest in the moment both are still here.
  defp register(worker) do
    registry = Connections.registry()
    key = {:pod, worker.namespace, worker.pod_name}

    for {pid, _value} <- Registry.lookup(registry, key), pid != self() do
      Logger.info(
        "troupe plane: #{worker.namespace}/#{worker.pod_name} enrolled again; " <>
          "dropping the connection its predecessor left open"
      )

      Process.exit(pid, :shutdown)
    end

    Registry.register(registry, key, {worker.id, System.monotonic_time()})
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

  # A worker with no keys cannot verify a single session token, so a failure here is
  # logged loudly rather than swallowed: the pod will enrol, heartbeat, look healthy, and
  # refuse everybody.
  defp push_jwks(state) do
    case Tokens.jwks() do
      {:ok, jwks} ->
        write(state, {:notification, "jwks.updated", %{"jwks" => jwks}})
        state

      {:error, reason} ->
        Logger.error("troupe plane: could not read its own JWKS to push: #{inspect(reason)}")
        state
    end
  end

  defp write(state, message) do
    :gen_tcp.send(state.socket, [JSONRPC.encode(message), ?\n])
  end
end
