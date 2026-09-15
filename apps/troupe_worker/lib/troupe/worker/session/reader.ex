defmodule Troupe.Worker.Session.Reader do
  @moduledoc """
  Serving a dormant session's history without waking it.

  Reading a session — listing it, replaying it, subscribing to it — deliberately does not
  activate it. A session that woke up because somebody looked at it would never stay
  dormant, and a fleet where every glance costs a pod slot is a fleet that cannot hold
  ten thousand sleeping sessions.

  So a reader is not a session. It restores the event log to the pod's disk and nothing
  else: no `Agent.Server`, no model call, no workspace. Subscribers replay from the log
  exactly as they would from a live one, because it *is* the same log — the same chain,
  the same sequence numbers, verifiable by the same `troupe verify`.

  It exits when its last subscriber leaves, which is what keeps a pod that serves a
  thousand glances a day from accumulating a thousand processes.
  """

  use GenServer, restart: :temporary

  alias Troupe.Sessions.Context
  alias Troupe.Worker.Session.Restore
  alias Troupe.Worker.Sessions

  require Logger

  # A reader with no subscribers at all — opened by a command that then went away — is
  # not kept around waiting for one that may never come.
  @idle_grace_ms 30_000

  defstruct [:session_id, :context, :log, :timer, subscribers: %{}]

  # -- api --------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  @doc "The registered name of one session's reader."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id), do: {:via, Registry, {registry(), {:reader, session_id}}}

  @doc "The reader for a session, or `nil`."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(registry(), {:reader, session_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Open a session for reading, or confirm it is already open.

  A session whose tree is already running needs no reader: its log is live and the
  gateway reads it straight from the running `Session.Log`.
  """
  @spec open(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open(session_id, opts \\ []) do
    if Sessions.whereis(session_id) do
      {:ok, %{session_id: session_id, source: :active, agents: length(Troupe.agent_tree(session_id))}}
    else
      start_reader(session_id, opts)
    end
  end

  defp start_reader(session_id, opts) do
    opts = Keyword.put(opts, :session_id, session_id)

    case DynamicSupervisor.start_child(supervisor(), {__MODULE__, opts}) do
      {:ok, pid} -> GenServer.call(pid, :info, 120_000)
      {:error, {:already_started, pid}} -> GenServer.call(pid, :info, 120_000)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Follow a reader, so it stays up while this process cares about it.

  Monitored rather than linked: a subscriber that goes away should close the reader, not
  the other way round.
  """
  @spec follow(String.t(), pid()) :: :ok | {:error, :no_reader}
  def follow(session_id, subscriber \\ self()) do
    case whereis(session_id) do
      nil -> {:error, :no_reader}
      pid -> GenServer.call(pid, {:follow, subscriber})
    end
  end

  @doc "Stop following. The reader exits once nobody is left."
  @spec unfollow(String.t(), pid()) :: :ok
  def unfollow(session_id, subscriber \\ self()) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:unfollow, subscriber})
    end
  end

  @doc "Close a reader now, whoever is following."
  @spec close(String.t()) :: :ok
  def close(session_id) do
    case whereis(session_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe reader #{session_id}")

    with {:ok, context} <- context(opts),
         root = Restore.workspace_root(context, opts),
         {:ok, log} <- Restore.events(context, root) do
      Logger.debug("troupe worker: reading #{session_id} from #{log.segments} segment(s)")

      state = %__MODULE__{session_id: session_id, context: context, log: log}
      {:ok, schedule_idle(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp context(opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, %Context{} = context} -> {:ok, context}
      :error -> Context.open(Keyword.fetch!(opts, :session_id), opts)
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call({:follow, subscriber}, _from, state) do
    reference = Process.monitor(subscriber)
    {:reply, :ok, cancel_idle(%{state | subscribers: Map.put(state.subscribers, subscriber, reference)})}
  end

  def handle_call({:unfollow, subscriber}, _from, state) do
    {:reply, :ok, drop(state, subscriber)}
  end

  @impl GenServer
  def handle_info({:DOWN, _reference, :process, pid, _reason}, state) do
    state = drop(state, pid)
    if map_size(state.subscribers) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(:idle, state) do
    if map_size(state.subscribers) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp drop(state, subscriber) do
    case Map.pop(state.subscribers, subscriber) do
      {nil, _} ->
        state

      {reference, rest} ->
        Process.demonitor(reference, [:flush])
        state = %{state | subscribers: rest}
        if rest == %{}, do: schedule_idle(state), else: state
    end
  end

  defp schedule_idle(state) do
    state = cancel_idle(state)
    %{state | timer: Process.send_after(self(), :idle, @idle_grace_ms)}
  end

  defp cancel_idle(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end

  defp info(state) do
    %{
      session_id: state.session_id,
      source: :storage,
      events: state.log.events,
      segments: state.log.segments,
      last_seq: state.log.last_seq,
      head_hash: state.log.head_hash,
      # The number that matters for the done item: reading starts no agents.
      agents: length(Troupe.agent_tree(state.session_id)),
      subscribers: map_size(state.subscribers)
    }
  end

  defp registry, do: Troupe.Worker.Session.Registry
  defp supervisor, do: Troupe.Worker.Session.Supervisor
end
