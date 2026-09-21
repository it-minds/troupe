defmodule Troupe.MCPEntitlementTest do
  @moduledoc """
  A team's entitlements narrow which MCP servers' tools a session is offered, and leave
  what the pod discovered alone.

  Not async, and on its own for that reason: the pod's discovered tools live in the
  application environment, which every session in the VM reads, so a test that puts
  tools there would put them in front of every session running beside it. It used to sit
  in `Troupe.SkillsTest`, which is async, and a local-MCP test running alongside took the
  jira tool for its own stub's.
  """

  use Troupe.SessionCase, async: false

  alias Troupe.Agent.Definition
  alias Troupe.{Tool, Tools}
  alias Troupe.Tool.Ctx

  setup context do
    dir = Path.join(context.base, "bundles/sha256-abc")
    File.mkdir_p!(dir)

    Map.put(context, :bundle, %{version: 3, hash: "sha256:abc", channel: "stable", dir: dir})
  end

  test "takes an MCP server's tools out of a session's list, without undiscovering them",
       context do
    jira = fake_mcp_tool("jira", "create_issue")
    pager = fake_mcp_tool("pager", "page")

    Application.put_env(:troupe_core, :remote_tools, [jira, pager])
    on_exit(fn -> Application.delete_env(:troupe_core, :remote_tools) end)

    definition = %Definition{name: "plain", mode: :primary, prompt: ""}

    offered = definition |> Tools.available(ctx(context, context.bundle)) |> names()
    assert "mcp.jira.create_issue" in offered
    assert "mcp.pager.page" in offered

    narrowed = Map.put(context.bundle, :entitlements, %{"mcp_servers" => ["jira"]})
    offered = definition |> Tools.available(ctx(context, narrowed)) |> names()
    assert "mcp.jira.create_issue" in offered
    refute "mcp.pager.page" in offered

    # The pod still knows the tool exists — discovery is pod-wide and stays that way,
    # because asking four servers for their tool list at every create would put
    # somebody else's latency on the create path.
    assert Enum.any?(Tools.all(), &(Tool.name(&1) == "mcp.pager.page"))
  end

  defp ctx(context, bundle) do
    %Ctx{
      session_id: "s-entitlements",
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      bundle: bundle,
      config: %Troupe.Config{}
    }
  end

  defp names(tools), do: Enum.map(tools, &Tool.name/1)

  # A tool value under an MCP name, which is all the entitlement filter looks at: it
  # works on names, so that a client-hosted tool and a built-in — neither of which any
  # set names — are never narrowed by one.
  defp fake_mcp_tool(server, tool) do
    %Troupe.MCP.Tool{
      name: Troupe.MCP.tool_name(server, tool),
      remote_name: tool,
      server: server,
      description: "a tool",
      schema: %{"type" => "object"},
      run: fn _arguments, _ctx -> {:ok, "done"} end
    }
  end
end
