defmodule Troupe.MemorySessionTest do
  @moduledoc "The brief end to end: the actor, the `remember` tool, the prompt and the librarian."
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake
  alias Troupe.Memory
  alias Troupe.Session

  # Built "now", so only the assertions that mean to test staleness see it stale.
  defp brief_text(files \\ 3) do
    """
    ---
    built_at: #{DateTime.to_iso8601(DateTime.utc_now())}
    head: abc1234
    files: #{files}
    ---

    ## Overview
    A fixture project used by the memory tests.

    ## Commands
    - test: `mise exec -- mix test`
    """
  end

  defp with_brief(extra \\ %{}) do
    files = Enum.count(extra) + 1
    tmp_workspace(Map.merge(%{".troupe/memory.md" => brief_text(files)}, extra))
  end

  defp system_prompts(fake, path) do
    fake |> Fake.requests() |> Enum.filter(&(&1.agent_path == path)) |> Enum.map(& &1.system)
  end

  ## The actor

  test "a hand-written brief is read at session start" do
    {sid, _fake, _ws} = start_session!(workspace: with_brief())

    brief = Session.Memory.brief(sid)
    assert Memory.section(brief, "Overview") =~ "fixture project"
    assert Session.Memory.status(sid, 1) == :fresh
  end

  test "an unreadable brief is ignored rather than fatal" do
    ws = tmp_workspace(%{".troupe/memory.md" => "---\nbuilt_at: x\n## Overview\nno end marker\n"})
    {sid, _fake, _ws} = start_session!(workspace: ws)

    assert Session.Memory.brief(sid) == nil
    assert Session.Memory.status(sid) == :absent
    assert Session.Memory.prompt_section(sid) == ""
  end

  test "notes are written through, survive a crash and do not stamp the brief" do
    ws = with_brief()
    {sid, _fake, _ws} = start_session!(workspace: ws)

    before = Session.Memory.brief(sid).built_at
    :ok = Session.Memory.note(sid, "code-1", "locks are advisory only")

    on_disk = File.read!(Session.Memory.path(ws))
    assert on_disk =~ "code-1: locks are advisory only"
    assert Session.Memory.brief(sid).built_at == before, "a note is not a rebuild"

    pid = Session.whereis(sid, :memory)
    Process.exit(pid, :kill)

    eventually(fn ->
      p = Session.whereis(sid, :memory)
      p != nil and p != pid
    end)

    assert Memory.section(Session.Memory.brief(sid), "Notes") =~ "locks are advisory only"
  end

  test "put_section stamps the brief and a later read sees the merge" do
    ws = with_brief()
    {sid, _fake, _ws} = start_session!(workspace: ws)

    :ok = Session.Memory.put_section(sid, "layout", "- `lib/` — the code.")

    brief = Session.Memory.brief(sid)
    assert Memory.section(brief, "Layout") == "- `lib/` — the code."
    assert Memory.section(brief, "Overview") =~ "fixture project", "other sections survive"
    assert DateTime.diff(DateTime.utc_now(), brief.built_at, :second) < 60
  end

  test "a hand edit between two writes is not clobbered" do
    ws = with_brief()
    {sid, _fake, _ws} = start_session!(workspace: ws)

    path = Session.Memory.path(ws)
    File.write!(path, File.read!(path) <> "\n## Gotchas\nEdited by hand.\n")

    :ok = Session.Memory.note(sid, "code-1", "something learned")

    assert File.read!(path) =~ "Edited by hand."
    assert File.read!(path) =~ "something learned"
  end

  test "forget deletes the brief" do
    ws = with_brief()
    {sid, _fake, _ws} = start_session!(workspace: ws)

    :ok = Session.Memory.forget(sid)
    refute File.exists?(Session.Memory.path(ws))
    assert Session.Memory.brief(sid) == nil
  end

  ## The prompt

  test "the brief reaches the system prompt and shrinks the survey" do
    files =
      Map.new(1..100, &{"lib/troupe/generated/module_#{&1}.ex", "defmodule M#{&1}, do: nil\n"})

    {with_sid, with_fake, _} =
      start_session!(workspace: with_brief(files), script: [{:finish, "ok"}])

    {:ok, path} = Troupe.dispatch(with_sid, "code", "task")
    await_state(path, :done_unread)
    [with_brief_prompt] = system_prompts(with_fake, path)

    assert with_brief_prompt =~ "# Project brief"
    assert with_brief_prompt =~ "A fixture project used by the memory tests."
    assert with_brief_prompt =~ "mise exec -- mix test"

    {plain_sid, without_fake, _} =
      start_session!(workspace: tmp_workspace(files), script: [{:finish, "ok"}])

    {:ok, path2} = Troupe.dispatch(plain_sid, "code", "task")
    await_state(path2, :done_unread)
    [without_brief_prompt] = system_prompts(without_fake, path2)

    refute without_brief_prompt =~ "# Project brief"
    assert without_brief_prompt =~ "## Files", "the full listing when there is no brief"
    assert with_brief_prompt =~ "## Layout", "per-directory counts once a brief supersedes it"
  end

  test "the system prompt stays byte-stable across turns even after a remember" do
    script = [
      {:tool, "remember", %{"section" => "note", "text" => "the ledger is a fold"}},
      {:finish, "ok"}
    ]

    {sid, fake, _ws} = start_session!(workspace: with_brief(), script: script)

    {:ok, path} = Troupe.dispatch(sid, "code", "task")
    await_state(path, :done_unread)

    assert [first, second | _] = system_prompts(fake, path)
    assert first == second, "the prompt must not move under the provider's cache"
  end

  ## The tool

  test "remember writes a note and reports it, and the next agent starts with it" do
    ws = with_brief()

    scripts = %{
      "code-1" => [
        {:tool, "remember",
         %{"section" => "note", "text" => "every OS process goes through reaper"}},
        {:finish, "recorded"}
      ],
      "code-2" => [{:finish, "ok"}]
    }

    {sid, fake, _} = start_session!(workspace: ws, fake: Fake.start!([], scripts: scripts))

    {:ok, p1} = Troupe.dispatch(sid, "code", "first")
    await_state(p1, :done_unread)

    assert [completed | _finish] = events_of(sid, p1, :tool_call_completed)
    assert completed.data.ok
    assert completed.data.content =~ "project brief updated"

    types = sid |> Troupe.events() |> Enum.filter(&(&1.agent_path == p1)) |> Enum.map(& &1.type)
    assert :approval_requested not in types, "remember is :auto"

    {:ok, p2} = Troupe.dispatch(sid, "code", "second")
    await_state(p2, :done_unread)
    assert hd(system_prompts(fake, p2)) =~ "every OS process goes through reaper"
  end

  test "remember rejects an empty text and an unknown section" do
    scripts = %{
      "code-1" => [
        {:tool, "remember", %{"section" => "note", "text" => "   "}},
        {:tool, "remember", %{"section" => "nonsense", "text" => "x"}},
        {:finish, "done"}
      ]
    }

    {sid, _fake, ws} =
      start_session!(workspace: with_brief(), fake: Fake.start!([], scripts: scripts))

    {:ok, path} = Troupe.dispatch(sid, "code", "task")
    await_state(path, :done_unread)

    assert [empty, unknown | _finish] = events_of(sid, path, :tool_call_completed)
    refute empty.data.ok
    assert empty.data.content =~ "nothing to remember"
    refute unknown.data.ok
    assert unknown.data.content =~ "unknown section"

    refute File.read!(Session.Memory.path(ws)) =~ "nonsense"
  end

  test "a worktree branch writes to the main checkout's brief" do
    ws = git_init!(tmp_workspace())
    File.mkdir_p!(Path.join(ws, ".troupe"))
    File.write!(Session.Memory.path(ws), brief_text())

    script = [
      {:tool, "remember", %{"section" => "note", "text" => "written from a worktree"}},
      {:finish, "ok"}
    ]

    {sid, _fake, _} = start_session!(workspace: ws, script: script)

    {:ok, path} = Troupe.dispatch(sid, "worktree", "task")
    await_state(path, :done_unread)

    worktree = window(sid, path).worktree
    assert File.read!(Session.Memory.path(ws)) =~ "written from a worktree"

    refute File.exists?(Session.Memory.path(worktree.path)),
           "the worktree must not grow a brief of its own"
  end

  ## The librarian

  test "a session without a brief dispatches exactly one self-dismissing librarian" do
    scripts = %{
      "librarian-1" => [
        {:tool, "remember", %{"section" => "overview", "text" => "A surveyed project."}},
        {:finish, "brief written"}
      ]
    }

    {sid, _fake, ws} =
      start_session!(
        fake: Fake.start!([], scripts: scripts),
        config: %{memory: %{auto_refresh: true}}
      )

    await_state("librarian-1", :done_unread)
    eventually(fn -> window(sid, "librarian-1").state == :dismissed end)

    assert Memory.section(Session.Memory.brief(sid), "Overview") == "A surveyed project."
    assert File.exists?(Session.Memory.path(ws))

    # Restarting the Dispatcher must not raise a second one.
    pid = Session.whereis(sid, :dispatcher)
    Process.exit(pid, :kill)
    eventually(fn -> Session.whereis(sid, :dispatcher) not in [nil, pid] end)

    assert events_of(sid, "librarian-1", :branch_spawned) != []
    assert Troupe.windows(sid) |> Enum.count(&(&1.name == "librarian")) == 1
  end

  test "a fresh brief raises no librarian" do
    ws = with_brief()
    File.write!(Session.Memory.path(ws), Memory.render(Memory.stamp(fresh_brief(), "abc", 1)))

    {sid, _fake, _} = start_session!(workspace: ws, config: %{memory: %{auto_refresh: true}})

    assert Session.Memory.status(sid, 1) == :fresh
    refute_receive {:troupe_event, %{agent_path: "librarian-1"}}, 300
    assert Troupe.windows(sid) == []
  end

  defp fresh_brief do
    {:ok, brief} = Memory.parse(brief_text())
    brief
  end
end
