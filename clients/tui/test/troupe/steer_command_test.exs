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

  alias Troupe.{Client, Event}
  alias Troupe.Client.Steering
  alias Troupe.UI.TUI.Model

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

  test "on a laptop's session steered through the plane an approval is answered once, and a is not offered" do
    script = [
      {:text_and_tools, "Let me write that.",
       [{"write_file", %{"path" => "note.txt", "content" => "from the train\n"}}]},
      {:text, "Done writing."},
      {:finish, "wrote note.txt"}
    ]

    ws = tmp_workspace()
    note = Path.join(ws, "note.txt")
    {sid, _, _} = start_session!(workspace: ws, script: script, auto_approve: false)
    {pid, session} = start_tui(sid)

    type(pid, "please write a note")
    press(pid, "enter")
    await_event("build-1", :approval_requested)

    # The laptop's daemon says `capabilities.relayed` to a connection the plane relays.
    send(pid, {:troupe_event, Event.transient(sid, "root", :remote_status, %{relayed?: true})})
    eventually(fn -> Model.relayed?(user_state(pid).model) end)

    eventually(fn -> screen_text(pid, session) =~ "approval: write_file (y / n in its window)" end)
    press(pid, "1")

    eventually(fn ->
      screen_text(pid, session) =~ "APPROVAL: write_file (y allow once / n deny)"
    end)

    refute screen_text(pid, session) =~ "allow for session"

    # `a` is not sent: it says why, and the approval still waits.
    press(pid, "a")

    eventually(fn ->
      Enum.any?(user_state(pid).model.notices, &(&1 =~ "a call is allowed or denied once"))
    end)

    refute File.exists?(note)
    assert screen_text(pid, session) =~ "APPROVAL: write_file"

    press(pid, "y")
    await_state("build-1", :done, 10_000)
    assert File.read!(note) == "from the train\n"
  end

  test "an offer says whether it comes back after a restart, and the command that makes it, once" do
    until_restart = %{"state" => "online", "shares" => [], "lasts" => "until_restart"}

    # Offered: the state, and the sentence with the command, said once.
    assert Steering.offered(until_restart) ==
             "Offered to the plane, for you alone (online, until this machine restarts). " <>
               "/steer off withdraws it. It stays offered until this machine restarts: " <>
               "troupe-daemon login on starts the daemon when you log in, and the offer comes back with it."

    # Asked again, the state alone.
    assert Steering.line(until_restart) ==
             "Offered to the plane, for you alone (online, until this machine restarts). /steer off withdraws it."

    # Started at login, nothing to say until a restart, and then that it came back.
    assert Steering.offered(%{until_restart | "lasts" => "across_restarts"}) ==
             "Offered to the plane, for you alone (online). /steer off withdraws it."

    back = %{"state" => "online", "shares" => [], "lasts" => "across_restarts", "restored" => true}

    assert Steering.line(back) ==
             "Offered to the plane, for you alone (online, back after a restart). /steer off withdraws it."
  end
end
