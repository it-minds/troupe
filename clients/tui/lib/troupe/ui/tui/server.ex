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
  alias Troupe.Settings
  alias Troupe.UI.HQ
  alias Troupe.UI.TUI.{Model, View}

  @tick_ms 33
  @mailbox_threshold 50

  @type state :: %{
          session_id: String.t(),
          workspace: String.t(),
          model: Model.t(),
          focus:
            :command | {:window, String.t()} | :settings | :observer | :sessions | :files | :hq,
          cmd_text: String.t(),
          win_text: String.t(),
          commands: [String.t()],
          tick: non_neg_integer(),
          now: integer(),
          dirty: boolean(),
          tick_scheduled: boolean(),
          quit_armed: boolean(),
          expanded: boolean(),
          pane: pane(),
          selection: selection() | nil,
          size: {non_neg_integer(), non_neg_integer()},
          answer: answer() | nil,
          settings: settings() | nil,
          observer: %{cursor: non_neg_integer()} | nil,
          sessions: sessions() | nil,
          files: files() | nil,
          hq: HQ.t() | nil,
          slow_render_ms: non_neg_integer(),
          on_quit: (-> any())
        }

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
  Settings-page state: the config as loaded, the cursor, the value being typed,
  and the open menu — a setting with choices (the models) shows them instead of
  asking you to type an identifier from memory.
  """
  @type settings :: %{
          config: Troupe.Config.t(),
          cursor: non_neg_integer(),
          editing: String.t() | nil,
          scroll: non_neg_integer(),
          status: String.t() | nil,
          picker: picker() | nil
        }

  @typedoc "An open menu: the choices offered and where the cursor sits (past the end means type one)."
  @type picker :: %{choices: [Settings.choice()], cursor: non_neg_integer()}

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

  def via(sid), do: {:via, Registry, {Troupe.Registry, {:tui, sid}}}

  ## ExRatatui.App

  @impl true
  def mount(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    :ok = Client.subscribe(sid)
    model = rebuild(sid)

    state = %{
      session_id: sid,
      workspace: model.workspace,
      model: model,
      focus: :command,
      cmd_text: "",
      win_text: "",
      commands: Client.commands(sid),
      tick: 0,
      now: System.system_time(:millisecond),
      dirty: false,
      tick_scheduled: false,
      quit_armed: false,
      expanded: false,
      pane: fresh_pane(),
      selection: nil,
      settings: nil,
      answer: nil,
      observer: nil,
      sessions: nil,
      files: nil,
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

    {:ok, schedule_tick(state)}
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
  # nothing to update and the message is dropped.
  def handle_info({:troupe_fleet, _plane, session_id, diff}, %{hq: hq} = state) when hq != nil,
    do: {:noreply, %{state | hq: HQ.summary(hq, session_id, diff), dirty: true}, render?: false}

  def handle_info({:troupe_fleet, _plane, _session_id, _diff}, state),
    do: {:noreply, state, render?: false}

  def handle_info(:force_render, state),
    do: {:noreply, %{state | now: System.system_time(:millisecond), dirty: false}, render?: true}

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

  def handle_event(%Key{} = key, %{focus: :command} = state) do
    case command_key(key, %{state | quit_armed: false}) do
      %{quitting: true} = state ->
        state.on_quit.()
        {:stop, state}

      state ->
        {:noreply, state}
    end
  end

  def handle_event(%Key{} = key, %{focus: :settings} = state),
    do: {:noreply, settings_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :observer} = state),
    do: {:noreply, observer_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :sessions} = state),
    do: {:noreply, sessions_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :files} = state),
    do: {:noreply, files_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: :hq} = state),
    do: {:noreply, hq_key(key, %{state | quit_armed: false})}

  def handle_event(%Key{} = key, %{focus: {:window, path}} = state) do
    if Map.has_key?(state.model.windows, path),
      do: {:noreply, window_key(key, path, %{state | quit_armed: false})},
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
      :command -> {:noreply, %{state | cmd_text: state.cmd_text <> content}}
      {:window, _} -> {:noreply, %{state | win_text: state.win_text <> content}}
      :observer -> {:noreply, state, render?: false}
      :sessions -> {:noreply, state, render?: false}
      :files -> {:noreply, state, render?: false}
      :hq -> {:noreply, state, render?: false}
      :settings -> {:noreply, paste_into_settings(state, content)}
    end
  end

  def handle_event(%Mouse{kind: "down"}, %{focus: focus} = state)
      when focus in [:settings, :observer, :sessions, :files, :hq],
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

      :settings when state.settings.picker != nil ->
        p = state.settings.picker
        cursor = p.cursor |> Kernel.+(div(step, 3)) |> max(0) |> min(length(p.choices))
        {:noreply, put_settings(state, picker: %{p | cursor: cursor})}

      :settings ->
        {:noreply, put_settings(state, scroll: max(state.settings.scroll + step, 0))}

      _ ->
        {:noreply, state, render?: false}
    end
  end

  def handle_event(_event, state), do: {:noreply, state, render?: false}

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

  defp command_key(%Key{code: "esc"}, state), do: %{state | cmd_text: ""}

  defp command_key(%Key{code: "backspace"}, state),
    do: %{state | cmd_text: String.slice(state.cmd_text, 0..-2//1)}

  defp command_key(%Key{code: "tab"}, state),
    do: %{state | cmd_text: complete_command(state.cmd_text, state)}

  # A newline in the box rather than running the command: any modifier on Enter,
  # and Ctrl-J. The box holds multiline (typed or pasted) input, folded to a
  # `<pasted N lines>` marker in the title. Shift-Enter alone is not enough:
  # most terminals send a bare `\r` for it, indistinguishable from Enter.
  defp command_key(%Key{code: "enter", modifiers: mods}, state) when mods != [],
    do: %{state | cmd_text: state.cmd_text <> "\n"}

  defp command_key(%Key{code: "j", modifiers: ["ctrl"]}, state),
    do: %{state | cmd_text: state.cmd_text <> "\n"}

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

  defp command_key(%Key{code: code, modifiers: mods}, state)
       when byte_size(code) >= 1 and mods in [[], ["shift"]] do
    if String.length(code) == 1, do: %{state | cmd_text: state.cmd_text <> code}, else: state
  end

  defp command_key(_key, state), do: state

  defp run_command(state, text) do
    sid = state.session_id
    text = String.trim_leading(text, "/")
    {name, args} = split_first(text)

    active =
      case state.focus do
        {:window, p} -> p
        _ -> nil
      end

    target = fn -> if args == "", do: active, else: resolve_window(state, args) end

    result =
      case name do
        q when q in ["quit", "exit", "q"] ->
          :quit

        "" ->
          {:notice, "commands: " <> Enum.map_join(state.commands, " ", &("/" <> &1))}

        "watch" ->
          toggle_watch(sid, state.model.watch.enabled)

        "cancel" ->
          with_target(target.(), &Client.cancel_branch(sid, &1))

        "dismiss" ->
          with_target(target.(), &Client.dismiss(sid, &1))

        "merge" ->
          with_target(target.(), &Client.merge(sid, &1))

        "discard" ->
          with_target(target.(), &Client.discard(sid, &1))

        n when n in ["settings", "help", "?"] ->
          :settings

        n when n in ["models", "model"] ->
          :models

        n when n in ["observer", "agents-tree", "tree"] ->
          :observer

        "agents" ->
          {:notice, "agents: " <> Enum.map_join(state.commands, ", ", & &1)}

        n when n in ["resume", "sessions"] ->
          {:sessions, args}

        "memory" ->
          notice_of(Client.memory(sid, String.trim(args)))

        "upload" ->
          notice_of(upload(sid, String.trim(args)))

        "files" ->
          :files

        n when n in ["hq", "remote"] ->
          {:hq, args}

        "copy" ->
          copy_command(state, String.trim(args))

        cmd ->
          Client.dispatch(sid, cmd, args)
      end

    state = %{state | cmd_text: ""}

    case result do
      :quit -> %{state | quitting: true}
      :files -> toggle_files(state)
      {:hq, arg} -> open_hq(state, plane_arg(arg))
      :settings -> open_settings(state)
      :models -> open_models(state)
      :observer -> %{state | focus: :observer, cmd_text: "", observer: %{cursor: 0}}
      {:sessions, ""} -> open_sessions(state)
      {:sessions, arg} -> resume_by_arg(state, arg)
      {:ok, _} -> state
      :ok -> state
      {:notice, text} -> notice(state, text)
      {:error, msg} when is_binary(msg) -> notice(state, msg)
      {:error, other} -> notice(state, inspect(other))
    end
  end

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

  # Sessions this window offers to switch to: the ones on disk for the directory the
  # TUI was opened in that got as far as a branch, plus the session on screen (which
  # may still be empty) so the list always says where you are.
  defp pickable_sessions(state) do
    case Client.sessions({:local, state.workspace}) do
      {:ok, sessions} ->
        Enum.filter(sessions, &(&1.branches != [] or &1.id == state.session_id))

      {:error, _reason} ->
        []
    end
  end

  defp open_sessions(state) do
    entries = pickable_sessions(state)
    cursor = Enum.find_index(entries, &(&1.id == state.session_id)) || 0

    %{state | focus: :sessions, cmd_text: "", sessions: %{entries: entries, cursor: cursor}}
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

  defp sessions_key(_key, state), do: state

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
        commands: Client.commands(sid),
        focus: :command,
        cmd_text: "",
        win_text: "",
        expanded: false,
        pane: fresh_pane(),
        settings: nil,
        observer: nil,
        sessions: nil,
        dirty: true
    }

    retire(previous)
    notice(state, "resumed #{sid}")
  end

  defp rename(previous, sid) do
    if {:tui, previous} in Registry.keys(Troupe.Registry, self()) do
      Registry.unregister(Troupe.Registry, {:tui, previous})
      _ = Registry.register(Troupe.Registry, {:tui, sid}, nil)
    end

    :ok
  end

  # A session with no branches is the scratch session `troupe` opens before you have
  # dispatched anything: nothing in its log will be read again, and leaving it running
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

    state = %{state | focus: :hq, cmd_text: "", hq: HQ.open(origin, state.workspace)}
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
    do: load_files(%{state | focus: :files, cmd_text: ""}, "session:/")

  defp toggle_files(state), do: %{state | focus: :command, files: nil}

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

  defp open_settings(state) do
    {_workspace, config} = Client.context(state.session_id)

    %{
      state
      | focus: :settings,
        cmd_text: "",
        settings: %{config: config, cursor: 0, editing: nil, scroll: 0, status: nil, picker: nil}
    }
  end

  # `/models` is `/settings` opened on the default model, with its menu up.
  defp open_models(state) do
    state = open_settings(state)
    cursor = Enum.find_index(Settings.fields(), &(&1.key == "models.default")) || 0
    open_picker(put_settings(state, cursor: cursor))
  end

  defp open_picker(%{settings: s} = state) do
    field = Enum.at(Settings.fields(), s.cursor)

    case Settings.choices(field, s.config) do
      [] -> put_settings(state, editing: Settings.format(s.config, field.key), status: nil)
      choices -> put_settings(state, picker: %{choices: choices, cursor: 0}, status: nil)
    end
  end

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
        put_settings(state, picker: nil, editing: Settings.format(s.config, field.key))

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

  defp settings_key(%Key{code: code}, %{settings: s} = state) when code in ["enter", " "] do
    field = Enum.at(Settings.fields(), s.cursor)

    case field.type do
      :bool -> apply_setting(state, field.key, not Settings.get(s.config, field.key))
      :model -> open_picker(state)
      _ -> put_settings(state, editing: Settings.format(s.config, field.key), status: nil)
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

  defp apply_setting(state, key, value) do
    sid = state.session_id

    state =
      case Client.put_setting(sid, key, value) do
        {:ok, config, path} ->
          put_settings(state,
            config: config,
            editing: nil,
            status: "#{key} = #{Settings.format(config, key)} · saved to #{path}"
          )

        {:error, msg} ->
          {_workspace, config} = Client.context(sid)
          put_settings(state, config: config, editing: nil, status: to_message(msg))
      end

    %{state | model: %{state.model | watch: Client.watch_status(sid)}}
  end

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

  defp window_key(%Key{code: "esc"}, _path, state), do: %{state | focus: :command, win_text: ""}

  # Ctrl-Y copies: the selection when the mouse made one, and otherwise the whole
  # transcript (same as `/copy`) — with mouse reporting on the terminal's own
  # selection is gone, and the interesting rows have usually scrolled off. It has
  # to come before the `y`/`n`/`a` approval clause, which matches any modifier.
  defp window_key(%Key{code: "y", modifiers: ["ctrl"]}, _path, state), do: copy_pane(state)

  # Scrolling: PgUp/PgDn, Home and End always; ↑/↓ while nothing is typed; End (or
  # reaching the bottom) follows the tail again.
  defp window_key(%Key{code: "page_up"}, _path, state), do: page_by(state, -1)
  defp window_key(%Key{code: "page_down"}, _path, state), do: page_by(state, 1)
  defp window_key(%Key{code: "home"}, _path, state), do: scroll_to(state, 0)
  defp window_key(%Key{code: "end"}, _path, state), do: follow(state)
  defp window_key(%Key{code: "up"}, _path, %{win_text: ""} = state), do: scroll_by(state, -1)
  defp window_key(%Key{code: "down"}, _path, %{win_text: ""} = state), do: scroll_by(state, 1)

  # ←/→ cycle through the branch's agents (root first), so a subagent's transcript can be read.
  defp window_key(%Key{code: code}, path, %{win_text: ""} = state) when code in ["left", "right"],
    do: cycle_agent(state, path, if(code == "right", do: 1, else: -1))

  defp window_key(%Key{code: "backspace"}, _path, state),
    do: %{state | win_text: String.slice(state.win_text, 0..-2//1)}

  defp window_key(%Key{code: "tab"}, path, %{win_text: ""} = state) do
    w = Map.fetch!(state.model.windows, path)

    case state.commands do
      [] ->
        state

      commands ->
        idx = Enum.find_index(commands, &(&1 == w.profile)) || -1
        next = Enum.at(commands, rem(idx + 1, length(commands)))

        case Client.switch_profile(state.session_id, path, next) do
          :ok -> state
          {:error, reason} -> notice(state, to_message(reason))
        end
    end
  end

  defp window_key(%Key{code: "tab"}, _path, state),
    do: %{state | win_text: complete_file(state.win_text, state.model.workspace)}

  defp window_key(%Key{code: code}, path, %{win_text: ""} = state) when code in ["y", "n", "a"] do
    w = Map.fetch!(state.model.windows, path)

    case answerable(w, state.pane.agent || path) do
      nil ->
        %{state | win_text: code}

      %{call_id: call_id} ->
        decision = %{"y" => :allow, "n" => :deny, "a" => :allow_session}[code]

        case Client.approve(state.session_id, call_id, decision) do
          :ok -> follow(state)
          {:error, reason} -> notice(follow(state), approval_error(reason))
        end
    end
  end

  defp window_key(%Key{code: "x"}, path, %{win_text: ""} = state) do
    case Client.cancel_branch(state.session_id, path) do
      :ok -> %{state | focus: :command}
      {:error, msg} -> notice(state, to_message(msg))
    end
  end

  defp window_key(%Key{code: "d"}, path, %{win_text: ""} = state) do
    case Client.dismiss(state.session_id, path) do
      :ok -> %{state | focus: :command}
      {:error, msg} -> notice(state, to_message(msg))
    end
  end

  defp window_key(%Key{code: "e"}, _path, %{win_text: ""} = state), do: toggle_expanded(state)

  # A digit picks an offered option: with a single-choice question it is the
  # answer, with `multiple` it toggles a tick that Enter later sends. Only while
  # such a question is on screen — otherwise digits are ordinary typed text.
  defp window_key(%Key{code: <<d>>}, path, %{win_text: ""} = state) when d in ?1..?9 do
    w = Map.fetch!(state.model.windows, path)

    case pending_of(w, state.pane.agent || path, [:question]) do
      %{options: options} = q when options != [] ->
        case Enum.at(options, d - ?1) do
          nil -> state
          %{label: label} -> choose(state, q, label)
        end

      _ ->
        %{state | win_text: <<d>>}
    end
  end

  # A newline in the input box: any modifier on Enter, and Ctrl-J. Multiline
  # (typed or pasted) input folds to a `<pasted N lines>` marker in the title.
  defp window_key(%Key{code: "enter", modifiers: mods}, _path, state) when mods != [],
    do: %{state | win_text: state.win_text <> "\n"}

  defp window_key(%Key{code: "j", modifiers: ["ctrl"]}, _path, state),
    do: %{state | win_text: state.win_text <> "\n"}

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
        Client.edit_todo(sid, path, {:cancel, String.trim_leading(text, "/todo cancel ")})

      String.starts_with?(text, "/todo add ") ->
        Client.edit_todo(sid, path, {:add, String.trim_leading(text, "/todo add ")})

      String.starts_with?(text, "/upload ") ->
        upload(sid, String.trim(String.trim_leading(text, "/upload ")))

      question = pending_of(w, state.pane.agent || path, [:question]) ->
        Client.answer(sid, question.call_id, text)

      true ->
        Client.send_input(sid, path, text)
    end

    # Any Enter that reaches here either answered the question or replaced it
    # with fresh input, so a half-built selection is stale either way.
    follow(%{state | win_text: "", answer: nil})
  end

  defp window_key(%Key{code: code, modifiers: mods}, _path, state) when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: %{state | win_text: state.win_text <> code}, else: state
  end

  defp window_key(_key, _path, state), do: state

  # y/n/a answers approvals and the budget question — a delegated subagent raises
  # both, and its pending item lives in the branch's window like the root's. When
  # more than one is outstanding the agent whose pane is open wins, so the keys
  # answer the request the reader is looking at rather than the oldest one.
  defp answerable(w, viewed), do: pending_of(w, viewed, [:approval, :budget])

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
    model = %{state.model | windows: Map.update!(state.model.windows, path, &%{&1 | badge: false})}
    agent = if agent == path, do: nil, else: agent

    %{
      state
      | focus: {:window, path},
        win_text: "",
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
    do: %{state | focus: :command, win_text: "", pane: fresh_pane(), selection: nil}

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

    %{state | model: model}
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

  @path_commands ~w(merge discard cancel dismiss copy)

  @doc """
  Tab completion on the command line: command names (`wor` → `worktree `), window paths
  for `/merge`, `/discard`, `/cancel`, `/dismiss`, `/copy` (repeated Tab cycles through the
  matches), and `@file` paths anywhere. `/merge` and `/discard` only offer worktree branches
  that have finished and are neither merged nor discarded.
  """
  @spec complete_command(String.t(), map()) :: String.t()
  def complete_command(text, state) do
    cond do
      Regex.match?(~r/@[^\s@]*$/, text) ->
        complete_file(text, state.model.workspace)

      not String.contains?(text, " ") ->
        complete_name(
          text,
          state.commands ++
            @path_commands ++
            ~w(settings help observer models watch agents sessions resume memory quit)
        )

      true ->
        [name, arg] = String.split(text, " ", parts: 2)

        cond do
          name in @path_commands ->
            complete_path(name, String.trim(arg), state)

          name == "worktree" and not String.contains?(String.trim(arg), " ") ->
            complete_worktree(arg, state)

          true ->
            text
        end
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
        matches =
          workspace
          |> Path.join(partial <> "*")
          |> Path.wildcard()
          |> Enum.map(&Path.relative_to(&1, workspace))
          |> Enum.sort()

        case matches do
          [first | _] ->
            String.replace_suffix(
              text,
              full,
              "@" <> first <> if(File.dir?(Path.join(workspace, first)), do: "/", else: "")
            )

          [] ->
            text
        end

      nil ->
        text
    end
  end
end
