defmodule Troupe.UI.TUI.Server do
  @moduledoc """
  The terminal UI: an `ExRatatui.App` subscribed to `Troupe.Events`. It never
  slows an agent down: deltas are coalesced and the screen redraws at most
  30 times per second; when the mailbox grows past a threshold the queued
  deltas are collapsed in one pass. After a restart it rebuilds every window
  from the session log.
  """

  use ExRatatui.App

  alias ExRatatui.Event.{Key, Mouse, Paste, Resize}
  alias Troupe.Events
  alias Troupe.Session.{Dispatcher, Log, Memory, Watcher}
  alias Troupe.Settings
  alias Troupe.UI.TUI.{Model, View}

  @tick_ms 33
  @mailbox_threshold 50

  @type state :: %{
          session_id: String.t(),
          model: Model.t(),
          focus: :command | {:window, String.t()} | :settings | :observer,
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
          size: {non_neg_integer(), non_neg_integer()},
          settings: settings() | nil,
          observer: %{cursor: non_neg_integer()} | nil,
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

  def via(sid), do: {:via, Registry, {Troupe.Registry, {:tui, sid}}}

  ## ExRatatui.App

  @impl true
  def mount(opts) do
    sid = Keyword.fetch!(opts, :session_id)
    :ok = Events.subscribe(sid)

    state = %{
      session_id: sid,
      model: rebuild(sid),
      focus: :command,
      cmd_text: "",
      win_text: "",
      commands: Dispatcher.commands(sid),
      tick: 0,
      now: System.system_time(:millisecond),
      dirty: false,
      tick_scheduled: false,
      quit_armed: false,
      expanded: false,
      pane: fresh_pane(),
      settings: nil,
      observer: nil,
      quitting: false,
      size: initial_size(opts),
      slow_render_ms: Keyword.get(opts, :slow_render_ms, 0),
      on_quit: Keyword.get(opts, :on_quit, fn -> Troupe.CLI.Runner.quit() end)
    }

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

  @impl true
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

    state = resume_follow(state)
    needs_blink = Enum.any?(Model.windows(state.model), &(&1.state in [:running, :needs_input]))

    if state.dirty or needs_blink do
      {:noreply, schedule_tick(%{state | dirty: false}, if(state.dirty, do: @tick_ms, else: 120)),
       render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  # Test seam: render synchronously regardless of dirtiness.
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

  def handle_event(%Key{} = key, %{focus: {:window, path}} = state) do
    if Map.has_key?(state.model.windows, path),
      do: {:noreply, window_key(key, path, %{state | quit_armed: false})},
      else: handle_event(key, to_command_line(state))
  end

  def handle_event(%Resize{width: w, height: h}, state), do: {:noreply, %{state | size: {w, h}}}

  # Bracketed paste arrives as one %Paste{} event, not a stream of keys. Insert the
  # raw text where the user is focused: the command line, an active window's input box,
  # or a settings field.
  def handle_event(%Paste{content: content}, state) do
    state = %{state | quit_armed: false}

    case state.focus do
      :command -> {:noreply, %{state | cmd_text: state.cmd_text <> content}}
      {:window, _} -> {:noreply, %{state | win_text: state.win_text <> content}}
      :observer -> {:noreply, state, render?: false}
      :settings -> {:noreply, paste_into_settings(state, content)}
    end
  end

  def handle_event(%Mouse{kind: "down"}, %{focus: focus} = state)
      when focus in [:settings, :observer],
      do: {:noreply, state, render?: false}

  def handle_event(%Mouse{kind: "down", button: "left", x: x, y: y}, state) do
    case clicked_window(state, x, y) do
      nil -> {:noreply, state, render?: false}
      path when state.focus == {:window, path} -> {:noreply, follow(state)}
      _ when state.focus in [:settings, :observer] -> {:noreply, state, render?: false}
      path -> {:noreply, activate(%{state | quit_armed: false}, path)}
    end
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

  # Shift-Enter inserts a newline rather than running: the box can hold multiline
  # (typed or pasted) input, folded to a `<pasted N lines>` marker in the title.
  defp command_key(%Key{code: "enter", modifiers: ["shift"]}, state),
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
          with_target(target.(), &Troupe.cancel_branch(sid, &1))

        "dismiss" ->
          with_target(target.(), &Troupe.dismiss(sid, &1))

        "merge" ->
          with_target(target.(), &Troupe.merge(sid, &1))

        "discard" ->
          with_target(target.(), &Troupe.discard(sid, &1))

        n when n in ["settings", "help", "?"] ->
          :settings

        n when n in ["models", "model"] ->
          :models

        n when n in ["observer", "agents-tree", "tree"] ->
          :observer

        "agents" ->
          {:notice, "agents: " <> Enum.map_join(state.commands, ", ", & &1)}

        "sessions" ->
          {:notice, "sessions: " <> Enum.map_join(Troupe.sessions(), ", ", & &1.session_id)}

        "resume" ->
          {:notice, "resume from the shell: troupe resume #{args}"}

        "memory" ->
          memory_command(sid, String.trim(args))

        cmd ->
          Troupe.dispatch(sid, cmd, args)
      end

    state = %{state | cmd_text: ""}

    case result do
      :quit -> %{state | quitting: true}
      :settings -> open_settings(state)
      :models -> open_models(state)
      :observer -> %{state | focus: :observer, cmd_text: "", observer: %{cursor: 0}}
      {:ok, _} -> state
      :ok -> state
      {:notice, text} -> notice(state, text)
      {:error, msg} when is_binary(msg) -> notice(state, msg)
      {:error, other} -> notice(state, inspect(other))
    end
  end

  ## Project brief

  defp memory_command(sid, "refresh") do
    Troupe.dispatch(
      sid,
      "librarian",
      "The project brief is out of date. Revise it against the repository as it is now."
    )
  end

  defp memory_command(sid, "forget") do
    :ok = Memory.forget(sid)
    {:notice, "project brief forgotten; /memory refresh writes a new one"}
  end

  defp memory_command(sid, "") do
    case Memory.brief(sid) do
      nil -> {:notice, "no project brief yet; /memory refresh writes one"}
      brief -> {:notice, brief_summary(sid, brief)}
    end
  end

  defp memory_command(_sid, other) do
    {:notice, "unknown /memory #{other}; use /memory, /memory refresh or /memory forget"}
  end

  defp brief_summary(sid, brief) do
    titles = brief.sections |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))
    built = if brief.built_at, do: DateTime.to_date(brief.built_at), else: "never"
    "project brief (#{Memory.status(sid)}, built #{built}): " <> Enum.join(titles, ", ")
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

  ## Settings page

  defp open_settings(state) do
    {_workspace, config} = Troupe.config(state.session_id)

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
      case Troupe.put_setting(sid, key, value) do
        {:ok, config, path} ->
          put_settings(state,
            config: config,
            editing: nil,
            status: "#{key} = #{Settings.format(config, key)} · saved to #{path}"
          )

        {:error, msg} ->
          {_workspace, config} = Troupe.config(sid)
          put_settings(state, config: config, editing: nil, status: msg)
      end

    %{state | model: %{state.model | watch: Watcher.status(sid)}}
  end

  defp put_settings(state, changes),
    do: %{state | settings: Enum.into(changes, state.settings)}

  # Paste into an open settings-edit field; if nothing is being edited, ignore it so
  # an accidental paste doesn't clobber the page.
  defp paste_into_settings(%{settings: %{editing: text}} = state, content) when is_binary(text),
    do: put_settings(state, editing: text <> content)

  defp paste_into_settings(state, _content), do: state

  defp toggle_watch(sid, true) do
    Watcher.disable(sid)
    {:notice, "watch mode off"}
  end

  defp toggle_watch(sid, false) do
    {:ok, backend} = Watcher.enable(sid)
    {:notice, "watch mode on (#{backend})"}
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

  defp window_key(%Key{code: "esc"}, _path, state), do: %{state | focus: :command, win_text: ""}

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
    idx = Enum.find_index(state.commands, &(&1 == w.profile)) || -1
    next = Enum.at(state.commands, rem(idx + 1, length(state.commands)))
    Troupe.switch_profile(state.session_id, path, next)
    state
  end

  defp window_key(%Key{code: "tab"}, _path, state),
    do: %{state | win_text: complete_file(state.win_text, state.model.workspace)}

  defp window_key(%Key{code: code}, path, %{win_text: ""} = state) when code in ["y", "n", "a"] do
    w = Map.fetch!(state.model.windows, path)

    case Enum.find(w.pending, &(&1.kind == :approval)) do
      nil ->
        %{state | win_text: code}

      %{call_id: call_id} ->
        decision = %{"y" => :allow, "n" => :deny, "a" => :allow_session}[code]
        Troupe.approve(state.session_id, call_id, decision)
        follow(state)
    end
  end

  defp window_key(%Key{code: "x"}, path, %{win_text: ""} = state) do
    case Troupe.cancel_branch(state.session_id, path) do
      :ok -> %{state | focus: :command}
      {:error, msg} -> notice(state, msg)
    end
  end

  defp window_key(%Key{code: "d"}, path, %{win_text: ""} = state) do
    case Troupe.dismiss(state.session_id, path) do
      :ok -> %{state | focus: :command}
      {:error, msg} -> notice(state, msg)
    end
  end

  defp window_key(%Key{code: "e"}, _path, %{win_text: ""} = state), do: toggle_expanded(state)

  # Shift-Enter inserts a newline; the box can hold multiline (typed or pasted)
  # input, folded to a `<pasted N lines>` marker in the title.
  defp window_key(%Key{code: "enter", modifiers: ["shift"]}, _path, state),
    do: %{state | win_text: state.win_text <> "\n"}

  defp window_key(%Key{code: "enter"}, path, %{win_text: text} = state) when text != "" do
    sid = state.session_id
    w = Map.fetch!(state.model.windows, path)

    cond do
      String.starts_with?(text, "/todo cancel ") ->
        Troupe.edit_todo(sid, path, {:cancel, String.trim_leading(text, "/todo cancel ")})

      String.starts_with?(text, "/todo add ") ->
        Troupe.edit_todo(sid, path, {:add, String.trim_leading(text, "/todo add ")})

      question = Enum.find(w.pending, &(&1.kind == :question)) ->
        Troupe.answer(sid, question.call_id, text)

      true ->
        Troupe.send_input(sid, path, text)
    end

    follow(%{state | win_text: ""})
  end

  defp window_key(%Key{code: code, modifiers: mods}, _path, state) when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: %{state | win_text: state.win_text <> code}, else: state
  end

  defp window_key(_key, _path, state), do: state

  ## Helpers

  defp activate(state, path, agent \\ nil) do
    model = %{state.model | windows: Map.update!(state.model.windows, path, &%{&1 | badge: false})}
    agent = if agent == path, do: nil, else: agent
    %{state | focus: {:window, path}, win_text: "", model: model, pane: fresh_pane(agent)}
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
    do: %{state | focus: :command, win_text: "", pane: fresh_pane()}

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
        %{state | pane: fresh_pane(if(next == path, do: nil, else: next))}
    end
  end

  defp notice(state, text),
    do: %{state | model: %{state.model | notices: Enum.take([text | state.model.notices], 3)}}

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
    receive do
      {:troupe_event, e} -> drain(apply_event(state, e), n - 1)
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
    workspace =
      case Enum.find(Log.all(sid), &(&1.type == :session_started)) do
        %{data: %{workspace: ws}} -> ws
        _ -> File.cwd!()
      end

    model = Model.rebuild(sid, workspace, Log.all(sid))
    %{model | watch: Watcher.status(sid)}
  end

  defp split_first(text) do
    case String.split(text, " ", parts: 2) do
      [name] -> {name, ""}
      [name, rest] -> {name, String.trim(rest)}
    end
  end

  @path_commands ~w(merge discard cancel dismiss)

  @doc """
  Tab completion on the command line: command names (`wor` → `worktree `), window paths
  for `/merge`, `/discard`, `/cancel`, `/dismiss` (repeated Tab cycles through the matches),
  and `@file` paths anywhere. `/merge` and `/discard` only offer worktree branches that
  have finished and are neither merged nor discarded.
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
            ~w(settings help observer models watch agents sessions memory quit)
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

    names =
      workspace
      |> Troupe.Session.Worktree.list()
      |> Enum.flat_map(&[&1.rel, &1.branch])
      |> Enum.reject(&is_nil/1)
      |> Enum.concat(Enum.map(Troupe.Session.Worktree.managed(workspace), &(&1 <> ":")))
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
