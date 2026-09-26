defmodule Troupe.SnapshotTest do
  @moduledoc """
  `Troupe.snapshot/2` while the agent it looked up is stopping. The sleep sweeper and the
  worker ask about sessions that are going to sleep, so an agent can stop between the
  lookup and the call; that is no agent, not a crash in whoever asked.
  """

  use ExUnit.Case, async: true

  # A stand-in registered where a session's root agent would be, which stops as it is
  # asked for its snapshot.
  defp stopping_agent(session_id, reason) do
    test = self()

    spawn(fn ->
      {:ok, _owner} = Registry.register(Troupe.Registry, {:agent, session_id, ["root"]}, nil)
      send(test, :registered)

      receive do
        {:"$gen_call", _from, :snapshot} -> exit(reason)
      end
    end)

    assert_receive :registered
  end

  for reason <- [:normal, :shutdown, {:shutdown, :sleeping}] do
    test "an agent that stops as it is asked (#{inspect(reason)}) is no agent" do
      session_id = "snapshot-#{System.unique_integer([:positive])}"
      stopping_agent(session_id, unquote(Macro.escape(reason)))

      assert Troupe.snapshot(session_id) == {:error, :no_agent}
    end
  end

  test "a session with no agent is no agent" do
    assert Troupe.snapshot("snapshot-none-#{System.unique_integer([:positive])}") ==
             {:error, :no_agent}
  end
end
