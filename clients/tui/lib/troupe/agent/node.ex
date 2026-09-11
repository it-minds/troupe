defmodule Troupe.Agent.Node do
  @moduledoc """
  Branch (or nested subagent) root: a `one_for_all` supervisor over the
  agent's Task.Supervisor, its children DynamicSupervisor and the agent
  server. Exceeding 3 restarts in 5 seconds ends the Node.
  """

  use Supervisor

  alias Troupe.Agent.{Server, Spec}
  alias Troupe.Session

  def start_link(%Spec{} = spec) do
    Supervisor.start_link(__MODULE__, spec,
      name: Session.via(spec.session_id, {:node, spec.agent_path})
    )
  end

  def child_spec(%Spec{} = spec) do
    %{
      id: {__MODULE__, spec.agent_path},
      start: {__MODULE__, :start_link, [spec]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @impl true
  def init(%Spec{} = spec) do
    sid = spec.session_id
    path = spec.agent_path

    children = [
      %{
        id: :tasks,
        start: {Task.Supervisor, :start_link, [[name: Session.via(sid, {:tasks, path})]]},
        type: :supervisor
      },
      %{
        id: :children,
        start:
          {DynamicSupervisor, :start_link,
           [[strategy: :one_for_one, name: Session.via(sid, {:children, path})]]},
        type: :supervisor
      },
      %{id: :server, start: {Server, :start_link, [spec]}, restart: :transient, shutdown: 5_000}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 5)
  end

  @doc "All live pids under a node's subtree (for orphan checks)."
  @spec subtree_pids(pid()) :: [pid()]
  def subtree_pids(sup) when is_pid(sup) do
    if Process.alive?(sup) do
      sup
      |> Supervisor.which_children()
      |> Enum.flat_map(fn
        {_, pid, :supervisor, _} when is_pid(pid) -> [pid | subtree_pids(pid)]
        {_, pid, _, _} when is_pid(pid) -> [pid]
        _ -> []
      end)
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
