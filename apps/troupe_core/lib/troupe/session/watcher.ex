defmodule Troupe.Session.Watcher do
  @moduledoc """
  Watch mode: turn AI comments in files into branches of the session.

  Started last in the session so its crashes never restart an agent — `rest_for_one`
  makes that a structural guarantee rather than a convention. It owns a backend
  process (native or polling), debounces bursts of change events into one scan, and
  starts one branch per scan (`Troupe.Watch.Branch`, Decision 844): `quick` for an
  `AI!`, `answer` for an `AI?`, never a turn of the session's own agent. The session's
  log says which file and comment started which branch (`watch_triggered`), and a
  client hears watch go on and off (`watch_changed`).

  Self-triggering is prevented by the write and edit tools announcing writes before
  they happen; a change event whose current content hash matches an announcement is
  dropped. A marker whose branch has not ended its turn is not sent again: the file is
  saved again while that branch's write waits for the person, and that is no new request.
  """

  use GenServer

  alias Troupe.{Events, Gitignore, Paths, Registry, Watch, Workspace}
  alias Troupe.Session.Log
  alias Troupe.Watch.{Branch, FileSystemBackend, Marker, PollBackend, Trigger}

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
    # A pod's session never watches (Decision 844): watching is for the files on the
    # person's own machine, and a branch it started there would be a session no plane
    # placed.
    local?: true,
    debounce_ms: 300,
    poll_interval_ms: 1_000,
    pending: MapSet.new(),
    expected: %{},
    ignore: nil,
    # `watch_auto_approve`, and what the session was started with, for its branches;
    # `dispatch` stands in for `Branch.start/2` in a test of the watcher alone.
    auto_approve: false,
    branch: [],
    dispatch: &Branch.start/2,
    # The markers a branch is working on, `{file, comment} => session id`, until it ends
    # its turn or its session goes; and the monitor on each branch's session.
    working: %{},
    monitors: %{}
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

  @doc """
  Turn watching on or off. Returns which backend is in use; a pod's session refuses
  (`:not_local`).
  """
  @spec set_enabled(String.t(), boolean()) :: {:ok, :native | :poll | :off} | {:error, :not_local}
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
      local?: Keyword.get(opts, :local, true),
      debounce_ms: Keyword.get(opts, :debounce_ms, 300),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 1_000),
      forced_backend: Keyword.get(opts, :backend),
      auto_approve: Keyword.get(opts, :auto_approve, false) == true,
      branch: Keyword.get(opts, :branch, []),
      dispatch: Keyword.get(opts, :dispatch, &Branch.start/2)
    }

    if Keyword.get(opts, :enabled, false) and state.local? do
      {:ok, start_backend(state)}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:set_enabled, true}, _from, %{local?: false} = state) do
    {:reply, {:error, :not_local}, state}
  end

  def handle_call({:set_enabled, true}, _from, %{enabled?: true} = state) do
    {:reply, {:ok, state.backend_module.name()}, state}
  end

  def handle_call({:set_enabled, true}, _from, state) do
    state = state |> start_backend() |> changed(state)
    {:reply, {:ok, backend_name(state)}, state}
  end

  def handle_call({:set_enabled, false}, _from, state) do
    {:reply, {:ok, :off}, state |> stop_backend() |> changed(state)}
  end

  def handle_call(:enabled?, _from, state), do: {:reply, state.enabled?, state}

  def handle_call(:backend, _from, state), do: {:reply, backend_name(state), state}

  def handle_call({:scan_now, paths}, _from, state) do
    {:reply, :ok, scan_and_trigger(%{with_ignore(state) | pending: MapSet.new(paths)})}
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
    {:noreply, state |> Map.put(:backend, nil) |> start_backend(PollBackend) |> changed(state)}
  end

  def handle_info({:branch_started, token, trigger, result}, state),
    do: {:noreply, started(state, token, trigger, result)}

  # A branch that ended its turn, or whose session went, has finished with its markers.
  def handle_info({:troupe_event, child, %{type: "turn_ended", agent: ["root"]}}, state),
    do: {:noreply, done_with(state, child)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {child, monitors} = Map.pop(state.monitors, ref)
    {:noreply, done_with(%{state | monitors: monitors}, child)}
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
    state = with_ignore(state)

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

    case Enum.reject(markers, &Map.has_key?(state.working, key(&1))) do
      [] -> state
      markers -> dispatch(state, Trigger.new(markers, context_markers(state, markers)))
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
    |> Paths.glob_escape()
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

  # -- the branch --------------------------------------------------------------

  # One branch per scan (Decision 844). The session starts in a task of its own, so the
  # watcher answers `enabled?` and its own shutdown while it does: the sessions' index asks
  # every watcher that as it sweeps, and a session starting asks it things back. Its
  # markers count as worked on from now.
  defp dispatch(state, trigger) do
    token = make_ref()
    watcher = self()
    start = state.dispatch

    opts =
      [
        parent: state.session_id,
        workspace: state.workspace.root_real,
        auto_approve: state.auto_approve
      ] ++
        state.branch

    {:ok, _task} =
      Task.start(fn ->
        send(watcher, {:branch_started, token, trigger, start_branch(start, trigger, opts)})
      end)

    %{state | working: Enum.reduce(trigger.markers, state.working, &Map.put(&2, key(&1), token))}
  end

  # A branch that cannot start is the trigger's failure, said in the log, never a crash.
  defp start_branch(start, trigger, opts) do
    start.(trigger, opts)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  # The branch is followed from before its input, so its turn's end is heard, and the
  # session's log says which file and comment started it, or why none could start, for a
  # client to show.
  defp started(state, token, trigger, {:ok, %{id: child, pid: pid}}) do
    :ok = Events.subscribe(child, :internal)
    triggered(state, trigger, %{"session_id" => child})
    _ = Troupe.send_input(child, trigger, :watch)

    working =
      Map.new(state.working, fn {key, id} -> {key, if(id == token, do: child, else: id)} end)

    %{state | working: working, monitors: Map.put(state.monitors, Process.monitor(pid), child)}
  end

  defp started(state, token, trigger, {:error, reason}) do
    Logger.warning("troupe: watch could not start #{Branch.agent(trigger)}: #{inspect(reason)}")
    triggered(state, trigger, %{"error" => describe(reason)})
    %{state | working: Map.reject(state.working, fn {_key, id} -> id == token end)}
  end

  defp triggered(state, trigger, outcome) do
    markers =
      Enum.map(trigger.markers, &%{"file" => &1.file, "line" => &1.line, "comment" => &1.comment})

    data =
      Map.merge(outcome, %{
        "agent" => Branch.agent(trigger),
        "mode" => Atom.to_string(trigger.mode),
        "markers" => markers
      })

    Log.append(state.session_id, state.agent_path, :watch_triggered, data)
  end

  defp key(%Marker{file: file, comment: comment}), do: {file, comment}

  defp done_with(state, nil), do: state

  defp done_with(state, child) do
    Events.unsubscribe(child)
    {gone, monitors} = Enum.split_with(state.monitors, fn {_ref, id} -> id == child end)
    Enum.each(gone, fn {ref, _id} -> Process.demonitor(ref, [:flush]) end)
    working = Map.reject(state.working, fn {_key, id} -> id == child end)
    %{state | working: working, monitors: Map.new(monitors)}
  end

  defp describe({:unknown_agent, name}), do: "there is no agent #{name}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # -- watch state ---------------------------------------------------------------

  defp backend_name(%{enabled?: true, backend_module: module}) when module != nil,
    do: module.name()

  defp backend_name(_state), do: :off

  # Whether watch is on, and how, said to every client as it changes (`watch_changed`),
  # so a status line shows what the session does rather than what that client last set.
  defp changed(state, before) do
    if backend_name(state) != backend_name(before) do
      Events.publish_ephemeral(state.session_id, "watch_changed", state.agent_path, %{
        "enabled" => state.enabled?,
        "backend" => Atom.to_string(backend_name(state))
      })
    end

    state
  end

  defp gitignore?(path), do: Path.basename(path) == ".gitignore"

  defp reload_ignore(state) do
    %{state | ignore: Gitignore.load(state.workspace.root_real)}
  end

  # The ignore rules are read the first time something needs them, a backend starting or
  # a scan asked for, and not when the session starts: reading them walks the workspace,
  # and in a home directory that is minutes, which a session that is not watching (most
  # of them) spent inside `session.create` until its client gave up (#231).
  defp with_ignore(%{ignore: nil} = state), do: reload_ignore(state)
  defp with_ignore(state), do: state

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
