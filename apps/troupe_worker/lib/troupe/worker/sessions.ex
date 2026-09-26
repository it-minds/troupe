defmodule Troupe.Worker.Sessions do
  @moduledoc """
  The sessions this pod currently has awake.

  A registry and a dynamic supervisor, and the lookup-or-start that goes with them.
  `activate/2` is the whole of the concurrency story inside one worker: two callers
  asking for the same session at the same moment race to start a manager, one of them
  loses to the registry, and both wait on the same restore. One tree, one epoch, one
  workspace.
  """

  use Supervisor

  alias Troupe.Worker.Session.Manager

  @registry Troupe.Worker.Session.Registry
  @supervisor Troupe.Worker.Session.Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Supervisor
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The registered name of one session's manager."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id), do: {:via, Registry, {@registry, session_id}}

  @doc "The manager for a session, or `nil` if it is dormant."
  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Bring a session up, or confirm it already is.

  Idempotent on purpose: every command that needs a running tree calls this, and a
  session that is already awake must cost a registry lookup rather than a restore.
  """
  @spec activate(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate(session_id, opts \\ []) do
    do_activate(Keyword.put(opts, :session_id, session_id), true)
  end

  defp do_activate(opts, retry?) do
    case DynamicSupervisor.start_child(@supervisor, {Manager, opts}) do
      {:ok, pid} -> await(pid, opts, retry?)
      {:error, {:already_started, pid}} -> await(pid, opts, retry?)
      {:error, reason} -> {:error, reason}
    end
  end

  # Monitored throughout, for two reasons. A failed activation stops its manager, and
  # returning before that has finished would let the caller's next attempt collide with
  # a process that is on its way out. And a manager that was already dying when this
  # caller found it in the registry is not an error — it is a race with a session going
  # dormant, and the right answer is to start a new one.
  defp await(pid, opts, retry?) do
    reference = Process.monitor(pid)

    try do
      case Manager.await(pid, Keyword.get(opts, :timeout, 120_000)) do
        {:ok, summary} ->
          Process.demonitor(reference, [:flush])
          {:ok, summary}

        {:error, reason} ->
          await_down(pid, reference)
          {:error, reason}
      end
    catch
      :exit, reason ->
        Process.demonitor(reference, [:flush])

        if retry? do
          do_activate(opts, false)
        else
          {:error, {:activation_failed, reason}}
        end
    end
  end

  defp await_down(pid, reference) do
    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      30_000 ->
        Process.demonitor(reference, [:flush])
        :ok
    end
  end

  @doc """
  The running tree an activating command on this pod's harness is for.

  In place of the core's lookup-or-restore, which would bring a dormant session back
  from a log it found on this pod's disk — one a reader restored for the plane's
  `session.read`, or one a pod that stopped without putting its sessions to sleep left
  on its volume — with no placement, no epoch and no sealer. On a pod only the plane
  brings a session back, by pushing `session.activate`, so this never restores: a session
  with no tree here is `{:error, :not_found}`, and the client asks the plane where it is.
  A manager still putting its tree back is waited for.
  """
  @spec running(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def running(session_id) do
    case whereis(session_id) do
      nil -> :ok
      manager -> Manager.await(manager)
    end

    case Troupe.Registry.whereis({:session, session_id}) do
      nil -> {:error, :not_found}
      tree -> {:ok, tree}
    end
  catch
    :exit, _gone -> {:error, :not_found}
  end

  @doc "Put a session to sleep now, rather than waiting for it to go idle."
  @spec dormant(String.t()) :: {:ok, map()} | {:error, :not_active | term()}
  def dormant(session_id) do
    with_manager(session_id, &Manager.go_dormant/1)
  end

  @doc "Tell a session it has been fenced, if this pod has it."
  @spec fence(String.t(), pos_integer()) :: :ok
  def fence(session_id, epoch) do
    case with_manager(session_id, &Manager.fence(&1, epoch)) do
      {:error, :not_active} -> :ok
      other -> other
    end
  end

  # Both of these end the manager, and both must not return until it has actually gone:
  # a caller that put a session to sleep and immediately placed it elsewhere would
  # otherwise find the corpse in the registry.
  defp with_manager(session_id, fun) do
    case whereis(session_id) do
      nil ->
        {:error, :not_active}

      pid ->
        reference = Process.monitor(pid)

        try do
          result = fun.(pid)
          await_down(pid, reference)
          result
        catch
          :exit, _reason ->
            Process.demonitor(reference, [:flush])
            {:error, :not_active}
        end
    end
  end

  @doc """
  Drop a session's registration before its manager exits.

  The registry would do this on its own when the process dies, but only when it gets
  round to the monitor message. A caller that has just put a session to sleep and is
  about to place it elsewhere would see the corpse in the meantime, so the manager gives
  up its name in `terminate/2` and the registry is authoritative the moment it does.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(session_id), do: Registry.unregister(@registry, session_id)

  @doc """
  Every session awake on this pod.

  Managers register under the bare session id; readers share this registry under
  `{:reader, id}`, and a reader is deliberately not an awake session — that is the whole
  point of it — so only the binaries count.
  """
  @spec active_ids() :: [String.t()]
  def active_ids do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&is_binary/1)
    |> Enum.sort()
  end

  @doc "How many, which is what the heartbeat reports."
  @spec active_count() :: non_neg_integer()
  def active_count, do: length(active_ids())
end
