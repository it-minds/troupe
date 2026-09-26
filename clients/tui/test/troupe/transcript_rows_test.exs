defmodule Troupe.TranscriptRowsTest do
  @moduledoc """
  What a transcript entry looks like once it is drawn (issue #182): a command's output
  that ends in newlines and a reply with a fenced code block take exactly the rows their
  text needs — folded through `Translate`, `Model` and `View`, and on a headless screen
  at a wide and a narrow width with tool output expanded. Nothing asserted the row count
  of a rendered entry before, which is how blank rows around code and command output
  reached daily use.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias ExRatatui.CellSession
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.{Model, View}

  # A blank line on each side of the fence and a newline after the last line: how most
  # models write a reply with code in it.
  @reply """
  Here is the fix:

  ```elixir
  def hello, do: :world
  ```

  Apply it and rerun.
  """

  ## Translate -> Model -> View

  # The worker's events as PROTOCOL.md §4 spells them, folded as a rebuild folds them
  # (the first one opens the window), and measured by the view that lays the pane out.
  defp fold(events) do
    {model, _memory} =
      Enum.reduce(events, {Model.new("s-1", "."), Translate.memory()}, fn {type, data},
                                                                          {model, memory} ->
        {local, memory} = Translate.durable("s-1", durable(type, data), memory)
        {Enum.reduce(local, model, &Model.apply(&2, &1)), memory}
      end)

    model
  end

  defp durable(type, data) do
    %{
      "seq" => 1,
      "prev_hash" => "sha256:abc",
      "ts" => "2026-09-26T10:00:00.000Z",
      "actor" => %{"kind" => "user", "subject" => "idp|martin", "display_name" => "Martin"},
      "agent" => ["root"],
      "type" => type,
      "v" => 1,
      "data" => data
    }
  end

  defp geometry(model, width) do
    state = %{
      focus: {:window, "root"},
      model: model,
      pane: %{agent: nil, scroll: :follow, seen_entries: 0},
      expanded: true,
      tick: 0,
      now: System.system_time(:millisecond),
      answer: nil
    }

    View.pane_geometry(state, {width, 40})
  end

  test "a result's trailing newlines and the blank lines beside a fence add no rows" do
    model =
      fold([
        {"user_input", %{"source" => "user", "text" => "fix it"}},
        {"llm_response",
         %{
           "message" => %{
             "role" => "assistant",
             "content" => [%{"type" => "text", "text" => @reply}]
           }
         }},
        {"tool_call_started",
         %{
           "call_id" => "c1",
           "name" => "shell",
           "args" => %{"command" => "printf 'one\\ntwo\\n\\n\\n'"}
         }},
        {"tool_call_completed",
         %{"call_id" => "c1", "name" => "shell", "ok" => true, "content" => "one\ntwo\n\n\n"}}
      ])

    for width <- [200, 60] do
      g = geometry(model, width)

      # The line typed; the prose and the block between its two rules; the call's head
      # and its two lines of output. Nothing blank.
      assert Enum.take(g.heights, g.entries) == [1, 5, 3]

      texts =
        g.blocks
        |> Enum.concat()
        |> Model.rows(g.inner_w, 0, g.total)
        |> Enum.map(&Model.line_text/1)

      assert [
               "> fix it",
               "Here is the fix:",
               "┌─ elixir " <> _,
               "│ def hello, do: :world",
               "└" <> _,
               "Apply it and rerun.",
               "✓ shell " <> _,
               "  one",
               "  two"
             ] = Enum.take(texts, 9)
    end
  end

  describe "Model.markdown/1" do
    test "drops the blank lines beside a fence and at the ends of a message, keeps a paragraph break" do
      kinds = fn text -> text |> Model.markdown() |> Enum.map(&elem(&1, 0)) end

      assert kinds.(@reply) == [:text, :code_head, :code, :code_tail, :text]

      assert kinds.("\n\none\n\n\n```\nx\n```\n\n\ntwo\n\n") ==
               [:text, :code_head, :code, :code_tail, :text]

      assert kinds.("one\n\ntwo") == [:text, :text, :text]
    end
  end

  ## On screen, through the daemon

  # The pane's interior at the size the TUI was started at, row by row, without the
  # borders or the side panel: a blank transcript row is an empty string here.
  defp pane_rows(pid, session, size) do
    send(pid, :force_render)
    _ = :sys.get_state(pid)
    g = View.pane_geometry(user_state(pid), size)
    cells = CellSession.take_cells(session).cells
    x0 = g.left.x + 1
    x1 = g.left.x + g.left.width - 2

    for y <- (g.left.y + 1)..(g.left.y + g.inner_h) do
      cells
      |> Enum.filter(&(&1.row == y and &1.col >= x0 and &1.col <= x1))
      |> Enum.sort_by(& &1.col)
      |> Enum.map_join("", & &1.symbol)
      |> String.trim_trailing()
    end
  end

  test "on screen, a command's output and a code block take exactly their rows, wide and narrow" do
    ws = tmp_workspace(%{"Makefile" => "all:\n\tgo build ./...\n\techo done\n"})

    {sid, _, _} =
      start_session!(
        workspace: ws,
        script: [
          {:text_and_tools, @reply,
           [
             {"shell", %{"command" => "printf 'one\\ntwo\\n\\n\\n'"}},
             {"read_file", %{"path" => "Makefile"}}
           ]},
          {:finish, "done"}
        ]
      )

    say!(sid, "fix it")
    await_done()

    for width <- [220, 60] do
      {pid, session} = start_tui(sid, width: width, height: 40)
      press(pid, "1")
      eventually(fn -> match?({:window, "root"}, user_state(pid).focus) end)
      press(pid, "e")
      eventually(fn -> user_state(pid).expanded end)

      rows = pane_rows(pid, session, {width, 40})

      start =
        Enum.find_index(rows, &(&1 == "Here is the fix:")) ||
          flunk("the reply is not on the #{width}-column screen:\n#{Enum.join(rows, "\n")}")

      assert [
               "Here is the fix:",
               "┌─ elixir " <> _,
               "│ def hello, do: :world",
               "└" <> _,
               "Apply it and rerun.",
               "✓ shell " <> _,
               "  one",
               "  two",
               "✓ read_file Makefile" <> _
             ] = Enum.slice(rows, start, 9)

      # A tab-indented file: its four lines and nothing else between the read and the
      # finish, whatever its tabs expand to.
      {read, [finish | _]} =
        rows
        |> Enum.drop(start + 9)
        |> Enum.split_while(&(not String.starts_with?(&1, "✓ finish")))

      assert length(read) == 4
      assert Enum.all?(read, &(&1 != ""))
      assert finish =~ "finish"

      GenServer.stop(pid)
    end
  end
end
