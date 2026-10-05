defmodule Troupe.PrivateSessionsTest do
  @moduledoc """
  D61 and D59, root Decision 785: the session picker lists a private session as private,
  with how its sealing stands as the daemon's `session.list` says it, one waiting to be
  erased as such, and `c` takes one another device sealed last over on this machine; a
  plane's row waiting to be erased is that state, not none.

  Against `FakeRemote` on the live plane's POST transport, which keeps a private session's
  row and takes a claim fenced on its epoch, and the daemon this VM embeds. That plane signs
  no assertion, so a session claimed here is not sealing yet: what is under test is that
  the row the plane holds is this machine's after `c`, and what the picker says of it.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link
  alias Troupe.FakeRemote
  alias Troupe.Remote.{Capability, Worker}
  alias Troupe.UI.TUI.View

  test "the picker says a private session is held by another device, and c claims it here" do
    {remote, url, sid, ws} = private_session!()

    # Another device of hers carried it on; the daemon hears it at its next link.
    FakeRemote.hold(remote, sid, %{"device" => "ada-laptop", "epoch" => 2})
    reattach()
    eventually(fn -> listed(ws, sid).sync == "elsewhere" end)
    assert %{kind: "private", device: "ada-laptop"} = listed(ws, sid)

    {pid, session} = start_tui(sid)
    type(pid, "/resume")
    press(pid, "enter")
    eventually(fn -> user_state(pid).focus == :sessions end)
    eventually(fn -> screen_text(pid, session) =~ "[private · on ada-laptop]" end)
    assert screen_text(pid, session) =~ "c claims it here"
    # The detail pane wraps the sentence at its width.
    assert screen_text(pid, session) =~ "on ada-laptop — ada-laptop sealed it last; claim it"
    assert screen_text(pid, session) =~ "c claims it for this computer"

    press(pid, "c")
    eventually(fn -> FakeRemote.registered(remote)[sid]["epoch"] == 3 end)
    refute FakeRemote.registered(remote)[sid]["device"] == "ada-laptop"
    eventually(fn -> screen_text(pid, session) =~ "claimed #{sid}" end)
    refute screen_text(pid, session) =~ "on ada-laptop"
    assert url
  end

  test "the picker says one waiting to be erased, and c has nothing to claim" do
    {remote, _url, sid, ws} = private_session!()

    FakeRemote.hold(remote, sid, %{"state" => "erasure_pending"})
    reattach()
    eventually(fn -> listed(ws, sid).sync == "erasure_pending" end)

    {pid, session} = start_tui(sid)
    type(pid, "/resume")
    press(pid, "enter")
    eventually(fn -> screen_text(pid, session) =~ "[private · waiting to be erased]" end)
    assert screen_text(pid, session) =~ "erased; its key is not destroyed yet"

    press(pid, "c")
    eventually(fn -> screen_text(pid, session) =~ "nothing to claim" end)
    assert FakeRemote.registered(remote)[sid]["state"] == "erasure_pending"
  end

  test "a plane's private row waiting to be erased is that state, and takes no input" do
    pending =
      FakeRemote.session(
        id: "p-erasing",
        kind: "private",
        state: "erasure_pending",
        device: "ada-laptop",
        title: "old plans"
      )

    {remote, url} = start_remote!(transport: :http, sessions: [pending])
    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> Client.fleet_status(origin).up? end)

    assert {:ok, [row]} = Client.sessions(origin, %{})
    assert %{state: :erasure_pending, kind: "private", sync: "erasure_pending"} = row
    assert View.kept(row) == "private · waiting to be erased"

    # What the worker reads it as, and what that allows.
    assert Worker.session_state("erasure_pending") == :erasure_pending

    assert %{can_input?: false, reason: "this session is waiting to be erased"} =
             Capability.of(:erasure_pending, ["observe", "control"], true)
  end

  # A private session the daemon made while this TUI was signed in, and registered with the
  # plane; its key cannot be had here, so it is not sealing.
  defp private_session! do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    reattach()
    eventually(fn -> linked(url) end)

    ws = tmp_workspace()

    {sid, _, _} =
      start_session!(workspace: ws, params: %{private: true}, script: [{:text, "ok"}])

    eventually(fn -> Map.has_key?(FakeRemote.registered(remote), sid) end)
    {remote, url, sid, ws}
  end

  defp listed(ws, sid) do
    {:ok, rows} = Client.sessions({:local, ws})
    Enum.find(rows, &(&1.id == sid))
  end

  # The TUI's connection to the daemon drops and is made again at the next call, which
  # links the daemon with the token again, and that link is when it asks the plane.
  defp reattach do
    case :sys.get_state(Link) do
      %{client: client} when is_pid(client) -> Troupe.Protocol.Client.close(client)
      _ -> :ok
    end

    {:ok, _} = Link.call("identity.get", %{})
  end

  defp linked(url) do
    case Link.call("identity.get", %{}) do
      {:ok, %{"linked" => true, "plane_url" => ^url} = identity} -> identity
      _ -> nil
    end
  end
end
