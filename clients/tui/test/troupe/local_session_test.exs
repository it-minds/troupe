defmodule Troupe.LocalSessionTest do
  @moduledoc """
  A session in the daemon on this machine is shown as one (issue #76). Every session is
  reached through a `Troupe.Remote.Worker` now, the daemon's as much as a plane's, and
  both used to be called remote: the root window's `isolation`, which a headless run
  printed as `spawned /root (remote)`, and the status line's `remote (active)`.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.{Client, Event}

  test "the root window of a daemon session is the checkout's" do
    {sid, _, _} = start_session!(script: [{:text_and_tools, "hi", []}])
    say!(sid, "hello")
    await_state("root", :idle, 10_000)

    spawned = Enum.filter(Client.events(sid), &(&1.type == :branch_spawned))
    assert spawned != []
    assert Enum.all?(spawned, &(&1.data.isolation == :shared))
  end

  # The worker says which plane a session is on, `nil` for the daemon's; the status line
  # names a plane's session remote and a daemon's not at all.
  test "the status line calls a plane's session remote, and a daemon's nothing" do
    {sid, _, _} = start_session!(script: [])
    {pid, session} = start_tui(sid)

    send(pid, {:troupe_event, status(sid, nil)})
    eventually(fn -> user_state(pid).model.remote != nil end)
    refute status_line(pid, session, sid) =~ "remote"

    send(pid, {:troupe_event, status(sid, "https://plane.example")})
    eventually(fn -> status_line(pid, session, sid) =~ "remote (active)" end)
  end

  defp status(sid, plane_url) do
    Event.transient(sid, "root", :remote_status, %{
      state: :active,
      scopes: ["observe", "control"],
      can_input?: true,
      can_approve?: true,
      reason: nil,
      endpoint: "ws://127.0.0.1:1/v1/socket",
      plane_url: plane_url
    })
  end

  # The status line is the one row that names the session.
  defp status_line(pid, session, sid) do
    pid |> screen(session) |> Enum.find("", &String.contains?(&1, sid))
  end
end
