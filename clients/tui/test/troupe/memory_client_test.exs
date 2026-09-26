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
  # A curated section stamps the brief as built; a note alone leaves it stale.
  @overview {:tools, [{"remember", %{"section" => "overview", "text" => "a fixture repository"}}]}

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
    today = Date.to_iso8601(Date.utc_today())
    assert {:ok, "project brief (fresh, built " <> ^today <> "): Notes"} = Client.memory(sid, "")

    assert {:ok, "project brief forgotten; " <> _} = Client.memory(sid, "forget")
    refute File.exists?(Path.join(ws, ".troupe/memory.md"))
    assert {:ok, "no project brief yet; " <> _} = Client.memory(sid, "")
    assert {:error, "unknown /memory nope; " <> _} = Client.memory(sid, "nope")
  end

  test "a session created where the brief is missing starts the librarian when the config asks" do
    {sid, _, _ws} =
      start_session!(
        workspace: git_init!(tmp_workspace()),
        script: [@overview, {:text, "recorded"}, {:finish, "ok"}],
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

    # The librarian wrote a note and nothing else, and came to rest: the brief is what it
    # made of the repository, checked now, and not stale (Decision 696).
    eventually(
      fn -> match?({:ok, "project brief (fresh, " <> _}, Client.memory(sid, "")) end,
      10_000
    )

    # A second session on the same workspace finds a fresh brief and starts nothing. The
    # branch would be in its journal already: creating a session records the librarian it
    # starts before it returns, so before the test could subscribe to hear it.
    {sid2, _, _} =
      start_session!(workspace: workspace_of(sid), config: %{memory_auto_refresh: true})

    spawned = for %{type: :branch_spawned} = event <- Client.events(sid2), do: event.data.name
    refute "librarian" in spawned
    refute Enum.any?(Client.events(sid2), &(&1.agent_path == "librarian-1"))
  end

  # What a brief describes is a repository: `troupe` opened in a home directory, or any
  # directory git does not know, surveys nothing. Nor does a session whose client says
  # not to, as a headless run does. `/memory refresh` still writes one anywhere.
  test "no librarian starts outside a git repository, or when the client says not to" do
    {outside, _, _} =
      start_session!(script: [{:finish, "ok"}], config: %{memory_auto_refresh: true})

    {headless, _, _} =
      start_session!(
        workspace: git_init!(tmp_workspace()),
        script: [{:finish, "ok"}],
        config: %{memory_auto_refresh: true},
        params: %{refresh_brief: false}
      )

    for sid <- [outside, headless] do
      assert {:ok, "no project brief yet; " <> _} = Client.memory(sid, "")
      refute Enum.any?(Client.events(sid), &(&1.agent_path == "librarian-1"))
    end
  end

  defp workspace_of(sid) do
    {workspace, _config} = Client.context(sid)
    workspace
  end
end
