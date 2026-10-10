defmodule Troupe.Bench.Onboarding do
  @moduledoc """
  The offline bench's onboarding scenarios (issue #516's slice 8, Decision 834): a
  repository for each other tool, with that tool's files only, onboarded as `troupe
  onboard` would with every proposal accepted, then a session asked for something its
  instructions decide.

  A session reads no other tool's file (Decision 828), so a rule in a `CLAUDE.md`, an
  opencode agent, a Cursor rule or Copilot's instructions reaches a prompt only through the
  files onboarding wrote. Each fixture carries one house rule, the line every file written
  starts with. The scripted model writes the note with that line when it finds the rule in
  its prompt and without it when it does not, so the outcome holds only when the rule came
  through. Each scenario measures what the instructions took of the first prompt, the files
  onboarding wrote and the tool's files it left out, held to budgets in
  `priv/bench/budgets.json` as the other scenarios' are.
  """

  alias Troupe.Bench.{Model, Scenario}
  alias Troupe.Onboard

  @note "The harbour opens at six."
  @rule ~r/Every file you write starts with the line `([^`\n]+)`/

  @doc "The onboarding scenarios, in report order."
  @spec all() :: [Scenario.t()]
  def all, do: [claude_code(), opencode(), cursor(), copilot()]

  # -- the fixtures -----------------------------------------------------------------

  # The project file, with an agent and a command beside it, and the person's own
  # `CLAUDE.local.md`, which onboarding leaves out (Decision 827).
  defp claude_code do
    scenario("claude_code", "Claude Code", %{
      "CLAUDE.md" => """
      # Harbour notes

      #{rule("Claude Code")}

      - Keep each note to one line.
      """,
      "CLAUDE.local.md" => "Mine only: the kettle is in the left cupboard.\n",
      ".claude/agents/proofreader.md" => """
      ---
      name: proofreader
      description: Reads a note for mistakes.
      tools: Read, Grep, Glob
      ---
      You read notes and say what is wrong in them, and where.
      """,
      ".claude/commands/summarise.md" => """
      ---
      description: Summarise the notes
      ---
      Summarise the notes in $ARGUMENTS.
      """
    })
  end

  # opencode's own instructions file is `AGENTS.md`, which Troupe reads as it is; what is
  # opencode's alone is its agents. So the rule is in the prompt of a primary agent, and
  # the session starts on it, as a person picking that agent would. A disabled agent in
  # `opencode.json` is left out (Decision 824).
  defp opencode do
    scenario(
      "opencode",
      "opencode",
      %{
        ".opencode/agents/scribe.md" => """
        ---
        description: Writes the harbour's notes.
        mode: primary
        ---
        You write the harbour's notes.

        #{rule("opencode")}
        """,
        "opencode.json" => """
        {
          "agent": {
            "proofreader": {
              "description": "Reads a note for mistakes.",
              "mode": "subagent",
              "prompt": "You read notes and say what is wrong in them, and where.",
              "tools": {"write": false, "edit": false}
            },
            "old-helper": {"disable": true}
          }
        }
        """,
        ".opencode/commands/summarise.md" => """
        ---
        description: Summarise the notes
        ---
        Summarise the notes in $ARGUMENTS.
        """
      },
      agent: "scribe"
    )
  end

  # A rule that always applies, one for some files, which joins no prompt here, and one in
  # a folder under `.cursor/rules`, which onboarding leaves out (Decision 827).
  defp cursor do
    scenario("cursor", "Cursor", %{
      ".cursor/rules/house.mdc" => """
      ---
      description: The harbour's house rules
      alwaysApply: true
      ---
      #{rule("Cursor")}
      """,
      ".cursor/rules/docs.mdc" => """
      ---
      description: How docs are written
      globs: docs/**
      alwaysApply: false
      ---
      Docs are written in short sentences.
      """,
      ".cursor/rules/archive/old.mdc" => """
      ---
      alwaysApply: true
      ---
      Notes were kept in a ledger.
      """
    })
  end

  # The repository's instructions, and instructions for some files.
  defp copilot do
    scenario("copilot", "Copilot", %{
      ".github/copilot-instructions.md" => """
      # Harbour notes

      #{rule("Copilot")}
      """,
      ".github/instructions/docs.instructions.md" => """
      ---
      applyTo: "docs/**"
      ---
      Docs are written in short sentences.
      """
    })
  end

  defp rule(tool),
    do: "Every file you write starts with the line `#{first_line(tool)}`, then its content."

  defp first_line(tool), do: "# kept by #{tool}'s rule"

  defp scenario(name, tool, files, opts \\ []) do
    %Scenario{
      name: "onboard_" <> name,
      title: "#{tool}'s files onboarded, and its rule in the prompt",
      prompt: "Write today's note to note.txt with write_file: #{@note}",
      files: files,
      prepare: &onboard/1,
      agent: opts[:agent],
      script: [&follow_rule/1, {:text, "note.txt is written."}],
      outcome: {:file, "note.txt", first_line(tool) <> "\n" <> @note <> "\n"},
      measure: &measure/1
    }
  end

  # -- onboarding, the task and the measures ---------------------------------------------

  @doc """
  `troupe onboard` in a run's workspace with every proposal accepted, a new `AGENTS.md`
  among them, which `--yes` never creates: what a person answering yes to each question
  leaves. The run's own home and config directories stand for the person's, so nothing
  but the fixture is read. Answers the marks the measure reads: the files written, those
  that failed, and the tool's files onboarding left out (skipped, refused, or failed).
  """
  @spec onboard(map()) :: map()
  def onboard(%{workspace: workspace} = dirs) do
    opts = [home: dirs.home, config_dir: dirs.config_dir, state_dir: dirs.state_dir]
    plan = Onboard.plan(workspace, opts)

    written =
      Enum.count(plan.proposals, &match?({:ok, _written}, Onboard.accept(&1, workspace, opts)))

    failed = length(plan.proposals) - written

    %{
      written: written,
      failed: failed,
      left_out: length(plan.skipped) + length(plan.refused) + failed
    }
  end

  # The scripted model's one decision: the note, under the rule's line when the rule is
  # anywhere in its prompt, and bare when it is not.
  defp follow_rule(request) do
    first =
      case Regex.run(@rule, Model.prompt_text(request)) do
        [_, line] -> line <> "\n"
        nil -> ""
      end

    {:tools, [{"write_file", %{"path" => "note.txt", "content" => first <> @note <> "\n"}}]}
  end

  defp measure(ctx) do
    {first, _task, _usage} = hd(ctx.requests)
    written = Map.get(ctx.marks, :written, 0)

    {[
       {"instruction_bytes", "instructions in the first prompt", "bytes",
        instruction_bytes(first, ctx)},
       {"files_written", "files onboarding wrote", "files", written},
       {"files_left_out", "the tool's files onboarding left out", "files",
        Map.get(ctx.marks, :left_out, 0)}
     ],
     [
       {"onboarded", "onboarding wrote every file it proposed",
        written > 0 and Map.get(ctx.marks, :failed, 0) == 0}
     ]}
  end

  @section "# Instruction files\n"

  # What the instructions took of a request's system prompt, the scratch workspace's path
  # written `<workspace>` as everywhere in the bench: the instruction files' section and,
  # for a session on an agent the workspace defines, that agent's own prompt before it,
  # both ending where the environment's section starts.
  defp instruction_bytes(request, ctx) do
    system = String.replace(request.system || "", ctx.workspace, "<workspace>")
    [head | _] = String.split(system, "\n\n<environment>", parts: 2)

    case {ctx.scenario.agent, :binary.match(head, @section)} do
      {nil, {at, _length}} -> byte_size(head) - at
      {nil, :nomatch} -> 0
      {_agent, _section} -> byte_size(head)
    end
  end
end
