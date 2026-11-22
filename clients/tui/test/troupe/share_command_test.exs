defmodule Troupe.ShareCommandTest do
  @moduledoc """
  `/share team` and `/share me` (root #1169): a session on the platform given to its team by
  its owner, or taken back, at the plane; `/share` alone says whose it is. The status line's
  mark follows, from the answer and from the log's `session_visibility_changed`. A session
  on this computer is never a team's, and somebody who is not the owner is told whose it is
  to change.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Share
  alias Troupe.FakeRemote

  defp on_a_pod(fields) do
    events = [%{"type" => "llm_response", "data" => FakeRemote.said("first line")}]

    session =
      FakeRemote.session([id: "s-share", profile: "build", team: "eng", events: events] ++ fields)

    {remote, url} = start_remote!(sessions: [session])
    sid = attach!(connect!(remote, url), "s-share")
    {pid, screen} = start_tui(sid)
    eventually(fn -> user_state(pid).commands != [] end)
    {remote, sid, pid, screen}
  end

  defp notices(pid), do: user_state(pid).model.notices

  defp say(pid, line) do
    paste(pid, line)
    press(pid, "enter")
  end

  test "the owner gives it to the team and takes it back; the mark follows" do
    {remote, sid, pid, screen} = on_a_pod(visibility: "private")

    eventually(fn -> screen_text(pid, screen) =~ "remote (active) · only you" end)

    say(pid, "/share")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "/share team gives it to the eng team")) end)

    say(pid, "/share team")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Given to the eng team")) end)
    eventually(fn -> screen_text(pid, screen) =~ "remote (active) · the team's" end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?(
               {"session.visibility.set", %{"session_id" => "s-share", "visibility" => "team"}},
               &1
             )
           )

    # The log's line, which every client attached hears, in the session's window.
    eventually(fn ->
      Enum.any?(
        Client.events(sid),
        &(&1.type == :remote_note and &1.data.text =~ "Alice gave this session to the team")
      )
    end)

    say(pid, "/share me")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Only you again")) end)
    eventually(fn -> screen_text(pid, screen) =~ "remote (active) · only you" end)

    say(pid, "/share everyone")

    eventually(fn ->
      Enum.any?(notices(pid), &(&1 =~ "/share team, /share me, or /share alone"))
    end)

    refute Enum.any?(Client.events(sid), &(&1.type == :input))
  end

  test "somebody who is not the owner is told whose it is to change" do
    {_remote, _sid, pid, screen} = on_a_pod(owner: "bea", visibility: "team")

    eventually(fn -> screen_text(pid, screen) =~ "remote (active) · the team's" end)

    say(pid, "/share me")

    eventually(fn ->
      Enum.any?(
        notices(pid),
        &(&1 =~ "only the session's owner gives it to the team or takes it back")
      )
    end)

    say(pid, "/share")
    eventually(fn -> Enum.any?(notices(pid), &(&1 =~ "Given to the eng team: everyone on it")) end)
    refute Enum.any?(notices(pid), &(&1 =~ "/share me takes it back"))
  end

  test "a session on this computer is never a team's" do
    {sid, _, _} = start_session!(script: [])
    assert {:error, refused} = Client.share(sid, {:set, "team"})
    assert refused == Share.not_here()
  end

  test "what /share names, and the marks" do
    assert {:ok, :status} = Share.parse(" ")
    assert {:ok, {:set, "team"}} = Share.parse("team")
    assert {:ok, {:set, "private"}} = Share.parse(" me ")
    assert {:error, _} = Share.parse("bea@example.com")

    assert Share.mark("team", false) == "the team's"
    assert Share.mark("private", true) == "only you"
    assert Share.mark("private", false) == "by invitation"
    assert Share.mark(nil, true) == nil
  end
end
