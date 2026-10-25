defmodule Troupe.InviteCommandTest do
  @moduledoc """
  `/invite` and `/uninvite` (root #765): a person invited into the session by name, to
  follow it or steer it, and the invitation taken back. A pod session is invited at the
  plane, a private one through the daemon that seals it; a session on this computer alone
  is offered instead, and the daemon says so, in its words. The sentences are the desktop
  app's.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Invites

  test "a session on this computer alone is not invited, and the daemon says what to do instead" do
    ws = tmp_workspace(%{})
    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:error, refused} = Client.invites(sid, {:invite, "bea@example.com", "observe"})
    assert refused =~ "only a private session is invited from this machine"

    {pid, _session} = start_tui(sid)
    eventually(fn -> Enum.any?(user_state(pid).commands, &(&1["name"] == "invite")) end)

    type(pid, "/invite bea@example.com control")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "/steer on"))
    end)

    type(pid, "/invite bea@example.com admin")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(
        user_state(pid).model.notices,
        &(&1 =~ "observe or /invite <email> control: not admin")
      )
    end)

    assert {:error, refused} = Client.invites(sid, {:uninvite, "bea@example.com"})
    assert refused =~ "only a private session is invited from this machine"
  end

  test "the person and role named, and the sentences an invitation is said in" do
    assert {:ok, "bea@example.com", "observe"} = Invites.parse("bea@example.com")
    assert {:ok, "bea@example.com", "control"} = Invites.parse(" bea@example.com  control ")
    assert {:error, _} = Invites.parse("bea@example.com cy@example.com observe")

    assert Invites.line([]) =~ "Shared with nobody by name"

    assert Invites.line([
             %{"subject" => "bea@example.com", "display_name" => "Bea", "role" => "observe"},
             %{"subject" => "cy@example.com", "email" => "cy@example.com", "role" => "control"}
           ]) == "Shared with Bea (follows), cy@example.com (steers)."

    assert Invites.invited(
             %{"invite" => %{"subject" => "bea@example.com", "display_name" => "Bea"}},
             "control"
           ) ==
             "Invited Bea to steer it: they see it in their list. /uninvite bea@example.com takes it back."

    assert Invites.uninvited(
             %{"subject" => "bea@example.com", "rekey_due" => false, "key_version" => 2},
             "bea"
           ) =~
             "sealed under a new key they are never given"

    assert Invites.uninvited(%{"subject" => "bea@example.com", "rekey_due" => true}, "bea") =~
             "once this computer can reach the key manager"

    assert Invites.uninvited(%{"subject" => "bea@example.com", "rekey_due" => false}, "bea") ==
             "Took back bea@example.com's invitation: their open views close."
  end
end
