defmodule Troupe.Agent.ImportedTest do
  @moduledoc """
  The agents other tools wrote into a workspace (Decision 819): Claude Code's
  `.claude/agents/*.md` and the `agent` entries of `opencode.json`, read as Troupe's at
  the workspace's layer, each used as its own tool says, with what Troupe cannot honour
  mapped or left out and said, and every file held to the workspace's edge.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.{Commands, Paths}
  alias Troupe.Tools.Delegate

  @reviewer """
  ---
  name: reviewer
  description: Reviews a change for what is wrong with it.
  tools: Read, Grep, Glob
  model: inherit
  ---
  You review code.
  """

  defp load(context, opts \\ []), do: Definitions.load(context.workspace, opts)

  defp skipped(defs, name), do: Enum.filter(defs.skipped, &(&1.name == name))

  defp reasons(%Definition{notes: notes}, key),
    do: for(%{key: ^key, reason: reason} <- notes, do: reason)

  describe "Claude Code's subagents" do
    test "a file in .claude/agents is a subagent of the workspace, its tools as Troupe's",
         context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)

      defs = load(context)
      reviewer = Definitions.fetch!(defs, "reviewer")

      assert reviewer.source == :claude_code
      assert reviewer.file == Paths.display(".claude/agents/reviewer.md")
      assert reviewer.prompt == "You review code."
      assert reviewer.description == "Reviews a change for what is wrong with it."
      assert reviewer.mode == :subagent
      # `inherit` is the session's model, and says nothing.
      assert reviewer.model == nil
      assert reviewer.notes == []
      # What the harness needs to honour the list: `finish` to report, `read_output` for
      # the rest of a cut grep.
      assert reviewer.tools == ["read_file", "grep", "glob", "read_output", "finish"]
      refute Definition.allows_tool?(reviewer, "shell")

      assert "reviewer" in Enum.map(Definitions.subagents(defs), & &1.name)
      refute "reviewer" in Enum.map(Definitions.primaries(defs), & &1.name)
    end

    test "what Troupe cannot honour is mapped or left out, each with its reason", context do
      write_file(context, ".claude/agents/scout.md", """
      ---
      name: scout
      description: Looks things up.
      tools: Read, Bash, WebSearch, NotebookEdit, Bash(git log:*, git diff:*), mcp__tracker__search, mcp__wiki, Frobnicate
      disallowedTools: Write, Bash(rm *)
      model: sonnet
      maxTurns: 5
      permissionMode: acceptEdits
      color: blue
      flavour: strawberry
      ---
      You scout.
      """)

      scout = Definitions.fetch!(load(context), "scout")

      assert scout.tools == ["read_file", "shell", "mcp.tracker.search", "read_output", "finish"]
      # A disallowed tool is removed whole, a rule for some of its uses included.
      assert scout.permissions == %{"write_file" => :deny, "shell" => :deny}
      assert Definition.permission(scout, "shell", :ask) == :deny
      assert scout.max_turns == 5
      assert scout.model == nil

      assert reasons(scout, "tools") == [
               "WebSearch is left out: Troupe has no web search tool",
               "NotebookEdit is left out: Troupe has no notebook tool",
               "Bash(git log:*, git diff:*) is left out: Troupe allows a tool whole or not at all, so a rule for some of its uses is not read",
               "mcp__wiki is left out: Troupe's tool list names an MCP server's tools one by one",
               "Frobnicate is left out: it is not a tool Troupe has"
             ]

      assert reasons(scout, "model") == [
               "sonnet is Claude Code's name for a model it picks itself, so the agent runs on the session's model"
             ]

      assert [permission_mode] = reasons(scout, "permissionMode")
      assert permission_mode =~ "not read"
      assert reasons(scout, "color") == ["not read: Troupe shows no colour per agent"]
      assert reasons(scout, "flavour") == ["not read: it is not a key Troupe reads"]
    end

    test "a model the session's provider serves is kept; one it does not is the session's",
         context do
      write_file(context, ".claude/agents/served.md", "---\nmodel: big-model\n---\nServed.")

      write_file(
        context,
        ".claude/agents/unserved.md",
        "---\nmodel: other-model\n---\nNot served."
      )

      defs = load(context, served?: &(&1 == "big-model"))

      assert Definitions.fetch!(defs, "served").model == "big-model"
      assert Definitions.fetch!(defs, "served").notes == []

      unserved = Definitions.fetch!(defs, "unserved")
      assert unserved.model == nil

      assert reasons(unserved, "model") == [
               "other-model is not a model the session's provider is known to serve, so the agent runs on the session's model"
             ]
    end

    test "the name is the frontmatter's, else the file's; one Troupe cannot use is skipped",
         context do
      write_file(context, ".claude/agents/a-file.md", "---\nname: named\n---\nNamed.")
      write_file(context, ".claude/agents/plain.md", "Just a prompt.")
      write_file(context, ".claude/agents/upper.md", "---\nname: Code Reviewer\n---\nNo.")

      defs = load(context)

      assert Definitions.fetch!(defs, "named").prompt == "Named."
      assert Definitions.fetch!(defs, "plain").prompt == "Just a prompt."
      assert {:error, _} = Definitions.fetch(defs, "upper")

      assert [%{reason: reason, file: file}] = skipped(defs, "Code Reviewer")
      assert reason =~ "is not a name Troupe can give an agent"
      assert file == Paths.display(".claude/agents/upper.md")
    end

    test "a subagent whose tools Troupe has none of is not read, as Claude Code would not start it",
         context do
      write_file(
        context,
        ".claude/agents/notes.md",
        "---\ntools: NotebookEdit, WebSearch\n---\nNotes."
      )

      defs = load(context)
      assert {:error, _} = Definitions.fetch(defs, "notes")

      assert [%{reason: reason}] = Enum.filter(defs.skipped, &(&1.file =~ "notes.md"))
      assert reason =~ "none of its tools (NotebookEdit, WebSearch) is one Troupe has"
    end

    test "frontmatter YAML cannot read is read a line per key", context do
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

      helper = Definitions.fetch!(load(context), "helper")
      assert helper.description == "Use when: the build breaks"
      assert helper.tools == ["read_file", "grep", "read_output", "finish"]

      assert reasons(helper, "frontmatter") == [
               "not YAML, so each line is read as a key and its value"
             ]
    end
  end

  describe "opencode's agents" do
    test "a primary agent with its permissions, as Troupe's approvals", context do
      write_file(context, "opencode.json", ~s({
        "agent": {
          "review": {
            "description": "Reviews before a merge.",
            "mode": "primary",
            "model": "anthropic/claude-sonnet-4-5",
            "prompt": "You review before a merge.",
            "temperature": 0.1,
            "permission": {"bash": "allow", "edit": "deny", "webfetch": "ask", "websearch": "allow"}
          }
        }
      }))

      defs = load(context)
      review = Definitions.fetch!(defs, "review")

      assert review.source == :opencode
      assert review.file == "opencode.json"
      assert review.mode == :primary
      assert review.prompt == "You review before a merge."
      assert review.tools == :all

      assert review.permissions == %{
               "shell" => :auto,
               "edit_file" => :deny,
               "write_file" => :deny,
               "web_fetch" => :ask
             }

      assert Definition.permission(review, "shell", :ask) == :auto
      assert Definition.permission(review, "edit_file", :ask) == :deny

      assert reasons(review, "model") == [
               "anthropic/claude-sonnet-4-5 is not a model the session's provider is known to serve, so the agent runs on the session's model"
             ]

      assert reasons(review, "permission") == [
               "websearch is left out: Troupe has no web search tool"
             ]

      assert reasons(review, "temperature") == ["not read: Troupe sets no temperature per agent"]

      assert "review" in Enum.map(Definitions.primaries(defs), & &1.name)
      refute "review" in Enum.map(Definitions.subagents(defs), & &1.name)
    end

    test "an agent without a mode is both, as opencode's default is", context do
      write_file(context, "opencode.jsonc", """
      // a repository's own
      {"agent": {"helper": {"description": "Helps.", "prompt": "You help."}}}
      """)

      defs = load(context)
      helper = Definitions.fetch!(defs, "helper")

      assert helper.mode == :all
      assert helper.file == "opencode.jsonc"
      assert "helper" in Enum.map(Definitions.primaries(defs), & &1.name)
      assert "helper" in Enum.map(Definitions.subagents(defs), & &1.name)

      # Delegation takes it as a subagent.
      ctx = %{agent_path: ["root"], max_depth: 3, definitions: defs}

      assert {:defer, {:delegate, "helper", "go"}} =
               Delegate.run(%{"agent" => "helper", "task" => "go"}, ctx)
    end

    test "an entry without a prompt adjusts the agent of that name below it", context do
      write_file(context, "opencode.json", ~s({
        "permission": {"bash": "deny"},
        "agent": {
          "build": {"permission": {"edit": "ask"}, "steps": 12},
          "plan": {"permission": {"bash": "ask"}},
          "solo": {"description": "No prompt."}
        }
      }))

      builtin = Definitions.load(System.tmp_dir!() |> Path.join("no-such-dir"))
      defs = load(context)

      build = Definitions.fetch!(defs, "build")
      assert build.prompt == Definitions.fetch!(builtin, "build").prompt
      assert build.source == :opencode
      assert build.mode == :primary
      assert build.max_turns == 12
      # The file's permission is under each agent's own.
      assert build.permissions["shell"] == :deny
      assert build.permissions["edit_file"] == :ask

      assert reasons(build, "prompt") == [
               "none given: it keeps the prompt of Troupe's built-in build agent"
             ]

      plan = Definitions.fetch!(defs, "plan")
      assert plan.permissions["shell"] == :ask
      # Its own list, which closes writes, stands.
      refute Definition.allows_tool?(plan, "write_file")

      solo = Definitions.fetch!(defs, "solo")
      assert solo.prompt == ""
      assert [reason] = reasons(solo, "prompt")
      assert reason =~ "none given"
    end

    test "a prompt's {file:} is read from inside the workspace only", context do
      write_file(context, "prompts/review.md", "  You review from a file.\n")
      outside = Path.join(context.base, "secret.md")
      File.write!(outside, "not for the prompt")

      write_file(context, "opencode.json", ~s({
        "agent": {
          "filed": {"prompt": "{file:./prompts/review.md}"},
          "escaped": {"prompt": "{file:../secret.md}"},
          "missing": {"prompt": "{file:./prompts/gone.md}"},
          "off": {"prompt": "Off.", "disable": true}
        }
      }))

      defs = load(context)

      assert Definitions.fetch!(defs, "filed").prompt == "You review from a file."

      for name <- ["escaped", "missing", "off"],
          do: assert({:error, _} = Definitions.fetch(defs, name))

      assert [%{reason: escaped}] = skipped(defs, "escaped")

      assert escaped ==
               "not read: its prompt reads {file:../secret.md}, which is outside the workspace"

      assert [%{reason: missing}] = skipped(defs, "missing")
      assert missing =~ "is not there"

      assert [%{reason: "not read: disable is true", file: "opencode.json"}] =
               skipped(defs, "off")
    end

    test "tools switches and rules for some uses", context do
      write_file(context, "opencode.json", ~s({
        "agent": {
          "careful": {
            "prompt": "Careful.",
            "tools": {"write": false, "bash": true},
            "permission": {"edit": {"*": "ask", "src/*": "allow"}}
          },
          "loose": {
            "prompt": "Loose.",
            "permission": {"bash": {"*": "allow", "rm *": "deny"}}
          },
          "reader": {
            "prompt": "Reads.",
            "mode": "subagent",
            "permission": {"*": "deny", "read": "allow", "grep": "ask"}
          }
        }
      }))

      defs = load(context)

      careful = Definitions.fetch!(defs, "careful")
      # `write: false` and `edit`'s ask meet on write_file: the stricter stands.
      assert careful.permissions == %{"write_file" => :deny, "edit_file" => :ask}
      # `bash: true` is on, at Troupe's own approval.
      assert Definition.permission(careful, "shell", :ask) == :ask

      assert reasons(careful, "permission") == [
               "edit: the rules for src/* are left out: Troupe allows a tool whole or not at all"
             ]

      # Rules that made an allow safe are not read, so the allow is not either.
      loose = Definitions.fetch!(defs, "loose")
      assert loose.permissions == %{}
      assert [reason] = reasons(loose, "permission")
      assert reason =~ "so it keeps Troupe's own approval"

      reader = Definitions.fetch!(defs, "reader")
      assert reader.tools == ["grep", "read_file", "read_output", "finish"]
      assert reader.permissions == %{"read_file" => :auto, "grep" => :ask}
      refute Definition.allows_tool?(reader, "shell")
    end
  end

  describe "the workspace's layer" do
    test "Troupe's own file of a name wins, and the one it hid is said", context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)
      write_file(context, ".troupe/agents/reviewer.md", "---\nmode: subagent\n---\nTroupe's own.")

      defs = load(context)
      reviewer = Definitions.fetch!(defs, "reviewer")
      assert reviewer.source == :project
      assert reviewer.prompt == "Troupe's own."

      own = Paths.display(".troupe/agents/reviewer.md")

      assert [%{file: file, reason: reason}] = skipped(defs, "reviewer")
      assert file == Paths.display(".claude/agents/reviewer.md")
      assert reason == "skipped: #{own} is used"
    end

    test "a Claude Code file wins a name opencode's config also has", context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)
      write_file(context, "opencode.json", ~s({"agent": {"reviewer": {"prompt": "opencode's."}}}))

      defs = load(context)
      assert Definitions.fetch!(defs, "reviewer").source == :claude_code

      assert [%{file: "opencode.json", reason: reason}] = skipped(defs, "reviewer")
      assert reason == "skipped: #{Paths.display(".claude/agents/reviewer.md")} is used"
    end

    test "one opencode made both stays a subagent where a team's grant does not name it",
         context do
      write_file(context, "opencode.json", ~s({"agent": {"helper": {"prompt": "Helps."}}}))

      helper = context |> load(entitled: ["build"]) |> Definitions.fetch!("helper")
      assert helper.mode == :subagent

      assert context
             |> load(entitled: ["helper"])
             |> Definitions.fetch!("helper")
             |> Map.get(:mode) == :all
    end
  end

  describe "the workspace's edge" do
    @describetag :unix

    test "a file, a directory or a config linked from outside is not read", context do
      elsewhere = Path.join(context.base, "elsewhere")
      File.mkdir_p!(Path.join(elsewhere, "agents"))
      File.write!(Path.join(elsewhere, "agents/spy.md"), "Spy.")
      File.write!(Path.join(elsewhere, "linked.md"), "Linked.")

      File.write!(
        Path.join(elsewhere, "opencode.json"),
        ~s({"agent": {"remote": {"prompt": "Remote."}}})
      )

      File.mkdir_p!(Path.join(context.workspace, ".claude"))
      File.ln_s!(Path.join(elsewhere, "agents"), Path.join(context.workspace, ".claude/agents"))

      File.ln_s!(
        Path.join(elsewhere, "opencode.json"),
        Path.join(context.workspace, "opencode.json")
      )

      defs = load(context)

      assert {:error, _} = Definitions.fetch(defs, "spy")
      assert {:error, _} = Definitions.fetch(defs, "remote")

      assert Enum.sort(Enum.map(defs.skipped, &{&1.file, &1.reason})) == [
               {Paths.display(".claude/agents"), "not read: outside the workspace"},
               {"opencode.json", "not read: outside the workspace"}
             ]

      # A linked file in a directory that is the workspace's own.
      File.rm!(Path.join(context.workspace, ".claude/agents"))
      File.mkdir_p!(Path.join(context.workspace, ".claude/agents"))

      File.ln_s!(
        Path.join(elsewhere, "linked.md"),
        Path.join(context.workspace, ".claude/agents/linked.md")
      )

      defs = load(context)
      assert {:error, _} = Definitions.fetch(defs, "linked")

      assert [%{reason: "not read: outside the workspace"}] =
               Enum.filter(defs.skipped, &(&1.file =~ "linked.md"))
    end
  end

  describe "in a session" do
    test "a session runs an opencode primary agent, its prompt and its tools", context do
      write_file(context, "opencode.json", ~s({
        "agent": {
          "review": {
            "mode": "primary",
            "prompt": "You review before a merge.",
            "permission": {"edit": "deny", "bash": "ask"}
          }
        }
      }))

      %{session: session, fake: fake} =
        start_session(context, agent: "review", steps: [{:text, "reviewed"}])

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "look")
      await_event(session.id, :turn_ended)

      [request] = Fake.requests(fake)
      assert request.system =~ "You review before a merge."
      names = Enum.map(request.tools, & &1.name)
      assert "shell" in names
      refute "edit_file" in names
      refute "write_file" in names
    end

    test "the root delegates to a Claude Code subagent, which has only its tools", context do
      write_file(context, ".claude/agents/reviewer.md", @reviewer)

      %{session: session, fake: fake} =
        start_session(context,
          routes: %{
            "root" => [
              {:tools, [{"delegate", %{"agent" => "reviewer", "task" => "review the change"}}]},
              {:text, "reviewed"}
            ],
            "reviewer" => [{:tools, [{"finish", %{"summary" => "looks fine"}}]}]
          }
        )

      Troupe.subscribe(session.id)
      Troupe.send_input(session.id, "review it")
      await_event(session.id, :turn_ended)

      assert [completed] =
               session.id
               |> events_of_type("tool_call_completed")
               |> Enum.filter(&(&1.data["name"] == "delegate"))

      assert completed.data["content"] == "looks fine"

      child = Enum.find(Fake.requests(fake), &(&1.system =~ "You review code."))
      names = Enum.map(child.tools, & &1.name)
      assert Enum.all?(["read_file", "grep", "glob", "finish"], &(&1 in names))
      refute "shell" in names
      refute "write_file" in names
    end
  end

  describe "the palette" do
    test "an opencode agent's row says where it came from and what was left out", context do
      write_file(context, "opencode.json", ~s({
        "agent": {"review": {"mode": "primary", "description": "Reviews.", "prompt": "R.", "temperature": 0.2}}
      }))

      agents = context |> load() |> Definitions.primaries()
      row = Enum.find(Commands.list(agents: agents), &(&1["name"] == "review"))

      assert row["detail"] ==
               "Reviews.\n\nFrom opencode.json, an opencode agent.\ntemperature: not read: Troupe sets no temperature per agent"
    end
  end
end
