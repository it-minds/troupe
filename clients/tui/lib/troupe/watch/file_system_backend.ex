defmodule Troupe.Watch.FileSystemBackend do
  @moduledoc "Native watch backend via the `file_system` package (inotify, FSEvents, ReadDirectoryChanges)."

  @behaviour Troupe.Watch.Backend
  use GenServer

  @impl Troupe.Watch.Backend
  def name, do: :file_system

  @impl Troupe.Watch.Backend
  def available? do
    case :os.type() do
      {:unix, :linux} -> System.find_executable("inotifywait") != nil
      {:unix, :darwin} -> true
      {:win32, _} -> true
      _ -> false
    end
  end

  @impl Troupe.Watch.Backend
  def start_link(dir, notify, _opts), do: GenServer.start_link(__MODULE__, {dir, notify})

  @impl GenServer
  def init({dir, notify}) do
    case FileSystem.start_link(dirs: [dir]) do
      {:ok, fs} ->
        FileSystem.subscribe(fs)
        {:ok, %{fs: fs, notify: notify}}

      other ->
        {:stop, {:file_system_unavailable, other}}
    end
  end

  @impl GenServer
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    send(state.notify, {:file_changed, to_string(path)})
    {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:stop, :file_system_stopped, state}
  def handle_info(_msg, state), do: {:noreply, state}
end
