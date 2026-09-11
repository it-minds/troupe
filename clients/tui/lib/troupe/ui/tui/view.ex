defmodule Troupe.UI.TUI.View do
  @moduledoc "Renders the TUI model into ExRatatui widgets: window strip, activated pane, status and command line."

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Troupe.UI.TUI.Model

  @spec render(map(), ExRatatui.Frame.t()) :: [{term(), Rect.t()}]
  def render(state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    windows = Model.windows(state.model)
    activated = activated_window(state)

    constraints =
      [{:fill, 1}] ++
        if(activated, do: [{:fill, 2}], else: []) ++
        [{:length, 1}, {:length, 3}]

    rects = Layout.split(area, :vertical, constraints)
    {strip_rect, rest} = List.pop_at(rects, 0)
    {pane_rect, rest} = if activated, do: List.pop_at(rest, 0), else: {nil, rest}
    [status_rect, cmd_rect] = rest

    strip(windows, strip_rect, state) ++
      if(activated, do: pane(activated, pane_rect, state), else: []) ++
      [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp activated_window(%{focus: {:window, path}, model: model}), do: Map.get(model.windows, path)
  defp activated_window(_), do: nil

  ## Window strip

  defp strip([], rect, state) do
    text = "No branches. Type a command: " <> Enum.map_join(state.commands, "  ", &("/" <> &1))
    [{%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true}, rect}]
  end

  defp strip(windows, rect, state) do
    shown = Enum.take(windows, 9)
    rects = Layout.split(rect, :horizontal, Enum.map(shown, fn _ -> {:fill, 1} end))

    shown
    |> Enum.with_index(1)
    |> Enum.zip(rects)
    |> Enum.map(fn {{w, n}, r} -> window_tile(w, n, r, state) end)
  end

  defp window_tile(w, n, rect, state) do
    agent = Map.get(w.agents, w.path, %{transcript: [], streaming: "", todos: []})
    inner_h = max(rect.height - 2, 1)
    lines = agent |> Model.transcript_lines(false) |> Enum.take(-inner_h)
    focused? = state.focus == {:window, w.path}

    %Paragraph{
      text: Enum.join(lines, "\n"),
      wrap: true,
      style: text_style(w),
      block: %Block{
        title: title(w, n, state),
        borders: [:all],
        border_type: if(focused?, do: :double, else: :rounded),
        border_style: border_style(w, state)
      }
    }
    |> then(&{&1, rect})
  end

  defp title(w, n, state) do
    badge = if w.badge, do: " ●", else: ""
    blink = if w.state == :needs_input and rem(state.tick, 2) == 0, do: " ▶ needs input", else: ""

    " #{n} #{w.path} · #{w.state}#{badge}#{blink} · #{Model.elapsed(w, state.now)} · #{Model.tokens(w)} "
  end

  defp border_style(%{state: :needs_input}, state) do
    if rem(state.tick, 2) == 0,
      do: %Style{fg: :yellow, modifiers: [:bold]},
      else: %Style{fg: :dark_gray}
  end

  defp border_style(%{state: :running}, _), do: %Style{fg: :cyan}

  defp border_style(%{state: :done_unread, badge: true}, _),
    do: %Style{fg: :green, modifiers: [:bold]}

  defp border_style(%{state: :done_unread}, _), do: %Style{fg: :dark_gray, modifiers: [:dim]}

  defp border_style(%{state: :failed_unread, badge: true}, _),
    do: %Style{fg: :red, modifiers: [:bold]}

  defp border_style(%{state: :failed_unread}, _), do: %Style{fg: :dark_gray, modifiers: [:dim]}
  defp border_style(_, _), do: %Style{}

  defp text_style(%{state: s}) when s in [:done_unread, :failed_unread],
    do: %Style{modifiers: [:dim]}

  defp text_style(_), do: %Style{}

  ## Activated pane

  defp pane(w, rect, state) do
    [left, right] = Layout.split(rect, :horizontal, [{:fill, 3}, {:fill, 1}])

    transcript =
      w.agents
      |> Map.get(w.path, %{transcript: [], streaming: "", todos: []})
      |> Model.transcript_lines(state.expanded)

    inner_h = max(left.height - 2, 1)
    tail = Enum.take(transcript, -inner_h)

    left_widget = %Paragraph{
      text: Enum.join(tail, "\n"),
      wrap: true,
      block: %Block{
        title:
          " #{w.path} (#{w.profile}) — Esc back · y/n/a approve · x cancel · d dismiss · Tab profile ",
        borders: [:all]
      }
    }

    [
      {left_widget, left},
      {%Paragraph{
         text: side_text(w),
         wrap: true,
         block: %Block{title: " tasks · agents · pending ", borders: [:all]}
       }, right}
    ]
  end

  defp side_text(w) do
    todos = todo_lines(w, w.path, "")

    children =
      w.agents
      |> Map.keys()
      |> Enum.reject(&(&1 == w.path))
      |> Enum.sort()
      |> Enum.flat_map(fn child ->
        depth = length(String.split(child, "/")) - 1
        indent = String.duplicate("  ", depth)

        [
          "#{indent}↳ #{child |> String.split("/") |> List.last()}"
          | todo_lines(w, child, indent <> "  ")
        ]
      end)

    pending =
      Enum.flat_map(w.pending, fn
        %{kind: :approval, name: name, preview: preview} ->
          [
            "",
            "APPROVAL: #{name} (y allow / n deny / a allow for session)"
            | String.split(preview || "", "\n")
          ]

        %{kind: :question, question: q} ->
          ["", "QUESTION: #{q}", "type your answer and press Enter"]
      end)

    (["Tasks:"] ++ if(todos == [], do: ["  (none)"], else: todos) ++ children ++ pending)
    |> Enum.join("\n")
  end

  defp todo_lines(w, path, indent) do
    w.agents
    |> Map.get(path, %{todos: []})
    |> Map.get(:todos, [])
    |> Enum.map(fn t -> "#{indent}[#{glyph(t.status)}] #{t.content}" end)
  end

  defp glyph(:completed), do: "x"
  defp glyph(:in_progress), do: ">"
  defp glyph(:cancelled), do: "-"
  defp glyph(_), do: " "

  ## Status and command line

  defp status(state, rect) do
    watch =
      case state.model.watch do
        %{enabled: true, backend: b} -> "watch: #{b}"
        _ -> "watch: off"
      end

    notice = List.first(state.model.notices)

    text =
      "#{Model.attention_summary(state.model)} · #{watch} · #{state.session_id}" <>
        if(notice, do: " · #{notice}", else: "")

    text =
      if state.quit_armed,
        do: text <> " · PRESS CTRL-C AGAIN TO QUIT",
        else: text <> " · /quit or Ctrl-C twice exits"

    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, rect}
  end

  defp command_line(state, rect) do
    {text, title} =
      case state.focus do
        :command -> {"/" <> state.cmd_text <> "▏", " command "}
        {:window, path} -> {state.win_text <> "▏", " → #{path} (Enter sends, Esc back) "}
      end

    focused_cmd? = state.focus == :command

    {%Paragraph{
       text: text,
       block: %Block{
         title: title,
         borders: [:all],
         border_style: %Style{fg: if(focused_cmd?, do: :white, else: :dark_gray)}
       }
     }, rect}
  end
end
