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

    # A box's line (troupe #929): the keys it is typed with stay, and a note that names
    # no key goes before any key.
    test "a note that names no key goes before a key, and Tab and Ctrl- keys act" do
      shell =
        " shell — runs in the session's workspace · no stdin · cd does not carry over · !! keeps it from the agent "

      assert KeyLine.fit(shell, 78) ==
               {" runs in the session's workspace · no stdin · !! keeps it from the agent ",
                "cd does not carry over"}

      plain =
        " Enter starts build in the checkout · Ctrl-N chooses agent and worktree · / commands "

      assert KeyLine.fit(plain, 78) ==
               {" Enter starts build in the checkout · Ctrl-N chooses agent and worktree ",
                "/ commands"}

      # A spare key goes before Tab or Ctrl-; Enter and Esc stay longest.
      line = " box — Enter sends · Tab completes · x drops · Ctrl-J new line · Esc back "

      assert KeyLine.fit(line, 60) ==
               {" Enter sends · Tab completes · Ctrl-J new line · Esc back ", "x drops"}
    end

    test "a line with no keys to spare is left to the border" do
      title = " → lib/a/very/long/path/to/a/file.ex (Enter sends, Esc back) "
      assert KeyLine.fit(title, 20) == {title, nil}
    end
  end

  # The boxes typed in (troupe #929): at 80 columns the command line and the palette keep
  # every key they are typed with on their border, and what the command line's still
  # gives up is on the box's last row while what is typed leaves it free.
  describe "a box's key line at 80 columns" do
    setup do
      {sid, _, _ws} = start_session!(script: [])
      %{sid: sid}
    end

    defp border(rows, word), do: Enum.find(rows, &(&1 =~ "┌" and &1 =~ word))

    defp ready(pid) do
      eventually(fn -> user_state(pid).commands != [] end)
      eventually(fn -> Troupe.UI.TUI.Model.session_window(user_state(pid).model) != nil end)
    end

    test "the command line keeps Enter and Ctrl-N, and shows / commands in the box", %{sid: sid} do
      {pid, session} = start_tui(sid, width: 80)
      ready(pid)

      rows = screen(pid, session)
      line = border(rows, "Enter starts")
      assert line, "no border says Enter starts at 80 columns:\n" <> Enum.join(rows, "\n")
      assert line =~ "Enter starts build in the checkout"
      assert line =~ "Ctrl-N chooses agent and worktree"
      assert Enum.any?(rows, &(&1 =~ "also / commands"))

      # A line long enough to need the row takes it back.
      type(pid, String.duplicate("word ", 70))
      refute screen_text(pid, session) =~ "also / commands"
    end

    test "an agent chosen keeps Enter and Esc, the note giving way first", %{sid: sid} do
      {pid, session} = start_tui(sid, width: 80)
      ready(pid)
      press(pid, "n", ["ctrl"])
      press(pid, "enter")
      press(pid, "c")

      line = border(screen(pid, session), "Esc forgets")
      assert line =~ "Enter starts build in the checkout · Esc forgets the choice"
    end

    test "the palette keeps every key it is typed with", %{sid: sid} do
      {pid, session} = start_tui(sid, width: 80)
      ready(pid)
      eventually(fn -> user_state(pid).commands != [] end)
      press(pid, "/")
      assert user_state(pid).focus == :palette

      line = border(screen(pid, session), "Enter runs")
      assert line, "no border says Enter runs at 80 columns"

      for key <- ["type to filter", "↑↓ move", "Enter runs", "Tab puts it on the line", "Esc back"],
          do: assert(line =~ key, "#{key} left the palette's line: #{line}")
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
