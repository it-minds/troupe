defmodule Troupe.Git do
  @moduledoc """
  Every `git` Troupe runs for itself in a workspace (Decision 833): the `git_read` tool,
  the project brief's repository, HEAD and file count (`Troupe.Session.Memory`), the files
  a worktree's checkout commits (`Troupe.Worktree`), and the gateway's worktrees.

  These run outside the sandbox, as the daemon or the worker, and git honours settings in
  the repository's own `.git`, some of which run a command: an fsmonitor hook, a hook, a
  filter, a diff or merge driver. A session's agent can write that directory, from its
  shell if not from the file tools, so each call here runs

  - with those settings neutralised: `core.fsmonitor` off, `core.hooksPath` a directory
    that cannot exist, the repository's own filters given no command and its own merge
    drivers `false`, `--no-textconv` and `--no-ext-diff` where a command diffs,
    `--no-pager`, no editor, no signing or signature check, no automatic gc, no
    submodule recursion, and no transport, so nothing that fetches (a partial clone's
    missing object) can start `core.sshCommand`, a credential helper or a remote's
    `uploadpack`;
  - with no `GIT_*` variable of the daemon's own, and its settings passed as `git -c`
    passes them on (`GIT_CONFIG_PARAMETERS`), each name quoted, so a repository's filter
    named with a `=` or a quote in it is still the one turned off;
  - only in a repository whose git directory and common directory are the checkout's
    own `.git` (or, for a worktree its checkout names back, the checkout's), pinned with
    `GIT_DIR`, `GIT_COMMON_DIR` and `GIT_WORK_TREE` so that what runs is what was checked,
    and whose objects stay in the checkout: no alternates entry and no link in
    `.git/objects` that leads out of it (Decision 858).
  """

  alias Troupe.Config.Trust
  alias Troupe.{Paths, Reaper, Workspace}

  @typedoc """
  Why git did not run: the reaper's reasons, a repository that is somewhere else than the
  checkout the workspace is in or whose objects lead out of it, or a git too old to say
  where it is.
  """
  @type error ::
          Reaper.error()
          | {:elsewhere, :work_tree | :common_dir | :git_dir | :objects, Path.t()}
          | :unlocated

  # Settings of the command line's scope, so above every file's: what runs a command, or
  # leaves something running, turned off.
  @settings [
    {"core.fsmonitor", "false"},
    {"commit.gpgSign", "false"},
    {"log.showSignature", "false"},
    {"merge.verifySignatures", "false"},
    {"submodule.recurse", "false"},
    {"gc.auto", "0"},
    {"maintenance.auto", "false"},
    {"safe.bareRepository", "explicit"}
  ]

  @env [
    # No transport at all: nothing here fetches, and a partial clone's missing object
    # would otherwise be fetched through whatever the repository's remote names.
    {"GIT_ALLOW_PROTOCOL", "none"},
    {"GIT_NO_LAZY_FETCH", "1"},
    {"GIT_TERMINAL_PROMPT", "0"},
    # `status` does not write the index back, so a read stays a read.
    {"GIT_OPTIONAL_LOCKS", "0"},
    # git's own word for no editor: nothing is started.
    {"GIT_EDITOR", ":"}
  ]

  @locate [
    "rev-parse",
    "--path-format=absolute",
    "--is-inside-work-tree",
    "--show-toplevel",
    "--git-dir",
    "--git-common-dir"
  ]

  # Commands that read only refs and objects, never a file of the working tree: no filter
  # or merge driver applies to them, so the repository's config need not be read first.
  @objects_only ~w(rev-parse ls-tree log show branch)

  @doc """
  Run `git args` in `dir`, as `Troupe.Reaper.run/3` would, neutralised and confined as
  above. Leading `-c name=value` pairs in `args` stay git's own options. A directory that
  is not in a repository answers as git does, with its exit status.

  `index:` names a file in the repository's own git directory to use as the index instead
  of `index` (`GIT_INDEX_FILE`): a name, not a path, so it is always beside the index git
  would use and nowhere else.
  """
  @spec run(Path.t(), [String.t()], keyword()) ::
          {:ok, String.t(), integer() | :timeout} | {:error, error() | :bad_index}
  def run(dir, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 30_000)
    {globals, command} = split_globals(args)

    with :ok <- index_name(opts[:index]),
         {:ok, repo} <- locate(dir, timeout),
         {:ok, drivers} <- drivers(dir, repo, command, timeout) do
      git(dir, globals ++ with_flags(command), drivers, with_index(repo, opts[:index]), timeout)
    end
  end

  defp index_name(nil), do: :ok

  defp index_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z/, name) and name != "index",
      do: :ok,
      else: {:error, :bad_index}
  end

  defp index_name(_name), do: {:error, :bad_index}

  defp with_index(repo, nil), do: repo
  defp with_index(repo, name), do: Map.put(repo, :index, Path.join(repo.git_dir, name))

  @doc "Why git did not run, as a clause for a tool's answer: no capital, no full stop."
  @spec explain(term()) :: String.t()
  def explain({:elsewhere, :work_tree, path}),
    do: "git's working tree for this workspace is #{Paths.display(path)}, which does not hold it"

  def explain({:elsewhere, :common_dir, path}) do
    "this workspace's .git names #{Paths.display(path)} as its repository, which is not the " <>
      ".git of the checkout the workspace is in, and Troupe reads no other"
  end

  def explain({:elsewhere, :git_dir, path}) do
    "this workspace's git directory is #{Paths.display(path)}, which is neither the .git of " <>
      "the checkout the workspace is in nor a worktree's that the checkout names back"
  end

  def explain({:elsewhere, :objects, path}) do
    "this repository's objects lead to #{Paths.display(path)}, which is outside the checkout " <>
      "the workspace is in (an objects/info/alternates entry or a link in .git/objects), and " <>
      "Troupe reads no other repository"
  end

  def explain(:unlocated),
    do: "git did not say where this workspace's repository is (git 2.31 or later is needed)"

  def explain(:bad_index), do: "an index is a file name in the repository's git directory"

  def explain(reason), do: Reaper.explain(reason)

  @doc """
  Whether the repository around `dir` ignores it: a folder its `.gitignore`, its
  `info/exclude` or the person's excludes file hides, or one inside such a folder. Such a
  folder is a workspace of its own, as one outside any repository is, and not part of the
  repository: neither its worktrees nor its brief are the repository's. A folder the
  repository tracks, or would add, is not ignored, and nor is the top of a checkout or a
  worktree, a directory in no repository, or one git could not answer for.
  """
  @spec ignored?(Path.t()) :: boolean()
  def ignored?(dir) do
    match?({:ok, _out, 0}, run(dir, ["check-ignore", "-q", "--", "."], timeout_ms: 10_000))
  end

  # -- where the repository is --------------------------------------------------------

  # git finds the repository the way it always does; what it found is then held to the
  # checkout the workspace is in. A git failure here (not a repository) is the answer.
  defp locate(dir, timeout) do
    case git(dir, @locate, [], nil, timeout) do
      {:ok, out, 0} ->
        case String.split(out, ~r/\r?\n/, trim: true) do
          ["true", top, git_dir, common] -> confine(real(top), real(git_dir), real(common))
          ["false", top | _] -> {:error, {:elsewhere, :work_tree, top}}
          _other -> {:error, :unlocated}
        end

      other ->
        other
    end
  end

  # The checkout is git's top level, or the main checkout a worktree's `.git` names and
  # that names the worktree back (`Troupe.Config.Trust.root/1`). Its `.git` must be the
  # common directory, and the git directory that `.git` itself or, for a worktree, one of
  # the checkout's `.git/worktrees/`: so a `.git` file, a `commondir` or a link in it that
  # points at another checkout is not followed there.
  defp confine(top, git_dir, common) do
    checkout = Trust.root(top)
    worktree? = key(checkout) != key(top)

    cond do
      key(common) != key(Path.join(checkout, ".git")) ->
        {:error, {:elsewhere, :common_dir, common}}

      not own_git_dir?(git_dir, top, checkout, worktree?) ->
        {:error, {:elsewhere, :git_dir, git_dir}}

      out = objects_out(Path.join(common, "objects"), real(checkout)) ->
        {:error, {:elsewhere, :objects, out}}

      true ->
        {:ok, %{top: top, git_dir: git_dir, common: common}}
    end
  end

  defp own_git_dir?(git_dir, top, _checkout, false),
    do: key(git_dir) == key(Path.join(top, ".git"))

  defp own_git_dir?(git_dir, _top, checkout, true),
    do: key(Path.dirname(git_dir)) == key(Path.join([checkout, ".git", "worktrees"]))

  # -- where its objects are ----------------------------------------------------------

  # git reads an object wherever the object directory leads, and no setting turns that
  # off: an `info/alternates` entry (and, in turn, that directory's own), or a link in
  # it - the directory itself, a fan-out directory, a pack, anything in `info`. Each must
  # really be in the checkout, or another repository on the machine reads as this one's
  # (#538). The first place that is not, or nil. A loose object's own file is not looked
  # at: there may be thousands, and a link to one shows only an object whose name the
  # link's maker already knew.
  defp objects_out(objects, checkout), do: objects_out([objects], checkout, MapSet.new())

  defp objects_out([], _checkout, _seen), do: nil

  defp objects_out([dir | rest], checkout, seen) do
    real = real(dir)

    cond do
      not inside?(real, checkout) -> real
      MapSet.member?(seen, key(real)) -> objects_out(rest, checkout, seen)
      out = linked_out(real, checkout) -> out
      true -> objects_out(alternates(real) ++ rest, checkout, MapSet.put(seen, key(real)))
    end
  end

  defp linked_out(objects, checkout) do
    ["", "pack", "info", "info/commit-graphs"]
    |> Enum.flat_map(fn sub ->
      dir = Path.join(objects, sub)
      dir |> ls() |> Enum.map(&Path.join(dir, &1))
    end)
    |> Enum.find_value(&link_out(&1, checkout))
  end

  defp link_out(path, checkout) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, _target} ->
        real = real(path)
        if inside?(real, checkout), do: nil, else: real

      {:error, _} ->
        nil
    end
  end

  # As git reads the file: one directory a line, relative to the object directory, a
  # line starting with `#` a comment, and one starting with `"` quoted as git quotes.
  defp alternates(objects) do
    case File.read(Path.join(objects, "info/alternates")) do
      {:ok, text} ->
        for line <- String.split(text, ~r/\r?\n/),
            line != "" and not String.starts_with?(line, "#"),
            do: Path.expand(unquote_c(line), objects)

      {:error, _} ->
        []
    end
  end

  # git's `unquote_c_style`: what follows the closing quote is ignored, and a line it
  # cannot unquote is taken as it stands.
  defp unquote_c(line) do
    case Regex.run(~r/\A"((?:[^"\\]|\\(?:[0-7]{3}|[abfnrtv\\"]))*)"/, line) do
      [_, quoted] ->
        Regex.replace(~r/\\([0-7]{3}|.)/, quoted, fn _, escaped -> unescape(escaped) end)

      nil ->
        line
    end
  end

  defp unescape(<<octal::binary-size(3)>>), do: <<String.to_integer(octal, 8)>>

  defp unescape(char) do
    case char do
      "a" -> "\a"
      "b" -> "\b"
      "f" -> "\f"
      "n" -> "\n"
      "r" -> "\r"
      "t" -> "\t"
      "v" -> "\v"
      other -> other
    end
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp inside?(path, root),
    do:
      key(path) == key(root) or
        String.starts_with?(key(path), String.trim_trailing(key(root), "/") <> "/")

  defp real(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> real
      {:error, _} -> path
    end
  end

  defp key(path), do: Workspace.compare_key(path)

  # -- what the repository's own config would run -------------------------------------

  # The repository's own filters and merge drivers, by name: given no command, and
  # `false` (a conflict, for the person to resolve), from the command line's scope. Those
  # of the person's own config, and the machine's, are theirs and run as they would.
  defp drivers(_dir, _repo, [command | _], _timeout) when command in @objects_only, do: {:ok, []}

  defp drivers(dir, repo, _command, timeout) do
    case git(dir, ["config", "--list", "--show-scope", "--name-only"], [], repo, timeout) do
      {:ok, out, 0} ->
        {:ok,
         out |> String.split(~r/\r?\n/, trim: true) |> Enum.flat_map(&driver/1) |> Enum.uniq()}

      other ->
        other
    end
  end

  defp driver(line) do
    with [scope, name] when scope in ["local", "worktree"] <- String.split(line, "\t", parts: 2),
         [section | rest] when length(rest) >= 2 <- String.split(name, ".") do
      neutralise(section, rest |> Enum.drop(-1) |> Enum.join("."), List.last(rest))
    else
      _ -> []
    end
  end

  defp neutralise("filter", name, key) when key in ["clean", "smudge", "process"],
    do: [{"filter.#{name}.#{key}", ""}, {"filter.#{name}.required", "false"}]

  defp neutralise("merge", name, "driver"), do: [{"merge.#{name}.driver", "false"}]
  defp neutralise(_section, _name, _key), do: []

  # -- the call -------------------------------------------------------------------------

  defp split_globals(["-c", setting | rest]) do
    {globals, command} = split_globals(rest)
    {["-c", setting | globals], command}
  end

  defp split_globals(args), do: {[], args}

  # A diff shows the bytes, not what a driver makes of them; and a submodule is its
  # commit, since looking inside one runs git there under the submodule's own config.
  defp with_flags(["diff" | rest]),
    do: ["diff", "--no-textconv", "--no-ext-diff", "--ignore-submodules=dirty" | rest]

  defp with_flags([command | rest]) when command in ["show", "log"],
    do: [command, "--no-textconv", "--no-ext-diff" | rest]

  defp with_flags(["status" | rest]), do: ["status", "--ignore-submodules=dirty" | rest]
  defp with_flags(command), do: command

  defp git(dir, args, drivers, repo, timeout) do
    Reaper.run(dir, ["git", "--no-pager" | args], timeout_ms: timeout, env: env(drivers, repo))
  end

  # The settings go as `git -c` passes its own to the commands it starts, each name and
  # value quoted on its own: a filter's name may have a `=` or a quote in it, and a value
  # may be empty, which a variable of its own (`GIT_CONFIG_VALUE_<n>`) cannot be here.
  defp env(drivers, repo) do
    config = [{"core.hooksPath", no_hooks()} | @settings] ++ drivers
    parameters = Enum.map_join(config, " ", fn {name, value} -> sq(name) <> "=" <> sq(value) end)

    set = [{"GIT_CONFIG_PARAMETERS", parameters} | @env] ++ pinned(repo)
    names = MapSet.new(set, fn {name, _} -> String.upcase(name) end)

    # Every other `GIT_*` the daemon was started with is taken away: a `GIT_DIR`, a
    # `GIT_CONFIG_PARAMETERS` or a `GIT_EXTERNAL_DIFF` is not the workspace's to inherit.
    unset =
      for {name, _} <- System.get_env(),
          String.starts_with?(String.upcase(name), "GIT_"),
          not MapSet.member?(names, String.upcase(name)),
          do: {name, nil}

    unset ++ set
  end

  # git's own shell quoting (`sq_quote_buf`): in single quotes, with `'` and `!` stepped
  # out of them.
  defp sq(text) do
    "'" <> (text |> String.replace("'", "'\\''") |> String.replace("!", "'\\!'")) <> "'"
  end

  defp pinned(nil), do: []

  defp pinned(%{index: index} = repo),
    do: [{"GIT_INDEX_FILE", index} | pinned(Map.delete(repo, :index))]

  defp pinned(%{top: top, git_dir: git_dir, common: common}),
    do: [{"GIT_DIR", git_dir}, {"GIT_COMMON_DIR", common}, {"GIT_WORK_TREE", top}]

  # A directory that cannot exist, so no hook is found in it: a path inside the reaper
  # helper, which is a file. `/dev/null` is the usual one, but on Windows that is
  # `\dev\null` on the current drive, where anyone may make a directory of that name.
  defp no_hooks do
    case Reaper.path() do
      {:ok, reaper} -> Path.join(reaper, "hooks")
      {:error, _} -> "/dev/null"
    end
  end
end
