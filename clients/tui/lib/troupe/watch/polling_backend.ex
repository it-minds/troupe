defmodule Troupe.Watch.PollingBackend do
  @moduledoc "Fallback backend: periodic mtime and size scan of non-ignored files."

  @behaviour Troupe.Watch.Backend
  use GenServer

  alias Troupe.Watch.Ignore

  @impl Troupe.Watch.Backend
  def name, do: :polling

  @impl Troupe.Watch.Backend
  def available?, do: true

  @impl Troupe.Watch.Backend
  def start_link(dir, notify, opts), do: GenServer.start_link(__MODULE__, {dir, notify, opts})

  @impl GenServer
  def init({dir, notify, opts}) do
    interval = Keyword.get(opts, :interval_ms, 500)
    state = %{dir: dir, notify: notify, interval: interval, snapshot: snapshot(dir)}
    Process.send_after(self(), :scan, interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:scan, state) do
    current = snapshot(state.dir)

    for {path, stat} <- current, Map.get(state.snapshot, path) != stat do
      send(state.notify, {:file_changed, path})
    end

    Process.send_after(self(), :scan, state.interval)
    {:noreply, %{state | snapshot: current}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp snapshot(dir) do
    dir
    |> Ignore.candidate_files()
    |> Map.new(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: m, size: s}} -> {path, {m, s}}
        _ -> {path, nil}
      end
    end)
  end
end
