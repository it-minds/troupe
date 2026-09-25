defmodule Troupe.Config.Trust do
  @moduledoc """
  Whether a workspace is trusted: whether its own `.troupe/config.yaml` and
  `config.local.yaml` may set the keys `Troupe.Config.Schema` marks `:trusted` — the
  ones that change approvals, where a request goes and with which key, what runs, and
  what may be read.

  A workspace is trusted when the user file's `trusted_workspaces` names it or a
  directory above it. A git worktree of a trusted checkout is trusted too, since that
  is where a branch session works: the worktree's `.git` file names the checkout's
  `.git/worktrees/<name>`, and that directory's `gitdir` names the worktree back, so a
  directory cannot borrow a checkout's trust by writing a `.git` file of its own.

  A session on a pod never asks: it reads no gated key from a project's file.

  `troupe config trust [PATH]`, `untrust [PATH]` and `trust --list` change and show the
  list, from `troupe` and `troupe-daemon` alike, each answering `{text, exit_status}`.
  They edit the user file line by line (`Troupe.Config.Yaml.edit_list/4`), so its
  comments and other keys stay as they were, and keep the file as it was beside it as
  `.previous`, as every writer does.
  """

  alias Troupe.Config.{Issue, Layers, Migrate, Yaml}
  alias Troupe.Workspace

  @key "trusted_workspaces"

  @doc "Whether `workspace` is one of `entries` or under one."
  @spec trusted?(Path.t(), [String.t()]) :: boolean()
  def trusted?(_workspace, []), do: false
  def trusted?(workspace, entries), do: covering(workspace, entries) != []

  @doc "The entries that trust `workspace`: it, a directory above it, or its checkout."
  @spec covering(Path.t(), [String.t()]) :: [String.t()]
  def covering(workspace, entries) do
    candidates = workspace |> candidates() |> Enum.map(&Workspace.compare_key/1)

    Enum.filter(entries, fn entry ->
      absolute?(entry) and Enum.any?(candidates, &under?(&1, key(entry)))
    end)
  end

  defp under?(candidate, root),
    do: candidate == root or String.starts_with?(candidate, String.trim_trailing(root, "/") <> "/")

  @doc "Whether a trust entry can mean anything: an absolute path, `~` allowed."
  @spec absolute?(String.t()) :: boolean()
  def absolute?(entry) when is_binary(entry) do
    entry == "~" or String.starts_with?(entry, "~/") or Path.type(entry) == :absolute
  end

  def absolute?(_entry), do: false

  @doc """
  The directory trusting `path` means: its real path, or for a git worktree the checkout
  it belongs to, which trusts the checkout and every worktree of it.
  """
  @spec root(Path.t()) :: Path.t()
  def root(path) do
    real = path |> Path.expand() |> real()
    main_checkout(real) || real
  end

  @doc """
  What to run to trust `workspace`, for a warning to name: `troupe config trust` and the
  path as a person on this platform types it.
  """
  @spec command(Path.t()) :: String.t()
  def command(workspace) do
    shown = Troupe.Paths.display(workspace)
    "troupe config trust " <> if(shown =~ ~r/\s/, do: ~s("#{shown}"), else: shown)
  end

  defp key(entry), do: entry |> Path.expand() |> real() |> Workspace.compare_key()

  defp candidates(workspace) do
    real = workspace |> Path.expand() |> real()
    [real | List.wrap(main_checkout(real))]
  end

  defp real(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> real
      {:error, _} -> path
    end
  end

  # `<worktree>/.git` is a file saying `gitdir: <checkout>/.git/worktrees/<name>`, and
  # that directory's `gitdir` file names `<worktree>/.git`. Both must agree.
  defp main_checkout(worktree) do
    dot_git = Path.join(worktree, ".git")

    with true <- File.regular?(dot_git),
         {:ok, "gitdir: " <> gitdir} <- File.read(dot_git),
         gitdir = gitdir |> String.trim() |> Path.expand(worktree),
         "worktrees" <- gitdir |> Path.dirname() |> Path.basename(),
         ".git" <- gitdir |> Path.dirname() |> Path.dirname() |> Path.basename(),
         {:ok, back} <- File.read(Path.join(gitdir, "gitdir")),
         true <- same?(back |> String.trim() |> Path.expand(gitdir), dot_git) do
      gitdir |> Path.dirname() |> Path.dirname() |> Path.dirname() |> real()
    else
      _ -> nil
    end
  end

  defp same?(a, b), do: Workspace.compare_key(real(a)) == Workspace.compare_key(real(b))

  # -- the commands ---------------------------------------------------------------

  @doc """
  `troupe config trust [PATH]`: add the workspace to the user file's
  `trusted_workspaces`, as `root/1` names it, unless an entry there trusts it already.

  Options: `:user_path` — the user file, when it is not `Troupe.Config.user_path/0`.
  """
  @spec trust(Path.t(), keyword()) :: {String.t(), non_neg_integer()}
  def trust(path, opts \\ []) do
    user_path = user_path(opts)
    path = Path.expand(path)

    with :ok <- directory(path),
         {:ok, text, entries} <- read_user(user_path),
         {:ok, said} <- add(path, user_path, text, covering(path, entries)) do
      {said, 0}
    else
      {:error, message} -> {message <> "\n", 1}
    end
  end

  defp add(path, user_path, _text, [entry | _]),
    do: {:ok, "#{show(path)} is already trusted: #{@key} in #{show(user_path)} has #{entry}\n"}

  defp add(path, user_path, text, []) do
    root = root(path)
    by_hand = "add #{Jason.encode!(root)} to #{@key} in #{show(user_path)} by hand"

    with :ok <- save(user_path, text, fn _entry -> true end, [root], by_hand) do
      worktree =
        if Workspace.compare_key(root) != Workspace.compare_key(real(path)),
          do: "#{show(path)} is a git worktree of #{show(root)}; trusting the checkout trusts its worktrees too\n",
          else: ""

      {:ok,
       worktree <>
         "trusted #{show(root)}: its .troupe files may now set every key; `troupe config --explain` shows them\n" <>
         "  added to #{@key} in #{show(user_path)}#{previous(user_path, text)}\n"}
    end
  end

  @doc """
  `troupe config untrust [PATH]`: remove the entries naming the workspace, or the
  checkout a worktree belongs to. An entry naming a directory above it trusts other
  workspaces too, so it stays, and the answer names it and says it still trusts this one.

  Options: `:user_path`, as for `trust/2`.
  """
  @spec untrust(Path.t(), keyword()) :: {String.t(), non_neg_integer()}
  def untrust(path, opts \\ []) do
    user_path = user_path(opts)
    path = Path.expand(path)

    with {:ok, text, entries} <- read_user(user_path),
         names = path |> candidates() |> Enum.map(&Workspace.compare_key/1),
         {removed, kept} = Enum.split_with(entries, &(absolute?(&1) and key(&1) in names)),
         {:ok, said, code} <- remove(path, user_path, text, removed, covering(path, kept)) do
      {said, code}
    else
      {:error, message} -> {message <> "\n", 1}
    end
  end

  defp remove(path, user_path, _text, [], []) do
    {:ok, "#{show(path)} is not trusted: #{@key} in #{show(user_path)} names neither it nor a directory above it\n",
     0}
  end

  defp remove(path, user_path, _text, [], still), do: {:ok, still_trusted(path, user_path, still), 1}

  defp remove(path, user_path, text, removed, still) do
    by_hand = "remove #{Enum.join(removed, ", ")} from #{@key} in #{show(user_path)} by hand"

    with :ok <- save(user_path, text, &(&1 not in removed), [], by_hand) do
      said =
        "untrusted #{show(path)}: its .troupe files set no key marked trusted any more\n" <>
          "  removed #{Enum.join(removed, ", ")} from #{@key} in #{show(user_path)}#{previous(user_path, text)}\n"

      if still == [], do: {:ok, said, 0}, else: {:ok, said <> still_trusted(path, user_path, still), 1}
    end
  end

  defp still_trusted(path, user_path, [entry | _]) do
    "#{show(path)} is still trusted: #{@key} in #{show(user_path)} has #{entry}, which trusts everything " <>
      "under it; `troupe config untrust #{entry}` removes that\n"
  end

  @doc "`troupe config trust --list`: the user file's `trusted_workspaces`, as written."
  @spec list(keyword()) :: {String.t(), non_neg_integer()}
  def list(opts \\ []) do
    user_path = user_path(opts)

    case read_user(user_path) do
      {:ok, _text, []} ->
        {"no workspace is trusted: #{show(user_path)} has no #{@key}\n", 0}

      {:ok, _text, entries} ->
        {"#{@key} in #{show(user_path)}:\n" <> Enum.map_join(entries, &"  #{&1}#{relative(&1)}\n"), 0}

      {:error, message} ->
        {message <> "\n", 1}
    end
  end

  defp relative(entry), do: if(absolute?(entry), do: "", else: "  (not an absolute path, and trusts nothing)")

  defp user_path(opts), do: Keyword.get_lazy(opts, :user_path, &Troupe.Config.user_path/0)

  defp directory(path) do
    if File.dir?(path), do: :ok, else: {:error, "#{show(path)} is not a directory; name the workspace to trust"}
  end

  # The user file's text (`nil` when there is none) and its entries. A file that is not
  # YAML, or whose list is not a list, is the person's to fix: nothing is written over it.
  defp read_user(user_path) do
    case Layers.parse(user_path) do
      :absent ->
        {:ok, nil, []}

      {:error, issue} ->
        {:error, Issue.format(issue) <> "; fix it, then run this again"}

      {:ok, map, text} ->
        case Map.get(map, @key) do
          list when is_list(list) or is_nil(list) ->
            {:ok, text, Layers.trust_list(map)}

          other ->
            {:error, "#{show(user_path)}: #{@key} must be a list of paths, not #{Layers.show(other)}; fix it first"}
        end
    end
  end

  # A file that is not there is written as every writer writes one. One that is has only
  # its list edited, or nothing: then the person is told what to change by hand.
  defp save(user_path, nil, _keep?, add, _by_hand), do: Migrate.write(user_path, %{@key => add})

  defp save(user_path, text, keep?, add, by_hand) do
    case Yaml.edit_list(text, @key, keep?, add) do
      {:ok, edited} ->
        Migrate.write_text(user_path, edited)

      :error ->
        {:error,
         "#{show(user_path)} is written in a way this cannot change without rewriting it, " <>
           "so it is as it was; #{by_hand}"}
    end
  end

  defp previous(_user_path, nil), do: ""
  defp previous(user_path, _text), do: "; the file as it was is #{show(user_path)}.previous"

  defp show(path), do: Troupe.Paths.display(path)
end
