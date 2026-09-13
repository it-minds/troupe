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

  ## What the plane is told while a session runs

  Four facts that are lifecycle rather than content: `status` (`idle`, `thinking`,
  `acting`, `waiting` when an approval is pending, `done`, `interrupted`), the
  `done_reason`, how many approvals are pending, and the cost so far. They go out as
  `session.status` notifications on change, at most twice a second per session, and
  again in the dormancy report — which is what lets the plane list a review queue
  without ever reading a log. Nothing about *what* the agent is doing crosses: not the
  tool, not the todo, not a word of any message.
  """

  use GenServer, restart: :temporary

  alias Troupe.ObjectStore
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Session.Summary
  alias Troupe.Sessions.{Cipher, Storage}
  alias Troupe.Worker.Cache
  alias Troupe.Worker.Session.{Context, Restore, Sealer, Workspace}
  alias Troupe.Worker.Sessions
  alias Troupe.Worker.Usage

  require Logger

  # Long enough that a person who stepped away finds their session where they left it,
  # short enough that a pod full of abandoned sessions empties itself.
  @dormant_after_ms 10 * 60 * 1000
  # How often a running session's workspace is archived. The event log is sealed every
  # sixty seconds, which bounds what a lost volume costs in *history*; this bounds what
  # it costs in *files*. Less often than sealing because a workspace archive is the whole
  # tree rather than the events since the last one, and skipped entirely when nothing has
  # changed.
  @archive_every_ms 5 * 60 * 1000
  # The least time between two status notifications for one session. An agent moves
  # `thinking -> acting -> thinking` several times a second on a fast tool, and the
  # plane's row does not need to see each of them.
  @status_debounce_ms 500

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
    :archive_timer,
    :archived_fingerprint,
    :status_timer,
    :last_status,
    status: :new,
    activated_at: nil,
    dormant_after_ms: @dormant_after_ms,
    status_dirty: false,
    lifecycle: %{state: "idle", done_reason: nil, interrupted: false, approvals: MapSet.new()}
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
        usage_follow(state)
        state = state |> seed_lifecycle() |> status_changed() |> touch() |> schedule_archive()
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

  def handle_call(:go_dormant, _from, state),
    do: {:reply, {:error, {:not_active, state.status}}, state}

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

  def handle_info({:troupe_event, _session_id, event}, state) do
    {:noreply, state |> observe(event) |> touch()}
  end

  def handle_info(:status_tick, state) do
    state = %{state | status_timer: nil}
    {:noreply, if(state.status_dirty, do: flush_status(state), else: state)}
  end

  # A periodic workspace archive, so losing the volume costs at most one interval of
  # files rather than every file. Skipped when the tree has not changed, which is the
  # common case for a session somebody is reading rather than working in.
  def handle_info(:archive, %__MODULE__{status: :active} = state) do
    fingerprint = fingerprint(state.workspace)

    state =
      if fingerprint == state.archived_fingerprint do
        state
      else
        sealed = Sealer.status(state.sealer)
        archive(state, sealed.sealed_through)
        %{state | archived_fingerprint: fingerprint}
      end

    {:noreply, schedule_archive(state)}
  end

  def handle_info(:archive, state), do: {:noreply, state}

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

      record_upgrade(context.session_id, Keyword.get(opts, :bundle))

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

  # Only when the version it was pinned to has been retired. A session whose bundle did
  # not move says nothing, because a `config_upgraded` on every activation would be noise
  # that hid the one that mattered.
  defp record_upgrade(_session_id, nil), do: :ok

  defp record_upgrade(_session_id, %{upgraded_from: nil}), do: :ok

  defp record_upgrade(session_id, bundle) do
    Log.append(session_id, ["root"], :config_upgraded, %{
      "channel" => bundle.channel,
      "from" => bundle.upgraded_from,
      "to" => bundle.version,
      "hash" => bundle.hash
    })
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

    # While the log process is still up, because folding it forward is how anything the
    # collector dropped or never saw is recovered — and a session going dormant is the
    # last chance to charge for it before the log stops answering.
    usage_flush(state)
    # Read while the tree is still up: the projection that knows the cost goes down
    # with it, and the dormancy report is the last word the plane gets on this session
    # until it wakes again.
    lifecycle = status_fields(state)

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

    payload =
      Map.merge(lifecycle, %{
        "session_id" => context.session_id,
        "epoch" => context.epoch,
        "last_seq" => sealed.sealed_through,
        "head_hash" => sealed.head_hash,
        "workspace_seq" => archive[:seq],
        "reason" => "dormant",
        "type" => "session.dormant"
      })

    state.report.(payload)

    # Last, and only once every byte of it is in object storage under a key the plane
    # cannot read. A plaintext workspace left on a PVC is the thing the Forbidden list
    # names first.
    erased = erase_local(state)

    {:ok,
     Map.merge(sealed, %{workspace: archive, erased: erased, session_id: context.session_id})}
  end

  defp archive(state, seq) do
    context = state.context

    case Workspace.archive(state.workspace) do
      {:ok, compressed, plain_bytes} ->
        sealed = Cipher.seal(context.data_key, context.session_id, compressed)
        upload(state, seq, sealed, plain_bytes)

      {:error, reason} ->
        %{seq: nil, error: reason}
    end
  end

  # Uploaded first, cached second. The cache is a convenience and the upload is the
  # durability, so a pod that ran out of disk while caching has still made the session
  # safe; one that cached and failed to upload would only look as if it had.
  defp upload(state, seq, sealed, plain_bytes) do
    context = state.context
    key = Storage.workspace_key(context.session_id, seq, "tar.zst")

    case ObjectStore.put(context.store, key, sealed) do
      {:ok, _} ->
        Cache.put_workspace(context.session_id, context.state_dir, seq, sealed)
        %{seq: seq, bytes: byte_size(sealed), plain_bytes: plain_bytes, cached: true}

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

  # -- status -----------------------------------------------------------------

  # Where the root agent stands the moment the tree is up, read once rather than
  # inferred from events that arrived before this process subscribed. A session that
  # came back interrupted, or with an approval outstanding from before it slept, is
  # reported that way from its first heartbeat.
  defp seed_lifecycle(state) do
    lifecycle =
      case Troupe.snapshot(state.session_id) do
        %{state: agent_state, done_reason: reason} ->
          %{
            state.lifecycle
            | state: Atom.to_string(agent_state),
              done_reason: reason && Atom.to_string(reason)
          }

        _ ->
          state.lifecycle
      end

    approvals = state.session_id |> Summary.snapshot() |> Map.get("approvals", []) |> MapSet.new()
    interrupted = interrupted_on_restore?(state.session_id)

    %{state | lifecycle: %{lifecycle | approvals: approvals, interrupted: interrupted}}
  end

  # The root's most recent restart, if it was interrupted and nothing has happened
  # since. Read from the log rather than remembered, because the event was written
  # before this process was listening.
  defp interrupted_on_restore?(session_id) do
    session_id
    |> Troupe.replay_from(0)
    |> Enum.filter(&(&1.agent == ["root"] and &1.type in ["agent_restarted", "user_input"]))
    |> List.last()
    |> case do
      %Event{type: "agent_restarted", data: %{"interrupted" => true}} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # The fold that turns the session's events into the four lifecycle facts. Only the
  # root agent's transitions count: a subagent thinking under an idle root is a root
  # that is acting, and the root's own state says so.
  defp observe(state, %Event{type: "agent_state", agent: ["root"], data: data}) do
    lifecycle = %{
      state.lifecycle
      | state: data["state"],
        done_reason: data["done_reason"],
        interrupted: state.lifecycle.interrupted and data["state"] == "idle"
    }

    status_changed(%{state | lifecycle: lifecycle})
  end

  defp observe(state, %Event{type: "agent_restarted", agent: ["root"], data: data}) do
    status_changed(put_in(state.lifecycle.interrupted, data["interrupted"] == true))
  end

  defp observe(state, %Event{type: "user_input", agent: ["root"]}) do
    status_changed(put_in(state.lifecycle.interrupted, false))
  end

  defp observe(state, %Event{type: "approval_requested", data: %{"call_id" => id}}) do
    status_changed(update_in(state.lifecycle.approvals, &MapSet.put(&1, id)))
  end

  defp observe(state, %Event{type: type, data: %{"call_id" => id}})
       when type in ["approval_decided", "approval_resolved"] do
    status_changed(update_in(state.lifecycle.approvals, &MapSet.delete(&1, id)))
  end

  defp observe(state, _event), do: state

  # `waiting` outranks everything: a session with a question outstanding is waiting on
  # a person whatever its agent is doing meanwhile. `interrupted` is an idle root that
  # came back mid-turn and has not been asked to carry on.
  defp lifecycle_status(%{approvals: approvals} = lifecycle) do
    cond do
      MapSet.size(approvals) > 0 -> "waiting"
      lifecycle.state == "done" -> "done"
      lifecycle.interrupted -> "interrupted"
      lifecycle.state in ["thinking", "compacting"] -> "thinking"
      lifecycle.state == "acting" -> "acting"
      true -> "idle"
    end
  end

  defp status_fields(state) do
    %{
      "status" => lifecycle_status(state.lifecycle),
      "done_reason" => state.lifecycle.done_reason,
      "pending_approvals" => MapSet.size(state.lifecycle.approvals),
      "cost_micros" => cost_micros(state.session_id)
    }
  end

  # The pod's usage collector, where there is one. There is none on a laptop and none
  # in most tests, and a session must run identically either way — so both of these are
  # a lookup and a no-op rather than a dependency.
  defp usage_follow(state) do
    if Process.whereis(Usage) do
      Usage.follow(Usage, state.session_id, Keyword.get(state.opts, :usage_seq, 0))
    end

    :ok
  end

  defp usage_flush(state) do
    if Process.whereis(Usage) do
      Usage.follow(Usage, state.session_id, Keyword.get(state.opts, :usage_seq, 0))
      Usage.flush(Usage, state.session_id)
    end

    :ok
  end

  # The summary's cost, in micro-units of the ledger's currency, or nothing when the
  # projection is not answering — which is what a session mid-shutdown looks like.
  # Micro-units are read from the projection's own integer; the whole-unit `cost` is a
  # fallback for a snapshot folded by an older build that had only the float.
  defp cost_micros(session_id) do
    case Summary.snapshot(session_id) do
      %{"cost_micros" => micros} when is_integer(micros) -> micros
      %{"cost" => cost} when is_number(cost) -> round(cost * 1_000_000)
      _ -> 0
    end
  end

  # Sent when the fields changed, and no more than once per debounce window: the first
  # change goes out at once, and anything that changes before the window closes is
  # sent as one notification when it does. A session that stopped changing is not
  # reported again.
  defp status_changed(%__MODULE__{status: status} = state) when status != :active, do: state

  defp status_changed(state) do
    if status_fields(state) == state.last_status,
      do: state,
      else: flush_status(%{state | status_dirty: true})
  end

  defp flush_status(%{status_timer: nil} = state) do
    fields = status_fields(state)

    payload =
      Map.merge(fields, %{
        "type" => "session.status",
        "session_id" => state.session_id,
        "epoch" => state.context && state.context.epoch
      })

    state.report.(payload)

    %{
      state
      | last_status: fields,
        status_dirty: false,
        status_timer: Process.send_after(self(), :status_tick, @status_debounce_ms)
    }
  end

  defp flush_status(state), do: state

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

  defp schedule_archive(state) do
    if state.archive_timer, do: Process.cancel_timer(state.archive_timer)
    interval = Keyword.get(state.opts, :archive_every_ms, @archive_every_ms)
    %{state | archive_timer: Process.send_after(self(), :archive, interval)}
  end

  # Cheap enough to run every few minutes on a large tree, and it moves whenever a file
  # is written, added or removed — which is all this needs to decide.
  defp fingerprint(nil), do: nil

  defp fingerprint(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce({0, 0, 0}, fn path, {count, bytes, newest} ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{size: size, mtime: mtime}} ->
          {count + 1, bytes + size, max(newest, mtime)}

        _ ->
          {count, bytes, newest}
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
