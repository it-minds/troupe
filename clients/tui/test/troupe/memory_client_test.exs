defmodule Troupe.MemoryClientTest do
  @moduledoc """
  The project brief from the client's side (Decision 105): `/memory` reads it through the
  daemon, `/memory refresh` runs the librarian as a branch, and a session created on a
  repository with no brief starts that branch itself when the config asks.
  """

  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.Client

  @note {:tools, [{"remember", %{"section" => "note", "text" => "tests live under test/"}}]}

  test "/memory shows the brief's state, /memory refresh has the librarian write it, /memory forget removes it" do
    # The same fake answers the session and the librarian branch: one note, then done.
    {sid, _, ws} = start_session!(script: [@note, {:text, "recorded"}, {:finish, "ok"}])

    assert {:ok, "no project brief yet; /memory refresh writes one"} = Client.memory(sid, "")

    assert {:ok, "refreshing the project brief in librarian-1"} = Client.memory(sid, "refresh")
    spawned = await_event("librarian-1", :branch_spawned)
    assert spawned.data.name == "librarian"
    assert spawned.data.isolation == :shared, "the librarian writes the checkout's own brief"
    await_state("librarian-1", :done, 10_000)

    assert File.read!(Path.join(ws, ".troupe/memory.md")) =~ "tests live under test/"
    assert {:ok, "project brief (stale, built never): Notes"} = Client.memory(sid, "")

    assert {:ok, "project brief forgotten; " <> _} = Client.memory(sid, "forget")
    refute File.exists?(Path.join(ws, ".troupe/memory.md"))
    assert {:ok, "no project brief yet; " <> _} = Client.memory(sid, "")
    assert {:error, "unknown /memory nope; " <> _} = Client.memory(sid, "nope")
  end

  test "a session created where the brief is missing starts the librarian when the config asks" do
    {sid, _, _ws} =
      start_session!(
        script: [@note, {:text, "recorded"}, {:finish, "ok"}],
        config: %{memory_auto_refresh: true}
      )

    # The branch was started before this test subscribed, so read it from the journal.
    spawned =
      eventually(fn ->
        Enum.find(
          Client.events(sid),
          &(&1.type == :branch_spawned and &1.agent_path == "librarian-1")
        )
      end)

    assert spawned.data.name == "librarian"
    assert spawned.data.prompt =~ "no project brief yet"

    eventually(
      fn -> match?({:ok, "project brief (stale, " <> _}, Client.memory(sid, "")) end,
      10_000
    )

    # A second session on the same workspace finds a brief and starts nothing.
    {sid2, _, _} =
      start_session!(workspace: workspace_of(sid), config: %{memory_auto_refresh: true})

    refute_receive {:troupe_event,
                    %{session_id: ^sid2, type: :branch_spawned, agent_path: "librarian-1"}},
                   500
  end

  defp workspace_of(sid) do
    {workspace, _config} = Client.context(sid)
    workspace
  end
end
