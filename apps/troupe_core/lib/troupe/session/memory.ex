defmodule Troupe.Session.Memory do
  @moduledoc """
  The project brief every agent's system prompt opens with: a repository's facts
  (`Troupe.Memory.Facts`, Decision 838) and the view of them, `.troupe/memory.md`.

  One brief per repository: the path is the repository's main checkout, so a session in
  a worktree reads and writes the same facts as the session whose branch it is, and a
  later session on either finds what both learned. A worktree is one its checkout names
  back, as trust has it (`Troupe.Config.Trust.root/1`): a `.git` a workspace wrote itself,
  giving another checkout's `.git` as its common directory, leaves the brief in the
  workspace (Decision 831). A fact's anchors are read from the top of the checkout or
  worktree the session is in, so a branch whose `mix.exs` differs says so.

  The facts have one writer, their store's process; this module says where they are,
  whether the brief is worth (re)building, and keeps the record of a librarian's try in
  the state directory.
  """

  alias Troupe.{Config, Git, Memory, Paths, Workspace}
  alias Troupe.Config.Trust
  alias Troupe.Memory.Facts

  require Logger

  @type status :: :absent | :stale | :fresh | :disabled

  # When a librarian last started on each brief, filed under the brief's path.
  @attempts "librarian.json"

  @doc """
  Where a workspace's facts are kept (`root`, its repository's main checkout) and where
  their anchors are read from (`top`, the checkout or worktree the workspace is in); the
  workspace itself for both outside git, or where its `.git` names a checkout that does
  not name it back.
  """
  @spec locate(Path.t()) :: %{root: Path.t(), top: Path.t()}
  def locate(workspace), do: repository_root(workspace)

  @doc "Where the brief's view lives for a workspace: its repository's main checkout."
  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: workspace |> locate() |> view_path()

  @doc "The view's path at a location `locate/1` gave."
  @spec view_path(%{root: Path.t()}) :: Path.t()
  def view_path(%{root: root}), do: Path.join([root, ".troupe", "memory.md"])

  @doc """
  The brief's view, parsed, or `nil` when there are no facts: read after its store has
  read the files again, so a person's edit or a brief from before facts is in it.
  """
  @spec brief(Path.t()) :: Memory.t() | nil
  def brief(workspace) do
    where = locate(workspace)
    if safely(fn -> Facts.count(where) end, 0) > 0, do: read(view_path(where))
  end

  @doc """
  The parsed view at a path `path/1` gave, or `nil`, as the file is now. A view that is
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
  def inside?(path), do: inside?(path, path |> Path.dirname() |> Path.dirname())

  @doc "Whether `path` is really under `root`, links followed: `inside?/1` for any file of the memory."
  @spec inside?(Path.t(), Path.t()) :: boolean()
  def inside?(path, root) do
    with {:ok, real} <- Workspace.real_path(path),
         {:ok, real_root} <- Workspace.real_path(root) do
      key = Workspace.compare_key(real)
      root_key = Workspace.compare_key(real_root)
      key == root_key or String.starts_with?(key, root_key <> "/")
    else
      _error -> false
    end
  end

  @doc "The `# Project brief` block for a system prompt; `\"\"` when there are no facts or it is off."
  @spec prompt_section(Path.t(), Config.t() | nil, keyword()) :: String.t()
  def prompt_section(workspace, config, opts \\ []) do
    if enabled?(config),
      do: workspace |> core() |> Memory.to_prompt(prompt_opts(config) ++ opts),
      else: ""
  end

  @doc "The core a prompt carries (`Troupe.Memory.Facts.core/1`), or nothing when it cannot be read."
  @spec core(Path.t() | %{root: Path.t(), top: Path.t()}) :: Memory.core() | nil
  def core(where), do: safely(fn -> Facts.core(where) end, nil)

  @doc "What `Troupe.Memory.prompt/2` is told under a config: the cap and the age a fact keeps."
  @spec prompt_opts(Config.t() | nil) :: keyword()
  def prompt_opts(config), do: [max_chars: max_chars(config), max_age_days: max_age(config)]

  @doc """
  Whether the brief is worth (re)building: `absent` with no facts, `stale` when it was
  never built, is older than `memory_max_age_days`, or a command or convention it holds
  rests on a file that changed or went since it was built (`Troupe.Memory.stale?/3`),
  `fresh` otherwise.
  """
  @spec status(Path.t(), Config.t() | nil) :: status()
  def status(workspace, config) do
    if enabled?(config),
      do: workspace |> locate() |> status_at(config),
      else: :disabled
  end

  defp status_at(where, config) do
    case core(where) do
      nil -> :absent
      %{facts: [], others: others} when map_size(others) == 0 -> :absent
      %{facts: facts} -> if stale?(where, facts, config), do: :stale, else: :fresh
    end
  end

  defp stale?(where, facts, config) do
    built_at = safely(fn -> where |> Facts.meta() |> Map.get(:built_at) end, nil)
    Memory.stale?(built_at, facts, max_age_days: max_age(config))
  end

  @doc "Appends a note from `agent`, as a fact of kind `note`."
  @spec note(Path.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def note(workspace, agent, text) do
    claim = text |> to_string() |> String.split() |> Enum.join(" ")

    case Facts.put(workspace, %{"kind" => "note", "claim" => claim}, %{by: "agent:" <> agent}) do
      {:ok, _fact} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces a section's facts with one per item of `text` and stamps the brief as rebuilt,
  as writing a whole section did before there were facts. `by` says who wrote it.
  """
  @spec put_section(Path.t(), String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put_section(workspace, title, text, by \\ "librarian") do
    case Memory.kind_of_title(title) do
      nil ->
        {:error, "unknown section #{title}"}

      kind ->
        Facts.replace(workspace, kind, Memory.claims(text), %{by: by, head: head(workspace)})
    end
  end

  @doc """
  Stamps the brief as checked against the repository now, and changes no word of it: what
  a librarian's run leaves when it found nothing to rewrite (Decision 696). Its unanchored
  facts count as checked again; a moved one stays moved. A repository with no facts is
  left as it is.
  """
  @spec checked(Path.t()) :: :ok | {:error, String.t()}
  def checked(workspace),
    do:
      safely(
        fn -> Facts.stamp(workspace, head(workspace)) end,
        {:error, "the facts could not be read"}
      )

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
    # since then, say because a file a command rests on changed, is due at once.
    with %DateTime{} = at <- attempted_at(path, state_dir(config)),
         until = DateTime.add(at, max_age(config) * 86_400, :second),
         true <- DateTime.compare(DateTime.utc_now(), until) != :gt,
         false <- built_since?(read(path), at) do
      until
    else
      _ -> nil
    end
  end

  @doc "Forgets the brief, every fact with it, and the record of a librarian's try at it."
  @spec forget(Path.t(), Path.t() | nil) :: :ok
  def forget(workspace, state_dir \\ nil) do
    where = locate(workspace)
    _ = safely(fn -> Facts.clear(where) end, :ok)
    _ = update_attempts(state_dir, &Map.delete(&1, attempt_key(view_path(where))))
    :ok
  end

  @doc "HEAD in the workspace, short, or `nil` outside git."
  @spec head(Path.t()) :: String.t() | nil
  def head(workspace) do
    case git(Path.expand(workspace), ["rev-parse", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      :error -> nil
    end
  end

  ## Internals

  # The store is a process: a read that finds it gone or failing reads as no brief rather
  # than taking the prompt, or the client asking, down with it.
  defp safely(fun, default) do
    fun.()
  rescue
    error ->
      Logger.warning("memory: the facts could not be read: #{Exception.message(error)}")
      default
  catch
    :exit, reason ->
      Logger.warning("memory: the facts could not be read: #{inspect(reason)}")
      default
  end

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
  # and replaced inside a transaction on its path.
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

  # The main checkout of the repository a workspace is in: a worktree's brief is the
  # repository's, not a copy that disappears with the worktree. git takes a `.git` at its
  # word, and one a workspace wrote itself can give any checkout's `.git` as its common
  # directory, so that checkout is the brief's only when trust finds it for git's top
  # level, which must hold the workspace: the top level is then the checkout itself, or a
  # worktree the checkout's `.git/worktrees/<name>` names back. Otherwise the brief is the
  # workspace's own (Decision 831). The top level is where anchors are read.
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
      %{root: checkout, top: Path.expand(top)}
    else
      _ -> %{root: workspace, top: workspace}
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

  # Not a repository, git missing or failing, and a reaper that will not start all read
  # as no repository: this runs before every model call, and the reaper logs its own
  # failure once (Decision 733). So does a `.git` naming another checkout's repository,
  # and nothing the repository's own `.git` names runs (Decision 833).
  defp git(workspace, args) do
    if File.dir?(workspace) do
      case Git.run(workspace, args, timeout_ms: 10_000) do
        {:ok, out, 0} -> {:ok, out}
        _other -> :error
      end
    else
      :error
    end
  end
end
