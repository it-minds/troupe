defmodule Troupe.FramesTest do
  @moduledoc """
  Frames for rendered output (issue #474, TUI Decision 161, `docs/design/frames.md`): a
  turn shows its answer on the rendered surface and its working as one strip above it,
  `transcript.detail` and `e` open what quiet keeps shut, what waits on a person or failed
  is never shut, and a curtain line says what runs while the turn works.

  Most of it is drawn from a fold, the way a replay draws it, at a fixed size and colour
  depth; the last tests drive the TUI against the daemon's scripted model.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.{CellSession, Frame}
  alias Troupe.Client
  alias Troupe.Client.Message
  alias Troupe.Event
  alias Troupe.UI.Headless.Printer
  alias Troupe.UI.TUI.{Model, Theme, View}

  @answer """
  ## Fixed

  The parser keeps the last line now.

  | file | change |
  |---|---:|
  | lib/p.ex | +1 −1 |

  - checked the parser
    - and its test

  ```elixir
  def parse(x), do: x
  ```
  """

  ## A turn, folded

  defp event(type, data, ts, opts \\ []) do
    %Event{
      session_id: "s-1",
      agent_path: Keyword.get(opts, :path, "root"),
      type: type,
      data: data,
      ts: ts,
      transient?: Keyword.get(opts, :transient?, false)
    }
  end

  defp opened do
    [
      event(:branch_spawned, %{name: "build", isolation: :shared, prompt: ""}, 0),
      event(:input, %{source: :user, content: "fix the failing test"}, 0)
    ]
  end

  # A turn with what #474 is about: reasoning, prose between calls, four calls of which
  # one failed, and an answer with a table, a nested list and a fenced block.
  defp turn do
    opened() ++
      [
        event(:agent_state, %{to: :thinking}, 0, transient?: true),
        event(:llm_delta, %{text: "I should look at parse.", reasoning: true}, 1_000,
          transient?: true
        ),
        event(
          :assistant_message,
          %{
            content: [
              Message.text_block("Let me look at the parser."),
              Message.tool_use("c1", "grep", %{"pattern" => "parse", "path" => "lib"}),
              Message.tool_use("c2", "read_file", %{"path" => "lib/p.ex"}),
              Message.tool_use("c3", "read_file", %{"path" => "nope"}),
              Message.tool_use("c4", "shell", %{"command" => "mix test"})
            ]
          },
          13_000
        ),
        done("c1", true, "lib/p.ex:2:  def parse(x), do: nil", 14_000),
        done("c2", true, "1\tdefmodule P do\n2\t  def parse(x), do: nil\n3\tend", 15_000),
        done("c3", false, "no such file: nope\n(check the path)", 15_500),
        done("c4", true, "1 test, 0 failures", 20_000),
        event(:assistant_message, %{content: [Message.text_block(@answer)]}, 21_000),
        event(:agent_state, %{to: :idle, turn: turn_cost()}, 21_500)
      ]
  end

  defp done(id, ok?, content, ts),
    do: event(:tool_call_completed, %{call_id: id, ok: ok?, content: content}, ts)

  defp turn_cost,
    do: %{
      calls: 2,
      usage: %{input: 300, output: 120, cache_read: 0, cache_write: 0},
      cost_micros: 0,
      unpriced: 2
    }

  defp fold(events), do: Model.rebuild("s-1", "/w", events)

  ## Drawn

  defp draw(model, opts \\ []) do
    {width, height} = Keyword.get(opts, :size, {120, 60})

    state = %{
      session_id: "s-1",
      workspace: "/w",
      model: model,
      focus: {:window, "root"},
      cmd_text: "",
      cmd_pos: 0,
      win_text: "",
      win_pos: 0,
      agents: ["build"],
      commands: [],
      palette: nil,
      tick: 0,
      now: Keyword.get(opts, :now, 30_000),
      quit_armed: false,
      win_armed: nil,
      # What a screen had before levels, so the reproduction draws on the chunk's tip too.
      expanded: false,
      detail: Keyword.get(opts, :detail, :quiet),
      pane: %{
        agent: nil,
        scroll: :follow,
        seen_entries: 0,
        open: MapSet.new(Keyword.get(opts, :open, []))
      },
      selection: nil,
      answer: nil,
      size: {width, height},
      theme: Keyword.get(opts, :theme, %{depth: :truecolor, mode: :dark})
    }

    session = CellSession.new(width, height)
    :ok = CellSession.draw(session, View.render(state, %Frame{width: width, height: height}))
    CellSession.take_cells(session).cells
  end

  # The pane's rows as text, the borders left out, trailing blanks trimmed.
  defp rows(cells) do
    cells
    |> Enum.group_by(& &1.row)
    |> Enum.sort()
    |> Enum.map(fn {_row, cs} ->
      cs |> Enum.sort_by(& &1.col) |> Enum.map_join("", & &1.symbol) |> String.trim_trailing()
    end)
  end

  defp text(cells), do: cells |> rows() |> Enum.join("\n")

  # The cells of the first row of the pane holding `text`, in column order: the tray of
  # tiles above it (rows 0 to 2) and the pane's border (row 3) left out.
  defp row_of(cells, text) do
    cells
    |> Enum.filter(&(&1.row > 3))
    |> Enum.group_by(& &1.row)
    |> Enum.sort()
    |> Enum.map(fn {_row, cs} -> Enum.sort_by(cs, & &1.col) end)
    |> Enum.find(fn cs -> Enum.map_join(cs, "", & &1.symbol) =~ text end) ||
      flunk("no row holds #{inspect(text)}:\n#{text(cells)}")
  end

  defp surface(depth \\ :truecolor), do: Theme.color(:surface, %{depth: depth, mode: :dark})

  # The transcript's interior on a row at 120 columns: the side box takes the right 30,
  # and the surface stops at the column before the scrollbar's, the pane's last inside.
  defp inside(row), do: Enum.filter(row, &(&1.col in 1..87))

  ## The reproduction

  # On the chunk's tip every call drew its own line and its output, reasoning had a line
  # of its own, there was no strip, and the answer sat on the terminal's own background
  # like every other line.
  test "quiet, the default: the working is one strip above the answer, which is on the surface" do
    cells = draw(fold(turn()))
    screen = text(cells)

    assert screen =~ "▸ 4 steps · 1 failed · grep, read_file, shell · 7s"
    refute screen =~ "✓ grep"
    refute screen =~ "✓ shell"
    refute screen =~ "thinking"
    refute screen =~ "Let me look at the parser."

    # The failed call is open, its error in view.
    assert screen =~ "✗ read_file nope · no such file: nope"
    assert screen =~ "▎ no such file: nope"

    # The strip is above the answer, and the answer is on the surface out to the edge.
    lines = rows(cells)
    strip = Enum.find_index(lines, &(&1 =~ "4 steps"))
    heading = Enum.find_index(lines, &(&1 =~ "## Fixed"))
    assert strip < heading

    answer = cells |> row_of("The parser keeps the last line now.") |> inside()
    assert Enum.all?(answer, &(&1.bg == surface()))
    assert hd(answer).symbol == "▎"

    # A person's own line and a note are not on it.
    assert Enum.all?(inside(row_of(cells, "> fix the failing test")), &(&1.bg == :reset))
  end

  ## The surface at each depth, and with no colour

  for depth <- [:truecolor, :x256] do
    test "at #{depth} the frame's rows are on the surface, the chat's are not" do
      depth = unquote(depth)
      cells = draw(fold(turn()), theme: %{depth: depth, mode: :dark})
      on = surface(depth)
      assert on != nil

      for line <- ["The parser keeps the last line now.", "def parse(x), do: x", "lib/p.ex"] do
        assert Enum.all?(inside(row_of(cells, line)), &(&1.bg == on)), "#{line} at #{depth}"
      end

      for line <- ["> fix the failing test", "4 steps", "✗ read_file nope"] do
        assert Enum.all?(inside(row_of(cells, line)), &(&1.bg == :reset)), "#{line} at #{depth}"
      end
    end
  end

  test "with sixteen colours there is no background: the rail and the rules carry the frame" do
    cells = draw(fold(turn()), theme: %{depth: :x16, mode: :dark})

    assert Enum.all?(cells, &(&1.bg == :reset))
    assert hd(inside(row_of(cells, "The parser keeps the last line now."))).symbol == "▎"
    assert text(cells) =~ "▎ ┌─ elixir"
    assert text(cells) =~ "▎ └─"
    assert text(cells) =~ "▸ 4 steps"
  end

  test "under NO_COLOR every cell is the terminal's own ink, and the frames still read" do
    cells = draw(fold(turn()), theme: %{depth: :none, mode: :dark})

    assert Enum.all?(cells, &(&1.fg == :reset and &1.bg == :reset))
    screen = text(cells)
    assert screen =~ "▸ 4 steps · 1 failed"
    assert screen =~ "▎ ## Fixed"
    assert screen =~ "▎ ┌─ elixir"
    assert screen =~ "▎ │ def parse(x), do: x"
    assert screen =~ "✗ read_file nope"
  end

  ## transcript.detail

  test "tools: the tool frames open under an open strip, the reasoning kept to its header" do
    screen = text(draw(fold(turn()), detail: :tools))

    assert screen =~ "▾ 4 steps · 1 failed · grep, read_file, shell · 7s"
    assert screen =~ "▸ thinking · 12s"
    refute screen =~ "I should look at parse."
    assert screen =~ "▎ Let me look at the parser."
    assert screen =~ "✓ grep lib"
    assert screen =~ "✓ shell mix test · 1 test, 0 failures · 7s"
    assert screen =~ "▎     2 │   def parse(x), do: nil"
  end

  test "everything: nothing collapsed, the reasoning open with how long it took" do
    screen = text(draw(fold(turn()), detail: :everything))

    assert screen =~ "▾ thinking · 12s"
    assert screen =~ "▎ I should look at parse."
    assert screen =~ "✓ grep lib"
    assert screen =~ "▎ Let me look at the parser."
  end

  test "e opens the whole turn and closes it again, and a level of everything the other way" do
    quiet = text(draw(fold(turn())))
    opened = text(draw(fold(turn()), open: [0]))
    shut = text(draw(fold(turn()), detail: :everything, open: [0]))

    refute quiet =~ "✓ grep"
    assert opened =~ "▾ thinking · 12s"
    assert opened =~ "✓ grep lib"
    assert opened =~ "▾ 4 steps"
    assert shut =~ "▸ 4 steps"
    refute shut =~ "✓ grep"
  end

  test "the level re-draws history: every turn, and nothing in the fold changes" do
    second = [
      event(:input, %{source: :user, content: "again"}, 30_000),
      event(
        :assistant_message,
        %{content: [Message.tool_use("d1", "grep", %{"pattern" => "x", "path" => "x"})]},
        31_000
      ),
      done("d1", true, "nothing", 32_000),
      event(:assistant_message, %{content: [Message.text_block("Still fixed.")]}, 33_000),
      event(:agent_state, %{to: :idle, turn: turn_cost()}, 33_500)
    ]

    model = fold(turn() ++ second)
    quiet = text(draw(model))
    assert quiet =~ "▸ 4 steps"
    assert quiet =~ "▸ 1 step · grep"
    assert text(draw(model, detail: :everything)) =~ "✓ grep x · nothing"
    assert model == fold(turn() ++ second)
  end

  test "e acts on the last turn while the pane follows, and on the one at the top of the view once scrolled" do
    second = [
      event(:input, %{source: :user, content: "again"}, 30_000),
      event(:assistant_message, %{content: [Message.text_block("Still fixed.")]}, 31_000)
    ]

    state = %{
      focus: {:window, "root"},
      model: fold(turn() ++ second),
      pane: %{agent: nil, scroll: :follow, seen_entries: 0, open: MapSet.new()},
      tick: 0,
      now: 40_000,
      answer: nil
    }

    following = View.pane_geometry(state, {120, 20})
    assert following.turns == [0, 9]
    assert View.turn_in_view(following) == 1

    scrolled = View.pane_geometry(put_in(state.pane.scroll, 0), {120, 20})
    refute scrolled.follow?
    assert View.turn_in_view(scrolled) == 0
    refute View.turn_open?(scrolled)

    opened = put_in(state, [:pane, :open], MapSet.new([0]))
    assert View.turn_open?(View.pane_geometry(put_in(opened.pane.scroll, 0), {120, 20}))
  end

  ## Long frames

  test "a frame past the cap keeps its first lines and says how many more, expanding in place" do
    output = Enum.map_join(1..60, "\n", &"line #{&1}")

    model =
      fold(
        opened() ++
          [
            event(
              :tool_started,
              %{call_id: "c1", name: "shell", input: %{"command" => "seq 60"}},
              1
            ),
            done("c1", true, output, 2),
            event(:assistant_message, %{content: [Message.text_block("Sixty.")]}, 3)
          ]
      )

    tools = text(draw(model, detail: :tools, size: {120, 80}))
    assert tools =~ "▎ line 20"
    refute tools =~ "line 21"
    assert tools =~ "▎ … 40 more lines"

    open = text(draw(model, detail: :tools, open: [0], size: {120, 80}))
    assert open =~ "▎ line 60"
    refute open =~ "more lines"
  end

  ## Never collapsed

  test "after a budget stop nothing is collapsed, at any level" do
    model =
      fold(
        opened() ++
          [
            event(:tool_started, %{call_id: "c1", name: "read_file", input: %{"path" => "a"}}, 1),
            done("c1", true, "a", 2),
            event(
              :budget_ask_started,
              %{call_id: "budget-1", detail: "the turn budget is spent"},
              3
            ),
            event(:tool_started, %{call_id: "c2", name: "read_file", input: %{"path" => "b"}}, 4),
            done("c2", true, "b", 5)
          ]
      )

    screen = text(draw(model))
    assert screen =~ "▸ 1 step · read_file"
    refute screen =~ "✓ read_file a"
    assert screen =~ "✓ read_file b"
    assert screen =~ "BUDGET: the turn budget is spent"
  end

  test "an approval waits in the reserved colour, never collapsed and never a joke" do
    model =
      fold(
        opened() ++
          [
            event(
              :tool_started,
              %{call_id: "c1", name: "edit_file", input: %{"path" => "lib/p.ex"}},
              1
            ),
            event(
              :approval_requested,
              %{
                call_id: "c1",
                name: "edit_file",
                preview: "--- a/lib/p.ex\n+++ b/lib/p.ex\n-x\n+y"
              },
              2
            )
          ]
      )

    cells = draw(model)
    screen = text(cells)
    assert screen =~ "APPROVAL: edit_file"
    assert screen =~ "+y"

    approval = row_of(cells, "APPROVAL")
    pink = Theme.color(:needs_you, %{depth: :truecolor, mode: :dark})
    assert Enum.any?(approval, &(&1.fg == pink))

    for words <- Map.values(Model.curtain_set()) |> List.flatten() do
      refute screen =~ words
    end
  end

  # Root #658: a call a per-tool rule asks about says which rule, and whose.
  test "an approval a rule asked for names the rule and where it came from" do
    model =
      fold(
        opened() ++
          [
            event(
              :tool_started,
              %{call_id: "c1", name: "shell", input: %{"command" => "git push"}},
              1
            ),
            event(
              :approval_requested,
              %{
                call_id: "c1",
                name: "shell",
                preview: nil,
                rule: %{
                  "action" => "ask",
                  "rule" => "shell(git push)",
                  "scope" => "enforced",
                  "source" => "/etc/troupe/managed.yaml"
                }
              },
              2
            )
          ]
      )

    screen = model |> draw() |> text()
    assert screen =~ "APPROVAL: shell"
    assert screen =~ "asked by the rule ask shell(git push), from your organisation"
  end

  # Root #724: on a pod, a rule of the worker profile the session runs on says so, by name.
  test "an approval a worker profile's rule asked for names the profile" do
    model =
      fold(
        opened() ++
          [
            event(
              :tool_started,
              %{call_id: "c1", name: "mcp.issues.delete", input: %{}},
              1
            ),
            event(
              :approval_requested,
              %{
                call_id: "c1",
                name: "mcp.issues.delete",
                preview: nil,
                rule: %{
                  "action" => "ask",
                  "rule" => "mcp(issues.delete)",
                  "scope" => "profile",
                  "source" => "fixing"
                }
              },
              2
            )
          ]
      )

    screen = model |> draw() |> text()
    assert screen =~ "from the worker profile (fixing)"
  end

  test "a scratchpad document stays a card at every level" do
    model =
      fold(
        opened() ++
          [
            event(
              :tool_started,
              %{call_id: "c1", name: "show", input: %{"title" => "Plan", "name" => "plan.md"}},
              1
            ),
            event(
              :scratch_updated,
              %{
                call_id: "c1",
                name: "plan.md",
                path: "scratch:/plan.md",
                kind: "markdown",
                title: "Plan",
                size: 840,
                version: 1
              },
              2
            ),
            done("c1", true, "shown", 3)
          ]
      )

    for detail <- Model.details() do
      screen = text(draw(model, detail: detail))
      assert screen =~ "▤ Plan · plan.md · 840 B · new", "#{detail}"
    end
  end

  ## Markdown

  test "a table is drawn as one, a nested list indents with its marker, a code block is a frame" do
    screen = text(draw(fold(turn())))

    assert screen =~ "▎ file     │ change"
    assert screen =~ "▎ ─────────┼───────"
    assert screen =~ "▎ lib/p.ex │  +1 −1"
    assert screen =~ "▎ • checked the parser"
    assert screen =~ "▎   ◦ and its test"
    assert screen =~ "▎ ┌─ elixir"
  end

  test "a list item wrapped onto more rows lines up under its text, however deep" do
    lines = Model.markdown("- top\n  - " <> String.duplicate("word ", 12))
    rows = lines |> Model.frame() |> Model.rows(30, 0, 10) |> Enum.map(&Model.line_text/1)

    assert ["• top", "  ◦ word word word word word", "    word word word word word" | _] = rows
  end

  test "data in a fence is a table with its row count when it parses, and source when not" do
    csv = Model.markdown("```csv\nname,size\na.ex,12\nb.ex,\"1,024\"\n```")
    assert Model.line_text(hd(csv)) =~ "┌─ csv · 2 rows"
    assert Enum.map(csv, &Model.line_text/1) |> Enum.any?(&(&1 =~ "b.ex │ 1,024"))

    json = Model.markdown(~s(```json\n[{"id": 1, "ok": true}, {"id": 2, "ok": false}]\n```))
    assert Model.line_text(hd(json)) =~ "┌─ json · 2 rows"
    assert Enum.map(json, &Model.line_text/1) |> Enum.any?(&(&1 =~ "2  │ false"))

    nested = Model.markdown(~s(```json\n{"a": {"b": 1}}\n```))
    assert Model.line_text(hd(nested)) =~ "┌─ json"
    refute Model.line_text(hd(nested)) =~ "rows"

    ragged = Model.markdown("```csv\na,b\n1\n```")
    refute Model.line_text(hd(ragged)) =~ "rows"
  end

  test "a diff in a fence says its path and what it adds and removes" do
    diff = Model.markdown("```diff\n--- a/lib/p.ex\n+++ b/lib/p.ex\n@@ -1 +1 @@\n-x\n+y\n+z\n```")
    assert Model.line_text(hd(diff)) =~ "┌─ diff · lib/p.ex +2 −1"
    assert {:code, [{:diff_add, "+y"}]} in diff
  end

  test "a table too wide to draw says so, and is shown as written" do
    wide = Enum.map_join(1..12, " | ", &"column number #{&1}")
    lines = Model.markdown("| #{wide} |\n|" <> String.duplicate("---|", 12) <> "\n| a |")
    texts = Enum.map(lines, &Model.line_text/1)

    assert hd(texts) =~ "a table too wide to draw here"
    assert Enum.at(texts, 1) =~ "| column number 1 | column number 2"
  end

  ## The curtain line

  defp working(extra) do
    fold(opened() ++ [event(:agent_state, %{to: :thinking}, 0, transient?: true)] ++ extra)
  end

  test "the curtain line: the flourish a prefix, the facts always there, none repeated in a turn" do
    w = Model.session_window(working([]))

    assert Model.curtain_line(w, "root", 0, 12_000) ==
             "◐ the actors are powdering their nose — thinking (00:12)"

    acting =
      working([
        event(:agent_state, %{to: :acting}, 1_000, transient?: true),
        event(:tool_started, %{call_id: "c1", name: "read_file", input: %{"path" => "a"}}, 1_000),
        event(:tool_started, %{call_id: "c2", name: "list_files", input: %{"path" => "src"}}, 1_000)
      ])

    assert Model.curtain_line(Model.session_window(acting), "root", 0, 7_000) ==
             "◐ reading the script — running 2 tools: read_file a, list_files src (00:06)"

    # The second time it thinks in the turn reads differently, and the fourth has no words
    # left: the facts alone.
    again =
      working(
        Enum.flat_map(1..3, fn n ->
          [
            event(:agent_state, %{to: :acting}, n * 1_000, transient?: true),
            event(:agent_state, %{to: :thinking}, n * 1_000 + 500, transient?: true)
          ]
        end)
      )

    w = Model.session_window(again)
    assert w.curtain.thinking == 4
    assert Model.curtain_line(w, "root", 0, 4_000) == "◐ thinking (00:00)"

    second =
      Model.session_window(
        working([
          event(:agent_state, %{to: :acting}, 1_000, transient?: true),
          event(:agent_state, %{to: :thinking}, 2_000, transient?: true)
        ])
      )

    assert Model.curtain_line(second, "root", 0, 2_000) =~ "running lines in the wings — thinking"

    # A new turn starts the set again.
    fresh =
      Model.session_window(
        fold(
          opened() ++
            [
              event(:agent_state, %{to: :thinking}, 0, transient?: true),
              event(:agent_state, %{to: :acting}, 1, transient?: true),
              event(:agent_state, %{to: :thinking}, 2, transient?: true),
              event(:agent_state, %{to: :idle}, 3),
              event(:input, %{source: :user, content: "next"}, 4),
              event(:agent_state, %{to: :thinking}, 5, transient?: true)
            ]
        )
      )

    assert Model.curtain_line(fresh, "root", 0, 5) =~ "the actors are powdering their nose"
  end

  test "no flourish on what waits on a person, a model error, or a subagent's own pane" do
    waiting =
      working([
        event(:question_asked, %{call_id: "q1", question: "which file?", options: []}, 1)
      ])

    assert Model.curtain_line(Model.session_window(waiting), "root", 0, 1) == "waiting for you"

    errored = working([event(:llm_error, %{message: "no key"}, 1)])
    w = Model.session_window(errored)
    w = %{w | activity: Map.put(w.activity, "root", :idle)}
    assert Model.curtain_line(w, "root", 0, 1) == "model error: no key"

    sub =
      working([
        event(:agent_state, %{to: :thinking}, 1, path: "root/explore-1", transient?: true)
      ])

    assert Model.curtain_line(Model.session_window(sub), "root/explore-1", 0, 1_000) ==
             "◐ thinking (00:00)"
  end

  test "the pane draws the curtain line; a tile and the headless printer never do" do
    model = working([])
    cells = draw(model, now: 12_000)
    screen = text(cells)

    assert screen =~ "◐ the actors are powdering their nose — thinking (00:12)"

    tile = Model.tile_lines(Model.session_window(model), 0, 12_000, false)
    refute Enum.any?(tile, &(Model.line_text(&1) =~ "powdering"))
    assert Enum.any?(tile, &(Model.line_text(&1) =~ "thinking (00:12)"))
  end

  test "a headless run prints facts, never the flourish" do
    script = [
      %{"reasoning" => "look first", "tools" => [%{"name" => "list_files", "input" => %{}}]},
      {:text, "done"}
    ]

    {sid, _, _} = start_session!(script: script)
    {:ok, io} = StringIO.open("")
    me = self()

    {:ok, _} =
      Printer.start_link(
        session_id: sid,
        target: "root",
        io: io,
        on_rest: fn code -> send(me, {:rest, code}) end
      )

    say!(sid, "look")
    assert_receive {:rest, 0}, 15_000
    {_, out} = StringIO.contents(io)
    assert out =~ "list_files"

    for words <- Map.values(Model.curtain_set()) |> List.flatten() do
      refute out =~ words
    end
  end

  test "the settings page offers transcript.detail as a menu of its three levels, taken at once" do
    assert {:ok, field} = Troupe.Settings.fetch("transcript.detail")
    assert %{type: :detail, effect: :now, default: "quiet"} = field

    assert Enum.map(Troupe.Settings.choices(field, nil, "quiet"), & &1.value) ==
             ~w(quiet tools everything)

    assert Troupe.Settings.parse(field, " Tools ") == {:ok, "tools"}
    assert {:error, _} = Troupe.Settings.parse(field, "loud")
  end

  ## Through the daemon

  defp ready(sid, opts \\ []) do
    {pid, session} = start_tui(sid, opts)
    press(pid, "1")
    eventually(fn -> match?({:window, "root"}, user_state(pid).focus) end)
    {pid, session}
  end

  test "against the daemon: e opens the turn and closes it, /detail re-draws, the log is as it was" do
    script = [
      {:text_and_tools, "Looking.", [{"list_files", %{}}, {"shell", %{"command" => "echo hi"}}]},
      {:text, "All good."}
    ]

    {sid, _, _} = start_session!(script: script)
    say!(sid, "check")
    await_done()
    events = Client.events(sid)

    {pid, session} = ready(sid)

    eventually(fn -> screen_text(pid, session) =~ "▸ 2 steps · list_files, shell" end)
    refute screen_text(pid, session) =~ "✓ shell echo hi"
    assert screen_text(pid, session) =~ "All good."
    assert screen_text(pid, session) =~ "e opens the turn"

    press(pid, "e")
    eventually(fn -> screen_text(pid, session) =~ "✓ shell echo hi" end)
    assert screen_text(pid, session) =~ "▾ 2 steps"
    assert screen_text(pid, session) =~ "e closes the turn"

    press(pid, "e")
    eventually(fn -> not (screen_text(pid, session) =~ "✓ shell echo hi") end)

    # `/detail` from the window's box: this screen only, and history drawn again.
    type(pid, "/detail tools")
    press(pid, "enter")
    eventually(fn -> user_state(pid).detail_own == :tools end)
    eventually(fn -> screen_text(pid, session) =~ "✓ shell echo hi" end)

    assert Client.events(sid) == events
    GenServer.stop(pid)
  end

  # The daemon's deltas are coalesced per frame, and a model that thinks and answers within
  # one frame used to have its reasoning flushed as the start of its answer, never folded
  # into a reasoning frame.
  test "against the daemon: reasoning that streams in the frame its answer starts in is reasoning" do
    {sid, _, _} = start_session!(script: [%{"reasoning" => "think hard about it", "text" => "hi"}])
    {pid, session} = start_tui(sid)
    _ = :sys.get_state(pid)
    say!(sid, "go")

    eventually(fn ->
      Enum.any?(
        user_state(pid).model.windows["root"].agents["root"].transcript,
        &match?({:reasoning, _}, &1)
      )
    end)

    press(pid, "1")
    eventually(fn -> screen_text(pid, session) =~ "▸ thinking" end)
    refute screen_text(pid, session) =~ "think hard about it"
    assert screen_text(pid, session) =~ "▎ hi"

    press(pid, "e")
    eventually(fn -> screen_text(pid, session) =~ "▎ think hard about it" end)
    assert screen_text(pid, session) =~ "▾ thinking"
    GenServer.stop(pid)
  end

  test "transcript.detail on the config ladder is the screen's default" do
    script = [{:text_and_tools, "Looking.", [{"list_files", %{}}]}, {:text, "All good."}]

    {sid, _, _} =
      start_session!(script: script, config: %{"transcript" => %{"detail" => "everything"}})

    say!(sid, "check")
    await_done()
    {pid, session} = ready(sid)

    eventually(fn -> user_state(pid).detail == :everything end)
    eventually(fn -> screen_text(pid, session) =~ "✓ list_files" end)
    GenServer.stop(pid)
  end
end
