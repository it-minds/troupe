Code.require_file("../support/fake_mcp.exs", __DIR__)

defmodule Troupe.MCPHandshakeTest do
  @moduledoc """
  The MCP lifecycle over streamable HTTP (Decision 746), against a fake server on
  loopback that keeps a session per client and refuses any request without the
  `Mcp-Session-Id` its `initialize` issued (`test/support/fake_mcp.exs`).

  A local session opens the MCP session before its first request and carries it, with
  the protocol version the server chose, on every request after; the agent lists the
  server's tools and calls one; a session the server has forgotten (`404`, or `400` as
  some servers built on the SDKs answer) is opened again once and the request goes
  through, and a `400` a new session does not cure is the call's error after that one
  retry; the session is ended with a `DELETE` when the local session stops, and a `405`
  to it is let be; two credentials are two sessions, and a credential that replaced
  another ends the session the other opened; a server that keeps no session is called
  without one once the handshake is done; and a server tried outside any session gets a
  session for its one request, ended after it. Nothing here skips.
  """

  use Troupe.SessionCase, async: true

  alias Troupe.MCP.{Client, Server, Sessions}
  alias Troupe.Session.MCP
  alias Troupe.Test.FakeMCP
  alias Troupe.Tool

  @moduletag timeout: 60_000

  setup context do
    fake = FakeMCP.start(self(), Map.get(context, :fake, []))
    on_exit(fn -> FakeMCP.stop(fake) end)
    Map.put(context, :fake, fake)
  end

  defp with_server(context, opts \\ []) do
    write_file(
      context,
      ".troupe/mcp.json",
      Jason.encode!(%{"mcpServers" => %{"notes" => %{"url" => context.fake.url}}})
    )

    start_session(context, opts)
  end

  describe "a server that keeps a session" do
    test "a session lists its tools and calls one, in the MCP session its handshake opened",
         context do
      %{session: session} =
        with_server(context,
          steps: [
            {:tools, [{"mcp.notes.search", %{"topic" => "trains"}}]},
            {:text_and_tools, "Found.", [{"finish", %{"summary" => "found"}}]}
          ]
        )

      sid = session.id

      assert %{state: :ready, tools: ["search"], error: nil} =
               wait_for_state(sid, "notes", [:ready])

      :ok = Troupe.subscribe(sid)
      Troupe.send_input(sid, "find trains")

      assert_receive {:troupe_event, ^sid, %Event{type: "tool_call_completed", data: data}},
                     15_000

      assert data["name"] == "mcp.notes.search"
      assert data["ok"] == true
      assert (data["result"] || data["content"]) =~ "three notes on trains"

      # The handshake, and then every request in the session it opened, carrying the
      # protocol version the server chose rather than the one asked for. One handshake
      # for the listing and the call both.
      assert [
               %{rpc: "initialize", session: nil, version: "2025-06-18", status: 200},
               %{rpc: "notifications/initialized", session: "session-1", status: 202} = ready,
               %{rpc: "tools/list", session: "session-1", status: 200} = listing,
               %{rpc: "tools/call", session: "session-1", status: 200} = call
             ] = requests()

      assert Enum.map([ready, listing, call], & &1.version) ==
               List.duplicate(FakeMCP.version(), 3)
    end

    test "a session the server has forgotten is opened again once, and the call goes through",
         context do
      %{session: session} = with_server(context)
      wait_for_state(session.id, "notes", [:ready])
      search = tool(session.id)
      _handshake_and_listing = requests()

      FakeMCP.forget(context.fake)

      assert {:ok, "three notes on boats"} =
               Tool.invoke(search, %{"topic" => "boats"}, ctx(session, context))

      assert [
               %{rpc: "tools/call", session: "session-1", status: 404},
               %{rpc: "initialize", session: nil, status: 200},
               %{rpc: "notifications/initialized", session: "session-2"},
               %{rpc: "tools/call", session: "session-2", status: 200}
             ] = requests()

      # And the next call is in the new session, with no handshake before it.
      assert {:ok, "three notes on cars"} =
               Tool.invoke(search, %{"topic" => "cars"}, ctx(session, context))

      assert [%{rpc: "tools/call", session: "session-2", status: 200}] = requests()
    end

    @tag fake: [forgotten: 400]
    test "a session the server answers 400 for is opened again once, as a 404 is", context do
      %{session: session} = with_server(context)
      wait_for_state(session.id, "notes", [:ready])
      search = tool(session.id)
      _handshake_and_listing = requests()

      FakeMCP.forget(context.fake)

      assert {:ok, "three notes on boats"} =
               Tool.invoke(search, %{"topic" => "boats"}, ctx(session, context))

      # Ended too, since a server may answer 400 for a session it still holds.
      assert [
               %{rpc: "tools/call", session: "session-1", status: 400},
               %{method: "DELETE", session: "session-1", status: 400},
               %{rpc: "initialize", session: nil, status: 200},
               %{rpc: "notifications/initialized", session: "session-2"},
               %{rpc: "tools/call", session: "session-2", status: 200}
             ] = requests()

      assert {:ok, "three notes on cars"} =
               Tool.invoke(search, %{"topic" => "cars"}, ctx(session, context))

      assert [%{rpc: "tools/call", session: "session-2", status: 200}] = requests()
    end

    @tag fake: [bad_calls: true]
    test "a 400 a new session does not cure is the call's error, after one more try",
         context do
      {:ok, holder} = Sessions.start_link()

      server = %Server{
        name: "notes",
        url: context.fake.url,
        credential: "profile-token",
        sessions: Sessions.table(holder)
      }

      assert {:ok, [%{"name" => "search"}]} = Client.list_tools(server)
      _handshake_and_listing = requests()

      assert {:error, {:unexpected_status, 400, _body}} =
               Client.call_tool(server, "search", %{"topic" => "a"})

      assert [
               %{rpc: "tools/call", session: "session-1", status: 400},
               %{method: "DELETE", session: "session-1", status: 200},
               %{rpc: "initialize", status: 200},
               %{rpc: "notifications/initialized", session: "session-2"},
               %{rpc: "tools/call", session: "session-2", status: 400}
             ] = requests()

      # The session it opened is kept, and nothing is left open beside it.
      assert Map.keys(FakeMCP.sessions(context.fake)) == ["session-2"]
      :ok = GenServer.stop(holder)
    end

    test "a credential that replaced another ends the session the other opened", context do
      {:ok, holder} = Sessions.start_link()
      server = %Server{name: "notes", url: context.fake.url, sessions: Sessions.table(holder)}
      person = %{server | credential: "ada-token", credential_mode: :person}

      assert {:ok, _} = Client.list_tools(%{server | credential: "token-1"})
      assert {:ok, _} = Client.call_tool(person, "search", %{"topic" => "a"})
      _so_far = requests()

      # A sign-in refreshed, or a profile's token renewed: the same server and caller.
      renewed = %{server | credential: "token-2"}
      assert {:ok, _} = Client.call_tool(renewed, "search", %{"topic" => "b"})

      assert [
               %{rpc: "initialize", authorization: "Bearer token-2"},
               %{rpc: "notifications/initialized", session: "session-3"},
               %{
                 method: "DELETE",
                 session: "session-1",
                 authorization: "Bearer token-1",
                 status: 200
               },
               %{rpc: "tools/call", session: "session-3", status: 200}
             ] = requests()

      # A person's is theirs: no credential of the profile's replaces it.
      assert FakeMCP.sessions(context.fake) == %{
               "session-2" => "Bearer ada-token",
               "session-3" => "Bearer token-2"
             }

      assert {:ok, _} = Client.call_tool(renewed, "search", %{"topic" => "c"})
      assert [%{rpc: "tools/call", session: "session-3", status: 200}] = requests()
      :ok = GenServer.stop(holder)
    end

    test "the session ends at the server when the local session stops", context do
      %{session: session} = with_server(context)
      wait_for_state(session.id, "notes", [:ready])
      assert Map.keys(FakeMCP.sessions(context.fake)) == ["session-1"]

      :ok = Troupe.stop_session(session.id)

      assert_receive {:fake_mcp, %{method: "DELETE", session: "session-1", status: 200} = ended},
                     5_000

      assert ended.version == FakeMCP.version()
      assert FakeMCP.sessions(context.fake) == %{}
    end

    @tag fake: [delete: :not_allowed]
    test "a server that will not end a session is let be", context do
      %{session: session} = with_server(context)
      wait_for_state(session.id, "notes", [:ready])

      assert :ok = Troupe.stop_session(session.id)
      assert_receive {:fake_mcp, %{method: "DELETE", session: "session-1", status: 405}}, 5_000
    end

    test "two credentials are two sessions, each kept and reused", context do
      {:ok, holder} = Sessions.start_link()
      server = %Server{name: "notes", url: context.fake.url, sessions: Sessions.table(holder)}
      profile = %{server | credential: "profile-token"}
      person = %{server | credential: "ada-token", credential_mode: :person}

      assert {:ok, [%{"name" => "search"}]} = Client.list_tools(profile)
      assert {:ok, _} = Client.call_tool(person, "search", %{"topic" => "a"})
      assert {:ok, _} = Client.call_tool(profile, "search", %{"topic" => "b"})
      assert {:ok, _} = Client.call_tool(person, "search", %{"topic" => "c"})

      # The fake refuses a session presented with another credential than it was opened
      # with, so a mix-up would have failed above.
      assert FakeMCP.sessions(context.fake) == %{
               "session-1" => "Bearer profile-token",
               "session-2" => "Bearer ada-token"
             }

      assert requests() |> Enum.filter(&(&1.rpc == "initialize")) |> length() == 2

      # Ended with the credential each was opened with; a person's is not kept for it.
      :ok = GenServer.stop(holder)

      assert_received {:fake_mcp,
                       %{
                         method: "DELETE",
                         session: "session-1",
                         authorization: "Bearer profile-token"
                       }}

      refute_received {:fake_mcp, %{method: "DELETE", session: "session-2"}}
    end

    test "a server tried outside any session gets a session for the one request", context do
      record = %{
        name: "notes",
        layer: :user,
        source: "mcp.json",
        config: %{url: context.fake.url}
      }

      assert %{state: :ready, tools: ["search"]} = MCP.probe(record, context.workspace)

      assert [
               %{rpc: "initialize", status: 200},
               %{rpc: "notifications/initialized", session: "session-1"},
               %{rpc: "tools/list", session: "session-1", status: 200},
               %{method: "DELETE", session: "session-1", status: 200}
             ] = requests()

      assert FakeMCP.sessions(context.fake) == %{}
    end
  end

  describe "a server that keeps none" do
    @describetag fake: [stateful: false]

    test "is called without a session once the handshake is done", context do
      %{session: session} = with_server(context)
      wait_for_state(session.id, "notes", [:ready])

      assert {:ok, "three notes on kites"} =
               Tool.invoke(tool(session.id), %{"topic" => "kites"}, ctx(session, context))

      assert [
               %{rpc: "initialize", status: 200},
               %{rpc: "notifications/initialized", session: nil},
               %{rpc: "tools/list", session: nil, status: 200},
               %{rpc: "tools/call", session: nil, status: 200}
             ] = requests()

      :ok = Troupe.stop_session(session.id)
      refute_receive {:fake_mcp, %{method: "DELETE"}}, 200
    end
  end

  defp wait_for_state(session_id, name, states, waited \\ 0) do
    entry = Enum.find(MCP.status(session_id), &(&1.name == name))

    cond do
      entry && entry.state in states -> entry
      waited > 10_000 -> flunk("#{name} never reached #{inspect(states)}: #{inspect(entry)}")
      true -> Process.sleep(50) && wait_for_state(session_id, name, states, waited + 50)
    end
  end

  defp tool(session_id),
    do: Enum.find(MCP.tools(session_id), &(Tool.name(&1) == "mcp.notes.search"))

  defp ctx(session, context) do
    %Troupe.Tool.Ctx{
      session_id: session.id,
      agent_path: ["root"],
      workspace: Workspace.new!(context.workspace),
      call_id: "call-1",
      agent_pid: self()
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
