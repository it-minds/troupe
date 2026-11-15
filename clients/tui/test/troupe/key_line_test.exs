defmodule Troupe.KeyLineTest do
  @moduledoc """
  A page's key line fits the terminal (#894). It is drawn on the command box's top border,
  and at 80 columns the end of `/new`'s, `/memory`'s and `/artifacts`' was cut, the way out
  with it. `Troupe.UI.TUI.KeyLine` keeps a line whole where it fits; where it does not, the
  label goes, then the keys from the end, never `Esc …` and `Enter …` while there is room
  for them, and the keys that left are shown in the box under the line. Held here on its
  own and on `/new`'s screen at 80 and 120 columns; `/memory`'s and `/artifacts`' are held
  in their own screen tests.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.TUI.KeyLine

  doctest KeyLine

  @memory " memory — ←/→ level · ↑↓ · Enter reads · a add · e edit · f forget · h versions · b who wrote it · s status · Esc back "

  describe "fit/2" do
    test "a line that fits is left alone" do
      assert KeyLine.fit(@memory, String.length(@memory)) == {@memory, nil}
    end

    test "the label goes first, then the keys from the end; the way out and what acts stay" do
      assert KeyLine.fit(@memory, 105) ==
               {" ←/→ level · ↑↓ · Enter reads · a add · e edit · f forget · h versions · b who wrote it · Esc back ",
                "s status"}

      {line, more} = KeyLine.fit(@memory, 78)
      assert String.length(line) <= 78
      assert line == " ←/→ level · ↑↓ · Enter reads · a add · e edit · f forget · Esc back "
      assert more == "h versions · b who wrote it · s status"
    end

    test "what left the line is in the line's order, so nothing is lost" do
      keys =
        @memory
        |> String.trim()
        |> String.split(" — ", parts: 2)
        |> List.last()
        |> String.split(" · ")

      for width <- 12..130 do
        {line, more} = KeyLine.fit(@memory, width)
        assert line =~ "Esc back", "#{width} columns lost the way out: #{inspect(line)}"
        if String.length(@memory) > width, do: assert(String.length(line) <= width)

        on_line = line |> String.trim() |> String.split(" — ") |> List.last() |> String.split(" · ")
        below = String.split(more || "", " · ", trim: true)

        assert Enum.sort(on_line ++ below) == Enum.sort(keys),
               "#{width} columns: #{inspect({line, more})}"

        # Below the line they keep the line's order.
        assert below == Enum.filter(keys, &(&1 in below))
      end
    end

    test "narrower than what acts, only the way out stays on the line" do
      assert {" Esc back ", more} = KeyLine.fit(@memory, 12)
      assert more =~ "Enter reads"
      assert more =~ "←/→ level"
    end

    test "a line with no keys to spare is left to the border" do
      title = " → lib/a/very/long/path/to/a/file.ex (Enter sends, Esc back) "
      assert KeyLine.fit(title, 20) == {title, nil}
    end
  end

  describe "/new's key line" do
    setup do
      {sid, _, _ws} = start_session!(script: [])
      %{sid: sid}
    end

    for width <- [80, 120] do
      test "keeps Enter and Esc at #{width} columns, the rest in the box under it", %{sid: sid} do
        {pid, session} = start_tui(sid, width: unquote(width))
        type(pid, "/new")
        press(pid, "enter")
        eventually(fn -> user_state(pid).focus == :new_session end)

        rows = screen(pid, session)
        line = Enum.find(rows, &(&1 =~ "Esc closes"))

        assert line,
               "no row says Esc closes at #{unquote(width)} columns:\n" <> Enum.join(rows, "\n")

        assert line =~ "Enter starts"
        assert line =~ "Tab the settings, then ←→ and Enter"

        text = Enum.join(rows, "\n")

        for key <- ["Ctrl-J new line", "Tab to the recents"],
            do: assert(text =~ key, "#{key} is not on the screen at #{unquote(width)} columns")
      end
    end
  end
end
