defmodule Troupe.Worker.PlaneCommandsTest do
  @moduledoc """
  What a pod does with a push that names a session it could not have been given.

  The plane generates every id it pushes, in the one shape `Troupe.Protocol.SessionId`
  describes, and a pod makes a directory of it. An id in any other shape is refused before
  anything is opened, started or written, which is also why this needs nothing running.
  """

  use ExUnit.Case, async: true

  alias Troupe.Worker.Plane.Commands

  test "session.activate refuses an id that is not a session id" do
    for id <- ["../elsewhere", "*", "a/b", "", nil, 7] do
      params = %{"session_id" => id, "team" => "team-a", "epoch" => 1}

      assert {:error, error} = Commands.handle("session.activate", params), inspect(id)
      assert error.message == "invalid_params"
      assert error.data.field == "session_id"
    end
  end
end

defmodule Troupe.Worker.PlaneCommandsDrainingTest do
  @moduledoc """
  A draining pod takes no new session (D40): one placed in the moments after the drain
  began would be in no list of what the drain puts to sleep, and go down with the pod. The
  plane hears `unavailable`, gives the slot back and places it again.

  `async: false`: whether the pod drains is the VM's (`Drain` keeps it in
  `:persistent_term`).
  """

  use ExUnit.Case, async: false

  alias Troupe.Worker.Drain
  alias Troupe.Worker.Plane.Commands

  setup do
    # Where the pod's awake sessions are named; none is, here.
    unless Process.whereis(Troupe.Worker.Session.Registry),
      do: start_supervised!({Registry, keys: :unique, name: Troupe.Worker.Session.Registry})

    Drain.reset()
    on_exit(&Drain.reset/0)
  end

  test "session.activate on a draining pod is refused, saying so" do
    :persistent_term.put({Drain, :draining?}, true)
    params = %{"session_id" => Troupe.Session.generate_id(), "team" => "team-a", "epoch" => 1}

    assert {:error, error} = Commands.handle("session.activate", params)
    assert error.message == "unavailable"
    assert error.data.reason == "draining"
  end
end
