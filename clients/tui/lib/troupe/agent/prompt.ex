defmodule Troupe.Agent.Prompt do
  @moduledoc "Builds the system prompt and request for a turn."

  alias Troupe.Agent.State
  alias Troupe.{Config, OS, Tools}
  alias Troupe.LLM.{Message, Request}
  alias Troupe.Workspace.Survey

  @spec request(State.t(), Survey.t() | nil, String.t()) :: Request.t()
  def request(%State{} = s, survey \\ nil, brief \\ "") do
    def = s.definition
    cfg = s.spec.config

    %Request{
      model: Config.resolve_model(cfg, def.model),
      system: system(s, survey, brief),
      messages: State.conversation(s),
      tools: Tools.specs(def, s.spec.definitions),
      max_tokens: 8192,
      reasoning_effort: def.reasoning_effort || cfg.reasoning_effort,
      agent_path: s.spec.agent_path,
      session_id: s.spec.session_id,
      purpose: :turn
    }
  end

  @spec compaction_request(State.t(), [Message.t()]) :: Request.t()
  def compaction_request(%State{} = s, messages) do
    cfg = s.spec.config

    %Request{
      model: Config.resolve_model(cfg, :cheap),
      system:
        "You summarize a coding agent's conversation so the agent can continue with less context. Preserve every fact needed to continue: the task, decisions taken, files touched and their current state, open problems, and exact identifiers. Output only the summary.",
      messages: messages ++ [Message.user("Summarize the conversation so far.")],
      tools: [],
      max_tokens: 4096,
      agent_path: s.spec.agent_path,
      session_id: s.spec.session_id,
      purpose: :compaction
    }
  end

  @spec system(State.t(), Survey.t() | nil, String.t()) :: String.t()
  def system(%State{} = s, survey \\ nil, brief \\ "") do
    {_shell, os_info} = OS.Process.shell_info()

    todo =
      case s.todos do
        [] -> "(empty)"
        items -> Enum.map_join(items, "\n", fn t -> "- [#{t.status}] #{t.id}: #{t.content}" end)
      end

    watch =
      case s.watch_context do
        nil -> ""
        text -> "\n\n# Context from AI comments in the workspace\n#{text}"
      end

    workspace =
      case survey do
        %Survey{} = sv -> Survey.render(sv)
        nil -> ""
      end

    """
    #{s.definition.prompt}#{brief}

    # Harness
    Agent: #{s.spec.agent_path} (profile #{s.definition.name})
    Workspace root: #{s.workspace}
    Isolation: #{s.spec.isolation}
    Platform: #{os_info}
    All paths are relative to the workspace root and confined to it.

    # Current task list
    #{todo}#{workspace}#{watch}
    """
  end
end
