defmodule Troupe.Worker.GitHub.Tree do
  @moduledoc """
  The working tree a push carries, read with the pod's own git and no token.

  Every call here is `Troupe.Git`'s: the repository's own hooks, filters, fsmonitor and
  transports neutralised, the repository held to the workspace's own `.git`, and on a
  worker inside the sandbox over the workspace alone. None of it has the session's token,
  so none of it can do more than the agent's own shell could; it reads what the push will
  send, and the push itself is made through GitHub's API (`Troupe.Worker.GitHub.API`).

  The tree is the working tree as `git add -A` takes it: every file that `.gitignore`
  leaves in, staged. That is what a push sends, whatever the agent committed itself. It is
  staged into an index of the push's own, never the agent's: a push refused for a file it
  would have carried leaves nothing staged behind it, so a `.gitignore` is all it takes to
  leave that file out of the next one.
  """

  alias Troupe.Git

  @timeout_ms 120_000

  @typedoc "One path that changed between two trees, as `git diff-tree --raw` says it."
  @type change :: %{
          path: String.t(),
          status: String.t(),
          old_mode: String.t(),
          mode: String.t(),
          sha: String.t()
        }

  @doc """
  The working tree as `git add -A` would stage it, written as a tree, and that tree's name.

  Staged into an index of the push's own (`GIT_INDEX_FILE`, a file of a random name in the
  workspace's git directory, gone afterwards), which starts as what the agent has staged:
  the tree its own index holds, written without changing it. So what the agent staged or
  took out of git's index itself counts as it would have, and the agent's index is as the
  push found it, whatever the push makes of the tree.
  """
  @spec write(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def write(root) do
    index = "troupe-push-index-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    try do
      with {:ok, staged} <- staged(root),
           {:ok, _} <- git(root, ["read-tree", staged], index: index),
           {:ok, _} <- git(root, ["add", "-A"], index: index),
           {:ok, out} <- git(root, ["write-tree"], index: index),
           do: name(out)
    after
      for file <- [index, index <> ".lock"], do: File.rm(Path.join([root, ".git", file]))
    end
  end

  # What the agent has staged, as a tree: `write-tree` of its own index, which stages
  # nothing. An index holding a conflict writes no tree, and the push starts from the
  # commit checked out instead.
  defp staged(root) do
    case git(root, ["write-tree"]) do
      {:ok, out} ->
        name(out)

      {:error, _conflicted} ->
        with {:ok, out} <- git(root, ["rev-parse", "--verify", "HEAD^{tree}"]), do: name(out)
    end
  end

  @doc "The commit `HEAD` names, which is where a clone starts."
  @spec head(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def head(root) do
    with {:ok, out} <- git(root, ["rev-parse", "--verify", "HEAD^{commit}"]), do: name(out)
  end

  @doc """
  The commit the clone started from: the root of `HEAD`'s history, which in a clone of
  depth one is the commit it checked out, whatever was committed on it since. More than one
  root is a history this cannot read a start from.
  """
  @spec start(Path.t()) :: {:ok, String.t()} | {:error, String.t()}
  def start(root) do
    with {:ok, out} <- git(root, ["rev-list", "--max-parents=0", "HEAD"]) do
      case String.split(out, "\n", trim: true) do
        [one] -> name(one)
        roots -> {:error, "HEAD's history has #{length(roots)} roots, not one"}
      end
    end
  end

  @doc "The tree of `commit`, which must be in the workspace's repository."
  @spec tree_of(Path.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def tree_of(root, commit) do
    with {:ok, out} <- git(root, ["rev-parse", "--verify", commit <> "^{tree}"]), do: name(out)
  end

  @doc "What changed from tree `from` to tree `to`, file by file, without rename detection."
  @spec changes(Path.t(), String.t(), String.t()) :: {:ok, [change()]} | {:error, String.t()}
  def changes(root, from, to) do
    with {:ok, out} <-
           git(root, ["diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", "--raw", from, to]),
         do: {:ok, parse_raw(out)}
  end

  @doc "The size of every file in `tree`, by path."
  @spec sizes(Path.t(), String.t()) ::
          {:ok, %{String.t() => non_neg_integer()}} | {:error, String.t()}
  def sizes(root, tree) do
    with {:ok, out} <- git(root, ["ls-tree", "-r", "-l", "-z", tree]) do
      {:ok,
       out
       |> String.split(<<0>>, trim: true)
       |> Enum.flat_map(fn line ->
         case String.split(line, "\t", parts: 2) do
           [meta, path] ->
             case String.split(meta, ~r/\s+/, trim: true) do
               [_mode, "blob", _sha, size] -> [{path, String.to_integer(size)}]
               _other -> []
             end

           _other ->
             []
         end
       end)
       |> Map.new()}
    end
  end

  @doc """
  A blob's bytes, checked against its name: what a port carried that was not exactly the
  object (a line git wrote to its error stream among them) is refused, not sent.
  """
  @spec blob(Path.t(), String.t()) :: {:ok, binary()} | {:error, String.t()}
  def blob(root, sha) do
    with {:ok, content} <- git(root, ["cat-file", "blob", sha]) do
      if object_name(content, sha) == sha,
        do: {:ok, content},
        else: {:error, "the blob #{short(sha)} did not read back as itself"}
    end
  end

  @doc "A commit or tree name, shortened as a person reads one."
  @spec short(String.t()) :: String.t()
  def short(name) when is_binary(name), do: String.slice(name, 0, 7)

  # -- reading git's answers ------------------------------------------------------------

  # `:old_mode new_mode old_sha new_sha status NUL path NUL`, one after another.
  defp parse_raw(out) do
    out
    |> String.split(<<0>>)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.flat_map(fn
      [":" <> meta, path] ->
        case String.split(meta, " ") do
          [old_mode, mode, _old_sha, sha, status] ->
            [
              %{
                path: path,
                status: String.first(status),
                old_mode: old_mode,
                mode: mode,
                sha: sha
              }
            ]

          _other ->
            []
        end

      _other ->
        []
    end)
  end

  # git names a blob by the hash of its header and its bytes: SHA-1 for most repositories,
  # SHA-256 for one made with `--object-format=sha256`.
  defp object_name(content, sha) do
    algorithm = if byte_size(sha) == 64, do: :sha256, else: :sha
    data = "blob #{byte_size(content)}" <> <<0>> <> content
    :crypto.hash(algorithm, data) |> Base.encode16(case: :lower)
  end

  defp name(out) do
    name = String.trim(out)

    if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, name),
      do: {:ok, name},
      else: {:error, "git answered #{inspect(String.slice(name, 0, 120))} for a name"}
  end

  defp git(root, args, opts \\ []) do
    case Git.run(root, args, Keyword.put(opts, :timeout_ms, @timeout_ms)) do
      {:ok, out, 0} ->
        {:ok, out}

      {:ok, out, :timeout} ->
        {:error, "git #{hd(args)} did not finish: #{String.slice(String.trim(out), 0, 300)}"}

      {:ok, out, status} ->
        {:error, "git #{hd(args)} exited #{status}: #{String.slice(String.trim(out), 0, 300)}"}

      {:error, reason} ->
        {:error, "git #{hd(args)} was not run: #{Git.explain(reason)}"}
    end
  end
end
