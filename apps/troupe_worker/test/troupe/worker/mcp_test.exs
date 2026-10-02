Code.require_file("../../../../troupe_core/test/support/fake_mcp.exs", __DIR__)

defmodule Troupe.Worker.MCPTest do
  @moduledoc """
  A pod's MCP servers keep the sessions they issue (Decision 746), against a fake server
  on loopback that refuses any request without the `Mcp-Session-Id` its `initialize`
  issued and any session presented with another credential than it was opened with
  (`troupe_core/test/support/fake_mcp.exs`).

  The bundle's servers are discovered through the handshake; every session on the pod
  calls the profile's server in the one MCP session; a person-mode server's calls go in a
  session opened with that person's credential, one per person; a session the server has
  forgotten is opened again once; a profile's renewed token ends the session the token
  before it opened; a server a new bundle drops has its sessions ended; and the pod's
  stopping ends the sessions whose credential it holds, leaving a person's to the server.
  Nothing skips.
  """

  use ExUnit.Case, async: false

  alias Troupe.MCP.{Server, Sessions}
  alias Troupe.Test.FakeMCP
  alias Troupe.{Tool, Workspace}
  alias Troupe.Tool.Ctx
  alias Troupe.Worker.MCP

  @moduletag timeout: 60_000

  setup do
    fake = FakeMCP.start(self())
    on_exit(fn -> FakeMCP.stop(fake) end)

    holder = :"troupe_mcp_sessions_#{System.unique_integer([:positive])}"
    start_supervised!({Sessions, name: holder})

    configs = [
      %{"name" => "notes", "url" => fake.url, "credential" => "svc-token"},
      %{"name" => "mine", "url" => fake.url, "credential_mode" => "person"}
    ]

    servers = Enum.map(configs, &Server.from_config/1)

    registry = :"troupe_worker_mcp_#{System.unique_integer([:positive])}"
    start_supervised!({MCP, name: registry, servers: servers, sessions: holder})

    Application.put_env(:troupe_core, :person_credentials, fn _server, ctx ->
      case Troupe.MCP.owner_of(ctx) do
        "idp|ada" -> {:ok, "ada-personal"}
        "idp|bo" -> {:ok, "bo-personal"}
        _other -> {:error, :not_connected}
      end
    end)

    on_exit(fn ->
      Enum.each(
        [:person_credentials, :profile_tokens, :remote_tools, :mcp_servers],
        &Application.delete_env(:troupe_core, &1)
      )
    end)

    tools = Map.new(MCP.tools(registry), &{Tool.name(&1), &1})
    %{fake: fake, tools: tools, configs: configs, registry: registry, holder: holder}
  end

  test "discovery opens a session per server and credential, and lists in it", context do
    assert Map.keys(context.tools) == ["mcp.mine.search", "mcp.notes.search"]

    # The profile's server with the profile's credential; the person-mode one with none,
    # since discovery is the profile's and nobody's credential goes out for it.
    assert [
             %{rpc: "initialize", authorization: "Bearer svc-token"},
             %{rpc: "notifications/initialized", session: "session-1"},
             %{rpc: "tools/list", session: "session-1", status: 200},
             %{rpc: "initialize", authorization: nil},
             %{rpc: "notifications/initialized", session: "session-2"},
             %{rpc: "tools/list", session: "session-2", status: 200}
           ] = requests()
  end

  test "every session on the pod calls the profile's server in the one MCP session", context do
    _discovery = requests()
    notes = context.tools["mcp.notes.search"]

    assert {:ok, "three notes on trains"} =
             Tool.invoke(notes, %{"topic" => "trains"}, ctx("s-1", "idp|ada"))

    assert {:ok, "three notes on boats"} =
             Tool.invoke(notes, %{"topic" => "boats"}, ctx("s-2", "idp|bo"))

    assert [
             %{
               rpc: "tools/call",
               session: "session-1",
               authorization: "Bearer svc-token",
               status: 200
             },
             %{
               rpc: "tools/call",
               session: "session-1",
               authorization: "Bearer svc-token",
               status: 200
             }
           ] = requests()
  end

  test "a person-mode server's calls go in a session opened with that person's credential",
       context do
    _discovery = requests()
    mine = context.tools["mcp.mine.search"]

    assert {:ok, _} = Tool.invoke(mine, %{"topic" => "a"}, ctx("s-1", "idp|ada"))
    assert {:ok, _} = Tool.invoke(mine, %{"topic" => "b"}, ctx("s-2", "idp|bo"))
    assert {:ok, _} = Tool.invoke(mine, %{"topic" => "c"}, ctx("s-3", "idp|ada"))

    assert [
             %{rpc: "initialize", authorization: "Bearer ada-personal"},
             %{rpc: "notifications/initialized", session: "session-3"},
             %{rpc: "tools/call", session: "session-3", status: 200},
             %{rpc: "initialize", authorization: "Bearer bo-personal"},
             %{rpc: "notifications/initialized", session: "session-4"},
             %{rpc: "tools/call", session: "session-4", status: 200},
             %{
               rpc: "tools/call",
               session: "session-3",
               authorization: "Bearer ada-personal",
               status: 200
             }
           ] = requests()
  end

  test "a session the server has forgotten is opened again once", context do
    _discovery = requests()
    FakeMCP.forget(context.fake)

    assert {:ok, "three notes on kites"} =
             Tool.invoke(
               context.tools["mcp.notes.search"],
               %{"topic" => "kites"},
               ctx("s-1", "idp|ada")
             )

    assert [
             %{rpc: "tools/call", session: "session-1", status: 404},
             %{rpc: "initialize", authorization: "Bearer svc-token"},
             %{rpc: "notifications/initialized", session: "session-3"},
             %{rpc: "tools/call", session: "session-3", status: 200}
           ] = requests()
  end

  test "a profile's renewed token ends the session the token before it opened", context do
    {:ok, tokens} = Agent.start_link(fn -> "token-1" end)

    Application.put_env(:troupe_core, :profile_tokens, fn _server, _rejected ->
      {:ok, Agent.get(tokens, & &1)}
    end)

    own = %{"name" => "own", "url" => context.fake.url, "credential_mode" => "client_credentials"}
    assert {:ok, _names} = MCP.put_servers(context.registry, context.configs ++ [own])
    _discovery = requests()

    Agent.update(tokens, fn _ -> "token-2" end)
    renewed = Enum.find(MCP.tools(context.registry), &(Tool.name(&1) == "mcp.own.search"))

    assert {:ok, "three notes on kites"} =
             Tool.invoke(renewed, %{"topic" => "kites"}, ctx("s-1", "idp|ada"))

    assert [
             %{rpc: "initialize", authorization: "Bearer token-2"},
             %{rpc: "notifications/initialized", session: "session-4"},
             %{
               method: "DELETE",
               session: "session-3",
               authorization: "Bearer token-1",
               status: 200
             },
             %{rpc: "tools/call", session: "session-4", status: 200}
           ] = requests()

    # One session for the profile's own identity, and the other servers' untouched.
    assert FakeMCP.sessions(context.fake) == %{
             "session-1" => "Bearer svc-token",
             "session-2" => nil,
             "session-4" => "Bearer token-2"
           }
  end

  test "a server a new bundle drops has its sessions ended, and the others are kept",
       context do
    assert {:ok, _} =
             Tool.invoke(
               context.tools["mcp.mine.search"],
               %{"topic" => "a"},
               ctx("s-1", "idp|ada")
             )

    _so_far = requests()

    notes = Enum.find(context.configs, &(&1["name"] == "notes"))
    assert {:ok, ["mcp.notes.search"]} = MCP.put_servers(context.registry, [notes])

    # The session discovery opened ends. Ada's, whose credential the pod held for her call
    # and no longer, is left to the server, and the pod keeps it no longer either.
    assert [
             %{method: "DELETE", session: "session-2", authorization: nil, status: 200},
             %{rpc: "tools/list", session: "session-1", status: 200}
           ] = requests()

    assert Map.keys(FakeMCP.sessions(context.fake)) == ["session-1", "session-3"]
    assert [{_key, %{id: "session-1"}}] = :ets.tab2list(Sessions.table(context.holder))
  end

  test "the pod's stopping ends the sessions whose credential it holds", context do
    assert {:ok, _} =
             Tool.invoke(
               context.tools["mcp.mine.search"],
               %{"topic" => "a"},
               ctx("s-1", "idp|ada")
             )

    _so_far = requests()

    :ok = stop_supervised!(Sessions)

    ended = requests() |> Enum.filter(&(&1.method == "DELETE")) |> Map.new(&{&1.session, &1})

    # The profile's, with the profile's credential; the one discovery opened with none.
    assert %{authorization: "Bearer svc-token", status: 200} = ended["session-1"]
    assert %{authorization: nil, status: 200} = ended["session-2"]

    # Ada's credential was held for her call and no longer, so her session is the
    # server's to expire.
    refute Map.has_key?(ended, "session-3")
    assert Map.keys(FakeMCP.sessions(context.fake)) == ["session-3"]
  end

  defp ctx(session_id, owner) do
    %Ctx{
      session_id: session_id,
      agent_path: ["root"],
      workspace: %Workspace{root: "/tmp", root_real: "/tmp", root_key: "/tmp"},
      call_id: "call-1",
      agent_pid: self(),
      config: %Troupe.Config{attribution: %{owner: owner, team: "engineering"}}
    }
  end

  # What the server has seen since the last time this was asked, in order.
  defp requests do
    receive do
      {:fake_mcp, request} -> [request | requests()]
    after
      0 -> []
    end
  end
end
