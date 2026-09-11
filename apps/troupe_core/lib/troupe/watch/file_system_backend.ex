defmodule Troupe.Watch.FileSystemBackend do
  @moduledoc """
  Native filesystem notifications via `:file_system`.

  Available only when the platform's watcher executable is actually present:
  `inotifywait` on Linux, `mac_listener` on macOS, `inotifywait.exe` on Windows. A
  clean Linux machine has none of them, which is why `available?/1` checks rather
  than assumes — a single self-contained binary must still watch files there,
  through the polling backend.

  Two things the underlying watcher does not give us, which this module adds:

  **New directories.** `inotifywait -r` arms watches on the directories that exist
  when it starts; a directory created afterwards is reported, but nothing *inside* it
  ever is. An agent creating `lib/feature/` and writing files there would go
  unnoticed. So a directory-creation event re-arms the watcher and sweeps the new
  directory, which also covers files written into it before the re-arm landed.

  **Readiness.** There is no signal for "watches are established", so a write
  immediately after start-up can be missed. Start-up therefore watches a private
  probe directory alongside the workspace and waits for an event on a file it writes
  there. The probe lives in the system temp directory, never in the user's
  repository.
  """

  use GenServer

  @behaviour Troupe.Watch.Backend

  require Logger

  @probe_attempts 8
  @probe_wait_ms 250

  @impl Troupe.Watch.Backend
  def name, do: :native

  @impl Troupe.Watch.Backend
  def available?(_root) do
    case :os.type() do
      {:unix, :darwin} -> executable?("mac_listener")
      {:win32, _} -> executable?("inotifywait.exe")
      {:unix, _} -> executable?("inotifywait")
    end
  end

  defp executable?(exe) do
    System.find_executable(exe) != nil or File.regular?(Path.join(file_system_priv(), exe))
  end

  defp file_system_priv do
    case :code.priv_dir(:file_system) do
      {:error, _} -> ""
      dir -> List.to_string(dir)
    end
  end

  @impl Troupe.Watch.Backend
  def start_link(root, listener, opts \\ []) do
    GenServer.start_link(__MODULE__, {root, listener, opts})
  end

  @impl GenServer
  def init({root, listener, _opts}) do
    Process.set_label("troupe watch backend (native)")
    Process.flag(:trap_exit, true)

    probe_dir =
      Path.join(System.tmp_dir!(), "troupe-watch-probe-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(probe_dir)

    case arm(root, probe_dir) do
      {:ok, watcher} ->
        {:ok, %{root: root, listener: listener, watcher: watcher, probe_dir: probe_dir}}

      {:error, reason} ->
        File.rm_rf(probe_dir)
        {:stop, {:file_system_unavailable, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    File.rm_rf(state.probe_dir)
    :ok
  end

  @impl GenServer
  def handle_info({:file_event, watcher, {path, events}}, %{watcher: watcher} = state) do
    cond do
      probe?(state, path) ->
        {:noreply, state}

      new_directory?(path, events) ->
        {:noreply, rearm(state, path)}

      true ->
        send(state.listener, {:watch_paths, [path]})
        {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    {:stop, :watcher_stopped, state}
  end

  def handle_info({:EXIT, watcher, reason}, %{watcher: watcher} = state) do
    {:stop, {:watcher_exited, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp probe?(state, path), do: String.starts_with?(path, state.probe_dir)

  defp new_directory?(path, events) do
    (:created in events or :moved_to in events) and (:isdir in events or File.dir?(path))
  end

  # Restart the watcher so the new directory gets a watch, then report everything
  # already inside it: files written between the directory's creation and the re-arm
  # produced no events of their own and would otherwise be lost.
  defp rearm(state, new_dir) do
    stop_watcher(state.watcher)

    case arm(state.root, state.probe_dir) do
      {:ok, watcher} ->
        case files_under(new_dir) do
          [] -> :ok
          files -> send(state.listener, {:watch_paths, files})
        end

        %{state | watcher: watcher}

      {:error, reason} ->
        Logger.warning("troupe: could not re-arm the native watcher: #{inspect(reason)}")
        state
    end
  end

  defp arm(root, probe_dir) do
    # The probe directory is watched alongside the workspace purely so start-up has
    # something to write to that is not the user's repository.
    case FileSystem.start_link(dirs: [root, probe_dir]) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)

        if await_ready(watcher, probe_dir, @probe_attempts) do
          {:ok, watcher}
        else
          # Watching without a confirmed arm is still better than not watching: the
          # first change or two may be missed, and everything after works.
          Logger.debug("troupe: native watcher did not confirm readiness; continuing anyway")
          {:ok, watcher}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Write a probe file and wait for its own event to come back. A real handshake
  # rather than a fixed delay, so start-up is as fast as the watcher allows.
  defp await_ready(_watcher, _probe_dir, 0), do: false

  defp await_ready(watcher, probe_dir, attempts) do
    probe = Path.join(probe_dir, "probe-#{attempts}")
    File.write!(probe, "probe")

    result =
      receive do
        {:file_event, ^watcher, {path, _events}} ->
          if String.starts_with?(path, probe_dir), do: true, else: false
      after
        @probe_wait_ms -> false
      end

    File.rm(probe)

    if result, do: true, else: await_ready(watcher, probe_dir, attempts - 1)
  end

  defp stop_watcher(watcher) do
    Process.unlink(watcher)
    Process.exit(watcher, :shutdown)
    flush_events(watcher)
  end

  defp flush_events(watcher) do
    receive do
      {:file_event, ^watcher, _} -> flush_events(watcher)
      {:EXIT, ^watcher, _} -> flush_events(watcher)
    after
      0 -> :ok
    end
  end

  defp files_under(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &descend(Path.join(dir, &1)))
      {:error, _} -> []
    end
  end

  defp descend(path), do: if(File.dir?(path), do: files_under(path), else: [path])
end
