defmodule Troupe.PublishCommandTest do
  @moduledoc """
  `/publish` (root #62): one file from this machine published as an artifact on the plane,
  through this computer's daemon, as its person. With no plane to publish to, the daemon's
  sentence says so and nothing is sent; asked wrongly, it says how it is asked.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

  test "/publish says how it is asked, and signed out, that there is nowhere to publish" do
    ws = tmp_workspace(%{"report.html" => "<title>Weekly</title><h1>Weekly</h1>"})
    {sid, _, _} = start_session!(workspace: ws, script: [])
    {:ok, _} = Link.call("identity.unlink", %{command_id: RPC.command_id()})

    {pid, _session} = start_tui(sid)
    eventually(fn -> Enum.any?(user_state(pid).commands, &(&1["name"] == "publish")) end)

    type(pid, "/publish #{Path.join(ws, "report.html")}")
    press(pid, "enter")

    eventually(fn ->
      Enum.find(user_state(pid).model.notices, &(&1 =~ "usage: /publish <path>"))
    end)

    type(pid, "/publish #{Path.join(ws, "report.html")} organisation")
    press(pid, "enter")

    refused =
      eventually(fn -> Enum.find(user_state(pid).model.notices, &(&1 =~ "not published")) end)

    assert refused =~ "not signed in to a Troupe plane"

    type(pid, "/publish #{Path.join(ws, "missing.html")} organisation")
    press(pid, "enter")

    eventually(fn ->
      Enum.find(user_state(pid).model.notices, &(&1 =~ "missing.html: no such file"))
    end)
  end
end
