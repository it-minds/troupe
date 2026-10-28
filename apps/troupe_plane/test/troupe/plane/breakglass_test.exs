defmodule Troupe.Plane.BreakglassTest do
  @moduledoc """
  The break-glass door as an API: `POST /auth/breakglass`, and the plane token it answers.

  What is proved is the contract a client builds against. Discovery says whether the door
  exists; a door that is not configured is a 404 like any other path; a wrong token is
  refused and recorded with its address; and the token a right one answers is a platform
  admin at `/rpc` and `/mcp` that says it is break-glass, until it expires. A person's
  token and a principal's are not marked, and the token administers and no more.

  Against the router directly rather than a socket: the bearer header, the status and the
  body are what matter, and `Plug.Test` carries all three. Minting needs the development
  OpenBao, as every token on the plane does.
  """

  use Troupe.Plane.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Troupe.Plane.{Audit, Breakglass, Tokens}
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.Token

  @moduletag timeout: 60_000

  @token "a-break-glass-token-for-tests"

  setup do
    on_exit(fn -> Application.delete_env(:troupe_plane, :breakglass) end)
    :ok
  end

  describe "discovery" do
    test "says whether the door exists" do
      assert {200, %{"breakglass" => false}} = get_json("/.well-known/troupe")

      configure()
      assert {200, %{"breakglass" => true}} = get_json("/.well-known/troupe")
    end
  end

  describe "the door" do
    test "is not there at all without a token configured" do
      assert {404, nil} = open(@token)
      assert {404, nil} = open(nil)
      assert door_events() == []
    end

    test "refuses a wrong token in one word, and records who tried" do
      configure()

      assert {403, %{"error" => "refused"}} = open("not-the-token")
      assert {403, %{"error" => "refused"}} = open(nil)

      assert [%{"outcome" => "refused", "address" => "127.0.0.1"}, %{"outcome" => "refused"}] =
               Enum.map(door_events(), & &1.detail)
    end

    test "answers a plane token that is a platform admin and says it is break-glass" do
      configure()
      now = System.system_time(:second)

      assert {200, %{"token" => token, "expires_at" => expires_at, "subject" => "breakglass"}} =
               open(@token)

      assert [%{actor: "breakglass", action: "admin.breakglass", detail: detail}] = door_events()
      assert detail == %{"outcome" => "granted", "address" => "127.0.0.1"}

      # ISO 8601, UTC, and no further out than the protocol lets any plane token be.
      assert {:ok, expires, 0} = DateTime.from_iso8601(expires_at)
      assert DateTime.to_unix(expires) > now
      assert DateTime.to_unix(expires) <= now + Token.max_lifetime_seconds() + 1

      {:ok, jwks} = Tokens.jwks()
      assert {:ok, claims} = Token.verify(token, jwks, audience: Router.plane_audience())
      assert claims["breakglass"] == true
      assert claims["sub"] == "breakglass"

      # An admin method over `/rpc`, as a platform admin.
      assert {200, %{"result" => teams}} = rpc(token, "admin.teams.list")
      assert is_list(teams)

      assert {200, %{"result" => me}} = rpc(token, "me")
      assert me["breakglass"] == true
      assert me["platform_admin"] == true
      assert me["subject"] == "breakglass"
      assert me["kind"] == "breakglass"
      assert me["teams"] == []
      assert me["profiles"] == []

      # And the same at `/mcp`, through the same actor.
      assert {200, %{"result" => result}} =
               post_json(
                 "/mcp",
                 %{
                   "jsonrpc" => "2.0",
                   "id" => 1,
                   "method" => "tools/call",
                   "params" => %{"name" => "admin_teams_list", "arguments" => %{}}
                 },
                 [{"authorization", "Bearer " <> token}]
               )

      refute result["isError"] == true
    end

    test "lasts the configured lifetime, and never longer than any plane token may" do
      configure(lifetime_seconds: 120)
      now = System.system_time(:second)

      assert {200, %{"expires_at" => expires_at}} = open(@token)
      assert {:ok, expires, 0} = DateTime.from_iso8601(expires_at)
      assert_in_delta DateTime.to_unix(expires), now + 120, 2

      configure(lifetime_seconds: 24 * 3600)
      assert Breakglass.lifetime_seconds() == Token.max_lifetime_seconds()
    end

    test "administers and no more: the harness refuses it everywhere but me" do
      configure()
      assert {200, %{"token" => token}} = open(@token)

      assert {200, %{"error" => %{"message" => "forbidden"}}} = rpc(token, "session.list")
      assert {200, %{"error" => %{"message" => "forbidden"}}} = rpc(token, "memory.get")
      assert {200, %{"result" => %{"breakglass" => true}}} = rpc(token, "me")

      assert {403, %{"error" => "forbidden"}} =
               post_json(
                 "/mcp/session",
                 %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"},
                 [{"authorization", "Bearer " <> token}]
               )
    end

    test "runs as the subject the deployment named" do
      configure(subject: "ops-on-call")

      assert {200, %{"token" => token, "subject" => "ops-on-call"}} = open(@token)

      assert {200, %{"result" => %{"subject" => "ops-on-call", "breakglass" => true}}} =
               rpc(token, "me")
    end

    test "the token ends when it expires, and nothing refreshes it" do
      configure()

      {:ok, expired, _payload} =
        Tokens.mint(Breakglass.claims("breakglass"),
          audience: Router.plane_audience(),
          lifetime: 60,
          now: System.system_time(:second) - 600
        )

      assert {401, %{"error" => %{"message" => "unauthenticated"}}} = rpc(expired, "me")
    end

    test "a person's token and a principal's are not marked" do
      configure()

      person = person("ada@example.test")

      {:ok, token, _payload} =
        Tokens.mint(%{"sub" => person.subject}, audience: Router.plane_audience())

      assert {200, %{"result" => me}} = rpc(token, "me")
      assert me["breakglass"] == false
      assert me["platform_admin"] == false

      team = team_with_grant("engineering", "dev", name: "engineering")
      {:ok, principal, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

      {:ok, token, _payload} =
        Tokens.mint(%{"sub" => principal.subject}, audience: Router.plane_audience())

      assert {200, %{"result" => me}} = rpc(token, "me")
      assert me["breakglass"] == false
      assert me["kind"] == "service"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp configure(opts \\ []) do
    Application.put_env(:troupe_plane, :breakglass, Keyword.merge([token: @token], opts))
  end

  defp door_events do
    Audit.list(kind: "admin")
    |> Enum.filter(&(&1.action == "admin.breakglass"))
    |> Enum.sort_by(& &1.occurred_at, DateTime)
  end

  defp open(token), do: post_json("/auth/breakglass", %{"token" => token})

  defp rpc(token, method, params \\ %{}) do
    post_json(
      "/rpc",
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      [{"authorization", "Bearer " <> token}]
    )
  end

  defp call(conn), do: Router.call(conn, Router.init([]))

  defp get_json(path) do
    conn = call(conn(:get, path))
    {conn.status, decode(conn.resp_body)}
  end

  defp post_json(path, body, headers \\ []) do
    conn =
      headers
      |> Enum.reduce(conn(:post, path, Jason.encode!(body)), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)
      |> put_req_header("content-type", "application/json")
      |> call()

    {conn.status, decode(conn.resp_body)}
  end

  defp decode(""), do: nil
  defp decode(body), do: Jason.decode!(body)
end
