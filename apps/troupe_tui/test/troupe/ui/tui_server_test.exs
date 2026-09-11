defmodule Troupe.UI.TUIServerTest do
  @moduledoc """
  The TUI as a live process against a real daemon, over a real socket.

  What is being checked here is the boundary, not the pixels. Three things:

  * a TUI crash never reaches the session, and the session was never in the TUI;
  * closing the TUI leaves the session running, which is the whole point of a daemon;
  * a flood of events never reaches the agent's turn latency, through the daemon's
    backpressure and the TUI's own drain.

  The TUI connects for itself and steers with commands. Nothing here gives it access
  a third-party client would not have.
  """

  use ExUnit.Case, async: false

  alias ExRatatui.Runtime
  alias Troupe.Gateway.Daemon
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Endpoint, Event}
  alias Troupe.UI.TUI.Server

  @moduletag timeout: 60_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-tui-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    state_dir = Path.join(base, "state")
    File.mkdir_p!(workspace)
    File.mkdir_p!(state_dir)

    previous = System.get_env("TROUPE_STATE_HOME")
    System.put_env("TROUPE_STATE_HOME", state_dir)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    on_exit(fn ->
      if previous, do: System.put_env("TROUPE_STATE_HOME", previous), else: System.delete_env("TROUPE_STATE_HOME")

      File.rm_rf!(base)
    end)

    %{endpoint: endpoint, workspace: workspace, state_dir: state_dir}
  end

  # The model is scripted through the core, the way the gateway's own tests do it:
  # scripting a model is test scaffolding, not something a client may ask for.
  defp start_session(context, opts) do
    fake =
      start_supervised!({Fake, Keyword.take(opts, [:steps, :delay_ms])},
        id: {Fake, System.unique_integer([:positive])}
      )

    overrides =
      [provider: "fake", model: "fake", state_dir: context.state_dir, auto_approve: true]
      |> Keyword.merge(Keyword.get(opts, :config_overrides, []))

    {:ok, session} =
      Troupe.start_session(workspace: context.workspace, fake: fake, config_overrides: overrides)

    on_exit(fn -> Troupe.stop_session(session.id) end)
    %{session: session, fake: fake}
  end

  defp start_tui(context, session, opts \\ []) do
    start_supervised!(
      {Server,
       [
         session_id: session.id,
         connect: [endpoint: context.endpoint, spawn: false],
         name: nil,
         test_mode: {120, 32},
         test_pid: self()
       ] ++ opts},
      id: {Server, System.unique_integer([:positive])}
    )
  end

  describe "crash isolation" do
    test "killing the TUI mid-stream leaves the session running and the model uncalled again",
         context do
      %{session: session, fake: fake} =
        start_session(context,
          delay_ms: 40,
          steps: [
            {:tools, [{"todo_read", %{}}]},
            {:text, "a long answer that streams in several chunks so a kill lands mid-stream"},
            {:text, "still here"}
          ]
        )

      tui = start_tui(context, session)
      Troupe.send_input(session.id, "say something long")

      assert_receive {:tui_event, "llm_delta"}, 10_000

      ref = Process.monitor(tui)
      Process.exit(tui, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tui, :killed}, 5_000

      await_idle(session.id)

      # The script has two turns: one tool call, one answer. A TUI dying mid-stream
      # must not cause a retry, so the count is exactly what the script implies.
      assert Fake.call_count(fake) == 2
      assert events_of_type(session.id, "llm_error") == []

      # A fresh TUI rebuilds the same screen by replaying from seq 0, not from memory.
      restarted = start_tui(context, session)
      state = tui_state(restarted)

      assert Enum.any?(state.transcript, &match?({:user, "say something long", _}, &1))

      assert Enum.any?(state.transcript, fn
               {:assistant, text} -> text =~ "a long answer"
               _ -> false
             end)
    end

    test "quitting the TUI leaves the session alive in the daemon", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}, {:text, "hi"}])
      tui = start_tui(context, session, owner: self())

      ref = Process.monitor(tui)
      ctrl_c(tui)
      ctrl_c(tui)
      assert_receive {:tui_exit, 0}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^tui, _}, 5_000

      # The session is still there, still active, still able to take work.
      assert %{state: :active} = Troupe.get_session(session.id)
      Troupe.send_input(session.id, "still listening?")
      await_idle(session.id)
      assert Enum.any?(Troupe.events(session.id), &(&1.type == "user_input"))
    end
  end

  describe "backpressure" do
    test "flooding 10k deltas neither slows the agent nor grows the TUI mailbox", context do
      %{session: session} = start_session(context, steps: [{:text, "ok"}, {:text, "ok"}])

      tui = start_tui(context, session)

      # Time a turn with the TUI idle, as a baseline.
      baseline = time_turn(session)

      # Now flood from outside the session, while a turn runs. Unlinked: killing a
      # linked flooder would take the test process with it.
      flood = spawn(fn -> flood_deltas(session.id, 10_000) end)
      flooded = time_turn(session)
      Process.exit(flood, :kill)

      {:message_queue_len, queued} = Process.info(tui, :message_queue_len)

      assert Process.alive?(tui)

      # The mailbox stays bounded: the daemon coalesces and drops ephemerals rather
      # than queueing them, and the server drains what does arrive in one pass.
      assert queued < 2_000, "TUI mailbox grew to #{queued}"

      # The agent's turn latency is unchanged: it never waits on a subscriber.
      assert flooded < max(baseline * 8, 500),
             "turn took #{flooded}ms under flood vs #{baseline}ms idle"
    end
  end

  describe "keys and commands" do
    test "typing and Enter sends input, and Tab switches profile", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}, {:text, "hi"}])
      tui = start_tui(context, session)

      type(tui, "hello")
      assert tui_state(tui).input == "hello"

      key(tui, "backspace")
      assert tui_state(tui).input == "hell"

      key(tui, "enter")
      assert tui_state(tui).input == ""

      assert await_event(session.id, "user_input").data["text"] == "hell"

      key(tui, "tab")
      assert await_event(session.id, "profile_switched").data["to"] == "plan"
    end

    test "Esc cancels a turn that is in flight", context do
      # A slow model call, so Esc lands while the agent is still thinking; cancelling
      # an idle agent is a no-op by design and would prove nothing.
      %{session: session} =
        start_session(context, delay_ms: 800, steps: [{:text, "a slow answer"}])

      tui = start_tui(context, session)

      type(tui, "take your time")
      key(tui, "enter")
      await_event(session.id, "llm_request")

      key(tui, "esc")
      await_event(session.id, "cancelled")

      await_idle(session.id)
      assert Troupe.snapshot(session.id).state == :idle
    end

    test "Ctrl-C once arms, twice quits", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      tui = start_tui(context, session, owner: self())

      ctrl_c(tui)
      assert tui_state(tui).quit_armed?

      ref = Process.monitor(tui)
      ctrl_c(tui)

      assert_receive {:tui_exit, 0}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^tui, _}, 5_000
    end

    test "an approval is answered from the keyboard", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "hi"}}]}, {:text, "done"}]
        )

      tui = start_tui(context, session)

      Troupe.send_input(session.id, "ask me")
      assert_receive {:tui_event, "approval_requested"}, 10_000

      assert [_pending] = tui_state(tui).approvals

      key(tui, "y")
      await_idle(session.id)

      [completed] = events_of_type(session.id, "tool_call_completed")
      assert completed.data["ok"]
      assert tui_state(tui).approvals == []
    end

    test "/help and an unknown command both land as notices", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      tui = start_tui(context, session)

      type(tui, "/help")
      key(tui, "enter")
      assert Enum.any?(tui_state(tui).transcript, &match?({:notice, "commands: " <> _}, &1))

      type(tui, "/nope")
      key(tui, "enter")
      assert Enum.any?(tui_state(tui).transcript, &match?({:notice, "unknown command" <> _}, &1))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp type(tui, text) do
    text |> String.graphemes() |> Enum.each(&key(tui, &1))
  end

  defp key(tui, code) do
    Runtime.inject_event(tui, %ExRatatui.Event.Key{code: code, kind: "press"})
  end

  defp ctrl_c(tui) do
    Runtime.inject_event(tui, %ExRatatui.Event.Key{
      code: "c",
      modifiers: ["ctrl"],
      kind: "press"
    })
  end

  # `:sys.get_state/1` returns after every prior message has been handled, which is
  # what makes this a synchronisation point rather than a guess.
  defp tui_state(tui), do: :sys.get_state(tui).user_state

  defp time_turn(session) do
    started = System.monotonic_time(:millisecond)
    Troupe.send_input(session.id, "go")
    await_idle(session.id)
    System.monotonic_time(:millisecond) - started
  end

  defp flood_deltas(session_id, count) do
    Enum.each(1..count, fn _ ->
      Troupe.Events.publish_ephemeral(session_id, "llm_delta", ["root"], %{
        "kind" => "text",
        "text" => "x"
      })
    end)
  end

  defp events_of_type(session_id, type) do
    session_id |> Troupe.events() |> Enum.filter(&(&1.type == type))
  end

  defp await_event(session_id, type, attempts \\ 400) do
    case Enum.find(Troupe.events(session_id), &(&1.type == type)) do
      %Event{} = event ->
        event

      nil when attempts > 0 ->
        Process.sleep(25)
        await_event(session_id, type, attempts - 1)

      nil ->
        raise "timed out waiting for a #{type} event in #{session_id}"
    end
  end

  defp await_idle(session_id, attempts \\ 600) do
    case Troupe.snapshot(session_id) do
      %{state: state} when state in [:idle, :done] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        await_idle(session_id, attempts - 1)

      _ ->
        :ok
    end
  end
end
