defmodule Troupe.PlaneMemoryRefreshTest do
  @moduledoc """
  The organisation's memory reaching a session that is already running (#55): a save on
  the plane gives the session new documents (`Troupe.Session.PlaneMemory`), its next turn
  reads them, its log says what changed and to which version, and what the session
  explains names the new versions. Nothing changes until that turn, and the same versions
  again say nothing.

  `async: false`: a session's documents are read from the registry the whole VM shares.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Config.Explain
  alias Troupe.PlaneMemory
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
  @team %{
    "scope" => "team",
    "name" => "design",
    "version" => 5,
    "hash" => "sha256:t5",
    "text" => "Team: use the design tokens."
  }

  defp given(documents), do: documents |> PlaneMemory.in_force() |> elem(0)

  test "a save reaches a running session at its next turn, with a line saying what changed and to which version",
       context do
    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: @per_turn ++ [plane_memory: [@org_v1]],
        steps: [{:text, "one"}, {:text, "two"}, {:text, "three"}]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)
    [first] = Fake.requests(fake)
    assert first.system =~ "Org: deploy on Tuesdays."

    assert :ok = Given.put(session.id, given([@org_v2, @team]))
    assert events_of_type(session.id, :memory_changed) == []

    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)
    [_first, second] = Fake.requests(fake)
    assert second.system =~ "Org: deploy on Thursdays."
    assert second.system =~ "Team: use the design tokens."
    refute second.system =~ "Tuesdays"

    assert [changed] = events_of_type(session.id, :memory_changed)
    assert changed.agent == ["root"]

    assert changed.data["changes"] == [
             %{"scope" => "organisation", "name" => nil, "from" => 1, "to" => 2},
             %{"scope" => "team", "name" => "design", "from" => nil, "to" => 5}
           ]

    assert changed.data["message"] ==
             "The organisation's memory changed: the organisation's memory is now version 2 (it was 1); " <>
               "the team design's memory is new, version 5. Read from this turn on."

    # What the session explains is what its turns now read.
    {json, 0} = Explain.explain_session(session.id, nil, json: true)

    assert Enum.map(Jason.decode!(json)["memory"], &{&1["scope"], &1["version"]}) == [
             {"organisation", 2},
             {"team", 5}
           ]

    # The same versions given again change nothing and say nothing.
    assert :ok = Given.put(session.id, given([@org_v2, @team]))
    Troupe.send_input(session.id, "once more")
    await_event(session.id, :turn_ended)
    assert length(Fake.requests(fake)) == 3
    assert [_only] = events_of_type(session.id, :memory_changed)
  end

  test "an empty list takes the documents away at the next turn, and says so", context do
    %{session: session, fake: fake} =
      start_session(context,
        config_overrides: @per_turn ++ [plane_memory: [@org_v1]],
        steps: [{:text, "one"}, {:text, "two"}]
      )

    :ok = Troupe.subscribe(session.id)
    Troupe.send_input(session.id, "hello")
    await_event(session.id, :turn_ended)

    assert :ok = Given.put(session.id, given([]))
    Troupe.send_input(session.id, "again")
    await_event(session.id, :turn_ended)

    [_first, second] = Fake.requests(fake)
    refute second.system =~ "Tuesdays"

    assert [%{data: %{"changes" => [%{"from" => 1, "to" => nil}], "message" => message}}] =
             events_of_type(session.id, :memory_changed)

    assert message =~ "the organisation's memory (version 1) was taken away"
  end

  test "a session not running here is said to be so" do
    assert {:error, :no_session} = Given.put("s-not-here", given([@org_v1]))
  end
end
