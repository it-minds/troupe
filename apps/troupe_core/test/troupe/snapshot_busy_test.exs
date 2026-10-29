defmodule Troupe.SnapshotBusyTest do
  @moduledoc """
  A session's snapshot asked of an agent that is alive but not answering: busy, which a
  caller may ignore, rather than an exit that takes the caller down with it. A pod's
  session manager seeds its lifecycle from this call right after activation, and its
  first turn can hold the agent past the call's limit.
  """

  use ExUnit.Case, async: true

  alias Troupe.Registry

  @moduletag timeout: 30_000

  test "an agent that does not answer in time is busy, not gone" do
    session_id = "snapshot-busy-#{System.unique_integer([:positive])}"

    # This process stands in as the root agent and never answers the call.
    {:ok, _owner} = Elixir.Registry.register(Registry, {:agent, session_id, ["root"]}, nil)

    task = Task.async(fn -> Troupe.snapshot(session_id) end)
    assert {:error, :busy} = Task.await(task, 10_000)

    # A gen_statem call that nobody answered is still in this mailbox; it is not an
    # agent's message and is left there.
    assert_received {:"$gen_call", _from, :snapshot}
  end

  test "a session with no agent is gone" do
    assert {:error, :no_agent} = Troupe.snapshot("snapshot-busy-nobody")
  end
end
