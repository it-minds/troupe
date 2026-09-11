defmodule Troupe.MCPTest do
  @moduledoc """
  Tools that live on somebody else's server.

  The done item is a negative one — the mock MCP server only ever receives the service
  credential — so the test runs a real HTTP server in the shape of an MCP server and
  reads every header of every request that arrives. Asserting on what this code believes
  it sends would prove nothing, because the question is precisely whether that belief is
  right.
  """

  use ExUnit.Case, async: false

  alias Troupe.MCP
  alias Troupe.MCP.{Client, Server}
  alias Troupe.{Tool, Tools, Workspace}
  alias Troupe.Tool.Ctx

  @moduletag timeout: 60_000

  setup do
    test = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    spawn_link(fn -> serve(listener, test) end)
    on_exit(fn -> :gen_tcp.close(listener) end)

    System.put_env("MOCK_MCP_SERVICE_CREDENTIAL", "svc-secret-9931")
    on_exit(fn -> System.delete_env("MOCK_MCP_SERVICE_CREDENTIAL") end)

    server =
      Server.from_config(%{
        name: "notes",
        url: "http://127.0.0.1:#{port}/mcp",
        credential_ref: "MOCK_MCP_SERVICE_CREDENTIAL"
      })

    %{server: server, port: port}
  end

  describe "the credential" do
    test "is the only thing the server ever receives", context do
      assert {:ok, _tools} = Client.list_tools(context.server)
      listing = assert_request()

      assert listing.headers["authorization"] == "Bearer svc-secret-9931"

      tools = MCP.tools(context.server)
      assert [tool] = tools

      assert {:ok, _output} = Tool.invoke(tool, %{"topic" => "a thing"}, ctx())
      call = assert_request()

      assert call.headers["authorization"] == "Bearer svc-secret-9931"

      # Everything that crossed, across both requests, and no user token anywhere in it.
      both = listing.raw <> call.raw

      refute both =~ "user-token"
      refute both =~ "eyJ"
      refute both =~ "refresh"
      refute both =~ "ada@example.test"

      # There is exactly one credential-bearing header, and it is the service one.
      assert Map.keys(call.headers) |> Enum.filter(&(&1 in ~w(authorization x-api-key cookie))) ==
               ["authorization"]
    end

    test "the session travels as metadata, which is not a credential", context do
      [tool] = MCP.tools(context.server)
      _listing = assert_request()

      assert {:ok, _output} = Tool.invoke(tool, %{"topic" => "a thing"}, ctx())
      call = assert_request()

      # Named, so the server can log which session called it — and useless anywhere
      # else, because it is an identifier rather than a bearer of anything.
      assert call.body["params"]["_meta"]["troupe/session"] == "s-1"
      assert call.body["params"]["_meta"]["troupe/agent"] == "root"
      refute call.body["params"]["_meta"]["troupe/token"]
    end

    test "a reference with no value behind it sends no credential at all", context do
      bare = Server.from_config(%{name: "notes", url: context.server.url, credential_ref: "NOT_SET_ANYWHERE"})

      assert {:ok, _} = Client.list_tools(bare)
      listing = assert_request()

      refute Map.has_key?(listing.headers, "authorization")
    end

    test "inspecting a server shows the reference, never the value", context do
      rendered = inspect(context.server)

      assert rendered =~ "notes"
      assert rendered =~ "MOCK_MCP_SERVICE_CREDENTIAL"
      refute rendered =~ "svc-secret-9931"
    end
  end

  describe "as tools" do
    test "appear as mcp.<server>.<tool> and ask by default", context do
      [tool] = MCP.tools(context.server)
      _listing = assert_request()

      assert tool.name == "mcp.notes.search"
      assert Tool.name(tool) == "mcp.notes.search"
      assert Tool.default_permission(tool) == :ask
      assert Tool.mode(tool) == :task
      assert Tool.schema(tool)["properties"]["topic"]
      assert Tool.describe(tool, ctx()) =~ "notes MCP server"
    end

    test "go through the same allowlist and permission map as a built-in", context do
      tools = MCP.tools(context.server)
      _listing = assert_request()

      Application.put_env(:troupe_core, :remote_tools, tools)
      on_exit(fn -> Application.delete_env(:troupe_core, :remote_tools) end)

      assert {:ok, found} = Tools.fetch("mcp.notes.search")
      assert found.name == "mcp.notes.search"

      # A profile that does not list it cannot call it, exactly as for `shell`.
      narrow = definition(tools: ["read_file"])
      assert {:reject, rejected} = Tools.authorize("mcp.notes.search", narrow, ctx())
      assert rejected.content =~ "not available"

      # A profile that denies it cannot either.
      denied = definition(permissions: %{"mcp.notes.search" => :deny})

      assert {:reject, _} = Tools.authorize("mcp.notes.search", denied, ctx())

      # And one that allows it gets a runnable tool with its mode.
      open = definition([])
      assert {:run, runnable, :task} = Tools.authorize("mcp.notes.search", open, ctx())
      assert Tool.name(runnable) == "mcp.notes.search"
    end

    test "a server that is down costs its tools and nothing else", _context do
      down = Server.from_config(%{name: "gone", url: "http://127.0.0.1:1/mcp"})
      assert MCP.tools(down) == []
    end

    test "an error from the server is a readable tool result, not a crash", context do
      [tool] = MCP.tools(context.server)
      _listing = assert_request()

      assert {:error, message} = Tool.invoke(tool, %{"topic" => "explode"}, ctx())
      _call = assert_request()

      assert message =~ "the MCP server refused"
      assert message =~ "no such topic"
    end
  end

  # -- a mock MCP server ------------------------------------------------------

  defp definition(overrides) do
    %Troupe.Agent.Definition{
      name: "test",
      mode: :primary,
      prompt: "",
      tools: Keyword.get(overrides, :tools, :all),
      permissions: Keyword.get(overrides, :permissions, %{})
    }
  end

  defp ctx do
    %Ctx{
      session_id: "s-1",
      agent_path: ["root"],
      workspace: %Workspace{root: "/tmp", root_real: "/tmp", root_key: "/tmp"},
      call_id: "call-1",
      agent_pid: self()
    }
  end

  defp assert_request(timeout \\ 5_000) do
    receive do
      {:mcp_request, request} -> request
    after
      timeout -> flunk("the MCP server saw no request within #{timeout}ms")
    end
  end

  defp serve(listener, test) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle(socket, test) end)
        serve(listener, test)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle(socket, test) do
    with {:ok, raw} <- read_request(socket),
         [head, body] <- String.split(raw, "\r\n\r\n", parts: 2),
         {:ok, decoded} <- Jason.decode(body) do
      send(test, {:mcp_request, %{raw: raw, headers: headers(head), body: decoded}})
      :gen_tcp.send(socket, response(decoded))
    end

    :gen_tcp.close(socket)
  end

  defp response(%{"id" => id, "method" => "tools/list"}) do
    reply(id, %{
      "tools" => [
        %{
          "name" => "search",
          "description" => "Search the team's notes.",
          "inputSchema" => %{
            "type" => "object",
            "properties" => %{"topic" => %{"type" => "string"}},
            "required" => ["topic"]
          }
        }
      ]
    })
  end

  defp response(%{"id" => id, "method" => "tools/call", "params" => %{"arguments" => %{"topic" => "explode"}}}) do
    error(id, "no such topic")
  end

  defp response(%{"id" => id, "method" => "tools/call"}) do
    reply(id, %{"content" => [%{"type" => "text", "text" => "three notes matched"}]})
  end

  defp response(%{"id" => id}), do: reply(id, %{})

  defp reply(id, result), do: json(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  defp error(id, message), do: json(%{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32000, "message" => message}})

  defp json(payload) do
    body = Jason.encode!(payload)

    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp headers(head) do
    head
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line, ": ", parts: 2) do
        [name, value] -> [{String.downcase(name), value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp read_request(socket, acc \\ "") do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        acc = acc <> data
        if complete?(acc), do: {:ok, acc}, else: read_request(socket, acc)

      {:error, _reason} ->
        :error
    end
  end

  defp complete?(request) do
    case String.split(request, "\r\n\r\n", parts: 2) do
      [head, body] -> byte_size(body) >= content_length(head)
      _ -> false
    end
  end

  defp content_length(head) do
    head
    |> String.split("\r\n")
    |> Enum.find_value(0, fn line ->
      case String.split(String.downcase(line), ": ", parts: 2) do
        ["content-length", value] -> String.to_integer(String.trim(value))
        _ -> nil
      end
    end)
  end
end
