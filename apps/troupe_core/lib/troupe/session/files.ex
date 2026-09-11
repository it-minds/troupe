defmodule Troupe.Session.Files do
  @moduledoc """
  Durable `fs_changed` events for everything that happens in `session:/`.

  Separate from watch mode, which turns AI comments into agent input and is a feature a
  user switches on. This is not optional and is not about the agent: it is how a client
  attached to a remote session knows the working tree changed, including when the change
  was made by `shell` — which no tool call announces, because `shell` runs arbitrary
  commands and cannot say in advance what they will touch.

  Each event carries the path, the SHA-256 of the new contents and the size, so a client
  can tell a real change from a touch and `fs.read` can be checked against what the
  event said. Deletions carry a null hash and a size of zero rather than being a
  different event type, because a client rendering a tree needs one stream to fold.

  Debounced, but only briefly: the done item allows one second end to end and most of
  that budget belongs to the hashing and the wire, not to waiting.
  """

  use GenServer

  alias Troupe.{Gitignore, Registry, Workspace}
  alias Troupe.Session.Log
  alias Troupe.Watch.{FileSystemBackend, PollBackend}

  require Logger

  # Short enough that a write and its event are the same moment to a person, long enough
  # that a compiler writing four hundred files is not four hundred events.
  @debounce_ms 100
  # Bigger files are recorded by size and mtime rather than hashed: a client checking
  # `fs.read` against the event still gets a stable answer, and hashing a gigabyte on
  # every save would make the watcher the slowest thing in the pod.
  @max_hash_bytes 8 * 1024 * 1024

  @enforce_keys [:session_id, :workspace]
  defstruct [
    :session_id,
    :workspace,
    :backend,
    :backend_module,
    :timer,
    :ignore,
    agent_path: ["root"],
    debounce_ms: @debounce_ms,
    pending: MapSet.new(),
    seen: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.files(session_id))
  end

  @doc "Whether this session is emitting `fs_changed`, and through which backend."
  @spec backend(String.t()) :: atom()
  def backend(session_id), do: GenServer.call(Registry.files(session_id), :backend)

  @doc "Emit now for the given paths rather than waiting for the debounce. Tests."
  @spec flush(String.t(), [Path.t()]) :: :ok
  def flush(session_id, paths \\ []) do
    GenServer.call(Registry.files(session_id), {:flush, paths})
  end

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    Process.set_label("troupe files #{session_id}")
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      session_id: session_id,
      workspace: workspace,
      agent_path: Keyword.get(opts, :agent_path, ["root"]),
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      ignore: Gitignore.load(workspace.root_real)
    }

    if Keyword.get(opts, :enabled, false) do
      {:ok, start_backend(state, opts)}
    else
      {:ok, state}
    end
  end

  defp start_backend(state, opts) do
    module =
      Keyword.get(opts, :backend) ||
        if FileSystemBackend.available?(state.workspace.root_real), do: FileSystemBackend, else: PollBackend

    case module.start_link(state.workspace.root_real, self(), Keyword.take(opts, [:interval_ms])) do
      {:ok, pid} ->
        %{state | backend: pid, backend_module: module}

      {:error, reason} ->
        Logger.warning("troupe: no filesystem events for #{state.session_id}: #{inspect(reason)}")
        state
    end
  end

  @impl GenServer
  def handle_call(:backend, _from, state) do
    {:reply, if(state.backend, do: state.backend_module.name(), else: :off), state}
  end

  def handle_call({:flush, paths}, _from, state) do
    pending = Enum.reduce(paths, state.pending, &MapSet.put(&2, &1))
    {:reply, :ok, emit(%{state | pending: pending, timer: nil})}
  end

  @impl GenServer
  def handle_info({:watch_paths, paths}, state) do
    interesting = Enum.filter(paths, &interesting?(state, &1))

    if interesting == [] do
      {:noreply, state}
    else
      pending = Enum.reduce(interesting, state.pending, &MapSet.put(&2, &1))
      {:noreply, debounce(%{state | pending: pending})}
    end
  end

  def handle_info(:debounced, state), do: {:noreply, emit(%{state | timer: nil})}

  def handle_info({:EXIT, pid, reason}, %{backend: pid} = state) do
    Logger.warning("troupe: filesystem backend for #{state.session_id} exited: #{inspect(reason)}")
    {:noreply, %{state | backend: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- emitting ---------------------------------------------------------------

  defp emit(%__MODULE__{pending: pending} = state) do
    if MapSet.size(pending) == 0 do
      state
    else
      seen =
        pending
        |> Enum.sort()
        |> Enum.reduce(state.seen, &record(state, &1, &2))

      %{state | pending: MapSet.new(), seen: seen}
    end
  end

  defp record(state, path, seen) do
    current = describe(path)

    # An event for a file that has not actually changed is noise a client has to filter,
    # and a filesystem watcher produces plenty of those: an editor writing in place, a
    # tool touching mtime, a directory scan.
    if Map.get(seen, path) == current do
      seen
    else
      Log.append(state.session_id, state.agent_path, :fs_changed, %{
        "path" => Workspace.relative(state.workspace, path),
        "hash" => current.hash,
        "size" => current.size
      })

      Map.put(seen, path, current)
    end
  end

  defp describe(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        %{hash: hash(path, size, mtime), size: size}

      {:ok, %File.Stat{type: :directory}} ->
        %{hash: nil, size: 0}

      # Gone. A null hash rather than a second event type, so a client rendering a tree
      # has one stream to fold.
      {:error, _reason} ->
        %{hash: nil, size: 0}
    end
  end

  defp hash(path, size, mtime) when size <= @max_hash_bytes do
    case File.read(path) do
      {:ok, contents} -> "sha256:" <> (:sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower))
      {:error, _reason} -> stamp(size, mtime)
    end
  end

  defp hash(_path, size, mtime), do: stamp(size, mtime)

  # Big files are identified by size and mtime. Honest about what it is, so nobody reads
  # it as a content hash.
  defp stamp(size, mtime), do: "size-mtime:#{size}-#{mtime}"

  defp interesting?(state, path) do
    relative = Workspace.relative(state.workspace, path)

    Workspace.inside?(state.workspace, path) and
      not Gitignore.ignored?(state.ignore, relative) and
      not String.starts_with?(relative, ".git/")
  end

  defp debounce(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :debounced, state.debounce_ms)}
  end

end
