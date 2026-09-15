defmodule Troupe.Session.Approvals do
  @moduledoc """
  Permission gate and user-question broker. Agents register a pending approval
  or question; the user's answer is forwarded to the agent as
  `{:approval, call_id, decision}` or `{:answer, call_id, text}`.
  """

  use GenServer

  alias Troupe.Session

  defstruct [
    :session_id,
    pending: %{},
    monitors: %{},
    session_allowed: MapSet.new(),
    budget_overridden: false,
    auto_approve: false
  ]

  def start_link(%{session_id: sid} = opts) do
    GenServer.start_link(__MODULE__, opts, name: Session.via(sid, :approvals))
  end

  @spec register(
          String.t(),
          String.t(),
          pid(),
          String.t(),
          :approval | :question | :budget,
          map()
        ) :: :ok
  def register(sid, call_id, agent_pid, agent_path, kind, payload) do
    GenServer.call(
      Session.via(sid, :approvals),
      {:register, call_id, agent_pid, agent_path, kind, payload}
    )
  end

  @spec answer(String.t(), String.t(), :allow | :deny | :allow_session | {:text, String.t()}) ::
          :ok | {:error, :unknown_call}
  def answer(sid, call_id, decision) do
    GenServer.call(Session.via(sid, :approvals), {:answer, call_id, decision})
  end

  @spec pending(String.t()) :: [map()]
  def pending(sid), do: GenServer.call(Session.via(sid, :approvals), :pending)

  @spec session_allowed?(String.t(), String.t()) :: boolean()
  def session_allowed?(sid, tool),
    do: GenServer.call(Session.via(sid, :approvals), {:allowed?, tool})

  @doc "Turns blanket approval on or off for the rest of the session."
  @spec set_auto_approve(String.t(), boolean()) :: :ok
  def set_auto_approve(sid, value) when is_boolean(value),
    do: GenServer.call(Session.via(sid, :approvals), {:auto_approve, value})

  @doc "Whether the user chose to override the budget for this session."
  @spec budget_overridden?(String.t()) :: boolean()
  def budget_overridden?(sid),
    do: GenServer.call(Session.via(sid, :approvals), :budget_overridden?)

  ## Server

  @impl true
  def init(%{session_id: sid, config: config}) do
    {:ok, %__MODULE__{session_id: sid, auto_approve: config.auto_approve}}
  end

  @impl true
  def handle_call({:register, call_id, pid, path, kind, payload}, _from, state) do
    # A restarted agent re-registers under its original call_id, so drop the dead
    # process's monitor rather than leaving it to fire against the live entry.
    state = forget(state, call_id)
    ref = Process.monitor(pid)

    entry = %{
      call_id: call_id,
      agent_pid: pid,
      agent_path: path,
      kind: kind,
      payload: payload,
      monitor: ref
    }

    {:reply, :ok,
     %{
       state
       | pending: Map.put(state.pending, call_id, entry),
         monitors: Map.put(state.monitors, ref, call_id)
     }}
  end

  def handle_call({:answer, call_id, decision}, _from, state) do
    case Map.pop(state.pending, call_id) do
      {nil, _} ->
        {:reply, {:error, :unknown_call}, state}

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        state = %{state | pending: pending, monitors: Map.delete(state.monitors, entry.monitor)}
        state = forward(entry, decision, state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:pending, _from, state), do: {:reply, Map.values(state.pending), state}

  def handle_call(:budget_overridden?, _from, state),
    do: {:reply, state.budget_overridden, state}

  def handle_call({:allowed?, tool}, _from, state) do
    {:reply, state.auto_approve or MapSet.member?(state.session_allowed, tool), state}
  end

  def handle_call({:auto_approve, value}, _from, %__MODULE__{} = state),
    do: {:reply, :ok, %__MODULE__{state | auto_approve: value}}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {call_id, monitors} ->
        {:noreply, %{state | monitors: monitors, pending: Map.delete(state.pending, call_id)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Retires whatever is registered under `call_id`, monitor included. `:flush` is
  # what makes re-registration safe: without it the dead agent's DOWN can arrive
  # after the restarted one registered and delete the live entry, orphaning a request
  # the user can still see and can no longer answer.
  defp forget(%__MODULE__{} = state, call_id) do
    case Map.pop(state.pending, call_id) do
      {nil, _} ->
        state

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | pending: pending, monitors: Map.delete(state.monitors, entry.monitor)}
    end
  end

  defp forward(%{kind: :question} = entry, {:text, text}, state) do
    send(entry.agent_pid, {:answer, entry.call_id, text})
    state
  end

  defp forward(%{kind: :approval} = entry, :allow_session, state) do
    send(entry.agent_pid, {:approval, entry.call_id, :allow})
    tool = Map.get(entry.payload, :name)
    %{state | session_allowed: MapSet.put(state.session_allowed, tool)}
  end

  defp forward(%{kind: :budget} = entry, :allow_session, state) do
    send(entry.agent_pid, {:budget_answer, entry.call_id, :always})
    %{state | budget_overridden: true}
  end

  defp forward(%{kind: :budget} = entry, :allow, state) do
    send(entry.agent_pid, {:budget_answer, entry.call_id, :allow})
    state
  end

  defp forward(%{kind: :budget} = entry, :deny, state) do
    send(entry.agent_pid, {:budget_answer, entry.call_id, :deny})
    state
  end

  defp forward(%{kind: :approval} = entry, decision, state) when decision in [:allow, :deny] do
    send(entry.agent_pid, {:approval, entry.call_id, decision})
    state
  end

  defp forward(_entry, _decision, state), do: state
end
