defmodule Troupe.BranchProfileTest do
  @moduledoc """
  A branch command whose agents the daemon did not list (D124): `/build` is checked
  against the workspace's primary agents, and when `agents.list` gets no answer the line
  says that, not "unknown command /build; available: /worktree", which reads as though the
  agent were not there.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.Client
  alias Troupe.Client.Daemon.Link

  @moduletag timeout: 120_000

  test "a branch whose agents the daemon did not list says the daemon did not answer" do
    {sid, _, _} = start_session!(script: [])
    {:ok, _endpoint} = Link.ensure()

    :ok = :sys.suspend(Link)

    answer =
      try do
        Task.await(Task.async(fn -> Client.dispatch(sid, "build", "go") end), 60_000)
      after
        :sys.resume(Link)
      end

    assert {:error, said} = answer
    assert said =~ "the daemon did not answer with the agents here, so /build was not started"
    refute said =~ "unknown command"
  end
end
