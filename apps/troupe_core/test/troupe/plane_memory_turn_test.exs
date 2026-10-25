defmodule Troupe.PlaneMemoryTurnTest do
  @moduledoc """
  A turn asks, as it begins, whether the memory its session holds is in force (#55): where
  the host installed a check (a pod asks the plane), a session whose push of a save was lost
  reads the new version at its next turn anyway, said as
  `memory_changed`; `instructions_loaded` names each document's version and hash; and what
  each turn read is kept for the host to tell the plane.

  `async: false`: the check is installed for the whole VM, and a session's documents are read
  from the registry it shares.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Session.PlaneMemory, as: Given

  @per_turn [system_prompt: "per_turn"]

  @org_v1 %{
    "scope" => "organisation",
    "name" => nil,
    "version" => 1,
    "hash" => "sha256:o1",
    "text" => "Org: deploy on Tuesdays."
  }
  @org_v2 %{
    "scope" => "organisation",
    "name" => nil,
    "version" => 2,
    "hash" => "sha256:o2",
    "text" => "Org: deploy on Thursdays."
  }

  setup do
    on_exit(fn -> Application.delete_env(:troupe_core, :plane_memory_check) end)
  end

  test "a push lost between turns: the next turn still reads the new version", context do
    test = self()
    in_force = :counters.new(1, [])
    :counters.put(in_force, 1, 1)

    # What the plane would answer: current while version 1 is in force, version 2 after.
    :ok =
      Given.install_check(fn session_id, held ->
        send(test, {:asked, session_id, held})
        if :counters.get(in_force, 1) == 1, do: {:ok, :current}, else: {:ok, [@org_v2]}
      end)

    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: @per_turn ++ [plane_memory: [@org_v1]],
        steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    id = session.id
    assert_received {:asked, ^id, [%{"scope" => "organisation", "version" => 1, "hash" => "sha256:o1"}]}
    assert [loaded] = events_of_type(session.id, :instructions_loaded)

    assert loaded.data["memory"] == [
             %{"scope" => "organisation", "name" => nil, "version" => 1, "hash" => "sha256:o1"}
           ]

    assert [%{"session_id" => ^id, "documents" => [%{"version" => 1}], "turn_at" => _}] = reads(id)

    # Version 2 is saved on the plane; the push that would have given it is lost. Nothing is
    # given to the session, and its next turn reads version 2 all the same.
    :counters.put(in_force, 1, 2)
    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)

    [first, second] = Fake.requests(fake)
    assert first.system =~ "Tuesdays"
    assert second.system =~ "Org: deploy on Thursdays."
    refute second.system =~ "Tuesdays"

    assert [%{data: %{"changes" => [%{"from" => 1, "to" => 2}]}}] = events_of_type(session.id, :memory_changed)
    assert [_, again] = events_of_type(session.id, :instructions_loaded)
    assert [%{"version" => 2, "hash" => "sha256:o2"}] = again.data["memory"]
    assert [%{"documents" => [%{"version" => 2, "hash" => "sha256:o2"}]}] = reads(id)

    # Current again: the third turn asks with version 2 and changes nothing.
    :counters.put(in_force, 1, 1)
    Troupe.send_input(session.id, "once more")
    await_event(session.id, :turn_ended)
    assert_received {:asked, ^id, [%{"version" => 2}]}
    assert [_only] = events_of_type(session.id, :memory_changed)
  end

  test "a check that cannot answer leaves the turn on what it holds", context do
    :ok = Given.install_check(fn _session_id, _held -> {:error, :no_link} end)

    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: @per_turn ++ [plane_memory: [@org_v1]],
        steps: [{:text, "one"}]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    [first] = Fake.requests(fake)
    assert first.system =~ "Tuesdays"
    assert events_of_type(session.id, :memory_changed) == []
  end

  defp reads(id), do: Enum.filter(Given.reads(), &(&1["session_id"] == id))
end
