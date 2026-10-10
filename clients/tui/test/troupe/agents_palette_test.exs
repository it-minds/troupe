defmodule Troupe.AgentsPaletteTest do
  @moduledoc """
  What an agent is on screen (issue #503, TUI Decision 156): the palette tells a command,
  an agent and a repository's own command apart, an agent's row says where it comes from
  and what it may do, and each window says which agent it runs and switches it with one
  key and a chooser, the transcript recording the switch. With the palette's rows the
  command audit found wrong (D107).
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.UI.TUI.View

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    eventually(fn -> Map.has_key?(user_state(pid).model.windows, "root") end)
    {pid, session}
  end

  defp row(pid, name) do
    {rows, _cursor} = View.palette_view(user_state(pid))
    Enum.find(rows, &(&1.entry["name"] == name))
  end

  test "the palette tells a command, an agent and a repository's command apart" do
    ws =
      tmp_workspace(%{
        ".troupe/commands/review.md" => "---\ndescription: Review the change\n---\nReview it.\n"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [])
    {pid, session} = ready(sid)

    press(pid, "/")
    type(pid, "plan")
    text = screen_text(pid, session)
    assert text =~ ~r/\/plan +agent +built-in · default · read-only · checkout +Read/
    assert text =~ "An agent, from built-in"
    assert text =~ "Tab in a window switches"

    for _ <- 1..4, do: press(pid, "backspace")
    type(pid, "merge")
    assert screen_text(pid, session) =~ ~r/\/merge +command +Land a worktree branch/

    for _ <- 1..5, do: press(pid, "backspace")
    type(pid, "review")
    assert screen_text(pid, session) =~ ~r/\/review +repository +Review the change/

    # `/worktree` is a command that starts an agent, and looks it.
    for _ <- 1..6, do: press(pid, "backspace")
    type(pid, "worktree")
    assert screen_text(pid, session) =~ ~r/\/worktree +command +Run the default agent/
  end

  test "an agent row that cannot run here says why" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = ready(sid)

    # The rows are read as the palette first opens.
    assert user_state(pid).agent_rows == %{}
    press(pid, "/")
    assert user_state(pid).agent_rows["plan"]["available"] == true
    press(pid, "esc")

    :sys.replace_state(pid, fn server ->
      update_in(server.user_state.agent_rows["plan"], fn row ->
        Map.merge(row, %{
          "available" => false,
          "reason" => "its model, x, is not one the provider serves"
        })
      end)
    end)

    press(pid, "/")
    type(pid, "plan")
    assert %{status: {:no, reason}} = row(pid, "plan")
    assert reason =~ "plan cannot run here: its model, x, is not one the provider serves"
  end

  test "each window says which agent it runs, and Tab switches it with a chooser" do
    {sid, _, _} = start_session!(script: [{:text, "done"}])
    {pid, session} = ready(sid)

    assert screen_text(pid, session) =~ "root (build)"

    assert {:ok, "build-1"} = Client.dispatch(sid, "build", "say done")
    eventually(fn -> match?(%{state: :done_unread}, user_state(pid).model.windows["build-1"]) end)
    assert screen_text(pid, session) =~ "build-1 (build)"

    press(pid, "2")
    assert user_state(pid).focus == {:window, "build-1"}
    press(pid, "tab")
    assert user_state(pid).focus == :chooser
    text = screen_text(pid, session)
    assert text =~ "the agent build-1 runs"
    assert text =~ ~r/build +● built-in · default · checkout/
    assert text =~ "You are Troupe's build agent"

    # Down to plan: its instruction is beside the list before it is chosen.
    eventually(fn ->
      press(pid, "down")
      Enum.at(user_state(pid).chooser.rows, user_state(pid).chooser.cursor)["name"] == "plan"
    end)

    assert screen_text(pid, session) =~ "You are Troupe's plan agent"
    press(pid, "enter")
    assert user_state(pid).focus == {:window, "build-1"}
    assert hd(user_state(pid).model.notices) =~ "build-1 runs plan from its next turn"

    # The daemon switched it: the header follows, and the transcript records it.
    eventually(fn -> user_state(pid).model.windows["build-1"].profile == "plan" end)
    assert screen_text(pid, session) =~ "build-1 (plan)"

    assert_receive {:troupe_event,
                    %{
                      agent_path: "build-1",
                      type: :remote_note,
                      data: %{text: "profile switched" <> _ = switched}
                    }},
                   5_000

    assert switched =~ "build → plan (builtin)"
    assert switched =~ "loses"

    # Esc keeps what it runs.
    press(pid, "tab")
    press(pid, "esc")
    assert user_state(pid).focus == {:window, "build-1"}
  end

  describe "the palette's rows the audit found wrong (D107)" do
    test "Tab completes by name, not by a word in a description" do
      {sid, _, _} = start_session!(script: [])
      {pid, _session} = ready(sid)

      press(pid, "/")
      type(pid, "wor")
      press(pid, "tab")
      assert user_state(pid).cmd_text == "/worktree "
    end

    test "a command a file defines that takes words asks for them rather than running empty" do
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
      {pid, _session} = ready(sid)

      press(pid, "/")
      type(pid, "review")
      press(pid, "enter")
      assert user_state(pid).focus == :command
      assert user_state(pid).cmd_text == "/review "
      refute Enum.any?(Client.events(sid), &(&1.type == :input))
    end

    test "the palette over a window keeps the window for a command that takes words" do
      {sid, _, ws} = start_session!(script: [])
      {pid, session} = ready(sid)

      upload = Path.join(System.tmp_dir!(), "troupe-y26-#{System.unique_integer([:positive])}.txt")
      File.write!(upload, "from this machine")
      on_exit(fn -> File.rm(upload) end)

      press(pid, "1")
      assert user_state(pid).focus == {:window, "root"}
      press(pid, "k", ["ctrl"])
      type(pid, "upload")
      press(pid, "enter")

      assert user_state(pid).focus == {:window, "root"}
      assert user_state(pid).win_text == "/upload "
      assert screen_text(pid, session) =~ "a command for this window"

      paste(pid, upload)
      press(pid, "enter")
      eventually(fn -> File.exists?(Path.join(ws, Path.basename(upload))) end)
      assert user_state(pid).focus == {:window, "root"}
      assert user_state(pid).win_text == ""
      refute Enum.any?(Client.events(sid), &(&1.type == :input))

      # Tab takes a command into the window's box too, and Enter runs it on that window.
      press(pid, "k", ["ctrl"])
      type(pid, "copy")
      press(pid, "tab")
      assert user_state(pid).win_text == "/copy "
      assert user_state(pid).win_command
      press(pid, "enter")
      assert user_state(pid).focus == {:window, "root"}
      refute hd(user_state(pid).model.notices) =~ "no window given"
      refute Enum.any?(Client.events(sid), &(&1.type == :input))
    end
  end
end
