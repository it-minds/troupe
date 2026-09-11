defmodule Troupe.UI.TUI.View do
  @moduledoc """
  Turning `Troupe.UI.TUI.State` into widgets.

  Pure: state and a frame in, `[{widget, rect}]` out, no I/O and no process. That is
  what lets the snapshot tests render a scene against a headless terminal without
  starting the app, which is the split ExRatatui's testing guide recommends.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.{Padding, Rect}
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, List, Paragraph}
  alias Troupe.UI.TUI.State

  @side_width 34
  @input_height 5

  # Below this there is not enough room for a bordered pane, and ratatui rejects the
  # rects a split would produce. A terminal really does report 0x0 — during a resize,
  # or on a pty whose size was never set — so this is a state to render, not an error.
  @min_width 20
  @min_height 6

  @doc "The whole screen for one frame."
  @spec scene(State.t(), ExRatatui.Frame.t()) :: [{struct(), Rect.t()}]
  def scene(%State{}, %{width: width, height: height})
      when width < @min_width or height < @min_height do
    if width < 1 or height < 1 do
      []
    else
      area = %Rect{x: 0, y: 0, width: width, height: height}
      [{%Paragraph{text: "terminal too small", wrap: true}, area}]
    end
  end

  def scene(%State{} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header, body, input] =
      Layout.split(area, :vertical, [{:length, 1}, {:min, 3}, {:length, @input_height}])

    {transcript_area, side_area} = split_body(body, frame.width)

    base =
      [
        {header_bar(state), header},
        {transcript(state), transcript_area},
        {input_box(state), input}
      ] ++ side_panels(state, side_area)

    base ++ overlay(state, area)
  end

  # Below ~90 columns the side panel costs more than it gives, so the transcript
  # takes the whole width and the task list moves into the header.
  defp split_body(body, width) when width < 90, do: {body, nil}

  defp split_body(body, _width) do
    [transcript, side] = Layout.split(body, :horizontal, [{:min, 20}, {:length, @side_width}])
    {transcript, side}
  end

  defp side_panels(_state, nil), do: []

  defp side_panels(state, side_area) do
    [todos_area, tree_area] =
      Layout.split(side_area, :vertical, [{:percentage, 50}, {:percentage, 50}])

    [{todo_panel(state), todos_area}, {agent_tree(state), tree_area}]
  end

  # -- header -----------------------------------------------------------------

  defp header_bar(state) do
    %Paragraph{
      text:
        Line.new([
          Span.new(" troupe ", style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]}),
          Span.new(" " <> state.profile, style: %Style{fg: :cyan, modifiers: [:bold]}),
          Span.new(" · " <> state_label(state.state), style: state_style(state.state)),
          Span.new(watch_label(state), style: %Style{fg: :dark_gray}),
          Span.new(
            " · Tab profile · Esc cancel · Ctrl-C twice quit",
            style: %Style{fg: :dark_gray}
          )
        ]),
      style: %Style{}
    }
  end

  # Agent states arrive as the strings a client sees on the wire, not as atoms: the
  # screen renders what the protocol says, including a state this build has never
  # heard of.
  defp state_label("idle"), do: "ready"
  defp state_label(nil), do: "ready"
  defp state_label(other), do: to_string(other)

  defp state_style("idle"), do: %Style{fg: :green}
  defp state_style(nil), do: %Style{fg: :green}
  defp state_style("done"), do: %Style{fg: :dark_gray}
  defp state_style(_), do: %Style{fg: :yellow, modifiers: [:bold]}

  defp watch_label(%State{watch?: true}), do: " · watch"
  defp watch_label(_), do: ""

  # -- transcript -------------------------------------------------------------

  defp transcript(state) do
    lines = state.transcript |> Enum.flat_map(&entry_lines(state, &1))

    %Paragraph{
      text: lines,
      wrap: true,
      scroll: {scroll_offset(state, length(lines)), 0},
      block: %Block{
        title: transcript_title(state),
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray},
        padding: Padding.symmetric(1, 0)
      }
    }
  end

  defp transcript_title(%State{focus: ["root"]}), do: " transcript "
  defp transcript_title(%State{focus: path}), do: " #{Enum.join(path, "/")} "

  # Following means pinning to the bottom; a user who scrolled up keeps their place.
  defp scroll_offset(%State{follow?: true}, _total), do: 0
  defp scroll_offset(%State{scroll: scroll}, _total), do: scroll

  defp entry_lines(_state, {:user, text, source}) do
    [
      Line.new([Span.new("")]),
      Line.new([
        Span.new(user_prefix(source), style: %Style{fg: :cyan, modifiers: [:bold]}),
        Span.new(text, style: %Style{modifiers: [:bold]})
      ])
    ]
  end

  defp entry_lines(_state, {:user, text}), do: entry_lines(nil, {:user, text, "user"})

  defp entry_lines(_state, {:assistant, text}) do
    text
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new(&1)]))
  end

  defp entry_lines(state, {:tool, tool}) do
    header =
      Line.new([
        Span.new(tool_marker(tool.status), style: tool_style(tool.status)),
        Span.new(tool.name <> " ", style: %Style{fg: :blue}),
        Span.new(summarise_args(tool.args), style: %Style{fg: :dark_gray})
      ])

    if State.expanded?(state, tool.call_id) do
      body =
        tool
        |> Map.get(:output, "")
        |> to_string()
        |> String.split("\n")
        |> Enum.take(40)
        |> Enum.map(&Line.new([Span.new("    " <> &1, style: %Style{fg: :dark_gray})]))

      [header | body]
    else
      [header]
    end
  end

  defp entry_lines(_state, {:delegation, delegation}) do
    [
      Line.new([
        Span.new("  ⇢ ", style: %Style{fg: :magenta}),
        Span.new(delegation.agent, style: %Style{fg: :magenta, modifiers: [:bold]}),
        Span.new(" " <> first_line(delegation.task), style: %Style{fg: :dark_gray})
      ])
    ]
  end

  defp entry_lines(_state, {:notice, message}) do
    [Line.new([Span.new("  · " <> message, style: %Style{fg: :dark_gray, modifiers: [:italic]})])]
  end

  defp user_prefix("watch"), do: "[watch] "
  defp user_prefix("tui_todo_edit"), do: "[tasks] "
  defp user_prefix(_), do: "› "

  defp tool_marker(:running), do: "  … "
  defp tool_marker(:ok), do: "  ✓ "
  defp tool_marker(:error), do: "  ✗ "

  defp tool_style(:running), do: %Style{fg: :yellow}
  defp tool_style(:ok), do: %Style{fg: :green}
  defp tool_style(:error), do: %Style{fg: :red}

  defp summarise_args(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{first_line(stringify(value))}" end)
    |> String.slice(0, 90)
  end

  defp summarise_args(_args), do: ""

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp first_line(text) when is_binary(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 70)
  end

  defp first_line(other), do: inspect(other)

  # -- side panels ------------------------------------------------------------

  defp todo_panel(state) do
    items =
      case state.todos do
        [] -> [Line.new([Span.new("no tasks yet", style: %Style{fg: :dark_gray})])]
        todos -> Enum.map(todos, &todo_line/1)
      end

    %List{
      items: items,
      block: %Block{
        title: " tasks ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  defp todo_line(todo) when is_map(todo) do
    status = Map.get(todo, "status", "pending")

    Line.new([
      Span.new(todo_marker(status), style: todo_style(status)),
      Span.new(Map.get(todo, "content", ""), style: todo_text_style(status))
    ])
  end

  defp todo_marker("in_progress"), do: "[~] "
  defp todo_marker("completed"), do: "[x] "
  defp todo_marker("cancelled"), do: "[-] "
  defp todo_marker(_), do: "[ ] "

  defp todo_style("in_progress"), do: %Style{fg: :yellow, modifiers: [:bold]}
  defp todo_style("completed"), do: %Style{fg: :green}
  defp todo_style("cancelled"), do: %Style{fg: :dark_gray}
  defp todo_style(_), do: %Style{fg: :white}

  defp todo_text_style("completed"), do: %Style{fg: :dark_gray, modifiers: [:crossed_out]}
  defp todo_text_style("cancelled"), do: %Style{fg: :dark_gray, modifiers: [:crossed_out]}
  defp todo_text_style(_), do: %Style{}

  defp agent_tree(state) do
    rows = State.agent_rows(state)

    items =
      case rows do
        [] -> [Line.new([Span.new("no agents", style: %Style{fg: :dark_gray})])]
        rows -> Enum.map(rows, &agent_line(state, &1))
      end

    %List{
      items: items,
      selected: state.selected_agent,
      highlight_style: %Style{bg: {:rgb, 40, 40, 40}, modifiers: [:bold]},
      highlight_symbol: "",
      block: %Block{
        title: " agents ",
        borders: [:all],
        border_type: :rounded,
        border_style: %Style{fg: :dark_gray}
      }
    }
  end

  defp agent_line(state, {path, agent}) do
    depth = length(path) - 1
    name = Elixir.List.last(path)

    Line.new([
      Span.new(String.duplicate("  ", depth)),
      Span.new(name <> " ", style: focus_style(state, path)),
      Span.new(state_label(Map.get(agent, "state")) <> " ",
        style: state_style(Map.get(agent, "state"))
      ),
      Span.new(State.budget_summary(agent), style: %Style{fg: :dark_gray})
    ])
  end

  defp focus_style(%State{focus: focus}, path) when focus == path do
    %Style{fg: :cyan, modifiers: [:bold]}
  end

  defp focus_style(_state, _path), do: %Style{}

  # -- input ------------------------------------------------------------------

  defp input_box(state) do
    %Paragraph{
      text: input_text(state),
      wrap: true,
      block: %Block{
        title: input_title(state),
        borders: [:all],
        border_type: :rounded,
        border_style: input_border(state),
        padding: Padding.horizontal(1)
      }
    }
  end

  defp input_text(%State{input: ""} = state) do
    Line.new([Span.new(placeholder(state), style: %Style{fg: :dark_gray})])
  end

  defp input_text(%State{input: input}) do
    Line.new([Span.new(input), Span.new("▏", style: %Style{fg: :cyan})])
  end

  defp placeholder(%State{quit_armed?: true}), do: "Ctrl-C again to quit"
  defp placeholder(_), do: "ask for something, /help for commands, @agent to address one"

  defp input_title(%State{quit_armed?: true}), do: " press Ctrl-C again to quit "
  defp input_title(_), do: " input "

  defp input_border(%State{quit_armed?: true}), do: %Style{fg: :red}
  defp input_border(_), do: %Style{fg: :cyan}

  # -- approval overlay -------------------------------------------------------

  defp overlay(%State{approvals: []}, _area), do: []

  defp overlay(%State{approvals: [approval | _]}, area) do
    popup_area = centred(area, min(area.width - 8, 92), min(area.height - 6, 24))

    [
      {%Clear{}, popup_area},
      {approval_popup(approval), popup_area}
    ]
  end

  # `Clear` underneath plus a bordered Paragraph, rather than the `Popup` widget:
  # the pair is the shape whose rendering is stable across ExRatatui versions, and
  # it reads identically.
  defp approval_popup(approval) do
    %Paragraph{
      text: approval_lines(approval),
      wrap: true,
      block: %Block{
        title: " approve #{approval.tool}? ",
        borders: [:all],
        border_type: :double,
        border_style: %Style{fg: :yellow},
        padding: Padding.uniform(1)
      }
    }
  end

  defp approval_lines(approval) do
    header = [
      Line.new([
        Span.new(Enum.join(approval.agent_path, "/"), style: %Style{fg: :magenta}),
        Span.new(" wants to run ", style: %Style{fg: :dark_gray}),
        Span.new(approval.tool, style: %Style{fg: :yellow, modifiers: [:bold]})
      ]),
      Line.new([Span.new("")])
    ]

    footer = [
      Line.new([Span.new("")]),
      Line.new([
        Span.new(" y ", style: %Style{fg: :black, bg: :green, modifiers: [:bold]}),
        Span.new(" allow    ", style: %Style{fg: :dark_gray}),
        Span.new(" a ", style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]}),
        Span.new(" allow for this session    ", style: %Style{fg: :dark_gray}),
        Span.new(" n ", style: %Style{fg: :black, bg: :red, modifiers: [:bold]}),
        Span.new(" deny", style: %Style{fg: :dark_gray})
      ])
    ]

    header ++ preview(approval) ++ footer
  end

  @doc """
  What an approval prompt shows: a diff for writes and edits, the command for shell.

  Public because it is the interesting part of the prompt and worth asserting on
  directly.
  """
  @spec preview(map()) :: [Line.t()]
  def preview(%{tool: "shell", args: args}) do
    args
    |> Map.get("command", "")
    |> String.split("\n")
    |> Enum.map(&Line.new([Span.new("  " <> &1, style: %Style{fg: :white})]))
  end

  def preview(%{tool: "write_file", args: args}) do
    path = Map.get(args, "path", "")
    content = Map.get(args, "content", "")

    [Line.new([Span.new("  " <> path, style: %Style{fg: :blue, modifiers: [:bold]})])] ++
      diff_lines(existing(path), content)
  end

  def preview(%{tool: "edit_file", args: args}) do
    [
      Line.new([
        Span.new("  " <> Map.get(args, "path", ""), style: %Style{fg: :blue, modifiers: [:bold]})
      ])
    ] ++
      diff_lines(Map.get(args, "old_string", ""), Map.get(args, "new_string", ""))
  end

  def preview(%{args: args}) do
    args
    |> Enum.sort()
    |> Enum.map(fn {key, value} ->
      Line.new([
        Span.new("  " <> key <> ": ", style: %Style{fg: :dark_gray}),
        Span.new(first_line(stringify(value)))
      ])
    end)
  end

  defp existing(_path), do: ""

  # A line-level diff: enough to see what changes without pulling in a diff library,
  # and the thing a reviewer actually reads before saying yes.
  defp diff_lines(old, new) do
    old_lines = String.split(old, "\n", trim: true)
    new_lines = String.split(new, "\n", trim: true)

    removed = Enum.reject(old_lines, &(&1 in new_lines))
    added = Enum.reject(new_lines, &(&1 in old_lines))

    Enum.map(Enum.take(removed, 12), fn line ->
      Line.new([Span.new("  - " <> line, style: %Style{fg: :red})])
    end) ++
      Enum.map(Enum.take(added, 12), fn line ->
        Line.new([Span.new("  + " <> line, style: %Style{fg: :green})])
      end)
  end

  defp centred(area, width, height) do
    %Rect{
      x: area.x + max(div(area.width - width, 2), 0),
      y: area.y + max(div(area.height - height, 2), 0),
      width: min(width, area.width),
      height: min(height, area.height)
    }
  end
end
