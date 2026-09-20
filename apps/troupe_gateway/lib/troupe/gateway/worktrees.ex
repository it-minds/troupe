defmodule Troupe.Gateway.Worktrees do
  @moduledoc """
  Git worktrees, so two sessions in one repository do not fight over the files.

  A second session in a workspace that already has a live one defaults to its own
  worktree on `troupe/<slug>`. Without that, two agents edit the same checkout and
  each sees the other's half-finished work as if it were the user's — which is worse
  than either of them failing.

  Removal refuses a dirty tree unless forced: uncommitted work in a worktree is
  usually the only copy.

  A worktree's work ends in one of two ways (Decision 647). `merge/3` commits whatever
  is uncommitted there, merges its branch into the checkout it came from with a merge
  commit, and removes the worktree and the branch; a merge git cannot complete is
  aborted, and the worktree is left exactly as it was for the person to resolve.
  `discard/2` removes the worktree and deletes its branch, uncommitted work included —
  which is what the word means. Both refuse while a session is still working in the
  worktree, because the tree would move under its agent.
  """

  alias Troupe.Reaper

  @type resolved :: %{path: Path.t(), worktree: Path.t() | nil, branch: String.t() | nil}

  @doc """
  Decide where a new session should work.

  `mode` is `"auto"` (branch only when the workspace is busy), `"never"`, or
  `"always"`.
  """
  @spec resolve(Path.t(), String.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(workspace, mode) do
    workspace = Path.expand(workspace)

    cond do
      mode == "never" -> {:ok, plain(workspace)}
      not git_repository?(workspace) -> {:ok, plain(workspace)}
      mode == "always" -> create(workspace)
      busy?(workspace) -> create(workspace)
      true -> {:ok, plain(workspace)}
    end
  end

  defp plain(workspace), do: %{path: workspace, worktree: nil, branch: nil}

  defp busy?(workspace) do
    %{}
    |> Troupe.list_live_sessions()
    |> Enum.any?(&(&1.workspace == workspace and &1.state == :active))
  end

  @doc "Create a worktree for a workspace on a fresh `troupe/<slug>` branch."
  @spec create(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def create(workspace) do
    slug = slug()
    branch = "troupe/" <> slug
    path = Path.join(Path.dirname(workspace), Path.basename(workspace) <> "-" <> slug)

    case git(workspace, ["worktree", "add", "-b", branch, path]) do
      {:ok, _output, 0} -> {:ok, %{path: path, worktree: path, branch: branch}}
      {:ok, output, _status} -> {:error, {:worktree_failed, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every worktree of a workspace, with the session using it and whether it is dirty."
  @spec list(Path.t() | nil) :: [map()]
  def list(nil) do
    %{}
    |> Troupe.list_live_sessions()
    |> Enum.map(& &1.workspace)
    |> Enum.uniq()
    |> Enum.flat_map(&list/1)
  end

  def list(workspace) do
    workspace = Path.expand(workspace)

    case git(workspace, ["worktree", "list", "--porcelain"]) do
      {:ok, output, 0} -> output |> parse_porcelain() |> Enum.map(&annotate/1)
      _ -> []
    end
  end

  @doc "Remove a worktree. Refuses a dirty one unless `force`."
  @spec remove(Path.t(), boolean()) :: :ok | {:error, :dirty | term()}
  def remove(path, force?) do
    path = Path.expand(path)

    cond do
      not File.dir?(path) ->
        {:error, :not_found}

      not force? and dirty?(path) ->
        {:error, :dirty}

      true ->
        args = ["worktree", "remove"] ++ if(force?, do: ["--force"], else: []) ++ [path]

        case git(path, args) do
          {:ok, _output, 0} -> :ok
          {:ok, output, _} -> {:error, String.trim(output)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Land a worktree's branch on the checkout it came from, then remove it.

  `opts[:message]` is the commit message for work left uncommitted in the worktree;
  the default names the branch. Returns the branch, whether anything had to be
  committed first, and git's own account of the merge.
  """
  @spec merge(Path.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, {:conflicts, String.t()} | {:busy, String.t()} | term()}
  def merge(workspace, path, opts \\ []) do
    workspace = Path.expand(workspace)
    path = Path.expand(path)

    with :ok <- worktree_at(path),
         :ok <- resting(path),
         {:ok, branch} <- branch_of(path),
         {:ok, committed?} <- commit_pending(path, Keyword.get(opts, :message) || "troupe: #{branch}"),
         {:ok, output} <- merge_branch(workspace, branch),
         :ok <- remove_tree(path),
         :ok <- delete_branch(workspace, branch, "-d") do
      {:ok, %{"branch" => branch, "committed" => committed?, "output" => output}}
    end
  end

  @doc "Throw a worktree away: the tree, its branch, and any work not yet merged."
  @spec discard(Path.t(), Path.t()) :: {:ok, map()} | {:error, {:busy, String.t()} | term()}
  def discard(workspace, path) do
    workspace = Path.expand(workspace)
    path = Path.expand(path)

    with :ok <- worktree_at(path),
         :ok <- resting(path),
         {:ok, branch} <- branch_of(path),
         :ok <- remove_tree(path),
         :ok <- delete_branch(workspace, branch, "-D") do
      {:ok, %{"branch" => branch}}
    end
  end

  defp worktree_at(path) do
    cond do
      not File.dir?(path) -> {:error, :not_found}
      not match?({:ok, _, 0}, git(path, ["rev-parse", "--git-dir"])) -> {:error, :not_a_worktree}
      true -> :ok
    end
  end

  # The session working in this tree, if its agent is mid-turn. An idle or finished
  # agent is not disturbed by the tree going away: its next turn, if any, fails loudly
  # rather than editing files nobody will look at.
  defp resting(path) do
    %{}
    |> Troupe.list_live_sessions()
    |> Enum.filter(&(&1.workspace == path and &1.state == :active))
    |> Enum.find(&working?(&1.id))
    |> case do
      nil -> :ok
      session -> {:error, {:busy, session.id}}
    end
  end

  defp working?(session_id) do
    case Troupe.snapshot(session_id) do
      %{state: state} -> state not in [:idle, :done]
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp branch_of(path) do
    case git(path, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, output, 0} -> {:ok, String.trim(output)}
      {:ok, output, _} -> {:error, {:git, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Work the agent left uncommitted goes into one commit on the branch first; a merge of
  # a branch whose changes are only in its working tree would merge nothing.
  defp commit_pending(path, message) do
    if dirty?(path) do
      with {:ok, _, 0} <- git(path, ["add", "-A"]),
           {:ok, _, 0} <- git(path, author() ++ ["commit", "-q", "-m", message]) do
        {:ok, true}
      else
        {:ok, output, _} -> {:error, {:git, String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  # So a merge works on a machine where nobody has told git who they are; the merge
  # commit is the harness's, and says so.
  defp author, do: ["-c", "user.name=troupe", "-c", "user.email=troupe@localhost"]

  defp merge_branch(workspace, branch) do
    args = author() ++ ["merge", "--no-ff", "--no-edit", "-m", "Merge #{branch}", branch]

    case git(workspace, args) do
      {:ok, output, 0} ->
        {:ok, String.trim(output)}

      {:ok, output, _status} ->
        # Leave the checkout as it was: a half-applied merge is worse than a refused one.
        _ = git(workspace, ["merge", "--abort"])
        {:error, {:conflicts, String.trim(output)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_tree(path) do
    case git(path, ["worktree", "remove", "--force", path]) do
      {:ok, _, 0} -> :ok
      {:ok, output, _} -> {:error, {:git, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_branch(workspace, branch, flag) do
    case git(workspace, ["branch", flag, branch]) do
      {:ok, _, 0} -> :ok
      {:ok, output, _} -> {:error, {:git, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Whether a checkout has uncommitted changes or untracked files."
  @spec dirty?(Path.t()) :: boolean()
  def dirty?(path) do
    case git(path, ["status", "--porcelain"]) do
      {:ok, output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp annotate(%{"worktree" => path} = entry) do
    session =
      %{}
      |> Troupe.list_live_sessions()
      |> Enum.find(&(&1.workspace == path))

    %{
      "path" => path,
      "branch" => entry |> Map.get("branch", "") |> String.replace_prefix("refs/heads/", ""),
      "session_id" => session && session.id,
      "dirty" => dirty?(path)
    }
  end

  defp parse_porcelain(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_block/1)
    |> Enum.filter(&Map.has_key?(&1, "worktree"))
  end

  defp parse_block(block) do
    block |> String.split("\n", trim: true) |> Map.new(&parse_field/1)
  end

  defp parse_field(line) do
    case String.split(line, " ", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, true}
    end
  end

  defp git_repository?(path) do
    match?({:ok, _, 0}, git(path, ["rev-parse", "--git-dir"]))
  end

  # Through reaper like every other OS process, so a hung git cannot outlive the
  # command that started it.
  defp git(cwd, args) do
    if File.dir?(cwd) do
      Reaper.run(cwd, ["git" | args], timeout_ms: 30_000)
    else
      {:error, :not_found}
    end
  end

  defp slug do
    4 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end
end
