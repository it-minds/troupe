defmodule Troupe.Agent.Node do
  @moduledoc """
  One agent as a fate-sharing unit: its task supervisor, its subagent supervisor, and
  the agent itself.

  `one_for_all` is the whole point. When `Agent.Server` dies, `Agent.Tasks` dies with
  it — killing the in-flight LLM stream and every tool task, which closes every reaper
  Port, which reaps every OS process tree — and `Agent.Children` dies too, taking the
  entire subagent subtree. "No orphans, ever" is a property of this supervisor, not of
  cleanup code somewhere.

  Restart intensity is deliberately tight: a deterministically crashing agent should
  fail fast so its parent can report an error for that delegation and carry on, rather
  than looping. Exceeding it takes this Node down; the parent sees `:DOWN` on its
  delegation monitor.
  """

  use Supervisor

  alias Troupe.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_path = Keyword.fetch!(opts, :agent_path)
    Supervisor.start_link(__MODULE__, opts, name: Registry.node_sup(session_id, agent_path))
  end

  @doc """
  A child spec for spawning this Node under a parent's `Agent.Children`.

  `:temporary` because a subagent that exhausted its restarts must not be restarted
  by the DynamicSupervisor: the parent converts the `:DOWN` into an error result for
  that one delegation, and siblings carry on.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :agent_path)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: Keyword.get(opts, :restart, :temporary),
      shutdown: 10_000
    }
  end

  @impl Supervisor
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_path = Keyword.fetch!(opts, :agent_path)

    Process.set_label("troupe node #{Enum.join(agent_path, "/")}")

    children = [
      {Task.Supervisor, name: Registry.tasks(session_id, agent_path)},
      {DynamicSupervisor,
       name: Registry.children_sup(session_id, agent_path), strategy: :one_for_one},
      {Troupe.Agent.Server, opts}
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: Keyword.get(opts, :max_restarts, 3),
      max_seconds: Keyword.get(opts, :max_seconds, 5)
    )
  end

  @doc "Every live process under this Node, for asserting a subtree left nothing behind."
  @spec descendants(String.t(), [String.t()]) :: [pid()]
  def descendants(session_id, agent_path) do
    session_id
    |> Registry.agent_paths_under(agent_path)
    |> Enum.flat_map(fn path ->
      [
        Registry.whereis({:node, session_id, path}),
        Registry.whereis({:agent, session_id, path}),
        Registry.whereis({:tasks, session_id, path}),
        Registry.whereis({:children, session_id, path})
      ]
    end)
    |> Enum.reject(&is_nil/1)
  end
end
