defmodule Troupe.Protocol.AgentRuleTest do
  @moduledoc """
  The one reading of a profile's `spec.agents` rule that the plane's offering and the pod's
  definition loader share: what is read, what is refused, deny over allow, a child only
  narrowing its parent, and the wire shape.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.AgentRule

  describe "parse/1" do
    test "absent is no rule, and a rule is its two lists, each once" do
      assert AgentRule.parse(nil) == {:ok, nil}

      assert AgentRule.parse(%{"allow" => ["a", "b", "a"], "deny" => ["c"]}) ==
               {:ok, %{allow: ["a", "b"], deny: ["c"]}}

      assert AgentRule.parse(%{"deny" => ["c"]}) == {:ok, %{allow: nil, deny: ["c"]}}
      assert AgentRule.parse(%{"allow" => []}) == {:ok, %{allow: [], deny: []}}
    end

    test "a name in both lists, a name that is not one, and a field that is neither are refused" do
      assert {:error, [sentence]} = AgentRule.parse(%{"allow" => ["a", "b"], "deny" => ["b"]})
      assert sentence == "b is in both agents.allow and agents.deny: name it in one"

      assert {:error, [sentence]} = AgentRule.parse(%{"deny" => ["a", 7, ""]})
      assert sentence =~ "agents.deny names agents, and 7, \"\" is not a name"

      assert {:error, [sentence]} = AgentRule.parse(%{"allow" => "a"})
      assert sentence =~ "agents.allow must be a list of agent names"

      assert {:error, [sentence]} = AgentRule.parse(%{"ask" => ["a"]})
      assert sentence == "agents.ask is not a field: agents has allow and deny"

      assert {:error, [_sentence]} = AgentRule.parse(["a"])
    end
  end

  describe "allows?/2 and keep/2" do
    test "allow is an allowlist, deny subtracts, deny wins, and no rule is everything" do
      assert AgentRule.keep(~w(a b c), nil) == ~w(a b c)
      assert AgentRule.keep(~w(a b c), %{allow: ~w(a c), deny: []}) == ~w(a c)
      assert AgentRule.keep(~w(a b c), %{allow: nil, deny: ~w(b)}) == ~w(a c)
      assert AgentRule.keep(~w(a b c), %{allow: ~w(a b), deny: ~w(b)}) == ~w(a)
      refute AgentRule.allows?(%{allow: [], deny: []}, "a")
    end
  end

  describe "compose/2" do
    test "a child only narrows: allow is cut to the parent's, deny adds, a denied name leaves allow" do
      parent = %{allow: ~w(a b c), deny: ~w(d)}
      child = %{allow: ~w(b c e), deny: ~w(c)}
      assert AgentRule.compose(parent, child) == %{allow: ~w(b), deny: ~w(d c)}

      # Only one side has a rule: it is the rule.
      assert AgentRule.compose(nil, child) == child
      assert AgentRule.compose(parent, nil) == parent
      assert AgentRule.compose(nil, nil) == nil

      # The parent allows, the child only denies: the parent's allow holds, less the deny.
      assert AgentRule.compose(parent, %{allow: nil, deny: ~w(a)}) == %{
               allow: ~w(b c),
               deny: ~w(d a)
             }

      # An empty cut stands, and a grandchild cannot widen it again.
      empty = AgentRule.compose(parent, %{allow: ~w(z), deny: []})
      assert empty == %{allow: [], deny: ~w(d)}
      assert AgentRule.compose(empty, %{allow: ~w(a), deny: []}) == %{allow: [], deny: ~w(d)}
    end
  end

  describe "the wire" do
    test "json leaves a nil allow out, and from_json reads what the plane sent, forgivingly" do
      assert AgentRule.json(nil) == nil
      assert AgentRule.json(%{allow: nil, deny: ~w(a)}) == %{"deny" => ~w(a)}
      assert AgentRule.json(%{allow: ~w(b), deny: ~w(a)}) == %{"allow" => ~w(b), "deny" => ~w(a)}

      assert AgentRule.from_json(%{"deny" => ~w(a)}) == %{allow: nil, deny: ~w(a)}

      assert AgentRule.from_json(%{"allow" => ["b", 3], "deny" => "no"}) == %{
               allow: ~w(b),
               deny: []
             }

      assert AgentRule.from_json("nonsense") == nil
    end

    test "unmatched names what the rule speaks of that nothing has" do
      assert AgentRule.unmatched(%{allow: ~w(a x), deny: ~w(y)}, ~w(a b)) == ~w(x y)
      assert AgentRule.unmatched(nil, ~w(a)) == []
    end
  end
end
