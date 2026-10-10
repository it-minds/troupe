defmodule Troupe.MCPLocalTest do
  @moduledoc """
  A workspace's own MCP servers (Decision 654): a stdio server from the config runs
  for the session, its tools are offered as `mcp.<server>.<tool>`, and the agent's call
  reaches it and comes back as text.

  And the workspace's `.troupe/mcp.json` (Decision 700): its servers wait for the
  session's question, `allow` starts them and is remembered for the workspace, `deny`
  leaves them stopped, `once` starts them and remembers nothing, a trusted workspace is
  never asked, `managed_mcp_servers_only` starts nothing, and a `reload` reads the file
  again. Its `permission: auto` applies once the workspace is trusted (Decision 830): the
  question grants starting it, and until then its tools ask. The user's layer is
  `Troupe.MCPLayersTest`, which has to run alone.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.MCP.Trust
  alias Troupe.Session.{MCP, Questions}
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

  # The scratch workspace is under the temp directory, which the suite's user file
  # trusts (test_helper.exs); the override makes this one an untrusted clone.
  defp with_workspace_file(context, extra \\ []) do
    write_file(
      context,
      ".troupe/mcp.json",
      Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}})
    )

    start_session(context, [config_overrides: [trusted_workspaces: []]] ++ extra)
  end

  describe "the workspace's .troupe/mcp.json" do
    test "waits for the question; allow starts the server and is remembered for the workspace", context do
      %{session: session} = with_workspace_file(context)

      assert [%{name: "stub", state: :pending, layer: :workspace, tools: []}] = MCP.status(session.id)
      assert MCP.tools(session.id) == []

      [question] = wait_for_question(session.id)
      assert question.call_id =~ "mcp-trust-"
      assert question.question =~ ".troupe/mcp.json"
      assert question.question =~ "stub ("
      assert Enum.map(question.options, & &1.label) == ["deny", "once", "allow"]
      assert [%{type: "question_asked"}] = events_of_type(session.id, :question_asked)

      Troupe.answer(session.id, question.call_id, "allow")

      tools = wait_for_tools(session.id)
      assert "mcp.stub.greet" in Enum.map(tools, &Tool.name/1)
      assert %{state: :ready, layer: :workspace} = Enum.find(MCP.status(session.id), &(&1.name == "stub"))
      assert Map.has_key?(Trust.approved(context.state_dir, context.workspace), "stub")

      # The next session on this workspace asks nothing.
      %{session: second} = start_session(context, config_overrides: [trusted_workspaces: []])
      assert "mcp.stub.greet" in Enum.map(wait_for_tools(second.id), &Tool.name/1)
      assert Questions.pending(second.id) == []
    end

    test "deny leaves the server stopped for the session; once starts it and remembers nothing", context do
      %{session: denied} = with_workspace_file(context)
      [question] = wait_for_question(denied.id)
      Troupe.answer(denied.id, question.call_id, "deny")

      assert %{state: :stopped, error: "not approved" <> _} = wait_for_state(denied.id, "stub", [:stopped])
      assert Questions.pending(denied.id) == []
      assert MCP.tools(denied.id) == []

      %{session: once} = start_session(context, config_overrides: [trusted_workspaces: []])
      [question] = wait_for_question(once.id)
      Troupe.answer(once.id, question.call_id, "once")
      assert "mcp.stub.greet" in Enum.map(wait_for_tools(once.id), &Tool.name/1)
      assert Trust.approved(context.state_dir, context.workspace) == %{}
    end

    test "a trusted workspace is not asked", context do
      write_file(
        context,
        ".troupe/mcp.json",
        Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}})
      )

      %{session: session} = start_session(context, [])
      assert "mcp.stub.greet" in Enum.map(wait_for_tools(session.id), &Tool.name/1)
      assert Questions.pending(session.id) == []
    end

    test "managed_mcp_servers_only starts nothing local, and every server says why", context do
      write_file(
        context,
        ".troupe/mcp.json",
        Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}})
      )

      %{session: session} = start_session(context, config_overrides: [managed_mcp_servers_only: true])
      assert [%{name: "stub", state: :error, error: "managed_mcp_servers_only" <> _}] = MCP.status(session.id)
      assert MCP.tools(session.id) == []
      assert Questions.pending(session.id) == []
    end

    test "reload reads the layers again: a server added, disabled and removed after the start", context do
      %{session: session} = start_session(context, [])
      assert MCP.status(session.id) == []
      assert {:error, :unknown_server} = MCP.reload(session.id, "stub")

      path = write_file(context, ".troupe/mcp.json", Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub]}}}))
      assert {:ok, %{state: :ready, tools: ["greet"], layer: :workspace}} = MCP.reload(session.id, "stub")
      assert "mcp.stub.greet" in Enum.map(MCP.tools(session.id), &Tool.name/1)

      File.write!(path, Jason.encode!(%{"mcpServers" => %{"stub" => %{"command" => @elixir, "args" => [@stub], "disabled" => true}}}))
      assert {:ok, %{state: :disabled}} = MCP.reload(session.id, "stub")
      assert MCP.tools(session.id) == []

      File.rm!(path)
      assert {:error, :unknown_server} = MCP.reload(session.id, "stub")
      assert MCP.status(session.id) == []
    end
  end

  # A workspace's server set to `permission: auto` (#522, Decision 830): the question
  # grants starting it, and its tools run unasked only once the workspace is trusted. The
  # agent calls the tool and a person is there to ask, so an `ask` is an approval request.
  defp auto_stub(context, opts) do
    write_file(
      context,
      ".troupe/mcp.json",
      Jason.encode!(%{
        "mcpServers" => %{
          "stub" => %{"command" => @elixir, "args" => [@stub], "permission" => "auto"}
        }
      })
    )

    start_session(context,
      kind: Keyword.get(opts, :kind, :local),
      steps: [{:tools, [{"mcp.stub.greet", %{"name" => "world"}}]}, {:text, "done"}],
      config_overrides: [
        auto_approve: false,
        trusted_workspaces: if(opts[:trusted], do: [context.workspace], else: [])
      ]
    )
  end

  defp greet_result(sid) do
    sid
    |> events_of_type(:tool_call_completed)
    |> Enum.find(&(&1.data["name"] == "mcp.stub.greet"))
  end

  describe "a workspace's permission: auto" do
    test "in a workspace nobody trusts, allowing the start leaves its tools asking", context do
      %{session: session} = auto_stub(context, trusted: false)
      sid = session.id

      [question] = wait_for_question(sid)
      Troupe.answer(sid, question.call_id, "allow")

      [greet] = sid |> wait_for_tools() |> Enum.filter(&(Tool.name(&1) == "mcp.stub.greet"))
      assert Tool.default_permission(greet) == :ask

      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "say hello")

      assert_receive {:troupe_event, ^sid, %Event{type: "approval_requested", data: asked}},
                     15_000

      assert asked["tool"] == "mcp.stub.greet"
      Troupe.approve(sid, asked["call_id"], :deny)

      assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 10_000
      refute greet_result(sid).data["ok"]
    end

    test "the same workspace trusted is not asked to start it, and its tools run unasked",
         context do
      %{session: session} = auto_stub(context, trusted: true)
      sid = session.id

      [greet] = sid |> wait_for_tools() |> Enum.filter(&(Tool.name(&1) == "mcp.stub.greet"))
      assert Tool.default_permission(greet) == :auto
      assert Questions.pending(sid) == []

      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "say hello")

      assert_receive {:troupe_event, ^sid, %Event{type: "turn_ended", agent: ["root"]}}, 15_000
      assert events_of_type(sid, :approval_requested) == []
      assert greet_result(sid).data["ok"]

      assert (greet_result(sid).data["result"] || greet_result(sid).data["content"]) =~
               "Hello, world!"
    end

    test "the question grants starting it, and says its tools ask until the workspace is trusted",
         context do
      %{session: session} = auto_stub(context, trusted: false)
      [question] = wait_for_question(session.id)

      assert question.question =~ "to start on this machine: stub ("
      assert question.question =~ "Start them?"
      refute question.question =~ "Run them?"

      assert question.question =~
               "stub is set to permission: auto, which applies once this workspace is trusted " <>
                 "(troupe config trust "

      assert question.question =~ "until then its tools ask before each call"

      assert [%{label: "deny"}, %{label: "once"}, %{label: "allow", description: allow}] =
               question.options

      assert allow =~ "start them"

      Troupe.answer(session.id, question.call_id, "deny")
    end

    test "a pod session reads none of it, trusted or not", context do
      %{session: session} = auto_stub(context, trusted: true, kind: :team)

      assert MCP.status(session.id) == []
      assert MCP.tools(session.id) == []
      assert Questions.pending(session.id) == []
    end
  end

  # The question goes out from the holder's own task a moment after the session starts.
  defp wait_for_question(session_id, waited \\ 0) do
    case Questions.pending(session_id) do
      [] when waited < 5_000 ->
        Process.sleep(50)
        wait_for_question(session_id, waited + 50)

      questions ->
        questions
    end
  end

  defp wait_for_state(session_id, name, states, waited \\ 0) do
    entry = Enum.find(MCP.status(session_id), &(&1.name == name))

    cond do
      entry && entry.state in states -> entry
      waited < 5_000 -> Process.sleep(50) && wait_for_state(session_id, name, states, waited + 50)
      true -> entry
    end
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
