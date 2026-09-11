defmodule Troupe.MemoryTUITest do
  @moduledoc "The /memory command: view, forget, and precedence over an agent of the same name."
  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Session

  defp brief_text do
    """
    ---
    built_at: #{DateTime.to_iso8601(DateTime.utc_now())}
    head: abc1234
    files: 1
    ---

    ## Overview
    A fixture project.

    ## Commands
    - test: `mise exec -- mix test`
    """
  end

  test "/memory summarises the brief, and /memory forget deletes it" do
    ws = tmp_workspace(%{".troupe/memory.md" => brief_text()})
    {sid, _fake, _} = start_session!(workspace: ws)
    {pid, session} = start_tui(sid)

    type(pid, "memory")
    press(pid, "enter")
    text = screen_text(pid, session)
    assert text =~ "project brief (fresh"
    assert text =~ "Overview, Commands"

    type(pid, "memory forget")
    press(pid, "enter")
    assert screen_text(pid, session) =~ "project brief forgotten"
    refute File.exists?(Session.Memory.path(ws))

    type(pid, "memory")
    press(pid, "enter")
    assert screen_text(pid, session) =~ "no project brief yet"
  end

  test "/memory beats an agent profile of the same name" do
    ws =
      tmp_workspace(%{
        ".troupe/agents/memory.md" => """
        ---
        description: A decoy profile that must not win the command name.
        mode: primary
        ---
        You are a decoy.
        """
      })

    {sid, _fake, _} = start_session!(workspace: ws)
    {pid, session} = start_tui(sid)

    assert "memory" in Session.Dispatcher.commands(sid), "the decoy profile is loaded"

    type(pid, "memory")
    press(pid, "enter")

    assert screen_text(pid, session) =~ "no project brief yet"
    assert Troupe.windows(sid) == [], "no branch was dispatched"
  end

  test "an unknown /memory subcommand explains itself" do
    {sid, _fake, _} = start_session!()
    {pid, session} = start_tui(sid)

    type(pid, "memory wat")
    press(pid, "enter")
    assert screen_text(pid, session) =~ "unknown /memory wat"
  end
end
