defmodule Troupe.WorkspaceInAnotherRepositoryTest do
  @moduledoc """
  A workspace that is a plain directory inside another repository (#621), in a folder the
  repository ignores or in one it tracks: it lists the built-in primary agents, and a plain
  line in command mode starts build there.

  What went wrong was not the directory's agents. Command mode lists the workspace's
  worktrees (`worktree.list`, TUI Decision 155), and for a directory inside another
  repository those are that repository's, each looked at with git several times. In the
  repository #621 was found in, with about two hundred worktrees, on Windows, that took
  minutes, on the one connection the TUI keeps to the daemon, which answers a connection's
  calls in turn: the plain line's `agents.list` waited behind it past its 35 s, and
  `branch_profile/2` read the timeout as no primary agents ("unknown command /build;
  available: /worktree"). The listing now goes on a connection of its own
  (`Troupe.Client.Daemon.Link.call_apart/2`).
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.UI.TUI.Model

  # Another repository, with a folder it ignores and a folder it tracks, each holding a
  # directory that is no repository of its own.
  defp enclosing! do
    outer = git_init!(tmp_workspace())
    File.write!(Path.join(outer, ".gitignore"), "scratch/\n")
    File.mkdir_p!(Path.join(outer, "scratch/ws"))
    File.mkdir_p!(Path.join(outer, "packages/ws"))
    File.write!(Path.join(outer, "packages/ws/README.md"), "# a package\n")
    run_git!(outer, ["add", "-A"])
    run_git!(outer, ["commit", "-q", "-m", "fixture"])
    outer
  end

  defp ready(pid) do
    eventually(fn -> user_state(pid).commands != [] end)
    eventually(fn -> Model.session_window(user_state(pid).model) != nil end)
  end

  for {folder, dir} <- [
        {"a folder another repository ignores", "scratch/ws"},
        {"a folder another repository tracks", "packages/ws"}
      ] do
    test "a plain directory in #{folder}: the primaries are listed, and a plain line starts build" do
      ws = Path.join(enclosing!(), unquote(dir))

      {:ok, profiles} = Client.profiles({:local, ws})
      names = Enum.map(profiles, & &1.name)
      assert "build" in names
      assert "plan" in names

      {sid, _, _} = start_session!(workspace: ws, script: [{:text, "Said hello."}])
      {pid, _session} = start_tui(sid)
      ready(pid)

      type(pid, "say hello")
      press(pid, "enter")

      spawned = await_event("build-1", :branch_spawned)
      assert spawned.data.name == "build"
      assert spawned.data.prompt == "say hello"
      await_state("build-1", :done, 10_000)
      refute Enum.any?(user_state(pid).model.notices, &(&1 =~ "did not start"))

      GenServer.stop(pid, :normal)
    end
  end

  # The mechanism, held still: with the link busy, as it was behind the slow listing, the
  # listing still answers, because it does not go through the link; so the link's calls,
  # `agents.list` among them, no longer wait behind it either. On the tip this waited on the
  # link until the link answered.
  test "the worktree listing goes on a connection of its own, not the link's" do
    ws = git_init!(tmp_workspace())
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {:ok, _endpoint} = Link.ensure()

    :ok = :sys.suspend(Link)

    try do
      listing = Task.async(fn -> Client.worktree_status(sid) end)
      assert {:ok, [%{path: path}]} = Task.await(listing, 10_000)
      assert Path.basename(path) == Path.basename(ws)

      assert {[], []} = Task.await(Task.async(fn -> Client.worktrees(ws) end), 10_000)
    after
      :sys.resume(Link)
    end
  end
end
