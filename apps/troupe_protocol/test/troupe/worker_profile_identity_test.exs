defmodule Troupe.WorkerProfileIdentityTest do
  @moduledoc """
  A profile's own identity at the MCP servers its bundle calls with client credentials
  (Decision 747), as the operator, the plane and the worker all read it: one parser, one
  list of what is wrong, and the token endpoints counted as egress.
  """

  use ExUnit.Case, async: true

  alias Troupe.MCP.Server
  alias Troupe.WorkerProfile
  alias Troupe.WorkerProfile.MCPIdentity

  @thumbprint "u9Y2ZbqDkFCLWHVUkWNrN7aQHqVZFEO3hxTXrpXDAjg"

  defp resource(spec) do
    %{"metadata" => %{"name" => "dev"}, "spec" => Map.put(spec, "image", %{"repository" => "w"})}
  end

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        "server" => "jira",
        "clientId" => "00000000-0000-0000-0000-000000000001",
        "scope" => "api://jira/.default",
        "tokenUrl" => "https://login.example.com/tenant/oauth2/v2.0/token",
        "transitKey" => "troupe-w-dev.jira",
        "certificateThumbprint" => @thumbprint
      },
      overrides
    )
  end

  defp marked,
    do: %{
      "name" => "jira",
      "url" => "https://mcp.example.com/mcp",
      "credentialMode" => "client_credentials"
    }

  test "is read from mcpIdentities, with RS256 and the latest key version by default" do
    profile = WorkerProfile.from_resource(resource(%{"mcpIdentities" => [identity()]}))

    assert [
             %MCPIdentity{
               server: "jira",
               client_id: "00000000-0000-0000-0000-000000000001",
               scope: "api://jira/.default",
               transit_key: "troupe-w-dev.jira",
               key_version: nil,
               thumbprint: @thumbprint,
               algorithm: "RS256"
             }
           ] = profile.mcp_identities

    # And back into the resource's spelling, which is what the pod's file holds.
    assert MCPIdentity.to_spec(hd(profile.mcp_identities)) ==
             Map.put(identity(), "algorithm", "RS256")
  end

  test "takes a thumbprint as openssl prints it and keeps it as x5t#S256 carries it" do
    hex =
      @thumbprint
      |> Base.url_decode64!(padding: false)
      |> Base.encode16()
      |> String.graphemes()
      |> Enum.chunk_every(2)
      |> Enum.map_join(":", &Enum.join/1)

    assert MCPIdentity.thumbprint(hex) == @thumbprint
    assert MCPIdentity.thumbprint(String.downcase(String.replace(hex, ":", ""))) == @thumbprint
  end

  test "a server marked client_credentials with no identity is a problem, and a complete one is none" do
    without = WorkerProfile.from_resource(resource(%{"mcpServers" => [marked()]}))
    assert [problem] = WorkerProfile.identity_problems(without)
    assert problem =~ "mcp server jira is called with client credentials"

    with_one =
      WorkerProfile.from_resource(
        resource(%{"mcpServers" => [marked()], "mcpIdentities" => [identity()]})
      )

    assert WorkerProfile.identity_problems(with_one) == []
  end

  test "an identity without its client or its key, or with a broken field, says which" do
    broken =
      identity(%{
        "clientId" => nil,
        "transitKey" => "",
        "certificateThumbprint" => "not-a-thumbprint",
        "algorithm" => "HS256",
        "keyVersion" => 0,
        "tokenUrl" => "http://login.example.com/token"
      })

    problems =
      resource(%{"mcpServers" => [marked()], "mcpIdentities" => [broken]})
      |> WorkerProfile.from_resource()
      |> WorkerProfile.identity_problems()
      |> Enum.join("\n")

    assert problems =~ "no clientId"
    assert problems =~ "no transitKey"
    assert problems =~ "certificateThumbprint is not a SHA-256 thumbprint"
    assert problems =~ ~s(algorithm "HS256" is not RS256 or PS256)
    assert problems =~ "keyVersion is not a version number"
    assert problems =~ "tokenUrl is not an https URL"
  end

  test "a token endpoint is egress the policy has to allow" do
    profile = WorkerProfile.from_resource(resource(%{"mcpIdentities" => [identity()]}))
    assert "login.example.com" in WorkerProfile.egress_destinations(profile)
  end

  test "a server called with client credentials resolves no credential of its own" do
    System.put_env("TROUPE_TEST_IDENTITY_TOKEN", "would-be-a-static-token")
    on_exit(fn -> System.delete_env("TROUPE_TEST_IDENTITY_TOKEN") end)

    server =
      Server.from_config(%{
        "name" => "jira",
        "url" => "https://mcp.example.com/mcp",
        "credential_mode" => "client_credentials",
        "credential_ref" => "TROUPE_TEST_IDENTITY_TOKEN"
      })

    assert server.credential_mode == :client_credentials
    assert server.credential == nil
    assert Server.headers(server) == []
  end
end
