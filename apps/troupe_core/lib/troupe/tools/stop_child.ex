defmodule Troupe.Tools.StopChild do
  @moduledoc """
  Stop a subagent this agent started in the background (#554, Decision 853).

  Inline and deferred, as `delegate` is: the child is a Node under this agent's
  `Agent.Children`, which only the agent process can end. The agent ends it, which takes
  its model call, its tasks and every subagent under it, closes their logs with the child's
  `agent_done` saying it was stopped and by whom, and hands its own model the child's end
  like any other: what it last said and what it had changed, before its next call. A
  waited-for child is not here: its parent cannot call a tool until it ends.

  An agent whose tool list names `delegate` holds this too
  (`Troupe.Agent.Definition.allows_tool?/2`): stopping a subagent goes with starting one.
  """

  @behaviour Troupe.Tool

  alias Troupe.Tool

  @impl Troupe.Tool
  def name, do: "stop_child"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description,
    do: "Stop a subagent you started with wait false; what it had done comes to you."

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{"child" => %{"type" => "string", "description" => "Its path."}},
      "required" => ["child"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, _ctx) do
    with {:ok, child} <- Tool.fetch_string(args, "child"), do: {:defer, {:stop_child, child}}
  end
end
