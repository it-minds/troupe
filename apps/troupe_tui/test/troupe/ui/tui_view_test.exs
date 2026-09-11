defmodule Troupe.UI.TUIViewTest do
  @moduledoc """
  Snapshot tests against ExRatatui's headless backend.

  `View.scene/2` is a pure function of state, so these render it directly rather than
  driving a supervised app — the split ExRatatui's testing guide recommends, since a
  supervised app's buffer is not exposed.
  """

  use ExUnit.Case, async: true

  alias ExRatatui.Layout.Rect
  alias Troupe.{Budget, Todo, Workspace}
  alias Troupe.UI.TUI.{State, View}

  @width 120
  @height 32

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-tui-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, workspace} = Workspace.new(root)
    %{state: State.new("session-1", workspace)}
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
        |> State.apply_event(%{
          type: :agent_state,
          agent_path: ["root"],
          data: agent_state(:acting, "build")
        })
        |> State.apply_event(%{
          type: :user_input,
          agent_path: ["root"],
          data: %{"source" => "user", "text" => "make the tests pass"}
        })
        |> State.apply_event(%{
          type: :tool_call_started,
          agent_path: ["root"],
          data: %{call_id: "c1", name: "read_file", args: %{"path" => "lib/math.ex"}}
        })
        |> State.apply_event(%{
          type: :tool_call_completed,
          agent_path: ["root"],
          data: %{call_id: "c1", name: "read_file", ok?: true, content: "1\tdefmodule Math do"}
        })
        |> State.apply_event(%{
          type: :tool_call_started,
          agent_path: ["root"],
          data: %{call_id: "c2", name: "shell", args: %{"command" => "mix test"}}
        })
        |> State.apply_event(%{
          type: :tool_call_completed,
          agent_path: ["root"],
          data: %{call_id: "c2", name: "shell", ok?: false, content: "1 test, 1 failure"}
        })
        |> State.apply_event(%{
          type: :llm_delta,
          agent_path: ["root"],
          data: %{kind: :text, text: "One test still fails."}
        })

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

    test "a collapsed tool call hides its output until expanded", %{state: state} do
      state =
        state
        |> State.apply_event(%{
          type: :tool_call_started,
          agent_path: ["root"],
          data: %{call_id: "c1", name: "grep", args: %{"pattern" => "defmodule"}}
        })
        |> State.apply_event(%{
          type: :tool_call_completed,
          agent_path: ["root"],
          data: %{call_id: "c1", name: "grep", ok?: true, content: "lib/a.ex:1:defmodule A do"}
        })

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
        %Todo{id: "a", content: "read the failing test", status: :completed},
        %Todo{id: "b", content: "fix the function", status: :in_progress},
        %Todo{id: "c", content: "run the suite", status: :pending},
        %Todo{id: "d", content: "abandoned idea", status: :cancelled}
      ]

      content =
        state
        |> State.apply_event(%{type: :todo_updated, agent_path: ["root"], data: %{items: todos}})
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
        |> State.apply_event(%{
          type: :agent_state,
          agent_path: ["root"],
          data: agent_state(:acting, "build")
        })
        |> State.apply_event(%{
          type: :agent_state,
          agent_path: ["root", "explore#1"],
          data: agent_state(:thinking, "explore")
        })
        |> State.apply_event(%{
          type: :agent_state,
          agent_path: ["root", "general#2"],
          data: agent_state(:done, "general")
        })
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
        |> State.apply_event(%{
          type: :approval_requested,
          agent_path: ["root"],
          data: %{
            call_id: "c9",
            tool: "edit_file",
            agent_path: ["root"],
            args: %{
              "path" => "lib/math.ex",
              "old_string" => "def answer, do: 0",
              "new_string" => "def answer, do: 42"
            }
          }
        })
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
        |> State.apply_event(%{
          type: :approval_requested,
          agent_path: ["root"],
          data: %{
            call_id: "c9",
            tool: "shell",
            agent_path: ["root"],
            args: %{"command" => "mix test --failed"}
          }
        })
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

        assert :ok = ExRatatui.draw(terminal, scene),
               "drawing failed at #{width}x#{height}"
      end
    end
  end

  describe "layout" do
    test "a narrow terminal drops the side panel rather than overflowing", %{state: state} do
      todos = [%Todo{id: "a", content: "something", status: :pending}]

      state =
        State.apply_event(state, %{
          type: :todo_updated,
          agent_path: ["root"],
          data: %{items: todos}
        })

      wide = draw(state, 120, 30)
      narrow = draw(state, 70, 30)

      assert wide =~ "tasks"
      assert wide =~ "agents"
      refute narrow =~ "agents"
      assert narrow =~ "transcript"
    end
  end

  defp agent_state(state, profile) do
    %{
      state: state,
      profile: profile,
      todos: [],
      budget: %Budget{turns: 3, max_turns: 40, input_tokens: 1_200, output_tokens: 300},
      done_reason: nil
    }
  end
end
