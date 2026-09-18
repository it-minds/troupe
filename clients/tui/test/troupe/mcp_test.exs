defmodule Troupe.MCPTest do
  use ExUnit.Case, async: false

  import Troupe.TestHelpers

  alias Troupe.LLM.Fake
  alias Troupe.MCP
  alias Troupe.MCP.JSONRPC

  # The single tool every test server advertises via tools/list. Atom keys
  # (Jason turns them into the string keys the Server decodes: "name",
  # "description", "inputSchema").
  @greet_tool %{
    name: "greet",
    description: "Says hello",
    inputSchema: %{type: "object", properties: %{name: %{type: "string"}}}
  }

  # Default tools/call result: plain text content.
  @greet_result %{content: [%{type: "text", text: "Hello, world!"}]}

  ## JSON-RPC (no session needed)

  test "JSON-RPC encode/decode" do
    json = JSONRPC.request(1, "tools/list", %{})
    assert {:ok, map} = JSONRPC.decode(json)
    assert map["jsonrpc"] == "2.0"
    assert map["id"] == 1
    assert map["method"] == "tools/list"
    assert map["params"] == %{}

    notif = JSONRPC.notification("initialized", %{})
    assert {:ok, notif_map} = JSONRPC.decode(notif)
    refute Map.has_key?(notif_map, "id")
    assert notif_map["jsonrpc"] == "2.0"
    assert notif_map["method"] == "initialized"
    assert notif_map["params"] == %{}

    assert JSONRPC.result?(%{"result" => %{}})
    refute JSONRPC.result?(%{"error" => %{}})
    assert JSONRPC.error?(%{"error" => %{}})
    refute JSONRPC.error?(%{"result" => %{}})
  end

  ## Lifecycle + routing (session tests)

  test "MCP.Server lifecycle: initialize → tools/list → ready" do
    {sid, _fake} = start_mcp_session()

    # :connecting is emitted in Server.init; starting the server *after*
    # subscribe (done in start_session!) is what makes it observable.
    assert_receive {:troupe_event,
                    %{type: :mcp_status, data: %{server: "test", state: :connecting}}},
                   5_000

    assert_receive {:troupe_event,
                    %{type: :mcp_status, data: %{server: "test", state: :ready} = data}},
                   5_000

    assert "mcp__test__greet" in Enum.map(data.tools, & &1.name)

    [spec] = MCP.tool_specs(sid)
    assert spec.name == "mcp__test__greet"
    assert spec.description == "Says hello"
    assert spec.input_schema["type"] == "object"

    assert MCP.status(sid) == [%{name: "test", state: :ready, tools: 1, error: nil}]
  end

  test "call_tool returns text content" do
    {sid, _fake} = start_mcp_session()
    await_ready()

    assert MCP.call(sid, "mcp__test__greet", %{"name" => "world"}, 5_000) ==
             {:ok, "Hello, world!"}
  end

  test "call_tool returns error when isError is true" do
    call_result = %{isError: true, content: [%{type: "text", text: "something went wrong"}]}

    {sid, _fake} = start_mcp_session(handler_opts: [call_result: call_result])
    await_ready()

    assert MCP.call(sid, "mcp__test__greet", %{}, 5_000) == {:error, "something went wrong"}
  end

  test "call on unknown server returns error" do
    {sid, _fake} = start_mcp_session()
    await_ready()

    assert MCP.call(sid, "mcp__unknown__tool", %{}, 5_000) ==
             {:error, "MCP server unknown is not running"}
  end

  test "mcp? predicate" do
    assert MCP.mcp?("mcp__test__greet")
    refute MCP.mcp?("read_file")
    refute MCP.mcp?("")
  end

  test "tool_specs returns [] when no MCP configured" do
    fake = Fake.start!([{:finish, "done"}])
    {sid, _fake, _ws} = start_session!(fake: fake)

    assert MCP.tool_specs(sid) == []
    assert MCP.status(sid) == []
  end

  test "MCP tools appear in the LLM request" do
    {sid, fake} = start_mcp_session(script: [{:finish, "done"}])
    await_ready()

    {:ok, _path} = Troupe.dispatch(sid, "code", "do something")
    await_state("code-1", :done_unread, 10_000)

    req = Fake.requests(fake) |> Enum.find(&(&1.agent_path == "code-1"))
    assert req != nil
    assert Enum.any?(req.tools, &(&1.name == "mcp__test__greet"))
  end

  test "agent dispatches an MCP tool call through the approval door" do
    # The Fake calls the MCP tool, then finishes. MCP tools default to :ask, so
    # auto_approve bypasses the approval door and runs the call directly.
    script = [
      {:tool, "mcp__test__greet", %{"name" => "world"}},
      {:finish, "greeted"}
    ]

    {sid, _fake} = start_mcp_session(script: script, auto_approve: true)
    await_ready()

    {:ok, _path} = Troupe.dispatch(sid, "code", "greet the world")
    await_state("code-1", :done_unread, 10_000)

    # tool_call_completed carries no :name, so find the started call's call_id
    # for the MCP tool and match the completion by it.
    started = events_of(sid, "code-1", :tool_call_started)
    [mcp_started] = Enum.filter(started, &(&1.data.name == "mcp__test__greet"))
    call_id = mcp_started.data.call_id

    [completed] =
      events_of(sid, "code-1", :tool_call_completed)
      |> Enum.filter(&(&1.data.call_id == call_id))

    assert completed.data.ok == true
    assert completed.data.content =~ "Hello, world!"
  end

  ## Helpers

  # Builds an InProcess MCP handler. Responds to the initialize → tools/list
  # lifecycle and to tools/call with the configured `call_result`.
  defp mcp_handler(opts) do
    tools = Keyword.get(opts, :tools, [@greet_tool])
    call_result = Keyword.get(opts, :call_result, @greet_result)

    fn owner, data ->
      msg = Jason.decode!(data)

      case msg do
        %{"id" => id, "method" => "initialize"} ->
          reply(owner, id, %{protocolVersion: "2024-11-05", capabilities: %{}})

        %{"id" => id, "method" => "tools/list"} ->
          reply(owner, id, %{tools: tools})

        %{"id" => id, "method" => "tools/call"} ->
          reply(owner, id, call_result)

        %{"method" => "notifications/initialized"} ->
          :ok
      end
    end
  end

  defp reply(owner, id, result) do
    send(owner, {:mcp_data, Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})})
  end

  # Starts a session (no MCP in its config), subscribes via start_session!, then
  # starts the "test" MCP server. Subscribing before the server starts is what
  # lets a test observe the :connecting event emitted in Server.init.
  defp start_mcp_session(opts \\ []) do
    handler_opts = Keyword.get(opts, :handler_opts, [])
    script = Keyword.get(opts, :script, [{:finish, "done"}])
    auto_approve = Keyword.get(opts, :auto_approve, false)
    fake = Fake.start!(script)

    {sid, fake, _ws} = start_session!(fake: fake, auto_approve: auto_approve)

    :ok =
      Troupe.MCP.Supervisor.start_servers(sid, %{
        "test" => %{handler: mcp_handler(handler_opts)}
      })

    {sid, fake}
  end

  defp await_ready(server \\ "test", timeout \\ 5_000) do
    assert_receive {:troupe_event, %{type: :mcp_status, data: %{server: ^server, state: :ready}}},
                   timeout
  end
end
