defmodule Troupe.Tools.OnboardWriteTest do
  @moduledoc """
  `onboard_write` (issue #516, slice 3; Decision 823): the librarian's one way to write
  Troupe's own files from another tool's, confined to the workspace's `.troupe/` and the
  person's config directory, asked first, recording where each file came from, with an
  `onboarded` event in the session's log. On the chunk's tip no tool the librarian has
  could write `.troupe/agents/x.md` at all.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.{Definition, Definitions}
  alias Troupe.Session.Approvals
  alias Troupe.Tool.{Ctx, Result}
  alias Troupe.Tools
  alias Troupe.Tools.OnboardWrite

  @content "---\ndescription: Reviews a change\n---\nYou review code.\n"

  defp call(args \\ %{}) do
    {"onboard_write",
     Map.merge(
       %{
         "target" => "repo",
         "path" => "agents/reviewer.md",
         "source" => ".claude/agents/reviewer.md",
         "content" => @content
       },
       args
     )}
  end

  test "the librarian writes .troupe/agents/x.md only once the person approves, with its provenance and an onboarded event",
       context do
    write_file(context, ".claude/agents/reviewer.md", "---\nname: reviewer\n---\nReview.\n")

    %{session: %{id: sid}} =
      start_session(context,
        agent: "librarian",
        config_overrides: [auto_approve: false],
        steps: [
          {:tools, [call()]},
          {:text_and_tools, "Onboarded.", [{"finish", %{"summary" => "onboarded"}}]}
        ]
      )

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "Onboard the reviewer subagent.")

    request = await_event(sid, :approval_requested)
    assert request.data["tool"] == "onboard_write"
    refute File.exists?(Path.join(context.workspace, ".troupe/agents/reviewer.md"))

    Troupe.approve(sid, request.data["call_id"], :allow)
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    hash = sha256(read_file(context, ".claude/agents/reviewer.md"))
    written = read_file(context, ".troupe/agents/reviewer.md")
    assert written =~ ~s(imported_from: ".claude/agents/reviewer.md"\n)
    assert written =~ ~s(imported_hash: "#{hash}"\n)
    assert written =~ ~r/imported_at: "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"\n/
    assert written =~ "description: Reviews a change\n"

    assert [%Event{data: data}] = events_of_type(sid, :onboarded)

    assert data == %{
             "target" => "repo",
             "path" => "agents/reviewer.md",
             "file" => ".troupe/agents/reviewer.md",
             "source" => ".claude/agents/reviewer.md",
             "source_hash" => hash,
             "action" => "created"
           }

    assert [%Event{data: %{"ok" => true, "content" => content}}] =
             sid
             |> events_of_type(:tool_call_completed)
             |> Enum.filter(&(&1.data["name"] == "onboard_write"))

    assert content =~
             "created .troupe/agents/reviewer.md, imported from .claude/agents/reviewer.md"
  end

  test "into the config directory it asks even with auto_approve on and the profile's auto; into .troupe/ it follows the rule",
       context do
    write_file(context, ".claude/agents/reviewer.md", "Review.\n")

    onboarder = %Definition{
      name: "onboarder",
      mode: :primary,
      prompt: "Onboard what you are told to.",
      tools: ["onboard_write", "finish"],
      permissions: %{"onboard_write" => :auto},
      source: :global
    }

    {_name, user} =
      call(%{
        "target" => "user",
        "path" => "agents/b26-never-written.md",
        "source" => "~/.troupe-b26-test-#{System.unique_integer([:positive])}/reviewer.md"
      })

    # The session's own config, as the suite starts every session: auto_approve on.
    %{session: %{id: sid}} =
      start_session(context,
        agent: "onboarder",
        definitions: Definitions.from_list([onboarder]),
        steps: [
          {:tools, [call()]},
          {:tools, [{"onboard_write", user}]},
          {:text_and_tools, "Done.", [{"finish", %{"summary" => "done"}}]}
        ]
      )

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "Onboard the reviewer, for the repository and for me.")

    request = await_event(sid, :approval_requested)
    assert request.data["tool"] == "onboard_write"
    assert request.data["args"]["target"] == "user"

    # The repository's file was written as the rule says, unasked; the person's is waiting.
    assert File.exists?(Path.join(context.workspace, ".troupe/agents/reviewer.md"))

    assert [%Event{data: %{"args" => %{"target" => "user"}}}] =
             events_of_type(sid, :approval_requested)

    # Saying yes to everything again does not answer it either.
    :ok = Approvals.set_auto_approve(sid, true)
    assert [%{tool: "onboard_write"}] = Approvals.pending(sid)

    Troupe.approve(sid, request.data["call_id"], :deny)
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    refute File.exists?(Path.join(Troupe.Paths.config_dir(), "agents/b26-never-written.md"))
    assert [%Event{data: %{"target" => "repo"}}] = events_of_type(sid, :onboarded)
  end

  test "an AGENTS.md is asked about whatever auto_approve says, and written with its record in .troupe/onboarded.json",
       context do
    write_file(context, "CLAUDE.md", "Be brief.\n")

    {_name, agents} =
      call(%{
        "target" => "workspace",
        "path" => "AGENTS.md",
        "source" => "CLAUDE.md",
        "content" => "Be brief.\n"
      })

    assert OnboardWrite.must_ask?(agents)

    # The suite starts every session with auto_approve on.
    %{session: %{id: sid}} =
      start_session(context,
        agent: "librarian",
        steps: [
          {:tools, [{"onboard_write", agents}]},
          {:text_and_tools, "Done.", [{"finish", %{"summary" => "onboarded"}}]}
        ]
      )

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "Onboard CLAUDE.md.")

    request = await_event(sid, :approval_requested)
    assert request.data["args"]["target"] == "workspace"
    refute File.exists?(Path.join(context.workspace, "AGENTS.md"))

    # Generous: under a full suite's load the turn after the approval has taken longer than 5 s.
    Troupe.approve(sid, request.data["call_id"], :allow)
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 15_000

    assert read_file(context, "AGENTS.md") == "Be brief.\n"

    assert %{"workspace" => %{"AGENTS.md" => %{"imported_from" => "CLAUDE.md"}}} =
             Jason.decode!(read_file(context, ".troupe/onboarded.json"))

    assert [
             %Event{
               data: %{"target" => "workspace", "file" => "AGENTS.md", "action" => "created"}
             }
           ] =
             events_of_type(sid, :onboarded)
  end

  test "a denied call leaves nothing behind", context do
    write_file(context, ".claude/agents/reviewer.md", "Review.\n")

    %{session: %{id: sid}} =
      start_session(context,
        agent: "librarian",
        config_overrides: [auto_approve: false],
        steps: [
          {:tools, [call()]},
          {:text_and_tools, "Left out.", [{"finish", %{"summary" => "nothing"}}]}
        ]
      )

    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "Onboard the reviewer subagent.")

    request = await_event(sid, :approval_requested)
    Troupe.approve(sid, request.data["call_id"], :deny)
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    refute File.exists?(Path.join(context.workspace, ".troupe"))
    assert events_of_type(sid, :onboarded) == []
  end

  test "an agent with every tool is neither offered onboard_write nor let call it", context do
    definitions = Definitions.load(context.workspace)
    build = Definitions.fetch!(definitions, "build")
    librarian = Definitions.fetch!(definitions, "librarian")

    refute "onboard_write" in Enum.map(Tools.for_definition(build), &Troupe.Tool.name/1)
    assert "onboard_write" in Enum.map(Tools.for_definition(librarian), &Troupe.Tool.name/1)

    ctx = ctx(context)
    assert {:reject, %{content: refusal}} = Tools.authorize("onboard_write", build, ctx)
    assert refusal == "The tool onboard_write is not available in the current profile."
    assert {:run, OnboardWrite, :task} = Tools.authorize("onboard_write", librarian, ctx)
    assert OnboardWrite.default_permission() == :ask
  end

  test "it refuses a path outside the two roots, a file it does not write, and a source it cannot hash",
       context do
    write_file(context, ".claude/agents/reviewer.md", "Review.\n")
    ctx = ctx(context)

    for {args, refusal} <- [
          {%{"path" => "../AGENTS.md"}, "`../AGENTS.md` has an empty, `.` or `..` part"},
          {%{"path" => "config.yaml"}, "`config.yaml` is not a file onboarding writes"},
          {%{"target" => "user", "path" => "credentials.json", "source" => "~/x"},
           "`credentials.json` is not a file onboarding writes"},
          {%{"source" => "../../etc/passwd"}, "`../../etc/passwd` is outside the workspace"},
          {%{"source" => ".claude/agents/none.md"}, "`.claude/agents/none.md` is not there"},
          {%{"target" => "user", "source" => ".claude/agents/reviewer.md"},
           "does not start with ~/"},
          {%{"target" => "elsewhere"}, "target must be \"repo\", \"workspace\" or \"user\""},
          {%{"target" => "workspace", "path" => ".git/AGENTS.md"},
           "`.git/AGENTS.md` is not a file onboarding writes into the workspace"},
          {%{"target" => "workspace", "path" => "CLAUDE.md"},
           "`CLAUDE.md` is not a file onboarding writes into the workspace"},
          {%{"target" => "workspace", "path" => "nowhere/AGENTS.md"},
           "`nowhere/AGENTS.md`: there is no such directory in the workspace"}
        ] do
      {_name, args} = call(args)
      assert {:error, reason} = OnboardWrite.run(args, ctx)
      assert Result.describe(reason) =~ refusal
    end

    refute File.exists?(Path.join(context.workspace, ".troupe"))
  end

  test "on a pod, and from a workspace's own agent into the config directory, it refuses",
       context do
    write_file(context, ".claude/agents/reviewer.md", "Review.\n")
    {_name, args} = call()

    assert {:error, reason} = OnboardWrite.run(args, %{ctx(context) | bundle: %{version: "1"}})
    assert reason =~ "this session runs on a pod"

    project = %Definition{name: "mine", mode: :primary, prompt: "", source: :project}
    {_name, user} = call(%{"target" => "user", "source" => "~/.claude/agents/reviewer.md"})
    assert {:error, reason} = OnboardWrite.run(user, %{ctx(context) | definition: project})

    assert reason =~
             "this agent is the workspace's own (.troupe/agents/), and may not write your config"

    refute File.exists?(Path.join(context.workspace, ".troupe"))
  end

  defp ctx(context) do
    %Ctx{
      session_id: "onboard-write-test",
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self()
    }
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
