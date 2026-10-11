defmodule Troupe.Gateway.StoppingSessionTest do
  @moduledoc """
  A command for a session whose stop runs past the wait for it is refused in words
  (Decision 855). `Troupe.activate/2` waits for a session being stopped and wakes it
  afresh; when the stop takes longer than the wait it answers `{:error, :stopping}`, and a
  client is told the session is stopping and to try again rather than handed an
  inspected atom. The waiting itself is `Troupe.Sessions.LifecycleTest`'s.
  """

  use ExUnit.Case, async: true

  alias Troupe.Gateway.Dispatch
  alias Troupe.Protocol.Error

  @id "20261011T120000-abcdef"

  test "a command for a session still stopping says so, and to try again" do
    context = %Dispatch.Context{
      principal: %{"subject" => "someone"},
      scopes: [:observe, :control],
      connection: self(),
      activate: fn @id -> {:error, :stopping} end
    }

    for {method, params} <- [
          {"input.send", %{"text" => "hello"}},
          {"turn.cancel", %{}}
        ] do
      assert {:error, %Error{message: "unavailable", data: %{reason: reason}}} =
               Dispatch.call(method, Map.put(params, "session_id", @id), context)

      assert reason == "session #{@id} is stopping; try again"
    end
  end
end
