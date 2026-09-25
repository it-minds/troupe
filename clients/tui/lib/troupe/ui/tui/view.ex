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
  alias Troupe.Client
  alias Troupe.Settings
  alias Troupe.UI.TUI.{Input, Model}

  # Command-box geometry. The focused box — the command line and an active
  # window's input — is a fixed `@input_rows` console rows: `@input_content`
  # rows to write in plus the two borders, so the box never jumps under the
  # typist and there is room to see what a long input actually says. Past that
  # it scrolls around the cursor rather than growing (Decision 88). The pages
  # (settings, sessions, files, HQ) keep the one-row `@cmd_rows` footer.
  @cmd_rows 3
  @input_content 5
  @input_rows @input_content + 2

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

  def render(%{focus: :sessions} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    sessions_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(%{focus: :hq} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())

    Troupe.UI.HQ.render(state.hq, page_rect, state) ++
      [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(%{focus: :files} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    files_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(%{focus: :mcp} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    mcp_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  def render(state, frame) do
    windows = Model.windows(state.model)
    geometry = pane_geometry(state, {frame.width, frame.height})
    cmd_rows = box_height(frame.height)

    {strip_rect, _pane_rect, status_rect, cmd_rect} =
      layout(frame.width, frame.height, geometry != nil, length(windows), cmd_rows)

    strip(windows, strip_rect, state) ++
      if(geometry, do: pane(geometry, state), else: []) ++
      [status(state, status_rect), command_line(state, cmd_rect, cmd_rows)]
  end

  @doc """
  The vertical layout for a frame: `{strip, pane | nil, status, command}` rects.
  With a pane open the strip becomes a compact tray (at most 8 rows) so the
  transcript gets the screen. `cmd_rows` sets the command box height; callers
  hand in `box_height/1` so the pane leaves room for the input box.
  """
  @spec layout(non_neg_integer(), non_neg_integer(), boolean(), non_neg_integer(), pos_integer()) ::
          {Rect.t(), Rect.t() | nil, Rect.t(), Rect.t()}
  def layout(width, height, activated?, windows \\ 2, cmd_rows \\ @cmd_rows) do
    area = %Rect{x: 0, y: 0, width: width, height: height}

    constraints =
      if activated?,
        do: [{:length, tray_height(height, windows)}, {:fill, 1}, {:length, 1}, {:length, cmd_rows}],
        else: [{:fill, 1}, {:length, 1}, {:length, cmd_rows}]

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
          layout(width, height, true, map_size(state.model.windows), box_height(height))

        {left, side} = pane_split(pane_rect)
        inner_w = max(left.width - 2, 1)
        inner_h = max(left.height - 2, 1)
        agent = viewed_agent(w, state.pane.agent)
        entries = length(Map.get(w.agents, agent, %{transcript: []}).transcript)
        blocks = Model.pane_blocks(w, agent, state.expanded, state.tick, state.now, state.answer)
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

  @doc """
  Maps a screen cell to a transcript coordinate: `{visual_row, cell_col}` where
  the row is absolute (`offset` plus the row within the view) so it survives new
  output and scrolling, and the column is a cell offset into that wrapped row.
  `nil` when the cell is outside the transcript's interior — the borders, the
  side panel, and the last inner column, where the scrollbar rides.
  """
  @spec pane_point(geometry(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def pane_point(g, x, y) do
    top = g.left.y + 1
    left = g.left.x + 1

    if x >= left and x < left + g.inner_w and y >= top and y < top + g.inner_h,
      do: {g.offset + (y - top), x - left},
      else: nil
  end

  @doc "Which way a drag at screen row `y` wants the pane to scroll, or nil while it is inside."
  @spec pane_edge(geometry(), non_neg_integer()) :: :above | :below | nil
  def pane_edge(g, y) do
    top = g.left.y + 1

    cond do
      y < top -> :above
      y >= top + g.inner_h -> :below
      true -> nil
    end
  end

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
    usage = rows |> Enum.map(& &1.agent.usage) |> Enum.reduce(Model.empty_usage(), &Model.add/2)

    counts =
      [:needs_input, :thinking, :acting, :compacting, :delegating, :done]
      |> Enum.filter(&Map.has_key?(by_state, &1))
      |> Enum.map_join(" · ", &"#{Map.fetch!(by_state, &1)} #{&1}")

    "#{length(rows)} agents in #{branches} branches" <>
      if(counts == "", do: "", else: " · " <> counts) <> " · #{Model.tokens(%{usage: usage})}"
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
      String.pad_leading(Model.tokens(row.agent), 15),
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
       field("tokens", Model.token_detail(a)),
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
  defp isolation_text(%{isolation: :remote}), do: "a worker on the plane"
  defp isolation_text(_), do: "shared checkout"

  defp todo_block(%{todos: []}), do: []

  defp todo_block(%{todos: todos}),
    do: ["", "tasks"] ++ Enum.map(todos, fn t -> "  [#{glyph(t.status)}] #{t.text}" end)

  defp pending_block(w, path) do
    case Enum.filter(w.pending, &(&1.agent_path == path)) do
      [] ->
        []

      pending ->
        ["", "waiting for you"] ++
          Enum.map(pending, &("  " <> pending_summary(&1, "y / n / a in the window")))
    end
  end

  # One line per outstanding request, shared by the observer's detail pane and the
  # side panel. The catch-all clause is load-bearing: an unmatched `kind` raises
  # inside `render/2`, which ExRatatui rescues by dropping the frame — the screen
  # would freeze on stale content while the app kept consuming keys.
  defp pending_summary(%{kind: :approval, name: name}, keys), do: "approval: #{name} (#{keys})"

  defp pending_summary(%{kind: :budget} = p, keys),
    do: "budget exhausted: #{Map.get(p, :detail) || "limit reached"} (#{keys})"

  defp pending_summary(%{kind: :question, question: q, options: [_ | _] = opts}, _keys),
    do: "question: #{q} (#{length(opts)} options — open the window)"

  defp pending_summary(%{kind: :question, question: q}, _keys), do: "question: #{q} (type + Enter)"
  defp pending_summary(%{kind: kind}, _keys), do: "#{kind} (see the window)"

  defp recent_block(agent) do
    case agent.transcript |> Enum.filter(&match?({:tool, _}, &1)) |> Enum.take(-6) do
      [] ->
        []

      tools ->
        ["", "recent tool calls"] ++
          Enum.map(tools, fn {:tool, t} -> "  " <> Model.tool_head(t) end)
    end
  end

  ## Session picker

  @doc "The picker's sessions and the clamped cursor, given the model and page state."
  @spec sessions_view(map()) :: {[Client.summary()], non_neg_integer()}
  def sessions_view(state) do
    entries = state.sessions.entries
    {entries, min(state.sessions.cursor, max(length(entries) - 1, 0))}
  end

  defp sessions_page(state, rect) do
    {entries, cursor} = sessions_view(state)
    [list_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 3}, {:fill, 2}])

    list = %ExRatatui.Widgets.List{
      items:
        entries
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, n} ->
          session_line(entry, n, state, max(list_rect.width - 4, 20))
        end),
      selected: if(entries == [], do: nil, else: cursor),
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: sessions_title(entries, state, list_rect.width - 2),
        borders: [:all],
        border_type: :double
      }
    }

    detail = %Paragraph{
      text: session_detail(Enum.at(entries, cursor), state, max(detail_rect.width - 2, 20)),
      wrap: true,
      block: %Block{title: " detail — Enter resumes this session ", borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp sessions_title(entries, state, width) do
    count = "#{length(entries)} session(s)"

    [
      " #{count} in #{state.workspace} ",
      " #{count} in #{Path.basename(state.workspace)} ",
      " #{count} "
    ]
    |> fit(width)
  end

  # One row per session: its number (`/resume 2` takes it), whether it is this one,
  # how long ago it was written to, what its branches came to, and the prompt the
  # first one was given.
  defp session_line(entry, n, state, width) do
    head =
      [
        String.pad_leading(Integer.to_string(n), 2),
        session_marker(entry, state),
        String.pad_trailing(age(entry.updated_at, state.now), 10),
        String.pad_trailing(branch_count(entry), 11),
        String.pad_trailing(branch_states(entry), 24)
      ]
      |> Enum.join(" ")

    room = max(width - Model.cell_width(head) - 1, 8)
    String.trim_trailing(head <> " " <> clip(Model.one_line(entry.title), room))
  end

  defp session_marker(%{id: sid}, %{session_id: sid}), do: "●"
  defp session_marker(%{state: :active}, _state), do: "○"
  defp session_marker(_entry, _state), do: " "

  defp branch_count(entry) do
    case length(live_branches(entry)) do
      1 -> "1 branch"
      n -> "#{n} branches"
    end
  end

  # A remote summary has no branches to count: it says where it lives instead,
  # which is the thing a mixed list needs to make plain.
  defp live_branches(%{branches: branches}) when is_list(branches),
    do: Enum.reject(branches, &(&1.state == :dismissed))

  defp live_branches(_entry), do: []

  @doc false
  @spec origin_label(Client.origin() | nil) :: String.t()
  def origin_label({:remote, plane}), do: "remote · " <> host(plane)
  def origin_label({:local, _workspace}), do: "local"
  def origin_label(_origin), do: "local"

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> url
    end
  end

  @branch_order [:needs_input, :running, :failed_unread, :done_unread]

  defp branch_states(%{origin: {:remote, _plane}} = entry),
    do: String.trim("#{entry.state} #{entry.status || ""}")

  defp branch_states(entry) do
    entry
    |> live_branches()
    |> Enum.frequencies_by(& &1.state)
    |> Enum.sort_by(fn {state, _n} -> Enum.find_index(@branch_order, &(&1 == state)) || 9 end)
    |> Enum.map_join(" · ", &state_count/1)
  end

  defp state_count({:needs_input, 1}), do: "1 needs you"
  defp state_count({:needs_input, n}), do: "#{n} need you"
  defp state_count({:running, n}), do: "#{n} running"
  defp state_count({:done_unread, n}), do: "#{n} done"
  defp state_count({:failed_unread, n}), do: "#{n} failed"
  defp state_count({state, n}), do: "#{n} #{state}"

  # "just now", "12m ago", "3h ago", "2d ago" — a picker row is read at a glance.
  defp age(nil, _now), do: "unknown"

  defp age(ts, now) do
    s = div(max(now - ts, 0), 1000)

    cond do
      s < 60 -> "just now"
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
    end
  end

  defp clip(text, room) do
    if Model.cell_width(text) <= room,
      do: text,
      else: String.slice(text, 0, max(room - 1, 1)) <> "…"
  end

  defp session_detail(nil, _state, _width),
    do:
      "No sessions in this directory yet.\n\n" <>
        "Dispatch a branch and this session shows up here; " <>
        "`troupe` in another directory keeps its own list."

  defp session_detail(entry, state, width) do
    branches = live_branches(entry)

    ([
       "#{entry.id}  (#{where(entry, state)})",
       "",
       field("origin", origin_label(entry.origin)),
       field("workspace", entry.workspace || "on the worker"),
       field("last event", "#{age(entry.updated_at, state.now)} · #{stamp(entry.updated_at)}"),
       field("owner", entry.owner || "you"),
       field("profile", entry.profile || "—"),
       field("branches", "#{length(branches)}#{dismissed_note(entry, branches)}")
     ] ++ branch_block(branches, width))
    |> Enum.join("\n")
  end

  defp where(%{id: sid}, %{session_id: sid}), do: "this session"
  defp where(%{origin: {:remote, _plane}} = entry, _state), do: "on the plane — #{entry.state}"
  defp where(%{state: :active}, _state), do: "running in this VM"
  defp where(_entry, _state), do: "on disk — Enter replays it"

  defp dismissed_note(entry, branches) do
    case length(List.wrap(entry.branches)) - length(branches) do
      0 -> ""
      n -> " (#{n} dismissed)"
    end
  end

  defp branch_block([], _width), do: ["", "No branches yet."]

  defp branch_block(branches, width) do
    ["", "branches"] ++
      Enum.map(branches, fn b ->
        head =
          "  " <>
            String.pad_trailing(b.path, 12) <>
            String.pad_trailing(b.name, 10) <> String.pad_trailing(to_string(b.state), 13)

        head <> clip(Model.one_line(b.prompt), max(width - Model.cell_width(head), 12))
      end)
  end

  defp stamp(nil), do: "unknown"

  defp stamp(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
  end

  ## Files panel

  @doc "The files panel's entries and the clamped cursor."
  @spec files_view(map()) :: {[map()], non_neg_integer()}
  def files_view(%{files: %{entries: entries, cursor: cursor}}),
    do: {entries, min(cursor, max(length(entries) - 1, 0))}

  def files_view(_state), do: {[], 0}

  defp files_page(state, rect) do
    {entries, cursor} = files_view(state)
    [list_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    list = %ExRatatui.Widgets.List{
      items: Enum.map(entries, &file_line(&1, max(list_rect.width - 4, 12))),
      selected: if(entries == [], do: nil, else: cursor),
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: fit([" #{state.files.path} ", " files "], list_rect.width - 2),
        borders: [:all],
        border_type: :double
      }
    }

    detail = %Paragraph{
      text: files_detail(state, Enum.at(entries, cursor)),
      wrap: false,
      block: %Block{title: files_detail_title(state), borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp file_line(entry, width) do
    mark = if entry.dir?, do: "/", else: " "
    size = if entry.dir?, do: "", else: human_size(entry.size)
    head = clip(entry.name <> mark, max(width - 10, 8))
    String.trim_trailing(String.pad_trailing(head, max(width - 10, 8)) <> " " <> size)
  end

  defp files_detail_title(%{files: %{preview: {path, _lines}}}), do: " #{path} — Esc closes "
  defp files_detail_title(_state), do: " Enter opens · ← up · r reloads · Esc closes "

  defp files_detail(%{files: %{error: error}}, _entry) when is_binary(error), do: error

  defp files_detail(%{files: %{preview: {_path, lines}}}, _entry), do: Enum.join(lines, "
")

  defp files_detail(_state, nil), do: "This directory is empty."

  defp files_detail(_state, entry) do
    kind = if entry.dir?, do: "directory", else: "file"

    Enum.join(
      [
        field("name", entry.name),
        field("path", entry.path),
        field("kind", kind),
        field("size", if(entry.dir?, do: "—", else: human_size(entry.size)))
      ],
      "
"
    )
  end

  defp human_size(size) when is_integer(size) and size >= 1_000_000,
    do: "#{Float.round(size / 1_000_000, 1)} MB"

  defp human_size(size) when is_integer(size) and size >= 1_000, do: "#{div(size, 1000)} kB"
  defp human_size(size) when is_integer(size), do: "#{size} B"
  defp human_size(_size), do: ""

  ## MCP page

  defp mcp_page(state, rect) do
    servers = Model.mcp_servers(state.model)
    [list_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    items =
      case servers do
        [] ->
          [
            "No MCP servers configured.",
            "",
            "Add servers to .troupe/config.yaml under 'mcp':",
            "",
            "Example:",
            "  mcp:",
            "    filesystem:",
            "      command: npx",
            "      args: [\"-y\", \"@modelcontextprotocol/server-filesystem\", \"/tmp\"]"
          ]

        list ->
          Enum.map(list, &mcp_server_line/1)
      end

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: if(servers == [], do: nil, else: min(state.mcp_cursor, length(servers) - 1)),
      highlight_symbol: "▸ ",
      highlight_style: %Style{fg: :cyan, modifiers: [:bold]},
      block: %Block{
        title: " MCP servers ",
        borders: [:all],
        border_type: :double
      }
    }

    detail = %Paragraph{
      text: mcp_detail(state, Enum.at(servers, state.mcp_cursor)),
      wrap: false,
      block: %Block{title: mcp_detail_title(), borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp mcp_server_line(%{name: name, state: state, tools: tools}),
    do: "#{mcp_glyph(state)} #{name} (#{tools} tools)"

  defp mcp_glyph(:ready), do: "✓"
  defp mcp_glyph(:connecting), do: "…"
  defp mcp_glyph(:error), do: "✗"
  defp mcp_glyph(:stopped), do: "○"
  defp mcp_glyph(_), do: " "

  defp mcp_detail_title, do: " ↑↓ move · r refreshes · Esc back "

  defp mcp_detail(_state, nil), do: "Select a server to see its tools."

  defp mcp_detail(_state, %{name: name, state: state, tools: tools, error: error}) do
    parts =
      [
        field("name", name),
        field("state", state),
        field("tools", tools)
      ]

    parts = if error, do: parts ++ [field("error", error)], else: parts
    Enum.join(parts, "\n")
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
  defp effect_line(:next_run), do: "applies the next time the TUI starts"

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

    rows =
      g.blocks
      |> Enum.concat()
      |> Model.rows(g.inner_w, g.offset, g.inner_h)
      |> highlight(g, Map.get(state, :selection))

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
             block: %Block{title: " tokens · tasks · agents · pending ", borders: [:all]}
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
    approval? = Enum.any?(w.pending, &(&1.kind in [:approval, :budget]))
    verb = if state.expanded, do: "collapses", else: "expands"
    selection? = Map.get(state, :selection) != nil

    pieces = [
      {true, ["PgUp/PgDn ↑↓ scroll", "PgUp/PgDn scroll", "PgUp/PgDn"]},
      {not g.follow?, ["End follows the tail", "End follows", "End"]},
      {agents > 1, ["←→ other agents", "←→ agents", "←→"]},
      {true, ["e #{verb} output", "e #{verb}", "e"]},
      {selection?, ["Ctrl-Y copies the selection", "Ctrl-Y copies selection", "Ctrl-Y sel"]},
      {not selection?, ["drag selects · Ctrl-Y copies all", "drag · Ctrl-Y copy", nil]},
      {approval?, ["y/n/a approve", "y/n/a", "y/n/a"]},
      {armed?(state, w.path, "x"), ["x again cancels & removes", "x again cancels", "x again"]},
      {armed?(state, w.path, "d"), ["d again dismisses", "d again dismisses", "d again"]},
      {not armed?(state, w.path, "x") and w.state in [:running, :needs_input],
       ["xx cancel & remove", "xx cancel", "xx"]},
      {not armed?(state, w.path, "d") and w.state in [:done_unread, :failed_unread],
       ["dd dismiss", "dd dismiss", "dd"]},
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

  # `x`/`d` are armed by their first press and act on the second (Decision 83),
  # so the hint has to say which press the reader is one keystroke away from.
  defp armed?(state, path, code), do: Map.get(state, :win_armed) == {path, code}

  ## Selection highlight

  # Paints the selected cell span of each visible row by re-tagging its segments
  # with their own resolved style plus `:reversed`, so syntax highlighting and
  # colours survive and no theme decision is needed. Styling stays in this module,
  # which is why `Model` only slices rows and never re-tags them.
  defp highlight(rows, _g, nil), do: rows

  defp highlight(rows, g, %{anchor: anchor, cursor: cursor}) do
    {{r1, c1}, {r2, c2}} = if anchor <= cursor, do: {anchor, cursor}, else: {cursor, anchor}

    rows
    |> Enum.with_index(g.offset)
    |> Enum.map(fn {row, abs_row} ->
      if abs_row >= r1 and abs_row <= r2,
        do: reverse_span(row, if(abs_row == r1, do: c1, else: 0), span_end(abs_row, r2, c2)),
        else: row
    end)
  end

  defp span_end(row, last, col), do: if(row == last, do: col + 1, else: :end)

  defp reverse_span({kind, _} = row, from, to) do
    {pre, inside, post} = Model.split_row(row, from, to)

    reversed =
      Enum.map(inside, fn {tag, text} ->
        {add_reversed(segment_style(tag, kind, text)), text}
      end)

    {kind, pre ++ reversed ++ post}
  end

  defp add_reversed(%Style{modifiers: mods} = style),
    do: %{style | modifiers: Enum.uniq([:reversed | mods])}

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
  defp segment_style(:reasoning_marker, _kind, _text), do: %Style{fg: :magenta}
  defp segment_style(:reasoning_title, _kind, _text), do: %Style{fg: :magenta, modifiers: [:dim]}
  defp segment_style(:reasoning_body, _kind, _text), do: %Style{fg: :magenta, modifiers: [:dim]}
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
            Enum.map(items, &{:pending, "  " <> pending_summary(&1, "y / n / a")})
      end

    [{:system, "Tokens:"}] ++
      Enum.map(Model.token_lines(w), &{:text, "  " <> &1}) ++
      [{:blank, ""}, {:system, "Tasks:"}] ++
      if(todos == [], do: [{:text, "  (none)"}], else: todos) ++
      agents ++ pending
  end

  # An item as `Troupe.Remote.Translate` spells it: `text`, `status`, `id`.
  defp todo_lines(w, path, indent) do
    w.agents
    |> Map.get(path, %{todos: []})
    |> Map.get(:todos, [])
    |> Enum.map(fn t -> {:text, "#{indent}[#{glyph(t.status)}] #{t.text}"} end)
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

    mcp =
      case state.model.mcp do
        map when map_size(map) > 0 ->
          total = map_size(map)
          ready = Enum.count(map, fn {_, v} -> v.state == :ready end)
          tools = Enum.reduce(map, 0, fn {_, v}, acc -> acc + v.tools end)
          " · mcp: #{ready}/#{total} srvs · #{tools} tools"

        _ ->
          ""
      end

    text =
      "#{Model.attention_summary(state.model)}#{hint}#{goal_note(state.model)}#{loop_note(state.model)}" <>
        " · #{watch}#{mcp}" <>
        " · #{state.session_id}" <>
        remote_note(state) <>
        if(notice, do: " · #{notice}", else: "")

    text =
      if state.quit_armed,
        do: text <> " · PRESS CTRL-C AGAIN TO QUIT",
        else: text <> " · /help for settings and help · /quit or Ctrl-C twice exits"

    {%Paragraph{text: text, style: %Style{fg: :dark_gray}}, rect}
  end

  # The session's goal, for as long as it has one, near the front of the line where a
  # narrow terminal still shows it. Clipped: `/goal` prints the whole of it.
  @goal_width 60

  defp goal_note(model) do
    case Model.goal(model) do
      nil ->
        ""

      goal ->
        line = goal |> String.split("\n", trim: true) |> Enum.join(" ")

        clipped =
          if String.length(line) > @goal_width,
            do: String.slice(line, 0, @goal_width - 1) <> "…",
            else: line

        " · goal: " <> clipped
    end
  end

  # Where a running loop is, beside the goal it works towards. It runs on its own, so the
  # line is all it takes of the screen: the input box stays yours.
  defp loop_note(model) do
    case Model.loop(model) do
      nil -> ""
      %{iteration: n, max: nil} -> " · loop #{n}"
      %{iteration: n, max: max} -> " · loop #{n}/#{max}"
    end
  end

  # A remote session says what it is and what it will not let you do; a local
  # one adds nothing to the line at all.
  defp remote_note(%{model: %{remote: %{} = remote}}) do
    state = " · remote (#{remote[:state] || "?"})"

    case remote[:reason] do
      reason when is_binary(reason) -> state <> " · #{reason}"
      _ -> state
    end
  end

  defp remote_note(_state), do: ""

  # The reason input is off, when it is: a read-only session, a viewer token, or
  # a connection that is coming back.
  @doc false
  @spec input_blocked(map()) :: String.t() | nil
  def input_blocked(%{model: %{remote: %{can_input?: false, reason: reason}}})
      when is_binary(reason),
      do: reason

  def input_blocked(_state), do: nil

  # The armed half of a double-press: the letter is in the box as text, and the
  # box's own title is where the reader is looking, so it says what a second
  # press would do and that anything else typed keeps the letter (Decision 83).
  defp armed_note(state, path) do
    case Map.get(state, :win_armed) do
      {^path, "x"} -> " → #{path} — press x again to cancel & remove, or keep typing "
      {^path, "d"} -> " → #{path} — press d again to dismiss, or keep typing "
      _ -> nil
    end
  end

  defp command_line(state, rect), do: command_line(state, rect, @cmd_rows)

  defp command_line(state, rect, box_rows) do
    {text, title} =
      case state.focus do
        :command ->
          {{:edit, {"/" <> state.cmd_text, state.cmd_pos + 1}},
           if(multiline?(state.cmd_text), do: pasted_title(state.cmd_text), else: " command ")}

        {:window, path} ->
          target = if state.pane.agent in [nil, path], do: "", else: " to the branch root"

          title =
            cond do
              blocked = input_blocked(state) -> " → #{path} — input disabled: #{blocked} "
              armed = armed_note(state, path) -> armed
              multiline?(state.win_text) -> pasted_title(state.win_text)
              true -> " → #{path} (Enter sends#{target}, Esc back) "
            end

          {{:edit, {state.win_text, state.win_pos}}, title}

        :settings ->
          settings_command_line(state)

        :observer ->
          {"", " agents — ↑↓ move · Enter opens the agent · Esc back "}

        :sessions ->
          {"", " sessions — ↑↓ move · Enter resumes · r refreshes · Esc back "}

        :files ->
          {"", " files — ↑↓ move · Enter opens · ← up · r reloads · Esc back "}

        :mcp ->
          {"", " mcp — ↑↓ move · r refreshes · Esc back "}

        :hq ->
          {hq_text(state), Troupe.UI.HQ.footer(state.hq)}
      end

    focused_cmd? = state.focus == :command

    {%Paragraph{
       text: input_box_text(state, text, box_rows),
       block: %Block{
         title: title,
         borders: [:all],
         border_style: %Style{fg: if(focused_cmd?, do: :white, else: :dark_gray)}
       },
       wrap: false
     }, rect}
  end

  # An editable box scrolls: fold the whole input to the inner width (hard
  # breaking, so a too-long row's continuation stays visible), then show the
  # window of rows around the one the cursor is on — centred, so there is
  # context either side, and pinned to the ends so the first and last rows are
  # reachable. An input that fits draws whole.
  defp input_box_text(state, {:edit, input}, box_rows) do
    content = max(box_rows - 2, 1)
    {rows, cursor_row} = Input.rows(input, cmd_inner_width(state, box_rows))

    offset =
      (cursor_row - div(content - 1, 2))
      |> max(0)
      |> min(max(length(rows) - content, 0))

    rows |> Enum.slice(offset, content) |> Enum.join("\n")
  end

  # A box nobody types into (a page's footer, the HQ wizard) just shows its tail.
  defp input_box_text(state, text, box_rows) do
    w = cmd_inner_width(state, box_rows)
    content = max(box_rows - 2, 1)

    text
    |> String.split("\n")
    |> Enum.take(-content)
    |> Enum.map(&Model.wrap(&1, w, :char))
    |> List.flatten()
    |> Enum.take(-content)
    |> Enum.join("\n")
  end

  # The inner width the box draws at, matching the layout: the command rect
  # minus its two border columns.
  defp cmd_inner_width(%{size: {w, h}} = state, box_rows) do
    activated? = match?({:window, _}, state.focus)
    {_, _, _, cmd} = layout(w, h, activated?, 0, box_rows)
    max(cmd.width - 2, 1)
  end

  defp cmd_inner_width(_state, _box_rows), do: 120

  # How tall the command box is: `@input_rows`, always — a fixed box is one the
  # typist can aim at, and five rows is enough of a long input to read back. On
  # a short terminal it gives way so the strip, the status line and two pane
  # rows still fit.
  defp box_height(height), do: max(@cmd_rows, min(@input_rows, height - 5))

  # The wizard's free-text steps type into the command line, so the page itself
  # stays a list and the box stays where the user is already looking.
  defp hq_text(%{hq: %{create: %{step: step} = create}}) when step in [:url, :ref, :prompt],
    do: Map.fetch!(create, step) <> "▏"

  defp hq_text(_state), do: ""

  @doc false
  @spec multiline?(String.t()) :: boolean()
  def multiline?(text), do: String.contains?(text, "\n")

  @doc false
  @spec pasted_title(String.t()) :: String.t()
  def pasted_title(text) do
    lines = text |> String.split("\n") |> Enum.count(&(&1 != "")) |> max(1)
    " pasted #{lines} lines — Enter sends, Alt-Enter/Ctrl-J newline, Esc clears "
  end
end
