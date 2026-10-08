defmodule Troupe.ShellModeTest do
  @moduledoc """
  Shell mode on the command line (issue #486, Decision 152): `!` on an empty line
  puts the box in shell mode, Enter runs the command in the session's workspace through
  `shell.run`, and the transcript shows it as the person's command with its output and
  how it ended; Esc kills one that runs; `!!` keeps it from the agent; a session whose
  policy forbids it is refused with the harness's sentence. Nothing typed after `!` is
  ever sent to the agent as text.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  @moduletag timeout: 60_000

  test "!cmd runs in the session's workspace and shows the person's command, not input" do
    ws = tmp_workspace(%{"marker.txt" => "here"})
    {sid, _, ^ws} = start_session!(workspace: ws, script: [])
    {pid, session} = start_tui(sid)

    type(pid, "!ls; exit 4")
    press(pid, "enter")

    entry = eventually_shell(pid, &(&1.status != :running))
    assert entry.command == "ls; exit 4"
    assert entry.status == :exited
    assert entry.exit_status == 4
    assert entry.output =~ "marker.txt"
    assert entry.agent == true

    # Nothing went to the agent as text: no line of the person's, in the window or the log.
    refute Enum.any?(transcript(pid), &match?({:user, _}, &1))
    refute Enum.any?(Client.events(sid), &(&1.type == :input))
    assert user_state(pid).cmd_text == ""

    text = screen_text(pid, session)
    assert text =~ "! ls; exit 4"
    assert text =~ "exit 4"
  end

  test "! on an empty line is shell mode, and backspace on it leaves" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "!")
    assert user_state(pid).cmd_text == "!"
    text = screen_text(pid, session)
    assert text =~ "shell"
    assert text =~ "no stdin"
    # The box's slash prompt gives way to the `!`.
    refute text =~ "/!"

    press(pid, "backspace")
    assert user_state(pid).cmd_text == ""
    refute screen_text(pid, session) =~ "no stdin"
  end

  test "a pasted line that starts with ! runs as a command too" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)

    paste(pid, "!echo pasted")
    press(pid, "enter")

    entry = eventually_shell(pid, &(&1.status != :running))
    assert entry.output =~ "pasted"
  end

  test "Esc kills a running command, and the block says so" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "!echo begun; sleep 30")
    press(pid, "enter")

    eventually_shell(pid, &(&1.status == :running and &1.output =~ "begun"))
    eventually(fn -> user_state(pid).shell != nil end)
    assert screen_text(pid, session) =~ "Esc kills it"

    press(pid, "esc")

    entry = eventually_shell(pid, &(&1.status != :running), 15_000)
    assert entry.status == :killed
    assert user_state(pid).shell == nil
    assert screen_text(pid, session) =~ "killed"
  end

  test "!!cmd runs the command and keeps it from the agent" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    type(pid, "!!echo private")
    press(pid, "enter")

    entry = eventually_shell(pid, &(&1.status != :running))
    assert entry.command == "echo private"
    assert entry.agent == false
    assert screen_text(pid, session) =~ "kept from the agent"
  end

  test "a policy that forbids it is refused with the harness's sentence" do
    {sid, _, _} = start_session!(script: [], config: %{"managed_permission_rules_only" => true})
    {pid, _session} = start_tui(sid)

    type(pid, "!echo no")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "commands typed with ! are turned off"))
    end)

    assert shells(pid) == []
    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  test "! alone says what to type rather than running nothing" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)

    type(pid, "!!")
    press(pid, "enter")

    assert Enum.any?(user_state(pid).model.notices, &(&1 =~ "type a command after"))
    assert shells(pid) == []
  end

  defp transcript(pid) do
    model = user_state(pid).model

    case Map.values(model.windows) do
      [window] -> window.agents[window.path].transcript
      _ -> []
    end
  end

  defp shells(pid), do: for({:shell, entry} <- transcript(pid), do: entry)

  defp eventually_shell(pid, done?, timeout \\ 10_000) do
    eventually(fn -> Enum.find(shells(pid), done?) end, timeout)
  end
end
