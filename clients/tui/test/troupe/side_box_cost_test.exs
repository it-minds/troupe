defmodule Troupe.SideBoxCostTest do
  @moduledoc """
  What a turn cost, in the side box (issue #578, TUI Decision 160).

  The side box beside an activated window's transcript says what the window's last turn
  cost and, beneath it, what the session has: calls, money, `↑` sent, cached, `↓`
  received, and the headroom warning under the session. At 100 columns and wider, where
  the side box is drawn, the transcript carries no line for the turn; below that there is
  no side box, and the line stays under the turn (Decision 139), in `turn_line/1`'s words.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.CellSession
  alias ExRatatui.Frame
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{Model, View}

  # 100 fresh tokens, 1,000 from the cache and one out, three times.
  @turn %{
    "calls" => 3,
    "input_tokens" => 300,
    "cache_read" => 3_000,
    "cache_write" => 0,
    "output_tokens" => 3,
    "cost_micros" => 37_500,
    "unpriced" => 0
  }

  @line "turn: 3 calls · ↑ 300 sent · 3.0k cached · ↓ 3 received · $0.04"

  test "after a turn ends, the side box says what it cost and the session's totals, and the transcript has no line for it" do
    model = fold(turn("go", 3) ++ [ended(@turn)])
    screen = draw(model, 120)

    assert side(screen, 120) =~
             """
             This turn:
               3 calls · $0.04
               ↑ 300 sent · 3.0k cached
               ↓ 3 received
             Session:
               3 calls · $0.04
               ↑ 300 sent · 3.0k cached
               ↓ 3 received

             Tasks:
             """

    # Not in the pane, and not on the window's tile above it either.
    refute text(screen) =~ "turn: 3 calls"
    # The fold keeps the line where it was written: it is the drawing that leaves it out.
    assert {:system, @line} in window(model).agents["root"].transcript
  end

  test "below 100 columns there is no side box, and the line is under the turn" do
    screen = draw(fold(turn("go", 3) ++ [ended(@turn)]), 99)

    assert text(screen) =~ "· " <> @line
    refute text(screen) =~ "This turn:"
    refute text(screen) =~ "Session:"
  end

  test "a screen narrowed past 100 columns has the line again, and widened leaves it out again" do
    model = fold(turn("go", 3) ++ [ended(@turn)])

    # 120 columns leaves the transcript 88 inside its borders, as 90 does without a side box.
    refute text(draw(model, 120)) =~ "turn: 3 calls"
    assert text(draw(model, 90)) =~ "· " <> @line
    refute text(draw(model, 120)) =~ "turn: 3 calls"
  end

  test "while the next turn runs, this turn says nothing of either, and the session counts on" do
    second = turn("again", 1)
    screen = draw(fold(turn("go", 3) ++ [ended(@turn)] ++ second), 120)

    assert side(screen, 120) =~
             """
             This turn:
               said when it ends
             Session:
               3 calls · $0.04
               ↑ 400 sent · 4.0k cached
               ↓ 4 received
             """

    ended = fold(turn("go", 3) ++ [ended(@turn)] ++ second ++ [ended(%{@turn | "calls" => 1})])

    assert side(draw(ended, 120), 120) =~
             """
             This turn:
               1 call · $0.04
               ↑ 300 sent · 3.0k cached
               ↓ 3 received
             Session:
               4 calls · $0.08
               ↑ 400 sent · 4.0k cached
               ↓ 4 received
             """
  end

  test "before any turn has ended, there is no turn to speak of and the session has only its tokens" do
    model =
      fold([wire("user_input", %{"source" => "user", "text" => "go"}), wire("turn_ended", %{})])

    assert side(draw(model, 120), 120) =~
             """
             This turn:
               (none)
             Session:
               ↑ 0 sent · 0 cached
               ↓ 0 received
             """
  end

  test "money is said as the line says it: no price, and the calls nobody priced" do
    unpriced =
      fold(turn("go", 2) ++ [ended(%{@turn | "calls" => 2, "cost_micros" => 0, "unpriced" => 2})])

    assert side(draw(unpriced, 240), 240) =~ "This turn:\n  2 calls · no price\n"

    some = fold(turn("go", 3) ++ [ended(%{@turn | "unpriced" => 1, "cost_micros" => 5_000})])
    assert side(draw(some, 240), 240) =~ "This turn:\n  3 calls · under a cent, 1 call unpriced\n"
  end

  test "the headroom warning is under the session, where the limit is" do
    warned =
      wire("budget_warning", %{
        "dimension" => "input",
        "used" => 820,
        "limit" => 1_000,
        "fraction" => 0.82,
        "detail" => "82% of input tokens"
      })

    screen = draw(fold(turn("go", 3) ++ [warned, ended(@turn)]), 120)

    assert side(screen, 120) =~
             """
             Session:
               3 calls · $0.04
               ↑ 300 sent · 3.0k cached
               ↓ 3 received
               ⚠ 82% of input tokens

             Tasks:
             """
  end

  test "at the side box's narrowest, 30 columns, a figure that does not fit beside another takes a line of its own" do
    big = %{
      "calls" => 40,
      "input_tokens" => 1_200_000,
      "cache_read" => 310_000,
      "cache_write" => 0,
      "output_tokens" => 19_000,
      "cost_micros" => 610_000,
      "unpriced" => 2
    }

    model = fold(turn("go", 1) ++ [ended(big)])

    # 120 columns is a side box of 30, 28 inside its borders: a line that did not fit would
    # wrap onto a row of its own, which none here is.
    assert side(draw(model, 120), 120) =~
             """
             This turn:
               40 calls
               $0.61, 2 calls unpriced
               ↑ 1.2M sent
               310.0k cached
               ↓ 19.0k received
             Session:
               40 calls
               $0.61, 2 calls unpriced
               ↑ 100 sent · 1.0k cached
               ↓ 1 received
             """

    # At 60 columns the two sit side by side.
    assert side(draw(model, 240), 240) =~
             """
             This turn:
               40 calls · $0.61, 2 calls unpriced
               ↑ 1.2M sent · 310.0k cached
               ↓ 19.0k received
             """
  end

  test "each line fits the room it is given, the narrowest side box's included" do
    turn = %{
      calls: 999,
      usage: %{input: 999_949, cache_write: 0, cache_read: 999_949, output: 999_949},
      cost_micros: 999_990_000,
      unpriced: 0
    }

    for width <- 26..56, line <- Model.turn_box(turn, width) do
      assert Model.cell_width(line) <= width, "#{width}: #{line}"
    end
  end

  test "the window's own turns leave the transcript where the side box is; a subagent's line stays in its own" do
    sub = ["root", "explore-1"]

    model =
      fold(
        turn("go", 1) ++
          [
            wire("agent_done", %{"reason" => "finished", "turn" => %{@turn | "calls" => 2}}, sub),
            ended(@turn)
          ]
      )

    shown = Model.without_turn_lines(window(model))

    refute Enum.any?(shown.agents["root"].transcript, &match?({:system, "turn: " <> _}, &1))

    assert Enum.any?(
             shown.agents["root/explore-1"].transcript,
             &match?({:system, "turn: 2 calls" <> _}, &1)
           )

    assert window(model).last_turn.calls == 3
  end

  defp turn(text, calls) do
    [wire("user_input", %{"source" => "user", "text" => text})] ++
      Enum.map(1..calls, fn n ->
        wire("llm_response", %{
          "message" => %{
            "role" => "assistant",
            "content" => [%{"type" => "text", "text" => "step #{n}"}]
          },
          "usage" => %{
            "input_tokens" => 100,
            "cache_read" => 1_000,
            "cache_write" => 0,
            "output_tokens" => 1
          },
          "gateway" => %{"cost_micros" => 12_500}
        })
      end)
  end

  defp ended(turn), do: wire("turn_ended", %{"turn" => turn})

  defp wire(type, data, agent \\ ["root"]),
    do: %{"type" => type, "agent" => agent, "data" => data, "ts" => "2026-10-11T10:00:00Z"}

  defp fold(wire_events) do
    {events, _memory} =
      wire_events
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> Map.put(event, "seq", seq) end)
      |> Enum.flat_map_reduce(Translate.memory(), &Translate.durable("s-1", &1, &2))

    Model.rebuild("s-1", "/w", events)
  end

  defp window(model), do: model |> Model.windows() |> hd()

  # The screen as the server draws it, the root window's pane open.
  defp draw(model, width, height \\ 40) do
    state = %{
      session_id: "s-1",
      workspace: "/w",
      model: model,
      focus: {:window, "root"},
      cmd_text: "",
      cmd_pos: 0,
      win_text: "",
      win_pos: 0,
      agents: ["code"],
      commands: [],
      palette: nil,
      tick: 0,
      now: 0,
      quit_armed: false,
      win_armed: nil,
      expanded: false,
      pane: %{agent: nil, scroll: :follow, seen_entries: 0},
      selection: nil,
      answer: nil,
      size: {width, height},
      hq: nil,
      observer: nil,
      theme: %{depth: :none, mode: :dark}
    }

    session = CellSession.new(width, height)
    :ok = CellSession.draw(session, View.render(state, %Frame{width: width, height: height}))

    CellSession.take_cells(session).cells
    |> Enum.group_by(& &1.row)
    |> Enum.sort()
    |> Enum.map(fn {_row, cells} -> Enum.sort_by(cells, & &1.col) end)
  end

  defp text(rows), do: Enum.map_join(rows, "\n", &line/1)

  # The side box's rows, inside its borders: `clamp(width / 4, 30, 60)` columns at the
  # right of the pane (Decision 48).
  defp side(rows, width) do
    side_w = width |> div(4) |> max(30) |> min(60)
    from = width - side_w + 1

    Enum.map_join(rows, "\n", fn cells ->
      cells |> Enum.filter(&(&1.col in from..(width - 2)//1)) |> line()
    end)
  end

  defp line(cells), do: cells |> Enum.map_join("", & &1.symbol) |> String.trim_trailing()
end
