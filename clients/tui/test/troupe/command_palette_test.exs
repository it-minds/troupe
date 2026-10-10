defmodule Troupe.CommandPaletteTest do
  @moduledoc """
  The command palette (issue #124, Decision 119): one list behind the protocol, drawn as
  a popup over the session. `/` on an empty line opens it with every section and a
  description per command; typing filters it; Enter runs the row, or puts it on the line
  when it wants an argument; Esc closes it; `/help` opens it; and the set of built-ins
  the TUI runs is exactly the set the harness lists, so nothing can drift.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.Server

  test "the TUI runs exactly the built-ins the harness lists" do
    listed = Troupe.Commands.builtins() |> Enum.map(& &1["name"]) |> Enum.sort()
    assert Enum.sort(Server.builtins()) == listed
  end

  test "the session's command table reaches the TUI over the socket, agents included" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)

    eventually(fn -> user_state(pid).commands != [] end)
    commands = user_state(pid).commands
    names = Enum.map(commands, & &1["name"])

    assert "goal" in names
    assert "help" in names
    assert "build" in names
    assert Enum.find(commands, &(&1["name"] == "build"))["source"] == "agent"
    assert commands == Client.command_table(sid)
  end

  test "/ on an empty line opens a sectioned palette with a description per command" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    assert user_state(pid).focus == :palette
    text = screen_text(pid, session)

    for section <- ["Session", "Navigate", "Workspace"] do
      assert text =~ "─ #{section} ", "no #{section} section on screen"
    end

    assert text =~ "/merge"
    assert text =~ "Land a worktree branch on the checkout"
    assert text =~ "/goal"
    assert text =~ "Set, show or clear the session's goal"
    # The command box shows the filter.
    assert text =~ "type to filter"

    # More rows than fit: the list scrolls with the cursor, so the last section comes
    # into view at the end.
    refute text =~ "─ Quit "
    press(pid, "end")
    text = screen_text(pid, session)
    assert text =~ "─ Quit "
    assert text =~ "/quit"
    {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert cursor == length(rows) - 1

    press(pid, "esc")
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == ""
  end

  test "typing filters by name, alias and summary, and Esc keeps the line clear" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    type(pid, "mer")
    {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert Enum.map(rows, & &1.entry["name"]) == ["merge"]
    assert cursor == 0
    assert screen_text(pid, session) =~ "commands — 1 of"

    # An alias is found and lands the cursor on its command, so `/q` + Enter still quits.
    press(pid, "backspace")
    press(pid, "backspace")
    press(pid, "backspace")
    type(pid, "q")
    {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert Enum.at(rows, cursor).entry["name"] == "quit"

    # A summary word finds its command.
    press(pid, "backspace")
    type(pid, "clipboard")
    {rows, _} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert Enum.map(rows, & &1.entry["name"]) == ["copy"]

    press(pid, "esc")
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == ""
  end

  test "Enter runs a command without arguments, and puts one that needs them on the line" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    # `/settings` runs: the settings page opens.
    press(pid, "/")
    type(pid, "settings")
    press(pid, "enter")
    assert user_state(pid).focus == :settings
    press(pid, "esc")

    # `/upload` needs a path: Enter puts it on the line to finish typing.
    press(pid, "/")
    type(pid, "upload")
    press(pid, "enter")
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == "/upload "

    # Space does the same for a prefix, which is how `/merge 2` has always been typed.
    press(pid, "esc")
    press(pid, "/")
    type(pid, "mer ")
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == "/merge "
  end

  test "a window command with no window activated is greyed and Enter puts it on the line" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    type(pid, "cancel")
    {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert {:window, reason} = Enum.at(rows, cursor).status
    assert reason =~ "activate one"
    assert screen_text(pid, session) =~ "not now: acts on a window"

    press(pid, "enter")
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == "/cancel "
  end

  test "/help opens the palette, and Ctrl-K does on an empty line" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    # Typed on the line (the palette's Space puts it there), so it is `/help` that opens it.
    type(pid, "/help ")
    assert user_state(pid).focus == :command
    press(pid, "enter")
    assert user_state(pid).focus == :palette
    press(pid, "esc")

    press(pid, "k", ["ctrl"])
    assert user_state(pid).focus == :palette
    press(pid, "esc")

    # With text on the line Ctrl-K is still the editor's kill-to-end.
    type(pid, "abc")
    press(pid, "left")
    press(pid, "k", ["ctrl"])
    assert user_state(pid).focus == :command
    assert user_state(pid).cmd_text == "ab"
  end

  # A command a repository defines (Decision 763): `.troupe/commands/review.md` is a row of
  # a section of its own with its file's description, and running it sends its prompt
  # with what was typed after the name, which comes back as the input of the branch it
  # starts in command mode (TUI Decision 155).
  test "a command a file defines is in the palette with its description, and runs" do
    ws =
      tmp_workspace(%{
        ".troupe/commands/review.md" => """
        ---
        description: Review the change on this branch
        argument-hint: <what to look at>
        ---
        Review the change on this branch. Look hardest at $ARGUMENTS.
        """
      })

    {sid, _, _} = start_session!(workspace: ws, script: [{:text, "looked"}])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    type(pid, "review")
    text = screen_text(pid, session)
    assert text =~ "─ Custom "
    assert text =~ "/review"
    assert text =~ "Review the change on this branch"
    assert text =~ "/review <what to look at>"
    {rows, cursor} = Troupe.UI.TUI.View.palette_view(user_state(pid))
    assert %{entry: %{"source" => "project"}, status: :ok} = Enum.at(rows, cursor)

    # What it sends is in its detail, not only what its frontmatter says (Decision 814).
    assert text =~ "sends:"
    assert text =~ "│ Review the change on this branch."

    # Space leaves it on the line, and what follows the name is its argument.
    press(pid, " ")
    assert user_state(pid).cmd_text == "/review "
    type(pid, "the parser")
    press(pid, "enter")

    # In command mode it runs in a branch of its own (TUI Decision 155).
    input = await_event("build-1", :input, 10_000)
    assert input.data.content == "Review the change on this branch. Look hardest at the parser."
    assert user_state(pid).focus == :command
  end

  # A long prompt shows as much of itself as the detail pane has room for, and says how
  # much more the file holds (Decision 814).
  test "a long command shows its first lines and how many more there are" do
    body = Enum.map_join(1..60, "\n", &"step #{&1} of the review")

    ws =
      tmp_workspace(%{".troupe/commands/audit.md" => "---\ndescription: Audit it\n---\n#{body}\n"})

    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    type(pid, "audit")
    text = screen_text(pid, session)

    assert text =~ "│ step 1 of the review"
    refute text =~ "step 60 of the review"
    [_, more] = Regex.run(~r/… (\d+) more lines in the file/, text)
    shown = length(Regex.scan(~r/│ step \d+ of the review/, text))
    assert shown > 3
    assert shown + String.to_integer(more) == 60
  end

  test "a query nothing matches runs as typed, as an unknown command always did" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    press(pid, "/")
    type(pid, "nosuchthing")
    assert screen_text(pid, session) =~ "nothing matches /nosuchthing"
    press(pid, "enter")
    assert user_state(pid).focus == :command
    eventually(fn -> user_state(pid).model.notices != [] end)
    assert hd(user_state(pid).model.notices) =~ "nosuchthing"
  end

  # Every built-in typed in full still runs as it did: the TUI stays up and none of them
  # was sent to the agent as input. `quit` ends the app, `worktree` starts a branch and
  # `new` a session, so those three are left out here; the client tests cover them.
  test "every built-in typed in full still runs" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    for name <- Server.builtins() -- ["quit", "worktree", "new"] do
      type(pid, "/#{name} ")
      press(pid, "enter")
      assert Process.alive?(pid), name
      # Whatever page the command opened, Esc is the way back; twice for a menu.
      press(pid, "esc")
      press(pid, "esc")
      assert user_state(pid).focus == :command, name
    end

    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end
end
