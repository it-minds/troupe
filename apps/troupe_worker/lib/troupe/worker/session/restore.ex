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

  alias Troupe.ObjectStore
  alias Troupe.Paths
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Log, Summary}
  alias Troupe.Sessions.{Cipher, Snapshot, Storage}
  alias Troupe.Worker.Cache
  alias Troupe.Worker.Session.{Context, Workspace}

  @doc """
  Write a session's durable log to disk, ready for `Troupe.resume/2` to replay.

  Only the live segments are read: a chain of them from `seq` 1, with the highest epoch
  winning at every step. Segments from an epoch the session has moved past were written
  by a pod that had already been fenced, and merging them would put events into the
  history that never happened to anyone.
  """
  @spec events(Context.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def events(%Context{} = context, workspace_root) do
    with {:ok, all} <- Storage.list_segments(context.store, context.session_id),
         live = Storage.live_segments(all),
         {:ok, events} <- read_all(context, live) do
      path = log_path(context.session_id, workspace_root, context.state_dir)
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, Enum.map(events, &[Jason.encode_to_iodata!(&1), ?\n]))

      {:ok,
       %{
         path: path,
         events: length(events),
         segments: length(live),
         skipped: length(all) - length(live),
         last_seq: events |> List.last() |> seq_of(),
         head_hash: head_hash(path)
       }}
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
        {:error, reason}
    end
  end

  # The pod's own cache first. It holds the same sealed bytes that went to object
  # storage, so using it is a local read instead of a download and is not a different
  # answer — and a cache that is behind what storage has is ignored rather than trusted.
  defp fetch_archive(context) do
    remote = newest_archive(context)
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

  defp download(context, seq, extension) do
    key = Storage.workspace_key(context.session_id, seq, extension)

    case ObjectStore.get(context.store, key) do
      {:ok, sealed} -> {:ok, :storage, seq, sealed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp newest_archive(context) do
    case ObjectStore.list(context.store, Storage.prefix(context.session_id) <> "workspace/") do
      {:ok, keys} -> keys |> Enum.flat_map(&parse_archive_key/1) |> Enum.max_by(&elem(&1, 0), fn -> nil end)
      _ -> nil
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
  """
  @spec start(Context.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(%Context{} = context, root, opts \\ []) do
    overrides =
      opts
      |> Keyword.get(:config_overrides, [])
      |> then(fn given ->
        if context.state_dir, do: Keyword.put_new(given, :state_dir, context.state_dir), else: given
      end)
      # Who the gateway bills and records this session against. The owner, not whoever
      # is typing: a collaborator's input is billed to the owner's team budget, because
      # the budget belongs to the session and a session has one owner.
      |> Keyword.put_new(:attribution, %{owner: context.owner_subject, team: context.team})
      # A client attached to a remote session has no other way to know that `shell` wrote
      # something, so this is not optional here.
      |> Keyword.put_new(:fs_events, true)

    Troupe.resume(context.session_id,
      workspace: root,
      # The *agent* profile, which is a session's configuration. `context.profile` is the
      # worker profile — the Kubernetes one — and the two are different things that
      # happen to share a word.
      agent: Keyword.get(opts, :agent),
      fake: Keyword.get(opts, :fake),
      config_overrides: overrides
    )
  end

  defp default_workspace(context) do
    Path.join([Paths.state_dir(context.state_dir), "workspaces", context.session_id])
  end
end
