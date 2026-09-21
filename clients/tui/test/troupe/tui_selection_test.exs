defmodule Troupe.TUISelectionTest do
  @moduledoc """
  Mouse text selection in the activated pane (Decision 82): mouse reporting takes
  the terminal's own click-and-drag away, so Troupe owns a selection — dragging
  highlights, releasing copies, and `Ctrl-Y` copies the selection when there is
  one and the whole transcript when there is not.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.Layout.Rect
  alias Troupe.UI.TUI.{Model, View}

  ## Pure functions

  describe "Model.row_slice/3 and split_row/3" do
    test "slices a wrapped row by cell column and drops rails and gutters" do
      row = {:code, [{:code_rail, "│ "}, {:text, "hello "}, {:code_inline, "world"}]}

      assert Model.row_slice(row, 0, :end) == "hello world"
      assert Model.row_slice(row, 2, 7) == "hello"
      assert Model.row_slice(row, 3, :end) == "ello world"
      assert Model.row_slice(row, 8, 11) == "wor"
      assert Model.row_slice(row, 0, 0) == ""
      assert Model.row_slice(row, 5, 3) == ""
      assert Model.row_slice(row, 99, :end) == ""
    end

    test "keeps every segment's tag, and the three pieces reassemble into the row" do
      row = {:body, [{:gutter, "  "}, {:strong, "bold"}, {:text, "plain"}]}
      {pre, inside, post} = Model.split_row(row, 4, 8)

      assert pre == [{:gutter, "  "}, {:strong, "bo"}]
      assert inside == [{:strong, "ld"}, {:text, "pl"}]
      assert post == [{:text, "ain"}]
      assert Model.line_text(pre ++ inside ++ post) == Model.line_text(row)
    end

    test "never cuts a wide glyph in half" do
      row = {:body, [{:gutter, "  "}, {:text, "日本語テキスト"}]}

      assert Model.row_slice(row, 2, 6) == "日本"
      # Column 3 is the trailing half of 日: the glyph belongs to the piece with room.
      assert Model.row_slice(row, 3, 6) == "日"
      assert Model.row_slice(row, 2, 3) == ""

      {pre, inside, post} = Model.split_row(row, 4, :end)
      assert Model.line_text(pre ++ inside ++ post) == Model.line_text(row)
    end

    test "a slice is never wider than the span asked for, and is a substring of the railless row" do
      row =
        {:code,
         [
           {:code_rail, "│ "},
           {:linenum, "   12"},
           {:text, "def héllo(x)"},
           {:code_inline, "日本"}
         ]}

      bare = "def héllo(x)日本"

      for from <- 0..20, span <- 0..8 do
        slice = Model.row_slice(row, from, from + span)
        assert Model.cell_width(slice) <= span
        assert slice == "" or String.contains?(bare, slice)
      end
    end
  end

  describe "View.pane_point/3 and pane_edge/2" do
    test "maps a screen cell to an absolute transcript row and a cell column" do
      g = %{left: %Rect{x: 4, y: 3, width: 40, height: 12}, inner_w: 38, inner_h: 10, offset: 100}

      assert View.pane_point(g, 5, 4) == {100, 0}
      assert View.pane_point(g, 9, 6) == {102, 4}
      # The interior only: borders are outside, and so is the scrollbar column.
      assert View.pane_point(g, 4, 4) == nil
      assert View.pane_point(g, 5, 3) == nil
      assert View.pane_point(g, 43, 4) == nil
      assert View.pane_point(g, 42, 4) == {100, 37}
      assert View.pane_point(g, 5, 14) == nil
      assert View.pane_point(g, 5, 13) == {109, 0}
    end

    test "says which way a drag off the edge wants to scroll" do
      g = %{left: %Rect{x: 4, y: 3, width: 40, height: 12}, inner_w: 38, inner_h: 10, offset: 0}

      assert View.pane_edge(g, 3) == :above
      assert View.pane_edge(g, 0) == :above
      assert View.pane_edge(g, 4) == nil
      assert View.pane_edge(g, 13) == nil
      assert View.pane_edge(g, 14) == :below
    end
  end

  ## The pane

  @reply """
  Here is what I found:

  ```
  SEL_ONE_LINE
  SEL_TWO_LINE
  ```
  """

  # Where a string sits on the drawn screen: `{x, y, length}` in *cells*, since a
  # row's rail glyphs are multi-byte and byte offsets are not columns.
  defp locate(pid, session, needle) do
    rows = screen(pid, session)

    y =
      Enum.find_index(rows, &String.contains?(&1, needle)) ||
        flunk("#{needle} is not on screen:\n#{Enum.join(rows, "\n")}")

    [prefix | _] = String.split(Enum.at(rows, y), needle, parts: 2)
    {Model.cell_width(prefix), y, Model.cell_width(needle)}
  end

  defp open_pane(context_reply \\ @reply) do
    ws = tmp_workspace()
    {sid, _, _} = start_session!(workspace: ws, script: [{:text, context_reply}, {:finish, "done"}])
    say!(sid, "do the thing")
    await_done()

    {pid, session} = start_tui(sid)
    press(pid, "1")
    eventually(fn -> match?({:window, "root"}, user_state(pid).focus) end)
    {pid, session}
  end

  test "dragging across part of one line copies exactly that substring" do
    path = clipboard_path()
    {pid, session} = open_pane()

    {x, y, _len} = locate(pid, session, "SEL_ONE_LINE")
    drag(pid, {x, y}, {x + 6, y})

    assert File.read!(path) == "SEL_ONE"
    assert screen_text(pid, session) =~ "copied 7 chars from the selection"
  end

  test "a multi-row drag copies the rows joined with a newline and without rails" do
    path = clipboard_path()
    {pid, session} = open_pane()

    {x1, y1, _} = locate(pid, session, "SEL_ONE_LINE")
    {x2, y2, len} = locate(pid, session, "SEL_TWO_LINE")
    drag(pid, {x1, y1}, {x2 + len - 1, y2})

    assert File.read!(path) == "SEL_ONE_LINE\nSEL_TWO_LINE"
    refute File.read!(path) =~ "│"
  end

  test "a drag backwards selects the same text as the same drag forwards" do
    path = clipboard_path()
    {pid, session} = open_pane()

    {x, y, len} = locate(pid, session, "SEL_TWO_LINE")
    drag(pid, {x + len - 1, y}, {x, y})

    assert File.read!(path) == "SEL_TWO_LINE"
  end

  test "a plain click selects nothing, copies nothing and leaves the pane following" do
    path = clipboard_path()
    {pid, session} = open_pane()

    {x, y, _} = locate(pid, session, "SEL_ONE_LINE")
    click(pid, x, y)
    mouse_up(pid, x, y)

    assert user_state(pid).selection == nil
    assert user_state(pid).pane.scroll == :follow
    refute File.exists?(path)
  end

  test "Ctrl-Y copies the selection when there is one and the whole transcript when there is not" do
    path = clipboard_path()
    {pid, session} = open_pane()

    # No selection: the whole transcript, as Decision 68 has it.
    press(pid, "y", ["ctrl"])
    whole = File.read!(path)
    assert whole =~ "do the thing"
    assert whole =~ "SEL_ONE_LINE"
    assert whole =~ "SEL_TWO_LINE"

    {x, y, _} = locate(pid, session, "SEL_TWO_LINE")
    drag(pid, {x, y}, {x + 6, y})
    File.rm!(path)

    press(pid, "y", ["ctrl"])
    assert File.read!(path) == "SEL_TWO"
  end

  test "the selected cells are drawn reversed and the rest of the row is not" do
    {pid, session} = open_pane()
    {x, y, _} = locate(pid, session, "SEL_ONE_LINE")
    drag(pid, {x, y}, {x + 6, y})

    cells =
      pid
      |> screen_cells(session)
      |> Enum.filter(fn {row, _col, _symbol, _mods} -> row == y end)
      |> Map.new(fn {_row, col, symbol, mods} -> {col, {symbol, mods}} end)

    for col <- x..(x + 6) do
      assert {_symbol, mods} = Map.fetch!(cells, col)
      assert :reversed in mods, "column #{col} of the selection should be reversed"
    end

    assert {"_", mods} = Map.fetch!(cells, x + 7)
    refute :reversed in mods
  end

  test "Esc clears a selection before it leaves the window, and a resize drops one" do
    {pid, session} = open_pane()
    {x, y, _} = locate(pid, session, "SEL_ONE_LINE")

    drag(pid, {x, y}, {x + 6, y})
    assert user_state(pid).selection
    assert screen_text(pid, session) =~ "Ctrl-Y copies the selection"

    press(pid, "esc")
    assert user_state(pid).selection == nil
    assert user_state(pid).focus == {:window, "root"}

    press(pid, "esc")
    assert user_state(pid).focus == :command

    press(pid, "1")
    {x, y, _} = locate(pid, session, "SEL_ONE_LINE")
    drag(pid, {x, y}, {x + 6, y})
    assert user_state(pid).selection

    resize(pid, session, 150, 30)
    assert user_state(pid).selection == nil
  end

  test "dragging below the pane scrolls, so a selection can grow past the viewport" do
    big = "```\n" <> Enum.map_join(1..200, "\n", &"L#{&1} marker") <> "\n```"
    {pid, _session} = open_pane(big)

    g = View.pane_geometry(user_state(pid))
    press(pid, "home")
    offset = View.pane_geometry(user_state(pid)).offset

    click(pid, g.left.x + 1, g.left.y + 1)
    drag_to(pid, {g.left.x + 5, g.left.y + g.left.height + 2})

    after_g = View.pane_geometry(user_state(pid))
    assert after_g.offset > offset, "a drag past the bottom row scrolls the pane"
    {_row, _col} = user_state(pid).selection.cursor
    assert user_state(pid).selection.anchor == {offset, 0}
  end
end
