defmodule Troupe.Session.Memory do
  @moduledoc """
  Owns `.troupe/memory.md`, the project brief every agent's system prompt opens with.

  One brief per repository: the path is the repository's main checkout, so a session in
  a worktree reads and writes the same file as the session whose branch it is, and a
  later session on either finds what both learned. Writes go through a VM-wide
  transaction keyed by the path, re-read the file before merging, and replace it by
  rename — so two agents in one daemon cannot clobber each other's note, and a hand
  edit made between two calls survives. Two daemons on one repository are last-write-
  wins per section; that is deliberate, and cheaper than locking state nobody is racing
  for in practice.

  No process of its own: the brief is a file, the daemon has many sessions, and a
  function over a path is what both want.
  """

  alias Troupe.{Config, Memory, Reaper}

  require Logger

  @type status :: :absent | :stale | :fresh | :disabled

  @doc "Where the brief lives for a workspace: its repository's main checkout."
  @spec path(Path.t()) :: Path.t()
  def path(workspace), do: Path.join([repository_root(workspace), ".troupe", "memory.md"])

  @doc "The parsed brief, or `nil` when there is no readable one."
  @spec brief(Path.t()) :: Memory.t() | nil
  def brief(workspace), do: workspace |> path() |> read()

  @doc "The `# Project brief` block for a system prompt; `\"\"` when absent or disabled."
  @spec prompt_section(Path.t(), Config.t() | nil) :: String.t()
  def prompt_section(workspace, config) do
    if enabled?(config),
      do: Memory.to_prompt(brief(workspace), max_chars: max_chars(config)),
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

  @doc "Deletes the brief."
  @spec forget(Path.t()) :: :ok
  def forget(workspace) do
    _ = File.rm(path(workspace))
    :ok
  end

  ## Internals

  defp enabled?(%Config{memory: enabled}), do: enabled != false
  defp enabled?(_config), do: true

  defp max_chars(%Config{memory_max_chars: n}) when is_integer(n) and n > 0, do: n
  defp max_chars(_config), do: 6_000

  defp max_age(%Config{memory_max_age_days: n}) when is_integer(n) and n > 0, do: n
  defp max_age(_config), do: 7

  # Re-read before merging, inside a transaction on the path: another session in this
  # daemon, or the person's editor, may have touched the file since anyone looked.
  defp mutate(workspace, fun) do
    path = path(workspace)

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

  defp read(path) do
    with {:ok, content} <- File.read(path),
         {:ok, brief} <- Memory.parse(content) do
      brief
    else
      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Logger.warning("memory: ignoring unreadable #{path}: #{inspect(reason)}")
        nil
    end
  end

  defp write(path, brief) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Memory.render(brief)) do
      File.rename(tmp, path)
    end
  end

  # The main checkout of the repository a workspace is in: a worktree's brief is the
  # repository's, not a copy that disappears with the worktree.
  defp repository_root(workspace) do
    workspace = Path.expand(workspace)

    case git(workspace, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      {:ok, common} ->
        common = common |> String.trim() |> Path.expand()
        if Path.basename(common) == ".git", do: Path.dirname(common), else: workspace

      :error ->
        workspace
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
