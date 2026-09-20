defmodule Troupe.Tools.RememberTest do
  @moduledoc """
  The brief on disk (Decision 649): an agent's `remember` lands in the repository's
  `.troupe/memory.md`, the next agent's system prompt opens with it, and a worktree
  writes the same file as the checkout it came from.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.Memory
  alias Troupe.Tools.Remember

  test "a note written by one session opens the next session's system prompt", context do
    %{session: first, fake: fake} =
      start_session(context,
        steps: [
          {:tools, [{"remember", %{"section" => "note", "text" => "the ledger is a fold over the log"}}]},
          {:text_and_tools, "Noted.", [{"finish", %{"summary" => "noted"}}]}
        ]
      )

    :ok = Troupe.subscribe(first.id)
    Troupe.send_input(first.id, "remember what you learned")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    # The first agent's own prompt had no brief: there was none when it started.
    assert fake |> Fake.requests() |> List.first() |> Map.fetch!(:system) |> Kernel.=~("Project brief") == false

    path = Path.join(context.workspace, ".troupe/memory.md")
    assert File.read!(path) =~ "root: the ledger is a fold over the log"
    assert Memory.status(context.workspace, Troupe.Config.load(context.workspace)) == :stale,
           "a note alone is not a built brief"

    %{session: second, fake: fake2} =
      start_session(context, steps: [{:text_and_tools, "hi", [{"finish", %{"summary" => "ok"}}]}])

    :ok = Troupe.subscribe(second.id)
    Troupe.send_input(second.id, "hello")
    assert_receive {:troupe_event, _, %Event{type: "agent_done", agent: ["root"]}}, 5_000

    system = fake2 |> Fake.requests() |> List.first() |> Map.fetch!(:system)
    assert system =~ "# Project brief"
    assert system =~ "the ledger is a fold over the log"
  end

  test "a curated section stamps the brief, and memory: false keeps it out of the prompt",
       context do
    assert :ok = Memory.put_section(context.workspace, "commands", "mix test")
    brief = Memory.brief(context.workspace)
    assert brief.built_at != nil
    assert Troupe.Memory.section(brief, "Commands") == "mix test"

    config = Troupe.Config.load(context.workspace)
    assert Memory.status(context.workspace, config) == :fresh
    assert Memory.prompt_section(context.workspace, config) =~ "mix test"

    off = %{config | memory: false}
    assert Memory.status(context.workspace, off) == :disabled
    assert Memory.prompt_section(context.workspace, off) == ""

    :ok = Memory.forget(context.workspace)
    assert Memory.status(context.workspace, config) == :absent
  end

  test "a worktree's brief is the repository's", context do
    repo = context.workspace
    {_, 0} = System.cmd("git", ["init", "-q", "--initial-branch", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# r\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "first"], cd: repo)

    worktree = Path.join(context.base, "repo-branch")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", "-b", "troupe/x", worktree], cd: repo)

    assert Memory.path(worktree) == Path.join(repo, ".troupe/memory.md")
    assert :ok = Memory.note(worktree, "root", "written from the worktree")
    assert File.read!(Path.join(repo, ".troupe/memory.md")) =~ "written from the worktree"
    refute File.exists?(Path.join(worktree, ".troupe/memory.md"))
  end

  test "remember refuses an unknown section and empty text", context do
    %{session: session} = start_session(context, steps: [])
    ctx = ctx(session, context)

    assert {:error, "unknown section" <> _} =
             Remember.run(%{"section" => "todo", "text" => "x"}, ctx)

    assert {:error, "nothing to remember" <> _} =
             Remember.run(%{"section" => "note", "text" => "  "}, ctx)

    assert {:ok, "project brief updated: Overview rewritten"} =
             Remember.run(%{"section" => "overview", "text" => "A thing."}, ctx)
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
