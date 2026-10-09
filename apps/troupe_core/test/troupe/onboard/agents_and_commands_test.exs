defmodule Troupe.Onboard.AgentsAndCommandsTest do
  @moduledoc """
  Other tools' agents and commands as onboarding proposals (Decision 824; #516, slice 4):
  Claude Code's `.claude/agents`, `.claude/settings.json` permissions and
  `.claude/commands`, opencode's `agent` entries, `.opencode/agents` and
  `.opencode/commands`, each a proposal for a `.troupe/` file whose tools, permissions and
  model follow #516's table, with every key left out or changed in its notes, and the
  same proposals from the same files.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Commands.Local
  alias Troupe.Onboard.AgentsAndCommands

  @reviewer """
  ---
  name: reviewer
  description: Reviews a change for what is wrong with it.
  tools: Read, Grep, Glob
  model: inherit
  ---
  You review code.
  """

  defp survey(context, opts \\ []), do: AgentsAndCommands.survey(context.workspace, opts)

  defp proposal(%{proposals: proposals}, path) do
    Enum.find(proposals, &(&1.path == path)) ||
      flunk("no proposal for #{path}: #{inspect(Enum.map(proposals, & &1.path))}")
  end

  defp definition(proposal) do
    {:ok, definition} =
      Definition.parse(Path.basename(proposal.path, ".md"), proposal.content, :project)

    definition
  end

  defp skipped(%{skipped: skipped}, source), do: Enum.filter(skipped, &(&1.source == source))

  defp sha256(context, relative),
    do: :sha256 |> :crypto.hash(read_file(context, relative)) |> Base.encode16(case: :lower)

  describe "the fixture repository (#516's slice 4)" do
    setup context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)

      write_file(context, ".claude/agents/scout.md", """
      ---
      name: scout
      description: Looks things up.
      tools: Read, Bash, WebSearch
      disallowedTools: Write
      model: sonnet
      color: blue
      ---
      You scout.
      """)

      write_file(context, ".claude/agents/migrator.md", """
      ---
      name: migrator
      description: Moves a schema forward.
      tools: Read, Edit, Write, Bash, mcp__tracker__search
      model: claude-opus-4-5
      maxTurns: 30
      permissionMode: acceptEdits
      ---
      You migrate schemas.
      """)

      write_file(context, ".claude/settings.json", ~s|{
        "permissions": {
          "allow": ["Bash", "Bash(git log:*)"],
          "deny": ["Read(./.env)"],
          "defaultMode": "acceptEdits"
        },
        "hooks": {}
      }|)

      write_file(context, "opencode.json", ~s({
        "permission": {"webfetch": "ask"},
        "agent": {
          "release": {
            "description": "Cuts a release.",
            "mode": "primary",
            "model": "anthropic/claude-sonnet-4-5",
            "prompt": "You cut releases.",
            "temperature": 0.1,
            "permission": {"bash": "allow", "edit": "deny", "lsp": "allow"}
          }
        }
      }))

      write_file(context, ".opencode/agents/docs-writer.md", """
      ---
      description: Writes and maintains project documentation
      mode: subagent
      tools:
        bash: false
      ---
      You write documentation.
      """)

      write_file(context, ".claude/commands/fix-issue.md", """
      ---
      description: Fix a GitHub issue
      argument-hint: [issue-number]
      allowed-tools: Bash(gh issue view:*)
      model: haiku
      ---
      Fix issue $ARGUMENTS. Its text: !`gh issue view $ARGUMENTS`
      """)

      write_file(
        context,
        ".claude/commands/commit.md",
        "Write a commit message for the staged change.\n"
      )

      write_file(context, ".claude/commands/migrate.md", """
      ---
      description: Migrate a component
      ---
      Migrate $1 from $2 to $3.
      """)

      :ok
    end

    test "five agents and three commands are proposed, each from its file", context do
      survey = survey(context)

      assert Enum.map(survey.proposals, & &1.path) == [
               "agents/docs-writer.md",
               "agents/migrator.md",
               "agents/release.md",
               "agents/reviewer.md",
               "agents/scout.md",
               "commands/commit.md",
               "commands/fix-issue.md",
               "commands/migrate.md"
             ]

      assert Enum.all?(survey.proposals, &(&1.target == :repo))

      reviewer = proposal(survey, "agents/reviewer.md")
      assert reviewer.source == ".claude/agents/reviewer.md"
      assert reviewer.source_hash == sha256(context, ".claude/agents/reviewer.md")

      release = proposal(survey, "agents/release.md")
      assert release.source == "opencode.json"
      assert release.source_hash == sha256(context, "opencode.json")

      assert proposal(survey, "agents/docs-writer.md").source == ".opencode/agents/docs-writer.md"
      assert proposal(survey, "commands/migrate.md").source == ".claude/commands/migrate.md"
      assert survey.skipped == []
    end

    test "Claude Code's subagents: tools, permissions and models as #516's table maps them",
         context do
      survey = survey(context)

      reviewer = survey |> proposal("agents/reviewer.md") |> definition()
      assert reviewer.mode == :subagent
      assert reviewer.prompt == "You review code."
      assert reviewer.description == "Reviews a change for what is wrong with it."
      assert reviewer.tools == ["read_file", "grep", "glob", "read_output", "finish"]
      assert reviewer.model == nil
      # The settings' deny for some reads makes reading ask; its allow of Bash is for a
      # tool the reviewer does not have.
      assert reviewer.permissions == %{"read_file" => :ask}

      scout = survey |> proposal("agents/scout.md") |> definition()
      assert scout.tools == ["read_file", "shell", "read_output", "finish"]
      assert scout.permissions == %{"read_file" => :ask, "shell" => :auto, "write_file" => :deny}
      assert scout.model == nil

      migrator = survey |> proposal("agents/migrator.md") |> definition()

      assert migrator.tools == [
               "read_file",
               "edit_file",
               "write_file",
               "shell",
               "mcp.tracker.search",
               "read_output",
               "finish"
             ]

      assert migrator.permissions == %{"read_file" => :ask, "shell" => :auto}
      # A model's own name is written; an alias is not.
      assert migrator.model == "claude-opus-4-5"
      assert migrator.max_turns == 30
    end

    test "every key left out or changed is a note with its reason", context do
      survey = survey(context)

      settings_notes = [
        "Bash(git log:*) in .claude/settings.json's permissions.allow is left out: Troupe allows a tool whole or not at all, so a rule allowing some of its uses is not carried.",
        "Read(./.env) in .claude/settings.json's permissions.deny cannot be carried as written: Troupe allows a tool whole or not at all, so read_file asks every time instead.",
        "permissions.defaultMode in .claude/settings.json is left out: a mode for all of a session's approvals has no counterpart here, where approvals are per tool."
      ]

      assert proposal(survey, "agents/reviewer.md").notes ==
               [
                 "The name reviewer is that of Troupe's built-in reviewer agent, which this file replaces in this workspace.",
                 "The model inherit is left out: an agent without a model runs on the session's, which is what inherit asks for."
               ] ++ settings_notes

      assert proposal(survey, "agents/scout.md").notes ==
               [
                 "WebSearch in tools is left out: Troupe has no web search tool.",
                 "The model sonnet is left out: it is Claude Code's name for a model it picks itself, which onboarding cannot ask a session for, so the agent runs on the session's model."
               ] ++ settings_notes ++ ["color is left out: Troupe shows no colour per agent."]

      assert proposal(survey, "agents/migrator.md").notes ==
               settings_notes ++
                 [
                   "permissionMode is left out: a mode for all of an agent's approvals has no counterpart here, where approvals are per tool."
                 ]

      assert proposal(survey, "agents/release.md").notes == [
               "lsp in permission is left out: Troupe has no language-server tool.",
               "temperature is left out: Troupe sets no temperature per agent."
             ]

      assert proposal(survey, "agents/docs-writer.md").notes == []
    end

    test "opencode's agents: mode, permissions under the file's, and the model as written",
         context do
      survey = survey(context)

      release = survey |> proposal("agents/release.md") |> definition()
      assert release.mode == :primary
      assert release.prompt == "You cut releases."
      assert release.description == "Cuts a release."
      assert release.model == "anthropic/claude-sonnet-4-5"
      assert release.tools == :all

      assert release.permissions == %{
               "shell" => :auto,
               "edit_file" => :deny,
               "write_file" => :deny,
               "web_fetch" => :ask
             }

      writer = survey |> proposal("agents/docs-writer.md") |> definition()
      assert writer.mode == :subagent
      assert writer.prompt == "You write documentation."
      assert writer.permissions == %{"shell" => :deny, "web_fetch" => :ask}
      assert Definition.permission(writer, "shell", :ask) == :deny
    end

    test "commands: description and hint carried, the rest left out and said", context do
      survey = survey(context)

      fix = proposal(survey, "commands/fix-issue.md")

      assert fix.content ==
               """
               ---
               description: "Fix a GitHub issue"
               argument-hint: "[issue-number]"
               ---

               Fix issue $ARGUMENTS. Its text: !`gh issue view $ARGUMENTS`
               """

      assert fix.notes == [
               "allowed-tools is left out: it lets the command's turn use those tools without asking, and a Troupe command is a prompt that goes through the session's approvals like any other (Decision 763).",
               "model is left out: a Troupe command runs on the session's agent and its model (Decision 763).",
               "The body's !`...` shell lines stay as written: Troupe does not run a command's shell lines before sending it, so the model reads the command rather than its output."
             ]

      commit = proposal(survey, "commands/commit.md")
      assert commit.content == "Write a commit message for the staged change.\n"
      assert commit.notes == []

      assert proposal(survey, "commands/migrate.md").notes == [
               "The body's $1, $2, $3 stay as written: Troupe fills $ARGUMENTS alone, with everything typed after the command's name."
             ]
    end

    test "running it again on the same files gives the same proposals, written or not", context do
      first = survey(context)
      assert survey(context) == first

      # What a writer would leave behind changes nothing: the proposals depend on the
      # other tools' files alone.
      for %{path: path, content: content} <- first.proposals,
          do: write_file(context, Path.join(".troupe", path), content)

      assert survey(context) == first
    end

    test "Troupe's loaders read the proposed files back as proposed", context do
      survey = survey(context)

      for %{path: path, content: content} <- survey.proposals,
          do: write_file(context, Path.join(".troupe", path), content)

      defs = Definitions.load(context.workspace)

      for %{path: "agents/" <> _} = proposal <- survey.proposals do
        expected = definition(proposal)
        assert Definitions.fetch!(defs, expected.name) == expected
      end

      commands = Map.new(Local.list(context.workspace), &{&1.name, &1})
      assert commands["fix-issue"].description == "Fix a GitHub issue"
      assert commands["fix-issue"].hint == "[issue-number]"

      assert commands["fix-issue"].body ==
               "Fix issue $ARGUMENTS. Its text: !`gh issue view $ARGUMENTS`"

      assert commands["commit"].description == ""
      assert commands["migrate"].body == "Migrate $1 from $2 to $3."
      assert Enum.all?(Map.values(commands), &(&1.layer == :project))
    end
  end

  describe "Claude Code's subagents" do
    test "rules for some uses: a grant asks, a deny asks, and each is said", context do
      write_file(context, ".claude/agents/scout.md", """
      ---
      name: scout
      tools: Read, Bash, NotebookEdit, Bash(git log:*, git diff:*), Grep(TODO), mcp__tracker__search, mcp__wiki, mcp__wiki__*, Frobnicate
      disallowedTools: Write, Bash(rm *), WebSearch
      maxTurns: nope
      flavour: strawberry
      ---
      You scout.
      """)

      scout = survey(context) |> proposal("agents/scout.md")
      definition = definition(scout)

      assert definition.tools == [
               "read_file",
               "shell",
               "mcp.tracker.search",
               "grep",
               "read_output",
               "finish"
             ]

      # `Bash` is granted whole, so its rule adds nothing; `Grep(TODO)` offers grep, asking;
      # `Bash(rm *)` in disallowedTools makes the whole of shell ask.
      assert definition.permissions == %{"write_file" => :deny, "shell" => :ask, "grep" => :ask}
      assert definition.max_turns == nil

      assert scout.notes == [
               "NotebookEdit in tools is left out: Troupe has no notebook tool.",
               "Bash(git log:*, git diff:*) in tools cannot be carried as written: Troupe allows a tool whole or not at all, so shell is offered and asks every time.",
               "Grep(TODO) in tools cannot be carried as written: Troupe allows a tool whole or not at all, so grep is offered and asks every time.",
               "mcp__wiki in tools is left out: Troupe names an MCP server's tools one by one, not a whole server.",
               "mcp__wiki__* in tools is left out: Troupe names an MCP server's tools one by one, not by a pattern.",
               "Frobnicate in tools is left out: it is not a tool Troupe has.",
               "Bash(rm *) in disallowedTools cannot be carried as written: Troupe allows a tool whole or not at all, so shell asks every time instead.",
               "WebSearch in disallowedTools is left out: Troupe has no web search tool.",
               "maxTurns \"nope\" is left out: it is not a positive number, so the agent has the session's limit.",
               "flavour is left out: it is not a key a Troupe agent reads."
             ]
    end

    test "the name is the frontmatter's, else the file's, made one Troupe can give", context do
      write_file(context, ".claude/agents/a-file.md", "---\nname: named\n---\nNamed.")
      write_file(context, ".claude/agents/plain.md", "Just a prompt.")
      write_file(context, ".claude/agents/upper.md", "---\nname: Code Reviewer\n---\nReviews.")
      write_file(context, ".claude/agents/symbols.md", "---\nname: \"!!!\"\n---\nNo.")

      survey = survey(context)

      assert survey |> proposal("agents/named.md") |> definition() |> Map.get(:prompt) == "Named."
      assert proposal(survey, "agents/named.md").source == ".claude/agents/a-file.md"

      assert survey |> proposal("agents/plain.md") |> definition() |> Map.get(:prompt) ==
               "Just a prompt."

      assert proposal(survey, "agents/code-reviewer.md").notes == [
               "The name \"Code Reviewer\" is code-reviewer here: Troupe's names are lower-case letters, digits and dashes."
             ]

      assert [%{name: "!!!", reason: reason}] = skipped(survey, ".claude/agents/symbols.md")
      assert reason =~ "is not a name Troupe can give"
    end

    test "a subagent whose tools Troupe has none of is not proposed, as Claude Code would not start it",
         context do
      write_file(
        context,
        ".claude/agents/notes.md",
        "---\ntools: NotebookEdit, WebSearch\n---\nNotes."
      )

      survey = survey(context)
      assert survey.proposals == []

      assert [%{reason: reason}] = skipped(survey, ".claude/agents/notes.md")
      assert reason =~ "none of its tools (NotebookEdit, WebSearch) is one Troupe has"
    end

    test "frontmatter YAML cannot read is read a line per key, and said", context do
      write_file(context, ".claude/agents/helper.md", """
      ---
      name: helper
      description: Use when: the build breaks
      tools:
        - Read
        - Grep
      ---
      You help.
      """)

      helper = survey(context) |> proposal("agents/helper.md")
      assert definition(helper).description == "Use when: the build breaks"
      assert definition(helper).tools == ["read_file", "grep", "read_output", "finish"]

      assert helper.notes == [
               "The frontmatter is not YAML, so each of its lines is read as a key and its value."
             ]
    end

    test "the settings' rules for whole tools are each agent's, for the tools it has", context do
      write_file(context, ".claude/agents/reader.md", "---\ntools: Read, Grep\n---\nReads.")
      write_file(context, ".claude/agents/anything.md", "Does anything.")

      write_file(context, ".claude/settings.json", ~s|{
        "permissions": {
          "allow": ["Read", "Edit", "mcp__tracker__search", "mcp__wiki"],
          "ask": ["Grep"],
          "deny": ["Bash", "WebFetch(domain:example.com)", "Read(./.env)"],
          "additionalDirectories": ["../other"]
        }
      }|)

      survey = survey(context)

      # `Read(./.env)`'s deny is for some uses, so reading asks, and asking beats allowing.
      assert definition(proposal(survey, "agents/reader.md")).permissions == %{
               "read_file" => :ask,
               "grep" => :ask
             }

      assert definition(proposal(survey, "agents/anything.md")).permissions == %{
               "read_file" => :ask,
               "grep" => :ask,
               "edit_file" => :auto,
               "write_file" => :auto,
               "shell" => :deny,
               "web_fetch" => :ask,
               "mcp.tracker.search" => :auto
             }

      notes = proposal(survey, "agents/anything.md").notes

      assert "mcp__wiki in .claude/settings.json's permissions.allow is left out: Troupe names an MCP server's tools one by one, not a whole server." in notes

      assert "permissions.additionalDirectories in .claude/settings.json is left out: a Troupe agent's tools reach its session's workspace and read roots." in notes
    end
  end

  describe "opencode's agents" do
    test "an agent without a mode is primary, saying why; opencode.jsonc is read", context do
      write_file(context, "opencode.jsonc", """
      // a repository's own
      {"agent": {"helper": {"description": "Helps.", "prompt": "You help.",}}}
      """)

      helper = survey(context) |> proposal("agents/helper.md")
      assert helper.source == "opencode.jsonc"
      assert definition(helper).mode == :primary

      assert [note] = helper.notes
      assert note =~ "The mode is not given, which opencode reads as all"
      assert note =~ "write subagent for other agents to delegate to it"
    end

    test "an entry without a prompt adjusts the built-in of that name", context do
      write_file(context, "opencode.json", ~s({
        "permission": {"bash": "deny"},
        "agent": {
          "build": {"permission": {"edit": "ask"}, "steps": 12},
          "plan": {"permission": {"bash": "ask"}},
          "solo": {"description": "No prompt."}
        }
      }))

      builtin = Definitions.load(Path.join(context.base, "no-such-dir"))
      survey = survey(context)

      build = survey |> proposal("agents/build.md") |> definition()
      assert build.prompt == Definitions.fetch!(builtin, "build").prompt
      assert build.mode == :primary
      assert build.max_turns == 12
      assert build.budget_share == 1.0
      # The file's permission is under each agent's own.
      assert build.permissions["shell"] == :deny
      assert build.permissions["edit_file"] == :ask

      assert proposal(survey, "agents/build.md").notes == [
               "The name build is that of Troupe's built-in build agent, which this file replaces in this workspace.",
               "The prompt is not given, so it is that of Troupe's built-in build agent as it is now: a later change to the built-in does not reach this file."
             ]

      plan = survey |> proposal("agents/plan.md") |> definition()
      assert plan.permissions["shell"] == :ask
      # Its own list, which closes writes, stands.
      refute Definition.allows_tool?(plan, "write_file")

      solo = survey |> proposal("agents/solo.md") |> definition()
      assert solo.prompt == ""

      assert Enum.any?(
               proposal(survey, "agents/solo.md").notes,
               &(&1 =~ "The prompt is not given")
             )
    end

    test "a prompt's {file:} is that file's text, read from inside the workspace only", context do
      write_file(context, "prompts/review.md", "  You review from a file.\n")
      File.write!(Path.join(context.base, "secret.md"), "not for the prompt")

      write_file(context, "opencode.json", ~s({
        "agent": {
          "filed": {"prompt": "{file:./prompts/review.md}", "mode": "subagent"},
          "escaped": {"prompt": "{file:../secret.md}"},
          "missing": {"prompt": "{file:./prompts/gone.md}"},
          "off": {"prompt": "Off.", "disable": true}
        }
      }))

      survey = survey(context)
      filed = proposal(survey, "agents/filed.md")
      assert definition(filed).prompt == "You review from a file."

      assert filed.notes == [
               "The prompt's {file:./prompts/review.md} is that file's text as it is now: a Troupe agent's prompt is its file's body."
             ]

      assert Enum.map(survey.proposals, & &1.path) == ["agents/filed.md"]

      assert Enum.sort(Enum.map(skipped(survey, "opencode.json"), &{&1.name, &1.reason})) == [
               {"escaped",
                "not proposed: its prompt reads {file:../secret.md}, which is outside the workspace"},
               {"missing",
                "not proposed: its prompt reads {file:./prompts/gone.md}, and prompts/gone.md is not there"},
               {"off", "not proposed: disable is true"}
             ]
    end

    test "tools switches and rules for some uses come to what Troupe can say of the whole tool",
         context do
      write_file(context, "opencode.json", ~s({
        "agent": {
          "careful": {
            "prompt": "Careful.", "mode": "primary",
            "tools": {"write": false, "bash": true},
            "permission": {"edit": {"*": "ask", "src/*": "allow"}}
          },
          "loose": {
            "prompt": "Loose.", "mode": "primary",
            "permission": {"bash": {"*": "allow", "rm *": "deny"}, "read": {"*": "allow", "docs/*": "allow"}}
          },
          "narrow": {
            "prompt": "Narrow.", "mode": "primary",
            "permission": {"bash": {"git *": "allow"}, "webfetch": {"*": "deny", "https://example.com/*": "allow"}}
          },
          "reader": {
            "prompt": "Reads.",
            "mode": "subagent",
            "permission": {"*": "deny", "read": "allow", "grep": "ask"}
          }
        }
      }))

      survey = survey(context)

      careful = proposal(survey, "agents/careful.md")
      # `write: false` and `edit`'s ask meet on write_file: the stricter stands.
      assert definition(careful).permissions == %{"write_file" => :deny, "edit_file" => :ask}
      # `bash: true` is on, at Troupe's own approval.
      assert Definition.permission(definition(careful), "shell", :ask) == :ask

      assert careful.notes == [
               "edit in permission: the rules for src/* cannot be carried as written, as Troupe allows a tool whole or not at all, so it asks every time."
             ]

      # A deny for some uses makes the whole tool ask; rules that all allow, allow.
      loose = proposal(survey, "agents/loose.md")
      assert definition(loose).permissions == %{"shell" => :ask, "read_file" => :auto}

      assert loose.notes == [
               "bash in permission: the rules for rm * cannot be carried as written, as Troupe allows a tool whole or not at all, so it asks every time.",
               "read in permission: the rules for docs/* cannot be carried as written, as Troupe allows a tool whole or not at all, so it runs without asking, which every rule allowed."
             ]

      # An allow for some uses alone says nothing; a deny of the whole stands.
      narrow = proposal(survey, "agents/narrow.md")
      assert definition(narrow).permissions == %{"web_fetch" => :deny}

      assert narrow.notes == [
               "bash in permission: the rules for git * cannot be carried as written, as Troupe allows a tool whole or not at all, so it keeps Troupe's own approval.",
               "webfetch in permission: the rules for https://example.com/* cannot be carried as written, as Troupe allows a tool whole or not at all, so it is denied whole, as its * says."
             ]

      reader = survey |> proposal("agents/reader.md") |> definition()
      assert reader.tools == ["grep", "read_file", "read_output", "finish"]
      assert reader.permissions == %{"read_file" => :auto, "grep" => :ask}
      refute Definition.allows_tool?(reader, "shell")
    end

    test "markdown agents in .opencode/agents and .opencode/agent, the plural first", context do
      write_file(
        context,
        ".opencode/agent/review.md",
        "---\nmode: subagent\n---\nThe singular's."
      )

      write_file(context, ".opencode/agents/review.md", """
      ---
      description: Reviews code
      mode: subagent
      model: anthropic/claude-sonnet-4-5
      temperature: 0.1
      permission:
        edit: deny
      ---
      The plural's.
      """)

      write_file(context, ".opencode/agent/lint.md", "---\nmode: all\n---\nLints.")

      survey = survey(context)
      review = proposal(survey, "agents/review.md")
      assert review.source == ".opencode/agents/review.md"
      assert definition(review).prompt == "The plural's."
      assert definition(review).model == "anthropic/claude-sonnet-4-5"
      assert definition(review).permissions == %{"edit_file" => :deny, "write_file" => :deny}

      assert review.notes == [
               "temperature is left out: Troupe sets no temperature per agent.",
               ".opencode/agent/review.md also gives the agent review and is not proposed: .opencode/agents/review.md comes first (Decision 824)."
             ]

      assert [%{reason: reason}] = skipped(survey, ".opencode/agent/review.md")

      assert reason ==
               "not proposed: .opencode/agents/review.md gives the agent review too, and comes first"

      lint = proposal(survey, "agents/lint.md")
      assert definition(lint).mode == :primary
      assert [note] = lint.notes
      assert note =~ "The mode all, both a primary and a subagent in opencode, is primary here"
    end
  end

  describe "one name from two files" do
    test "a Claude Code file wins over opencode's, and says which it hid", context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)
      write_file(context, "opencode.json", ~s({"agent": {"reviewer": {"prompt": "opencode's."}}}))
      write_file(context, ".opencode/agents/reviewer.md", "opencode's file.")

      survey = survey(context, below: %{})
      reviewer = proposal(survey, "agents/reviewer.md")
      assert definition(reviewer).prompt == "You review code."

      assert Enum.take(reviewer.notes, -2) == [
               ".opencode/agents/reviewer.md also gives the agent reviewer and is not proposed: .claude/agents/reviewer.md comes first (Decision 824).",
               "opencode.json's agent reviewer also gives the agent reviewer and is not proposed: .claude/agents/reviewer.md comes first (Decision 824)."
             ]

      assert Enum.map(survey.skipped, &{&1.source, &1.name}) == [
               {".opencode/agents/reviewer.md", "reviewer"},
               {"opencode.json", "reviewer"}
             ]
    end

    test "a command a Claude Code file and an opencode file both give is Claude Code's",
         context do
      write_file(context, ".claude/commands/review.md", "Claude Code's review.")

      write_file(
        context,
        ".opencode/commands/review.md",
        "---\nagent: plan\nsubtask: true\n---\nopencode's review."
      )

      write_file(
        context,
        ".opencode/command/test.md",
        "---\nmodel: anthropic/x\n---\nRun the tests."
      )

      survey = survey(context)
      review = proposal(survey, "commands/review.md")
      assert review.content == "Claude Code's review.\n"

      assert review.notes == [
               ".opencode/commands/review.md also gives the command review and is not proposed: .claude/commands/review.md comes first (Decision 824)."
             ]

      assert proposal(survey, "commands/test.md").notes == [
               "model is left out: a Troupe command runs on the session's agent and its model (Decision 763)."
             ]
    end

    test "a command is not proposed under a built-in's, an alias's or a primary agent's name",
         context do
      write_file(context, ".claude/commands/plan.md", "Plan it.")
      write_file(context, ".claude/commands/help.md", "Help me.")
      write_file(context, ".claude/commands/q.md", "Quit.")
      write_file(context, ".claude/commands/release.md", "Release it.")
      write_file(context, ".claude/commands/empty.md", "---\ndescription: Nothing\n---\n")
      write_file(context, ".claude/commands/frontend/component.md", "Make a component.")

      write_file(
        context,
        "opencode.json",
        ~s({"agent": {"release": {"prompt": "Cuts releases.", "mode": "primary"}}})
      )

      survey = survey(context)
      assert Enum.map(survey.proposals, & &1.path) == ["agents/release.md"]

      assert Enum.map(survey.skipped, &{&1.source, &1.reason}) == [
               {".claude/commands/empty.md", "not proposed: it has no prompt to send"},
               {".claude/commands/frontend",
                "not proposed: a file in a subdirectory has no name of its own among Troupe's, whose agents and commands are the files of one directory"},
               {".claude/commands/help.md",
                "not proposed: /help is Troupe's own /help command, and a command does not take the name of a built-in, an alias or a primary agent (Decision 763)"},
               {".claude/commands/plan.md",
                "not proposed: /plan is Troupe's built-in plan agent, and a command does not take the name of a built-in, an alias or a primary agent (Decision 763)"},
               {".claude/commands/q.md",
                "not proposed: /q is Troupe's own /quit command, and a command does not take the name of a built-in, an alias or a primary agent (Decision 763)"},
               {".claude/commands/release.md",
                "not proposed: /release is the release agent proposed from opencode.json, and a command does not take the name of a built-in, an alias or a primary agent (Decision 763)"}
             ]
    end
  end

  describe "the workspace's edge" do
    @describetag :unix

    test "a directory, a file or a config linked from outside is not proposed", context do
      elsewhere = Path.join(context.base, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "agents"))
      File.write!(Path.join(elsewhere, "agents/spy.md"), "Spy.")
      File.write!(Path.join(elsewhere, "linked.md"), "Linked.")

      File.write!(
        Path.join(elsewhere, "opencode.json"),
        ~s({"agent": {"remote": {"prompt": "Remote."}}})
      )

      File.write!(Path.join(elsewhere, "settings.json"), ~s({"permissions": {"allow": ["Bash"]}}))

      File.mkdir_p!(Path.join(context.workspace, ".claude/commands"))
      File.ln_s!(Path.join(elsewhere, "agents"), Path.join(context.workspace, ".claude/agents"))

      File.ln_s!(
        Path.join(elsewhere, "opencode.json"),
        Path.join(context.workspace, "opencode.json")
      )

      File.ln_s!(
        Path.join(elsewhere, "settings.json"),
        Path.join(context.workspace, ".claude/settings.json")
      )

      File.ln_s!(
        Path.join(elsewhere, "linked.md"),
        Path.join(context.workspace, ".claude/commands/linked.md")
      )

      survey = survey(context)
      assert survey.proposals == []

      assert Enum.map(survey.skipped, &{&1.source, &1.reason}) == [
               {".claude/agents", "not proposed: outside the workspace"},
               {".claude/commands/linked.md", "not proposed: outside the workspace"},
               {".claude/settings.json", "not proposed: outside the workspace"},
               {"opencode.json", "not proposed: outside the workspace"}
             ]
    end
  end
end
