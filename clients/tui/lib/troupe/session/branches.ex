defmodule Troupe.Session.Branches do
  @moduledoc "DynamicSupervisor holding one `Agent.Node` per dispatched command."

  use DynamicSupervisor

  alias Troupe.Agent
  alias Troupe.Session

  def start_link(%{session_id: sid}) do
    DynamicSupervisor.start_link(__MODULE__, [], name: Session.via(sid, :branches))
  end

  @impl true
  def init([]), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_branch(String.t(), Agent.Spec.t()) :: {:ok, pid()} | {:error, term()}
  def start_branch(sid, %Agent.Spec{} = spec) do
    DynamicSupervisor.start_child(Session.via(sid, :branches), {Agent.Node, spec})
  end

  @spec stop_branch(String.t(), String.t()) :: :ok | {:error, :not_found}
  def stop_branch(sid, agent_path) do
    case Session.whereis(sid, {:node, agent_path}) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Session.via(sid, :branches), pid)
    end
  end

  @spec live_nodes(String.t()) :: [pid()]
  def live_nodes(sid) do
    case Session.whereis(sid, :branches) do
      nil ->
        []

      sup ->
        sup
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, pid, _, _} -> pid end)
        |> Enum.filter(&is_pid/1)
    end
  end
end
