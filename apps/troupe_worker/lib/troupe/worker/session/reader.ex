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

  It exits when its last subscriber leaves and no client is reading the session through
  the pod's harness, which is what keeps a pod that serves a thousand glances a day from
  accumulating a thousand processes; and it takes the log it restored with it, which is
  what keeps those glances from leaving a thousand plaintext logs on the pod's volume.
  """

  use GenServer, restart: :temporary

  alias Troupe.Sessions.Context
  alias Troupe.Worker.Session.Restore
  alias Troupe.Worker.Sessions

  require Logger

  # A reader with no subscribers at all — opened by a command that then went away — is
  # not kept around waiting for one that may never come. Also how often one kept for a
  # client reading through the harness looks again. `:idle_grace_ms` in a test.
  @idle_grace_ms 30_000

  defstruct [:session_id, :context, :log, :timer, :found, :idle_ms, subscribers: %{}]

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
  def open(session_id, opts \\ []), do: do_open(session_id, opts, true)

  # A reader that finds an activation registered since the look here writes nothing and
  # does not start (`init/1`), and the answer is the running session's. One already
  # there whose log is no longer the one it restored, or that goes as it is asked, is not
  # an answer either: it is gone, and this looks again, once.
  defp do_open(session_id, opts, retry?) do
    if Sessions.whereis(session_id) do
      {:ok, active(session_id)}
    else
      case start_reader(Keyword.put(opts, :session_id, session_id)) do
        :gone when retry? -> do_open(session_id, opts, false)
        :gone -> {:error, :reader_gone}
        answer -> answer
      end
    end
  end

  defp start_reader(opts) do
    case DynamicSupervisor.start_child(supervisor(), {__MODULE__, opts}) do
      {:ok, pid} -> ask(pid)
      {:error, {:already_started, pid}} -> ask(pid)
      :ignore -> {:ok, active(Keyword.fetch!(opts, :session_id))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ask(pid) do
    GenServer.call(pid, :info, 120_000)
  catch
    :exit, _gone -> :gone
  end

  defp active(session_id),
    do: %{session_id: session_id, source: :active, agents: length(Troupe.agent_tree(session_id))}

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
    # So a pod that shuts down takes the log away too.
    Process.flag(:trap_exit, true)

    with {:ok, context} <- context(opts),
         root = Restore.workspace_root(context, opts),
         {:ok, log} <- Restore.events(context, root, unless_active: true) do
      Logger.debug("troupe worker: reading #{session_id} from #{log.segments} segment(s)")

      state = %__MODULE__{
        session_id: session_id,
        context: context,
        log: log,
        found: log.found,
        idle_ms: Keyword.get(opts, :idle_grace_ms, @idle_grace_ms)
      }

      {:ok, schedule_idle(state)}
    else
      # An activation of the session has registered here since `open/2` looked: the log is
      # its own, and the answer is the running session's.
      {:error, :active} ->
        leave(session_id)
        :ignore

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # A key manager or an object store the pod cannot reach is named as an activation names
  # it (`Restore.open_context/2`, `Restore.unreachable/2`).
  defp context(opts) do
    case Keyword.fetch(opts, :context) do
      {:ok, %Context{} = context} -> {:ok, context}
      :error -> Restore.open_context(Keyword.fetch!(opts, :session_id), opts)
    end
  end

  @impl GenServer
  # Not from a log that is no longer the one this reader restored: an activation has taken
  # it over, or erased it when it put the session back to sleep, and what came since is in
  # storage. The reader goes rather than answer from what it had, and `open/2` asks again.
  def handle_call(:info, _from, state) do
    if ours?(state),
      do: {:reply, {:ok, info(state)}, state},
      else: {:stop, :normal, :gone, state}
  end

  def handle_call({:follow, subscriber}, _from, state) do
    reference = Process.monitor(subscriber)
    {:reply, :ok, cancel_idle(%{state | subscribers: Map.put(state.subscribers, subscriber, reference)})}
  end

  def handle_call({:unfollow, subscriber}, _from, state) do
    {:reply, :ok, drop(state, subscriber)}
  end

  @impl GenServer
  def handle_info({:DOWN, _reference, :process, pid, _reason}, state) do
    settle(drop(state, pid))
  end

  def handle_info(:idle, state), do: settle(state)

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    forget(state)
    leave(state.session_id)
    :ok
  end

  # The name given up here rather than left to the registry's monitor, so a caller this
  # reader answered as it went can start another at once (`open/2`); and only once its log
  # is gone, so the next one's log is never this one's to take away.
  defp leave(session_id), do: Registry.unregister(registry(), {:reader, session_id})

  # Whether to go, once nobody follows the reader itself.
  #
  # A client reading the session through the pod's harness follows the log, not the
  # reader, and it reads the log from disk, so the reader stays as long as one is attached
  # — going sooner would take the log from under them. So does an activation of the
  # session starting over the log, until it has either taken the log over, which it has
  # once it has written to it and which leaves the reader nothing to serve or remove, or
  # failed and gone, leaving the log with the reader (Decision 725).
  defp settle(state) do
    cond do
      map_size(state.subscribers) > 0 -> {:noreply, state}
      not ours?(state) -> {:stop, :normal, state}
      read?(state.session_id) -> {:noreply, schedule_idle(state)}
      true -> {:stop, :normal, state}
    end
  end

  defp read?(session_id) do
    Troupe.Events.attached?(session_id) or Sessions.whereis(session_id) != nil
  end

  # What the reader restored goes when it does, and only that: not a log that was on the
  # pod before the read, and not one an activation has, is putting back or has written to,
  # which may hold events storage does not have yet. Under the lock a restore writes the
  # log under (`Restore.with_log/2`), so an activation starting now is either seen here or
  # writes its log after this one has gone.
  defp forget(%__MODULE__{found: true}), do: :ok

  defp forget(state) do
    Restore.with_log(state.session_id, fn ->
      if ours?(state) and Sessions.whereis(state.session_id) == nil do
        File.rm_rf(Path.dirname(state.log.path))
      end
    end)

    :ok
  end

  # The log is still the one this reader wrote: nobody has appended to it or written it
  # again since, and it has not been removed. The log only grows, so its size says so.
  defp ours?(state) do
    case File.stat(state.log.path) do
      {:ok, %File.Stat{size: size}} -> size == state.log.bytes
      {:error, _gone} -> false
    end
  end

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
    %{state | timer: Process.send_after(self(), :idle, state.idle_ms)}
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
