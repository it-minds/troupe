defmodule Troupe.HQInboxTest do
  @moduledoc """
  HQ's lines for the person (root #765, #62): one per invitation into a session, and one for
  the artifacts shared with them when there are any, each opening what it names — the
  session, to follow it, or `/artifacts` on Shared with you. Against `FakeRemote`, the
  daemon linked to it as `troupe login` links it.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote

  @moduletag :remote

  @invites [
    %{
      "session_id" => "s-alpha",
      "kind" => "team",
      "title" => "port the parser",
      "role" => "observe",
      "invited_by" => "bea@example.test",
      "invited_by_name" => "Bea"
    },
    %{
      "session_id" => "s-sealed",
      "kind" => "private",
      "title" => "the budget",
      "role" => "observe",
      "invited_by" => "cy@example.test",
      "invited_by_name" => "Cy"
    }
  ]

  @shared [
    %{
      "id" => "a-1",
      "title" => "Interview guide",
      "kind" => "markdown",
      "visibility" => "profile:ops",
      "scope" => "shared",
      "version" => 1
    },
    %{
      "id" => "a-2",
      "title" => "Notes",
      "kind" => "markdown",
      "visibility" => "private",
      "scope" => "shared",
      "version" => 1
    }
  ]

  test "HQ lists each invitation and what is shared with the person, and each line opens it" do
    sessions = [
      FakeRemote.session(
        id: "s-alpha",
        title: "port the parser",
        team: "core",
        profile: "code",
        state: "active"
      )
    ]

    {remote, url} =
      start_remote!(transport: :http, sessions: sessions, invites: @invites, artifacts: @shared)

    login!(remote, url)
    reattach()
    eventually(fn -> match?({:ok, %{"linked" => true}}, Link.call("identity.get", %{})) end)
    {sid, _, _} = start_session!(script: [])

    {pid, screen} = start_tui(sid, page: :hq, plane: url)
    text = screen_text(pid, screen)
    assert text =~ "for you"
    assert text =~ "✉ Bea invited you to follow “port the parser” · Enter opens it"
    assert text =~ "✉ Cy invited you to follow “the budget”"
    assert text =~ "◐ 2 artifacts shared with you · Enter opens /artifacts"

    # The inbox is a column of its own: ←/→ reaches it from the sessions.
    press(pid, "right")
    assert user_state(pid).hq.column == :inbox

    # A private session's is read by the desktop app, which holds its key.
    press(pid, "down")
    press(pid, "enter")
    assert screen_text(pid, screen) =~ "“the budget” is a private session: the desktop app reads it"

    # The shared line opens /artifacts on Shared with you.
    press(pid, "down")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :artifacts end)
    assert user_state(pid).artifacts_page.tab == :shared
    assert screen_text(pid, screen) =~ "Interview guide"
    press(pid, "esc")

    # An invitation opens its session to follow it.
    type(pid, "/hq")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :hq end)
    press(pid, "right")
    press(pid, "enter")

    eventually(fn ->
      match?({:window, _}, user_state(pid).focus) or user_state(pid).session_id == "s-alpha"
    end)

    GenServer.stop(pid, :normal)
  end

  test "with no invitations and nothing shared HQ has no lines for the person" do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    {sid, _, _} = start_session!(script: [])
    {pid, screen} = start_tui(sid, page: :hq, plane: url)

    refute screen_text(pid, screen) =~ "for you"
    press(pid, "right")
    refute user_state(pid).hq.column == :inbox
    GenServer.stop(pid, :normal)
  end

  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end
end
