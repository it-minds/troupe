defmodule Troupe.Plane.MCPAuthTest do
  @moduledoc """
  How a remote MCP client gets in.

  Two kinds of caller reach `/mcp`. `troupe mcp` bridges a plane token, because the CLI
  already holds credentials. Anything else — an editor, a desktop client — does OAuth
  against the identity provider and arrives with the provider's own token, because there
  is no step in that flow where it could obtain a plane token.

  What is tested here is the part a client depends on before it has any credential at all:
  that an unauthenticated call says *where to authenticate* rather than only no, and that
  the document it points at names the provider and a scope that will produce a token this
  plane accepts. Get that wrong and the failure is a client that cannot start, with no
  diagnostic beyond a 401.
  """

  use Troupe.Plane.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Troupe.Plane.Web.Router

  @issuer "https://login.example.test/9c5b/v2.0"
  @client "b18faeb7-ad28-4e80-bcd7-ec540c9b8c8e"

  setup do
    previous = Application.get_env(:troupe_plane, :oidc)
    base = Application.get_env(:troupe_plane, :base_url)

    Application.put_env(:troupe_plane, :oidc, issuer: @issuer, client_id: @client)
    Application.put_env(:troupe_plane, :base_url, "https://troupe.example.test")

    on_exit(fn ->
      Application.put_env(:troupe_plane, :oidc, previous)

      if base,
        do: Application.put_env(:troupe_plane, :base_url, base),
        else: Application.delete_env(:troupe_plane, :base_url)
    end)

    :ok
  end

  defp call(conn), do: Router.call(conn, Router.init([]))

  defp metadata(path) do
    conn = call(conn(:get, path))
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  describe "finding out where to authenticate" do
    test "an unauthenticated tool call points at the metadata rather than only refusing" do
      conn =
        call(
          conn(:post, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}))
          |> put_req_header("content-type", "application/json")
        )

      assert conn.status == 401

      [header] = get_resp_header(conn, "www-authenticate")
      assert header =~ ~s(Bearer realm="troupe-plane")

      assert header =~
               ~s(resource_metadata="https://troupe.example.test/.well-known/oauth-protected-resource")
    end

    test "the metadata is served at both the paths a client may derive" do
      # A client that has the resource URL inserts the well-known segment before the path;
      # one that has only the origin asks for the bare path. Neither should be told there
      # is no metadata.
      assert metadata("/.well-known/oauth-protected-resource") ==
               metadata("/.well-known/oauth-protected-resource/mcp")
    end

    test "it names this plane's MCP endpoint, the provider, and a scope worth asking for" do
      document = metadata("/.well-known/oauth-protected-resource")

      assert document["resource"] == "https://troupe.example.test/mcp"
      assert document["authorization_servers"] == [@issuer]
      assert document["bearer_methods_supported"] == ["header"]

      # Not a bare `openid`: that produces an access token addressed to the provider's own
      # directory API, which this plane refuses. And `offline_access`, so the client is
      # given a refresh token rather than sending the operator back to a browser in an hour.
      assert "offline_access" in document["scopes_supported"]
    end

    test "the scope is named after the resource, because that is what a client must send" do
      document = metadata("/.well-known/oauth-protected-resource")

      # MCP obliges a client to send RFC 8707's `resource` set to the server's canonical
      # URI, and a provider checks it against the resource the scopes belong to. A scope
      # under any other name is a pair the provider refuses — Entra says AADSTS9010010 —
      # and the failure lands in a browser, after consent, where it reads as the client's
      # fault.
      assert document["scopes_supported"] == [document["resource"] <> "/admin", "offline_access"]
    end

    test "a registration that exposes it elsewhere can say so" do
      oidc = Application.get_env(:troupe_plane, :oidc)

      Application.put_env(
        :troupe_plane,
        :oidc,
        Keyword.put(oidc, :mcp_scope, "api://other/admin")
      )

      on_exit(fn -> Application.put_env(:troupe_plane, :oidc, oidc) end)

      document = metadata("/.well-known/oauth-protected-resource")
      assert document["scopes_supported"] == ["api://other/admin", "offline_access"]
    end
  end

  describe "which tokens the door takes" do
    test "a token addressed to the client id is this plane's caller" do
      assert @client in Troupe.Plane.OIDC.audiences()
    end

    test "so is one addressed to the API that client exposes" do
      # An id_token is addressed to the client; an access token for a scope the client
      # exposes is addressed to the API. Which of the two a client holds is not something
      # the client chooses, so refusing either would refuse the client.
      assert "api://#{@client}" in Troupe.Plane.OIDC.audiences()
    end

    test "so is one addressed to the endpoint's own URL" do
      # The third identifier URI of the same registration. Which name an access token
      # carries depends on the provider and on the name the client asked under, neither of
      # which the caller chooses.
      assert "https://troupe.example.test/mcp" in Troupe.Plane.OIDC.audiences()
    end

    test "and nothing else" do
      refute "https://graph.microsoft.com" in Troupe.Plane.OIDC.audiences()
      assert length(Troupe.Plane.OIDC.audiences()) == 3
    end

    test "a plane with no client configured accepts no provider token at all" do
      Application.put_env(:troupe_plane, :oidc, issuer: @issuer)
      assert Troupe.Plane.OIDC.audiences() == []
    end

    test "a garbled token is refused, not crashed on" do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

      conn =
        conn(:post, "/mcp", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer not-a-jwt")
        |> call()

      assert conn.status == 401
    end
  end
end
