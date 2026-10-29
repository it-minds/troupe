defmodule Troupe.PublishCommandTest do
  @moduledoc """
  `/publish` (root #62): one file from this machine published as an artifact on the plane,
  through this computer's daemon, as its person. With no plane to publish to, the daemon's
  sentence says so and nothing is sent, whoever it was for: the person alone when it names
  nobody, or a team.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

  test "/publish says who it may be for, needs none, and signed out, that there is nowhere to publish" do
    ws =
      tmp_workspace(%{
        "report.html" => "<title>Weekly</title><h1>Weekly</h1>",
        "plan.md" => "# Plan"
      })

    {sid, _, _} = start_session!(workspace: ws, script: [])
    {:ok, _} = Link.call("identity.unlink", %{command_id: RPC.command_id()})

    {pid, _session} = start_tui(sid)

    publish =
      eventually(fn -> Enum.find(user_state(pid).commands, &(&1["name"] == "publish")) end)

    # Who it is for is offered, a team's among them with whose it is, and need not be said.
    assert publish["usage"] =~ "[private | organisation | team:<name> [me | team] | profile:<name>]"

    # Saying nothing of who it is for is the person's alone, and is sent as it is.
    type(pid, "/publish #{Path.join(ws, "report.html")}")
    press(pid, "enter")

    refused =
      eventually(fn -> Enum.find(user_state(pid).model.notices, &(&1 =~ "not published")) end)

    assert refused =~ "not signed in to a Troupe plane"

    type(pid, "/publish #{Path.join(ws, "plan.md")} team:core")
    press(pid, "enter")

    eventually(fn ->
      Enum.find(user_state(pid).model.notices, &(&1 =~ "plan.md not published"))
    end)

    type(pid, "/publish #{Path.join(ws, "missing.html")} organisation")
    press(pid, "enter")

    eventually(fn ->
      Enum.find(user_state(pid).model.notices, &(&1 =~ "missing.html: no such file"))
    end)
  end
end
