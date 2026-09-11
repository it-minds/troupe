defmodule Troupe.Session.Watcher do
  @moduledoc """
  Watch mode: turn AI comments in files into agent input.

  Started last in the session so its crashes never restart an agent — `rest_for_one`
  makes that a structural guarantee rather than a convention. It owns a backend
  process (native or polling), debounces bursts of change events into one scan, and
  sends the root agent a single `{:input, :watch, trigger}` per scan.

  Self-triggering is prevented by the write and edit tools announcing writes before
  they happen; a change event whose current content hash matches an announcement is
  dropped.
  """

  use GenServer

  alias Troupe.{Events, Gitignore, Registry, Watch, Workspace}
  alias Troupe.Watch.{FileSystemBackend, Marker, PollBackend, Trigger}

  require Logger

  @enforce_keys [:session_id, :workspace, :agent_path]
  defstruct [
    :session_id,
    :workspace,
    :agent_path,
    :backend,
    :backend_module,
    :forced_backend,
    :timer,
    enabled?: false,
    debounce_ms: 300,
    poll_interval_ms: 1_000,
    pending: MapSet.new(),
    expected: %{},
    ignore: nil
  ]

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.watcher(session_id))
  end

  @doc """
  Which backend is running, or `:off`.

  Reported to the user on start-up, because "watch mode is polling" is something they
  need to know: it explains both the latency and the CPU.
  """
  @spec backend(String.t()) :: :native | :poll | :off
  def backend(session_id), do: GenServer.call(Registry.watcher(session_id), :backend)

  @doc "Turn watching on or off. Returns which backend is in use."
  @spec set_enabled(String.t(), boolean()) :: {:ok, :native | :poll | :off}
  def set_enabled(session_id, enabled?) do
    GenServer.call(Registry.watcher(session_id), {:set_enabled, enabled?})
  end

  @spec enabled?(String.t()) :: boolean()
  def enabled?(session_id), do: GenServer.call(Registry.watcher(session_id), :enabled?)

  @doc "Run a scan now rather than waiting for the debounce. Tests and `/watch`."
  @spec scan_now(String.t(), [Path.t()]) :: :ok
  def scan_now(session_id, paths) do
    GenServer.call(Registry.watcher(session_id), {:scan_now, paths})
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    Process.set_label("troupe watcher #{session_id}")

    state = %__MODULE__{
      session_id: session_id,
      workspace: workspace,
      agent_path: Keyword.get(opts, :agent_path, ["root"]),
      debounce_ms: Keyword.get(opts, :debounce_ms, 300),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 1_000),
      ignore: Gitignore.load(workspace.root_real),
      forced_backend: Keyword.get(opts, :backend)
    }

    if Keyword.get(opts, :enabled, false) do
      {:ok, start_backend(state)}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:set_enabled, true}, _from, %{enabled?: true} = state) do
    {:reply, {:ok, state.backend_module.name()}, state}
  end

  def handle_call({:set_enabled, true}, _from, state) do
    state = start_backend(state)
    {:reply, {:ok, state.backend_module.name()}, state}
  end

  def handle_call({:set_enabled, false}, _from, state) do
    {:reply, {:ok, :off}, stop_backend(state)}
  end

  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled?, state}

  def handle_call(:backend, _from, state) do
    {:reply, if(state.enabled?, do: state.backend_module.name(), else: :off), state}
  end

  def handle_call({:scan_now, paths}, _from, state) do
    {:reply, :ok, scan_and_trigger(%{state | pending: MapSet.new(paths)})}
  end

  @impl GenServer
  def handle_info({:watch_paths, paths}, state) do
    # Ignore rules are data read at start-up, so a `.gitignore` written or changed
    # during a session has to be picked up explicitly or the watcher keeps applying
    # yesterday's rules.
    state = if Enum.any?(paths, &gitignore?/1), do: reload_ignore(state), else: state

    interesting = Enum.filter(paths, &interesting?(state, &1))

    if interesting == [] do
      {:noreply, state}
    else
      pending = Enum.reduce(interesting, state.pending, &MapSet.put(&2, &1))
      {:noreply, debounce(%{state | pending: pending})}
    end
  end

  def handle_info(:debounced_scan, state) do
    {:noreply, scan_and_trigger(%{state | timer: nil})}
  end

  def handle_info({:expect_write, path, hash}, state) do
    {:noreply, %{state | expected: Map.put(state.expected, path, hash)}}
  end

  def handle_info({:EXIT, pid, reason}, %{backend: pid} = state) do
    # A backend that died is worth one notice and a fallback, not a session failure.
    Logger.warning("troupe: watch backend exited (#{inspect(reason)}), falling back to polling")
    notice(state, "watch backend stopped; falling back to polling")
    {:noreply, state |> Map.put(:backend, nil) |> start_backend(PollBackend)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- backend ----------------------------------------------------------------

  defp start_backend(%{forced_backend: module} = state) when module != nil do
    start_backend(state, module)
  end

  defp start_backend(state) do
    if FileSystemBackend.available?(state.workspace.root_real) do
      start_backend(state, FileSystemBackend)
    else
      notice(state, poll_notice(state))
      start_backend(state, PollBackend)
    end
  end

  defp start_backend(state, module) do
    Process.flag(:trap_exit, true)

    opts = [interval_ms: state.poll_interval_ms]

    case module.start_link(state.workspace.root_real, self(), opts) do
      {:ok, pid} ->
        %{state | backend: pid, backend_module: module, enabled?: true}

      {:error, reason} ->
        fall_back(state, module, reason)
    end
  end

  # Native watching can be present but still refuse to start. Polling always works,
  # so the only unrecoverable case is polling itself failing.
  defp fall_back(state, PollBackend, reason) do
    Logger.error("troupe: cannot start any watch backend: #{inspect(reason)}")
    notice(state, "watch could not start: #{inspect(reason)}")
    %{state | enabled?: false}
  end

  defp fall_back(state, _module, reason) do
    Logger.warning("troupe: native watcher unavailable (#{inspect(reason)}), polling instead")
    notice(state, poll_notice(state))
    start_backend(state, PollBackend)
  end

  defp poll_notice(state) do
    "watch: no native file watcher available, polling every #{state.poll_interval_ms}ms"
  end

  defp stop_backend(%{backend: nil} = state), do: %{state | enabled?: false}

  defp stop_backend(%{backend: pid} = state) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    %{state | backend: nil, backend_module: nil, enabled?: false}
  end

  # -- scanning ---------------------------------------------------------------

  defp debounce(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :debounced_scan, state.debounce_ms)}
  end

  defp scan_and_trigger(state) do
    {paths, state} = take_pending(state)
    {markers, state} = Enum.reduce(paths, {[], state}, &scan_path/2)

    if markers == [] do
      state
    else
      trigger = Trigger.new(markers, context_markers(state, markers))
      send_to_agent(state, trigger)
      state
    end
  end

  defp take_pending(state), do: {MapSet.to_list(state.pending), %{state | pending: MapSet.new()}}

  defp scan_path(path, {acc, state}) do
    case File.read(path) do
      {:ok, contents} ->
        if own_write?(state, path, contents) do
          {acc, %{state | expected: Map.delete(state.expected, path)}}
        else
          triggers =
            state.workspace
            |> Workspace.relative(path)
            |> Marker.scan(contents)
            |> Enum.filter(&(&1.kind in [:change, :question]))

          {acc ++ triggers, state}
        end

      {:error, _} ->
        {acc, state}
    end
  end

  # A write we announced, whose content still matches, is ours. Once matched the
  # expectation is consumed: a later human edit to the same file must trigger.
  defp own_write?(state, path, contents) do
    Map.get(state.expected, path) == Watch.content_hash(contents)
  end

  # Bare `AI` comments anywhere in the workspace ride along with the next trigger.
  defp context_markers(state, triggering) do
    triggering_locations = MapSet.new(triggering, &{&1.file, &1.line})

    state.workspace.root_real
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&interesting?(state, &1))
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, contents} ->
          state.workspace
          |> Workspace.relative(path)
          |> Marker.scan(contents)
          |> Enum.filter(&(&1.kind == :context))

        {:error, _} ->
          []
      end
    end)
    |> Enum.reject(&MapSet.member?(triggering_locations, {&1.file, &1.line}))
  end

  defp send_to_agent(state, trigger) do
    case Registry.agent_pid(state.session_id, state.agent_path) do
      nil ->
        Logger.debug("troupe: watch trigger with no root agent to send it to")

      pid ->
        send(pid, {:input, :watch, trigger})
    end
  end

  defp gitignore?(path), do: Path.basename(path) == ".gitignore"

  defp reload_ignore(state) do
    %{state | ignore: Gitignore.load(state.workspace.root_real)}
  end

  defp interesting?(state, path) do
    relative = Workspace.relative(state.workspace, path)

    File.regular?(path) and
      not Gitignore.ignored?(state.ignore, relative) and
      not String.starts_with?(relative, "/")
  end

  defp notice(state, message) do
    Events.publish_ephemeral(state.session_id, "watch_notice", state.agent_path, %{
      "message" => message
    })
  end
end
