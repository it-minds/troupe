defmodule Troupe.Tools.Delegate do
  @moduledoc """
  Hand a subagent one piece of work, as a brief in five parts.

  Inline, and deferred: spawning a child means starting a supervised `Agent.Node`
  under *this agent's* `Agent.Children` supervisor and monitoring it, which only the
  agent process can do. `run/2` validates and returns `{:defer, {:delegate, ...}}`;
  the agent does the spawning and completes the tool call when
  `{:child_result, ref, result}` arrives.

  The brief has a shape (#554, Decision 847): `goal`, `context`, `constraints`,
  `deliverable` and `do_not`, each its own field, and a call missing one is refused
  with a sentence naming it before any child starts. A child starts with nothing but
  its brief, and a brief written as one blob of text was where what the child needed
  went missing. The child's first message is the parts under their names (`render/1`),
  and `delegation_started` carries them as they were given. What comes back is the
  child's `finish`, in parts too (`Troupe.Tools.Finish`).

  The description is generated from the definitions actually loaded, so a project
  that ships its own subagents advertises them without a code change.

  A delegation runs at once unless the person asked to see it first (#554, Decision 850):
  `delegation.ask` in a config file names the agent, or the agent's own definition says
  `delegation: ask` (`asks?/2`). Then the agent puts it through the session's approval gate
  before the child starts, with what the gate shows (`gate/4`): the agent and where its
  definition is, the brief's parts, the tools and permissions the child will hold, its
  budget share and its depth, and the subagents it could go to instead. The person runs it,
  edits the brief (`edit/2`, which holds the edit to the same shape), switches the agent,
  denies it with a word back, or lets that agent run unasked for the session.
  """

  @behaviour Troupe.Tool

  alias Troupe.Agent.{Definition, Definitions, Local}
  alias Troupe.{Paths, Tool, Tools}
  alias Troupe.Tools.Finish

  @parts ~w(goal context constraints deliverable do_not)

  @names %{
    "goal" => "Goal",
    "context" => "Context",
    "constraints" => "Constraints",
    "deliverable" => "Deliverable",
    "do_not" => "Do not"
  }

  @impl Troupe.Tool
  def name, do: "delegate"

  @impl Troupe.Tool
  def mode, do: :inline

  @impl Troupe.Tool
  def description do
    "Brief a subagent on one piece of work and receive its finish."
  end

  @impl Troupe.Tool
  def describe(ctx) do
    """
    Brief a subagent. It knows only what the brief says, so write each part for a
    stranger, and none where a part has nothing. You get back its finish, never its
    transcript.

    Independent work goes out in parallel: several `delegate` calls in one turn run
    concurrently.

    Available agents:
    #{agent_list(ctx)}
    """
    |> String.trim()
  end

  defp agent_list(%{definitions: nil}), do: "  (none loaded)"

  defp agent_list(%{definitions: definitions}) do
    case Definitions.subagents(definitions) do
      [] -> "  (none loaded)"
      agents -> Enum.map_join(agents, "\n", fn a -> "  - #{a.name}: #{a.description}" end)
    end
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent" => %{"type" => "string", "description" => "Which subagent to use."},
        "goal" => %{"type" => "string", "description" => "What done looks like, in a sentence."},
        "context" => %{"type" => "string", "description" => "What you know that it needs."},
        "constraints" => %{"type" => "string", "description" => "What it may not touch or break."},
        "deliverable" => %{"type" => "string", "description" => "What to return, in what form."},
        "do_not" => %{"type" => "string", "description" => "What is out of scope."}
      },
      "required" => ["agent" | @parts]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :auto

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, agent} <- Tool.fetch_string(args, "agent"),
         {:ok, brief} <- brief(args),
         :ok <- check_depth(ctx),
         {:ok, definition} <- fetch_definition(ctx, agent),
         :ok <- check_mode(definition) do
      {:defer, {:delegate, definition.name, brief}}
    end
  end

  @doc "The five parts of a brief, or the sentence that refuses it, naming what is missing."
  @spec brief(map()) :: {:ok, map()} | {:error, String.t()}
  def brief(args) do
    case parts(args) do
      {found, []} -> {:ok, found}
      {_found, missing} -> {:error, refusal(missing, Map.has_key?(args, "task"))}
    end
  end

  defp parts(args) do
    Enum.reduce(@parts, {%{}, []}, fn part, {found, missing} ->
      case Finish.text(Map.get(args, part)) do
        nil -> {found, missing ++ [part]}
        value -> {Map.put(found, part, value), missing}
      end
    end)
  end

  @doc """
  A brief as a person edited it at the gate: the parts they sent over the ones it had, held
  to the same shape. A part sent blank is a part taken away, and refused, naming it; a key
  that is no part is refused too.
  """
  @spec edit(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def edit(brief, edits) when is_map(edits) do
    case Map.keys(edits) -- @parts do
      [] ->
        case parts(Map.merge(brief, edits)) do
          {found, []} ->
            {:ok, found}

          {_found, missing} ->
            {:error,
             "the brief has no #{Finish.and_list(missing)}: each of goal, context, constraints, " <>
               "deliverable and do_not needs something, none where it has nothing"}
        end

      others ->
        {:error,
         "#{Finish.and_list(others)} #{if match?([_], others), do: "is", else: "are"} no part of a " <>
           "brief: its parts are goal, context, constraints, deliverable and do_not"}
    end
  end

  def edit(_brief, _edits),
    do:
      {:error, "a brief is its parts by name: goal, context, constraints, deliverable and do_not"}

  @doc "The parts of a brief a person's edit changed, in their order."
  @spec edited(map(), map()) :: [String.t()]
  def edited(before, now), do: Enum.filter(@parts, &(before[&1] != now[&1]))

  @doc """
  Whether a `delegate` to this agent asks the person first (Decision 850): its definition
  says `delegation: ask`, or the session's `delegation.ask` names it. Either is enough, and
  neither can be undone by the other: asking is what a person opted into.
  """
  @spec asks?(Definition.t(), Troupe.Config.t() | map()) :: boolean()
  def asks?(%Definition{} = definition, config) do
    definition.delegation == :ask or
      definition.name in List.wrap(Map.get(config, :delegation_ask))
  end

  @doc """
  What the gate shows of a delegation, as `approval_requested` carries it under
  `delegation`: the agent, where its definition is (for `agents.get`; the gate never edits
  one), the brief, the tools the child will hold with each one's permission, its budget
  share, its depth and the deepest it may go, and the subagents it could go to instead.
  """
  @spec gate(Definition.t(), map(), Definitions.t(), map()) :: map()
  def gate(%Definition{} = definition, brief, definitions, %{depth: depth} = where) do
    %{
      "agent" => definition.name,
      "definition" => definition_link(definition),
      "brief" => brief,
      "tools" => tools(definition, Map.get(where, :session_id)),
      "budget_share" => definition.budget_share,
      "depth" => depth + 1,
      "max_depth" => Map.get(where, :max_depth),
      "agents" =>
        definitions
        |> Definitions.subagents()
        |> Enum.map(&%{"name" => &1.name, "description" => &1.description})
    }
  end

  defp definition_link(definition) do
    %{
      "name" => definition.name,
      "layer" => Local.layer(definition),
      "path" => if(definition.path, do: Paths.display(definition.path)),
      "description" => definition.description
    }
  end

  # A program speaking ACP has no tool list of Troupe's to show.
  defp tools(definition, session_id) do
    if Definition.acp?(definition) do
      []
    else
      for tool <- Tools.for_definition(definition, session_id) do
        name = Tool.name(tool)
        permission = Definition.permission(definition, name, Tool.default_permission(tool))
        %{"name" => name, "permission" => Atom.to_string(permission)}
      end
    end
  end

  @doc "A brief as the child is given it: each part under its name, in the order they come."
  @spec render(map()) :: String.t()
  def render(brief) do
    Enum.map_join(@parts, "\n\n", &Finish.labelled({@names[&1], brief[&1]}))
  end

  defp refusal(missing, task?) do
    old =
      if task?,
        do: " The single `task` field is gone: split what it said into the five parts.",
        else: ""

    "delegate refused: the brief has no #{Finish.and_list(missing)}. A brief has five " <>
      "parts, each its own field: goal, context, constraints, deliverable and do_not; " <>
      "write none where one has nothing, and delegate again with all five." <> old
  end

  # Depth is `length(agent_path) - 1`, so the root is 0 and the default cap of 3
  # allows root -> child -> grandchild -> great-grandchild.
  defp check_depth(ctx) do
    depth = length(ctx.agent_path) - 1
    if depth >= ctx.max_depth, do: {:error, {:max_depth, ctx.max_depth}}, else: :ok
  end

  defp fetch_definition(%{definitions: nil}, agent), do: {:error, {:unknown_agent, agent}}

  defp fetch_definition(%{definitions: definitions}, agent),
    do: Definitions.fetch(definitions, agent)

  defp check_mode(%Definition{mode: :subagent}), do: :ok

  defp check_mode(%Definition{name: name}) do
    {:error, "#{name} is a primary profile, not a subagent. Delegate to a subagent instead."}
  end
end
