defmodule Troupe.RemoteTransportTest do
  @moduledoc """
  A plane speaks either a WebSocket or JSON-RPC over `POST`, and says which in
  its discovery document. The deployment this client was developed against does
  the latter, so both are exercised here against the same FakeRemote.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers, only: [eventually: 1]

  alias Troupe.Client
  alias Troupe.FakeRemote
  alias Troupe.Remote.{Discovery, RPC, Tokens}

  @moduletag :remote

  defp fixture do
    FakeRemote.session(
      id: "s-http",
      profile: "code",
      title: "over POST",
      events: [%{"type" => "message.completed", "data" => %{"text" => "hello over http"}}]
    )
  end

  describe "a plane that speaks JSON-RPC over POST" do
    test "is discovered as such, and every plane call works over it" do
      {remote, url} = start_remote!(transport: :http, sessions: [fixture()])

      login!(remote, url)
      {:ok, discovery} = Tokens.discovery(Discovery.base(url))
      assert discovery.transport == :http
      assert discovery.rpc_url == Discovery.base(url) <> "/rpc"

      {:ok, origin} = Client.connect_plane(url)
      eventually(fn -> Client.fleet_status(origin).up? end)

      assert {:ok, me} = Client.whoami(origin)
      assert me.sub == "alice"

      assert {:ok, [%{name: "code"}]} = Client.profiles(origin, "core")
      assert {:ok, [session]} = Client.sessions(origin, %{})
      assert session.id == "s-http"

      # …and a session attached through it streams over its worker socket
      sid = attach!(origin, "s-http")
      eventually(fn -> Enum.any?(Client.events(sid), &(&1.type == :assistant_message)) end)

      assert :ok = Client.send_input(sid, "code-1", "and back")
      eventually(fn -> Enum.any?(Client.events(sid), &(&1.type == :input_accepted)) end)
    end

    test "the handshake is `me`, and /rpc is shown the plane token /auth/exchange minted" do
      {remote, url} = start_remote!(transport: :http, sessions: [fixture()])
      login!(remote, url)
      {:ok, origin} = Client.connect_plane(url)
      eventually(fn -> Client.fleet_status(origin).up? end)

      calls = FakeRemote.calls(remote)
      assert Enum.any?(calls, &match?({"auth.exchange", %{"id_token" => _}}, &1))
      refute Enum.any?(calls, &match?({"initialize", _}, &1))

      # the principal comes out of `me`, in the live plane's spelling
      assert %{"sub" => "alice", "name" => "Alice"} = Client.fleet_status(origin).principal
    end

    test "no fleet subscription is attempted: a POST endpoint cannot push" do
      {remote, url} = start_remote!(transport: :http, sessions: [fixture()])
      login!(remote, url)
      {:ok, origin} = Client.connect_plane(url)
      eventually(fn -> Client.fleet_status(origin).up? end)

      :ok = Client.subscribe_fleet(origin)
      Process.sleep(100)

      refute Enum.any?(FakeRemote.calls(remote), &match?({"subscribe", %{"topic" => "fleet"}}, &1))
    end
  end

  describe "a worker endpoint" do
    test "is turned into the socket URL the way the reference clients do it" do
      assert Discovery.worker_url("wss://0-dev.workers.example/v1/socket") ==
               "wss://0-dev.workers.example/v1/socket"

      assert Discovery.worker_url("https://0-dev.workers.example") ==
               "wss://0-dev.workers.example/v1/socket"

      assert Discovery.worker_url("https://0-dev.workers.example/") ==
               "wss://0-dev.workers.example/v1/socket"

      assert Discovery.worker_url("http://127.0.0.1:4100/worker/w1") ==
               "ws://127.0.0.1:4100/worker/w1"

      assert Discovery.worker_url("0-dev.workers.example") ==
               "wss://0-dev.workers.example/v1/socket"
    end
  end

  describe "the live plane's error shape" do
    test "an unauthenticated -32003 is treated as a token problem, not a missing scope" do
      no_token = %{code: -32_003, message: "unauthenticated", data: %{"reason" => "no_token"}}

      bad_signature = %{
        code: -32_003,
        message: "unauthenticated",
        data: %{"reason" => "bad_signature"}
      }

      no_scope = %{code: -32_003, message: "control scope required", data: %{"scope" => "control"}}

      assert RPC.reason(no_token) == :unauthorized
      assert RPC.reason(bad_signature) == :unauthorized
      assert RPC.reason(no_scope) == :forbidden

      assert RPC.describe(no_token) =~ "signed out"
      assert RPC.describe(no_scope) =~ "needs the control scope"
    end

    test "the contract's codes keep their meanings" do
      assert RPC.reason(%{code: -32_001}) == :unauthorized
      assert RPC.reason(%{code: -32_004}) == :not_found
      assert RPC.reason(%{code: -32_009}) == :conflict
      assert RPC.reason(%{code: -32_010}) == :no_capacity
      assert RPC.reason(%{code: -32_012}) == :session_moved
      assert RPC.reason(%{code: -32_099}) == {:rpc, -32_099}
    end
  end
end
