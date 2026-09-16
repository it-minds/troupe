defmodule Troupe.TUIScrollTest do
  @moduledoc """
  Reading code in the activated pane (Decisions 45–48): the transcript scrolls
  and follows the tail, nothing is clipped, indentation survives, tool output
  can be read in full, subagent transcripts are reachable, and the layout
  leaves the pane the screen.
  """

  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.TUI.{Model, View}

  @big Enum.map_join(1..300, "\n", &"L#{&1} marker")

  # The transcript rows of the pane as drawn: without the title row (its scroll
  # position changes), the border/scrollbar column and the side panel.
  defp pane_rows(pid, session) do
    g = View.pane_geometry(user_state(pid))
    rows = screen(pid, session)

    for y <- (g.left.y + 1)..(g.left.y + g.left.height - 2) do
      rows |> Enum.at(y, "") |> String.slice((g.left.x + 1)..(g.left.x + g.left.width - 2)//1)
    end
  end

  # Decision 45
  test "the pane scrolls: PgUp leaves the tail, the view stays put while the branch works on, End follows again, Home goes to the top, the wheel scrolls" do
    ws = tmp_workspace(%{"big.txt" => @big})

    scripts = %{
      "code-1" => [
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:tool, "ask_user", %{"question" => "more?"}},
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:finish, "done"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read it")
    await_state("code-1", :needs_input, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].pending != [] end)

    press(pid, "1")
    press(pid, "e")
    text = screen_text(pid, session)
    assert text =~ "L300 marker", "following the tail shows the end of the result"
    assert text =~ "⇣ following"
    assert text =~ "QUESTION: more?"
    assert user_state(pid).pane.scroll == :follow

    g_before = View.pane_geometry(user_state(pid))
    press(pid, "page_up")
    g = View.pane_geometry(user_state(pid))
    assert g.offset == g_before.max_off - (g.inner_h - 1), "one page up from the tail"
    text = screen_text(pid, session)
    refute text =~ "L300 marker"
    assert text =~ ~r/↕ \d+–\d+\/\d+/
    assert is_integer(user_state(pid).pane.scroll)
    assert hd(pane_rows(pid, session)) != ""
    before = pane_rows(pid, session)
    scroll = user_state(pid).pane.scroll

    # the branch answers, reads again and finishes: the view does not move
    q = await_event("code-1", :question_asked, 5_000)
    :ok = Troupe.answer(sid, q.data.call_id, "yes")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)
    assert pane_rows(pid, session) == before
    assert user_state(pid).pane.scroll == scroll
    assert screen_text(pid, session) =~ ~r/· \d+ new/

    press(pid, "end")
    text = screen_text(pid, session)
    assert text =~ "⇣ following"
    assert text =~ "L300 marker"
    assert text =~ "finished (finished): done"
    assert user_state(pid).pane.scroll == :follow

    press(pid, "home")
    text = screen_text(pid, session)
    assert text =~ "> read it"
    assert text =~ "✓ read_file big.txt · 300 lines"
    assert text =~ "L1 marker"
    assert user_state(pid).pane.scroll == 0

    press(pid, "end")
    wheel(pid, :up)
    refute screen_text(pid, session) =~ "⇣ following"
    assert is_integer(user_state(pid).pane.scroll)
    wheel(pid, :down)
    assert user_state(pid).pane.scroll == :follow

    # ↑ / ↓ scroll only while nothing is typed
    press(pid, "up")
    assert is_integer(user_state(pid).pane.scroll)
    press(pid, "down")
    assert user_state(pid).pane.scroll == :follow
    type(pid, "hi")
    press(pid, "up")
    assert user_state(pid).pane.scroll == :follow
    assert user_state(pid).win_text == "hi"
  end

  # Decision 45
  test "a line wider than the pane is wrapped and fully visible; nothing is clipped at the bottom" do
    scripts = %{
      "code-1" => [{:text, String.duplicate("x", 400) <> " ZZZ_END"}, {:finish, "said it"}]
    }

    {sid, _, _} = start_session!(scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "say something long")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "ZZZ_END"
    assert text =~ "> say something long"
  end

  # Decision 46
  test "expanded read_file output keeps its indentation, tabs included, and the collapsed head says how much there is" do
    ws = tmp_workspace(%{"a.ex" => "def a do\n    x = 1\n\tt = 2\nend\n"})
    scripts = %{"code-1" => [{:tool, "read_file", %{"path" => "a.ex"}}, {:finish, "ok"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read a.ex")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    text = screen_text(pid, session)

    assert text =~ "✓ read_file a.ex · 5 lines",
           "read_file numbers the empty line after the final newline"

    refute text =~ "x = 1"

    press(pid, "e")
    text = screen_text(pid, session)
    assert text =~ "1 │ def a do", "the line number gets its own gutter"
    assert text =~ "2 │     x = 1", "four spaces of indentation survive"
    assert text =~ "3 │     t = 2", "a tab of indentation becomes four columns"
    refute text =~ "3t = 2"

    press(pid, "e")
    refute screen_text(pid, session) =~ "x = 1"
  end

  # Decision 46
  test "full tool results are kept (not a 300-character slice) and escape sequences are stripped" do
    ws = tmp_workspace(%{"big.txt" => @big})

    scripts = %{
      "code-1" => [
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:tool, "shell", %{"command" => "printf '\\033[32mgreen\\033[0m\\tok\\n'; exit 3"}},
        {:finish, "ok"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    transcript = user_state(pid).model.windows["code-1"].agents["code-1"].transcript

    [{:tool, read}, {:tool, shell}] =
      Enum.filter(transcript, &match?({:tool, %{name: n}} when n != "finish", &1))

    assert length(read.lines) == 300
    assert read.result =~ "L300 marker"
    assert shell.status == :error
    refute shell.result =~ "\e"
    refute shell.result =~ "[32m"
    assert shell.result =~ "green   ok"

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ ~r/✗ shell printf .* · exit 3/
    refute text =~ "\e"
    press(pid, "e")
    assert screen_text(pid, session) =~ "green   ok"
  end

  # Decision 47
  test "←/→ show a subagent's transcript; input still goes to the branch root" do
    ws = tmp_workspace() |> git_init!()

    scripts = %{
      "code-1" => [
        {:tool, "delegate", %{"agent" => "explore", "prompt" => "look around"}},
        {:tool, "ask_user", %{"question" => "next?"}},
        {:finish, "done"}
      ],
      "code-1/explore-1" => [{:tool, "list_files", %{"path" => "."}}, {:finish, "looked around"}]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "investigate then ask")
    await_state("code-1", :needs_input, 15_000)

    eventually(fn ->
      Map.has_key?(user_state(pid).model.windows["code-1"].agents, "code-1/explore-1")
    end)

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "code-1 (code) — Esc back"
    assert text =~ "delegated to code-1/explore-1 (explore)"
    assert text =~ "Agents (←→ to view):"
    assert text =~ "▸ code-1"
    assert text =~ "↳ explore-1 (explore) done"

    press(pid, "right")
    text = screen_text(pid, session)
    assert user_state(pid).pane.agent == "code-1/explore-1"
    assert text =~ "code-1 › explore-1 (explore) — Esc back"
    assert text =~ "> look around"
    assert text =~ "✓ list_files ."
    assert text =~ "finished (finished): looked around"
    assert text =~ "▸   ↳ explore-1"
    assert text =~ "Enter sends to the branch root"

    # cycling wraps around; the root's own view comes back
    press(pid, "right")
    assert user_state(pid).pane.agent == nil
    assert screen_text(pid, session) =~ "code-1 (code) — Esc back"
    press(pid, "left")
    assert user_state(pid).pane.agent == "code-1/explore-1"

    # the observer opens the selected agent directly
    press(pid, "esc")
    type(pid, "observer")
    press(pid, "enter")
    press(pid, "down")
    press(pid, "enter")
    assert user_state(pid).focus == {:window, "code-1"}
    assert user_state(pid).pane.agent == "code-1/explore-1"
    assert screen_text(pid, session) =~ "code-1 › explore-1 (explore) — Esc back"
  end

  # Decision 46
  test "an edit's diff lives on its tool call: shown while the approval waits, then as +/- and, expanded, in full" do
    ws = tmp_workspace(%{"a.txt" => "old\n"})

    scripts = %{
      "code-1" => [
        {:tool, "write_file", %{"path" => "a.txt", "content" => "new\n"}},
        {:finish, "x"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "rewrite a.txt")
    await_state("code-1", :needs_input, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].pending != [] end)

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "APPROVAL: write_file (y allow / n deny / a allow for session)"
    assert text =~ "-old"
    assert text =~ "+new"
    assert text =~ "y/n/a approve"

    press(pid, "y")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)
    text = screen_text(pid, session)
    assert text =~ "✓ write_file a.txt · +1 -1"
    refute text =~ "APPROVAL:"
    refute text =~ "-old"

    press(pid, "e")
    text = screen_text(pid, session)
    assert text =~ "-old"
    assert text =~ "+new"

    # the fold over the log carries the preview and the result, not the server
    m = Model.rebuild(sid, ws, Troupe.events(sid))

    [{:tool, t}] =
      Enum.filter(
        m.windows["code-1"].agents["code-1"].transcript,
        &match?({:tool, %{name: "write_file"}}, &1)
      )

    assert t.preview =~ "+new"
    assert t.summary == "+1 -1"
    assert t.status == :ok
  end

  # Decision 48
  test "with a pane open the strip is a compact tray, clicking the active tile jumps to the latest, and 80x24 works without a side panel" do
    {strip, pane, _status, _cmd} = View.layout(220, 40, true)
    assert strip.height == 8
    assert pane.height == 28
    {strip, pane, _, _} = View.layout(80, 24, true)
    assert strip.height == 4
    assert pane.height == 16
    {strip, nil, _, _} = View.layout(220, 40, false)
    assert strip.height == 36

    ws = tmp_workspace(%{"big.txt" => @big})

    scripts = %{
      "code-1" => [
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:delay, 60_000, {:finish, "never"}}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid, width: 80, height: 24)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read it")

    eventually(fn ->
      match?(
        [_, {:tool, %{status: :ok}} | _],
        get_in(user_state(pid).model.windows, ["code-1", :agents, "code-1", :transcript]) || []
      )
    end)

    click(pid, 5, 2)
    assert user_state(pid).focus == {:window, "code-1"}
    g = View.pane_geometry(user_state(pid))
    assert g.side == nil
    assert g.left.width == 80

    # The tool result reaches the transcript before the agent announces that it
    # is back on the model, and the activity line is drawn from that state: wait
    # for it rather than for the frame that happens to follow the result.
    eventually(fn ->
      get_in(user_state(pid).model.windows, ["code-1", :activity, "code-1"]) == :thinking
    end)

    text = screen_text(pid, session)
    assert text =~ "code-1 (code) — Esc back"
    assert text =~ "✓ read_file big.txt · 300 lines"
    assert text =~ ~r/thinking \(00:\d\d\)/

    press(pid, "e")
    press(pid, "page_up")
    assert is_integer(user_state(pid).pane.scroll)
    click(pid, 5, 2)
    assert user_state(pid).focus == {:window, "code-1"}
    assert user_state(pid).pane.scroll == :follow
  end

  # Decision 45
  test "expanding or collapsing output keeps the entry at the top of the view in place" do
    ws = tmp_workspace(%{"big.txt" => @big, "small.txt" => "one\ntwo\n"})

    # enough text after the big result that the collapsed transcript still needs scrolling
    scripts = %{
      "code-1" => [
        {:tool, "read_file", %{"path" => "small.txt"}},
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:text, Enum.map_join(1..30, "\n", &"paragraph #{&1}")}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    press(pid, "e")
    # scroll so that the second read_file's head is the first visible row
    g = View.pane_geometry(user_state(pid))
    start_of_big = g.heights |> Enum.take(2) |> Enum.sum()
    press(pid, "home")
    for _ <- 1..start_of_big, do: press(pid, "down")
    assert user_state(pid).pane.scroll == start_of_big
    assert hd(pane_rows(pid, session)) =~ "✓ read_file big.txt · 300 lines"

    press(pid, "e")
    assert hd(pane_rows(pid, session)) =~ "✓ read_file big.txt · 300 lines"
    press(pid, "e")
    assert hd(pane_rows(pid, session)) =~ "✓ read_file big.txt · 300 lines"
    assert user_state(pid).pane.scroll == start_of_big
  end

  test "the 'new' counter counts what arrived, not rows the terminal re-wrapped after a resize" do
    ws = tmp_workspace(%{"big.txt" => Enum.map_join(1..300, "\n", &"L#{&1} marker")})

    scripts = %{
      "code-1" => [
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:tool, "ask_user", %{"question" => "go on?"}},
        {:finish, "done"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read it")
    await_state("code-1", :needs_input, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].pending != [] end)

    press(pid, "1")
    press(pid, "e")
    press(pid, "page_up")
    refute screen_text(pid, session) =~ "new"

    # half the width doubles the wrapped rows; nothing has actually arrived
    resize(pid, session, 110, 40)
    assert user_state(pid).size == {110, 40}
    refute screen_text(pid, session) =~ ~r/· \d+ new/

    # an answer produces real new entries, and those are counted
    q = await_event("code-1", :question_asked, 5_000)
    :ok = Troupe.answer(sid, q.data.call_id, "yes")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> screen_text(pid, session) =~ ~r/· \d+ new/ end)
    assert is_integer(user_state(pid).pane.scroll)
  end
end

defmodule Troupe.TUIModelTextTest do
  use ExUnit.Case, async: true

  alias Troupe.UI.TUI.Model

  test "sanitize expands tabs to 4-column stops, strips escape sequences and control bytes, keeps newlines" do
    assert Model.sanitize("  1\tcode") == "  1 code"
    assert Model.sanitize("    1\tdef") == "    1   def"
    assert Model.sanitize("\tx\n\t\ty") == "    x\n        y"
    assert Model.sanitize("\e[32mok\e[0m \e]0;title\a\e[1;31mred\e[m") == "ok red"
    assert Model.sanitize("a\rb\x07c") == "abc"
    assert Model.sanitize("a\rb\tc") == "ab  c", "the tab stop counts what is displayed"
    assert Model.sanitize("\e日本") == "日本"
    assert String.valid?(Model.sanitize("\e日本")), "an escape before a wide character"
    assert String.valid?(Model.sanitize("x\e"))
    assert Model.sanitize("plain\ntext") == "plain\ntext"
  end

  test "cell_width counts wide glyphs as two columns and combining marks as none" do
    assert Model.cell_width("hello") == 5
    assert Model.cell_width("日本") == 4
    assert Model.cell_width("é") == 1
    assert Model.cell_width("✓ ok ⠋") == 6
  end

  test "wrap never trims and breaks prose at spaces, code anywhere" do
    assert Model.wrap("", 10, :char) == [""]
    assert Model.wrap("short", 10, :char) == ["short"]
    assert Model.wrap("abcdef", 4, :char) == ["abcd", "ef"]
    assert Model.wrap("    indented line here", 10, :char) == ["    indent", "ed line he", "re"]
    assert Model.wrap("hello world foo", 8, :word) == ["hello", "world", "foo"]

    assert Model.wrap("averyveryverylongword x", 6, :word) == [
             "averyv",
             "eryver",
             "ylongw",
             "ord x"
           ]

    assert Model.wrap("日本語テキスト", 4, :char) == ["日本", "語テ", "キス", "ト"]
    assert Model.height("x", 5, :char) == 1
    assert Model.height(String.duplicate("x", 12), 5, :char) == 3
    assert Model.wrap("abcd ", 4, :word) == ["abcd"]
    assert Model.wrap(" abcdef", 4, :word) == [" abc", "def"]
    assert Model.wrap("ab  cd ef", 4, :word) == ["ab ", "cd", "ef"]
  end

  test "the ASCII fast path wraps exactly like the grapheme path" do
    # the same text with one non-ASCII grapheme appended takes the slow path; rows must agree
    samples = [
      "hello world foo bar",
      "  indented    text with   gaps ",
      "averyveryverylongword then short words here",
      "a b c d e f g h i j k l m n o p",
      "trailing space at boundary ",
      "x" <> String.duplicate(" ", 12) <> "y",
      String.duplicate("lorem ipsum dolor sit amet ", 40)
    ]

    for text <- samples, width <- [3, 4, 7, 10, 33], mode <- [:char, :word] do
      fast = Model.wrap(text, width, mode)
      slow = Model.wrap(text <> "é", width, mode)
      # the slow path ends with the extra grapheme; compare everything before it
      slow_text = slow |> Enum.join() |> String.replace_suffix("é", "")

      assert Enum.join(fast) |> String.replace(" ", "") == slow_text |> String.replace(" ", ""),
             "content differs for #{inspect(text)} at #{width} #{mode}"

      assert Enum.all?(fast, &(Model.cell_width(&1) <= width))
      assert fast != []
    end

    # exact equality where the extra grapheme cannot change the row structure
    for text <- samples, width <- [4, 7, 10], mode <- [:char, :word] do
      slow = Model.wrap(text <> String.duplicate(" ", width) <> "é", width, mode)
      fast = Model.wrap(text <> String.duplicate(" ", width) <> "e", width, mode)

      assert length(slow) == length(fast),
             "row count differs for #{inspect(text)} at #{width} #{mode}"
    end
  end

  defp texts(rows), do: Enum.map(rows, &Model.line_text/1)

  test "rows materialises only the visible slice and tail_rows the last rows" do
    lines = [{:text, "aaaa bbbb"}, {:text, "cccccccc"}, {:text, "d"}]
    assert Model.row_count(lines, 4) == 5
    assert texts(Model.rows(lines, 4, 0, 2)) == ["aaaa", "bbbb"]
    assert texts(Model.rows(lines, 4, 1, 2)) == ["bbbb", "cccc"]
    assert texts(Model.rows(lines, 4, 4, 10)) == ["d"]
    assert texts(Model.tail_rows(lines, 4, 2)) == ["cccc", "d"]
    assert Model.rows(lines, 4, 99, 3) == []
  end

  test "a line kind's rail is drawn on every row it wraps onto" do
    # tool output is railed with two spaces, so 4 of 6 columns are left for it
    lines = [{:body, "abcdefgh"}, {:text, "abcdefgh"}]
    assert Model.row_count(lines, 6) == 4
    assert texts(Model.rows(lines, 6, 0, 2)) == ["  abcd", "  efgh"]
    assert texts(Model.rows(lines, 6, 2, 2)) == ["abcdef", "gh"]

    # a bullet hangs: the marker on the first row, its width on the rest
    [first, second] = Model.rows([{:bullet, [{:bullet_marker, "• "}, {:text, "one two"}]}], 6, 0, 2)
    assert Model.line_text(first) == "• one"
    assert Model.line_text(second) == "  two"
  end

  test "tail_rows measures only the lines it shows" do
    lines = List.duplicate({:text, String.duplicate("x", 400)}, 5_000) ++ [{:text, "last"}]
    {us, rows} = :timer.tc(fn -> Model.tail_rows(lines, 80, 3) end)
    assert Model.line_text(List.last(rows)) == "last"
    assert length(rows) == 3
    assert us < 50_000, "tail_rows walked the whole transcript (#{us}us)"
  end
end

defmodule Troupe.TUIPaneRegressionTest do
  @moduledoc "Regressions found reviewing Decisions 45-48."

  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.UI.TUI.{Model, View}

  test "a window dismissed from outside the pane returns focus to the command line instead of crashing it" do
    scripts = %{"code-1" => [{:finish, "done"}]}
    {sid, _, _} = start_session!(scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "quick one")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    assert user_state(pid).focus == {:window, "code-1"}

    :ok = Troupe.dismiss(sid, "code-1")
    eventually(fn -> user_state(pid).model.windows == %{} end)

    press(pid, "right")
    press(pid, "page_up")
    press(pid, "e")
    assert Process.alive?(pid)
    assert user_state(pid).focus == :command
    assert screen_text(pid, session) =~ "No branches."
  end

  test "clicking on the observer or the settings page does not activate an invisible tile" do
    scripts = %{"code-1" => [{:delay, 60_000, {:finish, "never"}}]}
    {sid, _, _} = start_session!(scripts: scripts)
    {pid, _session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "long one")
    eventually(fn -> user_state(pid).model.windows["code-1"] end)

    type(pid, "observer")
    press(pid, "enter")
    assert user_state(pid).focus == :observer
    click(pid, 5, 3)
    assert user_state(pid).focus == :observer

    press(pid, "esc")
    type(pid, "settings")
    press(pid, "enter")
    assert user_state(pid).focus == :settings
    click(pid, 5, 3)
    assert user_state(pid).focus == :settings
  end

  test "a branch told to carry on is no longer shown as done" do
    scripts = %{"code-1" => [{:finish, "first pass"}, {:delay, 60_000, {:finish, "never"}}]}
    {sid, _, _} = start_session!(scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "do it")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    :ok = Troupe.send_input(sid, "code-1", "keep going")
    await_state("code-1", :running, 15_000)

    eventually(fn ->
      {:user, "keep going"} in user_state(pid).model.windows["code-1"].agents["code-1"].transcript
    end)

    w = user_state(pid).model.windows["code-1"]
    row = %{window: w, path: "code-1", agent: w.agents["code-1"], depth: 0, root?: true}
    refute Model.agent_state(row) == :done
    assert Model.activity_line(w, "code-1", 0, w.started_at + 1_000)
    assert screen_text(pid, session) =~ "> keep going"
  end

  test "a pending approval taller than the pane opens at its header, not its last rows" do
    ws = tmp_workspace(%{"big.ex" => Enum.map_join(1..80, "\n", &"line #{&1}")})

    scripts = %{
      "code-1" => [
        {:tool, "edit_file",
         %{
           "path" => "big.ex",
           "old_string" => "line 3\nline 4",
           "new_string" => "line three\nline four"
         }},
        {:finish, "x"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts)
    {pid, session} = start_tui(sid, width: 80, height: 24)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "edit it")
    await_state("code-1", :needs_input, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].pending != [] end)

    click(pid, 5, 1)
    assert user_state(pid).focus == {:window, "code-1"}
    text = screen_text(pid, session)
    assert text =~ "APPROVAL: edit_file", "the header says what is being approved"
    assert text =~ "--- big.ex", "and the diff header says which file"
    assert text =~ "-line 3"
    assert text =~ "+line three"
    assert text =~ "@@", "the unchanged middle is summarised"

    # the tail of an unchanged file is not printed after the change
    refute text =~ "line 80"
    g = View.pane_geometry(user_state(pid))
    assert g.follow?, "still following, so new output keeps arriving in view"
  end

  test "at 80 columns the pane still says how to get back to the tail" do
    ws = tmp_workspace(%{"big.txt" => Enum.map_join(1..300, "\n", &"L#{&1}")})
    scripts = %{"code-1" => [{:tool, "read_file", %{"path" => "big.txt"}}, {:finish, "ok"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid, width: 80, height: 24)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read it")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    press(pid, "e")
    press(pid, "page_up")
    text = screen_text(pid, session)
    assert text =~ "End", "the key that follows the tail again is named"
    assert text =~ "PgUp/PgDn"
    hint = text |> String.split("\n") |> Enum.find("", &String.contains?(&1, "PgUp/PgDn"))
    assert Model.cell_width(hint) <= 80, "the hint fits the terminal"
  end
end

defmodule Troupe.TUIRichTextTest do
  @moduledoc "Decision 52: the transcript is rendered, not dumped."

  use ExUnit.Case, async: true

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.CellSession
  alias Troupe.UI.TUI.Model

  @source """
  defmodule Auth do
    def sign_in(user, password) do
      {:error, :invalid_credentials}
    end
  end
  """

  @reply """
  ## What I found

  It returns `{:error, :invalid_credentials}` but the test wants **another atom**.

  - `lib/auth.ex` is the only place
  - nothing else matches on it

  ```elixir
  def sign_in(user, password) do
    {:error, :bad_credentials}
  end
  ```

  > Safe: the atom never leaves the process.

  ---
  """

  defp styles_at(session, row, text) do
    snap = CellSession.take_cells(session)
    cells = snap.cells |> Enum.filter(&(&1.row == row)) |> Enum.sort_by(& &1.col)
    line = Enum.map_join(cells, "", & &1.symbol)

    case :binary.match(line, text) do
      {col, len} -> cells |> Enum.slice(col, len) |> Enum.map(&{&1.fg, &1.modifiers})
      :nomatch -> nil
    end
  end

  defp row_of(pid, session, text) do
    pid
    |> screen(session)
    |> Enum.find_index(&String.contains?(&1, text))
  end

  test "markdown in an assistant message: headings, bullets, quotes, rules, inline code and bold" do
    lines = Model.markdown(@reply)
    kinds = lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    assert :heading in kinds
    assert :bullet in kinds
    assert :quote in kinds
    assert :rule in kinds
    assert :code_head in kinds
    assert :code in kinds
    assert :code_tail in kinds

    # the markers are dropped, so a row is as wide as what it shows
    texts = Enum.map(lines, &Model.line_text/1)
    assert "## What I found" in texts, "the heading level stays visible"
    assert "• lib/auth.ex is the only place" in texts
    refute Enum.any?(texts, &String.contains?(&1, "`"))
    refute Enum.any?(texts, &String.contains?(&1, "**"))
    refute Enum.any?(texts, &String.contains?(&1, "```"))

    # inline code and bold become their own segments
    prose = Enum.find(lines, &String.contains?(Model.line_text(&1), "but the test wants"))
    tags = prose |> Model.segments() |> Enum.map(&elem(&1, 0))
    assert :code_inline in tags
    assert :strong in tags
  end

  test "a fenced code block is highlighted, railed and labelled with its language" do
    scripts = %{"code-1" => [{:text, @reply}, {:finish, "explained"}]}
    {sid, _, _} = start_session!(scripts: scripts)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "why does it fail?")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    text = screen_text(pid, session)
    assert text =~ "┌─ elixir ", "the block says what language it is"
    assert text =~ "│ def sign_in(user, password) do", "code sits behind a rail"
    assert text =~ "└─"

    # `def` is a keyword, so it is not drawn in the default colour
    row = row_of(pid, session, "def sign_in(user, password) do")
    [{fg, _} | _] = styles_at(session, row, "def")
    assert match?({:rgb, _, _, _}, fg), "syntax highlighting reached the screen"

    keyword = styles_at(session, row, "def")
    name = styles_at(session, row, "sign_in")
    assert keyword != name, "a keyword and a function name are drawn differently"
  end

  test "a file read shows numbered, highlighted source" do
    ws = tmp_workspace(%{"lib/auth.ex" => @source})
    scripts = %{"code-1" => [{:tool, "read_file", %{"path" => "lib/auth.ex"}}, {:finish, "read"}]}
    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read it")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    press(pid, "e")
    text = screen_text(pid, session)
    assert text =~ "1 │ defmodule Auth do"
    assert text =~ "2 │   def sign_in(user, password) do", "indentation is kept"
    assert text =~ "3 │     {:error, :invalid_credentials}"

    row = row_of(pid, session, "defmodule Auth do")
    [{number_fg, _} | _] = styles_at(session, row, "1 │")
    assert number_fg == :dark_gray, "the line number gutter stays out of the way"
    [{fg, _} | _] = styles_at(session, row, "defmodule")
    assert match?({:rgb, _, _, _}, fg)
  end

  test "output that is not code is left alone, and a body too big to highlight still renders" do
    big = Enum.map_join(1..600, "\n", &"line #{&1} of output")
    ws = tmp_workspace(%{"big.txt" => big})

    scripts = %{
      "code-1" => [
        {:tool, "shell", %{"command" => "echo plain"}},
        {:tool, "read_file", %{"path" => "big.txt"}},
        {:finish, "done"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "go")
    await_state("code-1", :done_unread, 15_000)
    eventually(fn -> user_state(pid).model.windows["code-1"].state == :done_unread end)

    press(pid, "1")
    press(pid, "e")
    press(pid, "home")
    assert screen_text(pid, session) =~ "plain"

    press(pid, "end")
    text = screen_text(pid, session)
    assert text =~ "600 │ line 600 of output", "past the highlighting cap it is still numbered"
  end

  test "text still streaming is shown plain and becomes markdown when the message lands" do
    {sid, _, _} = start_session!(scripts: %{"code-1" => [{:delay, 60_000, {:finish, "never"}}]})
    {pid, session} = start_tui(sid)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "write something")
    eventually(fn -> user_state(pid).model.windows["code-1"] end)

    Troupe.Events.notify(sid, "code-1", :llm_delta, %{
      text: "## Heading\n- one\n",
      purpose: :thinking
    })

    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "## Heading" end)
    assert screen_text(pid, session) =~ "- one", "a delta is not reflowed mid-flight"
  end
end
