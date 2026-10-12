Code.require_file("../support/fake_oauth.exs", __DIR__)

defmodule Troupe.MCPOAuthAddressTest do
  @moduledoc """
  Every URL the daemon calls for a person's own MCP server and its sign-in is held to one
  rule (Decision 875, issue #618): the server's URL, the protected-resource and
  authorization-server metadata, the authorization, token and revocation endpoints. A
  name is resolved, every address it answers is checked against Decision 856's list, and
  the request goes to the address that was checked. Loopback and the private ranges stay
  allowed. Against `test/support/fake_oauth.exs` on loopback, with `:mcp_resolver`
  standing in for DNS.
  """

  # The resolver stand-in is the application environment's, which is the whole VM's.
  use Troupe.SessionCase, async: false

  alias Troupe.MCP.OAuth
  alias Troupe.Session.MCP
  alias Troupe.Test.FakeOAuth

  @moduletag timeout: 60_000
  @moduletag :capture_log

  setup context do
    fake = FakeOAuth.start(self(), Map.get(context, :fake, []))

    on_exit(fn ->
      FakeOAuth.stop(fake)
      Application.delete_env(:troupe_protocol, :mcp_resolver)
    end)

    Map.put(context, :fake, fake)
  end

  # A stand-in for DNS: `answers` by name, a list for each lookup in turn, the last one
  # repeated; every lookup is sent to the test. A name it does not know answers nothing.
  defp resolver(answers) do
    test = self()
    {:ok, counter} = Agent.start(fn -> %{} end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Application.put_env(:troupe_protocol, :mcp_resolver, fn host ->
      send(test, {:looked_up, host})
      turns = Map.get(answers, host, [[]])

      n =
        Agent.get_and_update(
          counter,
          &{Map.get(&1, host, 0), Map.update(&1, host, 1, fn n -> n + 1 end)}
        )

      Enum.at(turns, n, List.last(turns))
    end)
  end

  defp lookups(host, count \\ 0) do
    receive do
      {:looked_up, ^host} -> lookups(host, count + 1)
    after
      0 -> count
    end
  end

  defp config(extra \\ %{}) do
    {:ok, config} = OAuth.config(Map.merge(%{"client_id" => FakeOAuth.client_id()}, extra))
    config
  end

  defp sign_in(context, url \\ nil, extra \\ %{}),
    do:
      OAuth.sign_in("notes", url || context.fake.mcp_url, config(extra),
        state_dir: context.state_dir
      )

  defp requests do
    receive do
      {:fake_oauth, request} -> [request | requests()]
    after
      0 -> []
    end
  end

  @metadata [{169, 254, 169, 254}]

  describe "reproduction" do
    @tag fake: [token_endpoint: "https://token.example.test/tenant/token"]
    test "a token endpoint named to a metadata address is refused, and never called", context do
      resolver(%{"token.example.test" => [@metadata]})

      assert sign_in(context) ==
               {:error,
                "the token endpoint (https://token.example.test/tenant/token) resolves to " <>
                  "169.254.169.254, a link-local address"}

      # A sign-in kept from before refreshes there no more either.
      entry = %{
        "refresh_token" => "a-refresh-token",
        "token_endpoint" => "https://token.example.test/tenant/token",
        "client_id" => FakeOAuth.client_id()
      }

      assert OAuth.refresh(entry) ==
               {:error,
                "the token endpoint (https://token.example.test/tenant/token) resolves to " <>
                  "169.254.169.254, a link-local address"}
    end
  end

  describe "every URL of a sign-in, by a name resolving to a metadata address" do
    test "the server's url", context do
      resolver(%{"notes.example.test" => [[{0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}]]})

      assert sign_in(context, "https://notes.example.test/mcp") ==
               {:error,
                "the server's url (https://notes.example.test/mcp) resolves to fd00:ec2::254, " <>
                  "a cloud metadata address"}

      assert requests() == []
    end

    @tag fake: [
           challenge_metadata:
             "https://resource.example.test/.well-known/oauth-protected-resource"
         ]
    test "the protected-resource metadata the server's 401 names", context do
      resolver(%{"resource.example.test" => [[{100, 100, 100, 200}]]})

      assert sign_in(context) ==
               {:error,
                "the resource metadata (https://resource.example.test/.well-known/oauth-protected-resource) " <>
                  "resolves to 100.100.100.200, a cloud metadata address"}
    end

    test "the authorization server's metadata", context do
      resolver(%{"login.example.test" => [[{0, 0, 0, 0}]]})

      assert sign_in(context, nil, %{"issuer" => "https://login.example.test/tenant"}) ==
               {:error,
                "the authorization server's metadata " <>
                  "(https://login.example.test/.well-known/oauth-authorization-server/tenant) " <>
                  "resolves to 0.0.0.0, the unspecified address"}
    end

    @tag fake: [authorization_endpoint: "https://login.example.test/authorize"]
    test "the authorization endpoint, which the browser opens", context do
      resolver(%{"login.example.test" => [@metadata]})

      assert sign_in(context) ==
               {:error,
                "the authorization endpoint (https://login.example.test/authorize) resolves to " <>
                  "169.254.169.254, a link-local address"}
    end

    @tag fake: [authorization_endpoint: "https://login.example.test/authorize"]
    test "an authorization endpoint that does not resolve here is left to the browser", context do
      resolver(%{})

      assert {:ok, %{url: "https://login.example.test/authorize?" <> _}} = sign_in(context)
    end

    @tag fake: [revocation_endpoint: "https://revoke.example.test/revoke"]
    test "the revocation endpoint", context do
      resolver(%{"revoke.example.test" => [@metadata]})
      {:ok, started} = sign_in(context)
      {200, _page} = FakeOAuth.browse(started.url)
      binding = OAuth.binding("notes", context.fake.mcp_url, config(), context.state_dir)

      assert {:ok, %{state: :failed, reason: reason}} = OAuth.sign_out(binding)

      assert reason ==
               "the revocation endpoint (https://revoke.example.test/revoke) resolves to " <>
                 "169.254.169.254, a link-local address"

      refute Enum.any?(requests(), &(&1.path == "/revoke"))
    end

    test "a server a local session calls" do
      # A person's own server without a sign-in, through `Troupe.Session.MCP`.
      resolver(%{"notes.example.test" => [@metadata]})

      assert %{state: :error, error: error} =
               MCP.probe(
                 %{
                   name: "notes",
                   config: %{url: "https://notes.example.test/mcp"},
                   layer: :user,
                   source: nil
                 },
                 nil
               )

      assert error ==
               "notes.example.test resolves to 169.254.169.254, a link-local address, and is not called"
    end
  end

  describe "the request goes to the address that was checked" do
    test "a token endpoint that answers loopback to the check and a metadata address after is asked once",
         context do
      resolver(%{"localhost" => [[{127, 0, 0, 1}], @metadata]})

      entry = %{
        "refresh_token" => "a-refresh-token",
        "token_endpoint" => "http://localhost:#{context.fake.port}/tenant/token",
        "client_id" => FakeOAuth.client_id()
      }

      # The fake took it, and refused a refresh token it never issued.
      assert OAuth.refresh(entry) == {:error, :invalid_grant}
      assert [%{path: "/tenant/token", headers: %{"host" => host}}] = requests()
      assert host == "localhost:#{context.fake.port}"
      assert lookups("localhost") == 1

      assert {:error, "the token endpoint (http://localhost:" <> _ = refused} =
               OAuth.refresh(entry)

      assert refused =~ "resolves to 169.254.169.254, a link-local address"
      assert requests() == []
    end

    @tag fake: [host: "localhost"]
    test "a server on loopback still signs in, by name", context do
      resolver(%{"localhost" => [[{127, 0, 0, 1}]]})

      assert {:ok, started} = sign_in(context)

      assert String.starts_with?(
               started.url,
               "http://localhost:#{context.fake.port}/tenant/authorize?"
             )

      assert {200, _page} = FakeOAuth.browse(started.url)

      binding = OAuth.binding("notes", context.fake.mcp_url, config(), context.state_dir)
      assert %{state: :signed_in, account: "ada@example.test"} = OAuth.status(binding)

      paths = Enum.map(requests(), & &1.path)
      assert "/tenant/token" in paths
      assert lookups("localhost") > 0
    end

    test "a private address is allowed: an intranet's authorization server is there" do
      resolver(%{
        "login.intranet.example.test" => [[{10, 1, 2, 3}]],
        "fc.example.test" => [[{0xFD12, 0, 0, 0, 0, 0, 0, 1}]]
      })

      assert :ok =
               OAuth.outbound("https://login.intranet.example.test/token", "the token endpoint")

      assert :ok = OAuth.outbound("https://fc.example.test/token", "the token endpoint")
      assert :ok = OAuth.outbound("https://172.16.4.5/token", "the token endpoint")
      assert :ok = OAuth.outbound("https://192.168.1.1/token", "the token endpoint")
    end

    test "a name that resolves to nothing is not sent a token" do
      resolver(%{})

      assert OAuth.outbound("https://gone.example.test/token", "the token endpoint") ==
               {:error,
                "the token endpoint (https://gone.example.test/token) does not resolve (nxdomain)"}
    end
  end
end
