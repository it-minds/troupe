defmodule Troupe.Worker.GitHub.Secrets do
  @moduledoc """
  What a push must not carry because it is mounted on this pod from a secret.

  The directories are the worker's configuration (`:secret_dirs`, by default
  `/var/run/secrets`, where the pod's projected tokens are, and the profile's MCP
  identities): nothing in a session's tree has any business being under one, being a link
  into one, or being a copy of a file in one. The agent's sandbox is not given these
  directories, so a copy means something got past that; this is the check that holds when
  something did.

  A copy is found by name, not by reading the push: each file under the directories is
  named as git would name it as a blob, and a path the push sends whose blob has that name
  is one. So the comparison is exact, costs one hash per mounted file, and never puts a
  secret's bytes anywhere but this VM's memory for as long as the hash takes. Nothing here
  logs a file's contents or its name's hash.
  """

  alias Troupe.Worker.GitHub.Tree

  # How much of the directories is read: mounted secrets are small and few, and a
  # directory that is neither is not read past these. A file of a few bytes is no secret,
  # and its name would be any other file's of the same bytes.
  @max_files 1_000
  @min_bytes 16
  @max_bytes 1024 * 1024
  @max_depth 8

  @default_dirs ["/var/run/secrets", "/etc/troupe/mcp-identities"]

  @doc "The directories this pod has mounted from secrets."
  @spec dirs() :: [Path.t()]
  def dirs, do: Application.get_env(:troupe_worker, :secret_dirs, @default_dirs)

  @doc """
  Which of `changes` (`Tree.changes/3`'s, without deletions) carry a mounted secret, each
  as `path (why)`: a path under one of the directories, a link into one, or a file whose
  bytes are a mounted file's.
  """
  @spec copies(Path.t(), [Tree.change()]) :: [String.t()]
  def copies(root, changes) do
    dirs = dirs() |> Enum.map(&Path.expand/1) |> Enum.filter(&File.dir?/1)

    if dirs == [] do
      []
    else
      names = names(dirs)
      for change <- changes, why = why(root, change, dirs, names), do: "#{change.path} (#{why})"
    end
  end

  defp why(root, change, dirs, names) do
    cond do
      under?(Path.expand(change.path, root), dirs) -> "it is under a mounted secret"
      change.mode == "120000" and link_into?(root, change, dirs) -> "a link to a mounted secret"
      MapSet.member?(names, change.sha) -> "a copy of a file mounted from a secret"
      true -> nil
    end
  end

  defp under?(path, dirs),
    do: Enum.any?(dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  # A link is a blob whose bytes are where it points, relative to the link's own directory.
  defp link_into?(root, change, dirs) do
    case Tree.blob(root, change.sha) do
      {:ok, target} ->
        under?(Path.expand(target, Path.dirname(Path.expand(change.path, root))), dirs)

      {:error, _reason} ->
        false
    end
  end

  # Every mounted file's name as a blob, both as SHA-1 and SHA-256 name it, so a repository
  # of either kind is compared like with like.
  defp names(dirs) do
    dirs
    |> Enum.flat_map(&files(&1, 0))
    |> Enum.uniq()
    |> Enum.take(@max_files)
    |> Enum.flat_map(fn file ->
      case read(file) do
        {:ok, content} -> [blob_name(content, :sha), blob_name(content, :sha256)]
        :skip -> []
      end
    end)
    |> MapSet.new()
  end

  # The files under `dir`, following the links a projected volume is made of (`..data`
  # and the names that point through it), as deep as `@max_depth`.
  defp files(_dir, depth) when depth > @max_depth, do: []

  defp files(dir, depth) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &entry_files(Path.join(dir, &1), depth))
      {:error, _reason} -> []
    end
  end

  defp entry_files(path, depth) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}}
      when size >= @min_bytes and size <= @max_bytes ->
        [path]

      {:ok, %File.Stat{type: :directory}} ->
        files(path, depth + 1)

      _other ->
        []
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> :skip
    end
  end

  defp blob_name(content, algorithm) do
    :crypto.hash(algorithm, "blob #{byte_size(content)}" <> <<0>> <> content)
    |> Base.encode16(case: :lower)
  end
end
