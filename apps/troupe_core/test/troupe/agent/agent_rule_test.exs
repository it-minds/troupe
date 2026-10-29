defmodule Troupe.Agent.AgentRuleTest do
  @moduledoc """
  A worker profile's rule on which agents exist on it (`agent_rule:`) is applied to every
  definition a session loads, subagents included, after the whole search order is merged
  and after the team's entitled set: an agent it excludes is not in the map, so the
  delegate tool's list, `fetch/2` and `primaries/1` never see it.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.Definitions
  alias Troupe.Tools.Delegate

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-rule-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".troupe/agents"))

    File.write!(
      Path.join(root, ".troupe/agents/helper.md"),
      "---\nmode: subagent\n---\nYou help."
    )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a deny drops a built-in primary and a subagent, and the delegate tool no longer lists it",
       %{root: root} do
    defs = Definitions.load(root, agent_rule: %{allow: nil, deny: ["plan", "explore", "helper"]})

    assert {:error, {:unknown_agent, "plan"}} = Definitions.fetch(defs, "plan")
    assert {:error, {:unknown_agent, "explore"}} = Definitions.fetch(defs, "explore")
    assert {:error, {:unknown_agent, "helper"}} = Definitions.fetch(defs, "helper")
    assert {:ok, _build} = Definitions.fetch(defs, "build")

    refute "plan" in Enum.map(Definitions.primaries(defs), & &1.name)
    refute "explore" in Enum.map(Definitions.subagents(defs), & &1.name)

    listed = Delegate.describe(%{definitions: defs})
    assert listed =~ "- general:"
    refute listed =~ "- explore:"
    refute listed =~ "- helper:"
  end

  test "an allow keeps only the named agents, in every mode", %{root: root} do
    defs = Definitions.load(root, agent_rule: %{allow: ["build", "general"], deny: []})
    assert Enum.map(Definitions.primaries(defs), & &1.name) == ["build"]
    assert Enum.map(Definitions.subagents(defs), & &1.name) == ["general"]
  end

  test "the rule is applied after the entitled set, and no rule changes nothing", %{root: root} do
    defs =
      Definitions.load(root,
        entitled: ["build", "plan"],
        agent_rule: %{allow: nil, deny: ["plan"]}
      )

    assert Enum.map(Definitions.primaries(defs), & &1.name) == ["build"]
    # The set names primaries alone; the subagents are untouched by it.
    assert "helper" in Enum.map(Definitions.subagents(defs), & &1.name)

    none = Definitions.load(root, agent_rule: nil)
    assert Definitions.all(none) == Definitions.all(Definitions.load(root))
  end
end
