defmodule Troupe.UI.TUI.View do
  @moduledoc """
  Renders the TUI model into ExRatatui widgets: window strip, activated pane,
  status and command line. Transcript text is wrapped in Elixir (`Model.rows/4`)
  and handed to the renderer as pre-wrapped lines, so only the rows in view are
  built and nothing is ever clipped at the bottom.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Scrollbar}
  alias ExRatatui.Widgets.Block.Title
  alias Troupe.Settings
  alias Troupe.UI.TUI.Model

  @spec render(map(), ExRatatui.Frame.t()) :: [{term(), Rect.t()}]
  def render(%{focus: :settings} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    settings_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(%{focus: :observer} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    observer_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(state, frame) do
    windows = Model.windows(state.model)
    geometry = pane_geometry(state, {frame.width, frame.height})

    {strip_rect, _pane_rect, status_rect, cmd_rect} =
      layout(frame.width, frame.height, geometry != nil, length(windows))

    strip(windows, strip_rect, state) ++
      if(geometry, do: pane(geometry, state), else: []) ++
      [status(state, status_rect), command_line(state, cmd_rect)]
  end

  @doc """
  The vertical layout for a frame: `{strip, pane | nil, status, command}` rects.
  With a pane open the strip becomes a compact tray (at most 8 rows) so the
  transcript gets the screen.
  """
  @spec layout(non_neg_integer(), non_neg_integer(), boolean()) ::
          {Rect.t(), Rect.t() | nil, Rect.t(), Rect.t()}
  def layout(width, height, activated?), do: layout(width, height, activated?, 2)

  @spec layout(non_neg_integer(), non_neg_integer(), boolean(), non_neg_integer()) ::
          {Rect.t(), Rect.t() | nil, Rect.t(), Rect.t()}
  def layout(width, height, activated?, windows) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    constraints =
      if activated?,
        do: [{:length, tray_height(height, windows)}, {:fill, 1}, {:length, 1}, {:length, 3}],
        else: [{:fill, 1}, {:length, 1}, {:length, 3}]

    rects = Layout.split(area, :vertical, constraints)
    {strip_rect, rest} = List.pop_at(rects, 0)
    {pane_rect, rest} = if activated?, do: List.pop_at(rest, 0), else: {nil, rest}
    [status_rect, cmd_rect] = rest
    {strip_rect, pane_rect, status_rect, cmd_rect}
  end

  defp tray_height(_height, windows) when windows <= 1, do: 3
  defp tray_height(height, _windows), do: min(8, max(div(height, 5), 4))

  @doc false
  @spec page_constraints() :: [tuple()]
  def page_constraints, do: [{:fill, 1}, {:length, 1}, {:length, 3}]

  @doc "Splits the pane into the transcript and the side panel; below 100 columns there is no side panel."
  @spec pane_split(Rect.t()) :: {Rect.t(), Rect.t() | nil}
  def pane_split(%Rect{width: width} = rect) when width < 100, do: {rect, nil}

  def pane_split(%Rect{width: width} = rect) do
    side_w = width |> div(4) |> max(30) |> min(60)
    [left, right] = Layout.split(rect, :horizontal, [{:fill, 1}, {:length, side_w}])
    {left, right}
  end

  ## Pane geometry (shared by render and the Server's scroll keys)

  @typedoc """
  Everything needed to draw or scroll the activated pane: the rects, the
  blocks of logical lines with their row heights, the total, and the clamped
  offset (`follow?` when the view sits at the bottom).
  """
  @type geometry :: %{
          window: Model.window(),
          agent: String.t(),
          left: Rect.t(),
          side: Rect.t() | nil,
          inner_w: pos_integer(),
          inner_h: pos_integer(),
          blocks: [[Model.line()]],
          heights: [non_neg_integer()],
          entries: non_neg_integer(),
          total: non_neg_integer(),
          max_off: non_neg_integer(),
          offset: non_neg_integer(),
          follow?: boolean()
        }

  @doc "The activated pane's geometry at the size the server last saw, or nil when no window is activated."
  @spec pane_geometry(map()) :: geometry() | nil
  def pane_geometry(%{size: size} = state), do: pane_geometry(state, size)

  @spec pane_geometry(map(), {non_neg_integer(), non_neg_integer()}) :: geometry() | nil
  def pane_geometry(%{focus: {:window, path}} = state, {width, height}) do
    case Map.get(state.model.windows, path) do
      nil ->
        nil

      w ->
        {_strip, pane_rect, _status, _cmd} =
          layout(width, height, true, map_size(state.model.windows))

        {left, side} = pane_split(pane_rect)
        inner_w = max(left.width - 2, 1)
        inner_h = max(left.height - 2, 1)
        agent = viewed_agent(w, state.pane.agent)
        entries = length(Map.get(w.agents, agent, %{transcript: []}).transcript)
        blocks = Model.pane_blocks(w, agent, state.expanded, state.tick, state.now)
        heights = Enum.map(blocks, &Model.row_count(&1, inner_w))
        total = Enum.sum(heights)
        max_off = max(total - inner_h, 0)

        {offset, follow?} =
          case state.pane.scroll do
            :follow -> {follow_offset(blocks, heights, total, inner_h, max_off), true}
            n when is_integer(n) -> {min(n, max_off), n >= max_off}
          end

        %{
          window: w,
          agent: agent,
          left: left,
          side: side,
          inner_w: inner_w,
          inner_h: inner_h,
          blocks: blocks,
          heights: heights,
          entries: entries,
          total: total,
          max_off: max_off,
          offset: offset,
          follow?: follow?
        }
    end
  end

  def pane_geometry(_state, _size), do: nil

  # Following shows the end of the transcript — except when the last block is what the
  # branch is waiting on and it is taller than the pane: then its header (`APPROVAL: …`
  # and the diff's `--- path`) matters more than its last rows, so start at its top.
  defp follow_offset(blocks, heights, total, inner_h, max_off) do
    case {List.last(blocks), List.last(heights)} do
      {[{:blank, _}, {:pending, _} | _], h} when is_integer(h) and h > inner_h -> total - h + 1
      _ -> max_off
    end
  end

  defp viewed_agent(w, nil), do: w.path
  defp viewed_agent(w, agent), do: if(Map.has_key?(w.agents, agent), do: agent, else: w.path)

  @doc "Which block covers visual row `offset`, and the row within it: `{index, row}`."
  @spec block_at([non_neg_integer()], non_neg_integer()) :: {non_neg_integer(), non_neg_integer()}
  def block_at(heights, offset), do: block_at(heights, offset, 0)

  defp block_at([], _offset, idx), do: {max(idx - 1, 0), 0}
  defp block_at([h | _], offset, idx) when offset < h, do: {idx, offset}
  defp block_at([_only], offset, idx), do: {idx, offset}
  defp block_at([h | rest], offset, idx), do: block_at(rest, offset - h, idx + 1)

  ## Observer page

  @doc "The observer's rows and the clamped cursor, given the model and page state."
  @spec observer_view(map()) :: {[Model.row()], non_neg_integer()}
  def observer_view(state) do
    rows = Model.observer_rows(state.model)
    {rows, min(state.observer.cursor, max(length(rows) - 1, 0))}
  end

  defp observer_page(state, rect) do
    {rows, cursor} = observer_view(state)
    [tree_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    tree = %ExRatatui.Widgets.List{
      items: Enum.map(rows, &tree_line(&1, state)),
      selected: if(rows == [], do: nil, else: cursor),
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: " agents — #{observer_totals(rows)} ",
        borders: [:all],
        border_type: :double
      }
    }

    detail = %Paragraph{
      text: detail_text(Enum.at(rows, cursor), state),
      wrap: true,
      block: %Block{title: " detail — Enter opens this agent's transcript ", borders: [:all]}
    }

    [{tree, tree_rect}, {detail, detail_rect}]
  end

  defp observer_totals([]), do: "nothing running yet"

  defp observer_totals(rows) do
    by_state = Enum.frequencies_by(rows, &Model.agent_state/1)
    branches = rows |> Enum.count(& &1.root?)
    tokens = rows |> Enum.map(& &1.agent.tokens) |> Enum.sum()

    counts =
      [:needs_input, :thinking, :acting, :compacting, :delegating, :done]
      |> Enum.filter(&Map.has_key?(by_state, &1))
      |> Enum.map_join(" · ", &"#{Map.fetch!(by_state, &1)} #{&1}")

    "#{length(rows)} agents in #{branches} branches" <>
      if(counts == "", do: "", else: " · " <> counts) <> " · #{Model.tokens(%{tokens: tokens})}"
  end

  defp tree_line(row, state) do
    indent = String.duplicate("  ", row.depth)
    label = if row.root?, do: row.path, else: "↳ " <> (row.path |> String.split("/") |> List.last())
    name = row.agent.name || row.window.profile
    st = Model.agent_state(row)

    detail =
      case Model.running_tools(row.agent) do
        [] -> ""
        tools -> Enum.join(tools, ", ")
      end

    [
      String.pad_trailing(indent <> label, 22),
      String.pad_trailing("(#{name})", 10),
      String.pad_trailing(state_text(st, state.tick), 12),
      String.pad_trailing(Model.agent_elapsed(row, state.now), 6),
      String.pad_leading(Model.tokens(row.agent), 9),
      detail
    ]
    |> Enum.join(" ")
    |> String.trim_trailing()
  end

  defp state_text(:needs_input, tick), do: if(rem(tick, 2) == 0, do: "▶ you", else: "needs you")
  defp state_text(:done_unread, _), do: "done ●"
  defp state_text(:failed_unread, _), do: "failed ●"
  defp state_text(state, _), do: to_string(state)

  defp detail_text(nil, _state),
    do: "No agents yet.\n\nDispatch one from the command line, e.g. /code fix the failing test."

  defp detail_text(row, state) do
    w = row.window
    a = row.agent

    prompt =
      Enum.find_value(a.transcript, fn
        {:user, t} -> t
        _ -> nil
      end)

    ([
       "#{row.path}  (#{a.name || w.profile}#{if row.root?, do: "", else: " subagent"}, depth #{row.depth})",
       "",
       field("state", state_line(row)),
       field(
         "branch",
         "#{w.path} · #{w.state} · #{Model.elapsed(w, state.now)} · #{Model.tokens(w)}"
       ),
       field("isolation", isolation_text(w)),
       field("working in", Model.working_dir(w, state.model.workspace)),
       field("model", a.model || "(not called yet)"),
       field("tokens", Model.tokens(a)),
       field("running", Model.agent_elapsed(row, state.now)),
       present(prompt) && field("prompt", String.slice(prompt, 0, 300)),
       row.root? && present(w.summary) && field("summary", w.summary),
       row.root? && present(w.message) && field("failure", w.message),
       row.root? && present(w.diff_stat) && field("diff", w.diff_stat)
     ] ++ todo_block(a) ++ pending_block(w, row.path) ++ recent_block(a))
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp field(label, value), do: String.pad_trailing(label, 11) <> to_string(value)

  defp present(value), do: value not in [nil, ""]

  defp state_line(row) do
    st = Model.agent_state(row)

    case Model.running_tools(row.agent) do
      [] -> to_string(st)
      tools -> "#{st} · #{Enum.join(tools, ", ")}"
    end
  end

  defp isolation_text(%{isolation: :worktree, worktree: %{git_branch: b} = wt}) do
    "worktree #{b}" <>
      cond do
        Map.get(wt, :managed, true) == false -> " (yours; nothing committed)"
        Map.get(wt, :merged) -> " (merged)"
        Map.get(wt, :discarded) -> " (discarded)"
        true -> " (Troupe-managed)"
      end
  end

  defp isolation_text(%{isolation: :worktree}), do: "worktree (not created yet)"
  defp isolation_text(_), do: "shared checkout"

  defp todo_block(%{todos: []}), do: []

  defp todo_block(%{todos: todos}),
    do: ["", "tasks"] ++ Enum.map(todos, fn t -> "  [#{glyph(t.status)}] #{t.content}" end)

  defp pending_block(w, path) do
    case Enum.filter(w.pending, &(&1.agent_path == path)) do
      [] ->
        []

      pending ->
        ["", "waiting for you"] ++
          Enum.map(pending, fn
            %{kind: :approval, name: name} -> "  approval: #{name} (y / n / a in the window)"
            %{kind: :question, question: q} -> "  question: #{q}"
          end)
    end
  end

  defp recent_block(agent) do
    case agent.transcript |> Enum.filter(&match?({:tool, _}, &1)) |> Enum.take(-6) do
      [] ->
        []

      tools ->
        ["", "recent tool calls"] ++
          Enum.map(tools, fn {:tool, t} -> "  " <> Model.tool_head(t) end)
    end
  end

  ## Settings page

  defp settings_page(state, rect) do
    %{settings: s} = state
    [list_rect, help_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    items =
      Enum.map(Settings.fields(), fn field ->
        value = Settings.format(s.config, field.key)
        "#{String.pad_trailing(field.label, 26)} #{value}"
      end)

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: s.cursor,
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: " settings — #{Settings.target_path(state.model.workspace)} ",
        borders: [:all],
        border_type: :double
      }
    }

    right = if s.picker, do: picker_list(state, help_rect), else: help_paragraph(state)
    [{list, list_rect}, {right, help_rect}]
  end

  # The menu for a setting that has one: every model Troupe found, plus a way out
  # to typing one it did not.
  defp picker_list(%{settings: %{picker: p}}, rect) do
    # "▸ " takes two columns of the block's interior, and a note that would not fit
    # drops back a form rather than being clipped mid-word.
    width = max(rect.width - 4, 20)
    label_w = p.choices |> Enum.map(&Model.cell_width(&1.label)) |> Enum.max(fn -> 0 end)
    room = width - label_w - 2

    items =
      Enum.map(p.choices, fn c ->
        String.trim_trailing(String.pad_trailing(c.label, label_w) <> "  " <> note(c, room))
      end) ++ ["type one instead…"]

    %ExRatatui.Widgets.List{
      items: items,
      selected: min(p.cursor, length(items) - 1),
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: " #{length(p.choices)} models detected — Enter picks · Esc back ",
        borders: [:all]
      }
    }
  end

  defp note(choice, room),
    do: Enum.find(choice.notes, "", &(Model.cell_width(&1) <= room))

  defp help_paragraph(%{settings: s}) do
    field = Enum.at(Settings.fields(), s.cursor)

    head =
      [
        field.label <> "  (" <> field.key <> ")",
        String.duplicate("─", String.length(field.label) + String.length(field.key) + 4),
        effect_line(field.effect),
        ""
      ] ++ String.split(String.trim_trailing(field.help), "\n") ++ [""]

    %Paragraph{
      text: Enum.join(head ++ Settings.help_lines(), "\n"),
      wrap: true,
      scroll: {s.scroll, 0},
      block: %Block{title: " help — PgUp/PgDn or the wheel scrolls ", borders: [:all]}
    }
  end

  defp settings_command_line(%{settings: %{picker: p} = s}) when p != nil do
    {s.status || "",
     " choose a model — ↑↓ move · Enter picks · Esc back · `troupe config` lists them all "}
  end

  defp settings_command_line(%{settings: %{editing: nil} = s}) do
    hint =
      case Enum.at(Settings.fields(), s.cursor) do
        %{type: :bool} -> "Enter/Space toggles"
        %{type: :model} -> "Enter opens the model menu"
        _ -> "Enter edits"
      end

    {s.status || "", " settings — ↑↓ move · #{hint} · Esc back "}
  end

  defp settings_command_line(%{settings: %{editing: text} = s}) do
    field = Enum.at(Settings.fields(), s.cursor)
    {text <> "▏", " " <> (s.status || "#{field.key} = (Enter saves, Esc cancels)") <> " "}
  end

  defp effect_line(:now), do: "applies immediately"
  defp effect_line(:new_branches), do: "applies to branches dispatched from now on"

  @doc "Rects of the (at most nine) tiles in the strip, in window order."
  @spec tile_rects(Rect.t(), non_neg_integer()) :: [Rect.t()]
  def tile_rects(_strip, 0), do: []

  def tile_rects(strip, n),
    do: Layout.split(strip, :horizontal, Enum.map(1..min(n, 9), fn _ -> {:fill, 1} end))

  ## Window strip

  defp strip([], rect, state) do
    text =
      "No branches. Type a command: " <>
        Enum.map_join(state.commands, "  ", &("/" <> &1)) <> "  /help"

    [{%Paragraph{text: text, style: %Style{fg: :dark_gray}, wrap: true}, rect}]
  end

  defp strip(windows, rect, state) do
    shown = Enum.take(windows, 9)
    rects = tile_rects(rect, length(shown))

    shown
    |> Enum.with_index(1)
    |> Enum.zip(rects)
    |> Enum.map(fn {{w, n}, r} -> window_tile(w, n, r, state) end)
  end

  defp window_tile(w, n, rect, state) do
    inner_w = max(rect.width - 2, 1)
    inner_h = max(rect.height - 2, 1)
    focused? = state.focus == {:window, w.path}

    # Every tile keeps showing its own tail, the focused one included: while you read back
    # through the pane, its tile is where the newest output still shows up.
    rows =
      w
      |> Model.tile_lines(state.tick, state.now, inner_h > 3)
      |> Model.tail_rows(inner_w, inner_h)

    %Paragraph{
      text: styled(rows),
      wrap: false,
      style: text_style(w),
      block: %Block{
        title: tile_title(w, n, state, inner_w),
        borders: [:all],
        border_type: if(focused?, do: :double, else: :rounded),
        border_style: border_style(w, state)
      }
    }
    |> then(&{&1, rect})
  end

  defp tile_title(w, n, state, inner_w) do
    badge = if w.badge, do: " ●", else: ""
    blink = if w.state == :needs_input and rem(state.tick, 2) == 0, do: " ▶ needs input", else: ""
    stats = " · #{Model.elapsed(w, state.now)} · #{Model.tokens(w)}"

    [
      " #{n} #{w.path} · #{w.state}#{badge}#{blink}#{stats} ",
      " #{n} #{w.path} · #{w.state}#{badge}#{blink} ",
      " #{n} #{w.path} · #{w.state}#{badge} ",
      " #{n} #{w.path} · #{state_glyph(w, state)}#{badge} ",
      " #{n} #{state_glyph(w, state)}#{badge} "
    ]
    |> fit(inner_w)
  end

  # The tray's tiles are narrow; a glyph still says whether a branch wants you.
  defp state_glyph(%{state: :needs_input}, _state), do: "▶"
  defp state_glyph(%{state: :done_unread}, _state), do: "✓"
  defp state_glyph(%{state: :failed_unread}, _state), do: "✗"
  defp state_glyph(_w, state), do: Enum.at(Model.spinner_glyphs(), rem(state.tick, 10))

  # The widest candidate that fits, or the narrowest when none does.
  defp fit(candidates, width) do
    Enum.find(candidates, List.last(candidates), &(Model.cell_width(&1) <= width))
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

  defp pane(g, state) do
    w = g.window
    rows = g.blocks |> Enum.concat() |> Model.rows(g.inner_w, g.offset, g.inner_h)

    transcript = %Paragraph{
      text: styled(rows),
      wrap: false,
      block: %Block{
        title: pane_title(w, g.agent),
        titles: [
          %Title{content: scroll_title(g, state), alignment: :right},
          %Title{content: hint_title(g, state), position: :bottom}
        ],
        borders: [:all]
      }
    }

    scrollbar =
      if g.total > g.inner_h do
        [
          {%Scrollbar{
             content_length: g.total,
             position: g.offset,
             viewport_content_length: g.inner_h,
             thumb_style: %Style{fg: :dark_gray},
             track_style: %Style{fg: :dark_gray}
           }, %Rect{x: g.left.x + g.left.width - 1, y: g.left.y + 1, width: 1, height: g.inner_h}}
        ]
      else
        []
      end

    side =
      if g.side do
        inner_w = max(g.side.width - 2, 1)
        lines = side_lines(w, g.agent)

        [
          {%Paragraph{
             text: styled(Model.rows(lines, inner_w, 0, max(g.side.height - 2, 1))),
             wrap: false,
             block: %Block{title: " tasks · agents · pending ", borders: [:all]}
           }, g.side}
        ]
      else
        []
      end

    [{transcript, g.left}] ++ scrollbar ++ side
  end

  defp pane_title(w, agent) when agent == w.path, do: " #{w.path} (#{w.profile}) — Esc back "

  defp pane_title(w, agent) do
    name = get_in(w.agents, [agent, :name]) || "subagent"
    " #{w.path} › #{String.replace_prefix(agent, w.path <> "/", "")} (#{name}) — Esc back "
  end

  defp scroll_title(%{follow?: true}, _state), do: " ⇣ following "

  defp scroll_title(g, state) do
    new = g.entries - state.pane.seen_entries
    last = min(g.offset + g.inner_h, g.total)

    " ↕ #{g.offset + 1}–#{last}/#{g.total}" <>
      if(new > 0, do: " · #{new} new", else: "") <> " "
  end

  # Context keys on the bottom border: the widest phrasing that fits, and only the keys
  # that do something right now. `End` stays in every form — once you have scrolled up it
  # is the one key you need.
  defp hint_title(g, state) do
    w = g.window
    agents = length(Model.agent_paths(w))
    approval? = Enum.any?(w.pending, &(&1.kind == :approval))
    verb = if state.expanded, do: "collapses", else: "expands"

    pieces = [
      {true, ["PgUp/PgDn ↑↓ scroll", "PgUp/PgDn scroll", "PgUp/PgDn"]},
      {not g.follow?, ["End follows the tail", "End follows", "End"]},
      {agents > 1, ["←→ other agents", "←→ agents", "←→"]},
      {true, ["e #{verb} output", "e #{verb}", "e"]},
      {approval?, ["y/n/a approve", "y/n/a", "y/n/a"]},
      {w.state in [:running, :needs_input], ["x cancel & remove", "x cancel", "x"]},
      {w.state in [:done_unread, :failed_unread], ["d dismiss", "d dismiss", "d"]},
      {true, ["Tab profile", nil, nil]}
    ]

    0..2
    |> Enum.map(fn tier ->
      pieces
      |> Enum.flat_map(fn {applies?, forms} ->
        label = Enum.at(forms, tier)
        if applies? and label, do: [label], else: []
      end)
      |> then(&(" " <> Enum.join(&1, " · ") <> " "))
    end)
    |> fit(g.left.width - 2)
  end

  ## Styling

  @muted %Style{fg: :dark_gray}

  defp styled([]), do: ""
  defp styled(rows), do: Enum.map(rows, &styled_row/1)

  # A row is its kind's segments: each one carries either a tag the view maps to
  # a style, or a style of its own (syntax highlighting).
  defp styled_row({kind, text}) when is_binary(text), do: styled_row({kind, [{kind, text}]})

  defp styled_row({kind, segments}) do
    Line.new(
      for {tag, text} <- segments,
          text != "",
          do: Span.new(text, style: segment_style(tag, kind, text))
    )
  end

  defp segment_style(%Style{} = style, _kind, _text), do: style
  defp segment_style(:muted, _kind, _text), do: @muted
  defp segment_style(:code_rail, _kind, _text), do: @muted
  defp segment_style(:quote_rail, _kind, _text), do: @muted
  defp segment_style(:linenum, _kind, _text), do: @muted
  defp segment_style(:code_lang, _kind, _text), do: %Style{fg: :magenta}
  defp segment_style(:code_inline, _kind, _text), do: %Style{fg: :magenta}
  defp segment_style(:strong, _kind, _text), do: %Style{modifiers: [:bold]}
  defp segment_style(:heading, _kind, _text), do: %Style{fg: :cyan, modifiers: [:bold]}
  defp segment_style(:bullet_marker, _kind, _text), do: %Style{fg: :cyan}
  defp segment_style(:quote, _kind, _text), do: %Style{modifiers: [:dim]}
  defp segment_style(:system, _kind, _text), do: %Style{modifiers: [:dim]}
  defp segment_style(:pending, _kind, _text), do: %Style{fg: :yellow, modifiers: [:bold]}
  defp segment_style(:diff_add, _kind, _text), do: %Style{fg: :green}
  defp segment_style(:diff_del, _kind, _text), do: %Style{fg: :red}
  defp segment_style(:diff_meta, _kind, _text), do: %Style{fg: :cyan, modifiers: [:dim]}
  defp segment_style(:user_marker, _kind, _text), do: %Style{fg: :cyan, modifiers: [:bold]}
  defp segment_style(:activity_glyph, _kind, _text), do: %Style{fg: :yellow}
  defp segment_style(:activity, _kind, _text), do: %Style{fg: :yellow, modifiers: [:dim]}
  defp segment_style(:tool_glyph, _kind, text), do: glyph_style(text)
  defp segment_style(:tool_name, _kind, _text), do: %Style{modifiers: [:bold]}
  defp segment_style(:tool_note, _kind, _text), do: @muted

  # A wrapped tool head's later rows have no glyph to key off: draw them dim.
  defp segment_style(kind, kind, _text) when kind in [:tool_ok, :tool_err, :tool_running],
    do: %Style{modifiers: [:dim]}

  defp segment_style(_tag, _kind, _text), do: %Style{}

  defp glyph_style("✓"), do: %Style{fg: :green}
  defp glyph_style("✗"), do: %Style{fg: :red, modifiers: [:bold]}
  defp glyph_style(_), do: %Style{fg: :yellow}

  ## Side panel

  defp side_lines(w, viewed) do
    todos = todo_lines(w, w.path, "")
    paths = Model.agent_paths(w)

    agents =
      if length(paths) > 1 do
        [{:blank, ""}, {:system, "Agents (←→ to view):"}] ++
          Enum.flat_map(paths, fn p ->
            depth = length(String.split(p, "/")) - 1
            indent = String.duplicate("  ", depth)
            mark = if p == viewed, do: "▸ ", else: "  "
            label = if p == w.path, do: p, else: "↳ " <> (p |> String.split("/") |> List.last())
            agent = Map.fetch!(w.agents, p)
            row = %{window: w, path: p, agent: agent, depth: depth, root?: p == w.path}
            kind = if p == viewed, do: :user, else: :text

            [
              {kind,
               "#{mark}#{indent}#{label} (#{agent.name || w.profile}) #{Model.agent_state(row)}"}
            ] ++ if(p == w.path, do: [], else: todo_lines(w, p, indent <> "    "))
          end)
      else
        []
      end

    pending =
      case w.pending do
        [] ->
          []

        items ->
          [{:blank, ""}, {:system, "Waiting for you:"}] ++
            Enum.map(items, fn
              %{kind: :approval, name: name} -> {:pending, "  approval: #{name} — y / n / a"}
              %{kind: :question, question: q} -> {:pending, "  question: #{q} — type and Enter"}
            end)
      end

    [{:system, "Tasks:"}] ++
      if(todos == [], do: [{:text, "  (none)"}], else: todos) ++
      agents ++ pending
  end

  defp todo_lines(w, path, indent) do
    w.agents
    |> Map.get(path, %{todos: []})
    |> Map.get(:todos, [])
    |> Enum.map(fn t -> {:text, "#{indent}[#{glyph(t.status)}] #{t.content}"} end)
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

    hint =
      case Enum.find_index(Model.windows(state.model), &(&1.state == :needs_input)) do
        nil -> ""
        i -> " · press #{i + 1} (or Enter, or click the window) to answer"
      end

    text =
      "#{Model.attention_summary(state.model)}#{hint} · #{watch} · #{state.session_id}" <>
        if(notice, do: " · #{notice}", else: "")

    text =
      if state.quit_armed,
        do: text <> " · PRESS CTRL-C AGAIN TO QUIT",
        else: text <> " · /help for settings and help · /quit or Ctrl-C twice exits"

    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, rect}
  end

  defp command_line(state, rect) do
    {text, title} =
      case state.focus do
        :command ->
          {"/" <> state.cmd_text <> "▏", " command "}

        {:window, path} ->
          target = if state.pane.agent in [nil, path], do: "", else: " to the branch root"
          {state.win_text <> "▏", " → #{path} (Enter sends#{target}, Esc back) "}

        :settings ->
          settings_command_line(state)

        :observer ->
          {"", " agents — ↑↓ move · Enter opens the agent · Esc back "}
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
