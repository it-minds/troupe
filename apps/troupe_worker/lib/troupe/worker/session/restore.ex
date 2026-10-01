defmodule Troupe.Worker.Session.Restore do
  @moduledoc """
  Rebuild a session on this pod from object storage alone.

  A worker pod holds no session state it cannot lose. Everything that says what a
  session is — its events, its workspace, its snapshots — is in object storage, and a
  restore is the only path from there back to a running actor tree. That is what makes
  relocation and PVC loss the same operation: neither has anything local to start from.

  The order is events first, workspace second, tree last. The event log is the session's
  truth and the workspace is a cache of what the events did to a directory, so a
  workspace archive that is missing or corrupt costs the working tree and not the
  history.
  """

  alias Troupe.KMS.OpenBao
  alias Troupe.ObjectStore
  alias Troupe.Paths
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Log, Summary}
  alias Troupe.Sessions.{Cipher, Context, Snapshot, Storage}
  alias Troupe.Worker.Cache
  alias Troupe.Worker.Session.Workspace
  alias Troupe.Worker.Sessions

  require Logger

  @doc """
  Write a session's durable log to disk, ready for `Troupe.resume/2` to replay.

  Only the live segments are read: a chain of them from `seq` 1, with the highest epoch
  winning at every step. Segments from an epoch the session has moved past were written
  by a pod that had already been fenced, and merging them would put events into the
  history that never happened to anyone.

  Written under `with_log/2`, and `:bytes` is how much was written, which is how a reader
  tells the log it restored from one somebody has since written to. `:found` says whether
  the log's directory was there before, looked at under the same lock.

  `unless_active: true` is a reader's: a manager registered for the session on this pod
  when the lock is taken means the log is that activation's, starting or running, and
  nothing is written (`{:error, :active}`). Looked at here rather than only before the
  read began, because an activation can start and write to the log while the segments
  download, and storage's copy written over that log would lose what the session has
  logged since its last seal (Decision 743).
  """
  @spec events(Context.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def events(%Context{} = context, workspace_root, opts \\ []) do
    path = log_path(context.session_id, workspace_root, context.state_dir)

    with {:ok, all} <- Storage.list_segments(context.store, context.session_id),
         live = Storage.live_segments(all),
         {:ok, events} <- read_all(context, live),
         lines = Enum.map(events, &[Jason.encode_to_iodata!(&1), ?\n]),
         {:ok, found} <- write_log(context.session_id, path, lines, opts) do
      {:ok,
       %{
         path: path,
         found: found,
         bytes: IO.iodata_length(lines),
         events: length(events),
         segments: length(live),
         skipped: length(all) - length(live),
         last_seq: events |> List.last() |> seq_of(),
         head_hash: head_hash(path)
       }}
    else
      {:error, reason} -> {:error, unreachable(context.store, reason)}
    end
  end

  defp write_log(session_id, path, lines, opts) do
    with_log(session_id, fn ->
      if Keyword.get(opts, :unless_active, false) and Sessions.whereis(session_id) do
        {:error, :active}
      else
        found = File.exists?(Path.dirname(path))
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, lines)
        {:ok, found}
      end
    end)
  end

  @doc """
  Run `fun` holding this pod's lock on one session's local log, and return what it returns.

  A restore writes the log under it, and a reader that is going away removes the log it
  restored under it (`Troupe.Worker.Session.Reader`). So an activation that starts as a
  reader leaves has either registered by the time the reader looks, and the reader leaves
  the log to it, or writes its own log after the reader's has gone — never before, which
  would have the reader remove the log a starting session is about to replay.

  The other way round too: a reader's restore writes nothing once a manager has
  registered (`events/3`), and an activation looks for a log already there, and removes
  the one it wrote when it fails, under it (`Troupe.Worker.Session.Manager`). What is done
  under it is file work and a registry lookup, never a call to a manager or a reader, and
  it is the only lock either takes: neither can hold it waiting for the other.
  """
  @spec with_log(String.t(), (-> result)) :: result when result: term()
  def with_log(session_id, fun) do
    :global.trans({{__MODULE__, :log, session_id}, self()}, fun, [node()])
  end

  @doc """
  An object-store failure that is the network's, named as one.

  A pod that cannot reach object storage restores nothing, and the transport error said
  as it is — `%Req.TransportError{reason: :timeout}`, some seconds later — names neither
  the store nor that it was the store. Behind an egress policy that dropped the
  connection, that was all a person and an operator were told. So a transport failure is
  `{:object_store_unreachable, endpoint, reason}`, and anything else — a refusal, a
  segment that will not decrypt — is left as it was.

  Not a report that parks the session (Decision 661): storage that does not answer is the
  plane's to retry, and the session is fine where it is.
  """
  @spec unreachable(ObjectStore.store(), term()) :: term()
  def unreachable(store, %Req.TransportError{reason: reason}),
    do: {:object_store_unreachable, endpoint(store), reason}

  def unreachable(store, {:unreadable_segment, _key, %Req.TransportError{} = error}),
    do: unreachable(store, error)

  def unreachable(_store, reason), do: reason

  @doc """
  Whether this pod can reach its object store, said in the log when it cannot.

  Asked once when the pod enrols, so that a store the pod cannot reach is a line in its
  log before it is the first person's session that will not start. One listing and no
  retry: the next enrolment asks again, and every activation says it anyway.
  """
  @spec check_reachable(ObjectStore.store()) :: :ok | {:error, term()}
  def check_reachable(store) do
    case ObjectStore.list(store, "reachability-probe/") do
      {:ok, _keys} ->
        :ok

      {:error, reason} ->
        reason = unreachable(store, reason)

        Logger.error(
          "troupe worker: this pod cannot use its object store, so no session can be " <>
            "restored or sealed here: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp endpoint(%ObjectStore{endpoint: endpoint}), do: endpoint
  defp endpoint(_signed), do: nil

  @doc """
  Open a session's context, naming a key manager the pod cannot reach.

  Opening a context asks the key manager for the session's key, and one the pod cannot
  reach is `{:kms_unreachable, address, reason}`, as `unreachable/2` names an object store:
  the transport error alone said neither which host nor that it was the key manager.
  Activating, reading and forking all open one here, so all three say it the same way. A
  key manager that answered and refused is left as it said.
  """
  @spec open_context(String.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def open_context(session_id, opts) do
    case Context.open(session_id, opts) do
      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:kms_unreachable, OpenBao.address(Keyword.get(opts, :kms_options, [])), reason}}

      result ->
        result
    end
  end

  defp read_all(context, segments) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, acc} ->
      case Storage.read_segment(context.store, context.session_id, context.data_key, segment.key) do
        {:ok, events} -> {:cont, {:ok, acc ++ events}}
        {:error, reason} -> {:halt, {:error, {:unreadable_segment, segment.key, reason}}}
      end
    end)
  end

  defp seq_of(nil), do: 0
  defp seq_of(%{"seq" => seq}), do: seq
  defp seq_of(_event), do: 0

  # Read back through the core's own reader, so a restored log that the core would
  # reject is caught here rather than at the first append.
  defp head_hash(path) do
    case path |> Log.read_file() |> List.last() do
      nil -> nil
      event -> Event.hash(event)
    end
  end

  @doc "Where the core keeps this session's log, which is where a restore writes it."
  @spec log_path(String.t(), Path.t(), Path.t() | nil) :: Path.t()
  def log_path(session_id, workspace_root, state_dir \\ nil) do
    Path.join(Paths.session_dir(workspace_root, session_id, state_dir), "events.jsonl")
  end

  @doc """
  Put the workspace back from its newest archive.

  A session with no archive is not an error: one that went dormant before it wrote
  anything, or one restored purely to be read, has an empty tree and a full history.

  A listing that failed is not a session with no archive. Read as one, storage that went
  away between the events and the tree brought the session back with an empty tree, or
  with an older one from this pod's cache, under a history that had moved past it — and
  the next archive sealed that over the real one. So it fails the activation, named by
  `unreachable/2` when it was the network's, and the plane tries again.
  """
  @spec workspace(Context.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def workspace(%Context{} = context, root) do
    case fetch_archive(context) do
      :none ->
        File.mkdir_p!(root)
        {:ok, %{restored: false, seq: nil}}

      {:ok, source, seq, sealed} ->
        with {:ok, archive} <- Cipher.open(context.data_key, context.session_id, sealed),
             :ok <- Workspace.restore(archive, root) do
          {:ok, %{restored: true, seq: seq, source: source, bytes: byte_size(sealed)}}
        end

      {:error, reason} ->
        {:error, unreachable(context.store, reason)}
    end
  end

  # The pod's own cache where it will do. It holds the same sealed bytes that went to
  # object storage, so using it is a local read instead of a download and is not a
  # different answer — and a cache that is behind what storage has is ignored rather than
  # trusted, which is why storage is asked first and the cache used only once it has
  # answered.
  defp fetch_archive(context) do
    with {:ok, remote} <- newest_archive(context) do
      cached = Cache.get_workspace(context.session_id, context.state_dir)

      case {remote, cached} do
        {nil, :miss} ->
          :none

        {nil, {:ok, seq, sealed}} ->
          {:ok, :cache, seq, sealed}

        {{seq, _extension}, {:ok, seq, sealed}} ->
          {:ok, :cache, seq, sealed}

        {{seq, extension}, _stale_or_missing} ->
          download(context, seq, extension)
      end
    end
  end

  defp download(context, seq, extension) do
    key = Storage.workspace_key(context.session_id, seq, extension)

    case ObjectStore.get(context.store, key) do
      {:ok, sealed} -> {:ok, :storage, seq, sealed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp newest_archive(context) do
    with {:ok, keys} <-
           ObjectStore.list(context.store, Storage.prefix(context.session_id) <> "workspace/") do
      {:ok,
       keys |> Enum.flat_map(&parse_archive_key/1) |> Enum.max_by(&elem(&1, 0), fn -> nil end)}
    end
  end

  defp parse_archive_key(key) do
    case key |> Path.basename() |> Integer.parse() do
      {seq, "." <> extension} -> [{seq, extension}]
      _ -> []
    end
  end

  @doc """
  The projection for a session, from the newest usable snapshot plus the tail.

  A snapshot is pure cache: anything wrong with it — a format this build does not write,
  a fold computed by a different build, bytes that will not decode — discards it and
  replays everything. The result is the same either way, which is the property that
  makes discarding it the safe choice rather than a loss.

  `:from` says where the answer came from, because "this took four seconds because the
  snapshot was rejected" is worth being able to see.
  """
  @spec projection(Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def projection(%Context{} = context, opts \\ []) do
    with {:ok, all} <- Storage.list_segments(context.store, context.session_id) do
      live = Storage.live_segments(all)

      case usable_snapshot(context, opts) do
        {:ok, fold, seq} -> fold_tail(context, live, fold, seq, :snapshot)
        {:error, reason} -> fold_tail(context, live, Summary.empty(), 0, {:replayed, reason})
      end
    end
  end

  defp usable_snapshot(context, opts) do
    case Storage.latest_snapshot_seq(context.store, context.session_id) do
      nil ->
        {:error, :none}

      seq ->
        case Storage.get_snapshot(context.store, context.session_id, context.data_key, seq) do
          {:ok, stored} -> Snapshot.open(stored, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Only the segments after the snapshot. With no snapshot that is every segment, which
  # is the full replay the fallback promises.
  defp fold_tail(context, segments, fold, from_seq, source) do
    tail = Enum.filter(segments, &(&1.last_seq > from_seq))

    with {:ok, events} <- read_all(context, tail) do
      folded =
        events
        |> Enum.map(&Event.from_json/1)
        |> Enum.filter(&(&1.seq > from_seq))
        |> Enum.reduce(fold, &Summary.fold(&2, &1))

      {:ok, %{fold: folded, from: source, from_seq: from_seq, segments: length(tail)}}
    end
  end

  @doc """
  Where this session's working tree goes on this pod.

  Explicit if the caller said so, otherwise under the state directory by session id —
  which is what a worker uses, because a pod has no idea what directory the session was
  created in and does not need one.
  """
  @spec workspace_root(Context.t(), keyword()) :: Path.t()
  def workspace_root(%Context{} = context, opts \\ []) do
    Keyword.get(opts, :workspace) || context.workspace || default_workspace(context)
  end

  @doc """
  Start the actor tree over a restored log and workspace.

  Deliberately separate from the restore itself, because the sealer has to be
  subscribed before this runs: events appended while the tree comes up — the activation
  itself, anything an agent replays into — are durable events like any other, and a
  sealer started afterwards would miss them.

  `:prompt` becomes the session's first input, and only on the activation that finds
  the root agent's log empty; a later activation with the same prompt replays the input
  it already took. `:terms` are config overrides the plane set for this session —
  `max_turns`, `wall_clock_ms`, `approvals` — and win over the pod's own. A budget the
  terms set is a contract, not a question (Decision 660): the agent stops at it rather
  than asking whoever is attached for more, unless the terms themselves say otherwise.
  """
  @spec start(Context.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(%Context{} = context, root, opts \\ []) do
    overrides =
      opts
      |> Keyword.get(:config_overrides, [])
      |> then(fn given ->
        if context.state_dir,
          do: Keyword.put_new(given, :state_dir, context.state_dir),
          else: given
      end)
      # Who the gateway bills and records this session against. The owner, not whoever
      # is typing: a collaborator's input is billed to the owner's team budget, because
      # the budget belongs to the session and a session has one owner.
      |> Keyword.put_new(:attribution, %{owner: context.owner_subject, team: context.team})
      # A client attached to a remote session has no other way to know that `shell` wrote
      # something, so this is not optional here.
      |> Keyword.put_new(:fs_events, true)
      |> Keyword.merge(contract(Keyword.get(opts, :terms, [])))

    Troupe.resume(context.session_id,
      workspace: root,
      # The *agent* profile, which is a session's configuration. `context.profile` is the
      # worker profile — the Kubernetes one — and the two are different things that
      # happen to share a word.
      agent: Keyword.get(opts, :agent),
      task: Keyword.get(opts, :prompt),
      bundle: Keyword.get(opts, :bundle),
      kind: :team,
      origin: Keyword.get(opts, :origin),
      fake: Keyword.get(opts, :fake),
      config_overrides: overrides
    )
  end

  # The limits the terms set ride along by the budget's names, so a session whose terms
  # do let it ask cannot raise itself past them (Decision 699).
  defp contract([]), do: []

  defp contract(terms) do
    caps =
      terms
      |> Keyword.take([:max_turns, :wall_clock_ms])
      |> Map.new(fn
        {:wall_clock_ms, ms} -> {:wall_clock, ms}
        {key, value} -> {key, value}
      end)

    terms |> Keyword.put_new(:budget_asks, false) |> Keyword.put(:terms, caps)
  end

  defp default_workspace(context) do
    Path.join([Paths.state_dir(context.state_dir), "workspaces", context.session_id])
  end
end
