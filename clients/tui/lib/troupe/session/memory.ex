defmodule Troupe.Session.Memory do
  @moduledoc """
  Owns `.troupe/memory.md`, the project brief every agent's system prompt opens
  with. Single writer within a session, serialised through this process.

  The path is built from the *session* workspace, so a `/worktree` branch reads
  and writes the user's checkout rather than a copy inside its own worktree:
  one brief per repository, shared by every branch and every later session.

  Each mutation re-reads the file before merging and replaces it by rename, so a
  hand edit made between two calls is not clobbered wholesale. Two Troupe
  sessions on one repository are still last-write-wins per section; that is
  deliberate, and cheaper than locking state nobody is racing for in practice.
  """

  use GenServer
  require Logger

  alias Troupe.{Memory, OS, Session}

  @type status :: :absent | :stale | :fresh | :disabled

  defstruct [:session_id, :workspace, :path, :config, brief: nil]

  ## API

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :memory))
  end

  @doc "The parsed brief, or `nil` when there is no readable one."
  @spec brief(String.t()) :: Memory.t() | nil
  def brief(sid), do: GenServer.call(Session.via(sid, :memory), :brief)

  @doc "The `# Project brief` block for a system prompt; `\"\"` when absent or disabled."
  @spec prompt_section(String.t()) :: String.t()
  def prompt_section(sid), do: GenServer.call(Session.via(sid, :memory), :prompt_section)

  @doc "Whether the brief is worth (re)building. `files` is the tracked-file count now."
  @spec status(String.t(), non_neg_integer() | nil) :: status()
  def status(sid, files \\ nil),
    do: GenServer.call(Session.via(sid, :memory), {:status, files})

  @doc "Appends a dated note from `agent_path`."
  @spec note(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def note(sid, agent_path, text),
    do: GenServer.call(Session.via(sid, :memory), {:note, agent_path, text})

  @doc "Replaces a curated section and stamps the brief as rebuilt."
  @spec put_section(String.t(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def put_section(sid, title, text),
    do: GenServer.call(Session.via(sid, :memory), {:put_section, title, text})

  @doc "Deletes the brief."
  @spec forget(String.t()) :: :ok
  def forget(sid), do: GenServer.call(Session.via(sid, :memory), :forget)

  @doc "Replaces the config this actor reads its limits from."
  @spec put_config(String.t(), Troupe.Config.t()) :: :ok
  def put_config(sid, config),
    do: GenServer.call(Session.via(sid, :memory), {:put_config, config})

  @doc "Where the brief lives for `workspace`."
  @spec path(String.t()) :: String.t()
  def path(workspace), do: Path.join([workspace, ".troupe", "memory.md"])

  ## Server

  @impl true
  def init(%{session_id: sid} = opts) do
    path = path(opts.workspace)

    {:ok,
     %__MODULE__{
       session_id: sid,
       workspace: opts.workspace,
       path: path,
       config: opts.config,
       brief: read(path)
     }}
  end

  @impl true
  def handle_call(:brief, _from, state), do: {:reply, state.brief, state}

  def handle_call(:prompt_section, _from, %__MODULE__{} = state) do
    settings = settings(state)

    text =
      if settings.enabled,
        do: Memory.to_prompt(state.brief, max_chars: settings.max_chars),
        else: ""

    {:reply, text, state}
  end

  def handle_call({:status, files}, _from, %__MODULE__{} = state) do
    settings = settings(state)
    files = files || tracked_files(state.workspace)

    status =
      cond do
        not settings.enabled -> :disabled
        is_nil(state.brief) -> :absent
        Memory.stale?(state.brief, files: files, max_age_days: settings.max_age_days) -> :stale
        true -> :fresh
      end

    {:reply, status, state}
  end

  def handle_call({:note, agent_path, text}, _from, state) do
    mutate(state, &Memory.add_note(&1, agent_path, text))
  end

  def handle_call({:put_section, title, text}, _from, state) do
    mutate(state, fn brief ->
      brief
      |> Memory.put_section(title, text)
      |> Memory.stamp(head(state.workspace), tracked_files(state.workspace))
    end)
  end

  def handle_call(:forget, _from, %__MODULE__{} = state) do
    File.rm(state.path)
    {:reply, :ok, %__MODULE__{state | brief: nil}}
  end

  def handle_call({:put_config, config}, _from, %__MODULE__{} = state) do
    {:reply, :ok, %__MODULE__{state | config: config}}
  end

  ## Internals

  # Re-read before merging: another session, or the user's editor, may have
  # touched the file since the copy in state was taken.
  defp mutate(%__MODULE__{} = state, fun) do
    brief = fun.(read(state.path) || Memory.empty())

    case write(state.path, brief) do
      :ok ->
        {:reply, :ok, %__MODULE__{state | brief: brief}}

      {:error, reason} ->
        Logger.warning("memory: cannot write #{state.path}: #{inspect(reason)}")
        {:reply, {:error, "cannot write #{state.path}: #{inspect(reason)}"}, state}
    end
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

  defp settings(%__MODULE__{config: config}) do
    Map.get(config || %{}, :memory) ||
      %{enabled: true, auto_refresh: true, max_age_days: 7, max_chars: 6_000, survey_chars: 1_500}
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
    case OS.Process.run("git", args, cd: workspace, timeout_ms: 10_000, max_output: 2_000_000) do
      {:ok, out, 0} -> {:ok, out}
      _other -> :error
    end
  end
end
