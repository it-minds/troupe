defmodule Troupe.UI.TUI.Server do
  @moduledoc """
  The terminal UI: an `ExRatatui.App` subscribed to one session through
  `Troupe.Client`, which is the only module it is allowed to call. It never
  slows an agent down: deltas are coalesced and the screen redraws at most
  30 times per second; when the mailbox grows past a threshold the queued
  deltas are collapsed in one pass. After a restart it rebuilds every window
  from the session log.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias Troupe.Client
  alias Troupe.Protocol.Glob
  alias Troupe.Settings
  alias Troupe.UI.HQ
  alias Troupe.UI.TUI.{Input, Model, View}

  @tick_ms 33
  @mailbox_threshold 50

  @type state :: %{
          session_id: String.t(),
          workspace: String.t(),
          model: Model.t(),
          focus:
            :command
            | {:window, String.t()}
            | :settings
            | :observer
            | :sessions
            | :files
            | :mcp
            | :hq
            | :palette,
          cmd_text: String.t(),
          cmd_pos: non_neg_integer(),
          win_text: String.t(),
          win_pos: non_neg_integer(),
          agents: [String.t()],
          commands: [Client.command()],
          palette: palette() | nil,
          tick: non_neg_integer(),
          now: integer(),
          dirty: boolean(),
          tick_scheduled: boolean(),
          quit_armed: boolean(),
          win_armed: win_armed() | nil,
          expanded: boolean(),
          pane: pane(),
          selection: selection() | nil,
          size: {non_neg_integer(), non_neg_integer()},
          answer: answer() | nil,
          settings: settings() | nil,
          observer: %{cursor: non_neg_integer()} | nil,
          sessions: sessions() | nil,
          files: files() | nil,
          mcp_cursor: non_neg_integer(),
          hq: HQ.t() | nil,
          slow_render_ms: non_neg_integer(),
          on_quit: (-> any())
        }

  @typedoc """
  A window key that is armed but not yet acted on: `{agent_path, "x" | "d"}`.
  Both keys take a branch away, and a window is also where the user types, so
  neither acts on one press (Decision 83): the first press types the letter and
  arms, and only an immediate second press of the same key acts. Anything else
  typed clears it, which is why it lives here and not in the log — it is a
  keystroke, not a decision.
  """
  @type win_armed :: {String.t(), String.t()}

  @typedoc """
  Activated-pane state: which of the branch's agents is shown (nil = the root),
  where the transcript is scrolled (`:follow` sticks to the bottom; a row offset
  stays put while new content arrives), and how many transcript entries there
  were when the user last scrolled, so the title can say how much arrived since.
  """
  @type pane :: %{
          agent: String.t() | nil,
          scroll: :follow | non_neg_integer(),
          seen_entries: non_neg_integer()
        }

  @typedoc """
  A mouse selection in the activated pane. Both ends are *transcript*
  coordinates — `{visual_row, cell_col}`, the row absolute in the wrapped
  transcript — so new output and scrolling leave them where the user put them.
  It is view state like `pane`, never a fold over the log: a TUI restart comes
  back with nothing selected, and a reflow (resize) drops it.
  """
  @type point :: {non_neg_integer(), non_neg_integer()}
  @type selection :: %{anchor: point(), cursor: point(), dragging?: boolean()}

  @typedoc """
  Settings-page state: what the daemon says the settings are (`view`, every key with its
  value and the layer that set it), the config as loaded, for the models it detects, the
  scope picked with `s` (nil: the file each value came from), the cursor, the value being
  typed, and the open menu — a setting with choices (the models) shows them instead of
  asking you to type an identifier from memory.
  """
  @type settings :: %{
          view: Settings.view(),
          config: Troupe.Config.t(),
          scope: String.t() | nil,
          cursor: non_neg_integer(),
          editing: String.t() | nil,
          scroll: non_neg_integer(),
          status: String.t() | nil,
          picker: picker() | nil
        }

  @typedoc "An open menu: the choices offered and where the cursor sits (past the end means type one)."
  @type picker :: %{choices: [Settings.choice()], cursor: non_neg_integer()}

  @typedoc """
  Command-palette state (Decision 119): the filter typed so far, the cursor over the
  rows it leaves, and where the palette was opened from — a command picked from a
  window acts on that window, and Esc goes back there. The rows themselves are a view
  over `commands`, the harness's table, computed when drawn (`View.palette_view/1`).
  """
  @type palette :: %{
          query: String.t(),
          cursor: non_neg_integer(),
          return_to: :command | {:window, String.t()}
        }

  @typedoc """
  A multiple-choice answer being assembled: which question it belongs to and the
  labels ticked so far. Held in the UI rather than the log because it is a
  cursor, not a decision — nothing outside this process may depend on it, and
  it is dropped the moment the question leaves `pending`.
  """
  @type answer :: %{call_id: String.t(), selected: [String.t()]}

  @typedoc """
  Session-picker state: the sessions found on disk for the directory the TUI was
  opened in, and where the cursor sits. Read once when the page opens (`r`
  refreshes it), never while a frame is drawn.
  """
  @type sessions :: %{entries: [Troupe.Client.summary()], cursor: non_neg_integer()}

  @typedoc """
  Files-panel state: the mount and directory being listed, what `fs.list`
  answered, where the cursor sits, and the file being previewed. `version` is
  the model's `files_version` as of the last listing, so an `fs.changed` that
  arrives while the panel is open reloads it.
  """
  @type files :: %{
          path: String.t(),
          entries: [map()],
          cursor: non_neg_integer(),
          preview: {String.t(), [String.t()]} | nil,
          error: String.t() | nil,
          version: non_neg_integer()
        }

  def via(sid), do: {:via, Registry, {Troupe.Client.Registry, {:tui, sid}}}

  ## ExRatatui.App

  @impl true
  def mount(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    :ok = Client.subscribe(sid)
    :ok = Client.subscribe_settings()
    model = rebuild(sid)

    state = %{
      session_id: sid,
      workspace: model.workspace,
      model: model,
      focus: :command,
      cmd_text: "",
      cmd_pos: 0,
      win_text: "",
      win_pos: 0,
      agents: Client.commands(sid),
      commands: Client.command_table(sid),
      palette: nil,
      tick: 0,
      now: System.system_time(:millisecond),
      dirty: false,
      tick_scheduled: false,
      quit_armed: false,
      win_armed: nil,
      expanded: false,
      pane: fresh_pane(),
      selection: nil,
      settings: nil,
      answer: nil,
      observer: nil,
      sessions: nil,
      files: nil,
      mcp_cursor: 0,
      mcp_page: nil,
      # The sign-in URL the daemon last answered, `%{name, url}`, shown on the page in
      # full for a person whose browser did not open (troupe-remote Decision 741).
      mcp_sign_in: nil,
      hq: nil,
      quitting: false,
      size: initial_size(opts),
      slow_render_ms: Keyword.get(opts, :slow_render_ms, 0),
      on_quit: Keyword.get(opts, :on_quit, fn -> :ok end)
    }

    # `troupe resume` with no id opens on the picker: the newest session is live
    # behind it, and the list says what else this directory holds.
    state =
      case Keyword.get(opts, :page) do
        :sessions -> open_sessions(state)
        :hq -> open_hq(state, Keyword.get(opts, :plane))
        _ -> state
      end

    {:ok, state |> recheck_loop() |> schedule_tick()}
  end

  @impl true
  def render(state, frame) do
    if state.slow_render_ms > 0, do: Process.sleep(state.slow_render_ms)
    trace_first_frame()
    View.render(state, frame)
  end

  # TROUPE_TRACE_STARTUP=1 prints the wall-clock time from VM start to the first frame.
  defp trace_first_frame do
    if System.get_env("TROUPE_TRACE_STARTUP") &&
         not :persistent_term.get({__MODULE__, :first_frame}, false) do
      :persistent_term.put({__MODULE__, :first_frame}, true)
      {ms, _} = :erlang.statistics(:wall_clock)
      IO.puts(:stderr, "troupe: first TUI frame #{ms} ms after VM start")
    end
  end

  # After switching sessions the old session's actors may still be publishing:
  # anything from a session this window no longer shows is not ours to fold in.
  @impl true
  def handle_info({:troupe_event, %{session_id: other}}, %{session_id: sid} = state)
      when other != sid,
      do: {:noreply, state, render?: false}

  def handle_info({:troupe_event, %{type: :llm_delta} = event}, state) do
    state = state |> apply_event(event) |> drain_mailbox()
    {:noreply, schedule_tick(%{state | dirty: true}), render?: false}
  end

  def handle_info({:troupe_event, event}, state) do
    {:noreply, state |> apply_event(event) |> Map.put(:dirty, true) |> schedule_tick(),
     render?: false}
  end

  def handle_info(:tick, state) do
    state = %{
      state
      | tick: state.tick + 1,
        now: System.system_time(:millisecond),
        tick_scheduled: false
    }

    state = state |> resume_follow() |> refresh_files()
    needs_blink = Enum.any?(Model.windows(state.model), &(&1.state in [:running, :needs_input]))

    if state.dirty or needs_blink do
      {:noreply, schedule_tick(%{state | dirty: false}, if(state.dirty, do: @tick_ms, else: 120)),
       render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  # Test seam: render synchronously regardless of dirtiness.
  # A fleet `summary` updates the HQ list in place; with HQ closed there is
  # nothing to update and the message is dropped. It asks for a frame itself: with
  # every window at rest nothing else is ticking.
  def handle_info({:troupe_fleet, _plane, session_id, diff}, %{hq: hq} = state) when hq != nil do
    state = %{state | hq: HQ.summary(hq, session_id, diff), dirty: true}
    {:noreply, schedule_tick(state), render?: false}
  end

  def handle_info({:troupe_fleet, _plane, _session_id, _diff}, state),
    do: {:noreply, state, render?: false}

  # A settings file changed, here or in another client (#57): an open settings page reads
  # them again, so a model picked in the desktop app is on it without a key pressed.
  def handle_info({:troupe_settings_changed, _changed}, %{settings: s} = state) when s != nil do
    state = %{refresh_settings(state) | dirty: true}
    {:noreply, schedule_tick(state), render?: false}
  end

  def handle_info({:troupe_settings_changed, _changed}, state),
    do: {:noreply, state, render?: false}

  def handle_info(:force_render, state),
    do: {:noreply, %{state | now: System.system_time(:millisecond), dirty: false}, render?: true}

  # What the session said about the loop the status line shows (`recheck_loop/1`). Kept
  # only while it runs; an error says nothing either way, and the next check asks again.
  def handle_info({:loop_checked, sid, id, answer}, %{session_id: sid} = state) do
    case answer do
      {:ok, %{"state" => "running"}} ->
        {:noreply, state, render?: false}

      {:ok, _stopped_or_none} ->
        state = %{state | model: Model.loop_ended(state.model, id), dirty: true}
        {:noreply, schedule_tick(state), render?: false}

      {:error, _reason} ->
        {:noreply, state, render?: false}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state, render?: false}

  # A scrolled-up pane that ends up at the bottom (because the transcript shrank) follows
  # the tail again, the same way scrolling down to the bottom does.
  defp resume_follow(%{pane: %{scroll: n}} = state) when is_integer(n) do
    case View.pane_geometry(state) do
      %{follow?: true} -> follow(state)
      _ -> state
    end
  end

  defp resume_follow(state), do: state

  @impl true
  def handle_event(%Key{kind: "release"}, state), do: {:noreply, state, render?: false}

  def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, %{quit_armed: true} = state) do
    state.on_quit.()
    {:stop, state}
  end

  def handle_event(%Key{code: "c", modifiers: ["ctrl"]}, state),
    do: {:noreply, %{state | quit_armed: true}}

  def handle_event(%Key{code: code, modifiers: ["ctrl"]}, state) when code in ["d", "q"] do
    state.on_quit.()
    {:stop, state}
  end

  # Ctrl-K opens the palette wherever nothing is typed yet; with text on the line it is
  # still the editor's kill-to-end (Decision 88).
  def handle_event(%Key{code: "k", modifiers: ["ctrl"]}, %{focus: :command, cmd_text: ""} = state),
    do: {:noreply, open_palette(%{state | quit_armed: false})}

  def handle_event(
        %Key{code: "k", modifiers: ["ctrl"]},
        %{focus: {:window, _}, win_text: ""} = state
      ),
      do: {:noreply, open_palette(%{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :command} = state),
    do: finish(command_key(key, %{state | quit_armed: false}))

  def handle_event(%Key{} = key, %{focus: :palette} = state),
    do: finish(palette_key(key, %{state | quit_armed: false}))

  def handle_event(%Key{} = key, %{focus: :settings} = state),
    do: {:noreply, settings_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :observer} = state),
    do: {:noreply, observer_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :sessions} = state),
    do: {:noreply, sessions_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :files} = state),
    do: {:noreply, files_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :mcp} = state),
    do: {:noreply, mcp_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :hq} = state),
    do: {:noreply, hq_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: {:window, path}} = state) do
    if Map.has_key?(state.model.windows, path),
      do: {:noreply, window_key(key, path, disarm(%{state | quit_armed: false}, key))},
      else: handle_event(key, to_command_line(state))
  end

  # A reflow moves every wrapped row, so transcript coordinates no longer point at
  # the text the user selected: drop the selection rather than highlight the wrong cells.
  def handle_event(%Resize{width: w, height: h}, state),
    do: {:noreply, %{state | size: {w, h}, selection: nil}}

  # Bracketed paste arrives as one %Paste{} event, not a stream of keys. Insert the
  # raw text where the user is focused: the command line, an active window's input box,
  # or a settings field.
  def handle_event(%Paste{content: content}, state) do
    state = %{state | quit_armed: false}

    case state.focus do
      :command ->
        {:noreply, put_cmd(state, Input.insert(cmd_input(state), content))}

      {:window, _} ->
        {:noreply, %{put_win(state, Input.insert(win_input(state), content)) | win_armed: nil}}

      :observer ->
        {:noreply, state, render?: false}

      :sessions ->
        {:noreply, state, render?: false}

      :files ->
        {:noreply, state, render?: false}

      :mcp ->
        {:noreply, state, render?: false}

      :hq ->
        {:noreply, state, render?: false}

      :palette ->
        {:noreply, state, render?: false}

      :settings ->
        {:noreply, paste_into_settings(state, content)}
    end
  end

  def handle_event(%Mouse{kind: "down"}, %{focus: focus} = state)
      when focus in [:settings, :observer, :sessions, :files, :mcp, :hq, :palette],
      do: {:noreply, state, render?: false}

  # Click-drag inside the transcript selects text: with mouse reporting on the
  # terminal's own selection is gone, so Troupe owns one (Decision 82). A press
  # that lands anywhere but the transcript's interior is a tile click and falls
  # through to the clause below.
  def handle_event(
        %Mouse{kind: "down", button: "left", x: x, y: y},
        %{focus: {:window, _}} = state
      ) do
    case pane_point(state, x, y) do
      nil ->
        clicked_tile(state, x, y)

      point ->
        {:noreply, %{state | selection: %{anchor: point, cursor: point, dragging?: true}},
         render?: false}
    end
  end

  def handle_event(%Mouse{kind: "down", button: "left", x: x, y: y}, state),
    do: clicked_tile(state, x, y)

  # Dragging past the top or bottom row scrolls, so a selection can grow beyond
  # the viewport; the cursor is clamped into the interior, and because both ends
  # are absolute transcript rows the scroll leaves the far end where it was.
  def handle_event(
        %Mouse{kind: "drag", button: "left", x: x, y: y},
        %{selection: %{dragging?: true} = sel, focus: {:window, _}} = state
      ) do
    case View.pane_geometry(state) do
      nil ->
        {:noreply, state, render?: false}

      g ->
        state =
          case View.pane_edge(g, y) do
            :above -> scroll_by(state, -1)
            :below -> scroll_by(state, 1)
            nil -> state
          end

        cursor = clamped_point(View.pane_geometry(state), x, y) || sel.cursor
        {:noreply, %{state | selection: %{sel | cursor: cursor}}}
    end
  end

  # Release ends the drag and copies: click-drag-release putting text on the
  # clipboard is the muscle memory mouse reporting took away. A press with no
  # drag selected nothing, so it clears rather than copying one cell.
  def handle_event(%Mouse{kind: "up", button: "left"}, %{selection: %{} = sel} = state) do
    if sel.anchor == sel.cursor,
      do: {:noreply, %{state | selection: nil}, render?: false},
      else: {:noreply, copy_selection(%{state | selection: %{sel | dragging?: false}})}
  end

  # The wheel scrolls whatever is under focus: the pane's transcript, the observer's
  # cursor, or the settings help. Three rows per notch, like a terminal.
  def handle_event(%Mouse{kind: kind}, state) when kind in ["scroll_up", "scroll_down"] do
    step = if kind == "scroll_up", do: -3, else: 3

    case state.focus do
      {:window, _} ->
        {:noreply, scroll_by(state, step)}

      :observer ->
        {rows, cursor} = View.observer_view(state)
        cursor = cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(max(length(rows) - 1, 0))
        {:noreply, %{state | observer: %{state.observer | cursor: cursor}}}

      :sessions ->
        {entries, cursor} = View.sessions_view(state)
        cursor = cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(max(length(entries) - 1, 0))
        {:noreply, %{state | sessions: %{state.sessions | cursor: cursor}}}

      :files ->
        {entries, cursor} = View.files_view(state)
        cursor = cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(max(length(entries) - 1, 0))
        {:noreply, %{state | files: %{state.files | cursor: cursor}}}

      :mcp ->
        count = length(View.mcp_entries(state))
        cursor = state.mcp_cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(max(count - 1, 0))
        {:noreply, %{state | mcp_cursor: cursor}}

      :settings when state.settings.picker != nil ->
        p = state.settings.picker
        cursor = p.cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(length(p.choices))
        {:noreply, put_settings(state, picker: %{p | cursor: cursor})}

      :settings ->
        {:noreply, put_settings(state, scroll: max(state.settings.scroll + step, 0))}

      :palette ->
        {:noreply, move_cursor(state, div(step, 3))}

      _ ->
        {:noreply, state, render?: false}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  # `/quit`, from the line or the palette, is the one command that ends the app.
  defp finish(%{quitting: true} = state) do
    state.on_quit.()
    {:stop, state}
  end

  defp finish(state), do: {:noreply, state}

  # An armed `x`/`d` (Decision 83) must be confirmed by the very next keystroke:
  # any other key — including more typing — takes the arming away, so the letter
  # stays in the input box as text and nothing is cancelled or dismissed.
  defp disarm(%{win_armed: {_path, code}} = state, %Key{code: pressed}) when pressed != code,
    do: %{state | win_armed: nil}

  defp disarm(state, _key), do: state

  # A press outside the transcript: the tiles are the only other thing a click means.
  defp clicked_tile(state, x, y) do
    case clicked_window(state, x, y) do
      nil -> {:noreply, state, render?: false}
      path when state.focus == {:window, path} -> {:noreply, follow(state)}
      path -> {:noreply, activate(%{state | quit_armed: false}, path)}
    end
  end

  # The transcript coordinate under a screen cell, or nil when there is no pane
  # or the cell is not inside it.
  defp pane_point(state, x, y) do
    case View.pane_geometry(state) do
      nil -> nil
      g -> View.pane_point(g, x, y)
    end
  end

  # While dragging, a pointer outside the interior still has to move the cursor:
  # clamp it to the nearest cell inside instead of dropping the event.
  defp clamped_point(nil, _x, _y), do: nil

  defp clamped_point(g, x, y) do
    x = x |> max(g.left.x + 1) |> min(g.left.x + g.inner_w)
    y = y |> max(g.left.y + 1) |> min(g.left.y + g.inner_h)
    View.pane_point(g, x, y)
  end

  # Hit-test a click against the tiles using the same layout the view draws.
  defp clicked_window(%{size: {w, h}} = state, x, y) do
    windows = Model.windows(state.model)
    {strip, _pane, _status, _cmd} = View.layout(w, h, match?({:window, _}, state.focus))

    strip
    |> View.tile_rects(length(windows))
    |> Enum.zip(windows)
    |> Enum.find_value(fn {r, win} ->
      if x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height, do: win.path
    end)
  end

  defp clicked_window(_state, _x, _y), do: nil

  defp initial_size(opts) do
    case {Keyword.get(opts, :width), Keyword.get(opts, :height)} do
      {w, h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> terminal_size()
    end
  end

  defp terminal_size do
    case ExRatatui.terminal_size() do
      {w, h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> {80, 24}
    end
  rescue
    _ -> {80, 24}
  end

  ## Command line keys

  defp command_key(%Key{code: "esc"}, state), do: put_cmd(state, "")

  defp command_key(%Key{code: "tab"}, state),
    do: put_cmd(state, complete_command(state.cmd_text, state))

  # A newline in the box rather than running the command: any modifier on Enter,
  # and Ctrl-J. The box holds multiline (typed or pasted) input, folded to a
  # `<pasted N lines>` marker in the title. Shift-Enter alone is not enough:
  # most terminals send a bare `\r` for it, indistinguishable from Enter.
  defp command_key(%Key{code: "enter", modifiers: mods}, state) when mods != [],
    do: put_cmd(state, Input.insert(cmd_input(state), "\n"))

  defp command_key(%Key{code: "j", modifiers: ["ctrl"]}, state),
    do: put_cmd(state, Input.insert(cmd_input(state), "\n"))

  defp command_key(%Key{code: "enter"}, %{cmd_text: ""} = state) do
    case Model.windows(state.model) do
      [] -> state
      ws -> activate(state, (Enum.find(ws, &(&1.state == :needs_input)) || hd(ws)).path)
    end
  end

  defp command_key(%Key{code: "enter"}, state), do: run_command(state, String.trim(state.cmd_text))

  defp command_key(%Key{code: <<d>>}, %{cmd_text: ""} = state) when d in ?1..?9 do
    case Enum.at(Model.windows(state.model), d - ?1) do
      nil -> state
      w -> activate(state, w.path)
    end
  end

  # `/` on an empty line opens the palette rather than typing a slash the box already
  # shows (Decision 119); the rest of the command is typed into the palette's filter.
  defp command_key(%Key{code: "/", modifiers: mods}, %{cmd_text: ""} = state)
       when mods in [[], ["shift"]],
       do: open_palette(state)

  defp command_key(%Key{code: code, modifiers: mods} = key, state)
       when byte_size(code) >= 1 and mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: put_cmd(state, Input.insert(cmd_input(state), code)),
      else: editing_key(key, state)
  end

  defp command_key(key, state), do: editing_key(key, state)

  # Motions and deletions the editor owns (Decision 88): they come last, so
  # every binding above — Esc, Tab, Enter, a digit that picks a window — wins.
  defp editing_key(key, %{focus: :command} = state) do
    case Input.key(key, cmd_input(state)) do
      {:ok, input} -> put_cmd(state, input)
      :pass -> state
    end
  end

  defp editing_key(key, state) do
    case Input.key(key, win_input(state)) do
      {:ok, input} -> put_win(state, input)
      :pass -> state
    end
  end

  # The command line and a window's input box as `{text, cursor}` pairs, and the
  # two ways back: a bare string puts the cursor at its end (a completion, a
  # clear), a pair keeps the cursor the editor chose.
  defp cmd_input(%{cmd_text: text, cmd_pos: pos}), do: {text, pos}
  defp win_input(%{win_text: text, win_pos: pos}), do: {text, pos}

  defp put_cmd(state, text) when is_binary(text), do: put_cmd(state, {text, String.length(text)})

  defp put_cmd(state, {text, pos}),
    do: %{state | cmd_text: text, cmd_pos: Input.clamp(text, pos)}

  defp put_win(state, text) when is_binary(text), do: put_win(state, {text, String.length(text)})

  defp put_win(state, {text, pos}),
    do: %{state | win_text: text, win_pos: Input.clamp(text, pos)}

  # The built-ins this client runs itself, one clause of `builtin/4` each. How each is
  # typed, described and aliased is the harness's table (`state.commands`, Decision
  # 698); this is only which of them the TUI implements, and the suite holds the two
  # equal, so a command added to the table without a clause here fails a test rather
  # than being dispatched as an agent.
  @builtins ~w(cancel dismiss merge discard goal loop sessions hq observer files
               upload copy memory context watch settings models mcp skills help agents worktree quit)

  @doc false
  @spec builtins() :: [String.t()]
  def builtins, do: @builtins

  defp run_command(state, text) do
    sid = state.session_id
    slash? = String.starts_with?(text, "/")
    typed = String.trim(text)
    text = String.trim_leading(text, "/")
    {name, args} = split_first(text)
    name = canonical(state, name)

    active =
      case state.focus do
        {:window, p} -> p
        _ -> nil
      end

    target = fn -> if args == "", do: active, else: resolve_window(state, args) end

    result =
      cond do
        name == "" ->
          :palette

        name in @builtins ->
          builtin(name, args, state, target)

        # A line with no slash is what the person wants to say to the session's agent:
        # one agent per session, so there is one place for it to go. A slash names a
        # command, and one this table does not know is asked of the client (a profile
        # to dispatch, where the client supports that).
        not slash? ->
          Client.send_input(sid, "root", typed)

        # A command a markdown file defines is the harness's to run (Decision 763): it
        # sends the file's prompt, and the line comes back as the session's own input.
        defined?(state, name) ->
          Client.run_command(sid, name, args)

        true ->
          Client.dispatch(sid, name, args)
      end

    state = put_cmd(state, "")

    case result do
      :quit -> %{state | quitting: true}
      :palette -> open_palette(state)
      :files -> toggle_files(state)
      :mcp -> open_mcp(state)
      {:mcp, text} -> state |> notice(text) |> open_mcp(state.mcp_cursor)
      {:mcp_sign_in, _name, _url, _text} = signing -> signing_in(state, signing)
      {:hq, arg} -> open_hq(state, plane_arg(arg))
      :settings -> open_settings(state)
      :models -> open_models(state)
      :observer -> %{put_cmd(state, "") | focus: :observer, observer: %{cursor: 0}}
      {:sessions, ""} -> open_sessions(state)
      {:sessions, arg} -> resume_by_arg(state, arg)
      {:ok, _} -> state
      :ok -> state
      {:notice, text} -> notice(state, text)
      {:error, msg} when is_binary(msg) -> notice(state, msg)
      {:error, other} -> notice(state, inspect(other))
    end
  end

  # An alias is the table's business (`/q`, `/resume`, `/?`); a name the table does not
  # know, or a table the harness never sent, is taken as typed.
  defp canonical(state, name) do
    case Enum.find(state.commands, &(name == &1["name"] or name in &1["aliases"])) do
      nil -> name
      entry -> entry["name"]
    end
  end

  defp defined?(state, name),
    do: Enum.any?(state.commands, &(&1["name"] == name and &1["source"] in ["user", "project"]))

  defp builtin("quit", _args, _state, _target), do: :quit
  defp builtin("settings", _args, _state, _target), do: :settings
  defp builtin("help", _args, _state, _target), do: :palette
  defp builtin("models", _args, _state, _target), do: :models
  defp builtin("observer", _args, _state, _target), do: :observer
  defp builtin("files", _args, _state, _target), do: :files
  defp builtin("mcp", args, state, _target), do: sources_command(state, "mcp", String.trim(args))

  defp builtin("skills", args, state, _target),
    do: sources_command(state, "skills", String.trim(args))

  defp builtin("sessions", args, _state, _target), do: {:sessions, args}
  defp builtin("hq", args, _state, _target), do: {:hq, args}

  defp builtin("watch", _args, state, _target),
    do: toggle_watch(state.session_id, state.model.watch.enabled)

  defp builtin("cancel", _args, state, target),
    do: with_target(target.(), &Client.cancel_branch(state.session_id, &1))

  defp builtin("dismiss", _args, state, target),
    do: with_target(target.(), &Client.dismiss(state.session_id, &1))

  defp builtin("merge", _args, state, target),
    do: with_target(target.(), &Client.merge(state.session_id, &1))

  defp builtin("discard", _args, state, target),
    do: with_target(target.(), &Client.discard(state.session_id, &1))

  defp builtin("agents", _args, state, _target),
    do: {:notice, "agents: " <> Enum.join(state.agents, ", ")}

  defp builtin("memory", args, state, _target),
    do: notice_of(Client.memory(state.session_id, String.trim(args)))

  defp builtin("context", _args, state, _target),
    do: notice_of(Client.instructions(state.session_id))

  defp builtin("goal", args, state, _target), do: goal_command(state.session_id, String.trim(args))
  defp builtin("loop", args, state, _target), do: loop_command(state.session_id, String.trim(args))

  defp builtin("upload", args, state, _target),
    do: notice_of(upload(state.session_id, String.trim(args)))

  defp builtin("copy", args, state, _target), do: copy_command(state, String.trim(args))

  # The default agent in a worktree of its own: a branch like any agent's, which the
  # client starts (`/worktree <name>: …` and `/worktree <existing> …` are its business).
  defp builtin("worktree", args, state, _target),
    do: Client.dispatch(state.session_id, "worktree", args)

  ## Command palette

  # The palette is a popup over the session (Decision 119): `/` on an empty command line,
  # Ctrl-K with nothing typed, or `/help` opens it, and what is typed while it is open
  # filters the harness's table. It remembers where it was opened from, because a
  # command picked from a window acts on that window.
  defp open_palette(state) do
    return_to =
      case state.focus do
        {:window, _} = window -> window
        _ -> :command
      end

    # The table is read when the session is opened; one that was not attached then is
    # read now, so a palette is never empty for want of asking.
    commands =
      case state.commands do
        [] -> Client.command_table(state.session_id)
        commands -> commands
      end

    %{
      state
      | focus: :palette,
        commands: commands,
        palette: %{query: "", cursor: 0, return_to: return_to},
        cmd_text: "",
        cmd_pos: 0
    }
  end

  defp close_palette(state), do: %{state | focus: state.palette.return_to, palette: nil}

  defp palette_key(%Key{code: "esc"}, state), do: close_palette(state)
  defp palette_key(%Key{code: "enter"}, state), do: pick_command(state)
  # Tab and Space put the command on the line, as completion does, so `/merge 2⏎` types
  # exactly as it did before there was a palette.
  defp palette_key(%Key{code: "tab"}, state), do: take_command(state, :tab)
  defp palette_key(%Key{code: " "}, state), do: take_command(state, :space)

  defp palette_key(%Key{code: "backspace"}, %{palette: %{query: ""}} = state),
    do: close_palette(state)

  defp palette_key(%Key{code: "backspace"}, %{palette: %{query: query}} = state),
    do: put_query(state, String.slice(query, 0..-2//1))

  defp palette_key(%Key{code: "up"}, state), do: move_cursor(state, -1)
  defp palette_key(%Key{code: "down"}, state), do: move_cursor(state, 1)
  defp palette_key(%Key{code: "page_up"}, state), do: move_cursor(state, -10)
  defp palette_key(%Key{code: "page_down"}, state), do: move_cursor(state, 10)
  defp palette_key(%Key{code: "home"}, state), do: put_palette(state, cursor: 0)
  defp palette_key(%Key{code: "end"}, state), do: move_cursor(state, 1_000_000)

  defp palette_key(%Key{code: code, modifiers: mods}, %{palette: %{query: query}} = state)
       when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: put_query(state, query <> code), else: state
  end

  defp palette_key(_key, state), do: state

  defp move_cursor(state, by) do
    {rows, cursor} = View.palette_view(state)
    put_palette(state, cursor: cursor |> Kernel.+(by) |> max(0) |> min(max(length(rows) - 1, 0)))
  end

  # A new query starts on the row that matches it exactly, so `/q` + Enter quits as it
  # always did; else on the first row.
  defp put_query(state, query) do
    state = put_palette(state, query: query, cursor: 0)
    {rows, _cursor} = View.palette_view(state)
    exact = Enum.find_index(rows, fn %{entry: e} -> query == e["name"] or query in e["aliases"] end)
    put_palette(state, cursor: exact || 0)
  end

  defp put_palette(state, changes),
    do: %{state | palette: Map.merge(state.palette, Map.new(changes))}

  # Enter runs the selected command, or puts it on the line when it wants an argument or
  # a window the person has to name; a query nothing matches runs as typed, which is
  # what `/x` did before there was a palette.
  defp pick_command(%{palette: %{query: query}} = state) do
    {rows, cursor} = View.palette_view(state)

    case Enum.at(rows, cursor) do
      nil when query == "" -> state
      nil -> run_command(close_palette(state), "/" <> query)
      %{status: {:window, _reason}} -> take_command(state, :tab)
      %{status: {:no, reason}} -> notice(close_palette(state), reason)
      %{entry: entry} -> run_or_take(state, entry)
    end
  end

  defp run_or_take(state, entry) do
    if Enum.any?(entry["args"], & &1["required"]),
      do: take_command(state, :tab),
      else: run_command(close_palette(state), "/" <> entry["name"])
  end

  # Space carries the selected command to the line only when what was typed is the start
  # of its name or an alias — a row found through its description is not what the
  # fingers meant — and otherwise carries the text itself. Either way the person is on
  # the command line to finish typing, whatever the palette was opened over.
  defp take_command(%{palette: %{query: query}} = state, how) do
    {rows, cursor} = View.palette_view(state)

    case Enum.at(rows, cursor) do
      %{entry: entry} when how == :tab or query == "" ->
        to_line(state, "/" <> entry["name"] <> " ")

      %{entry: entry} ->
        if Enum.any?([entry["name"] | entry["aliases"]], &String.starts_with?(&1, query)),
          do: to_line(state, "/" <> entry["name"] <> " "),
          else: to_line(state, "/" <> query <> " ")

      nil when how == :space ->
        to_line(state, "/" <> query <> " ")

      nil ->
        state
    end
  end

  defp to_line(state, text), do: state |> close_palette() |> to_command_line() |> put_cmd(text)

  ## Copying a transcript

  # `/copy` takes the activated window, `/copy 2` (or `/copy code-2`) any of them,
  # so a transcript can be copied from the command line without activating it.
  defp copy_command(state, "") do
    case state.focus do
      {:window, _} -> {:notice, copy_result(state)}
      _ -> {:error, "no window given; activate one or pass its number"}
    end
  end

  defp copy_command(state, arg) do
    path = resolve_window(state, arg)

    if Map.has_key?(state.model.windows, path) do
      # A named window has no selection context: `/copy 2` is the whole transcript.
      state = %{state | focus: {:window, path}, pane: fresh_pane(), selection: nil}
      {:notice, copy_result(state)}
    else
      {:error, "no window #{arg}"}
    end
  end

  ## Uploads and messages

  # `/upload <path>` sends a local file to the session's own mount. The path is
  # read here rather than on the worker: the worker has no access to this
  # machine, which is the point of the mount.
  defp upload(_sid, ""), do: {:error, "usage: /upload <path>"}

  defp upload(sid, path) do
    case File.read(Path.expand(path)) do
      {:ok, content} ->
        target = "session:/" <> Path.basename(path)

        case Client.fs_upload(sid, target, content) do
          :ok -> {:ok, "uploaded #{path} to #{target}"}
          {:error, reason} -> {:error, to_message(reason)}
        end

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  # `/todo cancel 2` and `/todo complete 2` are the second task as the side panel numbers
  # the window's list; the item's id, which the screen never shows, is what the daemon is
  # sent. Anything that is not a place on the list is taken to be an id already.
  defp todo_id(w, "/todo " <> command) do
    [_action, ref] = String.split(command, " ", parts: 2)
    ref = String.trim(ref)
    todos = w.agents |> Map.get(w.path, %{todos: []}) |> Map.get(:todos, [])

    case Integer.parse(ref) do
      {n, ""} when n >= 1 and n <= length(todos) -> Enum.at(todos, n - 1).id || ref
      _ -> ref
    end
  end

  # Errors cross the client as strings or as reasons; the notice line takes text.
  defp to_message(reason) when is_binary(reason), do: reason
  defp to_message(reason), do: inspect(reason)

  defp approval_error(:unknown_call), do: "that request is no longer outstanding"
  defp approval_error(reason), do: to_message(reason)

  ## Project brief

  # `/memory` is the client's answer, shown on the notice line either way.
  defp notice_of({:ok, text}), do: {:notice, text}
  defp notice_of({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp notice_of({:error, reason}), do: {:error, inspect(reason)}

  ## The session's goal

  # `/goal` says what it is, `/goal clear` clears it, and anything else sets it. The status
  # line follows the session's own `goal_set` and `goal_cleared`, so these only answer on
  # the notice line.
  defp goal_command(sid, "") do
    case Client.goal(sid) do
      {:ok, nil} -> {:notice, "no goal set; /goal <text> sets one"}
      {:ok, goal} -> {:notice, "goal: " <> goal}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  defp goal_command(sid, "clear") do
    case Client.clear_goal(sid) do
      :ok -> {:notice, "goal cleared"}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  defp goal_command(sid, text) do
    case Client.set_goal(sid, text) do
      :ok -> {:notice, "goal set"}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  ## A loop towards the goal

  # `/loop` and `/loop <n>` start one and `/loop stop` stops it. The status line and the
  # transcript follow the session's own `loop_*` events, so these answer on the notice line
  # only, and the input box is free while the loop runs. Whether a loop runs is asked of
  # the session, which knows one that a restart interrupted is not running, and what it
  # would refuse is said here first, in terms of what to type instead.
  defp loop_command(sid, "stop") do
    with {:ok, %{"state" => "running"}} <- Client.loop(sid),
         :ok <- Client.stop_loop(sid) do
      {:notice, "loop stopping"}
    else
      {:ok, _none_running} -> {:notice, "no loop is running"}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  defp loop_command(sid, args) do
    with {:ok, n} <- loop_count(args),
         :ok <- no_loop_running(sid),
         :ok <- has_goal(sid),
         :ok <- Client.start_loop(sid, n) do
      {:notice, "loop started"}
    else
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  defp loop_count(""), do: {:ok, nil}

  defp loop_count(text) do
    case Integer.parse(text) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "/loop [n] runs up to n iterations towards the goal; /loop stop stops it"}
    end
  end

  defp no_loop_running(sid) do
    case Client.loop(sid) do
      {:ok, %{"state" => "running", "iteration" => n}} ->
        {:error, "a loop is already running (iteration #{n}); /loop stop stops it"}

      {:ok, _none_running} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp has_goal(sid) do
    case Client.goal(sid) do
      {:ok, nil} -> {:error, "no goal to loop towards; /goal <text> sets one"}
      {:ok, _goal} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  ## Observer page

  defp observer_key(%Key{code: "esc"}, state), do: %{state | focus: :command, observer: nil}

  defp observer_key(%Key{code: code}, %{observer: o} = state) when code in ["up", "k"],
    do: %{state | observer: %{o | cursor: max(o.cursor - 1, 0)}}

  defp observer_key(%Key{code: code}, %{observer: o} = state) when code in ["down", "j"] do
    {rows, cursor} = View.observer_view(state)
    %{state | observer: %{o | cursor: min(cursor + 1, max(length(rows) - 1, 0))}}
  end

  # Enter opens the selected agent's transcript in its branch's pane.
  defp observer_key(%Key{code: "enter"}, state) do
    {rows, cursor} = View.observer_view(state)

    case Enum.at(rows, cursor) do
      nil -> state
      row -> activate(%{state | observer: nil}, row.window.path, row.path)
    end
  end

  defp observer_key(_key, state), do: state

  ## Session picker

  # Sessions this window offers to switch to: the ones the daemon has for the directory
  # the TUI was opened in that did something, spoke to a model or started a branch, plus
  # the session on screen (which may still be empty) so the list always says where you
  # are. A branch is not one of them: it is a window of its parent's, counted on its row.
  defp pickable_sessions(state) do
    case Client.sessions({:local, state.workspace}) do
      {:ok, sessions} ->
        Enum.filter(sessions, &(&1.id == state.session_id or (&1.parent == nil and worked?(&1))))

      {:error, _reason} ->
        []
    end
  end

  defp worked?(entry), do: entry.branches != [] or (entry.tokens || 0) > 0

  defp open_sessions(state) do
    entries = pickable_sessions(state)
    cursor = Enum.find_index(entries, &(&1.id == state.session_id)) || 0

    %{put_cmd(state, "") | focus: :sessions, sessions: %{entries: entries, cursor: cursor}}
  end

  defp sessions_key(%Key{code: "esc"}, state), do: %{state | focus: :command, sessions: nil}

  defp sessions_key(%Key{code: code}, %{sessions: s} = state) when code in ["up", "k"],
    do: %{state | sessions: %{s | cursor: max(s.cursor - 1, 0)}}

  defp sessions_key(%Key{code: code}, %{sessions: s} = state) when code in ["down", "j"] do
    {entries, cursor} = View.sessions_view(state)
    %{state | sessions: %{s | cursor: min(cursor + 1, max(length(entries) - 1, 0))}}
  end

  # The list is a snapshot of the state dir; `r` takes another one without losing your place.
  defp sessions_key(%Key{code: "r"}, %{sessions: s} = state) do
    state = open_sessions(state)
    entries = state.sessions.entries
    %{state | sessions: %{state.sessions | cursor: min(s.cursor, max(length(entries) - 1, 0))}}
  end

  defp sessions_key(%Key{code: "enter"}, state) do
    {entries, cursor} = View.sessions_view(state)

    case Enum.at(entries, cursor) do
      nil -> %{state | focus: :command, sessions: nil}
      entry -> switch_to(state, entry)
    end
  end

  # `c` takes a private session another device sealed last over on this machine (root
  # Decision 785), and the list is taken again so its row says how it stands now.
  defp sessions_key(%Key{code: "c"}, state) do
    {entries, cursor} = View.sessions_view(state)

    case Enum.at(entries, cursor) do
      nil ->
        state

      entry ->
        if View.claimable?(entry),
          do: claim(state, entry),
          else: notice(state, "#{entry.id} is not held by another device; nothing to claim")
    end
  end

  defp sessions_key(_key, state), do: state

  defp claim(%{sessions: s} = state, entry) do
    case Client.claim_session(entry.origin, entry.id) do
      {:ok, _claimed} ->
        state = open_sessions(state)
        entries = state.sessions.entries

        state = %{
          state
          | sessions: %{state.sessions | cursor: min(s.cursor, max(length(entries) - 1, 0))}
        }

        notice(state, "claimed #{entry.id}: this computer holds it now")

      {:error, reason} ->
        notice(state, "could not claim #{entry.id}: #{claim_reason(reason)}")
    end
  end

  defp claim_reason(reason) when is_binary(reason), do: reason
  defp claim_reason(reason), do: inspect(reason)

  # `/resume 2` (the row's number) or `/resume MU0W4A78` (an id or the start of one).
  defp resume_by_arg(state, arg) do
    entries = pickable_sessions(state)

    found =
      case Integer.parse(arg) do
        {n, ""} -> Enum.at(entries, n - 1)
        _ -> Enum.find(entries, &String.starts_with?(&1.id, arg))
      end

    case found do
      nil -> notice(state, "no session here matching #{arg}; /resume lists them")
      entry -> switch_to(state, entry)
    end
  end

  defp switch_to(%{session_id: sid} = state, %{id: sid}),
    do: notice(%{state | focus: :command, sessions: nil}, "already in this session")

  defp switch_to(state, entry) do
    case ensure_running(state, entry) do
      {:ok, sid} ->
        adopt(state, sid)

      {:error, reason} ->
        notice(state, "could not resume #{entry.id}: #{inspect(reason)}")
    end
  end

  # The session you switch to starts with the settings you have on screen — the
  # provider it resolved, the models, and any toggle you flipped this run — rather
  # than a fresh read of the config files, which would surprise you mid-run.
  defp ensure_running(state, entry) do
    Client.open_session(entry.origin, entry.id, :activate, like: state.session_id)
  end

  # Swaps the session this window shows: unsubscribe, subscribe, and rebuild every
  # window by folding the other log — the same function a restart uses, so there is
  # nothing session-specific left in the process but the name it is registered
  # under, which follows (Decision 65).
  defp adopt(state, sid) do
    previous = state.session_id
    :ok = Client.unsubscribe(previous)
    :ok = Client.subscribe(sid)
    rename(previous, sid)

    state = %{
      state
      | session_id: sid,
        model: rebuild(sid),
        workspace: workspace_of(sid),
        agents: Client.commands(sid),
        commands: Client.command_table(sid),
        palette: nil,
        focus: :command,
        cmd_text: "",
        cmd_pos: 0,
        win_text: "",
        win_pos: 0,
        win_armed: nil,
        expanded: false,
        pane: fresh_pane(),
        settings: nil,
        observer: nil,
        sessions: nil,
        dirty: true
    }

    retire(previous)
    state |> recheck_loop() |> notice("resumed #{sid}")
  end

  defp rename(previous, sid) do
    if {:tui, previous} in Registry.keys(Troupe.Client.Registry, self()) do
      Registry.unregister(Troupe.Client.Registry, {:tui, previous})
      _ = Registry.register(Troupe.Client.Registry, {:tui, sid}, nil)
    end

    :ok
  end

  # A session nobody has typed into is the scratch session `troupe` opens before you have
  # said anything: nothing in its log will be read again, and leaving it running
  # would keep a watcher and a memory refresher alive behind the session you switched to.
  # One that did something keeps running, so its agents finish and you can switch back.
  defp retire(sid) do
    if Client.has_session?(sid) and Client.idle?(sid) do
      _ = Client.stop_session(sid)
      :ok
    else
      :ok
    end
  end

  ## HQ

  # `/hq` opens the remote page against the plane this machine last logged in
  # to; `/hq <url>` picks another one. With no plane at all it still opens, on
  # the local sessions, which is what makes "local sessions stay visible
  # alongside" true rather than aspirational.
  defp open_hq(state, plane) do
    origin =
      case plane do
        {:remote, _url} = origin -> ensure_plane(origin)
        nil -> ensure_plane(Client.default_plane())
        url when is_binary(url) -> ensure_plane({:remote, url})
      end

    state = %{put_cmd(state, "") | focus: :hq, hq: HQ.open(origin, state.workspace)}
    _ = origin && Client.subscribe_fleet(origin)
    state
  end

  defp ensure_plane(nil), do: nil

  defp ensure_plane({:remote, url}) do
    case Client.connect_plane(url) do
      {:ok, origin} -> origin
      {:error, _reason} -> {:remote, url}
    end
  end

  defp plane_arg(""), do: nil
  defp plane_arg(url), do: url

  defp hq_key(key, state) do
    case HQ.key(state.hq, key) do
      :close ->
        %{state | focus: :command, hq: nil}

      {:ok, hq} ->
        %{state | hq: hq}

      {:open, _hq, session_id} ->
        %{state | hq: nil} |> adopt(session_id)
    end
  end

  ## Files panel

  # `/files` opens the panel on the session's own mount. It is backed by
  # `fs.list`/`fs.read` through the client, so a local session shows its
  # workspace and a remote one its worker's checkout with the same keys.
  defp toggle_files(%{files: nil} = state),
    do: load_files(%{put_cmd(state, "") | focus: :files}, "session:/")

  defp toggle_files(state), do: %{state | focus: :command, files: nil}

  ## MCP servers and skills (troupe-remote Decision 700)

  # `/mcp` opens the page on a live query — every server the layers give this
  # workspace with its state in this session, and every skill — and folds the running
  # servers into the model for the status line, like `/files` listing. `r` reads it
  # again, keeping the cursor.
  defp open_mcp(state, cursor \\ 0) do
    page =
      case Client.sources(state.session_id) do
        {:ok, sources} -> sources
        {:error, reason} -> %{servers: [], skills: [], warnings: [to_message(reason)]}
      end

    model =
      Enum.reduce(page.servers, state.model, fn
        %{state: nil}, m ->
          m

        server, m ->
          %{
            m
            | mcp:
                Map.put(m.mcp, server.name, %{
                  state: server.state,
                  tools: length(server.tools),
                  error: server.error
                })
          }
      end)

    state = %{put_cmd(state, "") | focus: :mcp, mcp_page: page, model: model}
    %{state | mcp_cursor: min(cursor, max(length(View.mcp_entries(state)) - 1, 0))}
  end

  # `/mcp import <path>`, `link <path>`, `unlink <path>`, `remove <name>`,
  # `check <name>`, `sign-in <name>` and `sign-out <name>` manage the servers,
  # `--workspace` on any of them writing the workspace's `.troupe/` file instead of the
  # user's; `/skills` has the same verbs for skills, and either word alone opens the page.
  defp sources_command(_state, _kind, ""), do: :mcp

  defp sources_command(state, kind, args) do
    {scope, rest} = scope_flag(args)

    case String.split(rest, " ", parts: 2) do
      [verb, target]
      when verb in ["import", "link", "unlink", "remove", "check", "sign-in", "sign-out"] and
             target != "" ->
        manage_source(state, kind, verb, String.trim(target), scope)

      _ ->
        {:error,
         "usage: /#{kind} [import|link|unlink <path> | remove <name>" <>
           check_usage(kind) <> "] [--workspace]"}
    end
  end

  defp check_usage("mcp"), do: " | check|sign-in|sign-out <name>"
  defp check_usage(_kind), do: ""

  defp scope_flag(args) do
    if String.contains?(args, "--workspace"),
      do: {"workspace", args |> String.replace("--workspace", "") |> String.trim()},
      else: {"user", args}
  end

  defp manage_source(state, kind, "import", path, scope),
    do: add_source(state, kind, path, scope, false)

  defp manage_source(state, kind, "link", path, scope),
    do: add_source(state, kind, path, scope, true)

  defp manage_source(state, kind, "unlink", path, scope),
    do: remove_source(state, kind, %{include: Path.expand(path)}, scope)

  defp manage_source(state, kind, "remove", name, scope),
    do: remove_source(state, kind, %{name: name}, scope)

  defp manage_source(state, "mcp", "check", name, _scope), do: check_server(state, name)
  defp manage_source(state, "mcp", "sign-in", name, _scope), do: sign_in_server(state, name)
  defp manage_source(state, "mcp", "sign-out", name, _scope), do: sign_out_server(state, name)

  defp manage_source(_state, "skills", "check", _name, _scope),
    do: {:error, "a skill has nothing to check; the page shows where it is"}

  defp manage_source(_state, "skills", verb, _name, _scope) when verb in ["sign-in", "sign-out"],
    do: {:error, "a skill has no sign-in; a server that wants you has one"}

  defp add_source(state, kind, path, scope, link?) do
    params = %{scope: scope, from: Path.expand(path), link: link?}

    case Client.manage_sources(state.session_id, kind <> ".add", params) do
      {:ok, answer} -> {:mcp, added_notice(kind, answer)}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  defp added_notice(kind, answer) do
    what = if kind == "mcp", do: "servers", else: "skills"
    verb = if answer["linked"], do: "linked", else: "imported"
    added = answer["added"] |> List.wrap() |> Enum.join(", ")
    skipped = answer["skipped"] |> List.wrap() |> Enum.map(&"#{&1["name"]} (#{&1["reason"]})")

    ["#{verb} #{what} #{if added == "", do: "(none)", else: added} into #{answer["path"]}"]
    |> Kernel.++(if skipped == [], do: [], else: ["skipped " <> Enum.join(skipped, "; ")])
    |> Kernel.++(List.wrap(answer["warnings"]))
    |> Enum.join(" · ")
  end

  # A server taken out of its file is checked afterwards, which is what stops the one
  # this session still runs under that name; a check that finds no server is the point.
  defp remove_source(state, kind, what, scope) do
    case Client.manage_sources(state.session_id, kind <> ".remove", Map.put(what, :scope, scope)) do
      {:ok, %{"removed" => removed}} ->
        if kind == "mcp", do: Enum.each(removed, &stop_removed(state, &1))
        {:mcp, "removed #{Enum.join(removed, ", ")} from the #{scope} #{kind}"}

      {:ok, _answer} ->
        {:mcp, "removed"}

      {:error, reason} ->
        {:error, to_message(reason)}
    end
  end

  defp stop_removed(state, name),
    do:
      Client.manage_sources(state.session_id, "mcp.check", %{
        session_id: state.session_id,
        name: name
      })

  # A check on this session's server reads its file again and starts what it says now,
  # which is also how one that died is brought back.
  defp check_server(state, name) do
    case Client.manage_sources(state.session_id, "mcp.check", %{
           session_id: state.session_id,
           name: name
         }) do
      {:ok, %{"server" => server}} -> {:mcp, "#{name}: #{server["state"]}#{server_note(server)}"}
      {:ok, _answer} -> {:mcp, "#{name}: checked"}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  # A server that wants the person signed in (troupe-remote Decision 741): the daemon
  # starts the sign-in and listens for the browser on this machine; the TUI opens the
  # URL it answers, and keeps it on the page for a person whose browser did not open.
  # The page shows how it stands after `r`, and a session waiting for it carries on by
  # itself once it lands.
  defp sign_in_server(state, name) do
    case Client.manage_sources(state.session_id, "mcp.sign_in", %{name: name}) do
      {:ok, %{"url" => url}} ->
        text =
          case open_url(url) do
            :ok ->
              "#{name}: finish signing in in your browser, then r"

            {:error, _why} ->
              "#{name}: open the sign-in URL on the page in a browser on this machine, then r"
          end

        {:mcp_sign_in, name, url, text}

      {:ok, _answer} ->
        {:error, "#{name}: the daemon answered no sign-in URL"}

      {:error, reason} ->
        {:error, to_message(reason)}
    end
  end

  defp sign_out_server(state, name) do
    case Client.manage_sources(state.session_id, "mcp.sign_out", %{name: name}) do
      {:ok, _answer} -> {:mcp, "#{name}: signed out on this machine"}
      {:error, reason} -> {:error, to_message(reason)}
    end
  end

  # The opener is configurable so the suite opens no browser: `:troupe, :open_url`.
  defp open_url(url) do
    opener = Application.get_env(:troupe, :open_url, &Troupe.UI.Browser.open/1)
    opener.(url)
  end

  defp signing_in(state, {:mcp_sign_in, name, url, text}) do
    %{state | mcp_sign_in: %{name: name, url: url}}
    |> notice(text)
    |> open_mcp(state.mcp_cursor)
  end

  defp server_note(%{"error" => error}) when is_binary(error) and error != "", do: " — " <> error
  defp server_note(%{"tools" => [_ | _] = tools}), do: ", #{length(tools)} tools"
  defp server_note(_server), do: ""

  # What the page's keys do to the selected entry. A server from `config.yaml` is
  # edited by hand, as it always was.
  defp mcp_selected(state), do: Enum.at(View.mcp_entries(state), state.mcp_cursor)

  defp mcp_act(state, nil), do: state

  defp mcp_act(state, result) do
    case result do
      {:mcp, text} -> state |> notice(text) |> open_mcp(state.mcp_cursor)
      {:mcp_sign_in, _name, _url, _text} = signing -> signing_in(state, signing)
      {:error, text} -> notice(state, text)
    end
  end

  defp mcp_check_selected(state) do
    case mcp_selected(state) do
      {:server, server} -> check_server(state, server.name)
      _other -> nil
    end
  end

  defp mcp_sign_in_selected(state) do
    case mcp_selected(state) do
      {:server, %{auth: %{}} = server} ->
        sign_in_server(state, server.name)

      {:server, server} ->
        {:error, "#{server.name} takes no sign-in; give its entry an oauth.client_id"}

      _other ->
        nil
    end
  end

  defp mcp_sign_out_selected(state) do
    case mcp_selected(state) do
      {:server, %{auth: %{}} = server} -> sign_out_server(state, server.name)
      {:server, server} -> {:error, "#{server.name} takes no sign-in"}
      _other -> nil
    end
  end

  defp mcp_toggle_selected(state) do
    case mcp_selected(state) do
      {:server, %{layer: layer} = server} when layer in [:user, :workspace] ->
        params = %{
          scope: Atom.to_string(layer),
          name: server.name,
          server: %{disabled: not server.disabled?}
        }

        case Client.manage_sources(state.session_id, "mcp.add", params) do
          {:ok, _} -> check_server(state, server.name)
          {:error, reason} -> {:error, to_message(reason)}
        end

      {:server, _server} ->
        {:error, "a server from config.yaml is enabled or disabled there"}

      _other ->
        nil
    end
  end

  defp mcp_remove_selected(state) do
    case mcp_selected(state) do
      {:server, %{layer: layer} = server} when layer in [:user, :workspace] ->
        remove_source(state, "mcp", %{name: server.name}, Atom.to_string(layer))

      {:server, _server} ->
        {:error, "a server from config.yaml is removed there"}

      {:skill, skill} ->
        remove_source(state, "skills", %{name: skill.name}, Atom.to_string(skill.layer))

      nil ->
        nil
    end
  end

  defp load_files(state, path) do
    case Client.fs_list(state.session_id, path) do
      {:ok, entries} ->
        %{
          state
          | files: %{
              path: path,
              entries: entries,
              cursor: 0,
              preview: nil,
              error: nil,
              version: state.model.files_version
            }
        }

      {:error, reason} ->
        files =
          state.files || %{path: path, entries: [], cursor: 0, preview: nil, error: nil, version: 0}

        %{state | files: %{files | error: to_message(reason), version: state.model.files_version}}
    end
  end

  # `fs.changed` bumps the model's version; an open panel reloads from it, which
  # is the whole of "live-updated" and costs nothing while the panel is closed.
  defp refresh_files(%{files: nil} = state), do: state

  defp refresh_files(%{files: %{version: version}} = state) do
    if version == state.model.files_version, do: state, else: load_files(state, state.files.path)
  end

  defp files_key(%Key{code: "esc"}, %{files: %{preview: preview}} = state) when preview != nil,
    do: %{state | files: %{state.files | preview: nil}}

  defp files_key(%Key{code: "esc"}, state), do: %{state | focus: :command, files: nil}

  defp files_key(%Key{code: code}, %{files: f} = state) when code in ["up", "k"],
    do: %{state | files: %{f | cursor: max(f.cursor - 1, 0)}}

  defp files_key(%Key{code: code}, %{files: f} = state) when code in ["down", "j"] do
    {entries, cursor} = View.files_view(state)
    %{state | files: %{f | cursor: min(cursor + 1, max(length(entries) - 1, 0))}}
  end

  defp files_key(%Key{code: "r"}, state), do: load_files(state, state.files.path)

  defp files_key(%Key{code: code}, state) when code in ["backspace", "left"],
    do: load_files(state, parent(state.files.path))

  defp files_key(%Key{code: "enter"}, state) do
    {entries, cursor} = View.files_view(state)

    case Enum.at(entries, cursor) do
      nil -> state
      %{dir?: true} = entry -> load_files(state, mount_of(state.files.path) <> entry.path)
      entry -> preview(state, entry)
    end
  end

  defp files_key(_key, state), do: state

  ## MCP page

  defp mcp_key(%Key{code: "esc"}, state), do: to_command_line(state)

  defp mcp_key(%Key{code: code}, state) when code in ["up", "k"],
    do: %{state | mcp_cursor: max(state.mcp_cursor - 1, 0)}

  defp mcp_key(%Key{code: code}, state) when code in ["down", "j"] do
    count = length(View.mcp_entries(state))
    %{state | mcp_cursor: min(state.mcp_cursor + 1, max(count - 1, 0))}
  end

  defp mcp_key(%Key{code: "r"}, state), do: open_mcp(state, state.mcp_cursor)
  defp mcp_key(%Key{code: "c"}, state), do: mcp_act(state, mcp_check_selected(state))
  defp mcp_key(%Key{code: "d"}, state), do: mcp_act(state, mcp_toggle_selected(state))
  defp mcp_key(%Key{code: "x"}, state), do: mcp_act(state, mcp_remove_selected(state))
  defp mcp_key(%Key{code: "s"}, state), do: mcp_act(state, mcp_sign_in_selected(state))
  defp mcp_key(%Key{code: "o"}, state), do: mcp_act(state, mcp_sign_out_selected(state))

  defp mcp_key(_key, state), do: state

  defp preview(state, entry) do
    path = mount_of(state.files.path) <> entry.path

    case Client.fs_read(state.session_id, path) do
      {:ok, content} ->
        lines = content |> Model.sanitize() |> String.split("
") |> Enum.take(2000)
        %{state | files: %{state.files | preview: {path, lines}}}

      {:error, reason} ->
        %{state | files: %{state.files | error: to_message(reason)}}
    end
  end

  # Paths in the panel are mount-relative; the mount is carried alongside so a
  # `team:` mount browses exactly like the session's own.
  defp mount_of(path) do
    case String.split(path, ":", parts: 2) do
      [mount, _rest] -> mount <> ":/"
      _ -> "session:/"
    end
  end

  defp parent(path) do
    [mount_name | rest] =
      case String.split(path, ":", parts: 2) do
        [mount, rest] -> [mount, rest]
        [only] -> ["session", only]
      end

    parent =
      rest
      |> List.first()
      |> to_string()
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
      |> Path.dirname()

    case parent do
      "." -> mount_name <> ":/"
      "/" -> mount_name <> ":/"
      dir -> mount_name <> ":/" <> dir
    end
  end

  ## Settings page

  # What the settings are is the daemon's to say (#57); the config struct is read too, for
  # the models it detects, and for the values when the daemon is too old to say them.
  defp open_settings(state) do
    %{
      state
      | focus: :settings,
        cmd_text: "",
        cmd_pos: 0,
        settings:
          Map.merge(read_settings(state.session_id), %{
            scope: nil,
            cursor: 0,
            editing: nil,
            scroll: 0,
            status: nil,
            picker: nil
          })
    }
  end

  defp read_settings(sid) do
    {_workspace, config} = Client.context(sid)

    view =
      case Client.settings(sid) do
        {:ok, answer} -> Settings.view(answer)
        {:error, _reason} -> Settings.view(%{})
      end

    %{view: view, config: config}
  end

  # The cursor, a value being typed and the scope picked stay where they are.
  defp refresh_settings(%{settings: s} = state),
    do: %{state | settings: Map.merge(s, read_settings(state.session_id))}

  # `/models` is `/settings` opened on the default model, with its menu up.
  defp open_models(state) do
    state = open_settings(state)
    cursor = Enum.find_index(Settings.fields(), &(&1.key == "models.default")) || 0
    open_picker(put_settings(state, cursor: cursor))
  end

  defp open_picker(%{settings: s} = state) do
    field = Enum.at(Settings.fields(), s.cursor)
    current = Settings.value(s.view, s.config, field.key)

    case Settings.choices(field, s.config, current) do
      [] -> put_settings(state, editing: shown(s, field.key), status: nil)
      choices -> put_settings(state, picker: %{choices: choices, cursor: 0}, status: nil)
    end
  end

  defp shown(s, key), do: Settings.format(s.view, s.config, key)

  defp settings_key(%Key{code: "esc"}, %{settings: %{picker: p}} = state) when p != nil,
    do: put_settings(state, picker: nil)

  defp settings_key(%Key{code: code}, %{settings: %{picker: p}} = state)
       when p != nil and code in ["up", "k"],
       do: put_settings(state, picker: %{p | cursor: max(p.cursor - 1, 0)})

  defp settings_key(%Key{code: code}, %{settings: %{picker: p}} = state)
       when p != nil and code in ["down", "j"],
       do: put_settings(state, picker: %{p | cursor: min(p.cursor + 1, length(p.choices))})

  # The entry past the last choice is "type one instead", for a model no config mentions.
  defp settings_key(%Key{code: "enter"}, %{settings: %{picker: p} = s} = state) when p != nil do
    field = Enum.at(Settings.fields(), s.cursor)

    case Enum.at(p.choices, p.cursor) do
      nil ->
        put_settings(state, picker: nil, editing: shown(s, field.key))

      choice ->
        state |> put_settings(picker: nil) |> apply_setting(field.key, choice.value)
    end
  end

  defp settings_key(%Key{code: "esc"}, %{settings: %{editing: nil}} = state),
    do: %{state | focus: :command, settings: nil}

  defp settings_key(%Key{code: "esc"}, state), do: put_settings(state, editing: nil, status: nil)

  defp settings_key(%Key{code: "enter"}, %{settings: %{editing: text}} = state)
       when is_binary(text),
       do: commit_setting(state, text)

  defp settings_key(%Key{code: "backspace"}, %{settings: %{editing: text}} = state)
       when is_binary(text),
       do: put_settings(state, editing: String.slice(text, 0..-2//1))

  defp settings_key(%Key{code: code, modifiers: mods}, %{settings: %{editing: text}} = state)
       when is_binary(text) and mods in [[], ["shift"]] do
    if String.length(code) == 1, do: put_settings(state, editing: text <> code), else: state
  end

  defp settings_key(%Key{code: code}, %{settings: s} = state) when code in ["up", "k"],
    do: put_settings(state, cursor: max(s.cursor - 1, 0), scroll: 0, status: nil, picker: nil)

  defp settings_key(%Key{code: code}, %{settings: s} = state) when code in ["down", "j"],
    do:
      put_settings(state,
        cursor: min(s.cursor + 1, length(Settings.fields()) - 1),
        scroll: 0,
        status: nil,
        picker: nil
      )

  defp settings_key(%Key{code: "page_up"}, %{settings: s} = state),
    do: put_settings(state, scroll: max(s.scroll - 5, 0))

  defp settings_key(%Key{code: "page_down"}, %{settings: s} = state),
    do: put_settings(state, scroll: s.scroll + 5)

  # `s` moves where a change goes: through the scopes the daemon says the setting may be
  # written to here, from the one it goes to now.
  defp settings_key(%Key{code: "s"}, %{settings: s} = state) do
    field = Enum.at(Settings.fields(), s.cursor)
    scope = Settings.next_scope(s.view, field.key, s.scope)
    put_settings(state, scope: scope, status: "a change goes to #{scope_file(s.view, scope)}")
  end

  defp settings_key(%Key{code: code}, %{settings: s} = state) when code in ["enter", " "] do
    field = Enum.at(Settings.fields(), s.cursor)

    case field.type do
      :bool -> apply_setting(state, field.key, Settings.value(s.view, s.config, field.key) != true)
      :model -> open_picker(state)
      _ -> put_settings(state, editing: shown(s, field.key), status: nil)
    end
  end

  defp settings_key(_key, state), do: state

  defp commit_setting(%{settings: s} = state, text) do
    field = Enum.at(Settings.fields(), s.cursor)

    case Settings.parse(field, text) do
      {:ok, value} -> apply_setting(state, field.key, value)
      {:error, msg} -> put_settings(state, status: msg)
    end
  end

  # Written into the scope `Settings.target/3` names, which the help beside the setting
  # said before Enter was pressed; the status says where it went, and what still wins
  # over it there when something does.
  defp apply_setting(%{settings: s} = state, key, value) do
    sid = state.session_id
    scope = Settings.target(s.view, key, s.scope)

    state =
      case Client.put_setting(sid, key, value, scope) do
        {:ok, answer} ->
          {_workspace, config} = Client.context(sid)
          view = Settings.view(answer)
          path = get_in(answer, ["written", "path"])

          put_settings(state,
            view: view,
            config: config,
            editing: nil,
            status:
              "#{key} = #{Settings.format(view, config, key)} · saved to #{path}" <>
                wins(view, key, scope)
          )

        {:error, msg} ->
          state |> refresh_settings() |> put_settings(editing: nil, status: to_message(msg))
      end

    %{state | model: %{state.model | watch: Client.watch_status(sid)}}
  end

  # A value written below one that beats it: the project's file over the user's, or a
  # `TROUPE_*` variable over both.
  defp wins(view, key, scope) do
    case Settings.layer(view, key) do
      layer when layer in [nil, "default", scope] -> ""
      layer -> " · #{layer} sets it too, and wins here"
    end
  end

  defp scope_file(view, scope), do: "#{scope} (#{Map.get(view.files, scope, "its file")})"

  defp put_settings(state, changes),
    do: %{state | settings: Enum.into(changes, state.settings)}

  # Paste into an open settings-edit field; if nothing is being edited, ignore it so
  # an accidental paste doesn't clobber the page.
  defp paste_into_settings(%{settings: %{editing: text}} = state, content) when is_binary(text),
    do: put_settings(state, editing: text <> content)

  defp paste_into_settings(state, _content), do: state

  defp toggle_watch(sid, true) do
    case Client.watch(sid, false) do
      {:error, reason} -> {:error, reason}
      _ -> {:notice, "watch mode off"}
    end
  end

  defp toggle_watch(sid, false) do
    case Client.watch(sid, true) do
      {:ok, backend} -> {:notice, "watch mode on (#{backend})"}
      :ok -> {:notice, "watch mode on"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_target(nil, _fun), do: {:error, "no window given; activate one or pass its number"}
  defp with_target(path, fun), do: fun.(path)

  @doc """
  Resolves a window argument: the number on its tile (`/cancel 3`) or its path
  (`/cancel code-3`). Numbers are what the strip and the digit keys already show,
  and no agent path is a bare number, so there is nothing to disambiguate.
  """
  @spec resolve_window(map(), String.t()) :: String.t()
  def resolve_window(state, arg) do
    with {n, ""} <- Integer.parse(arg),
         w when w != nil <- Enum.at(Model.windows(state.model), n - 1) do
      w.path
    else
      _ -> arg
    end
  end

  ## Window keys

  # Esc clears a selection before it leaves the window, so a mis-drag can be
  # cancelled without losing the pane.
  defp window_key(%Key{code: "esc"}, _path, %{selection: %{}} = state),
    do: %{state | selection: nil}

  defp window_key(%Key{code: "esc"}, _path, state),
    do: %{put_win(state, "") | focus: :command, win_armed: nil}

  # Ctrl-Y copies: the selection when the mouse made one, and otherwise the whole
  # transcript (same as `/copy`) — with mouse reporting on the terminal's own
  # selection is gone, and the interesting rows have usually scrolled off. It has
  # to come before the `y`/`n`/`a` approval clause, which matches any modifier.
  defp window_key(%Key{code: "y", modifiers: ["ctrl"]}, _path, state), do: copy_pane(state)

  # Scrolling: PgUp/PgDn, Home and End always; ↑/↓ while nothing is typed; End (or
  # reaching the bottom) follows the tail again.
  defp window_key(%Key{code: "page_up"}, _path, state), do: page_by(state, -1)
  defp window_key(%Key{code: "page_down"}, _path, state), do: page_by(state, 1)
  defp window_key(%Key{code: "home"}, _path, %{win_text: ""} = state), do: scroll_to(state, 0)
  defp window_key(%Key{code: "end"}, _path, %{win_text: ""} = state), do: follow(state)
  defp window_key(%Key{code: "up"}, _path, %{win_text: ""} = state), do: scroll_by(state, -1)
  defp window_key(%Key{code: "down"}, _path, %{win_text: ""} = state), do: scroll_by(state, 1)

  # ←/→ cycle through the branch's agents (root first), so a subagent's transcript can be read.
  defp window_key(%Key{code: code}, path, %{win_text: ""} = state) when code in ["left", "right"],
    do: cycle_agent(state, path, if(code == "right", do: 1, else: -1))

  defp window_key(%Key{code: "tab"}, path, %{win_text: ""} = state) do
    w = Map.fetch!(state.model.windows, path)

    case state.agents do
      [] ->
        state

      agents ->
        idx = Enum.find_index(agents, &(&1 == w.profile)) || -1
        next = Enum.at(agents, rem(idx + 1, length(agents)))

        case Client.switch_profile(state.session_id, path, next) do
          :ok -> state
          {:error, reason} -> notice(state, to_message(reason))
        end
    end
  end

  defp window_key(%Key{code: "tab"}, _path, state),
    do: put_win(state, complete_file(state.win_text, state.model.workspace))

  defp window_key(%Key{code: code, modifiers: []}, path, %{win_text: ""} = state)
       when code in ["y", "n", "a"] do
    w = Map.fetch!(state.model.windows, path)

    case answerable(w, state.pane.agent || path) do
      nil ->
        put_win(state, code)

      %{call_id: call_id} ->
        decision = %{"y" => :allow, "n" => :deny, "a" => :allow_session}[code]

        case Client.approve(state.session_id, call_id, decision) do
          :ok -> follow(state)
          {:error, reason} -> notice(follow(state), approval_error(reason))
        end
    end
  end

  # `x` and `d` take a branch away, and the window they act in is also where the
  # user types: a reply that begins with either letter used to cancel or dismiss
  # on the first keystroke. So the first press is typed text *and* an arming, and
  # only an immediate second press of the same key acts (Decision 83). The armed
  # clauses come first: after the first press the box holds the letter, so the
  # `win_text: ""` clauses below no longer match.
  defp window_key(%Key{code: "x", modifiers: []}, path, %{win_armed: {armed, "x"}} = state)
       when armed == path do
    case Client.cancel_branch(state.session_id, path) do
      :ok -> to_command_line(state)
      {:error, msg} -> notice(clear_input(state), to_message(msg))
    end
  end

  defp window_key(%Key{code: "d", modifiers: []}, path, %{win_armed: {armed, "d"}} = state)
       when armed == path do
    case Client.dismiss(state.session_id, path) do
      :ok -> to_command_line(state)
      {:error, msg} -> notice(clear_input(state), to_message(msg))
    end
  end

  defp window_key(%Key{code: code, modifiers: []}, path, %{win_text: ""} = state)
       when code in ["x", "d"],
       do: %{put_win(state, code) | win_armed: {path, code}}

  defp window_key(%Key{code: "e"}, _path, %{win_text: ""} = state), do: toggle_expanded(state)

  # A digit picks an offered option: with a single-choice question it is the
  # answer, with `multiple` it toggles a tick that Enter later sends. Only while
  # such a question is on screen — otherwise digits are ordinary typed text. The
  # budget question is one such (Decision 120).
  defp window_key(%Key{code: <<d>>}, path, %{win_text: ""} = state) when d in ?1..?9 do
    w = Map.fetch!(state.model.windows, path)

    case pending_of(w, state.pane.agent || path, [:question, :budget]) do
      %{options: options} = q when options != [] ->
        case Enum.at(options, d - ?1) do
          nil -> state
          %{label: label} -> choose(state, q, label)
        end

      _ ->
        put_win(state, <<d>>)
    end
  end

  # A newline in the input box: any modifier on Enter, and Ctrl-J. Multiline
  # (typed or pasted) input folds to a `<pasted N lines>` marker in the title.
  defp window_key(%Key{code: "enter", modifiers: mods}, _path, state) when mods != [],
    do: put_win(state, Input.insert(win_input(state), "\n"))

  defp window_key(%Key{code: "j", modifiers: ["ctrl"]}, _path, state),
    do: put_win(state, Input.insert(win_input(state), "\n"))

  # Enter with nothing typed sends the ticked options of a multiple-choice
  # question. With none ticked there is nothing to send, so it falls through.
  defp window_key(%Key{code: "enter"}, path, %{win_text: "", answer: %{} = answer} = state) do
    w = Map.fetch!(state.model.windows, path)

    case pending_of(w, state.pane.agent || path, [:question]) do
      %{call_id: id} when id == answer.call_id and answer.selected != [] ->
        send_answer(state, id, Client.answer_text(answer.selected))

      _ ->
        state
    end
  end

  defp window_key(%Key{code: "enter"}, path, %{win_text: text} = state) when text != "" do
    sid = state.session_id
    w = Map.fetch!(state.model.windows, path)

    cond do
      String.starts_with?(text, "/todo cancel ") ->
        Client.edit_todo(sid, path, {:cancel, todo_id(w, text)})

      String.starts_with?(text, "/todo complete ") ->
        Client.edit_todo(sid, path, {:complete, todo_id(w, text)})

      String.starts_with?(text, "/todo add ") ->
        Client.edit_todo(sid, path, {:add, String.trim_leading(text, "/todo add ")})

      String.starts_with?(text, "/upload ") ->
        upload(sid, String.trim(String.trim_leading(text, "/upload ")))

      question = pending_of(w, state.pane.agent || path, [:question, :budget]) ->
        Client.answer(sid, question.call_id, text)

      true ->
        Client.send_input(sid, path, text)
    end

    # Any Enter that reaches here either answered the question or replaced it
    # with fresh input, so a half-built selection is stale either way.
    follow(%{put_win(state, "") | answer: nil})
  end

  defp window_key(%Key{code: code, modifiers: mods} = key, _path, state)
       when mods in [[], ["shift"]] do
    if String.length(code) == 1,
      do: put_win(state, Input.insert(win_input(state), code)),
      else: editing_key(key, state)
  end

  defp window_key(key, _path, state), do: editing_key(key, state)

  # y/n/a answers approvals — a delegated subagent raises them too, and its pending
  # item lives in the branch's window like the root's. When more than one is
  # outstanding the agent whose pane is open wins, so the keys answer the request the
  # reader is looking at rather than the oldest one. The budget question is answered
  # by digit or by typing, never by one of these letters (Decision 120): an amount typed
  # in a person's own words — `no limit` — must not stop the session on its first key.
  defp answerable(w, viewed), do: pending_of(w, viewed, [:approval])

  # A single-choice question is answered by the digit itself; a multiple-choice
  # one accumulates ticks until Enter, and re-pressing a digit unticks it.
  defp choose(state, %{multiple: false, call_id: id}, label),
    do: send_answer(state, id, label)

  defp choose(state, %{call_id: id}, label) do
    selected =
      case state.answer do
        %{call_id: ^id, selected: selected} ->
          if label in selected, do: List.delete(selected, label), else: selected ++ [label]

        _ ->
          [label]
      end

    %{state | answer: %{call_id: id, selected: selected}}
  end

  defp send_answer(state, call_id, text) do
    state = %{state | answer: nil}

    case Client.answer(state.session_id, call_id, text) do
      :ok -> follow(state)
      {:error, reason} -> notice(follow(state), approval_error(reason))
    end
  end

  defp pending_of(w, viewed, kinds) do
    pending = Enum.filter(w.pending, &(&1.kind in kinds))
    Enum.find(pending, &(&1.agent_path == viewed)) || List.first(pending)
  end

  ## Helpers

  defp activate(state, path, agent \\ nil) do
    model = Model.seen(state.model, path)
    agent = if agent == path, do: nil, else: agent

    %{
      state
      | focus: {:window, path},
        win_text: "",
        win_pos: 0,
        win_armed: nil,
        model: model,
        pane: fresh_pane(agent),
        selection: nil
    }
  end

  defp fresh_pane(agent \\ nil), do: %{agent: agent, scroll: :follow, seen_entries: 0}

  ## Pane scrolling

  defp page_by(state, direction) do
    case View.pane_geometry(state) do
      nil -> state
      g -> set_scroll(state, g, from(g) + direction * max(g.inner_h - 1, 1))
    end
  end

  defp scroll_by(state, delta) do
    case View.pane_geometry(state) do
      nil -> state
      g -> set_scroll(state, g, from(g) + delta)
    end
  end

  defp scroll_to(state, offset) do
    case View.pane_geometry(state) do
      nil -> state
      g -> set_scroll(state, g, offset)
    end
  end

  # At or past the bottom the pane follows new content again; anywhere else it stays put.
  defp set_scroll(state, g, offset) do
    offset = max(offset, 0)

    if offset >= g.max_off,
      do: follow(state),
      else: %{state | pane: %{state.pane | scroll: offset, seen_entries: g.entries}}
  end

  defp from(g), do: if(g.follow?, do: g.max_off, else: g.offset)

  defp follow(state), do: %{state | pane: %{state.pane | scroll: :follow}}

  defp to_command_line(state),
    do: %{
      state
      | focus: :command,
        win_text: "",
        win_pos: 0,
        win_armed: nil,
        pane: fresh_pane(),
        selection: nil
    }

  # Empties the input box without leaving the window, and takes any arming with it.
  defp clear_input(state), do: %{put_win(state, "") | win_armed: nil}

  # Expanding or collapsing tool output keeps the entry at the top of the view where it is,
  # instead of throwing the reader to the bottom of a transcript that just changed height.
  defp toggle_expanded(state) do
    before = View.pane_geometry(state)
    state = %{state | expanded: not state.expanded}

    case {before, state.pane.scroll} do
      {nil, _} ->
        state

      {_, :follow} ->
        state

      {g, offset} ->
        {idx, row} = View.block_at(g.heights, offset)
        after_g = View.pane_geometry(state)
        start = after_g.heights |> Enum.take(idx) |> Enum.sum()
        height = Enum.at(after_g.heights, idx, 1)
        set_scroll(state, after_g, start + min(row, max(height - 1, 0)))
    end
  end

  defp cycle_agent(state, path, step) do
    paths = Model.agent_paths(Map.fetch!(state.model.windows, path))

    case paths do
      [_only] ->
        state

      _ ->
        current = Enum.find_index(paths, &(&1 == (state.pane.agent || path))) || 0
        next = Enum.at(paths, rem(current + step + length(paths), length(paths)))
        %{state | pane: fresh_pane(if(next == path, do: nil, else: next)), selection: nil}
    end
  end

  defp notice(state, text),
    do: %{state | model: %{state.model | notices: Enum.take([text | state.model.notices], 3)}}

  # The activated pane's transcript as plain text: the same blocks the pane draws,
  # unstyled and unwrapped, so a copy is the agent's own line breaks rather than
  # the ones this terminal width happened to impose.
  @spec pane_text(map()) :: String.t() | nil
  defp pane_text(state) do
    case View.pane_geometry(state) do
      nil ->
        nil

      g ->
        g.blocks
        |> Enum.concat()
        |> Enum.map_join("\n", &Model.line_text/1)
        |> String.trim_trailing()
    end
  end

  defp copy_pane(state), do: notice(state, copy_result(state))

  # Releasing a drag copies straight away, so the notice says what landed on the
  # clipboard without the user reaching for a key.
  defp copy_selection(state), do: notice(state, copy_result(state))

  # The text a selection covers: the wrapped rows between its two ends, sliced by
  # column on the first and last, rails dropped. Wrapped rather than logical text
  # because a selection is by definition what the reader sees — unlike a whole-
  # transcript copy, which deliberately restores the agent's own line breaks.
  @spec selection_text(map(), selection()) :: String.t() | nil
  defp selection_text(state, sel) do
    case View.pane_geometry(state) do
      nil ->
        nil

      g ->
        {{r1, c1}, {r2, c2}} = ordered(sel)
        flat = Enum.concat(g.blocks)
        last = min(r2, max(g.total - 1, 0))

        if r1 > last do
          ""
        else
          r1..last
          |> Enum.map_join("\n", fn row ->
            case Model.rows(flat, g.inner_w, row, 1) do
              [line] -> Model.row_slice(line, from_col(row, r1, c1), to_col(row, last, r2, c2))
              [] -> ""
            end
          end)
        end
    end
  end

  # Anchor and cursor in reading order, so a drag upwards or leftwards selects the
  # same text as the same drag the other way.
  defp ordered(%{anchor: a, cursor: c}), do: if(a <= c, do: {a, c}, else: {c, a})

  defp from_col(row, first, col), do: if(row == first, do: col, else: 0)

  # The far end is exclusive of the cell under the pointer's *start* and inclusive
  # of the one it is on, which is what a drag looks like it selects.
  defp to_col(row, last, r2, col), do: if(row == last and last == r2, do: col + 1, else: :end)

  # The message the notice line shows: what was copied and by which command, or
  # why this machine could not.
  defp copy_result(%{selection: %{} = sel} = state) do
    case selection_text(state, sel) do
      nil ->
        "no window is activated"

      "" ->
        "nothing selected"

      text ->
        report(
          text,
          "#{String.length(text)} #{plural(String.length(text), "char")} from the selection"
        )
    end
  end

  defp copy_result(state) do
    case pane_text(state) do
      nil ->
        "no window is activated"

      "" ->
        "nothing to copy yet"

      text ->
        lines = length(String.split(text, "\n"))
        report(text, "#{lines} #{plural(lines, "line")}")
    end
  end

  defp report(text, what) do
    case Client.copy(text) do
      {:ok, cmd} -> "copied #{what} to the clipboard (#{cmd})"
      {:error, msg} -> msg
    end
  end

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp apply_event(state, event) do
    model = Model.apply(state.model, event)

    model =
      case event do
        %{type: :notice, data: %{text: "watch mode" <> _}} -> model
        _ -> model
      end

    # A window that ends while it is open has been seen ending: only one you were not
    # looking at is unread.
    model =
      case state.focus do
        {:window, path} -> Model.seen(model, path)
        _ -> model
      end

    state = %{state | model: model}
    if event.type == :remote_status, do: recheck_loop(state), else: state
  end

  # The loop on the status line is the journal's, and a daemon that stopped mid-loop left
  # the journal saying it runs: `loop_stopped interrupted` is written only when the
  # session is next activated. So a screen that shows one asks the session, which knows
  # its tree is not running, whenever it may know better than the journal does — when the
  # screen opens, and when the connection says something about the session. From a task,
  # so a connection still coming up never holds the screen.
  defp recheck_loop(state) do
    case Model.loop(state.model) do
      nil ->
        state

      %{id: id} ->
        server = self()
        sid = state.session_id
        _ = Task.start(fn -> send(server, {:loop_checked, sid, id, Client.loop(sid)}) end)
        state
    end
  end

  # When the mailbox is deep, collapse every queued delta in one pass rather than one message at a time.
  defp drain_mailbox(state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n > @mailbox_threshold -> drain(state, n)
      _ -> state
    end
  end

  defp drain(state, 0), do: state

  defp drain(state, n) do
    sid = state.session_id

    receive do
      {:troupe_event, %{session_id: ^sid} = e} -> drain(apply_event(state, e), n - 1)
    after
      0 -> state
    end
  end

  defp schedule_tick(state, delay \\ @tick_ms)
  defp schedule_tick(%{tick_scheduled: true} = state, _delay), do: state

  defp schedule_tick(state, delay) do
    Process.send_after(self(), :tick, delay)
    %{state | tick_scheduled: true}
  end

  defp rebuild(sid) do
    events = Client.events(sid)

    workspace =
      case Enum.find(events, &(&1.type == :session_started)) do
        %{data: %{workspace: ws}} -> ws
        _ -> workspace_of(sid)
      end

    model = Model.rebuild(sid, workspace, events)
    %{model | watch: Client.watch_status(sid), remote: remote(sid)}
  end

  # The model learns what a remote session allows from `:remote_status` events,
  # but a window opened on one that is already attached has missed them: the
  # capability is read once here so the first frame is honest too.
  defp remote(sid) do
    case Client.capability(sid) do
      %{remote?: true} = capability -> capability
      _ -> nil
    end
  end

  # A remote session has no checkout here; its label is what the client calls it.
  defp workspace_of(sid) do
    case Client.context(sid) do
      {workspace, _config} when is_binary(workspace) -> workspace
      _ -> File.cwd!()
    end
  end

  defp split_first(text) do
    case String.split(text, " ", parts: 2) do
      [name] -> {name, ""}
      [name, rest] -> {name, String.trim(rest)}
    end
  end

  @doc """
  Tab completion on the command line: command names (`wor` → `worktree `), window paths
  for the commands whose first argument is a window — `/merge`, `/discard`, `/cancel`,
  `/dismiss`, `/copy` as the table has them (repeated Tab cycles through the matches) —
  and `@file` paths anywhere. `/merge` and `/discard` only offer worktree branches that
  have finished and are neither merged nor discarded.
  """
  @spec complete_command(String.t(), map()) :: String.t()
  def complete_command(text, state) do
    cond do
      Regex.match?(~r/@[^\s@]*$/, text) ->
        complete_file(text, state.model.workspace)

      not String.contains?(text, " ") ->
        complete_name(text, command_names(state))

      true ->
        [name, arg] = String.split(text, " ", parts: 2)
        # A name the palette put on the line carries its slash; the completion keeps it.
        {slash, name} =
          if String.starts_with?(name, "/"),
            do: {"/", String.trim_leading(name, "/")},
            else: {"", name}

        cond do
          takes_window?(state, name) ->
            slash <> complete_path(name, String.trim(arg), state)

          name == "worktree" and not String.contains?(String.trim(arg), " ") ->
            slash <> complete_worktree(arg, state)

          true ->
            text
        end
    end
  end

  # What Tab completes on the line: the table's names and aliases (Decision 698), agents
  # included; before the harness has answered, the agents alone.
  defp command_names(%{commands: [], agents: agents}), do: agents

  defp command_names(%{commands: commands}),
    do: Enum.flat_map(commands, &[&1["name"] | &1["aliases"]])

  # A command whose first argument is a window takes a window's number or path after it.
  defp takes_window?(state, name) do
    case Enum.find(state.commands, &(&1["name"] == name)) do
      %{"args" => [%{"kind" => "window"} | _]} -> true
      _ -> false
    end
  end

  # `/worktree <Tab>` offers the worktrees the user has checked out (by relative path or
  # branch) and, as `<name>:`, the worktrees Troupe manages for this workspace.
  defp complete_worktree(arg, state) do
    arg = String.trim(arg)
    workspace = state.model.workspace

    {checked_out, managed} = Client.worktrees(workspace)

    names =
      checked_out
      |> Enum.flat_map(&[&1.rel, &1.branch])
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(Enum.map(managed, &(&1 <> ":")))
      |> Enum.uniq()
      |> Enum.sort()

    picked = pick(names, arg)
    "worktree " <> picked <> if(picked == arg, do: "", else: " ")
  end

  defp complete_name(prefix, names) do
    case names |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort() do
      [] -> prefix
      [only] -> only <> " "
      [first | _] = many -> if prefix in many, do: cycle(many, prefix) <> " ", else: first <> " "
    end
  end

  defp complete_path(name, arg, state) do
    candidates =
      state.model.windows
      |> Map.values()
      |> Enum.filter(&eligible?(name, &1))
      |> Enum.map(& &1.path)
      |> Enum.sort()

    name <> " " <> pick(candidates, arg)
  end

  defp eligible?(cmd, w) when cmd in ["merge", "discard"] do
    wt = w.worktree || %{}

    w.isolation == :worktree and w.state in [:done_unread, :failed_unread] and
      Map.get(wt, :managed, true) == true and not Map.get(wt, :merged, false) and
      not Map.get(wt, :discarded, false)
  end

  defp eligible?("cancel", w), do: w.state != :dismissed
  defp eligible?("dismiss", w), do: w.state in [:done_unread, :failed_unread]
  # Any window has a transcript worth copying, dismissed ones included.
  defp eligible?("copy", _w), do: true
  # A window command the table gained and this list has no rule for yet: any live window.
  defp eligible?(_cmd, w), do: w.state != :dismissed

  # Exact match: rotate through every candidate. Otherwise the first candidate with that prefix.
  defp pick(candidates, arg) do
    if arg in candidates,
      do: cycle(candidates, arg),
      else: Enum.find(candidates, arg, &String.starts_with?(&1, arg))
  end

  defp cycle(list, current) do
    i = Enum.find_index(list, &(&1 == current))
    Enum.at(list, rem(i + 1, length(list)))
  end

  @doc false
  def complete_file(text, workspace) do
    case Regex.run(~r/@([^\s@]*)$/, text) do
      [full, partial] ->
        # Neither the workspace nor what was typed is a pattern: a Windows workspace is
        # written with backslashes, and a `[` or a `{` in either is part of a name. Only the
        # trailing `*` is a wildcard, and the matches are relative to the workspace as the
        # glob reads it, with forward slashes.
        root = String.replace(workspace, "\\", "/")

        matches =
          root
          |> Glob.escape()
          |> Path.join(Glob.escape(partial) <> "*")
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, root))
          |> Enum.sort()

        case matches do
          [first | _] ->
            String.replace_suffix(
              text,
              full,
              "@" <> first <> if(File.dir?(Path.join(root, first)), do: "/", else: "")
            )

          [] ->
            text
        end

      nil ->
        text
    end
  end
end
