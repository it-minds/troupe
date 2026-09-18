defmodule Troupe.Agent.Prompt do
  @moduledoc """
  Builds the system prompt and request for a turn.

  The split between `system/3` and `volatile/1` is what makes the prompt cache
  work. The prefix renders tools, then system, then messages, and a cache entry
  is a prefix match, so anything that changes between turns has to live at the
  very end: the system prompt holds only what is fixed for the life of the agent
  (its definition, the project brief, the workspace survey, the harness facts),
  and per-turn state — the task list, context picked up from the workspace —
  goes into a volatile block appended after the last breakpoint, where it costs
  its own tokens and invalidates nothing (Decision 84).
  """

  alias Troupe.Agent.State
  alias Troupe.{Config, OS, Tools}
  alias Troupe.LLM.{Message, Request}
  alias Troupe.Workspace.Survey

  @type cache :: %{ttl: String.t(), previous: non_neg_integer() | nil} | nil

  @spec request(State.t(), Survey.t() | nil, String.t(), cache()) :: Request.t()
  def request(%State{} = s, survey \\ nil, brief \\ "", cache \\ nil) do
    def = s.definition
    cfg = s.spec.config

    %Request{
      model: Config.resolve_model(cfg, def.model),
      system: system(s, survey, brief),
      messages: s |> State.conversation() |> append_volatile(volatile(s)),
      tools: Tools.specs(def, s.spec.definitions) ++ Troupe.MCP.tool_specs(s.spec.session_id),
      max_tokens: 8192,
      reasoning_effort: def.reasoning_effort || cfg.reasoning_effort,
      agent_path: s.spec.agent_path,
      session_id: s.spec.session_id,
      purpose: :turn,
      cache: cache
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

  @doc """
  The stable half of the prompt: identical on every turn of an agent's life, so
  it sits inside the cached prefix. Nothing volatile belongs here — see
  `volatile/1`.
  """
  @spec system(State.t(), Survey.t() | nil, String.t()) :: String.t()
  def system(%State{} = s, survey \\ nil, brief \\ "") do
    {_shell, os_info} = OS.Process.shell_info()

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

    # Tools
    Use a native tool wherever one fits; reach for `shell` only when none does.
    `read_file` (several paths in one call), `glob` to find files by name, `grep`
    to search contents, `git_read` for status, diffs, log and show. `shell` is
    for building, testing, running things and anything that changes the
    repository — not for `cat`, `ls`, `find`, `grep` or `git diff`.
    Read a file before editing it, and prefer `edit_file` over rewriting a whole
    file with `write_file`. Delegate a self-contained piece of work whose
    intermediate output you do not need to see; do it yourself when you do.

    # Large tool output
    Tool results are bounded. A command keeps its first and last lines, a file
    read a line window, a listing or search the first matches; whatever was cut
    is named in a marker that states the exact call that returns it. Page through
    a truncated command or fetch with `read_output`, and a file with `read_file`
    at the next offset — never re-run a slow or non-idempotent command just to
    see what was omitted. Prefer `grep` and a targeted `read_file` window over
    reading whole files.#{workspace}
    """
  end

  @doc """
  Per-turn state, rendered after the last cache breakpoint or not at all. `nil`
  when there is nothing to say, so a turn with no task list and no workspace
  context sends no extra block.
  """
  @spec volatile(State.t()) :: String.t() | nil
  def volatile(%State{} = s) do
    [task_list(s.todos), watch(s.watch_context)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end

  defp task_list([]), do: nil

  defp task_list(items) do
    "# Current task list\n" <>
      Enum.map_join(items, "\n", fn t -> "- [#{t.status}] #{t.id}: #{t.content}" end)
  end

  defp watch(nil), do: nil
  defp watch(text), do: "# Context from AI comments in the workspace\n#{text}"

  # Only ever appended to a user message: a volatile block after an assistant
  # turn would sit between its tool calls and their results.
  defp append_volatile(messages, nil), do: messages

  defp append_volatile(messages, text) do
    case List.last(messages) do
      %{role: :user, content: content} ->
        List.replace_at(
          messages,
          length(messages) - 1,
          %{role: :user, content: content ++ [Message.volatile_block(text)]}
        )

      _other ->
        messages
    end
  end
end
