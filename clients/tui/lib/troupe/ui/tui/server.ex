defmodule Troupe.UI.TUI.Server do
  @moduledoc """
  The terminal UI: an `ExRatatui.App` subscribed to `Troupe.Events`. It never
  slows an agent down: deltas are coalesced and the screen redraws at most
  30 times per second; when the mailbox grows past a threshold the queued
  deltas are collapsed in one pass. After a restart it rebuilds every window
  from the session log.
  """

  use ExRatatui.App

  alias ExRatatui.Event.Key
  alias Troupe.Events
  alias Troupe.Session.{Dispatcher, Log, Watcher}
  alias Troupe.UI.TUI.{Model, View}

  @tick_ms 33
  @mailbox_threshold 200

  @type state :: %{
          session_id: String.t(),
          model: Model.t(),
          focus: :command | {:window, String.t()},
          cmd_text: String.t(),
          win_text: String.t(),
          commands: [String.t()],
          tick: non_neg_integer(),
          now: integer(),
          dirty: boolean(),
          tick_scheduled: boolean(),
          quit_armed: boolean(),
          expanded: boolean(),
          slow_render_ms: non_neg_integer(),
          on_quit: (-> any())
        }

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
      quitting: false,
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

    needs_blink = Enum.any?(Model.windows(state.model), &(&1.state in [:running, :needs_input]))

    if state.dirty or needs_blink do
      {:noreply, schedule_tick(%{state | dirty: false}, if(state.dirty, do: @tick_ms, else: 500)),
       render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  # Test seam: render synchronously regardless of dirtiness.
  def handle_info(:force_render, state),
    do: {:noreply, %{state | now: System.system_time(:millisecond), dirty: false}, render?: true}

  def handle_info(_msg, state), do: {:noreply, state, render?: false}

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

  def handle_event(%Key{} = key, %{focus: {:window, path}} = state),
    do: {:noreply, window_key(key, path, %{state | quit_armed: false})}

  def handle_event(_event, state), do: {:noreply, state, render?: false}

  ## Command line keys

  defp command_key(%Key{code: "esc"}, state), do: %{state | cmd_text: ""}

  defp command_key(%Key{code: "backspace"}, state),
    do: %{state | cmd_text: String.slice(state.cmd_text, 0..-2//1)}

  defp command_key(%Key{code: "tab"}, state),
    do: %{state | cmd_text: complete_file(state.cmd_text, state.model.workspace)}

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

    target = fn -> if args == "", do: active, else: args end

    result =
      case name do
        q when q in ["quit", "exit", "q"] ->
          :quit

        "" ->
          {:notice, "commands: " <> Enum.map_join(state.commands, " ", &("/" <> &1))}

        "watch" ->
          toggle_watch(sid, state.model.watch.enabled)

        "cancel" ->
          with_target(target.(), &Troupe.cancel(sid, &1))

        "dismiss" ->
          with_target(target.(), &Troupe.dismiss(sid, &1))

        "merge" ->
          with_target(target.(), &Troupe.merge(sid, &1))

        "discard" ->
          with_target(target.(), &Troupe.discard(sid, &1))

        "agents" ->
          {:notice, "agents: " <> Enum.map_join(state.commands, ", ", & &1)}

        "sessions" ->
          {:notice, "sessions: " <> Enum.map_join(Troupe.sessions(), ", ", & &1.session_id)}

        "resume" ->
          {:notice, "resume from the shell: troupe resume #{args}"}

        cmd ->
          Troupe.dispatch(sid, cmd, args)
      end

    state = %{state | cmd_text: ""}

    case result do
      :quit -> %{state | quitting: true}
      {:ok, _} -> state
      :ok -> state
      {:notice, text} -> notice(state, text)
      {:error, msg} when is_binary(msg) -> notice(state, msg)
      {:error, other} -> notice(state, inspect(other))
    end
  end

  defp toggle_watch(sid, true) do
    Watcher.disable(sid)
    {:notice, "watch mode off"}
  end

  defp toggle_watch(sid, false) do
    {:ok, backend} = Watcher.enable(sid)
    {:notice, "watch mode on (#{backend})"}
  end

  defp with_target(nil, _fun), do: {:error, "no window given; activate one or pass its path"}
  defp with_target(path, fun), do: fun.(path)

  ## Window keys

  defp window_key(%Key{code: "esc"}, _path, state), do: %{state | focus: :command, win_text: ""}

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
        state
    end
  end

  defp window_key(%Key{code: "x"}, path, %{win_text: ""} = state) do
    Troupe.cancel(state.session_id, path)
    state
  end

  defp window_key(%Key{code: "d"}, path, %{win_text: ""} = state) do
    case Troupe.dismiss(state.session_id, path) do
      :ok -> %{state | focus: :command}
      {:error, msg} -> notice(state, msg)
    end
  end

  defp window_key(%Key{code: "e"}, _path, %{win_text: ""} = state),
    do: %{state | expanded: not state.expanded}

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

    %{state | win_text: ""}
  end

  defp window_key(%Key{code: code, modifiers: mods}, _path, state) when mods in [[], ["shift"]] do
    if String.length(code) == 1, do: %{state | win_text: state.win_text <> code}, else: state
  end

  defp window_key(_key, _path, state), do: state

  ## Helpers

  defp activate(state, path) do
    model = %{state.model | windows: Map.update!(state.model.windows, path, &%{&1 | badge: false})}
    %{state | focus: {:window, path}, win_text: "", model: model}
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
      {:troupe_event, %{type: :llm_delta} = e} -> drain(apply_event(state, e), n - 1)
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
