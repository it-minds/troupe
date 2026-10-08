defmodule Troupe.UI.TUI.View do
  @moduledoc """
  Renders the TUI model into ExRatatui widgets: window strip, activated pane,
  status and command line. Transcript text is wrapped in Elixir (`Model.rows/4`)
  and handed to the renderer as pre-wrapped lines, so only the rows in view are
  built and nothing is ever clipped at the bottom.

  Every colour is a role from `Troupe.UI.TUI.Theme` (Afterglow, generated from the
  design tokens), resolved for the terminal's depth once the frame is built. The
  reserved pink — `:needs_you` — is spent only where a person is needed.
  """

  alias ExRatatui.Layout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Clear, Paragraph, Scrollbar}
  alias ExRatatui.Widgets.Block.Title
  alias Troupe.Client
  alias Troupe.Settings
  alias Troupe.UI.TUI.{Input, Model, Theme}

  # Command-box geometry. The focused box — the command line and an active
  # window's input — is a fixed `@input_rows` console rows: `@input_content`
  # rows to write in plus the two borders, so the box never jumps under the
  # typist and there is room to see what a long input actually says. Past that
  # it scrolls around the cursor rather than growing (Decision 88). The pages
  # (settings, sessions, files, HQ) keep the one-row `@cmd_rows` footer.
  @cmd_rows 3
  @input_content 5
  @input_rows @input_content + 2

  @doc """
  The frame's widgets, coloured for the terminal: `state.theme` when the state carries
  one (a test drawing at a given depth), otherwise what the environment says.
  """
  @spec render(map(), ExRatatui.Frame.t()) :: [{term(), Rect.t()}]
  def render(state, frame) do
    theme = Map.get(state, :theme) || Theme.current()

    state
    |> Map.put(:theme, theme)
    |> draw(frame)
    |> Theme.paint(theme)
  end

  defp draw(%{focus: :settings} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    settings_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp draw(%{focus: :observer} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    observer_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp draw(%{focus: :sessions} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    sessions_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp draw(%{focus: :hq} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())

    Troupe.UI.HQ.render(state.hq, page_rect, state) ++
      [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp draw(%{focus: :files} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    files_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  defp draw(%{focus: :mcp} = state, frame) do
    area = %Rect{x: 0, y: 0, width: frame.width, height: frame.height}
    [page_rect, status_rect, cmd_rect] = Layout.split(area, :vertical, page_constraints())
    mcp_page(state, page_rect) ++ [status(state, status_rect), command_line(state, cmd_rect)]
  end

  # The palette is a popup over the session (Decision 119): the screen is drawn as it was
  # where the palette was opened from, the command box shows the filter being typed, and
  # the popup sits over the rest.
  defp draw(%{focus: :palette} = state, frame) do
    behind = draw(%{state | focus: state.palette.return_to}, frame)
    {_line, cmd_rect} = List.last(behind)

    Enum.drop(behind, -1) ++
      [command_line(state, cmd_rect, cmd_rect.height)] ++ palette_popup(state, frame, cmd_rect)
  end

  defp draw(state, frame) do
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
        transcript = Map.get(w.agents, agent, %{transcript: []}).transcript
        entries = length(transcript)
        blocks = Model.pane_blocks(w, agent, state.expanded, state.tick, state.now, state.answer)
        heights = block_heights(transcript, blocks, inner_w, state.expanded)
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

  # Measuring every block is the part of a frame that grows with the session, and a
  # finished entry does not change: its height is remembered per process, beside the
  # entry it was measured from, and only an entry that is new or changed, and the live
  # blocks after the transcript, are measured again. An unchanged entry is the very term
  # remembered, so matching it is a pointer check, not a walk of its text.
  defp block_heights(transcript, blocks, width, expanded?) do
    key = {__MODULE__, :heights}

    known =
      case Process.get(key) do
        {^width, ^expanded?, pairs} -> pairs
        _ -> []
      end

    {entry_blocks, live} = Enum.split(blocks, length(transcript))
    pairs = measure(transcript, entry_blocks, known, width)
    Process.put(key, {width, expanded?, pairs})
    Enum.map(pairs, &elem(&1, 1)) ++ Enum.map(live, &Model.row_count(&1, width))
  end

  defp measure([], _blocks, _known, _width), do: []

  defp measure([entry | entries], [_block | blocks], [{entry, h} | known], width),
    do: [{entry, h} | measure(entries, blocks, known, width)]

  defp measure([entry | entries], [block | blocks], known, width),
    do: [{entry, Model.row_count(block, width)} | measure(entries, blocks, drop1(known), width)]

  defp drop1([]), do: []
  defp drop1([_ | rest]), do: rest

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
      highlight_style: selected(),
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
      String.pad_trailing(state_text(st, state), 12),
      String.pad_trailing(Model.agent_elapsed(row, state.now), 6),
      String.pad_leading(Model.tokens(row.agent), 15),
      detail
    ]
    |> Enum.join(" ")
    |> String.trim_trailing()
    |> needs_you_line(st == :needs_input)
  end

  defp state_text(:needs_input, state), do: if(blink?(state), do: "▶ you", else: "needs you")
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
     ] ++ todo_block(a, row.root?) ++ pending_block(w, row.path) ++ recent_block(a))
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

  # A session the daemon started in a worktree of its own (`troupe run --worktree`) is
  # told so by `session.create`, not by a `worktree_created` of its own.
  defp isolation_text(%{isolation: :worktree}), do: "worktree"
  defp isolation_text(%{isolation: :remote}), do: "a worker on the plane"
  defp isolation_text(_), do: "shared checkout"

  defp todo_block(%{todos: []}, _root?), do: []

  defp todo_block(%{todos: todos}, root?),
    do: ["", "tasks"] ++ Enum.map(todo_texts(todos, root?), &("  " <> &1))

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
      highlight_style: selected(),
      block: %Block{
        title: sessions_title(entries, state, list_rect.width - 2),
        borders: [:all],
        border_type: :double
      }
    }

    entry = Enum.at(entries, cursor)

    detail = %Paragraph{
      text: session_detail(entry, state, max(detail_rect.width - 2, 20)),
      wrap: true,
      block: %Block{title: detail_title(entry), borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp detail_title(entry) do
    if claimable?(entry),
      do: " detail — Enter resumes · c claims it here ",
      else: " detail — Enter resumes this session "
  end

  @doc """
  Whether `c` takes the session over here: a private one another device sealed last, as
  this machine's daemon says it (root Decision 785).
  """
  @spec claimable?(map() | nil) :: boolean()
  def claimable?(%{kind: "private", sync: "elsewhere"}), do: true
  def claimable?(_entry), do: false

  @doc """
  Where a private session is kept and how its sealing stands, `private · synced`, in the
  desktop app's words (`@troupe/client`'s `syncWords`); empty for any other session.
  """
  @spec kept(map()) :: String.t()
  def kept(entry) do
    case {Map.get(entry, :kind), Map.get(entry, :sync)} do
      {"private", nil} -> "private"
      {"private", sync} -> "private · " <> elem(sync_words(sync, Map.get(entry, :device)), 0)
      _other -> ""
    end
  end

  @doc "A private session's sync state in words: the label, and the sentence behind it."
  @spec sync_words(String.t(), String.t() | nil) :: {String.t(), String.t()}
  def sync_words("current", _device), do: {"synced", "sealed under your key through its last event"}

  def sync_words("behind", _device),
    do: {"syncing", "being sealed; its latest events are not sealed yet"}

  def sync_words("paused", _device),
    do: {"not syncing", "nothing is sealed until this computer is signed in again"}

  def sync_words("elsewhere", device) do
    holder = device || "another device"
    {"on " <> holder, holder <> " sealed it last; claim it to seal it from this computer"}
  end

  def sync_words("erasure_pending", _device),
    do: {"waiting to be erased", "erased; its key is not destroyed yet"}

  def sync_words(other, _device), do: {other, other}

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

    (head <> " " <> clip(kept_title(entry), room))
    |> String.trim_trailing()
    |> needs_you_line(needs_you?(entry))
  end

  # A private session says so before its title, and how its sealing stands.
  defp kept_title(entry) do
    case kept(entry) do
      "" -> Model.one_line(entry.title)
      kept -> "[" <> kept <> "] " <> Model.one_line(entry.title)
    end
  end

  # A row in a list that says a person is needed is drawn in the reserved colour, whole,
  # so it is the row that is found from across the room; any other row is left as text.
  defp needs_you_line(text, true), do: Line.new([Span.new(text, style: Theme.style(:needs_you))])
  defp needs_you_line(text, false), do: text

  @doc false
  @spec needs_you?(Client.summary()) :: boolean()
  def needs_you?(%{status: "waiting"}), do: true
  def needs_you?(entry), do: Enum.any?(branches(entry), &(&1.state == :needs_input))

  defp session_marker(%{id: sid}, %{session_id: sid}), do: "●"
  defp session_marker(%{state: :active}, _state), do: "○"
  defp session_marker(_entry, _state), do: " "

  defp branch_count(entry) do
    case length(branches(entry)) do
      1 -> "1 branch"
      n -> "#{n} branches"
    end
  end

  # A remote summary has no branches to count: it says where it lives instead,
  # which is the thing a mixed list needs to make plain.
  defp branches(%{branches: branches}) when is_list(branches), do: branches
  defp branches(_entry), do: []

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

  @branch_order [:needs_input, :interrupted, :done]

  defp branch_states(%{origin: {:remote, _plane}} = entry),
    do: String.trim("#{entry.state} #{entry.status || ""}")

  # What the daemon says of the branches (`Troupe.Client.Daemon`): those asking you
  # something, and those asleep with how they stopped. A live one it says nothing about.
  defp branch_states(entry) do
    entry
    |> branches()
    |> Enum.reject(&is_nil(&1.state))
    |> Enum.frequencies_by(& &1.state)
    |> Enum.sort_by(fn {state, _n} -> Enum.find_index(@branch_order, &(&1 == state)) || 9 end)
    |> Enum.map_join(" · ", &state_count/1)
  end

  defp state_count({:needs_input, 1}), do: "1 needs you"
  defp state_count({:needs_input, n}), do: "#{n} need you"
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
        "Say something, or dispatch a branch, and this session shows up here; " <>
        "`troupe` in another directory keeps its own list."

  defp session_detail(entry, state, width) do
    branches = branches(entry)

    ([
       "#{entry.id}  (#{where(entry, state)})",
       "",
       field("origin", origin_label(entry.origin)),
       field("workspace", entry.workspace || "on the worker"),
       field("last event", "#{age(entry.updated_at, state.now)} · #{stamp(entry.updated_at)}"),
       field("owner", entry.owner || "you"),
       field("profile", entry.profile || "—"),
       field("branches", "#{length(branches)}")
     ] ++ private_block(entry) ++ branch_block(branches, width))
    |> Enum.join("\n")
  end

  # A private session's sealing, in a sentence, and what `c` does where another device
  # holds it.
  defp private_block(%{kind: "private", sync: sync} = entry) when is_binary(sync) do
    {label, detail} = sync_words(sync, Map.get(entry, :device))
    said = [field("private", label <> " — " <> detail)]

    if claimable?(entry),
      do:
        said ++
          ["", "c claims it for this computer: it is sealed from here, and the other device stops."],
      else: said
  end

  defp private_block(%{kind: "private"}), do: [field("private", "yes")]
  defp private_block(_entry), do: []

  defp where(%{id: sid}, %{session_id: sid}), do: "this session"
  defp where(%{origin: {:remote, _plane}} = entry, _state), do: "on the plane — #{entry.state}"
  defp where(%{state: :active}, _state), do: "running in this VM"
  defp where(_entry, _state), do: "on disk — Enter replays it"

  defp branch_block([], _width), do: ["", "No branches yet."]

  # Each branch as the daemon lists it: its session, its agent, what it says of it, and
  # the git branch of its worktree when it has one.
  defp branch_block(branches, width) do
    ["", "branches"] ++
      Enum.map(branches, fn b ->
        head =
          "  " <>
            String.pad_trailing(b.id, 12) <>
            String.pad_trailing(b.profile || "—", 10) <>
            String.pad_trailing(branch_word(b.state), 13)

        head <> clip(b.git_branch || "", max(width - Model.cell_width(head), 12))
      end)
  end

  defp branch_word(nil), do: "open"
  defp branch_word(:needs_input), do: "needs you"
  defp branch_word(state), do: to_string(state)

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
      highlight_style: selected(),
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

  ## MCP page (troupe-remote Decision 700)

  @doc """
  The rows the `/mcp` page lists, in order: every server the layers give the workspace,
  then every skill. What the page's cursor and keys index.
  """
  @spec mcp_entries(map()) :: [{:server, map()} | {:skill, map()}]
  def mcp_entries(%{mcp_page: %{servers: servers, skills: skills}}),
    do: Enum.map(servers, &{:server, &1}) ++ Enum.map(skills, &{:skill, &1})

  def mcp_entries(_state), do: []

  defp mcp_page(state, rect) do
    entries = mcp_entries(state)
    [list_rect, detail_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    items =
      case entries do
        [] ->
          [
            "No MCP servers or skills yet.",
            "",
            "/mcp import <path>    copy a .mcp.json (Claude Code, Cursor, VS Code, Claude Desktop)",
            "/mcp link <path>      read one in place",
            "/skills import <dir>  copy a directory of skills, such as ~/.claude/skills",
            "/skills link <dir>    read one in place",
            "",
            "Add --workspace to write the workspace's .troupe/ files instead of yours.",
            "Or write mcp.json beside config.yaml by hand: {\"mcpServers\": {...}}."
          ] ++ mcp_warnings(state)

        list ->
          Enum.map(list, &mcp_line/1) ++ mcp_warnings(state)
      end

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: if(entries == [], do: nil, else: min(state.mcp_cursor, length(entries) - 1)),
      highlight_symbol: "▸ ",
      highlight_style: selected(),
      block: %Block{
        title: " MCP servers and skills ",
        borders: [:all],
        border_type: :double
      }
    }

    detail = %Paragraph{
      text: mcp_detail(Enum.at(entries, state.mcp_cursor), Map.get(state, :mcp_sign_in)),
      wrap: true,
      block: %Block{title: mcp_detail_title(), borders: [:all]}
    }

    [{list, list_rect}, {detail, detail_rect}]
  end

  defp sign_in_text(%{state: :signed_in, account: account}) when is_binary(account),
    do: "signed in as #{account} — o signs out"

  defp sign_in_text(%{state: :signed_in}), do: "signed in — o signs out"
  defp sign_in_text(%{state: :signing_in}), do: "waiting for the browser"

  defp sign_in_text(%{state: :expired, account: account}) when is_binary(account),
    do: "run out for #{account} — s signs in again"

  defp sign_in_text(%{state: :expired}), do: "run out — s signs in again"
  defp sign_in_text(_signed_out), do: "not signed in — s signs in"

  # The URL in full while the browser is out, for a person whose browser did not open:
  # the daemon listens for the answer on this machine, so it is opened here.
  defp sign_in_url(%{name: name}, %{state: :signing_in}, %{name: name, url: url}),
    do: field("open", url)

  defp sign_in_url(_server, _auth, _sign_in), do: nil

  defp mcp_warnings(%{mcp_page: %{warnings: [_ | _] = warnings}}),
    do: [""] ++ Enum.map(warnings, &("! " <> &1))

  defp mcp_warnings(_state), do: []

  defp mcp_line({:server, %{name: name, layer: layer} = server}),
    do: "#{mcp_glyph(server)} #{name}  [#{layer}]  #{mcp_summary(server)}"

  defp mcp_line({:skill, %{name: name, layer: layer, description: description}}),
    do: "◆ #{name}  [#{layer}]  #{clip(description, 48)}"

  defp mcp_glyph(%{disabled?: true}), do: "–"
  defp mcp_glyph(%{state: :ready}), do: "✓"
  defp mcp_glyph(%{state: :connecting}), do: "…"
  defp mcp_glyph(%{state: :error}), do: "✗"
  defp mcp_glyph(%{state: :stopped}), do: "○"
  defp mcp_glyph(%{state: :pending}), do: "?"
  defp mcp_glyph(%{state: :disabled}), do: "–"
  defp mcp_glyph(%{state: :sign_in}), do: "→"
  defp mcp_glyph(_server), do: "·"

  # A server that wants the person signed in (troupe-remote Decision 741) says so on
  # its line, and what `s` does about it.
  defp mcp_summary(%{disabled?: true}), do: "disabled"
  defp mcp_summary(%{auth: %{state: :signing_in}}), do: "signing in — finish in the browser, then r"
  defp mcp_summary(%{state: :sign_in, auth: %{state: :expired}}), do: "sign in again — s"
  defp mcp_summary(%{state: :sign_in}), do: "sign in — s"
  defp mcp_summary(%{state: nil}), do: "not in this session yet — c starts it"

  defp mcp_summary(%{state: :ready, tools: tools, auth: %{state: :signed_in, account: account}})
       when is_binary(account),
       do: "#{length(tools)} tools · #{account}"

  defp mcp_summary(%{state: :ready, tools: tools}), do: "#{length(tools)} tools"
  defp mcp_summary(%{state: state}), do: to_string(state)

  defp mcp_detail_title,
    do:
      " ↑↓ move · r reload · c check · s sign in · o sign out · d enable/disable · x remove · Esc back "

  defp mcp_detail(nil, _sign_in), do: "Select a server or a skill to see where it comes from."

  defp mcp_detail({:server, server}, sign_in) do
    auth = Map.get(server, :auth)

    [
      field("name", server.name),
      field("layer", server.layer),
      field("source", server.source || "(this session)"),
      transport_field(server),
      field("state", server.state || "not started in this session"),
      if(auth, do: field("sign-in", sign_in_text(auth))),
      if(auth && auth.error, do: field("last sign-in", auth.error)),
      sign_in_url(server, auth, sign_in),
      field("tools", Enum.join(server.tools, ", ")),
      if(server.error, do: field("error", server.error)),
      if(server.trust, do: field("trust", server.trust)),
      if(server.disabled?, do: field("disabled", "yes"))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp mcp_detail({:skill, skill}, _sign_in) do
    [
      field("name", skill.name),
      field("layer", skill.layer),
      field("source", skill.source),
      if(skill.linked?, do: field("linked", "read in place")),
      "",
      skill.description
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp transport_field(%{url: url}) when is_binary(url), do: field("url", url)

  defp transport_field(%{command: command, args: args}) when is_binary(command),
    do: field("command", Enum.join([command | args], " "))

  defp transport_field(_server), do: field("command", "(none)")

  ## Settings page

  defp settings_page(state, rect) do
    %{settings: s} = state
    [list_rect, help_rect] = Layout.split(rect, :horizontal, [{:fill, 2}, {:fill, 3}])

    # Each value with the layer that set it, when that is not the default: what the
    # daemon says a session here would read (#57).
    items =
      Enum.map(Settings.fields(), fn field ->
        value = Settings.format(s.view, s.config, field.key)

        from =
          case Settings.layer(s.view, field.key) do
            layer when layer in [nil, "default"] -> ""
            layer -> "  · " <> layer
          end

        "#{String.pad_trailing(field.label, 26)} #{value}#{from}"
      end)

    list = %ExRatatui.Widgets.List{
      items: items,
      selected: s.cursor,
      highlight_symbol: "▸ ",
      highlight_style: selected(),
      block: %Block{
        title: " settings — #{settings_title(s)} ",
        borders: [:all],
        border_type: :double
      }
    }

    right = if s.picker, do: picker_list(state, help_rect), else: help_paragraph(state)
    [{list, list_rect}, {right, help_rect}]
  end

  # The menu for a setting that has one: every model Troupe found, plus a way out
  # to typing one it did not; or every theme there is.
  defp picker_list(%{settings: %{picker: p}}, rect) do
    # "▸ " takes two columns of the block's interior, and a note that would not fit
    # drops back a form rather than being clipped mid-word.
    width = max(rect.width - 4, 20)
    label_w = p.choices |> Enum.map(&Model.cell_width(&1.label)) |> Enum.max(fn -> 0 end)
    room = width - label_w - 2

    items =
      Enum.map(p.choices, fn c ->
        String.trim_trailing(String.pad_trailing(c.label, label_w) <> "  " <> note(c, room))
      end) ++ if(p.typed?, do: ["type one instead…"], else: [])

    %ExRatatui.Widgets.List{
      items: items,
      selected: min(p.cursor, length(items) - 1),
      highlight_symbol: "▸ ",
      highlight_style: selected(),
      block: %Block{
        title: " #{picker_count(p)} — Enter picks · Esc back ",
        borders: [:all]
      }
    }
  end

  defp picker_count(%{typed?: true, choices: choices}), do: "#{length(choices)} models detected"
  defp picker_count(%{choices: choices}), do: "#{length(choices)} themes"

  defp note(choice, room),
    do: Enum.find(choice.notes, "", &(Model.cell_width(&1) <= room))

  defp help_paragraph(%{settings: s} = state) do
    field = Enum.at(Settings.fields(), s.cursor)

    head =
      [
        field.label <> "  (" <> field.key <> ")",
        String.duplicate("─", String.length(field.label) + String.length(field.key) + 4),
        effect_line(field.effect),
        where_line(s, field.key),
        ""
      ] ++ String.split(String.trim_trailing(field.help), "\n") ++ [""]

    %Paragraph{
      text: Enum.join(head ++ Settings.help_lines(state.commands), "\n"),
      wrap: true,
      scroll: {s.scroll, 0},
      block: %Block{title: " help — PgUp/PgDn or the wheel scrolls ", borders: [:all]}
    }
  end

  ## Command palette

  @doc """
  The palette's rows for the filter typed so far, and the cursor over them: each row is
  the table's entry with whether this client can run it now — `:ok`, `{:window, why}`
  (acts on a window, and none is activated) or `{:no, why}` (a session on this machine
  only, or a plane). Rows keep the table's order, so sections stay together.
  """
  @spec palette_view(map()) :: {[%{entry: Client.command(), status: term()}], non_neg_integer()}
  def palette_view(%{palette: %{query: query, cursor: cursor, return_to: return_to}} = state) do
    query = String.downcase(query)

    rows =
      state.commands
      |> Enum.filter(&matches?(&1, query))
      |> Enum.map(&%{entry: &1, status: availability(&1, return_to, state)})

    {rows, min(cursor, max(length(rows) - 1, 0))}
  end

  # Names, aliases and summaries, as the filter is typed: `mer` finds `/merge`.
  defp matches?(_entry, ""), do: true

  defp matches?(entry, query) do
    String.contains?(entry["name"], query) or
      Enum.any?(entry["aliases"], &String.contains?(&1, query)) or
      String.contains?(String.downcase(entry["summary"]), query)
  end

  defp availability(%{"availability" => "window", "name" => name}, return_to, _state) do
    if match?({:window, _}, return_to),
      do: :ok,
      else: {:window, "acts on a window: activate one (1-9), or name one — /#{name} 2"}
  end

  defp availability(%{"availability" => "local"}, _return_to, state) do
    if Client.remote?(state.session_id),
      do: {:no, "only for a session on this machine; this one runs on a plane"},
      else: :ok
  end

  defp availability(%{"availability" => "plane"}, _return_to, _state),
    do: {:no, "needs a plane: troupe login first"}

  defp availability(_entry, _return_to, _state), do: :ok

  # Centred above the status line and the command box, split into the list and the
  # selected command's detail — beside it where the screen is wide, below it where not.
  defp palette_popup(state, frame, cmd_rect) do
    {rows, cursor} = palette_view(state)
    top_height = max(cmd_rect.y - 1, 3)
    width = frame.width |> Kernel.-(4) |> min(120) |> max(min(frame.width, 24))
    height = top_height |> Kernel.-(2) |> min(34) |> max(min(top_height, 6))

    rect = %Rect{
      x: div(frame.width - width, 2),
      y: max(div(top_height - height, 2), 0),
      width: width,
      height: height
    }

    [list_rect, detail_rect] =
      if width >= 90,
        do: Layout.split(rect, :horizontal, [{:fill, 3}, {:fill, 2}]),
        else: Layout.split(rect, :vertical, [{:fill, 1}, {:length, min(9, div(height, 2))}])

    [
      {%Clear{}, rect},
      {palette_list(rows, cursor, state, list_rect), list_rect},
      {palette_detail(Enum.at(rows, cursor), state, detail_rect), detail_rect}
    ]
  end

  # One row per command under its section's heading; the cursor's row is the list's
  # selection, which the widget keeps in view.
  defp palette_list(rows, cursor, state, rect) do
    width = max(rect.width - 4, 10)

    name_w =
      rows |> Enum.map(&String.length(&1.entry["name"])) |> Enum.max(fn -> 6 end) |> Kernel.+(2)

    tagged =
      rows
      |> Enum.with_index()
      |> Enum.chunk_by(fn {row, _i} -> row.entry["section"] end)
      |> Enum.flat_map(fn [{first, _} | _] = chunk ->
        [
          {nil, section_line(first.entry["section"], width)}
          | Enum.map(chunk, fn {row, i} -> {i, palette_line(row, name_w, width)} end)
        ]
      end)

    {items, selected} =
      case tagged do
        [] -> {[nothing_line(state)], nil}
        _ -> {Enum.map(tagged, &elem(&1, 1)), Enum.find_index(tagged, &(elem(&1, 0) == cursor))}
      end

    %ExRatatui.Widgets.List{
      items: items,
      selected: selected,
      highlight_symbol: "▸ ",
      highlight_style: selected(),
      block: %Block{
        title: " commands — #{length(rows)} of #{length(state.commands)} ",
        borders: [:all],
        border_type: :double
      }
    }
  end

  defp section_line(section, width) do
    label = "─ " <> String.capitalize(section) <> " "

    Line.new([
      Span.new(label <> String.duplicate("─", max(width - String.length(label), 0)),
        style: Theme.style(:rail)
      )
    ])
  end

  # A command this client cannot run now is greyed rather than hidden; the detail says why.
  defp palette_line(%{entry: entry, status: status}, name_w, width) do
    style = Theme.style(if(status == :ok, do: nil, else: :muted))
    name = String.pad_trailing("/" <> entry["name"], name_w)
    summary = Model.wrap(entry["summary"], max(width - name_w, 8), :char) |> List.first() || ""

    Line.new([
      Span.new(name, style: Map.put(style, :modifiers, [:bold])),
      Span.new(summary, style: style)
    ])
  end

  defp nothing_line(%{commands: []}),
    do:
      Line.new([
        Span.new("the session's harness did not answer commands.list",
          style: Theme.style(:muted)
        )
      ])

  defp nothing_line(%{palette: %{query: query}}),
    do:
      Line.new([
        Span.new("nothing matches /#{query} — Enter runs it as typed",
          style: Theme.style(:muted)
        )
      ])

  defp palette_detail(nil, %{commands: []}, _rect) do
    %Paragraph{
      text:
        "No commands to list: the session's harness did not answer, or is older than this client.\n\nA command typed in full still runs; Esc goes back.",
      wrap: true,
      block: %Block{title: " detail ", borders: [:all]}
    }
  end

  defp palette_detail(nil, _state, _rect) do
    %Paragraph{
      text:
        "Nothing matches. Enter runs what you typed, as it would on the command line; Backspace narrows the filter; Esc goes back.",
      wrap: true,
      block: %Block{title: " detail ", borders: [:all]}
    }
  end

  defp palette_detail(%{entry: entry, status: status}, _state, rect) do
    example = if entry["example"], do: ["", "for example: " <> entry["example"]], else: []
    now = if status == :ok, do: [], else: ["", "not now: " <> elem(status, 1)]

    lines =
      [entry["summary"], "", entry["detail"]] ++
        example ++
        ["", source_word(entry["source"]) <> " · " <> availability_word(entry["availability"])] ++
        now

    %Paragraph{
      text: Enum.join(lines ++ body_lines(entry["body"], lines, rect), "\n"),
      wrap: true,
      block: %Block{title: " " <> entry["usage"] <> " ", borders: [:all]}
    }
  end

  # What a command a file defines sends, last in its detail (troupe Decision 814): its
  # first lines, as many as the pane has room for, and how many more the file holds.
  defp body_lines(body, head, rect) when is_binary(body) do
    width = max(rect.width - 2, 1)
    used = Enum.sum(Enum.map(head, &text_rows(&1, width))) + 2
    room = rect.height - 2 - used
    lines = body |> Model.sanitize() |> String.split("\n") |> Enum.map(&("│ " <> &1))

    shown =
      if Enum.sum(Enum.map(lines, &text_rows(&1, width))) <= room,
        do: lines,
        else: fit_rows(lines, room - 1, width)

    case length(lines) - length(shown) do
      0 -> ["", "sends:" | shown]
      1 -> ["", "sends:" | shown] ++ ["… 1 more line in the file"]
      more -> ["", "sends:" | shown] ++ ["… #{more} more lines in the file"]
    end
  end

  defp body_lines(_body, _head, _rect), do: []

  defp fit_rows(lines, room, width) do
    lines
    |> Enum.reduce_while({[], 0}, fn line, {acc, taken} ->
      taken = taken + text_rows(line, width)
      if taken <= room, do: {:cont, {[line | acc], taken}}, else: {:halt, {acc, taken}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp text_rows(text, width),
    do: text |> String.split("\n") |> Enum.map(&Model.height(&1, width, :word)) |> Enum.sum()

  defp source_word("builtin"), do: "built-in"
  defp source_word(other), do: other

  defp availability_word("always"), do: "always available"
  defp availability_word("window"), do: "acts on the activated window, or one named"
  defp availability_word("local"), do: "for a session on this machine"
  defp availability_word("plane"), do: "needs a plane"
  defp availability_word(other), do: other

  defp settings_command_line(%{settings: %{picker: %{typed?: true}} = s}) do
    {s.status || "",
     " choose a model — ↑↓ move · Enter picks · Esc back · `troupe config` lists them all "}
  end

  defp settings_command_line(%{settings: %{picker: p} = s}) when p != nil do
    {s.status || "", " choose a theme — ↑↓ move · Enter picks · Esc back "}
  end

  defp settings_command_line(%{settings: %{editing: nil} = s}) do
    hint =
      case Enum.at(Settings.fields(), s.cursor) do
        %{type: :bool} -> "Enter/Space toggles"
        %{type: :model} -> "Enter opens the model menu"
        %{type: :theme} -> "Enter opens the theme menu"
        _ -> "Enter edits"
      end

    {s.status || "", " settings — ↑↓ move · #{hint} · s where it goes · Esc back "}
  end

  defp settings_command_line(%{settings: %{editing: text} = s}) do
    field = Enum.at(Settings.fields(), s.cursor)
    {text <> "▏", " " <> (s.status || "#{field.key} = (Enter saves, Esc cancels)") <> " "}
  end

  # Where the selected setting's change goes: the scope and its file.
  defp settings_title(s) do
    field = Enum.at(Settings.fields(), s.cursor)
    scope = Settings.target(s.view, field.key, s.scope)
    "a change goes to #{scope}: #{Map.get(s.view.files, scope, "config.yaml")}"
  end

  defp where_line(s, key) do
    case Settings.layer(s.view, key) do
      nil -> "set by: unknown to this daemon"
      "default" -> "set by: nobody; this is the default"
      layer -> "set by: #{layer} (#{get_in(s.view.keys, [key, "source"])})"
    end
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

  # Nothing dispatched yet: the mask and the word over what to type, when the screen has
  # room for them, and the words alone when it has not.
  defp strip([], rect, state) do
    hint =
      "No branches. Type a command: " <>
        Enum.map_join(state.agents, "  ", &("/" <> &1)) <> "  /help"

    {mask_w, mask_h} = Theme.mask_size(:large)
    hint_h = div(Model.cell_width(hint) + rect.width - 1, max(rect.width, 1))

    if rect.width >= mask_w + 2 and rect.height >= mask_h + 4 + hint_h do
      top = rect.y + div(rect.height - (mask_h + 4 + hint_h), 2)
      mark_rect = %Rect{x: rect.x, y: top, width: rect.width, height: mask_h + 2}

      hint_rect = %Rect{
        x: rect.x,
        y: top + mask_h + 3,
        width: rect.width,
        height: rect.y + rect.height - (top + mask_h + 3)
      }

      # The mask is not wrapped: wrapping trims a line's leading blanks, and those are
      # the picture.
      mark =
        Theme.mask(:large, state.theme) ++
          [Line.new([]), Line.new([Span.new("troupe", style: Theme.style(nil, [:bold]))])]

      [
        {%Paragraph{text: mark, alignment: :center}, mark_rect},
        {%Paragraph{text: hint, style: Theme.style(:muted), alignment: :center, wrap: true},
         hint_rect}
      ]
    else
      [{%Paragraph{text: hint, style: Theme.style(:muted), wrap: true}, rect}]
    end
  end

  defp strip(windows, rect, state) do
    shown = Enum.take(windows, 9)
    rects = tile_rects(rect, length(shown))

    shown
    |> Enum.with_index(1)
    |> Enum.zip(rects)
    |> Enum.flat_map(fn {{w, n}, r} -> window_tile(w, n, r, state) end)
  end

  # A session nobody has said anything to yet is the TUI's empty state: its one window
  # says it started and little else, so the mask and the word stand in the middle of it
  # until the first line is typed. Not wrapped: wrapping trims a line's leading blanks,
  # and those are the picture.
  defp lockup(w, rect, used, state) do
    {mask_w, mask_h} = Theme.mask_size(:large)
    {inner_w, inner_h} = {rect.width - 2, rect.height - 2}
    height = mask_h + 2
    top = max(div(inner_h - height, 2), used + 1)

    if fresh?(w) and inner_w >= mask_w + 2 and top + height <= inner_h do
      area = %Rect{x: rect.x + 1, y: rect.y + 1 + top, width: inner_w, height: height}

      mark =
        Theme.mask(:large, state.theme) ++
          [Line.new([]), Line.new([Span.new("troupe", style: Theme.style(nil, [:bold]))])]

      [{%Paragraph{text: mark, alignment: :center}, area}]
    else
      []
    end
  end

  defp fresh?(w) do
    w.pending == [] and
      w.agents
      |> Map.get(w.path, %{transcript: []})
      |> Map.get(:transcript, [])
      |> Enum.all?(&match?({:system, _}, &1))
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

    tile = %Paragraph{
      text: styled(rows),
      wrap: false,
      style: text_style(w),
      block: %Block{
        # The mark takes the top border's right end, three cells with its spaces; the
        # title fits in what is left.
        title: tile_title(w, n, state, inner_w - 3),
        title_style: title_style(w),
        titles: [%Title{content: mark(w, state), alignment: :right}],
        borders: [:all],
        border_type: if(focused?, do: :double, else: :rounded),
        border_style: border_style(w, state)
      }
    }

    [{tile, rect} | lockup(w, rect, length(rows), state)]
  end

  defp tile_title(w, n, state, inner_w) do
    badge = if w.badge, do: " ●", else: ""
    blink = if w.state == :needs_input and blink?(state), do: " ▶ needs input", else: ""
    stats = " · #{Model.elapsed(w, state.now)} · #{Model.tokens(w)}"

    [
      " #{n} #{w.path} · #{w.state}#{badge}#{blink}#{stats} ",
      " #{n} #{w.path} · #{w.state}#{badge}#{blink} ",
      " #{n} #{w.path} · #{w.state}#{badge} ",
      " #{n} #{w.path} ",
      " #{n} "
    ]
    |> fit(inner_w)
  end

  @doc """
  The mark in a window's corner (#228): one glyph, one meaning — fill is what the agent
  did alone, hollow is what waits on you. ◐ ◓ ◑ ◒ turning while its agent works; ◑, the
  mark itself, in the reserved colour while it needs a person, blinking with its border;
  ⏺ done and not yet read; ○ at rest; ✗ failed. It is always the glyph and the word in
  the title and the colour together, never the colour alone, so it reads with none.
  """
  @spec mark(map(), map()) :: Span.t()
  def mark(%{state: :needs_input}, state) do
    style = if blink?(state), do: Theme.style(:needs_you, [:bold]), else: Theme.style(:rail)
    Span.new(" ◑ ", style: style)
  end

  def mark(%{state: :done_unread, badge: true}, _state),
    do: Span.new(" ⏺︎ ", style: Theme.style(:ok, [:bold]))

  def mark(%{state: :done_unread}, _state), do: Span.new(" ○ ", style: Theme.style(:muted))

  def mark(%{state: :failed_unread, badge: true}, _state),
    do: Span.new(" ✗ ", style: Theme.style(:error, [:bold]))

  def mark(%{state: :failed_unread}, _state), do: Span.new(" ✗ ", style: Theme.style(:muted))

  def mark(_w, state), do: Span.new(" #{Model.spinner(state.now)} ", style: Theme.style(:working))

  # The widest candidate that fits, or the narrowest when none does.
  defp fit(candidates, width) do
    Enum.find(candidates, List.last(candidates), &(Model.cell_width(&1) <= width))
  end

  # A window that needs you is the one thing on screen that blinks, and the only border
  # in the reserved colour; everything else is quieter than it.
  defp border_style(%{state: :needs_input}, state) do
    if blink?(state),
      do: Theme.style(:needs_you_edge, [:bold]),
      else: Theme.style(:rail)
  end

  defp border_style(%{state: :running}, _), do: Theme.style(:working_edge)
  defp border_style(%{state: :done_unread, badge: true}, _), do: Theme.style(:ok, [:bold])
  defp border_style(%{state: :done_unread}, _), do: Theme.style(:rail, [:dim])
  defp border_style(%{state: :failed_unread, badge: true}, _), do: Theme.style(:error, [:bold])
  defp border_style(%{state: :failed_unread}, _), do: Theme.style(:rail, [:dim])
  defp border_style(_, _), do: Theme.style(nil)

  defp title_style(%{state: :needs_input}), do: Theme.style(:needs_you, [:bold])
  defp title_style(_w), do: nil

  # On for half a second and off for half: about once a second, whatever the tick's pace;
  # lit throughout when the person turned blinking off (`ui.blink`).
  defp blink?(%{now: now} = state), do: Theme.lit?(Map.get(state, :theme, %{}), now)

  defp text_style(%{state: s}) when s in [:done_unread, :failed_unread],
    do: Theme.style(nil, [:dim])

  defp text_style(_), do: Theme.style(nil)

  ## Activated pane

  defp pane(g, state) do
    w = g.window

    # Only the blocks from the one at the top of the view are wrapped: the heights
    # already say where the view starts, so nothing above it is measured again.
    {first, row} = block_at(g.heights, g.offset)

    rows =
      g.blocks
      |> Enum.drop(first)
      |> Enum.concat()
      |> Model.rows(g.inner_w, row, g.inner_h)
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
             thumb_style: Theme.style(:muted),
             track_style: Theme.style(:rail)
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

  # A list's selected row: the light that is not a status, bold.
  defp selected, do: Theme.style(:accent, [:bold])

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

  # A segment's tag, as the model draws it, in a role (issue #228). The pink is for the
  # three things that wait on a person — the pending line with the keys that answer it,
  # an option ticked in a question, and "waiting for you" where the activity line would
  # be — and a test holds every other tag the model emits to something else. The neon
  # that is left is the accent, for what structures a reply; reasoning stays muted.
  @doc false
  @spec segment_style(atom() | Style.t(), atom(), String.t()) :: Style.t()
  def segment_style(%Style{} = style, _kind, _text), do: style
  def segment_style(:muted, _kind, _text), do: Theme.style(:muted)

  def segment_style(tag, _kind, _text) when tag in [:code_rail, :quote_rail, :linenum, :fill],
    do: Theme.style(:rail)

  def segment_style(:code_lang, _kind, _text), do: Theme.style(:accent)
  def segment_style(:code_inline, _kind, _text), do: Theme.style(:accent)
  def segment_style(:strong, _kind, _text), do: Theme.style(nil, [:bold])

  def segment_style(tag, :heading, _text) when tag in [:heading, :text],
    do: Theme.style(:accent, [:bold])

  def segment_style(:heading, _kind, _text), do: Theme.style(:accent, [:bold])
  def segment_style(:bullet_marker, _kind, _text), do: Theme.style(:accent)
  def segment_style(:quote, _kind, _text), do: Theme.style(nil, [:dim])
  def segment_style(:system, _kind, _text), do: Theme.style(nil, [:dim])
  def segment_style(:reasoning_marker, _kind, _text), do: Theme.style(:muted)
  def segment_style(:reasoning_title, _kind, _text), do: Theme.style(:muted, [:dim])
  def segment_style(:reasoning_body, _kind, _text), do: Theme.style(:muted, [:dim])
  def segment_style(:pending, _kind, _text), do: Theme.style(:needs_you, [:bold])
  def segment_style(:diff_add, _kind, _text), do: Theme.style(:added)
  def segment_style(:diff_del, _kind, _text), do: Theme.style(:removed)
  def segment_style(:diff_meta, _kind, _text), do: Theme.style(:hunk)
  def segment_style(:user_marker, _kind, _text), do: Theme.style(:accent, [:bold])
  def segment_style(:activity_glyph, _kind, _text), do: Theme.style(:working)

  # `Model.activity_line/4` says this where a spinner would be when the agent is waiting
  # on a person; it is the one activity line that is not the machine working.
  def segment_style(:activity, _kind, "waiting for you" <> _),
    do: Theme.style(:needs_you, [:bold])

  def segment_style(:activity, _kind, _text), do: Theme.style(:working, [:dim])
  def segment_style(:tool_glyph, _kind, text), do: glyph_style(text)
  def segment_style(:tool_name, _kind, _text), do: Theme.style(nil, [:bold])
  def segment_style(:tool_note, _kind, _text), do: Theme.style(:muted)

  # A wrapped tool head's later rows have no glyph to key off: draw them dim.
  def segment_style(kind, kind, _text) when kind in [:tool_ok, :tool_err, :tool_running],
    do: Theme.style(nil, [:dim])

  def segment_style(_tag, _kind, _text), do: Theme.style(nil)

  defp glyph_style("✓"), do: Theme.style(:ok)
  defp glyph_style("✗"), do: Theme.style(:error, [:bold])
  defp glyph_style(_), do: Theme.style(:working)

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
    |> todo_texts(path == w.path)
    |> Enum.map(&{:text, indent <> &1})
  end

  # The window's own list is numbered, because the number is what `/todo cancel` takes:
  # an item's id is the model's, or a hash of its text, and is never shown. A subagent's
  # list is not the one `/todo` edits, so it has no numbers to mistake for its own.
  defp todo_texts(todos, true) do
    todos
    |> Enum.with_index(1)
    |> Enum.map(fn {t, n} -> "#{n}. [#{glyph(t.status)}] #{t.text}" end)
  end

  defp todo_texts(todos, false), do: Enum.map(todos, &"[#{glyph(&1.status)}] #{&1.text}")

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
      "#{goal_note(state.model)}#{loop_note(state.model)}" <>
        " · #{watch}#{mcp}" <>
        " · #{state.session_id}" <>
        remote_note(state) <>
        if(notice, do: " · #{notice}", else: "")

    text =
      if state.quit_armed,
        do: text <> " · PRESS CTRL-C AGAIN TO QUIT",
        else: text <> " · /help lists the commands · /settings · /quit or Ctrl-C twice exits"

    # The count of windows that need you, and how to answer, are the needs-you status:
    # in the reserved colour, on a line that is otherwise muted.
    {needs, others} =
      case Model.attention(state.model) do
        [] -> {"", "idle"}
        [{:needs_input, needs} | rest] -> {needs, Enum.map_join(rest, &(", " <> elem(&1, 1)))}
        parts -> {"", Enum.map_join(parts, ", ", &elem(&1, 1))}
      end

    line =
      [{needs, :needs_you}, {others, nil}, {hint, :needs_you}, {text, nil}]
      |> Enum.reject(fn {part, _role} -> part == "" end)
      |> Enum.map(fn
        {part, nil} -> Span.new(part)
        {part, role} -> Span.new(part, style: Theme.style(role, [:bold]))
      end)
      |> Line.new()

    {%Paragraph{text: [line], style: Theme.style(:muted)}, rect}
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

  # A remote session says what it is and what it will not let you do; a local one, in
  # the daemon on this machine (no plane), says only the second, when there is one.
  defp remote_note(%{model: %{remote: %{plane_url: nil} = remote}}) do
    case remote[:reason] do
      reason when is_binary(reason) -> " · #{reason}"
      _ -> ""
    end
  end

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
          # The box shows the slash; a line that carries its own (one the palette put
          # there, or a typed one) is not shown with two.
          prompt = if String.starts_with?(state.cmd_text, "/"), do: "", else: "/"

          {{:edit, {prompt <> state.cmd_text, state.cmd_pos + String.length(prompt)}},
           if(multiline?(state.cmd_text), do: pasted_title(state.cmd_text), else: " command ")}

        :palette ->
          query = state.palette.query

          {{:edit, {"/" <> query, String.length(query) + 1}},
           " commands — type to filter · ↑↓ move · Enter runs · Tab puts it on the line · Esc back "}

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
          {"", " mcp — ↑↓ move · r reload · c check · d enable/disable · x remove · Esc back "}

        :hq ->
          {hq_text(state), Troupe.UI.HQ.footer(state.hq)}
      end

    focused_cmd? = state.focus in [:command, :palette]

    {%Paragraph{
       text: input_box_text(state, text, box_rows),
       block: %Block{
         title: title,
         borders: [:all],
         border_style: Theme.style(if(focused_cmd?, do: nil, else: :rail))
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
