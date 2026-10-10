defmodule Troupe.CommandAuditTest do
  @moduledoc """
  The audit of every command (issue #502, part B; `docs/developer/command-audit.md`): what
  the rows of the harness's table do when they are typed, from the command line and from
  the palette over an activated window, on this machine and on a pod, where the audit
  found them wrong or nothing else held them.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp line(pid), do: user_state(pid).cmd_text

  defp notices(pid), do: user_state(pid).model.notices

  defp await_notice(pid, before) do
    eventually(fn -> length(notices(pid)) > length(before) or notices(pid) != before end)
    hd(notices(pid))
  end

  describe "Tab on the command line (D93)" do
    # A line without a slash is said to the agent (TUI Decision 101), so a name Tab
    # completes there carries its slash: Enter then runs the command it shows.
    test "completing a command name puts its slash in" do
      {sid, _, _} = start_session!(script: [])
      {pid, _session} = ready(sid)

      type(pid, "mer")
      press(pid, "tab")
      assert line(pid) == "/merge "

      press(pid, "esc")
      type(pid, "hel")
      press(pid, "tab")
      assert line(pid) == "/help "
    end

    test "a name the palette put on the line, edited, completes again" do
      {sid, _, _} = start_session!(script: [])
      {pid, _session} = ready(sid)

      press(pid, "/")
      type(pid, "merge")
      press(pid, "tab")
      assert line(pid) == "/merge "

      for _ <- 1..3, do: press(pid, "backspace")
      assert line(pid) == "/mer"
      press(pid, "tab")
      assert line(pid) == "/merge "
    end

    test "a window completed after a bare command name carries the slash too" do
      {sid, _, _} = start_session!(script: [{:text, "done"}])
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
      eventually(fn -> match?(%{state: :done_unread}, user_state(pid).model.windows["build-1"]) end)

      type(pid, "dismiss b")
      press(pid, "tab")
      assert line(pid) == "/dismiss build-1"

      # And Enter runs it: the branch's window goes, and nothing reaches the agent as text.
      press(pid, "enter")
      await_event("build-1", :window_dismissed)
      assert line(pid) == ""
      refute Enum.any?(Client.events(sid), &(&1.type == :input and &1.agent_path == "root"))
    end

    test "a Tab that finds nothing leaves a plain line as it was typed" do
      {sid, _, _} = start_session!(script: [])
      {pid, _session} = ready(sid)

      for text <- ["fix the flaky test", "merge the two functions", "zzz"] do
        type(pid, text)
        press(pid, "tab")
        assert line(pid) == text
        press(pid, "esc")
      end
    end
  end

  describe "/quit" do
    # Sessions live in the daemon (the row's own words): the screen goes, the session stays.
    test "each of its names closes the screen and leaves the session running" do
      {sid, _, _} = start_session!(script: [])

      for line <- ["/quit", "/q", "/exit"] do
        me = self()
        {pid, _session} = start_tui(sid, on_quit: fn -> send(me, {:quit, line}) end)
        eventually(fn -> user_state(pid).commands != [] end)
        ref = Process.monitor(pid)
        Process.unlink(pid)

        paste(pid, line)
        press(pid, "enter")

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
        assert_received {:quit, ^line}
        assert Client.has_session?(sid), line
      end
    end
  end

  describe "/merge and /discard" do
    # The window goes either way, so the line under the screen is where the person learns
    # which branch landed or went.
    test "each says what it did once the window has gone" do
      ws = git_init!(tmp_workspace())
      {sid, _, ^ws} = start_session!(workspace: ws, script: [{:text, "done"}])
      run_git!(ws, ["add", "-A"])
      run_git!(ws, ["commit", "-q", "-m", "fake model"])
      {pid, _session} = ready(sid)

      for {verb, said} <- [
            {"merge", ~r/^merged troupe\/\S+ into the checkout$/},
            {"discard", ~r/^discarded troupe\/\S+$/}
          ] do
        assert {:ok, window} = Client.dispatch(sid, "build", "say done")
        assert %{data: %{isolation: :worktree}} = await_event(window, :branch_spawned)

        eventually(
          fn -> match?(%{state: :done_unread}, user_state(pid).model.windows[window]) end,
          10_000
        )

        before = notices(pid)
        paste(pid, "/#{verb} #{window}")
        press(pid, "enter")
        await_event(window, :window_dismissed)
        assert await_notice(pid, before) =~ said
      end
    end

    # A branch that works in the checkout has no worktree of its own to land or to throw
    # away, and the refusal says which of the two was asked for.
    test "on a branch that shares the checkout, each says it has nothing to do" do
      {sid, _, _} = start_session!(script: [{:text, "done"}])
      {pid, _session} = ready(sid)

      assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
      assert %{data: %{isolation: :shared}} = await_event("build-1", :branch_spawned)

      before = notices(pid)
      press(pid, "/")
      type(pid, "discard")
      press(pid, " ")
      type(pid, "build-1")
      press(pid, "enter")

      assert await_notice(pid, before) ==
               "build-1 shares this checkout; there is nothing to discard"

      before = notices(pid)
      paste(pid, "/merge build-1")
      press(pid, "enter")
      assert await_notice(pid, before) == "build-1 shares this checkout; there is nothing to merge"
    end
  end

  describe "with a window activated" do
    # The palette opened over a window (Ctrl-K) runs a window command on that window, and
    # the rest as they run from the command line.
    test "a window command picked from the palette acts on the activated window" do
      ws = git_init!(tmp_workspace())
      {sid, _, ^ws} = start_session!(workspace: ws, script: [{:text, "done"}])
      run_git!(ws, ["add", "-A"])
      run_git!(ws, ["commit", "-q", "-m", "fake model"])
      {pid, _session} = ready(sid)
      clipboard_path()

      for {name, said} <- [
            {"copy", ~r/^copied \d+ lines? to the clipboard/},
            {"merge", ~r/^merged troupe\/\S+ into the checkout$/},
            {"dismiss", nil}
          ] do
        assert {:ok, window} = Client.dispatch(sid, "build", "say done")

        eventually(
          fn -> match?(%{state: :done_unread}, user_state(pid).model.windows[window]) end,
          10_000
        )

        index =
          Enum.find_index(Troupe.UI.TUI.Model.windows(user_state(pid).model), &(&1.path == window))

        press(pid, Integer.to_string(index + 1))
        assert user_state(pid).focus == {:window, window}

        before = notices(pid)
        press(pid, "k", ["ctrl"])
        type(pid, name)
        press(pid, "enter")

        if said, do: assert(await_notice(pid, before) =~ said, name)
        if name in ["merge", "dismiss"], do: await_event(window, :window_dismissed)

        refute Enum.any?(
                 Client.events(sid),
                 &(&1.type == :input and &1.agent_path == window and &1.data.content =~ name)
               )

        press(pid, "esc")
      end
    end
  end

  describe "on a pod" do
    @describetag :remote

    defp on_a_pod do
      session =
        FakeRemote.session(
          id: "s-pod",
          profile: "build",
          title: "on a pod",
          events: [%{"type" => "message.completed", "data" => %{"text" => "first line"}}]
        )

      {remote, url} = start_remote!(sessions: [session])
      sid = attach!(connect!(remote, url), "s-pod")
      {pid, _session} = start_tui(sid)
      eventually(fn -> user_state(pid).commands != [] end)
      eventually(fn -> user_state(pid).model.windows != %{} end)
      {remote, sid, pid}
    end

    # The notice a line leaves, or the notices as they stand when none came.
    defp answer(pid, line) do
      before = notices(pid)
      paste(pid, line)
      press(pid, "enter")

      try do
        await_notice(pid, before)
      rescue
        ExUnit.AssertionError -> {:none, notices(pid)}
      end
    end

    # Every built-in typed on a session a plane runs, the screen's own pages left with Esc:
    # the screen stays up, and none of them is sent to the agent as words.
    test "every built-in typed on a pod session runs as a command, none as input" do
      {remote, _sid, pid} = on_a_pod()

      upload = Path.join(System.tmp_dir!(), "troupe-audit-#{System.unique_integer([:positive])}")
      File.write!(upload, "from this machine")
      on_exit(fn -> File.rm(upload) end)

      for %{"name" => name} <- Troupe.Commands.builtins(), name not in ["quit", "new", "back"] do
        line = if name == "upload", do: "/upload " <> upload, else: "/" <> name
        paste(pid, line)
        press(pid, "enter")
        assert Process.alive?(pid), line
        assert user_state(pid).cmd_text == "", line
        if user_state(pid).focus != :command, do: press(pid, "esc")
        if user_state(pid).focus != :command, do: press(pid, "esc")
        assert user_state(pid).focus == :command, line
      end

      refute Enum.any?(FakeRemote.calls(remote), &match?({"input.send", _}, &1))
    end

    # What only a session on this machine can do says why on a pod, typed or picked.
    test "a local-only command says why it cannot run there" do
      {_remote, _sid, pid} = on_a_pod()

      for {line, said} <- [
            {"/watch", "watch mode runs where the files are"},
            {"/memory", "the project brief lives on the worker"},
            {"/merge 1", "a remote session has no local worktree to merge"},
            {"/discard 1", "a remote session has no local worktree to discard"},
            {"/worktree fix it",
             "a remote session runs one profile; create another session from HQ"},
            {"/build fix it", "a remote session runs one profile; create another session from HQ"}
          ] do
        assert {line, answer(pid, line)} == {line, said}
        if user_state(pid).focus != :command, do: press(pid, "esc")
      end

      # The palette greys them first, with the reason, and Enter on one says it.
      for name <- ["watch", "memory", "merge", "discard", "worktree"] do
        press(pid, "k", ["ctrl"])
        type(pid, name)
        {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))

        assert %{
                 entry: %{"name" => ^name},
                 status: {:no, "only for a session on this machine" <> _}
               } =
                 Enum.at(rows, cursor)

        press(pid, "esc")
      end

      press(pid, "k", ["ctrl"])
      type(pid, "watch")
      before = notices(pid)
      press(pid, "enter")

      assert await_notice(pid, before) ==
               "only for a session on this machine; this one runs on a plane"
    end
  end

  describe "/watch" do
    # The toggle reads the screen's own record of whether watch is on; a `/watch` that
    # turned it on has to leave that saying so, or the next `/watch` turns it on again.
    test "a second /watch turns watch off, and the status line follows" do
      {sid, _, _} = start_session!(script: [])
      {pid, session} = ready(sid)

      press(pid, "/")
      type(pid, "watch")
      press(pid, "enter")
      # Where there is no native watcher, the daemon's word that it polls comes too.
      eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "watch mode on")) end)
      assert user_state(pid).model.watch.enabled
      assert screen_text(pid, session) =~ ~r/watch: (native|poll)/

      before = notices(pid)
      press(pid, "/")
      type(pid, "watch")
      press(pid, "enter")
      assert await_notice(pid, before) == "watch mode off"
      refute user_state(pid).model.watch.enabled
      assert screen_text(pid, session) =~ "watch: off"
      refute Troupe.Session.Watcher.enabled?(sid)
    end
  end
end
