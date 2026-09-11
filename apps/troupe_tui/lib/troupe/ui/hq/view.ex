defmodule Troupe.UI.HQ.View do
  @moduledoc """
  Turning `Troupe.UI.HQ.State` into widgets.

  Pure, like the session view: state and a frame in, `[{widget, rect}]` out. Two
  panes — what is running, and what is waiting on a person — because those are the
  two questions someone opens HQ to answer.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.{Padding, Rect}
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, List, Paragraph}
  alias Troupe.UI.HQ.State

  @min_width 20
  @min_height 6

  @doc "The whole screen for one frame."
  @spec scene(State.t(), ExRatatui.Frame.t()) :: [{struct(), Rect.t()}]
  def scene(%State{}, %{width: width, height: height})
      when width < @min_width or height < @min_height do
    if width < 1 or height < 1 do
      []
    else
      [{%Paragraph{text: "terminal too small", wrap: true}, %Rect{x: 0, y: 0, width: width, height: height}}]
    end
  end

  def scene(%State{} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}

    [header, body, footer] =
      Layout.split(area, :vertical, [{:length, 1}, {:min, 4}, {:length, 3}])

    [sessions_area, approvals_area] = split_body(body, frame.width)

    [
      {header_bar(state), header},
      {sessions_panel(state), sessions_area},
      {approvals_panel(state), approvals_area},
      {detail(state), footer}
    ]
  end

  # Below ~90 columns the panes stack, because two 40-column lists of paths are two
  # columns of ellipses.
  defp split_body(body, width) when width < 90 do
    Layout.split(body, :vertical, [{:percentage, 50}, {:percentage, 50}])
  end

  defp split_body(body, _width) do
    Layout.split(body, :horizontal, [{:percentage, 50}, {:percentage, 50}])
  end

  defp header_bar(state) do
    waiting = length(state.approvals)

    %Paragraph{
      text:
        Line.new([
          Span.new(" troupe hq ", style: %Style{fg: :black, bg: :magenta, modifiers: [:bold]}),
          Span.new(" #{map_size(state.sessions)} sessions", style: %Style{fg: :cyan}),
          Span.new(waiting_label(waiting), style: waiting_style(waiting)),
          Span.new(" · ↑↓ select · y allow · a session · n deny · q quit",
            style: %Style{fg: :dark_gray}
          )
        ])
    }
  end

  defp waiting_label(0), do: " · nothing waiting"
  defp waiting_label(1), do: " · 1 approval waiting"
  defp waiting_label(n), do: " · #{n} approvals waiting"

  defp waiting_style(0), do: %Style{fg: :dark_gray}
  defp waiting_style(_), do: %Style{fg: :yellow, modifiers: [:bold]}

  defp sessions_panel(state) do
    items =
      case State.sessions(state) do
        [] -> [Line.new([Span.new("no sessions", style: %Style{fg: :dark_gray})])]
        sessions -> Enum.map(sessions, &session_line(state, &1))
      end

    %List{
      items: items,
      block: bordered(" sessions ")
    }
  end

  defp session_line(state, session) do
    id = session["id"]
    pending = Enum.count(state.approvals, &(&1.session_id == id))

    Line.new([
      Span.new(marker(pending), style: %Style{fg: :yellow, modifiers: [:bold]}),
      Span.new(short(id) <> " ", style: %Style{fg: :cyan}),
      Span.new(to_string(session["state"] || "active") <> " ", style: state_style(session["state"])),
      Span.new(basename(session["workspace"]), style: %Style{fg: :dark_gray})
    ])
  end

  defp marker(0), do: "  "
  defp marker(_), do: "? "

  defp state_style("active"), do: %Style{fg: :green}
  defp state_style("dormant"), do: %Style{fg: :dark_gray}
  defp state_style(_), do: %Style{fg: :white}

  defp approvals_panel(state) do
    items =
      case state.approvals do
        [] -> [Line.new([Span.new("nothing waiting", style: %Style{fg: :dark_gray})])]
        approvals -> Enum.map(approvals, &approval_line/1)
      end

    %List{
      items: items,
      selected: state.selected,
      highlight_style: %Style{bg: {:rgb, 40, 40, 40}, modifiers: [:bold]},
      highlight_symbol: "› ",
      block: bordered(" approvals ")
    }
  end

  defp approval_line(approval) do
    Line.new([
      Span.new(approval.tool <> " ", style: %Style{fg: :yellow, modifiers: [:bold]}),
      Span.new(short(approval.session_id) <> " ", style: %Style{fg: :cyan}),
      Span.new(Enum.join(approval.agent_path, "/"), style: %Style{fg: :dark_gray})
    ])
  end

  # The footer is where the decision actually gets made, so it shows the thing being
  # approved rather than a count of things being approved.
  defp detail(state) do
    text =
      case State.selected_approval(state) do
        nil -> [Line.new([Span.new(last_notice(state), style: %Style{fg: :dark_gray})])]
        approval -> summarise(approval)
      end

    %Paragraph{text: text, wrap: true, block: bordered(" detail ")}
  end

  defp last_notice(%State{notices: []}), do: "nothing waiting on you"
  defp last_notice(%State{notices: [notice | _]}), do: notice

  defp summarise(approval) do
    [
      Line.new([
        Span.new(approval.tool <> " ", style: %Style{fg: :yellow, modifiers: [:bold]}),
        Span.new(args_summary(approval.args), style: %Style{})
      ])
    ]
  end

  defp args_summary(args) when is_map(args) do
    args
    |> Enum.sort()
    |> Enum.map_join("  ", fn {key, value} -> "#{key}=#{first_line(value)}" end)
    |> String.slice(0, 300)
  end

  defp args_summary(_args), do: ""

  defp first_line(value) when is_binary(value) do
    value |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 120)
  end

  defp first_line(value), do: inspect(value)

  defp bordered(title) do
    %Block{
      title: title,
      borders: [:all],
      border_type: :rounded,
      border_style: %Style{fg: :dark_gray},
      padding: Padding.horizontal(1)
    }
  end

  # Session ids are timestamped and long; the tail is the part that differs.
  defp short(nil), do: "(unknown)"

  defp short(id) do
    if String.length(id) > 16, do: "…" <> String.slice(id, -15, 15), else: id
  end

  defp basename(nil), do: ""
  defp basename(path), do: Path.basename(path)
end
