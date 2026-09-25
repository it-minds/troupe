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
  """

  use GenServer

  alias Troupe.Paths
  alias Troupe.Protocol.Event
  alias Troupe.Session.Log

  @type meta :: %{
          id: String.t(),
          workspace: Path.t(),
          branch: String.t() | nil,
          parent: String.t() | nil,
          profile: String.t(),
          state: :active | :dormant | :read_only | :erased,
          status: atom(),
          tokens: non_neg_integer(),
          cost: float(),
          created_at: String.t() | nil,
          last_active_at: String.t() | nil,
          pinned: boolean()
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

  @doc "Session ids with a running actor tree."
  @spec live_ids() :: [String.t()]
  def live_ids, do: GenServer.call(__MODULE__, :live_ids)

  @doc "Workspaces this daemon has seen, most recently used first."
  @spec recent_workspaces(pos_integer()) :: [map()]
  def recent_workspaces(limit \\ 20), do: GenServer.call(__MODULE__, {:recent, limit}, 15_000)

  # How long a session may sit with nothing to do before its actor tree is stopped.
  # Its log stays; subscribing to it still serves history; the next activating command
  # brings the tree back.
  @default_idle_ms 30 * 60 * 1000
  @sweep_ms 15_000

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe session index")

    idle_ms =
      Keyword.get_lazy(opts, :session_idle_ms, fn ->
        Application.get_env(:troupe_core, :session_idle_ms, @default_idle_ms)
      end)

    sweep_ms =
      Keyword.get_lazy(opts, :sweep_ms, fn ->
        Application.get_env(:troupe_core, :session_sweep_ms, @sweep_ms)
      end)
    if idle_ms != :infinity, do: Process.send_after(self(), :sweep, sweep_ms)

    {:ok,
     %{
       live: %{},
       monitors: %{},
       state_dir: Keyword.get(opts, :state_dir),
       idle_ms: idle_ms,
       sweep_ms: sweep_ms
     }}
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
     |> put_in([:monitors, ref], session_id)}
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
    {:noreply, Enum.reduce(Map.keys(state.live), state, &sweep_session/2)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} -> {:noreply, state}
      {session_id, monitors} -> {:noreply, drop(%{state | monitors: monitors}, session_id)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A session with nothing to do for long enough gives its actor tree back. Idleness
  # is asked of the agent rather than inferred from events, because "nothing has been
  # logged lately" is also true of an agent waiting on a twenty-minute test run.
  defp sweep_session(session_id, state) do
    case Map.fetch(state.live, session_id) do
      :error ->
        state

      {:ok, entry} ->
        sweep_live(state, session_id, entry, agent_state(session_id))
    end
  end

  defp sweep_live(state, session_id, entry, :busy) do
    put_in(state.live[session_id], Map.put(entry, :idle_since, nil))
  end

  defp sweep_live(state, session_id, _entry, :gone), do: drop(state, session_id)

  defp sweep_live(state, session_id, entry, :idle) do
    idle_since = Map.get(entry, :idle_since) || now_ms()

    if now_ms() - idle_since >= state.idle_ms do
      Troupe.stop_session(session_id)
      drop(state, session_id)
    else
      put_in(state.live[session_id], Map.put(entry, :idle_since, idle_since))
    end
  end

  defp agent_state(session_id) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] -> :idle
      %{state: _} -> :busy
      _ -> :gone
    end
  catch
    :exit, _ -> :gone
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A session that is no longer running is no longer live, full stop. Its metadata
  # comes back from its log on the next listing, which is the only copy that survives
  # a restart anyway — so there is nothing here worth keeping stale.
  defp drop(state, session_id) do
    %{state | live: Map.delete(state.live, session_id)}
  end

  @impl GenServer
  def handle_call({:get, session_id}, _from, state) do
    {:reply, Map.get(state.live, session_id) || from_disk(state, session_id), state}
  end

  def handle_call({:list, filter}, _from, state) do
    {:reply, state |> all() |> apply_filter(filter), state}
  end

  def handle_call(:live_ids, _from, state) do
    {:reply, state.live |> Enum.filter(&(elem(&1, 1).state == :active)) |> Enum.map(&elem(&1, 0)),
     state}
  end

  def handle_call({:recent, limit}, _from, state) do
    workspaces =
      state
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

    {:reply, workspaces, state}
  end

  # Live entries win: a session with a running tree knows more about itself than its
  # log's first event does.
  defp all(state) do
    disk = Map.new(scan_disk(state), &{&1.id, &1})

    disk
    |> Map.merge(state.live)
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
  # and last events rather than from anything this process remembered.
  defp scan_disk(state) do
    root = state.state_dir |> Paths.state_dir() |> Paths.glob_escape()

    [root, "sessions", "*", "*", "events.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&meta_from_log/1)
  end

  # The id is a name, not a pattern: escaped, so `*` finds no session rather than the
  # first one on disk (#97).
  defp from_disk(state, session_id) do
    root = state.state_dir |> Paths.state_dir() |> Paths.glob_escape()

    [root, "sessions", "*", Paths.glob_escape(session_id), "events.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&meta_from_log/1)
    |> List.first()
  end

  defp meta_from_log(path) do
    case Log.read_file(path) do
      [] ->
        []

      events ->
        first = List.first(events)
        last = List.last(events)
        created = Enum.find(events, &(&1.type == "session_created"))

        [
          %{
            id: Path.basename(Path.dirname(path)),
            workspace: get_data(created, "workspace", "(unknown)"),
            branch: get_data(created, "branch", nil),
            parent: get_data(created, "parent", nil),
            profile: get_data(created, "profile", "build"),
            state: :dormant,
            status: status_from_log(events),
            tokens: total_tokens(events),
            cost: total_cost(events),
            created_at: first.ts,
            last_active_at: last.ts,
            pinned: false
          }
        ]
    end
  end

  # What a session was in the middle of when it stopped, read from the log alone. A
  # tool call that started and never finished, or a request the model never answered,
  # is a session that was interrupted — and a client has to be able to see that before
  # anything has been restarted.
  defp status_from_log(events) do
    cond do
      Enum.any?(events, &(&1.type == "agent_done")) -> :done
      incomplete_tool_call?(events) -> :interrupted
      unanswered_request?(events) -> :interrupted
      true -> :idle
    end
  end

  defp incomplete_tool_call?(events) do
    completed =
      for %Event{type: "tool_call_completed", data: %{"call_id" => id}} <- events,
          into: MapSet.new(),
          do: id

    Enum.any?(events, fn
      %Event{type: "tool_call_started", data: %{"call_id" => id}} ->
        not MapSet.member?(completed, id)

      _ ->
        false
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

  defp total_tokens(events) do
    Enum.reduce(events, 0, fn
      %Event{type: "llm_response", data: %{"usage" => usage}}, acc ->
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
      %Event{type: "llm_response", data: %{"gateway" => %{"cost_micros" => micros}}}, acc
      when is_integer(micros) ->
        acc + micros / 1_000_000

      _event, acc ->
        acc
    end)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
