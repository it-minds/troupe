defmodule Troupe.MemoryFactsTUITest do
  @moduledoc """
  `/memory` lists memory's facts (#248, root Decision 839): kind by kind, each with its
  status, "may no longer be true" in its own colour (not the reserved one), where the
  selected fact came from beside the list, and `x` forgets it. A daemon from before facts
  answers the line `/memory` always did.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.CellSession
  alias ExRatatui.Frame
  alias Troupe.Client
  alias Troupe.Memory.Facts
  alias Troupe.UI.TUI.{Palette, View}

  @mix "defmodule R.MixProject do\n  def project, do: [aliases: [check: [\"test\"]]]\nend\n"

  test "/memory lists the facts by kind with their status and evidence, and x forgets one" do
    ws = git_init!(tmp_workspace(%{"mix.exs" => @mix, "README.md" => "# r\n"}))
    {sid, _, ws} = start_session!(workspace: ws)

    {:ok, command} =
      Facts.put(
        ws,
        %{kind: "command", claim: "The gate is `mix check`", anchors: ["mix.exs"], scope: nil},
        %{session: "s-librarian", seq: 41, by: "librarian", exit_status: 0}
      )

    {:ok, convention} =
      Facts.put(
        ws,
        %{kind: "convention", claim: "Squash before merging", anchors: [], scope: nil},
        %{session: nil, seq: nil, by: "person"}
      )

    {:ok, _layout} =
      Facts.put(
        ws,
        %{kind: "layout", claim: "lib/ holds the code", anchors: ["README.md"], scope: "lib/**"},
        %{session: "s-librarian", seq: 42, by: "librarian"}
      )

    # The check alias moved: the command may no longer be true.
    File.write!(Path.join(ws, "mix.exs"), @mix <> "# moved\n")

    {pid, session} = start_tui(sid)
    type(pid, "/memory")
    press(pid, "enter")

    eventually(fn -> user_state(pid).focus == :memory end)
    text = screen_text(pid, session)

    assert text =~ "Memory: 3 facts, 1 may no longer be true"
    # Kind by kind, in the page's order.
    assert [_, after_commands] = String.split(text, "Commands (1)", parts: 2)
    assert [_, after_conventions] = String.split(after_commands, "Conventions (1)", parts: 2)
    assert after_conventions =~ "Layout (1)"
    assert text =~ "The gate is `mix check`  may no longer be true"

    # The first fact is selected, and where it came from is beside the list.
    assert text =~ "moved: an anchor changed, may no longer be true"
    assert text =~ "written by librarian"
    assert text =~ "session    s-librarian (event 41)"
    assert text =~ "exited     0"
    assert text =~ "anchors    mix.exs (#{String.slice(hd(command["anchors"])["hash"], 0, 8)})"

    # "may no longer be true" is drawn in its own role, never the reserved colour: beside
    # the selected fact's status here, and on its row once another is selected.
    stale = rgb(Palette.roles().stale.dark.rgb)
    reserved = rgb(Palette.roles().needs_you.dark.rgb)

    cells = truecolor_cells(user_state(pid))
    assert Enum.any?(cells_of(cells, "may no longer be true"), &(&1.fg == stale))
    refute Enum.any?(cells, &(&1.fg == reserved))

    # Down to the person's convention: unanchored, and theirs.
    press(pid, "j")
    text = screen_text(pid, session)
    assert text =~ "unanchored: it ages out"
    assert text =~ "written by person"

    cells = truecolor_cells(user_state(pid))
    # The page's title (row 0) counts them in the frame's own ink.
    warned = cells |> cells_of("may no longer be true") |> Enum.filter(&(&1.row > 0))
    assert warned != [] and Enum.all?(warned, &(&1.fg == stale))
    refute Enum.any?(cells, &(&1.fg == reserved))

    # x forgets the selected fact, and the page is read again.
    press(pid, "x")
    eventually(fn -> not Enum.any?(Facts.list(ws), &(&1["id"] == convention["id"])) end)
    eventually(fn -> screen_text(pid, session) =~ "Memory: 2 facts, 1 may no longer be true" end)
    assert hd(user_state(pid).model.notices) == "forgot: Squash before merging"

    press(pid, "esc")
    eventually(fn -> user_state(pid).focus == :command end)
  end

  test "/memory with no facts says how they are written" do
    {sid, _, _ws} = start_session!(workspace: git_init!(tmp_workspace()))
    {pid, session} = start_tui(sid)
    type(pid, "/memory")
    press(pid, "enter")

    eventually(fn -> user_state(pid).focus == :memory end)
    text = screen_text(pid, session)
    assert text =~ "No facts yet."
    assert text =~ "/memory refresh has the librarian survey the repository"
  end

  # A daemon from before facts answers `memory.get` with no `facts`, and a brief that is off
  # has none to list: `/memory` answers the line it always did.
  test "a daemon with no facts to answer leaves /memory the line it was" do
    old = %{
      "status" => "fresh",
      "path" => "/w/.troupe/memory.md",
      "built_at" => "2026-10-01T00:00:00Z",
      "sections" => ["Overview"],
      "text" => "## Overview\nA fixture.\n",
      "refresh_due" => false,
      "refresh_held_until" => nil
    }

    assert Troupe.Client.Daemon.memory_page(old) == :no_facts
    assert Troupe.Client.Daemon.memory_page(%{"status" => "disabled", "facts" => []}) == :no_facts

    assert {:ok, %{facts: [], status: "absent"}} =
             Troupe.Client.Daemon.memory_page(%{"status" => "absent", "facts" => []})

    {sid, _, _ws} =
      start_session!(workspace: git_init!(tmp_workspace()), config: %{memory: false})

    assert Client.memory_facts(sid) == :no_facts

    {pid, session} = start_tui(sid)
    type(pid, "/memory")
    press(pid, "enter")

    eventually(fn -> screen_text(pid, session) =~ "the project brief is off" end)
    assert user_state(pid).focus == :command
  end

  defp truecolor_cells(state) do
    {width, height} = {220, 40}
    theme = %{name: :afterglow, depth: :truecolor, mode: :dark, blink: false}
    session = CellSession.new(width, height)
    frame = %Frame{width: width, height: height}
    :ok = CellSession.draw(session, View.render(Map.put(state, :theme, theme), frame))
    CellSession.take_cells(session).cells
  end

  # The cells of every place `text` is drawn.
  defp cells_of(cells, text) do
    for {_row, row} <- Enum.group_by(cells, & &1.row),
        row = Enum.sort_by(row, & &1.col),
        line = Enum.map_join(row, & &1.symbol),
        {at, _} <- :binary.matches(line, text),
        cell <- Enum.slice(row, String.length(binary_part(line, 0, at)), String.length(text)),
        cell.symbol != " ",
        do: cell
  end

  defp rgb({r, g, b}), do: {:rgb, r, g, b}
end
