defmodule Troupe.Protocol.OrganisationTest do
  @moduledoc """
  What an organisation may enforce on people's machines, and what enforcing means
  (Decision 869): the one reading the plane and the machine share.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Organisation

  test "the list is the maintainer's, and nothing else" do
    assert Organisation.keys() ==
             ~w(approvals provider base_url managed_mcp_servers_only managed_permission_rules_only max_tokens max_turns wall_clock_ms max_depth)

    assert Organisation.kind("auto_approve") == nil
    assert Organisation.kind("max_turns") == :ceiling
    assert Organisation.kind("base_url") == :fixed
    assert Organisation.kind("approvals") == {:order, ["wait", "deny"]}
  end

  describe "check, as the plane puts an administrator's set" do
    test "takes enforceable keys of their types, and drops a null" do
      assert {:ok,
              %{"approvals" => "deny", "max_turns" => 100, "managed_mcp_servers_only" => true}} =
               Organisation.check(%{
                 "approvals" => "deny",
                 "max_turns" => 100,
                 "managed_mcp_servers_only" => true,
                 "max_depth" => nil
               })
    end

    test "refuses a key that is not on the list, saying which are, and a value of the wrong type" do
      assert {:error, [unmarked, typed]} =
               Organisation.check(%{"auto_approve" => false, "max_turns" => "lots"})

      assert unmarked ==
               "auto_approve is not a key an organisation may enforce; the ones it may are approvals, provider, " <>
                 "base_url, managed_mcp_servers_only, managed_permission_rules_only, max_tokens, max_turns, " <>
                 "wall_clock_ms and max_depth"

      assert typed == ~s|max_turns must be a whole number, at least 1, not "lots"|

      assert {:error, [_]} = Organisation.check(%{"approvals" => "always"})
      assert {:error, [_]} = Organisation.check(%{"base_url" => ""})
      assert {:error, [_]} = Organisation.check(["approvals"])
    end
  end

  describe "a ceiling" do
    test "a number may be lowered and not raised" do
      assert Organisation.exceeds?(:ceiling, 500, 100)
      refute Organisation.exceeds?(:ceiling, 20, 100)
      assert Organisation.hold(:ceiling, 500, 100) == 100
      assert Organisation.hold(:ceiling, 20, 100) == 20
    end

    test "approvals and a switch may be tightened and not loosened, an atom read as its name" do
      kind = Organisation.kind("approvals")
      assert Organisation.exceeds?(kind, :wait, "deny")
      refute Organisation.exceeds?(kind, "deny", "wait")
      assert Organisation.hold(kind, :wait, "deny") == "deny"

      switch = Organisation.kind("managed_mcp_servers_only")
      assert Organisation.exceeds?(switch, false, true)
      refute Organisation.exceeds?(switch, true, false)
    end

    test "a provider or a URL is fixed" do
      assert Organisation.exceeds?(:fixed, "anthropic", "openai")
      assert Organisation.exceeds?(:fixed, nil, "https://llm.example.test")

      assert Organisation.hold(:fixed, nil, "https://llm.example.test") ==
               "https://llm.example.test"
    end
  end
end
