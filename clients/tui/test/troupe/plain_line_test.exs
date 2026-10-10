defmodule Troupe.PlainLineTest do
  @moduledoc """
  A line typed without a slash is work for an agent, whatever its first word (issue #496,
  TUI Decision 101): "help me fix the failing test" is a request, not `/help`. In command
  mode it starts the default agent on it, in the checkout (TUI Decision 155). A built-in
  runs from a line that starts with `/`, or from the palette (`Troupe.CommandPaletteTest`
  runs every one of them that way).
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  test "a plain line whose first word is a built-in's name starts the default agent on it" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    type(pid, "help me fix the failing test")
    press(pid, "enter")

    spawned = await_event("build-1", :branch_spawned, 10_000)
    assert spawned.data.prompt == "help me fix the failing test"
    assert user_state(pid).focus == :command
  end

  # Every name and alias the harness's table gives a built-in, on its own and with words
  # after it, so a command added to the table is covered here without a word changed.
  test "no built-in's name or alias at the start of a plain line keeps it from the agent" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    words = Enum.flat_map(Troupe.Commands.builtins(), &[&1["name"] | &1["aliases"]])
    lines = Enum.flat_map(words, &[&1, &1 <> " the failing test"])

    for line <- lines do
      type(pid, line)
      assert user_state(pid).cmd_text == line, line
      press(pid, "enter")
      assert Process.alive?(pid), line
      assert user_state(pid).focus == :command, line
      assert user_state(pid).cmd_text == "", line
    end

    eventually(fn -> received(sid) == lines end, 10_000)
  end

  # The issue's own lines with a slash are the commands they name: `/help` opens the
  # palette whatever follows it, and a window command answers that there is no such
  # window. None of them is sent to the agent.
  test "the same line with a slash runs the built-in" do
    {sid, _, _} = start_session!(script: [])
    {pid, _session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)

    type(pid, "/help me fix the failing test")
    press(pid, "enter")
    assert user_state(pid).focus == :palette
    press(pid, "esc")

    for line <- [
          "/copy the config into the docs",
          "/merge the two functions",
          "/discard the old approach"
        ] do
      notices = length(user_state(pid).model.notices)
      type(pid, line)
      assert user_state(pid).cmd_text == line, line
      press(pid, "enter")
      assert user_state(pid).focus == :command, line
      eventually(fn -> length(user_state(pid).model.notices) > notices end)
    end

    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  # The lines the session's agent was sent, in the order they came. One that arrives while
  # it works is listed when it is queued and again when it is taken, so once is enough:
  # waiting for every turn would only measure the turns.
  defp received(sid),
    do: Enum.uniq(for %{type: :input, data: %{content: c}} <- Client.events(sid), do: c)
end
