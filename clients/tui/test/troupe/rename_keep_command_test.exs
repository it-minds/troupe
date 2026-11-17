defmodule Troupe.RenameKeepCommandTest do
  @moduledoc """
  `/rename` and `/keep` (issue #1032): the session's owner names it and keeps it at the top
  of the session list, for everyone who sees it. A session on this computer is named and
  kept by the daemon, a pod session at the plane, which refuses anybody but the owner.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.Client.Marks
  alias Troupe.FakeRemote

  defp ready(sid) do
    {pid, session} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {pid, session}
  end

  defp run(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  defp await_notice(pid, pattern) do
    eventually(fn -> Enum.find(user_state(pid).model.notices, &(&1 =~ pattern)) end)
  end

  defp listed(sid) do
    {:ok, %{"sessions" => rows}} = Link.call("session.list", %{})
    Enum.find(rows, &(&1["id"] == sid))
  end

  describe "a session on this computer" do
    test "/rename names it, /keep keeps it at the top and /keep off lets it go" do
      ws = tmp_workspace()
      {sid, _, _} = start_session!(workspace: ws, script: [])
      {pid, _session} = ready(sid)

      run(pid, "/rename Fix the parser")
      assert await_notice(pid, "Renamed") == Marks.renamed("Fix the parser")
      assert listed(sid)["title"] == "Fix the parser"

      run(pid, "/rename")
      await_notice(pid, "usage: /rename <name>")
      assert listed(sid)["title"] == "Fix the parser"

      run(pid, "/keep")
      assert await_notice(pid, "Kept at the top") == Marks.kept(true)
      assert listed(sid)["pinned"] == true

      run(pid, "/keep off")
      assert await_notice(pid, "Let go") == Marks.kept(false)
      assert listed(sid)["pinned"] == false

      run(pid, "/keep always")
      await_notice(pid, "unknown /keep always")
    end
  end

  describe "a pod session" do
    @describetag :remote

    test "its owner names it and keeps it at the plane" do
      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-mine", owner: "alice", events: [])])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-mine")
      {pid, _session} = ready(sid)

      run(pid, "/rename Ledger move")
      assert await_notice(pid, "Renamed") == Marks.renamed("Ledger move")

      assert [%{"session_id" => "s-mine", "title" => "Ledger move"}] =
               calls(remote, "session.title.set")

      run(pid, "/keep")
      assert await_notice(pid, "Kept at the top") == Marks.kept(true)
      assert [%{"session_id" => "s-mine"}] = calls(remote, "session.pin")

      run(pid, "/keep off")
      assert await_notice(pid, "Let go") == Marks.kept(false)
      assert [%{"session_id" => "s-mine"}] = calls(remote, "session.unpin")
      assert {:ok, rows} = Client.sessions(origin)
      assert %{title: "Ledger move"} = Enum.find(rows, &(&1.id == "s-mine"))
    end

    test "somebody else's is refused, in the owner's words" do
      {remote, url} =
        start_remote!(sessions: [FakeRemote.session(id: "s-bobs", owner: "bob", events: [])])

      origin = connect!(remote, url)
      sid = attach!(origin, "s-bobs")
      {pid, _session} = ready(sid)

      run(pid, "/rename Mine now")
      await_notice(pid, "only the session's owner can rename it")

      run(pid, "/keep")
      await_notice(pid, "only the session's owner can keep it at the top")
    end
  end

  defp calls(remote, method),
    do: for({^method, params} <- FakeRemote.calls(remote), do: params)
end
