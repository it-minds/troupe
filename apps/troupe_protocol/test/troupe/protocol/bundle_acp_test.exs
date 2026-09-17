defmodule Troupe.Protocol.BundleACPTest do
  @moduledoc """
  An ACP agent in a bundle, and why being in the bundle is the whole argument.

  A third-party coding agent run as a subprocess is exactly the sort of thing a team should
  have to be granted. Putting it in the bundle means it is narrowed by the same grant that
  narrows agents, skills and MCP servers — so done item 3, *an ACP subagent the team is not
  entitled to cannot be named*, needed no new mechanism. These tests are the evidence for
  that claim rather than a description of it.
  """

  use ExUnit.Case, async: true

  alias Troupe.Protocol.Bundle

  defp document(acp_agents, extra \\ %{}) do
    Map.merge(%{"schema" => 1, "acp_agents" => acp_agents}, extra)
  end

  describe "the entry" do
    test "carries a command, its arguments and what the binary should be" do
      assert {:ok, bundle} =
               Bundle.validate(
                 document([
                   %{
                     "name" => "gemini",
                     "command" => "gemini-cli",
                     "args" => ["--acp"],
                     "hash" => "sha256:" <> String.duplicate("a", 64),
                     "description" => "Google's CLI, over ACP"
                   }
                 ])
               )

      assert [agent] = bundle.acp_agents
      assert agent.name == "gemini"
      assert agent.command == "gemini-cli"
      assert agent.args == ["--acp"]
      assert agent.description == "Google's CLI, over ACP"
    end

    test "appears in the summary a listing reads" do
      {:ok, bundle} =
        Bundle.validate(document([%{"name" => "gemini", "command" => "gemini-cli"}]))

      assert Bundle.summary(bundle)["acp_agents"] == ["gemini"]
    end

    test "needs a command, and a malformed hash is named rather than ignored" do
      assert {:error, errors} = Bundle.validate(document([%{"name" => "gemini"}]))
      assert Enum.any?(errors, &(&1 =~ "command"))

      assert {:error, errors} =
               Bundle.validate(
                 document([%{"name" => "gemini", "command" => "x", "hash" => "deadbeef"}])
               )

      assert Enum.any?(errors, &(&1 =~ "sha256:"))

      assert {:error, errors} =
               Bundle.validate(
                 document([%{"name" => "gemini", "command" => "x", "args" => [1, 2]}])
               )

      assert Enum.any?(errors, &(&1 =~ "string"))
    end

    test "cannot take the name of a Troupe agent in the same bundle" do
      # One namespace, because one name is what a model says when it delegates. Two entries
      # called `reviewer` would make which one ran depend on which list was searched first.
      assert {:error, errors} =
               Bundle.validate(
                 document(
                   [%{"name" => "reviewer", "command" => "somebody-elses-agent"}],
                   %{
                     "agents" => [
                       %{"name" => "reviewer", "definition" => "---\nmode: primary\n---\nReview."}
                     ]
                   }
                 )
               )

      assert Enum.any?(errors, &(&1 =~ "both an agent and an acp_agent"))
    end

    test "is optional, and a bundle without one is unchanged" do
      assert {:ok, bundle} = Bundle.validate(%{"schema" => 1})
      assert bundle.acp_agents == []
    end
  end
end
