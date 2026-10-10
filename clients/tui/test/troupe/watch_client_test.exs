defmodule Troupe.WatchClientTest do
  @moduledoc """
  Watch mode in the TUI against the daemon (root Decision 844, D106): a saved `AI!`
  comment opens a `quick` branch's window rather than reaching the session's own agent,
  the line under the screen says which file and comment started which window, and the
  branch's write asks though the workspace auto-approves; the status line shows a watch
  another client turned on, and `/watch` then turns it off.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp notices(pid), do: user_state(pid).model.notices

  test "a saved AI! comment opens a quick branch, says which comment started it, and its write asks" do
    edit =
      {"edit_file",
       %{
         "path" => "calc.ex",
         "old_string" => "# make this 42 AI!\ndef answer, do: 0",
         "new_string" => "def answer, do: 42"
       }}

    {sid, _, ws} =
      start_session!(
        script: [{:tools, [edit]}, {:text, "Made it 42."}],
        config: %{"watch" => true, "watch_debounce_ms" => 80}
      )

    {pid, session} = ready(sid)
    assert screen_text(pid, session) =~ ~r/watch: (native|poll)/

    File.write!(Path.join(ws, "calc.ex"), "# make this 42 AI!\ndef answer, do: 0\n")

    eventually(fn -> Map.has_key?(user_state(pid).model.windows, "quick-1") end, 15_000)

    assert Enum.any?(notices(pid), &(&1 == ~s(watch: calc.ex:1 "make this 42" started quick-1)))

    # Its edit waits for the person, though this workspace auto-approves.
    eventually(
      fn -> match?(%{state: :needs_input}, user_state(pid).model.windows["quick-1"]) end,
      15_000
    )

    assert File.read!(Path.join(ws, "calc.ex")) =~ "AI!"

    # The session's own agent was told nothing; its window says what the comment started.
    refute Enum.any?(Client.events(sid), &(&1.type == :input and &1.agent_path == "root"))
    assert [_] = events_of(sid, "root", :watch_triggered)

    # Allowed, the edit is made in the checkout the comment was written in.
    [%{data: %{call_id: call_id}}] = events_of(sid, "quick-1", :approval_requested)
    :ok = Client.approve(sid, call_id, :allow)
    eventually(fn -> File.read!(Path.join(ws, "calc.ex")) =~ "def answer, do: 42" end, 15_000)
  end

  test "the status line shows a watch another client turned on, and /watch turns it off" do
    {sid, _, _ws} = start_session!(script: [])
    {pid, session} = ready(sid)
    assert screen_text(pid, session) =~ "watch: off"

    # The desktop app, say, turns watch on for this workspace.
    workspace = Troupe.get_session(sid).workspace
    assert {:ok, _backend} = Troupe.set_watch(workspace, true)
    eventually(fn -> user_state(pid).model.watch.enabled end)
    assert screen_text(pid, session) =~ ~r/watch: (native|poll)/

    before = notices(pid)
    press(pid, "/")
    type(pid, "watch")
    press(pid, "enter")
    eventually(fn -> notices(pid) != before end)
    assert hd(notices(pid)) == "watch mode off"
    refute Troupe.Session.Watcher.enabled?(sid)
    eventually(fn -> screen_text(pid, session) =~ "watch: off" end)
  end
end
