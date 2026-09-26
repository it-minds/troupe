defmodule Troupe.TypedInputTest do
  @moduledoc """
  A line typed into the TUI is on screen once (issue #181).

  The window draws a line the moment it is typed, and the daemon writes it back: as
  `user_input` when the agent takes it, and first as `input_queued` when the agent was
  working. Every one of those names the command id the line was sent with, and the window
  draws the first and not the rest. Each test types into the TUI itself, on a session in
  the daemon this VM embeds, so the events are the ones a real agent writes rather than a
  fake's, and each also rebuilds the window from the journal, as a restart does.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Remote.Worker
  alias Troupe.UI.TUI.Model

  # A turn that asks for an approval, so a line typed meanwhile arrives mid-turn, and two
  # replies after it: the turn's own, and the one to the line it queued.
  @approval_then_two_replies [
    {:text_and_tools, "Writing it.",
     [{"write_file", %{"path" => "note.txt", "content" => "a note\n"}}]},
    {:text_and_tools, "Written.", []},
    {:text_and_tools, "And that too.", []}
  ]

  test "a line typed at an idle agent is drawn once, live and rebuilt from the journal" do
    {sid, _, _} = start_session!(script: [{:text_and_tools, "Hello back.", []}])
    {pid, _session} = start_tui(sid)

    type(pid, "hello")
    press(pid, "enter")

    # The reply comes after the line's own events, so they have all been folded by now.
    eventually(fn -> replies(live(pid)) == 1 end, 10_000)

    assert drawn(live(pid), "hello") == 1
    assert drawn(rebuilt(sid), "hello") == 1
    assert window(pid).unconfirmed == %{}
  end

  test "a line typed while the agent works is drawn once, live and rebuilt from the journal" do
    {sid, _, _} = start_session!(script: @approval_then_two_replies, auto_approve: false)
    {pid, _session} = start_tui(sid)

    type(pid, "write a note")
    press(pid, "enter")
    %{data: %{call_id: call_id}} = await_event("root", :approval_requested, 10_000)

    type(pid, "and then this")
    press(pid, "enter")
    await_queued(sid, "and then this")

    :ok = Client.approve(sid, call_id, :allow)
    eventually(fn -> replies(live(pid)) == 3 end, 10_000)

    assert drawn(live(pid), "write a note") == 1
    assert drawn(live(pid), "and then this") == 1
    assert drawn(rebuilt(sid), "and then this") == 1
    assert window(pid).unconfirmed == %{}
  end

  # The connection to the daemon starts again between the line going out and the agent
  # taking it: what the window has drawn is the window's to know, not the connection's.
  test "a line typed before the connection restarts is still drawn once" do
    {sid, _, _} = start_session!(script: @approval_then_two_replies, auto_approve: false)
    {pid, _session} = start_tui(sid)

    type(pid, "write a note")
    press(pid, "enter")
    %{data: %{call_id: call_id}} = await_event("root", :approval_requested, 10_000)

    type(pid, "and then this")
    press(pid, "enter")
    await_queued(sid, "and then this")

    worker = Worker.whereis(sid)
    Process.exit(worker, :kill)
    eventually(fn -> Worker.whereis(sid) not in [nil, worker] end)
    eventually(fn -> Client.capability(sid).up? end)

    :ok = Client.approve(sid, call_id, :allow)
    eventually(fn -> replies(live(pid)) == 3 end, 10_000)

    assert drawn(live(pid), "and then this") == 1
    assert drawn(rebuilt(sid), "and then this") == 1
  end

  # The daemon has written the line down as queued: it is in the journal, which is where
  # a rebuild would find it.
  defp await_queued(sid, text), do: eventually(fn -> drawn(rebuilt(sid), text) >= 1 end)

  defp window(pid), do: user_state(pid).model.windows["root"]
  defp live(pid), do: window(pid).agents["root"].transcript

  defp rebuilt(sid),
    do: Model.rebuild(sid, "/w", Client.events(sid)).windows["root"].agents["root"].transcript

  defp drawn(transcript, text), do: Enum.count(transcript, &(&1 == {:user, text}))
  defp replies(transcript), do: Enum.count(transcript, &match?({:assistant, _}, &1))
end
