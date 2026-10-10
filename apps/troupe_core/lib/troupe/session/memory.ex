defmodule Troupe.Session.Memory do
  @moduledoc """
  Owns `.troupe/memory.md`, the project brief every agent's system prompt opens with.

  One brief per repository: the path is the repository's main checkout, so a session in
  a worktree reads and writes the same file as the session whose branch it is, and a
  later session on either finds what both learned. A worktree is one its checkout names
  back, as trust has it (`Troupe.Config.Trust.root/1`): a `.git` a workspace wrote itself,
  giving another checkout's `.git` as its common directory, leaves the brief in the
  workspace (Decision 831).

  Writes go through a VM-wide transaction keyed by the path, re-read the file before
  merging, and replace it by rename — so two agents in one daemon cannot clobber each
  other's note, and a hand edit made between two calls survives. Two daemons on one
  repository are last-write-wins per section; that is deliberate, and cheaper than
  locking state nobody is racing for in practice.

  No process of its own: the brief is a file, the daemon has many sessions, and a
  function over a path is what both want.
  """

  alias Troupe.{Config, Memory, Paths, Reaper, Workspace}
  alias Troupe.Config.Trust

  require Logger

  @type status :: :absent | :stale | :fresh | :disabled

  # When a librarian last started on each brief, filed under the brief's path.
  @attempts "librarian.json"

  @doc "Where the brief lives for a workspace: its repository's main checkout."
  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: Path.join([repository_root(workspace), ".troupe", "memory.md"])

  @doc "The parsed brief, or `nil` when there is no readable one."
  @spec brief(Path.t()) :: Memory.t() | nil
  def brief(workspace), do: workspace |> path() |> read()

  @doc """
  The parsed brief at a path `path/1` gave, or `nil`: for a caller that needs the path
  as well, since finding the repository's main checkout is a `git` call. A brief that is
  not `inside?/1` its repository is `nil` too.
  """
  @spec read(Path.t()) :: Memory.t() | nil
  def read(path) do
    with true <- inside?(path),
         {:ok, content} <- File.read(path),
         {:ok, brief} <- Memory.parse(content) do
      brief
    else
      false ->
        nil

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("memory: ignoring unreadable #{path}: #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Whether the brief at a path `path/1` gave is really in its repository (Decision 798): a
  `.troupe/memory.md`, or a `.troupe`, that is a link to somewhere else on the machine is
  not, and is neither read, written nor deleted, so a repository cannot have its brief
  stand for a file elsewhere. One that does not exist yet is inside.
  """
  @spec inside?(Path.t()) :: boolean()
  def inside?(path) do
    root = path |> Path.dirname() |> Path.dirname()

    with {:ok, real} <- Workspace.real_path(path),
         {:ok, real_root} <- Workspace.real_path(root) do
      key = Workspace.compare_key(real)
      root_key = Workspace.compare_key(real_root)
      key == root_key or String.starts_with?(key, root_key <> "/")
    else
      _error -> false
    end
  end

  @doc "The `# Project brief` block for a system prompt; `\"\"` when absent or disabled."
  @spec prompt_section(Path.t(), Config.t() | nil) :: String.t()
  def prompt_section(workspace, config) do
    if enabled?(config),
      do: workspace |> brief() |> to_prompt(config),
      else: ""
  end

  @doc "`prompt_section/2` for a brief already read."
  @spec to_prompt(Memory.t() | nil, Config.t() | nil) :: String.t()
  def to_prompt(brief, config) do
    if enabled?(config),
      do: Memory.to_prompt(brief, max_chars: max_chars(config)),
      else: ""
  end

  @doc "Whether the brief is worth (re)building."
  @spec status(Path.t(), Config.t() | nil) :: status()
  def status(workspace, config) do
    brief = brief(workspace)

    cond do
      not enabled?(config) -> :disabled
      is_nil(brief) -> :absent
      Memory.stale?(brief, files: tracked_files(workspace), max_age_days: max_age(config)) -> :stale
      true -> :fresh
    end
  end

  @doc "Appends a dated note from `agent`."
  @spec note(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def note(workspace, agent, text), do: mutate(workspace, &Memory.add_note(&1, agent, text))

  @doc "Replaces a curated section and stamps the brief as rebuilt."
  @spec put_section(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put_section(workspace, title, text) do
    mutate(workspace, fn brief ->
      brief
      |> Memory.put_section(title, text)
      |> Memory.stamp(head(workspace), tracked_files(workspace))
    end)
  end

  @doc """
  Stamps the brief as checked against the repository now, and changes no word of it: what
  a librarian's run leaves when it found nothing to rewrite (Decision 696). A repository
  with no readable brief is left as it is.
  """
  @spec checked(Path.t()) :: :ok | {:error, String.t()}
  def checked(workspace) do
    if brief(workspace),
      do: mutate(workspace, &Memory.stamp(&1, head(workspace), tracked_files(workspace))),
      else: :ok
  end

  @doc """
  Records that a librarian started on the brief at `at`, now unless told: what holds
  off the next automatic refresh if this run builds nothing (`refresh_due?/2`). Kept in
  the state directory, filed under the brief's path, never in the repository.
  """
  @spec attempted(Path.t(), Path.t() | nil, DateTime.t()) :: :ok | {:error, String.t()}
  def attempted(workspace, state_dir, at \\ DateTime.utc_now()) do
    key = workspace |> path() |> attempt_key()
    update_attempts(state_dir, &Map.put(&1, key, DateTime.to_iso8601(at)))
  end

  @doc """
  Whether a client that keeps the brief up by itself (`memory_auto_refresh`) should
  start a librarian now: the brief is absent or stale, and no librarian has tried it in
  the last `memory_max_age_days` without its being built since. So a run that failed,
  was cancelled or wrote nothing where there was no brief is tried again that much
  later, not in every new session (Decision 713).
  """
  @spec refresh_due?(Path.t(), Config.t() | nil) :: boolean()
  def refresh_due?(workspace, config) do
    status(workspace, config) in [:absent, :stale] and held_until(workspace, config) == nil
  end

  @doc """
  Until when a librarian's try that built nothing holds off the next automatic refresh,
  or `nil` when none does: what `refresh_due?/2` waits out, for a client to say.
  """
  @spec held_until(Path.t(), Config.t() | nil) :: DateTime.t() | nil
  def held_until(workspace, config) do
    path = path(workspace)

    # A try holds while it is younger than the age a brief may reach, and only when nothing
    # built the brief after it: a librarian that got through stamped it, and a brief stale
    # since then, say because the repository grew, is due at once.
    with %DateTime{} = at <- attempted_at(path, state_dir(config)),
         until = DateTime.add(at, max_age(config) * 86_400, :second),
         true <- DateTime.compare(DateTime.utc_now(), until) != :gt,
         false <- built_since?(read(path), at) do
      until
    else
      _ -> nil
    end
  end

  @doc "Deletes the brief, and the record of a librarian's try at it."
  @spec forget(Path.t(), Path.t() | nil) :: :ok
  def forget(workspace, state_dir \\ nil) do
    path = path(workspace)
    _ = if inside?(path), do: File.rm(path)
    _ = update_attempts(state_dir, &Map.delete(&1, attempt_key(path)))
    :ok
  end

  ## Internals

  defp enabled?(%Config{memory: enabled}), do: enabled != false
  defp enabled?(_config), do: true

  defp max_chars(%Config{memory_max_chars: n}) when is_integer(n) and n > 0, do: n
  defp max_chars(_config), do: 6_000

  defp max_age(%Config{memory_max_age_days: n}) when is_integer(n) and n > 0, do: n
  defp max_age(_config), do: 7

  defp state_dir(%Config{state_dir: dir}), do: dir
  defp state_dir(_config), do: nil

  defp built_since?(%Memory{built_at: %DateTime{} = built_at}, at),
    do: DateTime.compare(built_at, at) == :gt

  defp built_since?(_brief, _at), do: false

  defp attempted_at(path, state_dir) do
    with value when is_binary(value) <- Map.get(read_attempts(state_dir), attempt_key(path)),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _ -> nil
    end
  end

  defp attempt_key(path), do: Workspace.compare_key(path)

  defp attempts_path(state_dir), do: Path.join(Paths.state_dir(state_dir), @attempts)

  defp read_attempts(state_dir) do
    with {:ok, text} <- File.read(attempts_path(state_dir)),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      map
    else
      _ -> %{}
    end
  end

  # One daemon may start two librarians at once, on two repositories: the file is read
  # and replaced inside a transaction on its path, as the brief is.
  defp update_attempts(state_dir, fun) do
    file = attempts_path(state_dir)

    :global.trans({{__MODULE__, file}, self()}, fn ->
      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <-
             File.write(file, Jason.encode!(fun.(read_attempts(state_dir)), pretty: true) <> "\n") do
        :ok
      else
        {:error, reason} ->
          Logger.warning("memory: cannot write #{file}: #{inspect(reason)}")
          {:error, "cannot write #{file}: #{inspect(reason)}"}
      end
    end)
  end

  # Re-read before merging, inside a transaction on the path: another session in this
  # daemon, or the person's editor, may have touched the file since anyone looked. A brief
  # that is a link out is not written: the write would copy what it points at into the
  # repository, or, through a linked `.troupe`, write elsewhere.
  defp mutate(workspace, fun) do
    path = path(workspace)

    if inside?(path), do: transact(path, fun), else: refuse_outside(path)
  end

  defp refuse_outside(path) do
    Logger.warning("memory: not writing #{path}: it is a link to outside its repository")
    {:error, "not written: #{path} is a link to outside its repository"}
  end

  defp transact(path, fun) do
    :global.trans({{__MODULE__, path}, self()}, fn ->
      brief = fun.(read(path) || Memory.empty())

      case write(path, brief) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("memory: cannot write #{path}: #{inspect(reason)}")
          {:error, "cannot write #{path}: #{inspect(reason)}"}
      end
    end)
  end

  defp write(path, brief) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Memory.render(brief)) do
      File.rename(tmp, path)
    end
  end

  # The main checkout of the repository a workspace is in: a worktree's brief is the
  # repository's, not a copy that disappears with the worktree. git takes a `.git` at its
  # word, and one a workspace wrote itself can give any checkout's `.git` as its common
  # directory, so that checkout is the brief's only when trust finds it for git's top
  # level, which must hold the workspace: the top level is then the checkout itself, or a
  # worktree the checkout's `.git/worktrees/<name>` names back. Otherwise the brief is the
  # workspace's own (Decision 831).
  defp repository_root(workspace) do
    workspace = Path.expand(workspace)
    args = ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"]

    with {:ok, out} <- git(workspace, args),
         [top, common] <- String.split(out, "\n", trim: true),
         common = Path.expand(common),
         ".git" <- Path.basename(common),
         checkout = Path.dirname(common),
         true <- within?(workspace, top),
         true <- key(Trust.root(top)) == key(checkout) do
      checkout
    else
      _ -> workspace
    end
  end

  defp within?(path, root),
    do: key(path) == key(root) or String.starts_with?(key(path), key(root) <> "/")

  defp key(path) do
    case Workspace.real_path(path) do
      {:ok, real} -> Workspace.compare_key(real)
      {:error, _} -> Workspace.compare_key(path)
    end
  end

  defp head(workspace) do
    case git(workspace, ["rev-parse", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      :error -> nil
    end
  end

  defp tracked_files(workspace) do
    case git(workspace, ["ls-files", "--cached", "--others", "--exclude-standard"]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.reject(&String.starts_with?(&1, ".troupe/"))
        |> length()

      :error ->
        nil
    end
  end

  # Not a repository, git missing or failing, and a reaper that will not start all read
  # as no repository: this runs before every model call, and the reaper logs its own
  # failure once (Decision 733).
  defp git(workspace, args) do
    if File.dir?(workspace) do
      case Reaper.run(workspace, ["git" | args], timeout_ms: 10_000) do
        {:ok, out, 0} -> {:ok, out}
        _other -> :error
      end
    else
      :error
    end
  end
end
