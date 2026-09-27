defmodule Troupe.CommandsTest do
  @moduledoc """
  The command table (Decision 698) is what every client's palette is drawn from, so it
  has to be complete and unambiguous: every entry carries the fields the protocol
  promises, no name or alias is claimed twice, the sections come in their order, and an
  agent's entry is described by its definition.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definition
  alias Troupe.Commands

  @fields ~w(name aliases section summary usage args availability source detail example)

  test "every built-in carries every field, and no name or alias is claimed twice" do
    entries = Commands.builtins()
    assert length(entries) > 20

    for entry <- entries do
      assert Enum.sort(Map.keys(entry)) == Enum.sort(@fields), entry["name"]
      assert entry["summary"] != "", entry["name"]
      assert String.starts_with?(entry["usage"], "/" <> entry["name"]), entry["name"]
      assert entry["section"] in Commands.sections(), entry["name"]
      assert entry["availability"] in ~w(always window local plane), entry["name"]
      assert entry["source"] == "builtin", entry["name"]

      for arg <- entry["args"] do
        assert Enum.sort(Map.keys(arg)) == ~w(kind name required), entry["name"]
      end
    end

    names = Enum.flat_map(entries, &[&1["name"] | &1["aliases"]])
    assert names == Enum.uniq(names)
  end

  test "the goal and the loop are entries, and help is one that opens the list" do
    names = Enum.map(Commands.builtins(), & &1["name"])
    assert "goal" in names
    assert "loop" in names
    assert "help" in names
    assert "settings" in names
  end

  test "the list comes grouped by section in the sections' order, agents in their own" do
    agents = [
      %Definition{
        name: "code",
        mode: :primary,
        prompt: "",
        description: "Edit in the checkout.\n\nAll tools."
      },
      %Definition{
        name: "plan",
        mode: :primary,
        prompt: "",
        description: "Investigate; read-only."
      }
    ]

    entries = Commands.list(agents: agents)
    sections = entries |> Enum.map(& &1["section"]) |> Enum.dedup()
    assert sections == Commands.sections()

    code = Enum.find(entries, &(&1["name"] == "code"))
    assert code["section"] == "agents"
    assert code["source"] == "agent"
    assert code["summary"] == "Edit in the checkout."
    assert code["detail"] == "Edit in the checkout.\n\nAll tools."
    assert code["usage"] == "/code <prompt>"
    assert [%{"name" => "prompt", "required" => true}] = code["args"]

    # The built-in agent commands come first in their section, then the agents.
    agents_section =
      entries |> Enum.filter(&(&1["section"] == "agents")) |> Enum.map(& &1["name"])

    assert agents_section == ["agents", "worktree", "code", "plan"]
  end

  test "without agents the list is the built-ins" do
    assert Commands.list() == Commands.builtins()
  end
end
