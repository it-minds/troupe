defmodule Troupe.UnlinkCommandTest do
  @moduledoc """
  `/unlink` (D71): the terminal's way to stop using an account on this computer's daemon,
  which the desktop app has as "Stop using my account here". Alone it says who the daemon
  records sessions as, and what unlinking drops and keeps; `/unlink yes` does it.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client.Daemon.Link
  alias Troupe.Remote.RPC

  @plane "https://plane.example.test"

  test "/unlink asks once, saying what goes and what stays, and /unlink yes unlinks" do
    ws = tmp_workspace(%{})
    {sid, _, _} = start_session!(workspace: ws, script: [])

    {:ok, _} = Link.call("identity.unlink", %{command_id: RPC.command_id()})

    {:ok, _} =
      Link.call("identity.link", %{
        command_id: RPC.command_id(),
        subject: "bea",
        display_name: "Bea",
        plane_url: @plane
      })

    {pid, _session} = start_tui(sid)
    eventually(fn -> Enum.any?(user_state(pid).commands, &(&1["name"] == "unlink")) end)

    type(pid, "/unlink")
    press(pid, "enter")

    asked =
      eventually(fn -> Enum.find(user_state(pid).model.notices, &(&1 =~ "/unlink yes")) end)

    assert asked =~ "recorded as Bea at #{@plane}"
    assert asked =~ "drops the link, the platform's token and the daemon's own sign-in"
    assert asked =~ "organisation's memory"
    assert asked =~ "the sessions stay"
    # Asked, not done.
    assert {:ok, %{"linked" => true, "subject" => "bea"}} = Link.call("identity.get", %{})

    type(pid, "/unlink yes")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "unlinked from Bea at #{@plane}"))
    end)

    assert {:ok, %{"linked" => false}} = Link.call("identity.get", %{})
  end
end
