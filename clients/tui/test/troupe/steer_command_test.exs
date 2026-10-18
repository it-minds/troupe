defmodule Troupe.SteerCommandTest do
  @moduledoc """
  `/steer` (root #58): a session on this computer offered to the plane, to
  steer it from another device. Alone it says how the offer stands and who is steering;
  `/steer on` offers it to the people named, an email to steer it and `email:observe` to
  follow it; `/steer off` withdraws it. What the daemon refuses is said as it says it: a
  daemon nobody signed in on has no plane to offer to.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.Client.Steering

  test "/steer says it is not offered, and an offer with no plane signed in to is refused in words" do
    ws = tmp_workspace(%{})
    {sid, _, _} = start_session!(workspace: ws, script: [])

    assert {:ok, "Not offered to the plane." <> _} = Client.remote_steering(sid, :status)

    {pid, _session} = start_tui(sid)
    eventually(fn -> Enum.any?(user_state(pid).commands, &(&1["name"] == "steer")) end)

    type(pid, "/steer on bea@example.com")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "sign in to a plane first"))
    end)

    type(pid, "/steer on bea@example.com:admin")
    press(pid, "enter")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "add :observe for one who only follows it"))
    end)
  end

  test "the people named, and the sentences an offer is said in" do
    assert {:ok,
            [
              %{"person" => "bea@example.com", "role" => "control"},
              %{"person" => "cy@example.com", "role" => "observe"}
            ]} =
             Steering.share("bea@example.com, cy@example.com:observe")

    assert {:ok, []} = Steering.share("")

    remote = %{
      "state" => "online",
      "shares" => [
        %{"email" => "bea@example.com", "role" => "control"},
        %{"email" => "cy@example.com", "role" => "observe"}
      ],
      "steering" => [
        %{"subject" => "bea@example.com", "display_name" => "Bea", "role" => "control"}
      ]
    }

    assert Steering.line(remote) ==
             "Offered to the plane, shared with bea@example.com, cy@example.com to follow (online). " <>
               "/steer off withdraws it. Bea is steering it from another device."

    assert Steering.offered(%{
             "state" => "offline",
             "since" => "2026-10-18T07:30:00Z",
             "shares" => []
           }) ==
             "Offered to the plane, for you alone (offline since 2026-10-18T07:30:00Z). /steer off withdraws it."
  end
end
