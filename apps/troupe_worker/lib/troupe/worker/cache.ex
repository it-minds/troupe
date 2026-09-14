defmodule Troupe.Worker.Cache do
  @moduledoc """
  What a pod keeps of a session it is no longer running.

  Dormancy deletes the plaintext workspace, because a plaintext workspace on a PVC is
  the first thing the Forbidden list names. What it may keep is the *encrypted* archive
  it just uploaded — the same bytes, under the same key, which the pod cannot read
  without fetching that key from OpenBao. Keeping it turns reactivation on the same pod
  from a download into a local read.

  A cache is therefore pure convenience, and everything about it follows from that:

  * it is evicted least-recently-used above the disk low watermark, because losing it
    costs a download and nothing else;
  * an entry that does not match what object storage says is ignored rather than
    repaired, for the same reason;
  * an *active* session's workspace is not a cache and is never evicted.
  """

  alias Troupe.Paths

  @doc "Where a pod keeps its caches."
  @spec root(Path.t() | nil) :: Path.t()
  def root(state_dir \\ nil), do: Path.join(Paths.state_dir(state_dir), "cache")

  @doc "Where one session's cache lives."
  @spec dir(String.t(), Path.t() | nil) :: Path.t()
  def dir(session_id, state_dir \\ nil), do: Path.join(root(state_dir), session_id)

  @doc """
  Keep a session's workspace archive, exactly as it went to object storage.

  Sealed bytes in and sealed bytes out: this module never holds a key and never sees a
  plaintext byte, which is what makes an eviction policy a storage decision rather than
  a security one.
  """
  @spec put_workspace(String.t(), Path.t() | nil, non_neg_integer(), binary()) :: :ok | {:error, term()}
  def put_workspace(session_id, state_dir, seq, sealed) do
    directory = dir(session_id, state_dir)
    File.mkdir_p!(directory)

    with :ok <- File.write(Path.join(directory, "workspace.#{seq}.enc"), sealed) do
      # Anything older is superseded. A cache holding three generations of the same
      # workspace is three times the disk for no benefit.
      prune_workspaces(directory, seq)
      touch(session_id, state_dir)
    end
  end

  defp prune_workspaces(directory, keep_seq) do
    directory
    |> workspace_files()
    |> Enum.reject(&(elem(&1, 0) == keep_seq))
    |> Enum.each(fn {_seq, path} -> File.rm(path) end)
  end

  @doc "The newest cached workspace archive, with the sequence it was taken at."
  @spec get_workspace(String.t(), Path.t() | nil) :: {:ok, non_neg_integer(), binary()} | :miss
  def get_workspace(session_id, state_dir \\ nil) do
    case session_id |> dir(state_dir) |> workspace_files() |> Enum.max_by(&elem(&1, 0), fn -> nil end) do
      nil ->
        :miss

      {seq, path} ->
        case File.read(path) do
          {:ok, sealed} ->
            touch(session_id, state_dir)
            {:ok, seq, sealed}

          {:error, _reason} ->
            :miss
        end
    end
  end

  defp workspace_files(directory) do
    [directory, "workspace.*.enc"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case path |> Path.basename() |> String.split(".") do
        ["workspace", seq, "enc"] -> parse(seq, path)
        _ -> []
      end
    end)
  end

  defp parse(seq, path) do
    case Integer.parse(seq) do
      {number, ""} -> [{number, path}]
      _ -> []
    end
  end

  @doc "Record that a cache was used, which is what least-recently-used means."
  @spec touch(String.t(), Path.t() | nil) :: :ok
  def touch(session_id, state_dir \\ nil) do
    directory = dir(session_id, state_dir)
    File.mkdir_p!(directory)
    File.write(Path.join(directory, "accessed"), DateTime.utc_now() |> DateTime.to_iso8601())
  end

  @doc "Every cache this pod holds, least recently used first."
  @spec entries(Path.t() | nil) :: [map()]
  def entries(state_dir \\ nil) do
    case File.ls(root(state_dir)) do
      # `DateTime`, not the default term order. Comparing two `%DateTime{}` structurally
      # compares their fields in key order — `:calendar, :day, :hour, :microsecond,
      # :minute, :month, :second, ...` — so microseconds outrank seconds and
      # `10:00:01.900` sorts after `10:00:02.100`. Least-recently-used is the whole
      # claim this function makes, and across a second boundary it was making it
      # backwards, which is a cache evicting the wrong session's workspace.
      {:ok, names} ->
        names |> Enum.map(&entry(&1, state_dir)) |> Enum.sort_by(& &1.accessed_at, DateTime)
      {:error, _reason} -> []
    end
  end

  defp entry(session_id, state_dir) do
    directory = dir(session_id, state_dir)

    %{
      session_id: session_id,
      path: directory,
      bytes: bytes_in(directory),
      accessed_at: accessed_at(directory)
    }
  end

  defp accessed_at(directory) do
    with {:ok, contents} <- File.read(Path.join(directory, "accessed")),
         {:ok, at, _offset} <- DateTime.from_iso8601(String.trim(contents)) do
      at
    else
      _ -> DateTime.from_unix!(0)
    end
  end

  defp bytes_in(directory) do
    [directory, "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.reduce(0, fn path, total ->
      case File.stat(path) do
        {:ok, %File.Stat{size: size}} -> total + size
        _ -> total
      end
    end)
  end

  @doc "How much of the volume this pod's caches are using."
  @spec total_bytes(Path.t() | nil) :: non_neg_integer()
  def total_bytes(state_dir \\ nil), do: state_dir |> entries() |> Enum.reduce(0, &(&1.bytes + &2))

  @doc "Drop one session's cache. Reactivating it then costs a download, and nothing more."
  @spec evict(String.t(), Path.t() | nil) :: non_neg_integer()
  def evict(session_id, state_dir \\ nil) do
    directory = dir(session_id, state_dir)
    bytes = bytes_in(directory)
    File.rm_rf(directory)
    bytes
  end
end
