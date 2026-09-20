defmodule Troupe.MCPLocalTest do
  @moduledoc """
  A workspace's own MCP servers (Decision 654): a stdio server from the config runs
  for the session, its tools are offered as `mcp.<server>.<tool>`, and the agent's call
  reaches it and comes back as text.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.Session.MCP
  alias Troupe.Tool

  @stub Path.expand("../support/mcp_stub.exs", __DIR__)

  # The stub is an Elixir script, so the `elixir` executable has to be on the path;
  # `mix` always runs where it is.
  @elixir System.find_executable("elixir") || "elixir"

  defp with_stub(context, extra \\ []) do
    File.mkdir_p!(Path.join(context.workspace, ".troupe"))

    File.write!(Path.join(context.workspace, ".troupe/config.yaml"), """
    mcp:
      stub:
        command: #{@elixir}
        args: ["#{@stub}"]
      broken:
        command: no-such-mcp-server-anywhere
    """)

    start_session(context, extra)
  end

  test "the stub's tools are offered under the server's name, and its status is readable", context do
    %{session: session} = with_stub(context)

    tools = wait_for_tools(session.id)
    assert "mcp.stub.greet" in Enum.map(tools, &Tool.name/1)
    [greet] = Enum.filter(tools, &(Tool.name(&1) == "mcp.stub.greet"))
    assert Tool.default_permission(greet) == :ask
    assert Tool.schema(greet)["properties"]["name"]["type"] == "string"

    status = MCP.status(session.id)
    assert %{name: "broken", state: :error} = Enum.find(status, &(&1.name == "broken"))
    assert %{name: "stub", state: :ready, tools: ["greet"], error: nil} = Enum.find(status, &(&1.name == "stub"))

    assert {:ok, "Hello, Troupe!"} = Tool.invoke(greet, %{"name" => "Troupe"}, ctx(session, context))
    assert {:error, "nobody to greet"} = Tool.invoke(greet, %{"name" => "nobody"}, ctx(session, context))
  end

  test "the agent calls the server's tool like any other", context do
    %{session: session} =
      with_stub(context,
        steps: [
          {:tools, [{"mcp.stub.greet", %{"name" => "world"}}]},
          {:text_and_tools, "Greeted.", [{"finish", %{"summary" => "greeted"}}]}
        ]
      )

    sid = session.id
    _ = wait_for_tools(sid)
    :ok = Troupe.subscribe(sid)
    Troupe.send_input(sid, "say hello")

    assert_receive {:troupe_event, ^sid, %Event{type: "tool_call_completed", data: data}}, 15_000
    assert data["name"] == "mcp.stub.greet"
    assert data["ok"] == true
    assert (data["result"] || data["content"]) =~ "Hello, world!"
    assert_receive {:troupe_event, ^sid, %Event{type: "agent_done", agent: ["root"]}}, 5_000
  end

  test "a workspace with no mcp block offers no local tools", context do
    %{session: session} = start_session(context, steps: [])
    assert MCP.tools(session.id) == []
    assert MCP.status(session.id) == []
    refute Enum.any?(Troupe.Tools.all(session.id), &String.starts_with?(Tool.name(&1), "mcp."))
  end

  # The stub takes a moment to start (an Elixir VM), and the session does not wait for it.
  defp wait_for_tools(session_id, waited \\ 0) do
    case Enum.filter(Troupe.Tools.all(session_id), &String.starts_with?(Tool.name(&1), "mcp.")) do
      [] when waited < 20_000 ->
        Process.sleep(200)
        wait_for_tools(session_id, waited + 200)

      tools ->
        tools
    end
  end

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self(),
      config: Troupe.Config.load(context.workspace, state_dir: context.state_dir)
    }
  end
end
