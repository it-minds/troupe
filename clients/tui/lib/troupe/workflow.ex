defmodule Troupe.Workflow do
  @moduledoc """
  Named, multi-step engineering workflows. A workflow is an *ordered list of
  steps* (each a name and a directive) that a `workflow` agent runs top to
  bottom as its todo list — branch off, describe, implement, test, document,
  verify — inside an isolated git worktree that it auto-commits on `finish`
  and that you `/merge` or `/discard` from the TUI.

  The whole thing is intentionally thin and free of state: a pure module that
  loads step definitions and renders a plan. Running a workflow is `Troupe.dispatch
  /1` on the `workflow` primary agent with the plan as its prompt, so every
  existing mechanism — branch windows, worktrees, approvals, budgets, resume
  — applies unchanged.

  ## Defining a workflow

  A workflow lives at `.troupe/workflows/<name>.json` in the workspace as a
  JSON array of step objects:

      [
        {"name": "understand", "prompt": "Read the repository and restate ..."},
        {"name": "plan",       "prompt": "Write the execution plan as todos ..."},
        {"name": "implement",  "prompt": "Implement the change ..."},
        {"name": "test",       "prompt": "Add or fix tests and run them ..."}
      ]

  With no file (or `name: "default"`), `Troupe.Workflow.default_steps/0` is
  used — a generic engineering pipeline that suits any repository. A workflow
  whose JSON is invalid falls back to the default rather than failing the run.
  """

  @type step :: %{name: String.t(), prompt: String.t()}

  @doc "The bundled default workflow: a generic engineering pipeline."
  @spec default_steps() :: [step()]
  def default_steps do
    [
      %{
        name: "understand",
        prompt:
          "Read the repository and the project brief. Restate the task in your own words, " <>
            "name the files and subsystems you will touch, and note any tests/commands to run."
      },
      %{
        name: "plan",
        prompt:
          "Write the execution plan as a todo list (todo_write) with one todo per step below. " <>
            "Mark `understand` and `plan` complete once done."
      },
      %{
        name: "implement",
        prompt:
          "Implement the change in minimal, correct edits. Read before you edit; keep changes " <>
            "as small as the task allows. Split independent sub-tasks to subagents where useful."
      },
      %{
        name: "test",
        prompt:
          "Add or fix tests for the change and run the project's test/lint command until it " <>
            "passes. Fix any regressions you introduce before moving on."
      },
      %{
        name: "document",
        prompt:
          "Update documentation and durable notes affected by the change. Record anything " <>
            "non-obvious with `remember`."
      },
      %{
        name: "verify",
        prompt:
          "Run the full verification (compile with warnings-as-errors, tests, format/lint) and " <>
            "confirm nothing is broken. Leave the workspace clean of scratch files."
      }
    ]
  end

  @doc """
  Loads a named workflow from `.troupe/workflows/<name>.json`, or `:default`
  when the name is `"default"`, no matching file exists, or the file does not
  parse into a non-empty list of `%{name, prompt}` steps.
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
      %{"name" => name, "prompt" => prompt} when is_binary(name) and is_binary(prompt) ->
        [%{name: name, prompt: prompt}]

      _ ->
        []
    end)
  end

  defp parse_steps(_), do: []

  @doc """
  Renders the full prompt sent to the `workflow` agent for `task` using `steps`:
  the task, then the ordered step list. The agent parses `<name>: task` off the
  front of `task` to pick the workflow; a bare `task` uses the default.
  """
  @spec plan([step()], String.t()) :: String.t()
  def plan(steps, task) do
    steps = if steps == [], do: default_steps(), else: steps

    body =
      steps
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "#{i}. **#{s.name}: ** #{s.prompt}" end)

    """
    Task: #{task}

    Run this workflow, top to bottom, as your todo list. Keep one todo in
    progress at a time.

    #{body}

    When every step is complete, call `finish` with a summary of what you
    changed and how it was verified.
    """
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
