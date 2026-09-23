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
