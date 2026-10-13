defmodule Troupe.Sessions.Index do
  @moduledoc """
  What sessions exist, and what is true of them without opening one.

  A client needs to list sessions, and a listing must include the ones that are not
  running: a session that went dormant still exists, still has history, and still
  belongs in the fleet. So this is two sources folded together — the live registry for
  anything with an actor tree, and the state directory for everything else — with the
  live view winning where they overlap.

  It holds metadata only: workspace, profile, lifecycle state, counters. Session
  *content* is in the log and never here, which is the same rule the remote plane
  follows and the reason this can be rebuilt from logs at any time.

  It is also what puts a session to sleep. One with nothing running — idle, or waiting on
  a person — gives its actor tree back after `session_idle_ms` while somebody is watching
  it, and after the much shorter `detached_idle_ms` once nobody is. Never while a client
  is reading it (`Troupe.Events.attached?/1`): a session stopped under the person looking
  at it is a state change nobody asked for, and the clocks start when they leave. The
  whole ladder, from a running turn to the daemon's exit, with every clock's setting:
  [troupe-daemon](../../../../troupe_daemon/README.md#how-long-it-stays-up).

  None of it waits on a session (Decision 848). The sweep asks the sessions how they are
  from a task and decides here, from the answers, which to stop; a stop runs in a task of
  its own, and a session being stopped reads as dormant until its tree is gone. A read is
  answered from a task too, since a listing asks every live session's summary. Nor does a
  read wait on the file server, the one process every other file operation in the VM goes
  through: it lists the state directories and reads the logs from its task, raw (#589).

  The state directory is more than one (Decision 855): the platform's, the one the
  person's `config.yaml` names, and every one a session it was told of was started with,
  since a session's log is wherever its config put it. A dormant session's row is read
  from its log when the log is new here or has changed, by its size and time, and kept
  between listings otherwise. And an agent slow to answer the sweep is not taken for gone:
  only its tree's monitor says that.
  """

  use GenServer

  alias Troupe.{Config, Events, Paths, Registry, Session}
  alias Troupe.Protocol.Event
  alias Troupe.Session.{Approvals, Log, Questions, Summary, Watcher}
  alias Troupe.Sessions.{Pin, Unseen}

  @type meta :: %{
          id: String.t(),
          workspace: Path.t(),
          branch: String.t() | nil,
          parent: String.t() | nil,
          profile: String.t(),
          kind: String.t(),
          owner: String.t() | nil,
          state: :active | :dormant | :read_only | :erased,
          status: atom(),
          failed: %{String.t() => String.t() | nil} | nil,
          pending_approvals: non_neg_integer(),
          pending_questions: non_neg_integer(),
          unseen: Unseen.t(),
          tokens: non_neg_integer(),
          cost: float(),
          created_at: String.t() | nil,
          last_active_at: String.t() | nil,
          pinned: boolean(),
          state_dir: Path.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Record a session that has just started.

  `pid` is the session's supervisor. The index monitors it, so "live" means a tree
  that is actually running rather than one this process was once told about — a
  distinction that matters the moment a session crashes.
  """
  @spec register(String.t(), pid(), map()) :: :ok
  def register(session_id, pid, meta) do
    GenServer.cast(__MODULE__, {:register, session_id, pid, meta})
  end

  @doc "Update fields on a live session."
  @spec update(String.t(), map()) :: :ok
  def update(session_id, changes), do: GenServer.cast(__MODULE__, {:update, session_id, changes})

  @doc """
  Drop a session from the live view. Its history stays and it is listed from its log.

  Called when a tree stops on purpose; a tree that stops by crashing gets here through
  the monitor instead.
  """
  @spec dormant(String.t()) :: :ok
  def dormant(session_id), do: GenServer.cast(__MODULE__, {:dormant, session_id})

  @doc "Forget a session entirely. Only for erasure."
  @spec forget(String.t()) :: :ok
  def forget(session_id), do: GenServer.cast(__MODULE__, {:forget, session_id})

  @doc """
  Add one response's tokens and cost to a live session's running totals.

  The entry has carried `tokens` and `cost` since it was first written and nothing ever
  added to them, so every listing said 0 tokens and $0.00 however long a session had
  been working. `cost_micros` is `nil` for a response nobody priced, which adds tokens
  and leaves the cost where it was.
  """
  @spec observe(String.t(), non_neg_integer(), non_neg_integer() | nil) :: :ok
  def observe(session_id, tokens, cost_micros) do
    GenServer.cast(__MODULE__, {:observe, session_id, tokens, cost_micros})
  end

  @doc "One session's metadata, live or dormant, or `nil`."
  @spec get(String.t()) :: meta() | nil
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @doc """
  Every session this daemon knows about, newest first.

  `filter` may carry `"state"` (a list of state strings), `"workspace"` and `"parent"`
  (a session id: the sessions made as branches of that one).
  """
  @spec list(map()) :: [meta()]
  def list(filter \\ %{}), do: GenServer.call(__MODULE__, {:list, filter}, 15_000)

  @doc """
  The agent a session's root was last switched to, from its log's events, or `nil` when
  it never was (Decision 841): what its listing says it runs, beside the one it was
  created with.
  """
  @spec switched_to([Troupe.Protocol.Event.t()]) :: String.t() | nil
  def switched_to(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: "profile_switched", agent: ["root"], data: %{"to" => to}} -> to
      _other -> nil
    end)
  end

  @doc "Session ids with a running actor tree."
  @spec live_ids() :: [String.t()]
  def live_ids, do: GenServer.call(__MODULE__, :live_ids)

  @doc """
  The live sessions with a turn at work, as the sweep reads them: an agent that is busy,
  or does not say. Idle, done, or parked on a person is not at work, for the same reason
  the sweep may stop it: nothing is running to lose. What `daemon.stop` waits on (Decision
  865). Each session is asked from the calling process, never from this one (Decision 848).
  """
  @spec at_work() :: [String.t()]
  def at_work, do: Enum.filter(live_ids(), &(agent_state(&1) in [:busy, :unknown]))

  @doc """
  Every state directory sessions are kept under, as far as this daemon knows (Decision
  855): the platform's, the one `config.yaml` named when it started, and each one a session
  it was told of was started with. Where a session that is not running is looked for.
  """
  @spec roots() :: [Path.t()]
  def roots, do: GenServer.call(__MODULE__, :roots)

  @doc "Workspaces this daemon has seen, most recently used first."
  @spec recent_workspaces(pos_integer()) :: [map()]
  def recent_workspaces(limit \\ 20), do: GenServer.call(__MODULE__, {:recent, limit}, 15_000)

  # How long a session may sit with nothing to do before its actor tree is stopped.
  # Its log stays; subscribing to it still serves history; the next activating command
  # brings the tree back. Waiting on a person is nothing to do: an approval or a question
  # is durable, and is asked again when the tree comes back.
  @default_idle_ms 30 * 60 * 1000
  # The same for a session nobody is watching, which has nobody to notice it sleep and
  # keeps a laptop awake until it does. Shorter than a tool's own timeout (three minutes),
  # so a call waiting on a person is still outstanding when the tree comes down, and is
  # asked again on the way back rather than failed as timed out.
  @default_detached_ms 2 * 60 * 1000
  @sweep_ms 15_000

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe session index")

    idle_ms =
      Keyword.get_lazy(opts, :session_idle_ms, fn ->
        Application.get_env(:troupe_core, :session_idle_ms, @default_idle_ms)
      end)

    # Never longer than the watched clock: nobody looking is less reason to keep a tree,
    # not more. `:infinity` sorts after every number, so this is also "never" only when
    # both are.
    detached_ms =
      opts
      |> Keyword.get_lazy(:detached_idle_ms, fn ->
        Application.get_env(:troupe_core, :detached_idle_ms, @default_detached_ms)
      end)
      |> min(idle_ms)

    sweep_ms =
      Keyword.get_lazy(opts, :sweep_ms, fn ->
        Application.get_env(:troupe_core, :session_sweep_ms, @sweep_ms)
      end)
    if detached_ms != :infinity, do: Process.send_after(self(), :sweep, sweep_ms)

    # Where the sweep, the stops and the reads run, so that this process never waits on one.
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok,
     %{
       live: %{},
       monitors: %{},
       tasks: tasks,
       sweeper: nil,
       stops: %{},
       state_dir: Keyword.get(opts, :state_dir),
       configured: configured(opts),
       roots: MapSet.new(),
       # A dormant session's row by its log's path, with the stamp it was read at. Written
       # by the reads' tasks, so public; this process owns it and never reads it.
       rows: :ets.new(:troupe_session_rows, [:set, :public, read_concurrency: true]),
       idle_ms: idle_ms,
       detached_ms: detached_ms,
       sweep_ms: sweep_ms
     }}
  end

  # The state directory the person's `config.yaml` names, read once as this starts: a
  # session started under another one later says so when it is registered. `:user_path` is
  # the file, for a test. A config that cannot be read names none.
  defp configured(opts) do
    case Config.resolve(nil, [], Keyword.take(opts, [:user_path])) do
      {:ok, config, _layers} -> config.state_dir
      {:error, _error} -> nil
    end
  rescue
    _ -> nil
  end

  @impl GenServer
  def handle_cast({:register, session_id, pid, meta}, state) do
    entry =
      meta
      |> Map.put(:id, session_id)
      |> Map.put_new(:state, :active)
      |> Map.put_new(:status, :idle)
      |> Map.put_new(:tokens, 0)
      |> Map.put_new(:cost, 0.0)
      |> Map.put_new(:pinned, false)
      |> Map.put_new(:created_at, timestamp())
      |> Map.put(:last_active_at, timestamp())
      # Idle from the moment it exists: a session created and never spoken to is the
      # commonest way one sits there holding an actor tree for nothing.
      |> Map.put(:idle_since, now_ms())

    ref = Process.monitor(pid)

    {:noreply,
     state
     |> put_in([:live, session_id], entry)
     |> put_in([:monitors, ref], session_id)
     |> remember(Map.get(meta, :state_dir))}
  end

  def handle_cast({:update, session_id, changes}, state) do
    case Map.fetch(state.live, session_id) do
      {:ok, entry} ->
        merged = entry |> Map.merge(changes) |> Map.put(:last_active_at, timestamp())
        {:noreply, put_in(state.live[session_id], merged)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:observe, session_id, tokens, cost_micros}, state) do
    case Map.fetch(state.live, session_id) do
      {:ok, entry} ->
        added = (cost_micros || 0) / 1_000_000

        merged = %{
          entry
          | tokens: Map.get(entry, :tokens, 0) + tokens,
            cost: Map.get(entry, :cost, 0.0) + added,
            last_active_at: timestamp()
        }

        {:noreply, put_in(state.live[session_id], merged)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:dormant, session_id}, state), do: {:noreply, drop(state, session_id)}

  def handle_cast({:forget, session_id}, state), do: {:noreply, drop(state, session_id)}

  @impl GenServer
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, state.sweep_ms)
    {:noreply, start_sweep(state)}
  end

  def handle_info({:probed, session_id, facts}, state) do
    {:noreply, sweep_session(state, session_id, facts)}
  end

  # A task's answer: the sweep's, or a stop's.
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, task_done(state, ref, result)}
  end

  # A tree that is gone drops its entry, unless the session was started again since and the
  # entry is the new tree's (Decision 855): a command that waited on a stop wakes the
  # session at once, and its registration may be here before the old tree's monitor is.
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, task_done(state, ref, {:exit, reason})}

      {session_id, monitors} ->
        state = %{state | monitors: monitors}

        if session_id in Map.values(monitors),
          do: {:noreply, state},
          else: {:noreply, drop(state, session_id)}
    end
  end

  # State directories a read found gone, forgotten unless a running session is under one.
  def handle_info({:roots_gone, gone}, state) do
    used =
      for {_id, entry} <- state.live, into: MapSet.new(), do: root(Map.get(entry, :state_dir))

    forgotten = MapSet.difference(MapSet.new(gone), used)
    {:noreply, %{state | roots: MapSet.difference(state.roots, forgotten)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # One task asks each session in turn what this process used to ask it, and sends each
  # answer back as soon as it has it, so the answer is as fresh when it is acted on as it
  # was. A sweep still asking when the next is due is left to finish: a session slow to
  # answer delays the sweep after it, and nobody's call. One being stopped is not asked.
  defp start_sweep(%{sweeper: nil} = state) do
    index = self()

    case for {id, entry} <- state.live, not stopping?(entry), do: id do
      [] ->
        state

      ids ->
        task =
          Task.Supervisor.async_nolink(state.tasks, fn ->
            Enum.each(ids, &send(index, {:probed, &1, probe(&1)}))
          end)

        %{state | sweeper: task.ref}
    end
  end

  defp start_sweep(state), do: state

  defp probe(session_id) do
    if Events.attached?(session_id),
      do: :attached,
      else: {watched?(session_id), agent_state(session_id)}
  end

  # A session with nothing to do for long enough gives its actor tree back. Idleness
  # is asked of the agent rather than inferred from events, because "nothing has been
  # logged lately" is also true of an agent waiting on a twenty-minute test run.
  #
  # Not while a client is reading it, whatever the clocks say. Both start again from the
  # sweep after it leaves, so a session read for an hour and left is on the same footing
  # as one that went quiet the moment its reader went.
  defp sweep_session(state, session_id, facts) do
    case {Map.fetch(state.live, session_id), facts} do
      {{:ok, %{stopping: true}}, _facts} ->
        state

      {{:ok, entry}, :attached} ->
        put_in(state.live[session_id], Map.merge(entry, %{idle_since: nil, unwatched_since: nil}))

      {{:ok, entry}, {watched?, agent}} ->
        sweep_live(state, session_id, watch(entry, watched?), agent)

      {:error, _facts} ->
        state
    end
  end

  defp sweep_live(state, session_id, entry, :busy) do
    put_in(state.live[session_id], Map.put(entry, :idle_since, nil))
  end

  # An agent that did not say how it is decides nothing: asked again at the next sweep, on
  # the clocks it had. A tree that has really gone is dropped by its monitor.
  defp sweep_live(state, session_id, entry, :unknown), do: put_in(state.live[session_id], entry)

  # Idle, or parked on a person: the same here, since neither has anything running to lose.
  defp sweep_live(state, session_id, entry, _idle_or_parked) do
    now = now_ms()
    entry = Map.put(entry, :idle_since, Map.get(entry, :idle_since) || now)

    if due?(state, entry, now) do
      stop(state, session_id, entry)
    else
      put_in(state.live[session_id], entry)
    end
  end

  # In a task, since a tree can take thirty seconds to come down, and marked meanwhile: a
  # session being stopped is read from its log as dormant, and no sweep asks about it or
  # stops it again. Its monitor drops it once the tree has gone.
  defp stop(state, session_id, entry) do
    task = Task.Supervisor.async_nolink(state.tasks, fn -> stop_session(session_id) end)

    %{
      state
      | live: Map.put(state.live, session_id, Map.put(entry, :stopping, true)),
        stops: Map.put(state.stops, task.ref, session_id)
    }
  end

  defp stop_session(session_id) do
    Troupe.stop_session(session_id)
  catch
    :exit, reason -> {:error, reason}
  end

  defp task_done(%{sweeper: ref} = state, ref, _result), do: %{state | sweeper: nil}

  defp task_done(state, ref, result) do
    case Map.pop(state.stops, ref) do
      {nil, _stops} -> state
      {session_id, stops} -> stopped(%{state | stops: stops}, session_id, result)
    end
  end

  # A stop that did not happen leaves a tree running, which is live again and the next
  # sweep's to ask about, on a clock started afresh.
  defp stopped(state, _session_id, :ok), do: state

  defp stopped(state, session_id, _failed) do
    case Map.fetch(state.live, session_id) do
      {:ok, %{stopping: true} = entry} ->
        put_in(
          state.live[session_id],
          entry |> Map.delete(:stopping) |> Map.put(:idle_since, nil)
        )

      _gone_or_new ->
        state
    end
  end

  defp stopping?(entry), do: Map.get(entry, :stopping, false)

  # On the long clock whoever is watching, or on the short one once nobody has been
  # watching for that long either.
  defp due?(state, %{idle_since: idle_since} = entry, now) do
    unwatched_since = Map.get(entry, :unwatched_since)

    now - idle_since >= state.idle_ms or
      (unwatched_since != nil and now - max(idle_since, unwatched_since) >= state.detached_ms)
  end

  # When the sweep first found nobody watching, so the short clock runs from whichever
  # came later — going quiet, or the last viewer leaving — and a client that reconnects
  # within a sweep or two finds its session where it left it.
  defp watch(entry, watched?) do
    if watched?,
      do: Map.put(entry, :unwatched_since, nil),
      else: Map.put(entry, :unwatched_since, Map.get(entry, :unwatched_since) || now_ms())
  end

  # A client follows it, or it is in watch mode — a person's editor rather than a client,
  # and one that stops being watched when the tree stops.
  defp watched?(session_id) do
    Events.watched?(session_id) or Watcher.enabled?(session_id)
  catch
    :exit, _ -> false
  end

  # Unknown, not gone, when the agent does not answer within a snapshot's five seconds or is
  # not there to ask (Decision 855): one busy past the timeout, or between two restarts of
  # its Node, is still a running tree, and taken for gone it was dropped from this index,
  # listed as dormant while it ran, and never swept again.
  defp agent_state(session_id) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] -> at_rest(session_id)
      %{state: state} when state in [:acting, :waiting] -> parked_or_busy(session_id)
      %{state: _} -> :busy
      _ -> :unknown
    end
  catch
    :exit, _ -> :unknown
  end

  # Waiting on a person and on nothing else: the root agent has asked something — an
  # approval, a question, the budget's own question (Decision 660) — and every task it has
  # running is one of the askers. Only the root's own calls are asked again when the tree
  # comes back; a delegation comes back interrupted, so a session with a subagent at work is
  # busy, and a subagent's question times out with its tool as it always has. One that
  # finished or ran out of budget is not at work: what it had to say is already its
  # delegation's result (#134), and its parent stops it on taking that (#171), so all it
  # can be here is `:done` for the moment in between.
  defp parked_or_busy(session_id) do
    root = Session.root_path()

    asked =
      (Approvals.pending(session_id) ++ Questions.pending(session_id))
      |> Enum.count(&(&1.agent_path == root))

    subagents = Troupe.agent_tree(session_id) -- [root]

    parked? =
      asked > 0 and Enum.all?(subagents, &done_agent?(session_id, &1)) and
        length(Task.Supervisor.children(Registry.tasks(session_id, root))) <= asked

    if parked?, do: :parked, else: :busy
  catch
    :exit, _ -> :busy
  end

  defp done_agent?(session_id, path), do: match?(%{state: :done}, Troupe.snapshot(session_id, path))

  # A root at rest while a subagent it started in the background still works (Decision 853)
  # is not idle: the subagent's end is its next turn, and a sleep would stop it.
  defp at_rest(session_id) do
    subagents = Troupe.agent_tree(session_id) -- [Session.root_path()]
    if Enum.all?(subagents, &done_agent?(session_id, &1)), do: :idle, else: :busy
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A session that is no longer running is no longer live, full stop. Its metadata
  # comes back from its log on the next listing, which is the only copy that survives
  # a restart anyway — so there is nothing here worth keeping stale.
  defp drop(state, session_id) do
    %{state | live: Map.delete(state.live, session_id)}
  end

  # A state directory a session was started with, read from once it is dormant. The
  # platform's is read anyway.
  defp remember(state, state_dir) when is_binary(state_dir) and state_dir != "",
    do: %{state | roots: MapSet.put(state.roots, root(state_dir))}

  defp remember(state, _state_dir), do: state

  # Every state directory a session may be under: this index's own first, the platform's
  # unless it was given another, then the one `config.yaml` names, if it names one.
  defp roots(state) do
    [state.state_dir | Enum.reject([state.configured | MapSet.to_list(state.roots)], &is_nil/1)]
    |> Enum.map(&root/1)
    |> Enum.uniq()
  end

  # With `/` for `\`, as a glob reads it on every host (`Paths.glob_escape/1`): one
  # directory spelt two ways is one root, and `File.dir?/1` finds it on Linux too.
  defp root(state_dir),
    do: state_dir |> Paths.state_dir() |> String.replace("\\", "/") |> Path.expand()

  @impl GenServer
  def handle_call({:get, session_id}, from, state) do
    read(state, from, &(live(&1, session_id) || from_disk(&1, session_id)))
  end

  def handle_call({:list, filter}, from, state) do
    read(state, from, fn view ->
      view |> all() |> apply_filter(filter) |> Enum.map(&(live(view, &1.id, &1) || &1))
    end)
  end

  def handle_call(:live_ids, _from, state) do
    {:reply, for({id, %{state: :active}} <- readable(state), do: id), state}
  end

  def handle_call(:roots, _from, state), do: {:reply, roots(state), state}

  def handle_call({:recent, limit}, from, state) do
    read(state, from, fn view ->
      view
      |> all()
      |> Enum.group_by(& &1.workspace)
      |> Enum.map(fn {workspace, sessions} ->
        %{
          "path" => workspace,
          "sessions" => length(sessions),
          "last_used_at" => sessions |> Enum.map(& &1.last_active_at) |> Enum.max(fn -> nil end)
        }
      end)
      |> Enum.sort_by(& &1["last_used_at"], :desc)
      |> Enum.take(limit)
    end)
  end

  # Answered from a task, over what this process holds as it is asked: a read goes through
  # logs on disk and each live session's summary, and neither the next caller nor the sweep
  # waits on that (Decision 848). A session being stopped is read from its log.
  defp read(state, from, answer) do
    view = %{live: readable(state), roots: roots(state), rows: state.rows, index: self()}

    {:ok, _pid} =
      Task.Supervisor.start_child(state.tasks, fn -> GenServer.reply(from, answer.(view)) end)

    {:noreply, state}
  end

  defp readable(state), do: Map.reject(state.live, fn {_id, entry} -> stopping?(entry) end)

  # A running session's entry, with the approvals and questions it has open read when it
  # is asked for: from the session's own summary projection, which already follows every
  # way an approval (#142) or a question (#162) ends and is what a worker reports to the
  # plane from. Nothing here hears the session's events, so a count kept here would be one
  # more reader to get it wrong. What nobody has seen of it is read from its log the same
  # way: `listed` is the listing's own scan of that log, already done, and `get` reads it
  # now, only when nobody is attached (`Unseen`). A turn that failed is the listing's scan
  # alone to say: a session stops on one, so `get` finds it on disk.
  defp live(view, session_id, listed \\ nil) do
    case Map.fetch(view.live, session_id) do
      {:ok, entry} ->
        entry
        |> put_asked(Summary.snapshot(session_id))
        |> waiting()
        |> Map.put(:unseen, (listed && Map.get(listed, :unseen)) || unseen(session_id))
        |> Map.put(:failed, listed && Map.get(listed, :failed))
        |> Map.put(
          :pinned,
          if(listed, do: Map.get(listed, :pinned, false), else: pinned(session_id))
        )

      :error ->
        nil
    end
  end

  defp unseen(session_id) do
    path = Log.path(session_id)
    Unseen.of(session_id, Path.dirname(path), fn -> Log.read_file(path) end)
  catch
    :exit, _ -> Unseen.none()
  end

  # The pin beside the log, which a session pinned while it was dormant woke with.
  defp pinned(session_id) do
    session_id |> Log.path() |> Path.dirname() |> Pin.pinned?()
  catch
    :exit, _ -> false
  end

  defp put_asked(meta, summary) do
    meta
    |> Map.put(:pending_approvals, summary |> Map.get("approvals", []) |> length())
    |> Map.put(:pending_questions, summary |> Map.get("questions", []) |> length())
  end

  # `waiting` outranks whatever else a listing would say, as it does in what a worker
  # reports: a session with an approval or a question open is waiting on a person,
  # whatever its agent is doing meanwhile. So a local row and a plane's row say the same
  # of it.
  defp waiting(%{pending_approvals: approvals, pending_questions: questions} = meta)
       when approvals > 0 or questions > 0,
       do: %{meta | status: :waiting}

  defp waiting(meta), do: meta

  # Live entries win: a session with a running tree knows more about itself than its
  # log's first event does. What nobody has seen of it, a turn that failed, and the pin
  # beside it are the log's directory's to say either way.
  defp all(view) do
    disk = Map.new(scan_disk(view), &{&1.id, &1})

    disk
    |> Map.merge(view.live, fn _id, from_disk, live ->
      Map.merge(live, Map.take(from_disk, [:unseen, :failed, :pinned]))
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.last_active_at, :desc)
  end

  defp apply_filter(sessions, filter) do
    sessions
    |> filter_by(filter, "state", fn session, states ->
      to_string(session.state) in List.wrap(states)
    end)
    |> filter_by(filter, "workspace", fn session, workspace ->
      session.workspace == workspace
    end)
    |> filter_by(filter, "parent", fn session, parent ->
      Map.get(session, :parent) == parent
    end)
  end

  defp filter_by(sessions, filter, key, predicate) do
    case Map.get(filter, key) do
      nil -> sessions
      value -> Enum.filter(sessions, &predicate.(&1, value))
    end
  end

  # A dormant session is only its log, so its metadata comes from the log's own first
  # and last events rather than from anything this process remembered: in every state
  # directory a session may be under (Decision 855).
  defp scan_disk(view) do
    found = for root <- present(view), path <- logs(root, "*"), do: {root, path}

    forget_rows(view.rows, MapSet.new(found, &elem(&1, 1)))
    Enum.flat_map(found, fn {root, path} -> dormant(view, root, path) end)
  end

  # The id is a name, not a pattern: escaped, so `*` finds no session rather than the
  # first one on disk (#97).
  defp from_disk(view, session_id) do
    Enum.find_value(present(view), fn root ->
      root
      |> logs(Paths.glob_escape(session_id))
      |> Enum.find_value(&(view |> dormant(root, &1) |> List.first()))
    end)
  end

  # Without the file server, as is everything a read does on disk (#589): a listing goes
  # through every session directory, and through the file server under load each of those
  # thousands of calls waited behind every other process's file operations.
  defp logs(root, id_pattern) do
    [Paths.glob_escape(root), "sessions", "*", id_pattern, "events.jsonl"]
    |> Path.join()
    |> Paths.wildcard()
  end

  # The state directories that are there; this process is told of the ones that are not.
  defp present(view) do
    {present, gone} = Enum.split_with(view.roots, &File.dir?(&1, [:raw]))
    if gone != [], do: send(view.index, {:roots_gone, gone})
    present
  end

  # A dormant session's row, read from its log only when the log is new here or has changed
  # since it was read: by its size and time, and by the `seen` mark beside it, whose value
  # is read each time, a few bytes. A listing of thousands of dormant sessions reads none
  # of their logs again (Decision 855). Whether a client is attached is asked every time,
  # since that is not on disk.
  defp dormant(view, root, path) do
    dir = Path.dirname(path)
    mark = Unseen.mark(dir)
    stamp = {file_stamp(path), mark}

    rows =
      case :ets.lookup(view.rows, path) do
        [{^path, ^stamp, rows}] ->
          rows

        _changed_or_new ->
          rows = meta_from_log(root, path, mark)
          :ets.insert(view.rows, {path, stamp, rows})
          rows
      end

    # The pin is read each time, a file's presence: it changes without the log changing.
    pinned = Pin.pinned?(dir)
    Enum.map(rows, &%{&1 | unseen: Unseen.unseen_now(&1.id, &1.unseen), pinned: pinned})
  end

  defp file_stamp(path) do
    case :file.read_file_info(path, [:raw, time: :posix]) do
      {:ok, info} ->
        %File.Stat{size: size, mtime: mtime} = File.Stat.from_record(info)
        {size, mtime}

      {:error, _} ->
        nil
    end
  end

  # The rows of logs a listing no longer finds: an erased session's, or one whose directory
  # went.
  defp forget_rows(rows, found) do
    rows
    |> :ets.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.reject(&MapSet.member?(found, &1))
    |> Enum.each(&:ets.delete(rows, &1))
  end

  defp meta_from_log(root, path, mark) do
    case Log.read_file(path) do
      [] ->
        []

      events ->
        first = List.first(events)
        last = List.last(events)
        created = Enum.find(events, &(&1.type == "session_created"))

        id = Path.basename(Path.dirname(path))

        meta = %{
          id: id,
          workspace: get_data(created, "workspace", "(unknown)"),
          branch: get_data(created, "branch", nil),
          parent: get_data(created, "parent", nil),
          profile: switched_to(events) || get_data(created, "profile", "build"),
          kind: get_data(created, "kind", "local"),
          owner: get_data(created, "owner", nil),
          state: :dormant,
          status: status_from_log(events),
          failed: failed_from_log(events),
          unseen: Unseen.since_mark(mark, fn -> events end),
          tokens: total_tokens(events),
          cost: total_cost(events),
          created_at: first.ts,
          last_active_at: last.ts,
          pinned: false,
          state_dir: root
        }

        [meta |> put_asked(root_asked(events)) |> waiting()]
    end
  end

  # The root agent's approvals and questions still open, folded by the summary
  # projection's own rules: an approval ends with its decision, a question with its
  # answer, and either with its call's `tool_call_completed` or with a cancel. The root's
  # alone, like the status below, because those are what it asks again when it wakes; a
  # delegation comes back interrupted, and what its subagent asked is owed to nobody.
  defp root_asked(events) do
    events
    |> Enum.filter(&(&1.agent == Session.root_path()))
    |> Enum.reduce(Summary.empty(), &Summary.fold(&2, &1))
  end

  # What a session was in the middle of when it stopped, read from the log alone. A
  # tool call that started and never finished, or a request the model never answered,
  # is a session that was interrupted — and a client has to be able to see that before
  # anything has been restarted. One whose open calls were all waiting on a person was
  # not: it asks again when it wakes, so it is still waiting.
  #
  # The root agent's part of the log only. A subagent's `finish` does not finish the
  # session, and a subagent a cancel took down leaves calls open in its own log that
  # nobody owes anything.
  defp status_from_log(events) do
    root = Enum.filter(events, &(&1.agent == Session.root_path()))
    open = open_calls(root)
    asked = asked_of_a_person(root)

    cond do
      done?(root) -> :done
      open != [] and Enum.all?(open, &MapSet.member?(asked, &1)) -> :waiting
      open != [] -> :interrupted
      unanswered_request?(root) -> :interrupted
      MapSet.member?(asked, owed_gate_question(root)) -> :waiting
      true -> :idle
    end
  end

  # How the root agent's last turn failed, when the harness ended it so: a root that kept
  # crashing ends its turn `agent_failed`, with the first line of what it raised, and the
  # session stops on it (Decision 727). Read from the log like the status, so a client
  # that was not watching learns it from a listing; nil once another turn has started.
  defp failed_from_log(events) do
    events
    |> Enum.filter(
      &(&1.agent == Session.root_path() and
          &1.type in ["user_input", "turn_ended", "cancelled", "agent_done"])
    )
    |> List.last()
    |> case do
      %Event{type: "turn_ended", data: %{"reason" => "agent_failed"} = data} ->
        %{"reason" => "agent_failed", "detail" => Map.get(data, "detail")}

      _ ->
        nil
    end
  end

  # The last word on it, since a finished root is woken by the next input.
  defp done?(events) do
    events
    |> Enum.filter(&(&1.type in ["agent_done", "agent_woken"]))
    |> List.last()
    |> case do
      %Event{type: "agent_done"} -> true
      _ -> false
    end
  end

  # Started and never finished, since the last cancel: a cancel ends every call it finds.
  defp open_calls(events) do
    events
    |> Enum.reduce(MapSet.new(), fn
      %Event{type: "tool_call_started", data: %{"call_id" => id}}, open -> MapSet.put(open, id)
      %Event{type: "tool_call_completed", data: %{"call_id" => id}}, open -> MapSet.delete(open, id)
      %Event{type: "cancelled"}, _open -> MapSet.new()
      _event, open -> open
    end)
    |> MapSet.to_list()
  end

  # An approval requested and not decided, or a question asked and not answered, since the
  # last cancel: what the agent itself asks again when it comes back.
  defp asked_of_a_person(events) do
    Enum.reduce(events, MapSet.new(), fn
      %Event{type: type, data: %{"call_id" => id}}, asked
      when type in ["approval_requested", "question_asked"] ->
        MapSet.put(asked, id)

      %Event{type: type, data: %{"call_id" => id}}, asked
      when type in ["approval_decided", "question_answered"] ->
        MapSet.delete(asked, id)

      %Event{type: "cancelled"}, _asked ->
        MapSet.new()

      _event, asked ->
        asked
    end)
  end

  # The id of the question still owed at the gate before the next model call, if one is:
  # the budget's (Decision 660) or the failure guard's (Decision 687).
  defp owed_gate_question(events) do
    Enum.reduce(events, nil, fn
      %Event{type: type, data: %{"call_id" => id}}, _owed
      when type in ["budget_ask_started", "tool_failures_ask_started"] ->
        id

      %Event{type: type}, _owed
      when type in ["budget_ask_answered", "tool_failures_ask_answered"] ->
        nil

      _event, owed ->
        owed
    end)
  end

  defp unanswered_request?(events) do
    events
    |> Enum.filter(&(&1.type in ["llm_request", "llm_response", "llm_error", "cancelled"]))
    |> List.last()
    |> case do
      %Event{type: "llm_request"} -> true
      _ -> false
    end
  end

  defp get_data(nil, _key, default), do: default
  defp get_data(%Event{data: data}, key, default), do: Map.get(data, key, default)

  # A model call's figures are on its `llm_response`, and the summariser's on the
  # `compacted` that took its answer (Decision 769), and a call the agent stopped on the
  # `llm_error` or `cancelled` that says so (Decision 788), as the running total counted
  # them.
  defp total_tokens(events) do
    Enum.reduce(events, 0, fn
      %Event{type: type, data: %{"usage" => %{} = usage}}, acc
      when type in ["llm_response", "compacted"] ->
        acc + Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)

      %Event{type: type, data: %{"stopped" => %{"usage" => %{} = usage}}}, acc
      when type in ["llm_error", "cancelled"] ->
        acc + Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)

      _event, acc ->
        acc
    end)
  end

  # What a dormant session cost, from its log rather than from a running total nobody
  # kept. A response the gateway did not price and this machine could not price either
  # adds nothing, which is why a listing can show tokens against no cost.
  defp total_cost(events) do
    Enum.reduce(events, 0.0, fn
      %Event{type: type, data: %{"gateway" => %{"cost_micros" => micros}}}, acc
      when type in ["llm_response", "compacted"] and is_integer(micros) ->
        acc + micros / 1_000_000

      %Event{type: type, data: %{"stopped" => %{"gateway" => %{"cost_micros" => micros}}}}, acc
      when type in ["llm_error", "cancelled"] and is_integer(micros) ->
        acc + micros / 1_000_000

      _event, acc ->
        acc
    end)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
