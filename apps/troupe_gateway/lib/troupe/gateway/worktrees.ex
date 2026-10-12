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

  A workspace inside another repository follows git. A folder the repository tracks, or
  would add, belongs to it: its worktrees are the repository's, made beside the checkout
  with the session in the same folder of the new tree. A folder the repository ignores is
  a workspace of its own, as one in no repository is: it lists no worktree, and none is
  made of the repository around it.
  """

  alias Troupe.Config.Trust
  alias Troupe.{Git, Workspace}

  @type resolved :: %{path: Path.t(), worktree: Path.t() | nil, branch: String.t() | nil}

  # How long `list/2` reads the trees' status for, and how many it reads at once.
  @status_ms 2_000
  @status_at_once 8

  @doc """
  Decide where a new session should work.

  `mode` is `"auto"` (branch only when the workspace is busy), `"never"`, or
  `"always"`. A `name` is a worktree of that name (`named/2`), whatever the mode. A
  workspace in no repository, or in a folder its repository ignores, works where it is.
  """
  @spec resolve(Path.t(), String.t(), String.t() | nil) :: {:ok, resolved()} | {:error, term()}
  def resolve(workspace, mode, name \\ nil) do
    workspace = Path.expand(workspace)

    cond do
      is_binary(name) ->
        named(workspace, name)

      mode == "never" ->
        {:ok, plain(workspace)}

      mode != "always" and not busy?(workspace) ->
        {:ok, plain(workspace)}

      true ->
        case repository(workspace) do
          {:ok, top} -> create(workspace, top)
          _none -> {:ok, plain(workspace)}
        end
    end
  end

  @doc """
  Whether a session started in `workspace` now would get a worktree of its own, as
  `resolve/2` decides it for `"auto"`: what `agents.list` says of each agent (Decision 841).
  """
  @spec auto?(Path.t()) :: boolean()
  def auto?(workspace) do
    workspace = Path.expand(workspace)
    busy?(workspace) and match?({:ok, _top}, repository(workspace))
  end

  defp plain(workspace), do: %{path: workspace, worktree: nil, branch: nil}

  # A live session's agent at work in this very directory: a second one there would edit
  # the same files.
  defp busy?(workspace) do
    key = same_key(workspace)
    Enum.any?(live_sessions(), &(&1.state == :active and same_key(&1.workspace) == key))
  end

  defp live_sessions, do: Troupe.list_live_sessions(%{})

  # The top of the checkout or worktree a workspace belongs to, as git names it: the
  # workspace itself or a directory above it. A folder git ignores is `:ignored`, a
  # workspace of its own, and one in no repository `:none`.
  defp repository(workspace) do
    args = ["rev-parse", "--path-format=absolute", "--show-toplevel"]

    with {:ok, output, 0} <- git(workspace, args),
         [top | _] <- String.split(output, ~r/\r?\n/, trim: true) do
      if same_key(top) != same_key(workspace) and Git.ignored?(workspace),
        do: :ignored,
        else: {:ok, top}
    else
      _ -> :none
    end
  end

  @doc """
  Create a worktree of the repository a workspace belongs to, on a fresh `troupe/<slug>`
  branch: beside the checkout, with the session in the same folder of it as the workspace
  is of the checkout. `{:no_repository, :ignored | :none}` for a workspace that belongs to
  none.
  """
  @spec create(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def create(workspace) do
    workspace = Path.expand(workspace)

    case repository(workspace) do
      {:ok, top} -> create(workspace, top)
      why -> {:error, {:no_repository, why}}
    end
  end

  defp create(workspace, top) do
    slug = slug()
    branch = "troupe/" <> slug
    tree = beside(workspace, top, slug)

    case git(workspace, ["worktree", "add", "-b", branch, tree]) do
      {:ok, _output, 0} -> {:ok, placed(workspace, top, tree, branch)}
      {:ok, output, _status} -> {:error, {:worktree_failed, String.trim(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `<checkout>-<name>` beside the checkout or worktree the workspace belongs to, never in
  # it: spelled as the workspace spells it when the workspace is that top, as git does
  # when it is a folder below.
  defp beside(workspace, top, name) do
    checkout = if same_key(workspace) == same_key(top), do: workspace, else: top
    Path.join(Path.dirname(checkout), Path.basename(checkout) <> "-" <> name)
  end

  # Where a session in a new tree works: the folder of it the workspace is of its own
  # checkout. One nothing in it is committed yet is not in the tree, and is made there.
  defp placed(workspace, top, tree, branch) do
    path =
      case below(workspace, top) do
        [] ->
          tree

        folders ->
          path = Path.join([tree | folders])
          _ = File.mkdir_p(path)
          path
      end

    %{path: path, worktree: tree, branch: branch}
  end

  # The folders from `top` down to `path`, both as they really are; none when it is `top`.
  defp below(path, top) do
    here = path |> real() |> Path.split()
    above = top |> real() |> Path.split()
    {head, rest} = Enum.split(here, length(above))

    if Enum.map(head, &Workspace.compare_key/1) == Enum.map(above, &Workspace.compare_key/1),
      do: rest,
      else: []
  end

  @doc """
  The worktree of that name (TUI Decision 42, Decision 843): `<checkout>-<name>` on
  `troupe/<name>`, made the first time and the same tree after, and made again from its
  branch when only the directory has gone. Refused while a session is working in it, as a
  merge is, since two agents would be writing one tree; refused for a name git would not
  take as a branch or that would leave the directory beside the checkout; and refused
  for a workspace that belongs to no repository, `{:no_repository, :ignored | :none}`.
  """
  @spec named(Path.t(), String.t()) ::
          {:ok, resolved()} | {:error, {:bad_name, String.t()} | {:busy, String.t()} | term()}
  def named(workspace, name) do
    workspace = Path.expand(workspace)

    if name?(name) do
      case repository(workspace) do
        {:ok, top} -> named(workspace, top, name)
        why -> {:error, {:no_repository, why}}
      end
    else
      {:error, {:bad_name, name}}
    end
  end

  defp named(workspace, top, name) do
    branch = "troupe/" <> name
    tree = beside(workspace, top, name)

    if registered?(workspace, tree) and File.dir?(tree) do
      with :ok <- resting(tree), do: {:ok, placed(workspace, top, tree, branch)}
    else
      # A tree whose directory went is still registered until git is told; its branch,
      # and the work committed on it, is what it is made again from.
      _ = git(workspace, ["worktree", "prune"])
      from = if branch?(workspace, branch), do: [tree, branch], else: ["-b", branch, tree]

      case git(workspace, ["worktree", "add" | from]) do
        {:ok, _output, 0} -> {:ok, placed(workspace, top, tree, branch)}
        {:ok, output, _status} -> {:error, {:worktree_failed, String.trim(output)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A name is one path segment that is also a branch name git takes, and starts with
  # neither a dot nor a dash.
  defp name?(name) do
    String.match?(name, ~r/^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/) and
      not String.contains?(name, "..") and not String.ends_with?(name, [".", ".lock"])
  end

  defp registered?(workspace, path) do
    case git(workspace, ["worktree", "list", "--porcelain"]) do
      {:ok, output, 0} ->
        key = same_key(path)
        output |> parse_porcelain() |> Enum.any?(&(same_key(&1["worktree"]) == key))

      _ ->
        false
    end
  end

  defp branch?(workspace, branch) do
    ref = "refs/heads/" <> branch
    match?({:ok, _, 0}, git(workspace, ["rev-parse", "--verify", "--quiet", ref]))
  end

  # A directory however it is spelled: git writes `C:/…` where a session's workspace is
  # `c:/…` or `C:\…`, and a link to it is it too.
  defp same_key(path), do: path |> real() |> Workspace.compare_key()

  defp real(path) do
    path = Path.expand(path)

    case Workspace.real_path(path) do
      {:ok, real} -> real
      {:error, _} -> path
    end
  end

  @doc """
  Every worktree of a workspace's repository, the checkout first, with the session working
  in it, whether it is dirty, and how it stands against the checkout (Decision 840):
  `ahead` and `behind`, the commits its branch has that the checkout's branch has not and
  the other way round (for the checkout itself, against its upstream), and `added` and
  `removed`, the lines it would bring: its changes since its branch left the checkout's,
  uncommitted and untracked files included, as a merge would commit them (for the
  checkout, what it has not committed). Each is `nil` where git cannot say: a checkout
  with no upstream, a detached one. A workspace in a folder its repository ignores, or in
  none, has no worktrees.

  The listing answers in bounded time however many trees there are. `status: false`
  leaves the status out: each row is its `path`, `branch` and `session_id`, from git's
  list of the trees alone. Otherwise each tree's status is read while the listing's time
  lasts (two seconds, `:worktree_status_ms` in the application's environment), several at
  once, the checkout first, then the trees a session works in, then the rest as git lists
  them. A row says whether it was (`checked`); one the time did not reach has `dirty` and
  every count `nil`, not a clean tree's answers. Each git a tree's reading runs is given
  only what is left of that time, so a slow tree holds the answer back by a few seconds at
  most, however many trees there are.
  """
  @spec list(Path.t() | nil, keyword()) :: [map()]
  def list(workspace, opts \\ [])

  def list(nil, opts) do
    sessions = live_sessions()

    opts =
      opts |> Keyword.put(:sessions, sessions) |> Keyword.put_new_lazy(:deadline, &deadline/0)

    sessions
    |> Enum.map(& &1.workspace)
    |> Enum.uniq()
    |> Enum.flat_map(&list(&1, opts))
  end

  def list(workspace, opts) do
    workspace = Path.expand(workspace)

    with {:ok, output, 0} <- git(workspace, ["worktree", "list", "--porcelain"]),
         # git lists the main worktree first: its branch is the one the others left.
         entries = parse_porcelain(output),
         keys = Enum.map(entries, &same_key(&1["worktree"])),
         false <- folder_ignored?(workspace, keys) do
      held = sessions_by_tree(keys, Keyword.get_lazy(opts, :sessions, &live_sessions/0))
      rows = Enum.zip_with(entries, keys, &row(&1, &2, held))

      if Keyword.get(opts, :status, true),
        do: with_status(rows, entries, Keyword.get_lazy(opts, :deadline, &deadline/0)),
        else: rows
    else
      _ -> []
    end
  end

  # A workspace that is one of the trees is the repository's; one in a folder below them
  # is unless git ignores that folder.
  defp folder_ignored?(workspace, keys),
    do: same_key(workspace) not in keys and Git.ignored?(workspace)

  defp row(%{"worktree" => path} = entry, key, held) do
    session = Map.get(held, key)
    %{"path" => path, "branch" => branch_name(entry), "session_id" => session && session.id}
  end

  defp branch_name(entry),
    do: entry |> Map.get("branch", "") |> String.replace_prefix("refs/heads/", "")

  # The live session working in each tree, by the tree's key: one in the tree's own
  # directory, or else one in a folder of it git does not ignore. Such a folder belongs to
  # the nearest tree holding it, not to a checkout further up that holds that tree's
  # directory too.
  defp sessions_by_tree(keys, sessions) do
    {at, below} =
      sessions
      |> Enum.map(&{same_key(&1.workspace), &1})
      |> Enum.split_with(fn {key, _session} -> key in keys end)

    held = Enum.reduce(at, %{}, fn {key, session}, acc -> Map.put_new(acc, key, session) end)
    Enum.reduce(below, held, fn {key, session}, acc -> hold(acc, nearest(key, keys), session) end)
  end

  defp hold(held, nil, _session), do: held

  defp hold(held, tree, session) do
    if Map.has_key?(held, tree) or Git.ignored?(session.workspace),
      do: held,
      else: Map.put(held, tree, session)
  end

  defp nearest(key, keys) do
    keys
    |> Enum.filter(&inside?(key, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp inside?(key, root), do: String.starts_with?(key, String.trim_trailing(root, "/") <> "/")
  defp within?(key, root), do: key == root or inside?(key, root)

  defp deadline do
    budget = Application.get_env(:troupe_gateway, :worktree_status_ms, @status_ms)
    System.monotonic_time(:millisecond) + budget
  end

  defp left(deadline), do: deadline - System.monotonic_time(:millisecond)

  # Each tree's status, read in the order it is wanted in and put back in git's.
  defp with_status(rows, entries, deadline) do
    main = List.first(entries)

    read =
      rows
      |> Enum.zip(entries)
      |> Enum.sort_by(fn {row, entry} -> wanted(row, entry, main) end)
      |> Task.async_stream(
        fn {row, entry} -> {row["path"], status_of(entry, main, deadline)} end,
        max_concurrency: @status_at_once,
        ordered: false,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, read} -> read end)

    Enum.map(rows, &Map.merge(&1, Map.fetch!(read, &1["path"])))
  end

  # The checkout first, then the trees a session works in, then the rest.
  defp wanted(_row, main, main), do: 0
  defp wanted(%{"session_id" => id}, _entry, _main) when is_binary(id), do: 1
  defp wanted(_row, _entry, _main), do: 2

  @unchecked %{
    "checked" => false,
    "dirty" => nil,
    "ahead" => nil,
    "behind" => nil,
    "added" => nil,
    "removed" => nil
  }

  defp status_of(%{"worktree" => path} = entry, main, deadline) do
    main? = entry == main
    branch = branch_name(entry)

    case status(path, against(main?, branch, main["branch"]), deadline) do
      :unchecked ->
        @unchecked

      status ->
        %{"checked" => true, "dirty" => status.entries != []}
        |> Map.merge(standing(path, main?, main["branch"], status, deadline))
    end
  end

  @doc """
  Remove a worktree. Refuses a dirty one unless `force`. git runs from the checkout the
  tree belongs to, as `merge/3` and `discard/2` remove it: on Windows git cannot delete
  the directory it was started in. git's refusal is `{:git, output}`, as theirs is.
  """
  @spec remove(Path.t(), boolean()) ::
          :ok | {:error, :dirty | :not_found | {:git, String.t()} | term()}
  def remove(path, force?) do
    path = Path.expand(path)

    cond do
      not File.dir?(path) ->
        {:error, :not_found}

      not force? and dirty?(path) ->
        {:error, :dirty}

      true ->
        args = ["worktree", "remove"] ++ if(force?, do: ["--force"], else: []) ++ [path]

        # The checkout a worktree's `.git` names and that names it back; a directory that
        # is no linked worktree is its own, and git says what it makes of it.
        case git(Trust.root(path), args) do
          {:ok, _output, 0} -> :ok
          {:ok, output, _} -> {:error, {:git, String.trim(output)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Land a worktree's branch on the checkout it came from, then remove it.

  `opts[:message]` is the commit message for work left uncommitted in the worktree;
  the default names the branch. Returns the branch, whether anything had to be
  committed first, and git's own account of the merge.

  Once the merge has landed it is a merge, whatever follows: a tree git then cannot
  remove is said beside it (`"removed" => false`, `"removal_error"`), with the tree and
  its branch left, rather than answered as an error that reads as though nothing
  happened. A merge git refuses to start because the checkout's own uncommitted changes
  are in its way is `{:local_changes, output}`, not a conflict: nothing conflicted
  (Decision 843).
  """
  @spec merge(Path.t(), Path.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             {:conflicts, String.t()}
             | {:local_changes, String.t()}
             | {:busy, String.t()}
             | term()}
  def merge(workspace, path, opts \\ []) do
    workspace = Path.expand(workspace)
    path = Path.expand(path)

    with :ok <- worktree_at(path),
         :ok <- resting(path),
         {:ok, branch} <- branch_of(path),
         {:ok, committed?} <- commit_pending(path, Keyword.get(opts, :message) || "troupe: #{branch}"),
         {:ok, output} <- merge_branch(workspace, branch) do
      merged = %{"branch" => branch, "committed" => committed?, "output" => output}

      with :ok <- remove_tree(workspace, path),
           :ok <- delete_branch(workspace, branch, "-d") do
        {:ok, Map.put(merged, "removed", true)}
      else
        {:error, reason} ->
          {:ok, Map.merge(merged, %{"removed" => false, "removal_error" => describe(reason)})}
      end
    end
  end

  defp describe({:git, output}), do: output
  defp describe(reason), do: Git.explain(reason)

  @doc "Throw a worktree away: the tree, its branch, and any work not yet merged."
  @spec discard(Path.t(), Path.t()) :: {:ok, map()} | {:error, {:busy, String.t()} | term()}
  def discard(workspace, path) do
    workspace = Path.expand(workspace)
    path = Path.expand(path)

    with :ok <- worktree_at(path),
         :ok <- resting(path),
         {:ok, branch} <- branch_of(path),
         :ok <- remove_tree(workspace, path),
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

  # The session working in this tree, in its directory or a folder of it, if its agent is
  # mid-turn. An idle or finished agent is not disturbed by the tree going away: its next
  # turn, if any, fails loudly rather than editing files nobody will look at.
  defp resting(path) do
    key = same_key(path)

    live_sessions()
    |> Enum.filter(&(&1.state == :active and within?(same_key(&1.workspace), key)))
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
        refused(workspace, String.trim(output))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A merge git started and stopped has a MERGE_HEAD, and is aborted: the checkout is left
  # as it was, since a half-applied merge is worse than a refused one. One git would not
  # start has none and nothing to abort; in a checkout with uncommitted changes, they are
  # what was in its way (git names the files), and the person keeps them.
  defp refused(workspace, output) do
    started? = match?({:ok, _, 0}, git(workspace, ["rev-parse", "-q", "--verify", "MERGE_HEAD"]))

    cond do
      started? ->
        _ = git(workspace, ["merge", "--abort"])
        {:error, {:conflicts, output}}

      dirty?(workspace) ->
        {:error, {:local_changes, output}}

      true ->
        {:error, {:git, output}}
    end
  end

  # Run from the checkout, not the tree: on Windows git cannot delete the directory it was
  # started in, and the merge or discard stopped half done, the tree unregistered but left.
  defp remove_tree(workspace, path) do
    case git(workspace, ["worktree", "remove", "--force", path]) do
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

  # One `git status` a tree (D113): its entries, each untracked file named (not its
  # directory), say whether it is dirty and which files a merge would add, and `--branch`
  # says how far its branch is from its upstream. For a linked tree's branch the upstream is,
  # for this one call, the checkout's branch (`branch.<name>.remote` `.`), so the same line
  # says how far it is from that. Nothing where git could not say, and `:unchecked` when the
  # listing's time ran out first.
  defp status(path, settings, deadline) do
    args =
      settings ++
        ["status", "--porcelain=v2", "--branch", "--ahead-behind", "--untracked-files=all"]

    case git_by(path, args, deadline) do
      {:ok, output, 0} ->
        {headers, entries} =
          output
          |> String.split(~r/\r?\n/, trim: true)
          |> Enum.split_with(&String.starts_with?(&1, "# "))

        %{entries: entries, upstream: header(headers, "upstream"), ab: ab(header(headers, "ab"))}

      {:ok, _output, :timeout} ->
        :unchecked

      {:error, :late} ->
        :unchecked

      _ ->
        %{entries: [], upstream: nil, ab: nil}
    end
  end

  # The checkout's branch as the linked tree's upstream. A name git's `-c` would split
  # wrongly (one with a `=`) is not offered; its tree is counted the other way.
  defp against(false, branch, "refs/heads/" <> _ = base) when branch != "" do
    if String.contains?(branch, "="),
      do: [],
      else: ["-c", "branch.#{branch}.remote=.", "-c", "branch.#{branch}.merge=#{base}"]
  end

  defp against(_main?, _branch, _base), do: []

  defp header(headers, name) do
    Enum.find_value(headers, fn line ->
      case String.split(line, " ", parts: 3) do
        ["#", "branch." <> ^name, value] -> value
        _ -> nil
      end
    end)
  end

  # `+ahead -behind`, or nil.
  defp ab("+" <> counts) do
    with [ahead, "-" <> behind] <- String.split(counts, " "),
         {ahead, ""} <- Integer.parse(ahead),
         {behind, ""} <- Integer.parse(behind) do
      {ahead, behind}
    else
      _ -> nil
    end
  end

  defp ab(_value), do: nil

  # The checkout against its upstream, and what it has not committed.
  defp standing(path, true, _base, status, deadline) do
    {ahead, behind} = if status.upstream, do: status.ab || {nil, nil}, else: {nil, nil}
    {added, removed} = changed(path, ["HEAD"], status, deadline)
    %{"ahead" => ahead, "behind" => behind, "added" => added, "removed" => removed}
  end

  # A linked worktree against the checkout's branch: what its branch has that that one has
  # not and the other way round, and the lines since it left it. A tree whose status did not
  # take the checkout's branch for its upstream (a detached one, one whose branch has an
  # upstream of its own) is counted with `rev-list`.
  defp standing(path, false, "refs/heads/" <> short = base, status, deadline) do
    {ahead, behind} =
      case status do
        %{upstream: upstream, ab: {_, _} = ab} when upstream in [short, "heads/" <> short] ->
          ab

        _ ->
          {behind, ahead} = counts(path, base <> "...HEAD", deadline)
          {ahead, behind}
      end

    {added, removed} = changed(path, ["--merge-base", base], status, deadline)
    %{"ahead" => ahead, "behind" => behind, "added" => added, "removed" => removed}
  end

  defp standing(_path, false, _base, _status, _deadline),
    do: %{"ahead" => nil, "behind" => nil, "added" => nil, "removed" => nil}

  # `left...right` as `{only left, only right}`, or `{nil, nil}` where git cannot say.
  defp counts(path, range, deadline) do
    with {:ok, output, 0} <-
           git_by(path, ["rev-list", "--left-right", "--count", range], deadline),
         [left, right] <- String.split(output),
         {left, ""} <- Integer.parse(left),
         {right, ""} <- Integer.parse(right) do
      {left, right}
    else
      _ -> {nil, nil}
    end
  end

  # Lines added and removed since `from` (a commit, or `--merge-base` and the branch it
  # left), the working tree's included, and the lines of every untracked file, which a
  # merge commits too (`git add -A`, `commit_pending/2`).
  defp changed(path, from, status, deadline) do
    case git_by(path, ["diff", "--numstat" | from], deadline) do
      {:ok, output, 0} ->
        {added, removed} =
          output |> String.split(~r/\r?\n/, trim: true) |> Enum.reduce({0, 0}, &numstat/2)

        {added + untracked_lines(path, status), removed}

      _ ->
        {nil, nil}
    end
  end

  # One `--numstat` line, `added<TAB>removed<TAB>file`, added to the sums.
  defp numstat(line, {added, removed}) do
    case String.split(line, "\t", parts: 3) do
      [plus, minus, _file] -> {added + number(plus), removed + number(minus)}
      _ -> {added, removed}
    end
  end

  # A binary file is `-` in `--numstat`, and counts for no lines.
  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> 0
    end
  end

  @untracked_files 200
  @untracked_bytes 1_000_000

  # The lines of the untracked files `git status` named, each read only while it is a
  # small text file inside the tree: a count for a screen, not an inventory.
  defp untracked_lines(path, status) do
    root = Path.expand(path)

    # git quotes a name with unusual characters in it; such a file is left out of the
    # count rather than read by a name worked out here.
    status.entries
    |> Enum.flat_map(fn
      "? \"" <> _quoted -> []
      "? " <> file -> [file]
      _ -> []
    end)
    |> Enum.take(@untracked_files)
    |> Enum.reduce(0, fn file, acc ->
      full = Path.expand(file, root)

      with true <- String.starts_with?(full, root <> "/"),
           {:ok, %File.Stat{type: :regular, size: size}} when size <= @untracked_bytes <-
             File.lstat(full),
           {:ok, text} <- File.read(full),
           true <- String.valid?(text) do
        acc + lines_of(text)
      else
        _ -> acc
      end
    end)
  end

  defp lines_of(""), do: 0

  defp lines_of(text) do
    newlines = text |> :binary.matches("\n") |> length()
    if String.ends_with?(text, "\n"), do: newlines, else: newlines + 1
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

  # Through reaper like every other OS process, so a hung git cannot outlive the
  # command that started it; and neutralised, so no hook, filter or merge driver the
  # repository's own `.git` names runs, and confined to the checkout's own `.git`
  # (Decision 833).
  defp git(cwd, args, timeout_ms \\ 30_000) do
    if File.dir?(cwd) do
      Git.run(cwd, args, timeout_ms: timeout_ms)
    else
      {:error, :not_found}
    end
  end

  # A tree's git within what is left of the listing's time; none once it is spent.
  defp git_by(cwd, args, deadline) do
    case left(deadline) do
      ms when ms > 0 -> git(cwd, args, min(ms, 30_000))
      _spent -> {:error, :late}
    end
  end

  defp slug do
    4 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
  end
end
