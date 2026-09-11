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

  @doc "Record a session that has just started."
  @spec register(String.t(), map()) :: :ok
  def register(session_id, meta), do: GenServer.cast(__MODULE__, {:register, session_id, meta})

  @doc "Update fields on a live session."
  @spec update(String.t(), map()) :: :ok
  def update(session_id, changes), do: GenServer.cast(__MODULE__, {:update, session_id, changes})

  @doc "Mark a session as no longer running. Its history stays."
  @spec dormant(String.t()) :: :ok
  def dormant(session_id), do: GenServer.cast(__MODULE__, {:dormant, session_id})

  @doc "Forget a session entirely. Only for erasure."
  @spec forget(String.t()) :: :ok
  def forget(session_id), do: GenServer.cast(__MODULE__, {:forget, session_id})

  @doc "One session's metadata, live or dormant, or `nil`."
  @spec get(String.t()) :: meta() | nil
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})

  @doc """
  Every session this daemon knows about, newest first.

  `filter` may carry `"state"` (a list of state strings) and `"workspace"`.
  """
  @spec list(map()) :: [meta()]
  def list(filter \\ %{}), do: GenServer.call(__MODULE__, {:list, filter}, 15_000)

  @doc "Session ids with a running actor tree."
  @spec live_ids() :: [String.t()]
  def live_ids, do: GenServer.call(__MODULE__, :live_ids)

  @doc "Workspaces this daemon has seen, most recently used first."
  @spec recent_workspaces(pos_integer()) :: [map()]
  def recent_workspaces(limit \\ 20), do: GenServer.call(__MODULE__, {:recent, limit}, 15_000)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe session index")
    {:ok, %{live: %{}, state_dir: Keyword.get(opts, :state_dir)}}
  end

  @impl GenServer
  def handle_cast({:register, session_id, meta}, state) do
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

    {:noreply, put_in(state.live[session_id], entry)}
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

  def handle_cast({:dormant, session_id}, state) do
    case Map.fetch(state.live, session_id) do
      {:ok, entry} -> {:noreply, put_in(state.live[session_id], %{entry | state: :dormant})}
      :error -> {:noreply, state}
    end
  end

  def handle_cast({:forget, session_id}, state) do
    {:noreply, %{state | live: Map.delete(state.live, session_id)}}
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
    root = Paths.state_dir(state.state_dir)

    [root, "sessions", "*", "*", "events.jsonl"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&meta_from_log/1)
  end

  defp from_disk(state, session_id) do
    root = Paths.state_dir(state.state_dir)

    [root, "sessions", "*", session_id, "events.jsonl"]
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
            profile: get_data(created, "profile", "build"),
            state: :dormant,
            status: :idle,
            tokens: total_tokens(events),
            cost: 0.0,
            created_at: first.ts,
            last_active_at: last.ts,
            pinned: false
          }
        ]
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

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
