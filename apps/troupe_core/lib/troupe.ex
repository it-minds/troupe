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
  alias Troupe.Session.{Approvals, Blobs, Log, Watcher}
  alias Troupe.Sessions.Index

  @type session :: %{id: String.t(), pid: pid(), workspace: Troupe.Workspace.t()}

  @doc """
  Start a session over a workspace directory.

  Options: `:workspace`, `:agent` (starting profile), `:task` (a first message),
  `:session_id`, `:config_overrides`, `:definitions`, `:fake`, `:mounts`, `:bundle`
  (`%{version, hash, channel, dir}`), `:kind` (`:local` or `:team`), `:origin`.
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(opts \\ []) do
    with {:ok, session_opts} <- Session.build_opts(opts),
         {:ok, pid} <- Sessions.start_session(session_opts) do
      session_id = Keyword.fetch!(session_opts, :session_id)
      workspace = Keyword.fetch!(session_opts, :workspace)
      profile = Keyword.fetch!(session_opts, :profile)

      Index.register(session_id, pid, %{workspace: workspace.root_real, profile: profile})

      # The first durable event says what this session is, so a listing can be
      # rebuilt from the log alone — which is what makes a dormant session visible.
      Log.append(session_id, Session.root_path(), :session_created, created_data(session_opts))

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
    |> put_present("origin", Keyword.get(session_opts, :origin))
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

  @doc "A read-only snapshot of one agent. Never used inside the loop."
  @spec snapshot(String.t(), [String.t()]) :: map() | {:error, :no_agent}
  def snapshot(session_id, agent_path \\ ["root"]) do
    case Registry.agent_pid(session_id, agent_path) do
      nil -> {:error, :no_agent}
      pid -> Agent.snapshot(pid)
    end
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
    if Registry.whereis({:session, session_id}) do
      Log.append(session_id, Session.root_path(), :session_dormant, %{
        "last_seq" => head_seq(session_id)
      })
    end

    Sessions.stop_session(session_id)
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
