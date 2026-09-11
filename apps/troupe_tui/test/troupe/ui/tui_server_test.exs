defmodule Troupe.UI.TUIServerTest do
  @moduledoc """
  The TUI as a live process against a real session.

  What is being checked here is the boundary, not the pixels: a TUI crash must not
  reach the session, and a flood of deltas must not reach the agent's turn latency.
  """

  use Troupe.SessionCase, async: true

  alias ExRatatui.Runtime
  alias Troupe.UI.TUI.Server

  defp start_tui(session, opts \\ []) do
    start_supervised!(
      {Server,
       [
         session_id: session.id,
         workspace: session.workspace,
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

      Troupe.subscribe(session.id)
      tui = start_tui(session)

      Troupe.send_input(session.id, "say something long")

      # Kill the TUI while the model is streaming.
      assert_receive {:tui_event, :llm_delta}, 5_000

      ref = Process.monitor(tui)
      Process.exit(tui, :kill)
      assert_receive {:DOWN, ^ref, :process, ^tui, :killed}, 2_000

      await_state(session.id, [:idle], 10_000)

      # The script has two turns: one tool call, one answer. A TUI dying mid-stream
      # must not cause a retry, so the count is exactly what the script implies.
      assert Fake.call_count(fake) == 2
      assert events_of_type(session.id, "llm_error") == []
      assert Process.alive?(Registry.agent_pid(session.id, ["root"]))

      # A fresh TUI rebuilds the same screen from the log, not from memory.
      restarted = start_tui(session)
      state = tui_state(restarted)

      assert Enum.any?(state.transcript, &match?({:user, "say something long", _}, &1))

      assert Enum.any?(state.transcript, fn
               {:assistant, text} -> text =~ "a long answer"
               _ -> false
             end)
    end
  end

  describe "backpressure" do
    test "flooding 10k deltas neither slows the agent nor grows the TUI mailbox", context do
      %{session: session} = start_session(context, steps: [{:text, "ok"}, {:text, "ok"}])

      Troupe.subscribe(session.id)
      tui = start_tui(session)

      # Time a turn with the TUI idle, as a baseline.
      baseline = time_turn(session)

      # Now flood the TUI with deltas from outside the session, while a turn runs.
      # Unlinked: killing a linked flooder would take the test process with it.
      flood = spawn(fn -> flood_deltas(session.id, 10_000) end)
      flooded = time_turn(session)
      Process.exit(flood, :kill)

      {:message_queue_len, queued} = Process.info(tui, :message_queue_len)

      assert Process.alive?(tui)

      # The mailbox stays bounded because the server drains and collapses the backlog
      # in one pass rather than rendering per message.
      assert queued < 2_000, "TUI mailbox grew to #{queued}"

      # The agent's turn latency is unchanged: it never waits on a subscriber.
      assert flooded < max(baseline * 8, 500),
             "turn took #{flooded}ms under flood vs #{baseline}ms idle"
    end
  end

  describe "keys and commands" do
    test "typing and Enter sends input, and Tab switches profile", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}, {:text, "hi"}])

      Troupe.subscribe(session.id)
      tui = start_tui(session)

      type(tui, "hello")
      assert tui_state(tui).input == "hello"

      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "backspace", kind: "press"})
      assert tui_state(tui).input == "hell"

      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "enter", kind: "press"})
      assert tui_state(tui).input == ""

      event = await_event(session.id, :user_input)
      assert event.data["text"] == "hell"

      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "tab", kind: "press"})
      switched = await_event(session.id, :profile_switched, 5_000)
      assert switched.data["to"] == "plan"
    end

    test "Esc cancels a turn that is in flight", context do
      # A slow model call, so Esc lands while the agent is still :thinking; cancelling
      # an idle agent is a no-op by design and would prove nothing.
      %{session: session} =
        start_session(context, delay_ms: 800, steps: [{:text, "a slow answer"}])

      Troupe.subscribe(session.id)
      tui = start_tui(session)

      type(tui, "take your time")
      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "enter", kind: "press"})
      await_event(session.id, :llm_request, 5_000)

      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "esc", kind: "press"})
      await_event(session.id, :cancelled, 5_000)

      assert Troupe.snapshot(session.id).state == :idle
    end

    test "Ctrl-C once arms, twice quits", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      tui = start_tui(session, owner: self())

      Runtime.inject_event(tui, %ExRatatui.Event.Key{
        code: "c",
        modifiers: ["ctrl"],
        kind: "press"
      })

      assert tui_state(tui).quit_armed?

      ref = Process.monitor(tui)

      Runtime.inject_event(tui, %ExRatatui.Event.Key{
        code: "c",
        modifiers: ["ctrl"],
        kind: "press"
      })

      assert_receive {:tui_exit, 0}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^tui, _}, 2_000
    end

    test "an approval is answered from the keyboard", context do
      %{session: session} =
        start_session(context,
          config_overrides: [auto_approve: false],
          steps: [{:tools, [{"needs_approval", %{"note" => "hi"}}]}, {:text, "done"}]
        )

      Troupe.subscribe(session.id)
      tui = start_tui(session)

      Troupe.send_input(session.id, "ask me")
      assert_receive {:tui_event, :approval_requested}, 5_000

      assert [_pending] = tui_state(tui).approvals

      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "y", kind: "press"})
      await_state(session.id, [:idle], 10_000)

      [completed] = events_of_type(session.id, "tool_call_completed")
      assert completed["data"]["ok"]
      assert tui_state(tui).approvals == []
    end

    test "/help and an unknown command both land as notices", context do
      %{session: session} = start_session(context, steps: [{:text, "hi"}])
      tui = start_tui(session)

      type(tui, "/help")
      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "enter", kind: "press"})
      assert Enum.any?(tui_state(tui).transcript, &match?({:notice, "commands: " <> _}, &1))

      type(tui, "/nope")
      Runtime.inject_event(tui, %ExRatatui.Event.Key{code: "enter", kind: "press"})
      assert Enum.any?(tui_state(tui).transcript, &match?({:notice, "unknown command" <> _}, &1))
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp type(tui, text) do
    text
    |> String.graphemes()
    |> Enum.each(&Runtime.inject_event(tui, %ExRatatui.Event.Key{code: &1, kind: "press"}))
  end

  # `:sys.get_state/1` returns after every prior message has been handled, which is
  # what makes this a synchronisation point rather than a guess.
  defp tui_state(tui), do: :sys.get_state(tui).user_state

  defp time_turn(session) do
    started = System.monotonic_time(:millisecond)
    Troupe.send_input(session.id, "go")
    await_state(session.id, [:idle], 15_000)
    System.monotonic_time(:millisecond) - started
  end

  defp flood_deltas(session_id, count) do
    delta = %Troupe.LLM.Delta{kind: :text, text: "x"}

    Enum.each(1..count, fn _ ->
      Troupe.Events.publish(session_id, %{
        type: :llm_delta,
        agent_path: ["root"],
        data: delta
      })
    end)
  end
end
