defmodule Troupe.BranchClientTest do
  @moduledoc """
  A branch is a session of its own that this session's screen shows as a window
  (Decision 103). Everything here runs against the embedded daemon over the protocol:
  the branch is created with `parent`, works in its own worktree, and its events, input,
  approvals, merge and discard all go through `Troupe.Client` under the window's name.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  # A branch reads the workspace's `.troupe/config.yaml` from its own worktree, so the
  # fake's configuration has to be committed for the branch to see it.
  defp repo_with_fake!(script, opts \\ []) do
    ws = git_init!(tmp_workspace())
    {sid, _, ^ws} = start_session!([workspace: ws, script: script] ++ opts)
    run_git!(ws, ["add", "-A"])
    run_git!(ws, ["commit", "-q", "-m", "fake model"])
    {sid, ws}
  end

  test "a slash command opens a branch as a window of this session, in its own worktree" do
    script = [
      {:text_and_tools, "Writing the note.",
       [{"write_file", %{"path" => "note.txt", "content" => "from the branch\n"}}]},
      {:text, "Wrote it."},
      {:finish, "wrote note.txt"}
    ]

    {sid, ws} = repo_with_fake!(script)
    assert "worktree" in Client.commands(sid)

    assert {:ok, "build-1"} = Client.dispatch(sid, "build", "write a note")

    spawned = await_event("build-1", :branch_spawned)
    assert spawned.data.name == "build"
    assert spawned.data.isolation == :worktree
    assert is_binary(spawned.data.session_id)

    created = await_event("build-1", :worktree_created)
    assert created.data.git_branch =~ ~r"^troupe/"
    worktree = created.data.path
    assert File.dir?(worktree)

    # The prompt is the branch's first input, and its work happens in its worktree.
    await_event("build-1", :input)
    assert %{data: %{name: "write_file"}} = await_event("build-1", :tool_started)
    await_state("build-1", :done, 10_000)
    assert File.read!(Path.join(worktree, "note.txt")) == "from the branch\n"
    refute File.exists?(Path.join(ws, "note.txt"))

    # Read back beside this session's own events, under the window's name.
    events = Client.events(sid)
    assert Enum.any?(events, &(&1.agent_path == "build-1" and &1.type == :assistant_message))
    assert Enum.any?(events, &(&1.agent_path == "root" and &1.type == :branch_spawned))

    # A second branch of the same profile is the next number.
    assert {:ok, "build-2"} = Client.dispatch(sid, "build", "")
    await_event("build-2", :branch_spawned)

    # Merging lands the work and closes the window.
    assert {:ok, "merged troupe/" <> _} = Client.merge(sid, "build-1")
    assert %{data: %{conflicts: false}} = await_event("build-1", :worktree_merged)
    await_event("build-1", :window_dismissed)
    assert File.read!(Path.join(ws, "note.txt")) == "from the branch\n"
    refute File.dir?(worktree)
    assert {:error, "no branch build-1"} = Client.merge(sid, "build-1")

    assert {:error, "unknown command /nothing; " <> _} = Client.dispatch(sid, "nothing", "x")
  end

  test "input typed into a branch window goes to its session, and an approval is answered through it" do
    script = [
      {:tool, "write_file", %{"path" => "gated.txt", "content" => "approved\n"}},
      {:finish, "wrote it"}
    ]

    {sid, ws} = repo_with_fake!(script, auto_approve: false)

    assert {:ok, "build-1"} = Client.dispatch(sid, "build", "")
    created = await_event("build-1", :worktree_created)

    :ok = Client.send_input(sid, "build-1", "write the gated file")

    assert %{data: %{call_id: call_id, name: "write_file"}} =
             await_event("build-1", :approval_requested)

    refute File.exists?(Path.join(created.data.path, "gated.txt"))
    :ok = Client.approve(sid, call_id, :allow)
    await_event("build-1", :approval_answered)
    await_state("build-1", :done, 10_000)
    assert File.read!(Path.join(created.data.path, "gated.txt")) == "approved\n"

    assert {:error, "no window nowhere-1"} = Client.send_input(sid, "nowhere-1", "hello")

    assert {:ok, "discarded troupe/" <> _} = Client.discard(sid, "build-1")
    await_event("build-1", :worktree_discarded)
    await_event("build-1", :window_dismissed)
    refute File.dir?(created.data.path)
    refute File.exists?(Path.join(ws, "gated.txt"))
  end

  test "a session opened again brings its branch windows back" do
    {sid, ws} = repo_with_fake!([{:text, "hi"}, {:finish, "ok"}])

    assert {:ok, "build-1"} = Client.dispatch(sid, "build", "")
    spawned = await_event("build-1", :branch_spawned)
    child = spawned.data.session_id

    :ok = Client.stop_session(sid)
    eventually(fn -> not Client.has_session?(sid) and not Client.has_session?(child) end)

    {:ok, ^sid} = Client.open_session({:local, ws}, sid, :read)
    eventually(fn -> Client.has_session?(child) end)

    assert Enum.any?(
             Client.events(sid),
             &(&1.agent_path == "build-1" and &1.type == :branch_spawned)
           )
  end

  test "the TUI opens the branch's window from the command line" do
    {sid, _ws} = repo_with_fake!([{:text, "hello from the branch"}, {:finish, "said hi"}])
    {pid, session} = start_tui(sid)

    type(pid, "/build say hello")
    press(pid, "enter")

    await_event("build-1", :branch_spawned)
    await_state("build-1", :done, 10_000)
    eventually(fn -> screen_text(pid, session) =~ "build-1" end)
    press(pid, "2")
    eventually(fn -> screen_text(pid, session) =~ "hello from the branch" end)
  end

  test "/workflow runs a named workflow as a branch in its own worktree, its plan rendered by the daemon" do
    ws = git_init!(tmp_workspace())
    File.mkdir_p!(Path.join(ws, ".troupe/workflows"))

    File.write!(
      Path.join(ws, ".troupe/workflows/greet.json"),
      ~s|[{"name":"write","agent":"implementer","prompt":"write hello.txt"}]|
    )

    {sid, _, ^ws} = start_session!(workspace: ws, script: [{:text, "planned"}, {:finish, "ok"}])
    run_git!(ws, ["add", "-A"])
    run_git!(ws, ["commit", "-q", "-m", "fake model and a workflow"])

    assert "workflow" in Client.commands(sid)
    assert {:ok, "workflow-1"} = Client.dispatch(sid, "workflow", "greet: greet the world")

    spawned = await_event("workflow-1", :branch_spawned)
    assert spawned.data.name == "workflow"
    assert spawned.data.isolation == :worktree

    input = await_event("workflow-1", :input)
    assert input.data.content =~ "Task: greet the world"
    assert input.data.content =~ "1. [`implementer`] **write:** write hello.txt"
    await_state("workflow-1", :done, 10_000)

    # A leading word that names no workflow is part of the task, on the default pipeline.
    assert {:ok, "workflow-2"} = Client.dispatch(sid, "workflow", "just do it")
    input = await_event("workflow-2", :input)
    assert input.data.content =~ "Task: just do it"
    assert input.data.content =~ "1. [`explore`] **understand:**"
  end
end
