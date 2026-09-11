defmodule Troupe.UI.TUI.Server do
  @moduledoc """
  The terminal UI: an `ExRatatui.App` subscribed to `Troupe.Events`.

  Two properties matter as much as what it draws.

  **It can never slow an agent down.** Events arrive by `send/2` from
  `Troupe.Events`; nothing in a session ever waits on this process. Rendering is
  capped at 30 frames per second, and when the mailbox passes a threshold the whole
  backlog is drained and collapsed in one pass rather than handled message by
  message — a flood of deltas costs one fold, not one render each.

  **It owns no session state.** The transcript is a projection of the event log, so a
  crash costs nothing: the supervisor restarts it, `mount/1` replays the log, and the
  screen comes back while the session carries on untouched.
  """

  use ExRatatui.App

  alias ExRatatui.Event
  alias Troupe.Session.Approvals
  alias Troupe.UI.TUI.{State, View}

  @frame_ms 33
  @mailbox_threshold 64
  @drain_limit 5_000

  @commands ~w(/plan /build /watch /cancel /agents /sessions /resume /help /quit)

  @doc false
  def scene(state, frame), do: View.scene(state, frame)

  @impl ExRatatui.App
  def mount(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)

    Troupe.Events.subscribe(session_id)

    state =
      session_id
      |> State.new(workspace, watch: Keyword.get(opts, :watch, false))
      |> rebuild_from_log()

    schedule_frame()

    {:ok,
     state
     |> Map.put(:owner, Keyword.get(opts, :owner))
     |> Map.put(:test_pid, Keyword.get(opts, :test_pid))}
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.scene(state, frame)

  # -- input ------------------------------------------------------------------

  @impl ExRatatui.App
  def handle_event(%Event.Key{code: "c", modifiers: modifiers} = event, state)
      when is_list(modifiers) do
    if "ctrl" in modifiers do
      if state.quit_armed?, do: quit(state), else: {:noreply, arm_quit(state), render?: true}
    else
      handle_text_key(event, state)
    end
  end

  def handle_event(%Event.Key{code: "esc"}, state) do
    Troupe.cancel(state.session_id)
    {:noreply, disarm(state)}
  end

  def handle_event(%Event.Key{code: "tab"}, state) do
    next = if state.profile == "plan", do: "build", else: "plan"
    Troupe.switch_profile(state.session_id, next)
    {:noreply, disarm(state)}
  end

  def handle_event(%Event.Key{code: "enter"}, %{approvals: [approval | _]} = state) do
    decide(state, approval, :allow)
  end

  def handle_event(%Event.Key{code: code}, %{approvals: [approval | _]} = state)
      when code in ["y", "a", "n"] do
    decision = %{"y" => :allow, "a" => :allow_session, "n" => :deny}[code]
    decide(state, approval, decision)
  end

  def handle_event(%Event.Key{code: "enter"}, state) do
    {:noreply, submit(disarm(state)), render?: true}
  end

  def handle_event(%Event.Key{code: "backspace"}, state) do
    {:noreply, %{disarm(state) | input: String.slice(state.input, 0..-2//1)}, render?: true}
  end

  def handle_event(%Event.Key{code: "up"}, state) do
    {:noreply, move_selection(disarm(state), -1), render?: true}
  end

  def handle_event(%Event.Key{code: "down"}, state) do
    {:noreply, move_selection(disarm(state), 1), render?: true}
  end

  def handle_event(%Event.Key{code: "page_up"}, state) do
    {:noreply, %{disarm(state) | follow?: false, scroll: max(state.scroll - 10, 0)},
     render?: true}
  end

  def handle_event(%Event.Key{code: "page_down"}, state) do
    scrolled = state.scroll + 10
    {:noreply, %{disarm(state) | scroll: scrolled, follow?: false}, render?: true}
  end

  def handle_event(%Event.Key{code: "end"}, state) do
    {:noreply, %{disarm(state) | follow?: true, scroll: 0}, render?: true}
  end

  def handle_event(%Event.Key{code: "f5"}, state) do
    {:noreply, rebuild_from_log(state), render?: true}
  end

  def handle_event(%Event.Key{} = event, state), do: handle_text_key(event, state)

  def handle_event(%Event.Paste{content: content}, state) do
    {:noreply, %{disarm(state) | input: state.input <> content}, render?: true}
  end

  def handle_event(%Event.Resize{}, state), do: {:noreply, State.mark_dirty(state), render?: true}

  # Unmatched events must never crash the app; ExRatatui's own guidance, and the same
  # rule the agent follows for unknown messages.
  def handle_event(_event, state), do: {:noreply, state, render?: false}

  defp handle_text_key(%Event.Key{code: code}, state) when byte_size(code) <= 4 do
    if printable?(code) do
      {:noreply, %{disarm(state) | input: state.input <> code}, render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  defp handle_text_key(_event, state), do: {:noreply, state, render?: false}

  # Key codes for character keys are the character itself; named keys ("enter",
  # "f1") are longer words that must not be typed into the input.
  defp printable?(code) do
    String.length(code) == 1 and String.printable?(code)
  end

  # -- session events ---------------------------------------------------------

  @impl ExRatatui.App
  def handle_info({:troupe_event, _session_id, event}, state) do
    state = State.apply_event(state, event)

    # One `receive` pass over whatever else is already queued. Under a flood this
    # turns thousands of pending deltas into a single fold and a single frame, which
    # is what keeps the mailbox bounded without ever blocking the publisher.
    state = if mailbox_len() > @mailbox_threshold, do: drain(state, @drain_limit), else: state

    notify_test(state, event)
    {:noreply, state, render?: false}
  end

  def handle_info(:frame, state) do
    schedule_frame()

    if state.dirty? do
      {:noreply, State.mark_clean(state), render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  def handle_info(:disarm_quit, state),
    do: {:noreply, %{state | quit_armed?: false}, render?: true}

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  @impl ExRatatui.App
  def terminate(_reason, state) do
    if owner = Map.get(state, :owner), do: send(owner, {:tui_exit, 0})
    :ok
  end

  # -- helpers ----------------------------------------------------------------

  defp schedule_frame, do: Process.send_after(self(), :frame, @frame_ms)

  defp mailbox_len do
    {:message_queue_len, len} = Process.info(self(), :message_queue_len)
    len
  end

  defp drain(state, 0), do: state

  defp drain(state, budget) do
    receive do
      {:troupe_event, _session_id, event} -> drain(State.apply_event(state, event), budget - 1)
    after
      0 -> state
    end
  end

  defp rebuild_from_log(state) do
    events = Troupe.events(state.session_id)

    state
    |> Map.put(:transcript, [])
    |> State.rebuild(events)
    |> State.mark_dirty()
  end

  defp submit(%{input: ""} = state), do: state

  defp submit(%{input: input} = state) do
    state = %{state | input: "", follow?: true, scroll: 0}

    cond do
      String.starts_with?(input, "/") -> command(state, input)
      String.starts_with?(input, "@") -> address_agent(state, input)
      true -> send_input(state, input)
    end
  end

  defp send_input(state, text) do
    Troupe.send_input(state.session_id, text)
    State.mark_dirty(state)
  end

  # `@explore find where auth lives` spawns that subagent under the root and lands
  # its result in the root transcript, which is what the delegate tool already does —
  # so this is phrased as an instruction rather than a second spawning path.
  defp address_agent(state, input) do
    case String.split(input, " ", parts: 2) do
      ["@" <> agent, task] when task != "" ->
        send_input(
          state,
          "Delegate this to the #{agent} subagent, in one delegate call, and report " <>
            "what it says:\n\n#{task}"
        )

      _ ->
        State.apply_event(state, %{
          type: :watch_notice,
          agent_path: state.focus,
          data: %{message: "usage: @agent then what you want it to do"}
        })
    end
  end

  defp command(state, input) do
    trimmed = String.trim(input)

    case Map.fetch(command_handlers(), trimmed) do
      {:ok, handler} -> handler.(state)
      :error -> notice(state, "unknown command #{trimmed} — try /help")
    end
  end

  defp command_handlers do
    %{
      "/plan" => &switch_to(&1, "plan"),
      "/build" => &switch_to(&1, "build"),
      "/cancel" => &cancel_turn/1,
      "/watch" => &toggle_watch/1,
      "/agents" => &notice(&1, agents_help(&1)),
      "/sessions" => &notice(&1, sessions_help(&1)),
      "/resume" => &notice(&1, "resume from the shell: troupe resume <session-id>"),
      "/help" => &notice(&1, "commands: " <> Enum.join(@commands, " ")),
      "/quit" => &stop_session/1
    }
  end

  defp switch_to(state, profile) do
    Troupe.switch_profile(state.session_id, profile)
    state
  end

  defp cancel_turn(state) do
    Troupe.cancel(state.session_id)
    state
  end

  defp toggle_watch(state) do
    {:ok, backend} = Troupe.watch(state.session_id, not state.watch?)
    notice(%{state | watch?: backend != :off}, "watch: #{backend}")
  end

  defp stop_session(state) do
    Troupe.stop_session(state.session_id)
    state
  end

  defp notice(state, message) do
    State.apply_event(state, %{
      type: :watch_notice,
      agent_path: state.focus,
      data: %{message: message}
    })
  end

  defp agents_help(state) do
    state.session_id
    |> Troupe.agent_tree()
    |> Enum.map_join(", ", &Enum.join(&1, "/"))
    |> case do
      "" -> "no agents running"
      list -> "live agents: " <> list
    end
  end

  defp sessions_help(state) do
    case Troupe.list_sessions(state.workspace.root_real) do
      [] -> "no sessions recorded for this workspace"
      sessions -> "sessions: " <> Enum.map_join(Enum.take(sessions, 5), ", ", & &1.id)
    end
  end

  # Enter on an agent row opens that subagent's transcript; the selection moves with
  # the arrow keys when there is a tree to move through.
  defp move_selection(state, delta) do
    rows = State.agent_rows(state)

    if rows == [] do
      state
    else
      index = state.selected_agent + delta
      index = index |> max(0) |> min(length(rows) - 1)
      {path, _agent} = Enum.at(rows, index)
      %{state | selected_agent: index} |> State.focus(path) |> rebuild_from_log()
    end
  end

  defp decide(state, approval, decision) do
    Approvals.decide(state.session_id, approval.call_id, decision)
    approvals = Enum.reject(state.approvals, &(&1.call_id == approval.call_id))
    {:noreply, %{disarm(state) | approvals: approvals}, render?: true}
  end

  defp arm_quit(state) do
    Process.send_after(self(), :disarm_quit, 2_000)
    %{state | quit_armed?: true}
  end

  defp disarm(state), do: %{state | quit_armed?: false}

  defp quit(state) do
    if owner = Map.get(state, :owner), do: send(owner, {:tui_exit, 0})
    {:stop, state}
  end

  defp notify_test(%{test_pid: pid}, event) when is_pid(pid) do
    send(pid, {:tui_event, event.type})
  end

  defp notify_test(_state, _event), do: :ok
end
