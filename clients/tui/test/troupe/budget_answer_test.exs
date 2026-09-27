defmodule Troupe.BudgetAnswerTest do
  @moduledoc """
  The budget question on screen (Decision 120, issue #183): the harness's words and its
  numbered options, a digit that picks one, and an amount typed and sent with Enter —
  where a typed answer that begins with `n` stays a letter rather than a stop. Each test
  drives the TUI on a session in the daemon this VM embeds, whose model is the fake, with
  a turn limit of one so the second model call asks.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  @two_calls [{:tools, [{"todo_read", %{}}]}, {:tools, [{"todo_read", %{}}]}, {:text, "done"}]

  setup do
    {sid, _, _} = start_session!(script: @two_calls, config: %{"max_turns" => 1})
    {pid, session} = start_tui(sid)

    # The TUI starts on the command line; `1` opens the session's window, where digits
    # pick options and typing goes to the window's own line.
    eventually(fn -> user_state(pid).model.windows["root"] != nil end)
    press(pid, "1")
    eventually(fn -> user_state(pid).focus == {:window, "root"} end)

    say!(sid, "go")
    eventually(fn -> match?(%{options: [_ | _]}, budget(pid)) end, 10_000)
    %{sid: sid, pid: pid, session: session}
  end

  test "is drawn with the harness's words and its numbered options", %{pid: pid, session: session} do
    text = screen_text(pid, session)

    assert text =~ "BUDGET: turns 1/1 (100%): the turn limit is a safety net"
    assert text =~ "1. +5 turns this run"
    assert text =~ "no limit this session"
    assert text =~ "type an amount (+25, +25 session, +25 workspace) and press Enter"
  end

  test "a digit picks an option", %{pid: pid} do
    press(pid, "1")

    assert %{data: %{decision: "raise"}} = await_event("root", :budget_ask_answered, 10_000)
    eventually(fn -> budget(pid) == nil end)
  end

  test "a typed answer is sent with Enter, and one that begins with n is not a stop", %{pid: pid} do
    type(pid, "no limit this session")

    assert user_state(pid).win_text == "no limit this session"
    assert budget(pid) != nil

    press(pid, "enter")

    assert %{data: %{decision: "always"}} = await_event("root", :budget_ask_answered, 10_000)
    eventually(fn -> budget(pid) == nil end)
  end

  defp budget(pid) do
    case user_state(pid).model.windows["root"] do
      %{pending: pending} -> Enum.find(pending, &(&1.kind == :budget))
      _ -> nil
    end
  end
end
