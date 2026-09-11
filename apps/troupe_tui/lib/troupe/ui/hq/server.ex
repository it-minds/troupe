defmodule Troupe.UI.HQ.Server do
  @moduledoc """
  HQ: one screen for every session, and one inbox for everything waiting on a person.

  A `fleet` subscription plus one `session.list` at start-up is the whole data source.
  That is deliberate: HQ must show an approval raised in a session nobody has open,
  because that is the one that silently stalls for an hour, and a client that had to
  open a session to notice would never find it.

  Answering an approval here is the ordinary `approval.respond` command. First
  response wins; if someone else got there first the session says so with an
  `approval_resolved` event, which lands on this same subscription and takes the row
  off the list.
  """

  use ExRatatui.App

  alias ExRatatui.Event, as: Key
  alias Troupe.Protocol.{Client, Daemon}
  alias Troupe.UI.HQ.{State, View}

  @frame_ms 33

  @doc false
  def scene(state, frame), do: View.scene(state, frame)

  @impl ExRatatui.App
  def mount(opts) do
    with {:ok, client} <- connect(opts),
         {:ok, %{"sessions" => sessions}} <- Client.call(client, "session.list"),
         {:ok, _} <- Client.subscribe(client, "fleet") do
      schedule_frame()

      state =
        [client: client]
        |> State.new()
        |> State.put_sessions(sessions)
        |> seed_approvals(client, sessions)

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

  # A `fleet` subscription starts live, so an approval raised before HQ opened would
  # be invisible. The log already holds it, so the opening picture is folded from each
  # session's own history — the same events, read once.
  defp seed_approvals(state, client, sessions) do
    Enum.reduce(sessions, state, fn session, acc ->
      session_id = session["id"]

      case Client.call(client, "session.get", %{"session_id" => session_id}) do
        {:ok, %{"head_seq" => head}} when head > 0 -> replay(acc, client, session_id, head)
        _ -> acc
      end
    end)
  end

  defp replay(state, client, session_id, _head) do
    subscribe = Client.subscribe(client, "session:#{session_id}", level: :summary, from_seq: 0)

    case subscribe do
      {:ok, %{"subscription_id" => id}} ->
        state = drain_replay(state, session_id)
        Client.unsubscribe(client, id)
        state

      _ ->
        state
    end
  end

  # The replay arrives as ordinary event messages; this is the one place HQ reads them
  # synchronously, because the opening picture has to be complete before the first
  # frame rather than filling in as it draws.
  defp drain_replay(state, session_id) do
    receive do
      {:troupe_event, _topic, ^session_id, event} ->
        drain_replay(State.apply_event(state, session_id, event), session_id)
    after
      250 -> state
    end
  end

  @impl ExRatatui.App
  def render(state, frame), do: View.scene(state, frame)

  # -- input ------------------------------------------------------------------

  @impl ExRatatui.App
  def handle_event(%Key.Key{code: "c", modifiers: modifiers}, state) when is_list(modifiers) do
    if "ctrl" in modifiers, do: quit(state), else: {:noreply, state, render?: false}
  end

  def handle_event(%Key.Key{code: "q"}, state), do: quit(state)

  def handle_event(%Key.Key{code: "up"}, state) do
    {:noreply, State.move(state, -1), render?: true}
  end

  def handle_event(%Key.Key{code: "down"}, state) do
    {:noreply, State.move(state, 1), render?: true}
  end

  def handle_event(%Key.Key{code: code}, state) when code in ["y", "a", "n", "enter"] do
    decision = %{"y" => "allow", "enter" => "allow", "a" => "allow_session", "n" => "deny"}[code]
    {:noreply, respond(state, decision), render?: true}
  end

  def handle_event(%Key.Resize{}, state), do: {:noreply, State.mark_dirty(state), render?: true}
  def handle_event(_event, state), do: {:noreply, state, render?: false}

  # -- events -----------------------------------------------------------------

  @impl ExRatatui.App
  def handle_info({:troupe_event, _topic, session_id, event}, state) do
    state = State.apply_event(state, session_id, event)
    notify_test(state, event)
    {:noreply, state, render?: false}
  end

  def handle_info({:troupe_resync, _id, topic, _last_seq}, state) do
    Client.subscribe(state.client, topic)
    {:noreply, State.notice(state, "reconnected the fleet stream"), render?: true}
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

  def handle_info(_message, state), do: {:noreply, state, render?: false}

  @impl ExRatatui.App
  def terminate(_reason, state) do
    if owner = Map.get(state, :owner), do: send(owner, {:hq_exit, 0})
    :ok
  end

  # -- helpers ----------------------------------------------------------------

  defp respond(state, decision) do
    case State.selected_approval(state) do
      nil ->
        state

      approval ->
        Client.call(state.client, "approval.respond", %{
          "command_id" => Client.command_id(),
          "session_id" => approval.session_id,
          "call_id" => approval.call_id,
          "decision" => decision
        })

        # Removed here as well as on the event, so the row goes away on the keystroke
        # rather than a round trip later.
        state
        |> State.drop_approval(approval.session_id, approval.call_id)
        |> State.notice("#{decision} #{approval.tool} in #{approval.session_id}")
    end
  end

  defp schedule_frame, do: Process.send_after(self(), :frame, @frame_ms)

  defp quit(state) do
    if owner = Map.get(state, :owner), do: send(owner, {:hq_exit, 0})
    {:stop, state}
  end

  defp notify_test(%{test_pid: pid}, event) when is_pid(pid), do: send(pid, {:hq_event, event.type})
  defp notify_test(_state, _event), do: :ok
end
