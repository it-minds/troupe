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

  alias Troupe.Paths
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log
  alias Troupe.Worker.{ObjectStore, Storage}
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
    case newest_archive(context) do
      nil ->
        File.mkdir_p!(root)
        {:ok, %{restored: false, seq: nil}}

      {seq, extension} ->
        with {:ok, archive} <-
               Storage.get_workspace(context.store, context.session_id, context.data_key, seq, extension),
             :ok <- Workspace.restore(archive, root) do
          {:ok, %{restored: true, seq: seq, bytes: byte_size(archive)}}
        end
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

    Troupe.resume(context.session_id,
      workspace: root,
      agent: Keyword.get(opts, :profile) || context.profile,
      fake: Keyword.get(opts, :fake),
      config_overrides: overrides
    )
  end

  defp default_workspace(context) do
    Path.join([Paths.state_dir(context.state_dir), "workspaces", context.session_id])
  end
end
