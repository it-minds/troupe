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

  describe "the contract's errors" do
    # The table is PROTOCOL.md's own, read from the page: a code added there and not
    # here fails, and so does one this client reads differently.
    test "every code in PROTOCOL.md §10 is read as the token the contract gives it" do
      contract = protocol_errors()
      assert {-32_006, "conflict"} in contract

      for {code, token} <- contract do
        assert RPC.reason(%{code: code}) == String.to_atom(token), "#{code} is `#{token}`"
      end

      assert RPC.codes() == Map.new(contract, fn {code, token} -> {code, String.to_atom(token)} end)
      assert RPC.reason(%{code: -32_099}) == {:rpc, -32_099}
    end

    test "-32003 is a token problem and -32004 a missing scope, whatever `data` says" do
      no_token = %{code: -32_003, message: "unauthenticated", data: %{"reason" => "no_token"}}
      expired = %{code: -32_003, message: "unauthenticated", data: %{"reason" => "expired"}}

      no_scope = %{
        code: -32_004,
        message: "forbidden",
        data: %{"required_scope" => "control"}
      }

      assert RPC.reason(no_token) == :unauthenticated
      assert RPC.reason(expired) == :unauthenticated
      assert RPC.reason(no_scope) == :forbidden

      assert RPC.describe(no_token) == "signed out: no_token"
      assert RPC.describe(no_scope) == "not allowed (needs the control scope)"

      # Section 10 spells it `required_scope`, and nothing sends the older `scope`.
      old_spelling = %{code: -32_004, message: "forbidden", data: %{"scope" => "control"}}
      assert RPC.describe(old_spelling) == "not allowed"
    end

    test "what went wrong is said with why, not as the bare token" do
      conflict = %{
        code: -32_006,
        message: "conflict",
        data: %{"reason" => "watch is exclusive per workspace"}
      }

      assert RPC.describe(conflict) == "conflict: watch is exclusive per workspace"
      assert RPC.describe(%{code: -32_006, message: "conflict", data: nil}) == "conflict"

      unavailable = %{
        code: -32_010,
        message: "unavailable",
        data: %{"reason" => "no capacity", "component" => "pod"}
      }

      assert RPC.describe(unavailable) == "unavailable: pod: no capacity"

      too_large = %{code: -32_012, message: "payload_too_large", data: %{"limit" => 1_048_576}}
      assert RPC.describe(too_large) == "payload_too_large"

      # A server that words its message itself keeps its words.
      assert RPC.describe(%{code: -32_005, message: "no such session", data: nil}) ==
               "not found: no such session"
    end
  end

  defp protocol_errors do
    [_before, section] =
      [File.cwd!(), "..", "..", "PROTOCOL.md"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n## 10. Errors\n")

    [section | _rest] = String.split(section, "\n## ")

    for [_row, code, token] <- Regex.scan(~r/^\| (-\d+) \| `([a-z_]+)` \|/m, section),
        do: {String.to_integer(code), token}
  end
end
