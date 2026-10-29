defmodule Troupe.Agent.FunctionAgentTest do
  @moduledoc """
  A function agent (`mode: function`) is one the harness starts by name for one job: it
  is fetched by name, no team's entitled set narrows it, and the profile's rule removes it
  as it removes any other agent. One the rule took away is not started, and the session
  it would have been a branch of hears so once in its log rather than its root crashing.
  Runs on the scripted model; nothing is skipped.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Agent.Definitions

  @deny_librarian %{allow: nil, deny: ["librarian"]}

  test "the entitled set leaves function agents alone and the profile's rule removes one" do
    entitled = Definitions.load(nil, entitled: ["build"])
    assert Enum.map(Definitions.primaries(entitled), & &1.name) == ["build"]
    assert "librarian" in Enum.map(Definitions.functions(entitled), & &1.name)

    ruled = Definitions.load(nil, agent_rule: @deny_librarian)
    assert {:error, {:unknown_agent, "librarian"}} = Definitions.fetch(ruled, "librarian")
    assert Definitions.ruled_out?(ruled, "librarian")
    refute Definitions.ruled_out?(ruled, "answer")
    assert "answer" in Enum.map(Definitions.functions(ruled), & &1.name)
  end

  test "a librarian the profile denies is not started, and its parent's log says so once",
       context do
    %{session: parent} = start_session(context)
    definitions = Definitions.load(context.workspace, agent_rule: @deny_librarian)

    start = fn ->
      Troupe.start_session(
        workspace: context.workspace,
        agent: "librarian",
        parent: parent.id,
        definitions: definitions,
        config_overrides: [provider: "fake", model: "fake-model", state_dir: context.state_dir]
      )
    end

    assert {:error, {:not_on_profile, "librarian"}} = start.()
    assert {:error, {:not_on_profile, "librarian"}} = start.()

    assert [note] =
             parent.id
             |> events_of_type("config_note")
             |> Enum.filter(&(&1.data["key"] == "agents"))

    assert note.data["message"] =~ "librarian was not started"
    assert note.data["message"] =~ "agents rule"
    assert Process.alive?(parent.pid)
  end

  test "an agent nothing defines is refused by name, not by a crash of its root", context do
    assert {:error, {:unknown_agent, "nobody"}} =
             Troupe.start_session(
               workspace: context.workspace,
               agent: "nobody",
               config_overrides: [
                 provider: "fake",
                 model: "fake-model",
                 state_dir: context.state_dir
               ]
             )
  end
end
