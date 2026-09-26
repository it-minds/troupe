defmodule Troupe do
  @moduledoc """
  The client API: start a session, feed it input, watch what happens.

  These are the only synchronous calls into a session from outside. Everything the
  agents do among themselves is async `send` plus monitors — see `ARCHITECTURE.md`
  for why (mutual calls between a parent and a child deadlock the moment both are
  busy).

      {:ok, session} = Troupe.start_session(workspace: ".")
      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "add a test for Foo.bar/1")

  """

  alias Troupe.Agent.Server, as: Agent
  alias Troupe.{Events, Mounts, Registry, Session, Sessions}
  alias Troupe.Protocol.Origin
  alias Troupe.Session.{Approvals, Blobs, Log, Questions, Watcher}
  alias Troupe.Sessions.Index

  @type session :: %{id: String.t(), pid: pid(), workspace: Troupe.Workspace.t()}

  @doc """
  Start a session over a workspace directory.

  Options: `:workspace`, `:agent` (starting profile), `:task` (a first message),
  `:session_id`, `:config_overrides`, `:definitions`, `:fake`, `:mounts`, `:bundle`
  (`%{version, hash, channel, dir}`), `:kind` (`:local` or `:team`), `:origin`,
  `:parent` (the session id this one is a branch of).
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(opts \\ []) do
    with {:ok, session_opts} <- Session.build_opts(opts),
         # Read before the tree starts. The tree appends on its way up — `agent_started`
         # among others — so by the time the first durable event is written the log is
         # not empty, and "is this a reopen" has to be asked of what was on disk before
         # any of this run's events were.
         previously <- previous_events(session_opts),
         {:ok, pid} <- Sessions.start_session(session_opts) do
      session_id = Keyword.fetch!(session_opts, :session_id)
      workspace = Keyword.fetch!(session_opts, :workspace)
      profile = Keyword.fetch!(session_opts, :profile)

      Index.register(session_id, pid, %{
        workspace: workspace.root_real,
        profile: profile,
        parent: Keyword.get(session_opts, :parent)
      })

      # The event that says what this session is, so a listing can be rebuilt from the
      # log alone — which is what makes a dormant session visible. Not the first event
      # in the file: the tree starts before this is appended and its `agent_started` is
      # already in, which has been true since stage 1.
      #
      # Only the *first*. `resume/2` is `start_session/1` with a session id, so every
      # resume used to append a second `session_created` — a log with three of them was a
      # log that had been opened three times, and a reader had no way to tell that from a
      # session that had been created three times. A resume appends `session_resumed`
      # instead, which has been in the schema since stage 2 and was never emitted.
      opened(session_id, session_opts, workspace, previously)

      # What this session may touch, and at what mode, recorded once — but only when
      # there is something to say. A local session has `session:/` and nothing else,
      # which is the default and not worth a line in every log; a session with a team or
      # org volume records it, so that what it was allowed to see is part of its history
      # even after the pod that resolved it has been replaced.
      if shared_mounts?(workspace.mounts) do
        Log.append(
          session_id,
          Session.root_path(),
          :mounts_resolved,
          Mounts.to_json(workspace.mounts)
        )
      end

      {:ok, %{id: session_id, pid: pid, workspace: workspace}}
    end
  end

  defp opened(session_id, session_opts, workspace, previously) do
    case Enum.find(previously, &(&1.type == "session_created")) do
      nil ->
        Log.append(session_id, Session.root_path(), :session_created, created_data(session_opts))
        fired(session_id, Keyword.get(session_opts, :origin))

      created ->
        Log.append(
          session_id,
          Session.root_path(),
          :session_resumed,
          resumed_data(previously, created, workspace)
        )
    end
  end

  # One event for all seven ways a session is started by something other than a person at
  # a keyboard. `session_created` already carries the origin, but as an opaque object
  # whose shape is the plane's business; this is the normalised claim a reader can group
  # by — which source, under which document, on whose authority, against which key.
  #
  # Only on creation, and only from the origin the plane sent. A resume appends nothing:
  # a session is fired once, however many times it is opened, and a second
  # `trigger_fired` would read as a second run.
  defp fired(session_id, origin) do
    case Origin.fired(origin) do
      nil -> :ok
      data -> Log.append(session_id, Session.root_path(), :trigger_fired, data)
    end
  end

  # What was on disk before this run. Empty for a session nobody has opened before,
  # which is the whole of the test for "created" against "resumed".
  defp previous_events(session_opts) do
    Log.read_session(
      Keyword.fetch!(session_opts, :session_id),
      Keyword.get(session_opts, :config, %Troupe.Config{}) |> Map.get(:state_dir)
    )
  end

  # How long it was asleep, and whether it came back somewhere else. `moved` is the field
  # Cursor's warning is about and the reason `session_resumed` carries it: a snapshot
  # preserves disk and nothing else, so a tree restored from an archive is the files and
  # not the processes, the shell history, or anything else that was running.
  defp resumed_data(previously, created, workspace) do
    %{
      "dormant_ms" => dormant_ms(previously),
      "moved" => moved?(created, workspace)
    }
  end

  defp dormant_ms([]), do: 0

  defp dormant_ms(events) do
    last = List.last(events)

    case last.ts && DateTime.from_iso8601(to_string(last.ts)) do
      {:ok, at, _offset} -> max(DateTime.diff(DateTime.utc_now(), at, :millisecond), 0)
      _ -> 0
    end
  end

  # Against what `session_created` recorded, because that is the only thing in the log
  # that claims where the session was.
  defp moved?(%{data: %{"workspace" => recorded}}, workspace) when is_binary(recorded) do
    recorded != workspace.root_real
  end

  defp moved?(_created, _workspace), do: false

  defp linked_owner do
    case Troupe.Identity.get() do
      nil -> nil
      identity -> identity.subject
    end
  end

  defp shared_mounts?(nil), do: false

  defp shared_mounts?(%Mounts{entries: entries}), do: Enum.any?(entries, &(&1.kind != :session))

  # What the session is: where, under which profile, of which kind, on which bundle,
  # and started by what. The optional fields are left out rather than written as null,
  # so a local session's first event carries the fields it always did plus its kind.
  defp created_data(session_opts) do
    workspace = Keyword.fetch!(session_opts, :workspace)
    bundle = Keyword.get(session_opts, :bundle)

    %{
      "workspace" => workspace.root_real,
      "profile" => Keyword.fetch!(session_opts, :profile),
      "visibility" => "private",
      "kind" => session_opts |> Keyword.get(:kind, :local) |> to_string()
    }
    |> put_present("bundle_version", bundle && bundle[:version] && to_string(bundle[:version]))
    # What this session was allowed to see, by name. Recorded here so the log answers
    # "what could this session have used" for as long as the log exists — without the
    # reader having to know what the bundle said that day, nor which grant the team had.
    |> put_present("entitlements", bundle && bundle[:entitlements])
    |> put_present("origin", Keyword.get(session_opts, :origin))
    # Who it belongs to. A worker is told; a daemon works it out from the link, and a
    # daemon nobody has linked leaves the field out rather than writing a username that
    # means nothing anywhere else.
    |> put_present("owner", Keyword.get(session_opts, :owner) || linked_owner())
    # The session this is a branch of. A client that groups a workspace's sessions into
    # one view reads it back from the listing; the log is where it survives dormancy.
    |> put_present("parent", Keyword.get(session_opts, :parent))
  end

  defp put_present(data, _key, nil), do: data
  defp put_present(data, key, value), do: Map.put(data, key, value)

  @doc """
  Send the root agent a message. Async: it is postponed if the agent is busy.

  `actor` records *who* asked, which is what lets several clients share one session
  and still see who did what. `:command_id` in `opts` is the caller's own identifier for
  the send, echoed in `input_queued` and `input_accepted`; one is generated when the
  caller has none.
  """
  @spec send_input(
          String.t(),
          String.t() | struct(),
          :user | :watch | :tui_todo_edit,
          Troupe.Protocol.Event.Actor.t() | nil,
          keyword()
        ) :: :ok | {:error, :no_session}
  def send_input(session_id, content, source \\ :user, actor \\ nil, opts \\ []) do
    with_root(session_id, &Agent.input(&1, source, content, actor, opts))
  end

  @doc "Cancel whatever the root agent is doing. Valid from any state."
  @spec cancel(String.t()) :: :ok | {:error, :no_session}
  def cancel(session_id), do: with_root(session_id, &Agent.cancel/1)

  @doc "Switch the root agent's primary profile, applied at the next turn boundary."
  @spec switch_profile(String.t(), String.t()) :: :ok | {:error, :no_session}
  def switch_profile(session_id, name), do: with_root(session_id, &Agent.switch_profile(&1, name))

  @doc """
  Set the session's goal: what every later turn of the root agent works towards, until it
  is cleared or replaced. The root agent writes `goal_set` under `actor`; `:command_id` in
  `opts` rides along in the event.
  """
  @spec set_goal(String.t(), String.t(), Troupe.Protocol.Event.Actor.t() | nil, keyword()) ::
          :ok | {:error, :no_session}
  def set_goal(session_id, text, actor \\ nil, opts \\ []) when is_binary(text) and text != "" do
    with_root(session_id, &Agent.set_goal(&1, text, actor, opts))
  end

  @doc "Clear the session's goal; the root agent writes `goal_cleared` if it had one."
  @spec clear_goal(String.t(), Troupe.Protocol.Event.Actor.t() | nil, keyword()) ::
          :ok | {:error, :no_session}
  def clear_goal(session_id, actor \\ nil, opts \\ []) do
    with_root(session_id, &Agent.set_goal(&1, nil, actor, opts))
  end

  @doc """
  The session's goal as its log has it — `%{text, set_by, set_at}` — or `nil`.

  Read from the events rather than asked of the agent, so a dormant session answers
  without its tree being brought back, as every read must.
  """
  @spec goal(String.t()) ::
          %{text: String.t(), set_by: String.t() | nil, set_at: String.t() | nil} | nil
  def goal(session_id) do
    root = Session.root_path()

    session_id
    |> events()
    |> Enum.reduce(nil, fn
      %{type: "goal_set", agent: ^root, data: %{"text" => text}} = event, _goal ->
        %{text: text, set_by: event.actor && event.actor.subject, set_at: event.ts}

      %{type: "goal_cleared", agent: ^root}, _goal ->
        nil

      _event, goal ->
        goal
    end)
  end

  @doc """
  Start a loop towards the session's goal (`/loop`, Decision 681): up to `:max_iterations`
  turns of the root agent (else the config's `loop_max_iterations`), each ending with the
  agent's own verdict, `goal_complete` or not. Written as `loop_started` under `actor`;
  `:command_id` rides along. A session with no goal has nothing to loop towards.
  """
  @spec start_loop(String.t(), Troupe.Protocol.Event.Actor.t() | nil, keyword()) ::
          {:ok, Troupe.Loop.t()}
          | {:error, :no_session | :no_goal | {:already_running, String.t()}}
  def start_loop(session_id, actor \\ nil, opts \\ []) do
    Troupe.Session.Loop.start(session_id, actor, opts)
  end

  @doc """
  Stop the session's loop, written as `loop_stopped` (`requested`) under `actor`, and
  cancel the root's turn if it is one of the loop's. Nothing is written when no loop runs.
  """
  @spec stop_loop(String.t(), Troupe.Protocol.Event.Actor.t() | nil, keyword()) :: :ok
  def stop_loop(session_id, actor \\ nil, opts \\ []) do
    Troupe.Session.Loop.stop(session_id, actor, opts)
  end

  @doc """
  The session's latest loop as its log has it, or `nil` if it never had one.

  Read from the events, so a dormant session answers without waking; a loop the log says
  is running in a session whose tree is not is reported as it will be recorded when the
  session is next activated, stopped and `interrupted`.
  """
  @spec loop(String.t()) :: map() | nil
  def loop(session_id) do
    case session_id |> events() |> Troupe.Loop.fold() do
      nil -> nil
      loop -> Troupe.Loop.to_json(loop, Registry.whereis({:session, session_id}) != nil)
    end
  end

  @doc "Answer a question an agent asked with `ask_user`. First answer wins."
  @spec answer(String.t(), String.t(), String.t(), Troupe.Protocol.Event.Actor.t() | nil) :: :ok
  def answer(session_id, call_id, text, actor \\ nil) do
    Questions.answer(session_id, call_id, text, actor)
  end

  @doc "Answer an outstanding approval. First response wins."
  @spec approve(
          String.t(),
          String.t(),
          :allow | :deny | :allow_session,
          Troupe.Protocol.Event.Actor.t() | nil
        ) :: :ok
  def approve(session_id, call_id, decision, actor \\ nil) do
    Approvals.decide(session_id, call_id, decision, actor)
  end

  @doc "Receive `{:troupe_event, session_id, event}` for everything the session does."
  @spec subscribe(String.t()) :: :ok
  def subscribe(session_id), do: Events.subscribe(session_id)

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id), do: Events.unsubscribe(session_id)

  @doc """
  A read-only snapshot of one agent. Never used inside the loop.

  An agent that stops between the lookup and the call, as one does when its session goes
  to sleep, is `{:error, :no_agent}` like one that was never there, so the sweeper and
  the worker that ask can't be taken down by the timing.
  """
  @spec snapshot(String.t(), [String.t()]) :: map() | {:error, :no_agent}
  def snapshot(session_id, agent_path \\ ["root"]) do
    case Registry.agent_pid(session_id, agent_path) do
      nil -> {:error, :no_agent}
      pid -> snapshot_of(pid)
    end
  end

  defp snapshot_of(pid) do
    Agent.snapshot(pid)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :no_agent}
    :exit, {{:shutdown, _}, _call} -> {:error, :no_agent}
  end

  @doc "Every live agent path in a session, root first."
  @spec agent_tree(String.t()) :: [[String.t()]]
  def agent_tree(session_id) do
    session_id
    |> Registry.agent_paths_under(["root"])
    |> Enum.sort_by(&{length(&1), &1})
  end

  @doc """
  The session's persisted events, oldest first.

  Works whether or not the session is running: a dormant session is only its log, and
  reading one must never bring an actor tree back.
  """
  @spec events(String.t()) :: [Troupe.Protocol.Event.t()]
  def events(session_id) do
    Log.replay(session_id)
  catch
    :exit, _ -> Log.read_session(session_id)
  end

  @doc "Turn watch mode on or off, reporting which backend took over."
  @spec watch(String.t(), boolean()) :: {:ok, :native | :poll | :off}
  def watch(session_id, enabled?), do: Watcher.set_enabled(session_id, enabled?)

  @doc """
  Stop a session's actor tree. Its agents, tasks and OS process trees go with it.

  The session itself is not gone: it becomes dormant, which is a state its log
  records, so a client that reconnects can tell "stopped on purpose" from "the daemon
  died".
  """
  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    # The last word before the tree comes down, and only where there is still somewhere
    # to write it. A live session does not imply a live log: the tree is `rest_for_one`
    # with `Log` first, so a session already on its way down has lost its log while its
    # supervisor is still terminating — and two callers stopping the same session, which
    # is ordinary at shutdown, race exactly there. Asking the registry for the log rather
    # than for the session is the difference between a quiet no-op and an exit in
    # whoever called this.
    if Registry.whereis({:log, session_id}) do
      Log.append(session_id, Session.root_path(), :session_dormant, %{
        "last_seq" => head_seq(session_id)
      })
    end

    Sessions.stop_session(session_id)
  catch
    # The log went between the lookup and the call. Nothing is lost that was not already
    # lost: the events are on disk and `session_dormant` is a marker, not a fact anything
    # is rebuilt from.
    :exit, {:noproc, _} -> Sessions.stop_session(session_id)
    :exit, {:normal, _} -> Sessions.stop_session(session_id)
  end

  @doc "Sessions recorded on disk for a workspace, newest first."
  @spec list_sessions(Path.t(), Path.t() | nil) :: [map()]
  def list_sessions(workspace_root, state_dir \\ nil) do
    Log.list_sessions(workspace_root, state_dir)
  end

  @doc """
  Resume a session from its log.

  Starting a session with an existing id is all it takes: every agent rebuilds its
  own state by replaying its own events. A `:task` may ride along — a worker passes
  the prompt a session was created with — and it is safe to, because the root agent
  seeds a task only when its own log is empty, so a session activated a second time
  replays its first input rather than repeating it.
  """
  @spec resume(String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(session_id, opts \\ []) do
    start_session(Keyword.put(opts, :session_id, session_id))
  end

  @doc """
  Bring a dormant session's actor tree back, or confirm it is already up.

  This is what an *activating* command does before it takes effect. Reading a session —
  listing it, replaying it, subscribing to it — deliberately does not come through
  here: a dormant session that woke up because someone looked at it would never stay
  dormant.
  """
  @spec activate(String.t()) :: {:ok, pid()} | {:error, :not_found | term()}
  def activate(session_id) do
    case Registry.whereis({:session, session_id}) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case Index.get(session_id) do
          nil -> {:error, :not_found}
          meta -> restore(session_id, meta)
        end
    end
  end

  defp restore(session_id, meta) do
    case resume(session_id, workspace: meta.workspace, agent: meta.profile) do
      {:ok, session} ->
        Log.append(session_id, Session.root_path(), :session_activated, %{
          "epoch" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "pod" => nil
        })

        {:ok, session.pid}

      error ->
        error
    end
  end

  @doc "Every session this daemon knows about, running or not."
  @spec list_live_sessions(map()) :: [map()]
  def list_live_sessions(filter \\ %{}), do: Index.list(filter)

  @doc "One session's metadata, or `nil`."
  @spec get_session(String.t()) :: map() | nil
  def get_session(session_id), do: Index.get(session_id)

  @doc "Session ids with a running actor tree."
  @spec session_ids() :: [String.t()]
  def session_ids, do: Index.live_ids()

  @doc "Whether anything is running. The daemon's idle watch asks this."
  @spec any_active_sessions?() :: boolean()
  def any_active_sessions?, do: session_ids() != []

  @doc "The highest sequence number in a session's log."
  @spec head_seq(String.t()) :: non_neg_integer()
  def head_seq(session_id) do
    Log.head_seq(session_id)
  catch
    :exit, _ ->
      case Log.read_session(session_id) do
        [] -> 0
        events -> List.last(events).seq || 0
      end
  end

  @doc "Durable events after a cursor. `0` replays everything."
  @spec replay_from(String.t(), non_neg_integer()) :: [Troupe.Protocol.Event.t()]
  def replay_from(session_id, from_seq) do
    Log.replay_from(session_id, from_seq)
  catch
    :exit, _ ->
      session_id |> Log.read_session() |> Enum.filter(&(&1.seq && &1.seq > from_seq))
  end

  @doc "Read a stored blob, optionally a byte range."
  @spec read_blob(String.t(), String.t(), [integer()] | nil) ::
          {:ok, binary(), non_neg_integer()} | {:error, :not_found}
  def read_blob(session_id, digest, range \\ nil) do
    case get_session(session_id) do
      nil -> {:error, :not_found}
      session -> Blobs.read(session_id, session.workspace, digest, range)
    end
  end

  @doc "Workspaces this daemon has seen, most recently used first."
  @spec recent_workspaces(pos_integer()) :: [map()]
  def recent_workspaces(limit \\ 20), do: Index.recent_workspaces(limit)

  @doc """
  Directories matching a query, for a launcher.

  Ranks recent workspaces above the filesystem, because the thing you want is nearly
  always somewhere you have already been.
  """
  @spec search_workspaces(String.t(), pos_integer()) :: [map()]
  def search_workspaces(query, limit \\ 20) do
    recent =
      recent_workspaces(200)
      |> Enum.filter(&String.contains?(String.downcase(&1["path"]), String.downcase(query)))
      |> Enum.map(&%{"path" => &1["path"], "score" => 1.0})

    Enum.take(recent, limit)
  end

  @doc "Mark a session exempt from retention, or not."
  @spec pin_session(String.t(), boolean()) :: :ok
  def pin_session(session_id, pinned?), do: Index.update(session_id, %{pinned: pinned?})

  @doc """
  Erase a session: stop it, delete its stored events and blobs, forget it.

  Local sessions have no key to destroy — the user's disk encryption is the boundary —
  so erasure here is deletion. The remote tier destroys the session key instead, which
  is what makes erasure survive a backup.
  """
  @spec erase_session(String.t()) :: :ok
  def erase_session(session_id) do
    session = get_session(session_id)
    stop_session(session_id)
    Index.forget(session_id)

    if session do
      session.workspace
      |> Troupe.Paths.session_dir(session_id)
      |> File.rm_rf()
    end

    :ok
  end

  @doc """
  Turn watch mode on or off for a workspace.

  Watch is exclusive per workspace: two sessions watching the same files would both
  act on the same marker.
  """
  @spec set_watch(Path.t(), boolean()) ::
          {:ok, :native | :poll | :off} | {:error, :already_watching | :no_session}
  def set_watch(workspace, enabled?) do
    sessions =
      %{}
      |> list_live_sessions()
      |> Enum.filter(&(&1.workspace == workspace and &1.state == :active))

    case sessions do
      [] ->
        {:error, :no_session}

      [session] ->
        watch(session.id, enabled?)

      [session | _rest] when enabled? ->
        if Enum.any?(sessions, &watching?(&1.id)) do
          {:error, :already_watching}
        else
          watch(session.id, enabled?)
        end

      [session | _rest] ->
        watch(session.id, enabled?)
    end
  end

  defp watching?(session_id) do
    Watcher.enabled?(session_id)
  catch
    :exit, _ -> false
  end

  defp with_root(session_id, fun) do
    case Registry.agent_pid(session_id, Session.root_path()) do
      nil -> {:error, :no_session}
      pid -> fun.(pid)
    end
  end
end
