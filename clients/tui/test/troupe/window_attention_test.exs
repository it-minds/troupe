defmodule Troupe.WindowAttentionTest do
  @moduledoc """
  What the screen says needs you, and what finished or failed while you looked elsewhere:
  the status line's count, Enter on the command line, and a window's unread mark.

  The old in-process harness logged a window's state (`branch_state`), and the daemon
  sends none, so since the TUI became its client every window said `running` for ever:
  no count of what needs you, no unread mark, and Enter opened the first window rather
  than the one asking. The model derives the state from what the daemon does send — what
  is pending in the window, and how the window's own agent's turn ended, as the log says
  it — and these tests hold it to that, over the wire events as a worker translates
  them.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Codec
  alias Troupe.Remote.Translate
  alias Troupe.UI.TUI.Model

  @child "root/general#1"

  describe "the model" do
    test "a subagent waiting on an approval needs you, and answering it clears that" do
      asked = fold(delegated() ++ [approval_asked(@child, "call_8")])

      assert Model.attention_summary(asked) == "1 need input"
      assert [%{state: :needs_input}] = Model.windows(asked)

      answered =
        fold(delegated() ++ [approval_asked(@child, "call_8"), approval_decided(@child, "call_8")])

      assert Model.attention_summary(answered) == "idle"
      assert [%{state: :running}] = Model.windows(answered)
    end

    test "a subagent's question needs you the same way, until it is answered" do
      asked = fold(delegated() ++ [question_asked(@child, "call_9")])

      assert Model.attention_summary(asked) == "1 need input"
      assert [%{state: :needs_input}] = Model.windows(asked)

      answered =
        fold(delegated() ++ [question_asked(@child, "call_9"), question_answered(@child, "call_9")])

      assert Model.attention_summary(answered) == "idle"
      assert [%{state: :running}] = Model.windows(answered)
    end

    test "a turn that ended is done, and unread" do
      model = fold(turn() ++ [wire("root", "turn_ended")])

      assert Model.attention_summary(model) == "1 done"
      assert [%{state: :done_unread, badge: true, ended_at: ended}] = Model.windows(model)
      assert is_integer(ended)
    end

    test "a turn whose model request failed is failed, and unread" do
      model =
        fold(
          turn() ++
            [
              wire("root", "llm_error", %{"reason" => "the gateway is down"}),
              wire("root", "turn_ended")
            ]
        )

      assert Model.attention_summary(model) == "1 failed"
      assert [%{state: :failed_unread, badge: true} = w] = Model.windows(model)
      assert w.message =~ "the gateway is down"
    end

    test "an agent that ended short, or a turn the harness stopped, is failed" do
      for ending <- [
            wire("root", "agent_done", %{"reason" => "interrupted"}),
            wire("root", "agent_done", %{"reason" => "budget_exhausted", "limit" => "turns"}),
            wire("root", "turn_ended", %{"reason" => "tool_failures"})
          ] do
        model = fold(turn() ++ [ending])
        assert Model.attention_summary(model) == "1 failed", inspect(ending)
      end

      finished = fold(turn() ++ [wire("root", "agent_done", %{"reason" => "finished"})])
      assert Model.attention_summary(finished) == "1 done"
    end

    # Decision 7: a cancel is the person's own doing, and the window reads what happened.
    test "a cancelled turn is done, not failed" do
      model = fold(turn() ++ [wire("root", "cancelled")])
      assert [%{state: :done_unread}] = Model.windows(model)
    end

    test "input sets a window that rested working again" do
      model = fold(turn() ++ [wire("root", "turn_ended")] ++ turn())

      assert [%{state: :running, ended_at: nil}] = Model.windows(model)
      assert Model.attention_summary(model) == "idle"
    end

    test "a subagent's end is not its window's" do
      model =
        fold(delegated() ++ [wire(@child, "agent_done", %{"reason" => "interrupted"})])

      assert [%{state: :running}] = Model.windows(model)
    end

    # The live `agent_state` says idle once before the agent has even taken its task; only
    # the log says the turn is over.
    test "the live idle is not a rest" do
      {events, memory} = translate("s-1", turn())

      {[live], _memory} =
        Translate.ephemeral(
          "s-1",
          %{"type" => "agent_state", "agent" => ["root"], "data" => %{"state" => "idle"}},
          memory
        )

      model = Model.rebuild("s-1", "/w", events ++ [live])
      assert [%{state: :running}] = Model.windows(model)
    end

    # What a screen opened again folds: the journal's copy, which `Codec` reads back with
    # the agent state as the string it wrote.
    test "the journal read back says the same" do
      for {ending, state} <- [
            {[wire("root", "turn_ended")], :done_unread},
            {[wire("root", "llm_error", %{"reason" => "down"}), wire("root", "turn_ended")],
             :failed_unread},
            {[wire("root", "turn_ended", %{"reason" => "tool_failures"})], :failed_unread},
            {[wire("root", "cancelled")], :done_unread}
          ] do
        {events, _memory} = translate("s-1", turn() ++ ending)
        model = Model.rebuild("s-1", "/w", Enum.map(events, &journaled/1))

        assert [%{state: ^state, badge: true}] = Model.windows(model)

        assert Model.activity_line(hd(Model.windows(model)), "root", 0, 10) in [
                 nil,
                 "model error: down"
               ]
      end
    end

    # A window at rest has no spinner, but a model that failed still says why.
    test "a failed window still says what the model said" do
      model =
        fold(
          turn() ++
            [wire("root", "llm_error", %{"reason" => "no API key"}), wire("root", "turn_ended")]
        )

      assert Model.activity_line(hd(Model.windows(model)), "root", 0, 10) ==
               "model error: no API key"
    end
  end

  describe "the screen" do
    setup do
      {sid, _, _} = start_session!(script: [])
      {pid, session} = start_tui(sid)
      %{sid: sid, pid: pid, session: session}
    end

    test "Enter on the command line opens the window a subagent waits in", %{sid: sid, pid: pid} do
      inject(pid, sid, turn("explore-1"))
      inject(pid, sid, delegated("build-1") ++ [approval_asked("build-1/general#1", "call_8")])

      refute hd(Model.windows(user_state(pid).model)).path == "build-1"

      press(pid, "enter")
      assert user_state(pid).focus == {:window, "build-1"}
      assert Model.attention_summary(user_state(pid).model) =~ "1 need input"
    end

    test "a finished and a failed window are unread until they are opened", %{sid: sid, pid: pid} do
      inject(pid, sid, turn("build-1") ++ [wire("build-1", "turn_ended")])

      inject(
        pid,
        sid,
        turn("explore-1") ++
          [wire("explore-1", "llm_error", %{"reason" => "down"}), wire("explore-1", "turn_ended")]
      )

      assert Model.attention_summary(user_state(pid).model) =~ "1 done, 1 failed"

      open(pid, "build-1")
      assert Model.attention_summary(user_state(pid).model) =~ "1 failed"
      refute Model.attention_summary(user_state(pid).model) =~ "done"
      assert %{state: :done_unread, badge: false} = user_state(pid).model.windows["build-1"]

      open(pid, "explore-1")
      refute Model.attention_summary(user_state(pid).model) =~ "failed"
    end

    test "a window that ends while it is open is read", %{sid: sid, pid: pid} do
      inject(pid, sid, turn("build-1"))
      open(pid, "build-1")
      inject(pid, sid, [wire("build-1", "turn_ended")])

      assert %{state: :done_unread, badge: false} = user_state(pid).model.windows["build-1"]
      refute Model.attention_summary(user_state(pid).model) =~ "done"
    end
  end

  # The real thing: a delegation whose subagent asks to write a file, on the daemon this VM
  # embeds, with the scripted model.
  test "a delegated approval is counted, Enter lands on it, and y answers it" do
    {sid, _, ws} =
      start_session!(
        auto_approve: false,
        scripts: %{
          "root" => [
            {:tool, "delegate", %{"agent" => "general", "task" => "write the note"}},
            {:text_and_tools, "The note is written.", []}
          ],
          "general" => [
            {:tool, "write_file", %{"path" => "note.txt", "content" => "from a subagent\n"}},
            {:finish, "wrote note.txt"}
          ]
        }
      )

    {pid, _session} = start_tui(sid)
    :ok = Client.send_input(sid, "root", "delegate the note")

    eventually(fn -> Model.attention_summary(user_state(pid).model) == "1 need input" end, 15_000)

    assert [%{agent_path: "root/general" <> _, kind: :approval}] =
             user_state(pid).model.windows["root"].pending

    press(pid, "enter")
    assert user_state(pid).focus == {:window, "root"}
    press(pid, "y")

    eventually(fn -> File.exists?(Path.join(ws, "note.txt")) end, 15_000)

    eventually(
      fn -> match?(%{state: :done_unread}, user_state(pid).model.windows["root"]) end,
      15_000
    )

    # Open all along, so what it finished with has been seen.
    assert %{pending: [], badge: false} = user_state(pid).model.windows["root"]
    assert Model.attention_summary(user_state(pid).model) == "idle"
  end

  ## Wire events, as a worker receives them

  # A turn the window's agent is taking: the person's line and the model asked.
  defp turn(agent \\ "root") do
    [
      wire(agent, "user_input", %{"source" => "user", "text" => "go"}),
      wire(agent, "llm_request", %{"message_count" => 1})
    ]
  end

  # A turn that delegated: the subagent has started and taken its task.
  defp delegated(agent \\ "root") do
    child = agent <> "/general#1"

    turn(agent) ++
      [
        wire(agent, "tool_call_started", %{
          "call_id" => "call_6",
          "name" => "delegate",
          "args" => %{"agent" => "general", "task" => "ask for it"}
        }),
        wire(child, "agent_started", %{"mode" => "subagent", "profile" => "general"}),
        wire(agent, "delegation_started", %{"agent" => "general", "call_id" => "call_6"}),
        wire(child, "user_input", %{"source" => "user", "text" => "ask for it"}),
        wire(child, "llm_request", %{"message_count" => 1})
      ]
  end

  defp approval_asked(agent, call_id) do
    wire(agent, "approval_requested", %{
      "agent_path" => String.split(agent, "/"),
      "args" => %{"path" => "note.txt"},
      "call_id" => call_id,
      "tool" => "write_file"
    })
  end

  defp approval_decided(agent, call_id) do
    wire(agent, "approval_decided", %{
      "agent_path" => String.split(agent, "/"),
      "call_id" => call_id,
      "decision" => "allow",
      "tool" => "write_file"
    })
  end

  defp question_asked(agent, call_id) do
    wire(agent, "question_asked", %{
      "agent_path" => String.split(agent, "/"),
      "call_id" => call_id,
      "multiple" => false,
      "options" => [%{"label" => "red"}, %{"label" => "blue"}],
      "question" => "Which colour?"
    })
  end

  defp question_answered(agent, call_id),
    do: wire(agent, "question_answered", %{"call_id" => call_id, "text" => "blue"})

  defp wire(agent, type, data \\ %{}) do
    %{
      "actor" => %{"kind" => "system"},
      "agent" => String.split(agent, "/"),
      "data" => data,
      "seq" => System.unique_integer([:positive, :monotonic]),
      "ts" => System.system_time(:millisecond),
      "type" => type,
      "v" => 1
    }
  end

  defp translate(sid, wires, memory \\ Translate.memory(:shared)),
    do: Enum.flat_map_reduce(wires, memory, &Translate.durable(sid, &1, &2))

  defp fold(wires) do
    {events, _memory} = translate("s-1", wires)
    Model.rebuild("s-1", "/w", events)
  end

  defp journaled(event) do
    line = event |> Codec.encode_event() |> IO.iodata_to_binary()
    {:ok, back} = Codec.decode_event(event.session_id, line)
    back
  end

  # Straight into the screen's mailbox, as a worker publishes them; the state read after
  # has them all, the process handling its messages in order.
  defp inject(pid, sid, wires) do
    {events, _memory} = translate(sid, wires)
    for event <- events, do: send(pid, {:troupe_event, event})
    _ = user_state(pid)
    :ok
  end

  # A window opened from the command line by its digit, as the strip numbers it.
  defp open(pid, path) do
    press(pid, "esc")
    eventually(fn -> user_state(pid).focus == :command end)
    i = Enum.find_index(Model.windows(user_state(pid).model), &(&1.path == path))
    press(pid, Integer.to_string(i + 1))
    eventually(fn -> user_state(pid).focus == {:window, path} end)
  end
end
