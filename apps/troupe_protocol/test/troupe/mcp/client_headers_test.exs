Code.require_file("../../../../troupe_core/test/support/fake_mcp.exs", __DIR__)

defmodule Troupe.MCP.ClientHeadersTest do
  @moduledoc """
  The headers a server's entry names (Decision 820) go out on every request to it, as
  they are: the handshake's `initialize` and `notifications/initialized`, the listing, a
  call and the `DELETE` that ends the session, against a server on loopback that records
  every header of every request (`troupe_core`'s `test/support/fake_mcp.exs`). The
  server's own credential wins over a header of the same name, and neither is in what
  `inspect/1` prints.
  """

  use ExUnit.Case, async: true

  alias Troupe.MCP.{Client, Server, Sessions}
  alias Troupe.Test.FakeMCP

  setup do
    fake = FakeMCP.start(self())
    on_exit(fn -> FakeMCP.stop(fake) end)
    %{fake: fake}
  end

  test "every request carries the entry's headers, the handshake and the session's end too",
       %{fake: fake} do
    {:ok, holder} = Sessions.start_link()

    server =
      Server.from_config(%{
        "name" => "notes",
        "url" => fake.url,
        "headers" => %{"X-Api-Key" => "key-123", "X-Tenant" => "acme"}
      })
      |> Map.put(:sessions, Sessions.table(holder))

    assert {:ok, [%{"name" => "search"}]} = Client.list_tools(server)

    assert {:ok, %{"content" => [%{"text" => "three notes on trains"}]}} =
             Client.call_tool(server, "search", %{"topic" => "trains"})

    GenServer.stop(holder)

    requests = drain()

    assert Enum.map(requests, &(&1.rpc || &1.method)) ==
             ["initialize", "notifications/initialized", "tools/list", "tools/call", "DELETE"]

    for request <- requests do
      assert request.headers["x-api-key"] == "key-123", "#{request.rpc || request.method}"
      assert request.headers["x-tenant"] == "acme"
    end

    assert Enum.all?(requests, &(&1.status in [200, 202]))
  end

  test "the server's credential wins over a header of the same name, sent once", %{fake: fake} do
    server =
      Server.from_config(%{
        "name" => "notes",
        "url" => fake.url,
        "credential" => "the-token",
        "headers" => %{"Authorization" => "Bearer from-the-file", "X-Tenant" => "acme"}
      })

    assert {:ok, _tools} = Client.list_tools(server)

    for request <- drain() do
      assert request.headers["authorization"] == "Bearer the-token"
      assert request.headers["x-tenant"] == "acme"
    end

    assert Server.headers(server) == [{"X-Tenant", "acme"}, {"authorization", "Bearer the-token"}]
  end

  test "a header's value is not in what inspect prints" do
    server =
      Server.from_config(%{
        "name" => "notes",
        "url" => "http://127.0.0.1:1/mcp",
        "headers" => %{"X-Api-Key" => "key-123"}
      })

    refute inspect(server) =~ "key-123"
  end

  defp drain(acc \\ []) do
    receive do
      {:fake_mcp, request} -> drain([request | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end
end
