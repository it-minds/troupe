defmodule Troupe.UI.TUI.Server do
  @moduledoc """
  The terminal UI: an `ExRatatui.App` holding one `Troupe.Protocol.Client`.

  Three properties matter as much as what it draws.

  **It has no private access.** Everything on the screen arrived as a protocol event,
  and every key that changes something sends a command. There is no call into a
  session from here, and `mix troupe.boundaries` makes sure there never is.

  **It can never slow an agent down.** Events arrive by `send/2` from the client
  process; nothing in a session ever waits on this one. Rendering is capped at 30
  frames per second, and when the mailbox passes a threshold the whole backlog is
  drained and collapsed in one pass rather than handled message by message — a flood
  of deltas costs one fold, not one render each.

  **It owns no session state.** The transcript is a fold over the event stream, so a
  crash costs nothing: `mount/1` subscribes from `seq` 0 and the screen comes back
  while the session carries on untouched.
  """

  use ExRatatui.App

  alias ExRatatui.Event, as: Key
  alias Troupe.Protocol.{Client, Daemon}
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

    with {:ok, client} <- connect(opts),
         {:ok, session} <- Client.call(client, "session.get", %{"session_id" => session_id}),
         {:ok, _} <- Client.subscribe(client, "session:" <> session_id, from_seq: 0) do
      state =
        session_id
        |> State.new(session["workspace"], client: client, watch: Keyword.get(opts, :watch, false))

      schedule_frame()

      {:ok,
       state
       |> Map.put(:owner, Keyword.get(opts, :owner))
       |> Map.put(:test_pid, Keyword.get(opts, :test_pid))}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp connect(opts) do
    case Keyword.get(opts, :client) do
      nil -> Daemon.connect(Keyword.get(opts, :connect, []))
      client -> {:ok, client}
    end
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.scene(state, frame)

  # -- input ------------------------------------------------------------------

  @impl ExRatatui.App
  def handle_event(%Key.Key{code: "c", modifiers: modifiers} = event, state)
      when is_list(modifiers) do
    if "ctrl" in modifiers do
      if state.quit_armed?, do: quit(state), else: {:noreply, arm_quit(state), render?: true}
    else
      handle_text_key(event, state)
    end
  end

  def handle_event(%Key.Key{code: "esc"}, state) do
    command(state, "turn.cancel", %{})
    {:noreply, disarm(state)}
  end

  def handle_event(%Key.Key{code: "tab"}, state) do
    next = if state.profile == "plan", do: "build", else: "plan"
    command(state, "profile.switch", %{"profile" => next})
    {:noreply, disarm(state)}
  end

  def handle_event(%Key.Key{code: "enter"}, %{approvals: [approval | _]} = state) do
    decide(state, approval, "allow")
  end

  def handle_event(%Key.Key{code: code}, %{approvals: [approval | _]} = state)
      when code in ["y", "a", "n"] do
    decide(state, approval, %{"y" => "allow", "a" => "allow_session", "n" => "deny"}[code])
  end

  def handle_event(%Key.Key{code: "enter"}, state) do
    {:noreply, submit(disarm(state)), render?: true}
  end

  def handle_event(%Key.Key{code: "backspace"}, state) do
    {:noreply, %{disarm(state) | input: String.slice(state.input, 0..-2//1)}, render?: true}
  end

  def handle_event(%Key.Key{code: "up"}, state) do
    {:noreply, move_selection(disarm(state), -1), render?: true}
  end

  def handle_event(%Key.Key{code: "down"}, state) do
    {:noreply, move_selection(disarm(state), 1), render?: true}
  end

  def handle_event(%Key.Key{code: "page_up"}, state) do
    {:noreply, %{disarm(state) | follow?: false, scroll: max(state.scroll - 10, 0)}, render?: true}
  end

  def handle_event(%Key.Key{code: "page_down"}, state) do
    {:noreply, %{disarm(state) | scroll: state.scroll + 10, follow?: false}, render?: true}
  end

  def handle_event(%Key.Key{code: "end"}, state) do
    {:noreply, %{disarm(state) | follow?: true, scroll: 0}, render?: true}
  end

  def handle_event(%Key.Key{code: "f5"}, state) do
    {:noreply, State.focus(state, state.focus), render?: true}
  end

  def handle_event(%Key.Key{} = event, state), do: handle_text_key(event, state)

  def handle_event(%Key.Paste{content: content}, state) do
    {:noreply, %{disarm(state) | input: state.input <> content}, render?: true}
  end

  def handle_event(%Key.Resize{}, state), do: {:noreply, State.mark_dirty(state), render?: true}

  # Unmatched events must never crash the app; ExRatatui's own guidance, and the same
  # rule the agent follows for unknown messages.
  def handle_event(_event, state), do: {:noreply, state, render?: false}

  defp handle_text_key(%Key.Key{code: code}, state) when byte_size(code) <= 4 do
    if printable?(code) do
      {:noreply, %{disarm(state) | input: state.input <> code}, render?: true}
    else
      {:noreply, state, render?: false}
    end
  end

  defp handle_text_key(_event, state), do: {:noreply, state, render?: false}

  # Key codes for character keys are the character itself; named keys ("enter",
  # "f1") are longer words that must not be typed into the input.
  defp printable?(code), do: String.length(code) == 1 and String.printable?(code)

  # -- session events ---------------------------------------------------------

  @impl ExRatatui.App
  def handle_info({:troupe_event, _topic, _session_id, event}, state) do
    state = State.apply_event(state, event)

    # One `receive` pass over whatever else is already queued. Under a flood this
    # turns thousands of pending deltas into a single fold and a single frame, which
    # is what keeps the mailbox bounded without ever blocking the publisher.
    state = if mailbox_len() > @mailbox_threshold, do: drain(state, @drain_limit), else: state

    notify_test(state, event)
    {:noreply, state, render?: false}
  end

  # The daemon gave up on this subscription because we fell too far behind on
  # *durable* events. Re-subscribing from the last seq we actually folded is the
  # whole recovery, and it is why the last seq is tracked rather than the last one
  # that arrived.
  def handle_info({:troupe_resync, _id, topic, _last_seq}, state) do
    Client.subscribe(state.client, topic, from_seq: state.last_seq)
    {:noreply, State.notice(state, "reconnected the event stream"), render?: true}
  end

  def handle_info({:troupe_disconnected, reason}, state) do
    {:noreply, State.notice(state, "lost the daemon: #{inspect(reason)}"), render?: true}
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
      {:troupe_event, _t, _s, event} -> drain(State.apply_event(state, event), budget - 1)
    after
      0 -> state
    end
  end

  # Every command carries a fresh `command_id`: this is a first attempt, never a
  # retry, and reusing one would make a second keystroke a no-op.
  defp command(state, method, params) do
    Client.call(
      state.client,
      method,
      Map.merge(params, %{
        "command_id" => Client.command_id(),
        "session_id" => state.session_id
      })
    )
  end

  defp submit(%{input: ""} = state), do: state

  defp submit(%{input: input} = state) do
    state = %{state | input: "", follow?: true, scroll: 0}

    cond do
      String.starts_with?(input, "/") -> slash(state, input)
      String.starts_with?(input, "@") -> address_agent(state, input)
      true -> send_input(state, input)
    end
  end

  defp send_input(state, text) do
    command(state, "input.send", %{"text" => text})
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
        State.notice(state, "usage: @agent then what you want it to do")
    end
  end

  defp slash(state, input) do
    trimmed = String.trim(input)

    case Map.fetch(slash_commands(), trimmed) do
      {:ok, handler} -> handler.(state)
      :error -> State.notice(state, "unknown command #{trimmed} — try /help")
    end
  end

  defp slash_commands do
    %{
      "/plan" => &switch_to(&1, "plan"),
      "/build" => &switch_to(&1, "build"),
      "/cancel" => &cancel_turn/1,
      "/watch" => &toggle_watch/1,
      "/agents" => &State.notice(&1, agents_help(&1)),
      "/sessions" => &sessions_help/1,
      "/resume" => &State.notice(&1, "resume from the shell: troupe resume <session-id>"),
      "/help" => &State.notice(&1, "commands: " <> Enum.join(@commands, " ")),
      "/quit" => &detach/1
    }
  end

  defp switch_to(state, profile) do
    command(state, "profile.switch", %{"profile" => profile})
    state
  end

  defp cancel_turn(state) do
    command(state, "turn.cancel", %{})
    state
  end

  defp toggle_watch(state) do
    params = %{
      "command_id" => Client.command_id(),
      "workspace" => state.workspace,
      "enabled" => not state.watch?
    }

    case Client.call(state.client, "watch.set", params) do
      {:ok, %{"backend" => backend, "enabled" => enabled}} ->
        State.notice(%{state | watch?: enabled and backend != "off"}, "watch: #{backend}")

      {:error, error} ->
        State.notice(state, "watch: #{error.message}")
    end
  end

  # Closing the view no longer ends the session — that is the point of the daemon.
  defp detach(state) do
    if owner = Map.get(state, :owner), do: send(owner, {:tui_exit, 0})
    state
  end

  defp agents_help(state) do
    case State.agent_rows(state) do
      [] -> "no agents running"
      rows -> "live agents: " <> Enum.map_join(rows, ", ", fn {path, _} -> Enum.join(path, "/") end)
    end
  end

  defp sessions_help(state) do
    params = %{"filter" => %{"workspace" => state.workspace}}

    case Client.call(state.client, "session.list", params) do
      {:ok, %{"sessions" => []}} ->
        State.notice(state, "no sessions recorded for this workspace")

      {:ok, %{"sessions" => sessions}} ->
        ids = sessions |> Enum.take(5) |> Enum.map_join(", ", & &1["id"])
        State.notice(state, "sessions: " <> ids)

      {:error, error} ->
        State.notice(state, "sessions: #{error.message}")
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
      State.focus(%{state | selected_agent: index}, path)
    end
  end

  defp decide(state, approval, decision) do
    command(state, "approval.respond", %{
      "call_id" => approval.call_id,
      "decision" => decision
    })

    # Removed locally as well as on the `approval_decided` event: the popup should
    # close on the keystroke, not a round trip later.
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

  defp notify_test(%{test_pid: pid}, event) when is_pid(pid), do: send(pid, {:tui_event, event.type})
  defp notify_test(_state, _event), do: :ok
end
