defmodule Troupe.UI.TUIViewTest do
  @moduledoc """
  Snapshot tests against ExRatatui's headless backend.

  `View.scene/2` is a pure function of state, so these render it directly rather than
  driving a supervised app — the split ExRatatui's testing guide recommends, since a
  supervised app's buffer is not exposed.

  The events fed in are `%Troupe.Protocol.Event{}` records exactly as they arrive over
  a socket. There is no test-only shape: if the screen can be built from these, it can
  be built by any client.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Troupe.Protocol.Event
  alias Troupe.UI.TUI.{State, View}

  @width 120
  @height 32

  setup do
    %{state: State.new("session-1", "/tmp/workspace")}
  end

  defp draw(state, width \\ @width, height \\ @height) do
    terminal = ExRatatui.init_test_terminal(width, height)
    frame = %ExRatatui.Frame{width: width, height: height}
    scene = View.scene(state, frame)

    :ok =
      ExRatatui.draw(
        terminal,
        Enum.map(scene, fn {widget, %Rect{} = rect} -> {widget, rect} end)
      )

    ExRatatui.get_buffer_content(terminal)
  end

  describe "transcript" do
    test "renders the header, a question, an answer and tool calls", %{state: state} do
      state =
        state
        |> apply_all([
          event("agent_state", agent_state("acting", "build")),
          event("user_input", %{"source" => "user", "text" => "make the tests pass"}),
          event("tool_call_started", %{
            "call_id" => "c1",
            "name" => "read_file",
            "args" => %{"path" => "lib/math.ex"}
          }),
          event("tool_call_completed", %{
            "call_id" => "c1",
            "name" => "read_file",
            "ok" => true,
            "content" => "1\tdefmodule Math do"
          }),
          event("tool_call_started", %{
            "call_id" => "c2",
            "name" => "shell",
            "args" => %{"command" => "mix test"}
          }),
          event("tool_call_completed", %{
            "call_id" => "c2",
            "name" => "shell",
            "ok" => false,
            "content" => "1 test, 1 failure"
          }),
          event("llm_delta", %{"kind" => "text", "text" => "One test still fails."})
        ])

      content = draw(state)

      assert content =~ "troupe"
      assert content =~ "build"
      assert content =~ "acting"
      assert content =~ "transcript"
      assert content =~ "make the tests pass"
      assert content =~ "read_file"
      assert content =~ "lib/math.ex"
      assert content =~ "shell"
      assert content =~ "✓"
      assert content =~ "✗"
      assert content =~ "One test still fails."
      assert content =~ "input"
    end

    test "an llm_response settles the streamed answer rather than repeating it", %{state: state} do
      state =
        apply_all(state, [
          event("llm_delta", %{"kind" => "text", "text" => "One test "}),
          event("llm_delta", %{"kind" => "text", "text" => "still fails."}),
          event("llm_response", %{
            "message" => %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => "One test still fails."}]
            }
          })
        ])

      assert [{:assistant, "One test still fails."}] = state.transcript
    end

    test "a collapsed tool call hides its output until expanded", %{state: state} do
      state =
        apply_all(state, [
          event("tool_call_started", %{
            "call_id" => "c1",
            "name" => "grep",
            "args" => %{"pattern" => "defmodule"}
          }),
          event("tool_call_completed", %{
            "call_id" => "c1",
            "name" => "grep",
            "ok" => true,
            "content" => "lib/a.ex:1:defmodule A do"
          })
        ])

      collapsed = draw(state)
      assert collapsed =~ "grep"
      refute collapsed =~ "lib/a.ex:1:defmodule"

      expanded = state |> State.toggle_expanded("c1") |> draw()
      assert expanded =~ "lib/a.ex:1:defmodule A do"
    end
  end

  describe "task panel" do
    test "renders every status with its own marker", %{state: state} do
      todos = [
        todo("a", "read the failing test", "completed"),
        todo("b", "fix the function", "in_progress"),
        todo("c", "run the suite", "pending"),
        todo("d", "abandoned idea", "cancelled")
      ]

      content =
        state
        |> State.apply_event(event("todo_updated", %{"items" => todos}))
        |> draw()

      assert content =~ "tasks"
      assert content =~ "[x] read the failing test"
      assert content =~ "[~] fix the function"
      assert content =~ "[ ] run the suite"
      assert content =~ "[-] abandoned idea"
    end
  end

  describe "agent tree" do
    test "nests subagents under their parent with state and budget", %{state: state} do
      content =
        state
        |> apply_all([
          event("agent_state", agent_state("acting", "build")),
          event("agent_state", agent_state("thinking", "explore"), agent: ["root", "explore#1"]),
          event("agent_state", agent_state("done", "general"), agent: ["root", "general#2"])
        ])
        |> draw()

      assert content =~ "agents"
      assert content =~ "root"
      assert content =~ "explore#1"
      assert content =~ "general#2"
      assert content =~ "thinking"
      assert content =~ "turns"
    end
  end

  describe "approval prompt" do
    test "shows a diff for an edit", %{state: state} do
      content =
        state
        |> State.apply_event(
          event("approval_requested", %{
            "call_id" => "c9",
            "tool" => "edit_file",
            "agent_path" => ["root"],
            "args" => %{
              "path" => "lib/math.ex",
              "old_string" => "def answer, do: 0",
              "new_string" => "def answer, do: 42"
            }
          })
        )
        |> draw()

      assert content =~ "approve edit_file?"
      assert content =~ "lib/math.ex"
      assert content =~ "- def answer, do: 0"
      assert content =~ "+ def answer, do: 42"
      assert content =~ "allow"
      assert content =~ "deny"
    end

    test "shows the whole command for shell", %{state: state} do
      content =
        state
        |> State.apply_event(
          event("approval_requested", %{
            "call_id" => "c9",
            "tool" => "shell",
            "agent_path" => ["root"],
            "args" => %{"command" => "mix test --failed"}
          })
        )
        |> draw()

      assert content =~ "approve shell?"
      assert content =~ "mix test --failed"
    end
  end

  describe "degenerate terminal sizes" do
    # A terminal really does report 0x0 — during a resize, and on a pty whose size was
    # never set. Producing rects from that made ratatui reject every draw, which is
    # how this was found: a TUI that painted nothing but "rect.width: unexpected value".
    test "a zero-sized frame renders nothing rather than an invalid rect", %{state: state} do
      assert View.scene(state, %ExRatatui.Frame{width: 0, height: 0}) == []
      assert View.scene(state, %ExRatatui.Frame{width: 80, height: 0}) == []
      assert View.scene(state, %ExRatatui.Frame{width: 0, height: 24}) == []
    end

    test "a terminal too small for the layout says so instead of erroring", %{state: state} do
      # Wrapped across the narrow width, so the assertion is on the words present.
      content = draw(state, 12, 4)
      assert content =~ "terminal"
      assert content =~ "small"
    end

    test "every scene a real terminal size produces is drawable", %{state: state} do
      for {width, height} <- [{20, 6}, {40, 10}, {80, 24}, {120, 40}, {200, 60}] do
        terminal = ExRatatui.init_test_terminal(width, height)
        scene = View.scene(state, %ExRatatui.Frame{width: width, height: height})

        assert :ok = ExRatatui.draw(terminal, scene), "drawing failed at #{width}x#{height}"
      end
    end
  end

  describe "layout" do
    test "a narrow terminal drops the side panel rather than overflowing", %{state: state} do
      state =
        State.apply_event(
          state,
          event("todo_updated", %{"items" => [todo("a", "something", "pending")]})
        )

      wide = draw(state, 120, 30)
      narrow = draw(state, 70, 30)

      assert wide =~ "tasks"
      assert wide =~ "agents"
      refute narrow =~ "agents"
      assert narrow =~ "transcript"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp apply_all(state, events), do: Enum.reduce(events, state, &State.apply_event(&2, &1))

  defp event(type, data, opts \\ []) do
    %Event{
      type: type,
      agent: Keyword.get(opts, :agent, ["root"]),
      data: data,
      seq: Keyword.get(opts, :seq),
      ts: "2026-01-01T00:00:00Z"
    }
  end

  defp todo(id, content, status) do
    %{"id" => id, "content" => content, "status" => status}
  end

  defp agent_state(state, profile) do
    %{
      "state" => state,
      "profile" => profile,
      "todos" => [],
      "budget" => %{
        "turns" => 3,
        "max_turns" => 40,
        "input_tokens" => 1_200,
        "output_tokens" => 300
      },
      "done_reason" => nil
    }
  end
end
