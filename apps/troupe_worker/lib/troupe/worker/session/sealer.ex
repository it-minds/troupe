defmodule Troupe.Worker.Session.Sealer do
  @moduledoc """
  Gets a session's events into object storage, and says how far it has got.

  One process per active session. It subscribes to the session's events, keeps the
  durable ones, and seals a segment at every turn completion and at least every sixty
  seconds while anything is pending. That interval is the whole of the durability
  promise: losing a pod's disk costs the unsealed tail and nothing else, which is at
  most a minute of events.

  Sealing is upload-then-report, in that order. A segment the plane has been told about
  but that is not in storage would make a rebuild claim history it cannot produce; a
  segment in storage the plane has not heard of is merely un-anchored, and the next
  report fixes it. If the plane is unreachable the sealing carries on and the reports
  queue, because durability must not depend on the plane being up.
  """

  use GenServer

  alias Troupe.Protocol.Event
  alias Troupe.Sessions.Storage
  alias Troupe.Worker.Session.Context

  require Logger

  # The spec's number, and the one the done item measures against: a lost PVC costs at
  # most this much.
  @seal_interval_ms 60_000
  # Snapshots are pure cache, written often enough that a replay is short and rarely
  # enough that writing them is not the cost.
  @snapshot_every 500

  @enforce_keys [:context]
  defstruct [
    :context,
    :timer,
    pending: [],
    sealed_through: 0,
    head_hash: nil,
    segments: [],
    object_bytes: 0,
    report: nil,
    snapshot: nil,
    last_snapshot_at: 0,
    seal_interval_ms: @seal_interval_ms,
    snapshot_every: @snapshot_every
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Seal whatever is pending now, and wait for it. Dormancy and shutdown use this."
  @spec seal_now(GenServer.server(), timeout()) :: {:ok, map()} | {:error, term()}
  def seal_now(server, timeout \\ 60_000), do: GenServer.call(server, :seal_now, timeout)

  @doc "How far this session is sealed, for tests and for the heartbeat."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl GenServer
  def init(opts) do
    context = Keyword.fetch!(opts, :context)
    Process.set_label("troupe sealer #{context.session_id}")
    # So that a manager going away — cleanly or not — still runs `terminate/2` here and
    # the unsealed tail gets one last chance at object storage.
    Process.flag(:trap_exit, true)

    Troupe.subscribe(context.session_id)

    state = %__MODULE__{
      context: context,
      # Where to send `session.sealed`. A function rather than a pid so a worker with no
      # plane connection — a test, or a plane that is down — simply drops the report and
      # keeps sealing.
      report: Keyword.get(opts, :report, fn _ -> :ok end),
      # How to fold a snapshot. Optional: without one, a restore replays every segment,
      # which is correct but slower.
      snapshot: Keyword.get(opts, :snapshot),
      seal_interval_ms: Keyword.get(opts, :seal_interval_ms, @seal_interval_ms),
      snapshot_every: Keyword.get(opts, :snapshot_every, @snapshot_every),
      sealed_through: Keyword.get(opts, :sealed_through, 0)
    }

    {:ok, schedule(state)}
  end

  @impl GenServer
  def handle_info({:troupe_event, _session_id, %Event{seq: nil} = event}, state) do
    # Ephemerals are not durable and are never sealed — dropping them is what keeps the
    # object tier the size of the session rather than the size of its typing. They are
    # still read for their timing: the root agent going back to idle is how a turn ends,
    # and that transition is only ever announced ephemerally.
    if turn_complete?(event), do: {:noreply, seal(state)}, else: {:noreply, state}
  end

  def handle_info({:troupe_event, _session_id, %Event{} = event}, state) do
    state = %{state | pending: [event | state.pending]}

    # A turn ending is the natural seal point: everything the model and its tools did is
    # in, and the next thing to happen is a person.
    if turn_complete?(event) do
      {:noreply, seal(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:interval, state) do
    {:noreply, state |> seal() |> schedule()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:seal_now, _from, state) do
    state = seal(state)
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, summary(state), state}

  @impl GenServer
  def terminate(_reason, state) do
    # A sealer going away with events in hand is the case that costs data, so it takes
    # the chance it has.
    seal(state)
    :ok
  end

  # -- sealing ----------------------------------------------------------------

  defp seal(%__MODULE__{pending: []} = state), do: state

  defp seal(state) do
    events = Enum.reverse(state.pending)
    context = state.context

    attrs = %{
      events: Enum.map(events, &Event.to_json/1),
      epoch: context.epoch,
      first_seq: List.first(events).seq,
      last_seq: List.last(events).seq,
      head_hash: Event.hash(List.last(events))
    }

    case Storage.seal_segment(context.store, context.session_id, context.data_key, attrs) do
      {:ok, segment} ->
        state
        |> record(segment)
        |> write_manifest()
        |> maybe_snapshot()
        |> report(segment)

      {:error, reason} ->
        # Keep them. The next interval tries again, and until it succeeds this session's
        # tail is only on the pod's disk — which is exactly what the seal interval
        # bounds.
        Logger.error("troupe worker: could not seal #{context.session_id}: #{inspect(reason)}")
        state
    end
  end

  defp record(state, segment) do
    %{
      state
      | pending: [],
        sealed_through: segment.last_seq,
        head_hash: segment.head_hash,
        segments: [segment | state.segments],
        object_bytes: state.object_bytes + (segment.bytes || 0)
    }
  end

  # Rewritten on every seal, because it is what a rebuild reads and a rebuild has to
  # find the session where it actually got to.
  defp write_manifest(state) do
    context = state.context

    Storage.put_manifest(context.store, context.session_id, %{
      team: context.team,
      owner_subject: context.owner_subject,
      profile: context.profile,
      epoch: context.epoch,
      last_seq: state.sealed_through,
      head_hash: state.head_hash,
      key_path: Context.key_path(context),
      object_bytes: state.object_bytes,
      latest_segment: state.segments |> List.first() |> then(& &1.key)
    })

    state
  end

  defp maybe_snapshot(%__MODULE__{snapshot: nil} = state), do: state

  defp maybe_snapshot(state) do
    if state.sealed_through - state.last_snapshot_at >= state.snapshot_every do
      context = state.context

      case state.snapshot.() do
        {:ok, snapshot} ->
          Storage.put_snapshot(context.store, context.session_id, context.data_key, state.sealed_through, snapshot)
          %{state | last_snapshot_at: state.sealed_through}

        _ ->
          state
      end
    else
      state
    end
  end

  # Upload first, then report. A segment the plane has been told about but that is not
  # in storage would make a rebuild claim history it cannot produce.
  defp report(state, segment) do
    state.report.(%{
      "session_id" => state.context.session_id,
      "epoch" => segment.epoch,
      "first_seq" => segment.first_seq,
      "last_seq" => segment.last_seq,
      "head_hash" => segment.head_hash,
      "object_key" => segment.key,
      "bytes" => segment.bytes,
      "object_bytes" => state.object_bytes
    })

    state
  end

  # The root agent coming to rest is a turn ending: everything the model and its tools
  # did is in, and the next thing to happen is a person. Sub-agents coming to rest are
  # not, because a turn can contain a dozen of them and sealing each one would make
  # segments the size of a tool call.
  defp turn_complete?(%Event{type: "agent_done", agent: ["root"]}), do: true

  defp turn_complete?(%Event{type: "agent_state", agent: ["root"], data: %{"state" => at_rest}}) do
    at_rest in ["idle", "done"]
  end

  defp turn_complete?(_event), do: false

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :interval, state.seal_interval_ms)}
  end

  defp summary(state) do
    %{
      session_id: state.context.session_id,
      epoch: state.context.epoch,
      sealed_through: state.sealed_through,
      head_hash: state.head_hash,
      pending: length(state.pending),
      segments: length(state.segments),
      object_bytes: state.object_bytes
    }
  end
end
