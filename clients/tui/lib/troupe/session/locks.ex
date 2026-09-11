defmodule Troupe.Session.Locks do
  @moduledoc "Advisory per-path write locks for shared-isolation branches."

  use GenServer

  alias Troupe.Session

  defstruct [:session_id, locks: %{}, monitors: %{}]

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :locks))
  end

  @spec acquire(String.t(), String.t(), String.t()) :: :ok | {:error, {:held_by, String.t()}}
  def acquire(sid, path, holder),
    do: GenServer.call(Session.via(sid, :locks), {:acquire, path, holder, self()})

  @spec release(String.t(), String.t(), String.t()) :: :ok
  def release(sid, path, holder),
    do: GenServer.call(Session.via(sid, :locks), {:release, path, holder})

  @doc "Runs `fun` holding the lock; contention returns an error naming the holder."
  @spec with_lock(String.t(), String.t(), String.t(), (-> Troupe.Tool.result())) ::
          Troupe.Tool.result()
  def with_lock(sid, path, holder, fun) do
    if Session.whereis(sid, :locks) do
      case acquire(sid, path, holder) do
        :ok ->
          try do
            fun.()
          after
            release(sid, path, holder)
          end

        {:error, {:held_by, other}} ->
          {:error, "#{path} is locked by branch #{other}; retry later or work elsewhere"}
      end
    else
      fun.()
    end
  end

  @impl true
  def init(%{session_id: sid}), do: {:ok, %__MODULE__{session_id: sid}}

  @impl true
  def handle_call({:acquire, path, holder, pid}, _from, state) do
    case Map.get(state.locks, path) do
      nil ->
        ref = Process.monitor(pid)

        {:reply, :ok,
         %{
           state
           | locks: Map.put(state.locks, path, {holder, ref}),
             monitors: Map.put(state.monitors, ref, path)
         }}

      {^holder, _ref} ->
        {:reply, :ok, state}

      {other, _ref} ->
        {:reply, {:error, {:held_by, other}}, state}
    end
  end

  def handle_call({:release, path, holder}, _from, state) do
    case Map.get(state.locks, path) do
      {^holder, ref} ->
        Process.demonitor(ref, [:flush])

        {:reply, :ok,
         %{state | locks: Map.delete(state.locks, path), monitors: Map.delete(state.monitors, ref)}}

      _ ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {path, monitors} ->
        {:noreply, %{state | monitors: monitors, locks: Map.delete(state.locks, path)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
