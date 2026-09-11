defmodule Troupe.Worker.Session.Manager do
  @moduledoc """
  One process per *active* session on this pod. Nothing at all per dormant one.

  That asymmetry is the design. A worker is expected to be responsible for tens of
  thousands of sessions and to have almost all of them dormant at any moment, so a
  dormant session must cost no process, no timer and no cached bytes — only a row in the
  plane. Everything a dormant session is lives in object storage, and activation is the
  only path back.

  The manager is also where a session's serialisation comes from. Two clients activating
  the same session at the same moment reach the same registered process, and the second
  gets the tree the first started rather than a second tree over the same log. Across
  pods that is the plane's job; within one it is this.

  ## Order of operations, and why

  Dormancy is: record it, seal, stop the tree, archive, upload, report, erase. Sealing
  before stopping is what keeps the last turn; stopping before archiving is what keeps
  the archive from being torn halfway through a file write; erasing last is what makes
  the erase safe, because by then every byte of it is in object storage under a key the
  plane cannot read.
  """

  use GenServer, restart: :temporary

  alias Troupe.Session.Log
  alias Troupe.Session.Summary
  alias Troupe.Worker.Session.{Context, Restore, Sealer, Workspace}
  alias Troupe.Worker.Sessions
  alias Troupe.Worker.Storage

  require Logger

  # Long enough that a person who stepped away finds their session where they left it,
  # short enough that a pod full of abandoned sessions empties itself.
  @dormant_after_ms 10 * 60 * 1000

  defstruct [
    :session_id,
    :context,
    :workspace,
    :sealer,
    :session_pid,
    :report,
    :opts,
    :idle_timer,
    :error,
    :restored,
    status: :new,
    activated_at: nil,
    dormant_after_ms: @dormant_after_ms
  ]

  # -- api --------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Sessions.via(session_id))
  end

  @doc "Block until the session is up, or say why it is not."
  @spec await(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(pid, timeout \\ 120_000), do: GenServer.call(pid, :await, timeout)

  @doc "Seal, archive, report, erase, and go away."
  @spec go_dormant(pid(), timeout()) :: {:ok, map()} | {:error, term()}
  def go_dormant(pid, timeout \\ 120_000), do: GenServer.call(pid, :go_dormant, timeout)

  @doc "What this session is doing, for the heartbeat and for tests."
  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @doc """
  Tell a session it has been fenced.

  A pod that was presumed lost comes back believing it still owns a session the plane
  has already moved. It must stop: no more events, no more seals, and the local cache
  gone, because that cache is plaintext session content for a session this pod is no
  longer allowed to hold.
  """
  @spec fence(pid(), pos_integer()) :: :ok
  def fence(pid, epoch), do: GenServer.call(pid, {:fence, epoch}, 60_000)

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe session #{session_id}")
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      session_id: session_id,
      report: Keyword.get(opts, :report, fn _ -> :ok end),
      opts: opts,
      dormant_after_ms: Keyword.get(opts, :dormant_after_ms, @dormant_after_ms)
    }

    {:ok, state}
  end

  @impl GenServer
  # The restore happens on the first `await` rather than in `init/1` or a continue, so
  # that the caller who asked for it is the one who hears how it went. A manager that
  # failed before anyone called it could only report `:noproc`, which says nothing about
  # why — and "why" is the difference between a storage blip worth retrying and a stale
  # epoch that must never be retried.
  def handle_call(:await, _from, %__MODULE__{status: :new} = state) do
    case restore(state) do
      {:ok, state} ->
        Troupe.subscribe(state.session_id)
        state = touch(state)
        {:reply, {:ok, summary(state)}, state}

      {:error, reason} ->
        Logger.error("troupe worker: could not activate #{state.session_id}: #{inspect(reason)}")
        {:stop, :normal, {:error, reason}, %{state | status: :failed, error: reason}}
    end
  end

  def handle_call(:await, _from, %__MODULE__{status: :active} = state) do
    {:reply, {:ok, summary(state)}, state}
  end

  def handle_call(:await, _from, %__MODULE__{status: :failed} = state) do
    {:reply, {:error, state.error}, state}
  end

  def handle_call(:status, _from, state), do: {:reply, summary(state), state}

  def handle_call(:go_dormant, _from, %__MODULE__{status: :active} = state) do
    {:stop, :normal, dormancy(state), state}
  end

  def handle_call(:go_dormant, _from, state), do: {:reply, {:error, {:not_active, state.status}}, state}

  def handle_call({:fence, epoch}, _from, state) do
    if state.context && epoch > state.context.epoch do
      Logger.warning(
        "troupe worker: #{state.session_id} fenced at epoch #{epoch}, was #{state.context.epoch}"
      )

      discard(state)
      {:stop, :normal, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_info(:idle, %__MODULE__{status: :active} = state) do
    if busy?(state.session_id) do
      {:noreply, touch(state)}
    else
      dormancy(state)
      {:stop, :normal, state}
    end
  end

  def handle_info({:troupe_event, _session_id, _event}, state), do: {:noreply, touch(state)}

  def handle_info({:EXIT, pid, _reason}, %__MODULE__{sealer: pid} = state) do
    {:noreply, %{state | sealer: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Give up the registered name here rather than leaving it to the registry's monitor,
    # so that a caller who waited for this process to go can trust the registry.
    Sessions.unregister(state.session_id)

    # A linked process does not die of a normal exit, so the sealer is stopped by name
    # rather than left to a link signal that would never arrive.
    if state.sealer && Process.alive?(state.sealer) do
      GenServer.stop(state.sealer, :normal, 60_000)
    end

    :ok
  end

  # -- activation -------------------------------------------------------------

  defp restore(state) do
    opts = state.opts

    with {:ok, context} <- context(opts),
         :ok <- check_epoch(context),
         root = Restore.workspace_root(context, opts),
         {:ok, log} <- Restore.events(context, root),
         {:ok, _tree} <- Restore.workspace(context, root),
         {:ok, sealer} <- start_sealer(state, context, log),
         {:ok, session} <- Restore.start(context, root, opts) do
      # The session records that it came back. A reader who was subscribed the whole
      # time sees a gap in wall-clock time and nothing else without this.
      Log.append(context.session_id, ["root"], :session_activated, %{
        "epoch" => Integer.to_string(context.epoch),
        "pod" => System.get_env("HOSTNAME")
      })

      {:ok,
       %{
         state
         | context: context,
           workspace: root,
           sealer: sealer,
           session_pid: session.pid,
           status: :active,
           restored: log,
           activated_at: System.system_time(:millisecond)
       }}
    end
  end

  # Started before the tree, so that everything the tree appends on the way up is sealed
  # like any other durable event.
  defp start_sealer(state, context, log) do
    Sealer.start_link(
      context: context,
      report: state.report,
      sealed_through: log.last_seq,
      seal_interval_ms: Keyword.get(state.opts, :seal_interval_ms, 60_000),
      snapshot_every: Keyword.get(state.opts, :snapshot_every, 500),
      snapshot: fn -> {:ok, Summary.snapshot(context.session_id)} end
    )
  end

  defp context(opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, %Context{} = context} -> {:ok, context}
      :error -> Context.open(Keyword.fetch!(opts, :session_id), opts)
    end
  end

  # The manifest is plaintext and needs no key, which is what lets this check happen
  # before anything is decrypted. A session whose stored epoch is ahead of ours has been
  # moved, and this pod is the ghost.
  defp check_epoch(context) do
    case Storage.get_manifest(context.store, context.session_id) do
      {:ok, %{"epoch" => stored}} when is_integer(stored) and stored > context.epoch ->
        {:error, {:stale_epoch, stored, context.epoch}}

      _ ->
        :ok
    end
  end

  # -- dormancy ---------------------------------------------------------------

  defp dormancy(state) do
    context = state.context
    head = Troupe.head_seq(state.session_id)

    # Records `session_dormant` and then takes the tree down. The sealer is not part of
    # that tree and is subscribed, so the event is already in its mailbox by the time
    # this returns — which is why sealing afterwards still catches it. Nothing may write
    # to the workspace after this point, which is what makes the archive a consistent
    # picture rather than a racing one.
    Troupe.stop_session(context.session_id)

    sealed =
      case state.sealer && Sealer.seal_now(state.sealer) do
        {:ok, sealed} -> sealed
        _ -> %{sealed_through: head, head_hash: nil}
      end

    archive = archive(state, sealed.sealed_through)

    state.report.(%{
      "session_id" => context.session_id,
      "epoch" => context.epoch,
      "last_seq" => sealed.sealed_through,
      "head_hash" => sealed.head_hash,
      "workspace_seq" => archive[:seq],
      "reason" => "dormant",
      "type" => "session.dormant"
    })

    # Last, and only once every byte of it is in object storage under a key the plane
    # cannot read. A plaintext workspace left on a PVC is the thing the Forbidden list
    # names first.
    erased = erase_local(state)

    {:ok, Map.merge(sealed, %{workspace: archive, erased: erased, session_id: context.session_id})}
  end

  defp archive(state, seq) do
    context = state.context

    case Workspace.archive(state.workspace) do
      {:ok, compressed, plain_bytes} ->
        case Storage.put_workspace(context.store, context.session_id, context.data_key, seq, compressed, "tar.zst") do
          {:ok, _} -> %{seq: seq, bytes: byte_size(compressed), plain_bytes: plain_bytes}
          {:error, reason} -> %{seq: nil, error: reason}
        end

      {:error, reason} ->
        %{seq: nil, error: reason}
    end
  end

  # Both the workspace and the local event log: the log is plaintext session content on
  # the same PVC, and the durable copy of it is encrypted in object storage.
  defp erase_local(state) do
    workspace = Workspace.erase(state.workspace)
    log_dir =
      Path.dirname(Restore.log_path(state.session_id, state.workspace, state.context.state_dir))
    File.rm_rf(log_dir)
    %{workspace: workspace, log: not File.exists?(log_dir)}
  end

  # A fenced pod uploads nothing: its events belong to an epoch the session has moved
  # past, and its workspace is a copy of a tree somebody else now owns. It throws them
  # away.
  defp discard(state) do
    if state.sealer && Process.alive?(state.sealer), do: Process.exit(state.sealer, :kill)
    Troupe.stop_session(state.session_id)
    erase_local(state)
  end

  # -- plumbing ---------------------------------------------------------------

  # A session with an agent still thinking or running a tool is not idle no matter how
  # long it has been since anyone typed: going dormant mid-turn would seal a turn that
  # never finished and lose whatever the tool was doing.
  defp busy?(session_id) do
    session_id
    |> Troupe.agent_tree()
    |> Enum.any?(fn path ->
      case Troupe.snapshot(session_id, path) do
        %{state: agent_state} -> agent_state not in [:idle, :done]
        _ -> false
      end
    end)
  end

  defp touch(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: Process.send_after(self(), :idle, state.dormant_after_ms)}
  end

  defp summary(state) do
    %{
      session_id: state.session_id,
      status: state.status,
      epoch: state.context && state.context.epoch,
      workspace: state.workspace,
      pid: state.session_pid,
      sealer: state.sealer,
      activated_at: state.activated_at,
      restored: state.restored,
      error: state.error
    }
  end
end
