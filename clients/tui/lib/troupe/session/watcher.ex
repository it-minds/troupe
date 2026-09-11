defmodule Troupe.Session.Watcher do
  @moduledoc """
  Watch mode. Debounces file changes, ignores the harness's own writes
  (`expect_write/3`), scans for AI markers and dispatches `code` (AI!) or
  `plan` (AI?) branches through the Dispatcher.
  """

  use GenServer
  require Logger

  alias Troupe.{Events, Session}
  alias Troupe.Session.{Dispatcher, Log}
  alias Troupe.Watch.{FileSystemBackend, Ignore, Markers, PollingBackend}

  defstruct [
    :session_id,
    :workspace,
    :config,
    enabled: false,
    backend: nil,
    backend_pid: nil,
    pending: MapSet.new(),
    timer: nil,
    expected: %{}
  ]

  ## API

  def start_link(%{session_id: sid} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :watcher))

  @spec enable(String.t(), keyword()) :: {:ok, :file_system | :polling}
  def enable(sid, opts \\ []), do: GenServer.call(Session.via(sid, :watcher), {:enable, opts})

  @spec disable(String.t()) :: :ok
  def disable(sid), do: GenServer.call(Session.via(sid, :watcher), :disable)

  @spec status(String.t()) :: %{enabled: boolean(), backend: atom() | nil}
  def status(sid), do: GenServer.call(Session.via(sid, :watcher), :status)

  @doc "Replaces the config the watcher reads its debounce and poll interval from."
  @spec put_config(String.t(), Troupe.Config.t()) :: :ok
  def put_config(sid, config),
    do: GenServer.call(Session.via(sid, :watcher), {:put_config, config})

  @doc "Tells the watcher an upcoming write is ours so it does not retrigger."
  @spec expect_write(String.t(), String.t(), String.t()) :: :ok
  def expect_write(sid, abs_path, content) do
    case Session.whereis(sid, :watcher) do
      nil -> :ok
      pid -> send(pid, {:expect_write, abs_path, hash(content)})
    end

    :ok
  end

  ## Server

  @impl true
  def init(%{session_id: sid, workspace: ws, config: config}) do
    state = %__MODULE__{session_id: sid, workspace: ws, config: config}

    if config.watch.enabled do
      {:ok, state, {:continue, :enable}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:enable, state) do
    {_, state} = do_enable(state, [])
    {:noreply, state}
  end

  @impl true
  def handle_call({:enable, opts}, _from, state) do
    {backend, state} = do_enable(state, opts)
    {:reply, {:ok, backend}, state}
  end

  def handle_call(:disable, _from, state) do
    if state.backend_pid, do: GenServer.stop(state.backend_pid)
    {:reply, :ok, %{state | enabled: false, backend: nil, backend_pid: nil}}
  end

  def handle_call(:status, _from, state),
    do: {:reply, %{enabled: state.enabled, backend: state.backend}, state}

  def handle_call({:put_config, config}, _from, %__MODULE__{} = state),
    do: {:reply, :ok, %__MODULE__{state | config: config}}

  @impl true
  def handle_info({:file_changed, path}, %{enabled: true} = state) do
    state = %{state | pending: MapSet.put(state.pending, path)}

    timer =
      state.timer || Process.send_after(self(), :flush, state.config.watch.debounce_ms)

    {:noreply, %{state | timer: timer}}
  end

  def handle_info({:file_changed, _path}, state), do: {:noreply, state}

  def handle_info({:expect_write, path, hash}, state) do
    {:noreply, %{state | expected: Map.put(state.expected, path, hash)}}
  end

  def handle_info(:flush, state) do
    paths = state.pending |> MapSet.to_list() |> Enum.filter(&File.regular?/1)
    state = %{state | pending: MapSet.new(), timer: nil}
    {paths, state} = drop_expected(Ignore.filter(state.workspace, paths), state)
    state = process(paths, state)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("watcher dropped unknown message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Internals

  defp do_enable(%{enabled: true, backend: backend} = state, _opts), do: {backend, state}

  defp do_enable(state, opts) do
    forced = Keyword.get(opts, :backend)

    mod =
      cond do
        forced == :polling -> PollingBackend
        forced == :file_system -> FileSystemBackend
        FileSystemBackend.available?() -> FileSystemBackend
        true -> PollingBackend
      end

    {mod, result} =
      case mod.start_link(state.workspace, self(), interval_ms: state.config.watch.poll_interval_ms) do
        {:ok, pid} ->
          {mod, {:ok, pid}}

        {:error, _} ->
          {PollingBackend,
           PollingBackend.start_link(state.workspace, self(),
             interval_ms: state.config.watch.poll_interval_ms
           )}
      end

    {:ok, pid} = result

    if mod == PollingBackend and forced != :polling do
      Events.notify(state.session_id, "watcher", :notice, %{
        text: "watch mode: native file watching unavailable (inotifywait not found); using polling"
      })
    end

    {mod.name(), %{state | enabled: true, backend: mod.name(), backend_pid: pid}}
  end

  defp drop_expected(paths, state) do
    Enum.reduce(paths, {[], state}, fn path, {keep, st} ->
      case File.read(path) do
        {:ok, content} ->
          h = hash(content)

          case Map.get(st.expected, path) do
            ^h -> {keep, %{st | expected: Map.delete(st.expected, path)}}
            _ -> {[path | keep], st}
          end

        _ ->
          {keep, st}
      end
    end)
  end

  defp process([], state), do: state

  defp process(paths, state) do
    markers =
      Enum.flat_map(paths, fn path ->
        case File.read(path) do
          {:ok, content} ->
            content |> Markers.scan() |> Enum.map(&Map.merge(&1, %{path: path, content: content}))

          _ ->
            []
        end
      end)

    triggers = Enum.filter(markers, &(&1.kind in [:change, :question]))

    if triggers == [] do
      state
    else
      kind = if Enum.any?(triggers, &(&1.kind == :change)), do: :change, else: :question
      command = if kind == :change, do: "code", else: "plan"
      context = context_markers(state.workspace, Enum.map(triggers, & &1.path))
      payload = payload(state.workspace, triggers, context)

      Log.append(state.session_id, "watcher", :watch_trigger, %{
        kind: kind,
        markers:
          Enum.map(
            triggers,
            &%{
              "path" => Path.relative_to(&1.path, state.workspace),
              "line" => &1.line,
              "text" => &1.text
            }
          )
      })

      Dispatcher.command_async(state.session_id, command, payload, :watch)
      state
    end
  end

  defp context_markers(workspace, exclude_paths) do
    workspace
    |> Ignore.candidate_files()
    |> Enum.reject(&(&1 in exclude_paths))
    |> Enum.filter(&(File.stat!(&1).size < 512_000))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} ->
          content
          |> Markers.scan()
          |> Enum.filter(&(&1.kind == :context))
          |> Enum.map(&Map.merge(&1, %{path: path, content: content}))

        _ ->
          []
      end
    end)
  end

  defp payload(workspace, triggers, context) do
    requests =
      Enum.map_join(triggers, "\n\n", fn m ->
        rel = Path.relative_to(m.path, workspace)
        "- #{rel}:#{m.line}: #{m.text}\n```\n#{Markers.context(m.content, m.line)}\n```"
      end)

    ctx =
      case context do
        [] ->
          "(none)"

        list ->
          Enum.map_join(list, "\n", fn m ->
            "- #{Path.relative_to(m.path, workspace)}:#{m.line}: #{m.text}"
          end)
      end

    """
    Triggered by AI comments in the workspace. Address each request below, then remove the processed AI marker comments as part of your edit.

    ## Requests
    #{requests}

    ## Context (bare AI comments elsewhere)
    #{ctx}
    """
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
