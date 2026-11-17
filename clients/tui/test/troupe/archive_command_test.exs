defmodule Troupe.ArchiveCommandTest do
  @moduledoc """
  `/archive` and `/unarchive` (issue #1005): the session's owner puts it away, hidden from
  the session list for everyone who can see it and kept whole, and brings it back. The
  session stays on screen either way; `/sessions archived` and HQ's `a` list the archived
  ones. A session on this computer is archived by the daemon, a pod session at the plane,
  which refuses anybody but the owner.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Archive
  alias Troupe.FakeRemote
  alias Troupe.UI.HQ

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp run(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp await_notice(pid, pattern) do
    eventually(fn -> Enum.find(notices(pid), &(&1 =~ pattern)) end)
  end

  defp ids({:ok, rows}), do: Enum.map(rows, & &1.id)

  describe "a session on this computer" do
    test "archived, it leaves the list, /sessions archived lists it, and /unarchive brings it back" do
      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws, script: [{:text, "done"}])
      say!(sid, "hello")
      await_done()

      assert sid in ids(Client.sessions({:local, ws}))

      {pid, session} = ready(sid)
      run(pid, "/archive")
      assert await_notice(pid, "Archived") == Archive.said(true)

      # Still on screen: archiving does not take the person out of the session.
      assert user_state(pid).session_id == sid
      assert user_state(pid).focus == :command

      refute sid in ids(Client.sessions({:local, ws}))
      assert {:ok, [%{id: ^sid, archived: true}]} = Client.sessions({:local, ws}, %{archived: true})

      run(pid, "/sessions")
      eventually(fn -> user_state(pid).focus == :sessions end)
      refute sid in Enum.map(user_state(pid).sessions.entries, & &1.id)
      press(pid, "esc")

      run(pid, "/sessions archived")
      eventually(fn -> user_state(pid).focus == :sessions end)
      assert [%{id: ^sid}] = user_state(pid).sessions.entries
      assert screen_text(pid, session) =~ "1 archived session(s)"
      press(pid, "esc")

      run(pid, "/unarchive")
      assert await_notice(pid, "Unarchived") == Archive.said(false)
      assert sid in ids(Client.sessions({:local, ws}))
      assert {:ok, []} = Client.sessions({:local, ws}, %{archived: true})
    end

    test "u in the archived list brings the one under the cursor back" do
      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws, script: [])
      assert {:ok, _said} = Client.archive(sid, true)

      {pid, _session} = ready(sid)
      run(pid, "/sessions archived")
      eventually(fn -> user_state(pid).focus == :sessions end)
      assert [%{id: ^sid}] = user_state(pid).sessions.entries

      press(pid, "u")
      await_notice(pid, "#{sid} is back in the session list")
      assert user_state(pid).sessions.entries == []
      assert sid in ids(Client.sessions({:local, ws}))
    end
  end

  describe "a pod session" do
    @describetag :remote

    test "its owner archives it at the plane, and it is listed only as archived until unarchived" do
      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-mine", owner: "alice", events: [])])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-mine")
      {pid, _session} = ready(sid)

      run(pid, "/archive")
      assert await_notice(pid, "Archived") == Archive.said(true)
      assert [%{"session_id" => "s-mine"}] = calls(remote, "session.archive")
      assert user_state(pid).session_id == sid

      refute "s-mine" in ids(Client.sessions(origin))
      assert {:ok, [%{id: "s-mine", archived: true}]} = Client.sessions(origin, %{archived: true})

      # HQ's `a` turns its sessions column to the archived ones and back.
      hq = HQ.open(origin, tmp_workspace())
      refute "s-mine" in Enum.map(hq.sessions, & &1.id)
      {:ok, hq} = HQ.key(hq, %{code: "a"})
      assert "s-mine" in Enum.map(hq.sessions, & &1.id)
      assert HQ.footer(hq) =~ "a the rest"
      {:ok, hq} = HQ.key(hq, %{code: "a"})
      refute "s-mine" in Enum.map(hq.sessions, & &1.id)

      run(pid, "/unarchive")
      assert await_notice(pid, "Unarchived") == Archive.said(false)
      assert "s-mine" in ids(Client.sessions(origin))
    end

    test "somebody else's is refused, in the owner's words" do
      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-bobs", owner: "bob", events: [])])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-bobs")
      {pid, _session} = ready(sid)

      run(pid, "/archive")
      await_notice(pid, "only the session's owner can archive it")

      run(pid, "/unarchive")
      await_notice(pid, "only the session's owner can unarchive it")

      assert "s-bobs" in ids(Client.sessions(origin))
    end
  end

  defp calls(remote, method),
    do: for({^method, params} <- FakeRemote.calls(remote), do: params)
end
