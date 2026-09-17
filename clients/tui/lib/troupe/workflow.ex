defmodule Troupe.Workflow do
  @moduledoc """
  Named, multi-step engineering workflows, run as an *orchestration*: the
  `workflow` agent is an expensive orchestrator that never edits the repository
  itself. It reads the step list, decides when each step is ready, and hands
  every step to the subagent that owns it — which may delegate further in turn,
  up to `max_delegation_depth`. The whole run happens in an isolated git
  worktree that is auto-committed on `finish` and that you `/merge` or
  `/discard` from the TUI.

  A step is a name, a directive, the `agent` responsible for it, and whether it
  may run concurrently with the steps beside it. A step with no agent is the
  orchestrator's own (planning, deciding, reporting).

  The module is intentionally thin and free of state: it loads step definitions
  and renders a plan. Running a workflow is `Troupe.dispatch/3` on the
  `workflow` primary agent with the plan as its prompt, so every existing
  mechanism — branch windows, worktrees, approvals, budgets, resume — applies
  unchanged.

  ## Defining a workflow

  A workflow lives at `.troupe/workflows/<name>.json` in the workspace as a
  JSON array of step objects:

      [
        {"name": "understand", "agent": "explore",  "prompt": "Read the repository and ..."},
        {"name": "plan",                            "prompt": "Write the execution plan ..."},
        {"name": "implement", "agent": "implementer", "prompt": "Implement the change ..."},
        {"name": "test",      "agent": "implementer", "prompt": "Add or fix tests ..."},
        {"name": "verify",    "agent": "reviewer",  "prompt": "Run the full verification ..."}
      ]

  `agent` names a subagent (`/agents` lists them); omitted or `null`, the
  orchestrator does that step itself. `"parallel": true` marks a step that may
  be dispatched in the same turn as the adjacent steps also marked parallel —
  several `delegate` calls in one turn run concurrently.

  With no file (or `name: "default"`), `default_steps/0` is used — a generic
  engineering pipeline that suits any repository. A workflow whose JSON is
  invalid falls back to the default rather than failing the run.
  """

  @type step :: %{
          name: String.t(),
          prompt: String.t(),
          agent: String.t() | nil,
          parallel: boolean()
        }

  @doc "The bundled default workflow: a generic engineering pipeline, one owner per step."
  @spec default_steps() :: [step()]
  def default_steps do
    [
      step(
        "understand",
        "explore",
        "Read the repository and the project brief, then report what the task touches: " <>
          "the files and subsystems involved, the existing patterns to follow, and the " <>
          "build/test/lint commands to run. Quote paths and line numbers."
      ),
      step(
        "plan",
        nil,
        "From the research, decide the change and write it out as your todo list " <>
          "(`todo_write`), one todo per remaining step. Say explicitly which files each " <>
          "later step may touch so two subagents never edit the same file at once."
      ),
      step(
        "implement",
        "implementer",
        "Implement the change in minimal, correct edits. Read before you edit and keep " <>
          "changes as small as the task allows."
      ),
      step(
        "test",
        "implementer",
        "Add or fix tests for the change and run the project's test command until it " <>
          "passes. Fix any regression you introduced before reporting back."
      ),
      step(
        "document",
        "implementer",
        "Update the documentation and durable notes the change affects. Record anything " <>
          "non-obvious with `remember`."
      ),
      step(
        "verify",
        "reviewer",
        "Run the full verification (compile with warnings-as-errors, the test suite, " <>
          "format and lint) and review the diff against the task. Report every failure " <>
          "and every gap you find; do not fix them yourself."
      )
    ]
  end

  @doc "Builds one step; `agent` is `nil` for a step the orchestrator does itself."
  @spec step(String.t(), String.t() | nil, String.t(), boolean()) :: step()
  def step(name, agent, prompt, parallel \\ false) do
    %{name: name, agent: agent, prompt: prompt, parallel: parallel}
  end

  @doc """
  Loads a named workflow from `.troupe/workflows/<name>.json`, or the bundled
  default when the name is `"default"`, no matching file exists, or the file
  does not parse into a non-empty list of steps.
  """
  @spec load(String.t(), String.t()) :: [step()]
  def load(workspace, name)

  def load(_workspace, "default"), do: default_steps()

  def load(workspace, name) when is_binary(name) do
    path = workflow_path(workspace, name)

    case read_steps(path) do
      {:ok, steps} -> steps
      _ -> default_steps()
    end
  end

  @doc "Path a named workflow's definition is read from."
  @spec workflow_path(String.t(), String.t()) :: String.t()
  def workflow_path(workspace, name) do
    Path.join([workspace, ".troupe", "workflows", name <> ".json"])
  end

  defp read_steps(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content),
         steps = parse_steps(data),
         [_ | _] <- steps do
      {:ok, steps}
    else
      _ -> :error
    end
  end

  defp parse_steps(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"name" => name, "prompt" => prompt} = raw when is_binary(name) and is_binary(prompt) ->
        [step(name, parse_agent(Map.get(raw, "agent")), prompt, Map.get(raw, "parallel") == true)]

      _ ->
        []
    end)
  end

  defp parse_steps(_), do: []

  defp parse_agent(agent) when is_binary(agent) do
    case String.trim(agent) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_agent(_), do: nil

  @doc """
  Renders the full prompt sent to the `workflow` agent for `task` using `steps`:
  the task, the orchestration contract, then the ordered step list with the
  agent that owns each step.
  """
  @spec plan([step()], String.t()) :: String.t()
  def plan(steps, task) do
    steps = if steps == [], do: default_steps(), else: steps

    body =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} ->
        "#{i}. #{owner(s)}#{if s.parallel, do: " `parallel`", else: ""} **#{s.name}:** #{s.prompt}"
      end)

    """
    Task: #{task}

    You are orchestrating this workflow. Run it top to bottom as your todo list,
    one todo in progress at a time. Each step below names the agent responsible
    for it: delegate that step to that agent and do not do its work yourself.
    A step marked `[you]` is yours — planning, deciding, and reporting.

    #{body}

    #{rules(steps)}

    When every step is complete, call `finish` with a summary of what changed
    and how it was verified.
    """
  end

  defp owner(%{agent: nil}), do: "[you]"
  defp owner(%{agent: agent}), do: "[`#{agent}`]"

  defp rules(steps) do
    parallel =
      if Enum.any?(steps, & &1.parallel) do
        "Steps marked `parallel` in the same run of the list may be delegated in " <>
          "one turn; several `delegate` calls in a turn run concurrently.\n    - "
      else
        ""
      end

    """
    Rules:
    - #{parallel}Every delegate prompt must stand alone. The subagent sees only
      what you write: restate the task, name the files and commands the earlier
      steps found, and say exactly what to produce. It cannot see your
      transcript or another subagent's.
    - Never delegate two concurrent steps that write the same file.
    - Carry each step's result into the next prompt: a subagent's `finish`
      summary is all you get back from it, so quote what the next step needs.
    - When a step reports a failure, decide what to do — re-delegate it with the
      failure quoted, hand it to a different agent, or change the plan — and say
      why in your summary. Do not skip a test or verify step silently.
    - You read, search and plan; subagents write, run and verify. Delegate
      research to `explore` rather than reading the tree yourself.
    """
    |> String.trim_trailing()
  end

  @doc """
  Resolves `<name> <task>` (or `name: task`) that arrived as the dispatch
  prompt into `{workflow_name, task}`. A leading `name:` or a leading word that
  names a workflow on disk (`.troupe/workflows/<name>.json`) selects that
  workflow; anything else — including a bare first word with no matching file —
  is the `"default"` workflow with the whole prompt as the task.
  """
  @spec split(String.t(), String.t()) :: {String.t(), String.t()}
  def split(workspace, prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)
    available = available(workspace)

    case String.split(prompt, ~r/\s+/, parts: 2) do
      [word, rest] when byte_size(word) > 0 ->
        cond do
          String.ends_with?(word, ":") ->
            {String.trim_trailing(word, ":"), String.trim(rest)}

          word == "default" ->
            {"default", String.trim(rest)}

          word in available ->
            {word, String.trim(rest)}

          true ->
            {"default", prompt}
        end

      _ ->
        {"default", prompt}
    end
  end

  @doc "Names of the workflows on disk under `.troupe/workflows`, sorted."
  @spec available(String.t()) :: [String.t()]
  def available(workspace) do
    workspace
    |> Path.join(".troupe/workflows/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end
end
