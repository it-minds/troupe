defmodule Troupe.Worker.Session.Workspace do
  @moduledoc """
  A session's working tree, on the way to object storage and back.

  Tar because it is the only archive format that survives a round trip through a
  workspace without losing what a workspace is: modes, symlinks, empty directories.
  zstd over it for the same reason segments are zstd — a source tree compresses well and
  the object tier is charged by the byte.

  `erase/1` is the half of dormancy the Forbidden list cares about: once a session's
  workspace is in object storage, encrypted with a key the pod holds and the plane
  cannot read, the plaintext copy on the PVC must be gone. Not moved, not truncated —
  gone, and then checked.
  """

  require Logger

  @doc """
  Archive a workspace into one encrypted-ready blob.

  Returns the uncompressed tar's size too, because that is the number a disk watermark
  reasons about and the compressed size is not.
  """
  @spec archive(Path.t()) :: {:ok, binary(), non_neg_integer()} | {:error, term()}
  def archive(root) do
    if File.dir?(root) do
      scratch = Path.join(System.tmp_dir!(), "troupe-ws-#{System.unique_integer([:positive])}.tar")

      try do
        entries = entries(root)

        case :erl_tar.create(String.to_charlist(scratch), entries) do
          :ok ->
            tar = File.read!(scratch)
            {:ok, :ezstd.compress(tar), byte_size(tar)}

          {:error, reason} ->
            {:error, reason}
        end
      after
        File.rm(scratch)
      end
    else
      {:error, :enoent}
    end
  end

  # Relative names, so the archive can be unpacked anywhere — a session that comes back
  # on a different pod lands under a different PVC path, and an archive full of absolute
  # names would either fail or overwrite the wrong tree.
  defp entries(root) do
    root
    |> walk()
    |> Enum.map(fn path ->
      {path |> Path.relative_to(root) |> String.to_charlist(), String.to_charlist(path)}
    end)
  end

  # Top-level entries only: erl_tar recurses into directories itself, and listing both a
  # directory and its contents writes every file twice.
  defp walk(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.sort() |> Enum.map(&Path.join(root, &1))
      {:error, _} -> []
    end
  end

  @doc "Unpack an archive into a workspace root, creating it if it is not there."
  @spec restore(binary(), Path.t()) :: :ok | {:error, term()}
  def restore(compressed, root) do
    File.mkdir_p!(root)
    scratch = Path.join(System.tmp_dir!(), "troupe-ws-#{System.unique_integer([:positive])}.tar")

    try do
      File.write!(scratch, :ezstd.decompress(compressed))
      :erl_tar.extract(String.to_charlist(scratch), cwd: String.to_charlist(root))
    after
      File.rm(scratch)
    end
  end

  @doc """
  Remove the plaintext workspace, and say whether anything is left.

  The check is not paranoia about `rm -rf`: a workspace with a file the pod cannot
  delete — a stale mount, a read-only bind — would leave plaintext on the PVC while the
  code believed it had cleaned up, and dormancy would report success. Better to fail.
  """
  @spec erase(Path.t()) :: :ok | {:error, {:not_erased, [Path.t()]}}
  def erase(root) do
    File.rm_rf(root)

    case File.exists?(root) do
      false ->
        :ok

      true ->
        remaining = leftovers(root)
        Logger.error("troupe worker: workspace #{root} still has #{length(remaining)} entries")
        {:error, {:not_erased, remaining}}
    end
  end

  defp leftovers(root) do
    case File.ls(root) do
      {:ok, []} -> []
      {:ok, names} -> Enum.map(names, &Path.join(root, &1))
      {:error, _} -> [root]
    end
  end

  @doc "How many bytes a workspace is using, for the disk watermarks."
  @spec size(Path.t()) :: non_neg_integer()
  def size(root) do
    root
    |> files()
    |> Enum.reduce(0, fn path, total ->
      case File.stat(path, time: :posix) do
        {:ok, %File.Stat{size: size}} -> total + size
        _ -> total
      end
    end)
  end

  defp files(root) do
    case File.ls(root) do
      {:ok, names} -> Enum.flat_map(names, &files_under(Path.join(root, &1)))
      {:error, _} -> []
    end
  end

  defp files_under(path) do
    if File.dir?(path), do: files(path), else: [path]
  end
end
