defmodule Troupe.Plane.WebTest do
  @moduledoc """
  The plane's HTTP surface.

  Everything a person's client does goes through `/rpc`, and everything `/rpc` does goes
  through `Troupe.Plane.Harness` — which is the "any client, including our own, uses
  nothing but public APIs" rule made structural rather than remembered. These tests are
  against a real server over a real socket, because the parts that matter are the ones
  a unit test of the router would skip: the bearer header, the status code, the shape of
  a JSON-RPC error.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Bundles, Fleet, Identity, OIDC, Sessions, Tokens}
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.Token

  @moduletag timeout: 60_000

  setup do
    {:ok, listener} = start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})
    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    Application.put_env(:troupe_plane, :oidc,
      issuer: "https://issuer.example.test",
      client_id: "troupe-cli",
      device_authorization_endpoint: "https://issuer.example.test/device",
      token_endpoint: "https://issuer.example.test/token"
    )

    Application.put_env(:troupe_plane, :oidc_verifier, &fake_verify/1)
    Application.put_env(:troupe_plane, :scim_token, "scim-secret")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :oidc)
      Application.delete_env(:troupe_plane, :oidc_verifier)
      Application.delete_env(:troupe_plane, :scim_token)
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  describe "discovery" do
    test "says where to log in and what to call this plane", context do
      assert {:ok, %{status: 200, body: body}} = get(context, "/.well-known/troupe")

      assert body["issuer"] == "https://issuer.example.test"
      assert body["client_id"] == "troupe-cli"
      assert body["device_authorization_endpoint"] =~ "/device"
      assert body["plane"]["rpc"] == "/rpc"
      assert body["plane"]["protocol_version"] == Troupe.Protocol.version()
    end

    test "publishes the keys workers verify session tokens against", context do
      assert {:ok, %{status: 200, body: body}} = get(context, "/.well-known/jwks.json")
      assert [key | _] = body["keys"]
      assert key["kty"] == "EC"
      refute Map.has_key?(key, "d")
    end

    test "is alive", context do
      assert {:ok, %{status: 200, body: %{"ok" => true}}} = get(context, "/healthz")
    end
  end

  describe "logging in" do
    test "a provider token becomes a plane token, and the identity it implies", context do
      _team = team_with_grant("engineering", "dev", name: "engineering")

      assert {:ok, %{status: 200, body: body}} =
               post(context, "/auth/exchange", %{"id_token" => "good:ada@example.test:engineering"})

      assert body["subject"] == "ada@example.test"
      assert body["teams"] == ["engineering"]
      assert body["profiles"] == ["dev"]
      assert is_binary(body["token"])
      assert body["expires_at"] > System.system_time(:second)

      # The token is for the plane, not for a pod: presenting it to a worker fails on
      # audience, which is the point of the audience being there.
      {:ok, jwks} = Tokens.jwks()
      assert {:ok, _} = Token.verify(body["token"], jwks, audience: OIDC.audience())
      assert {:error, :wrong_audience} = Token.verify(body["token"], jwks, audience: "worker-dev-0")
    end

    test "a token the provider does not vouch for is refused", context do
      assert {:ok, %{status: 401, body: body}} =
               post(context, "/auth/exchange", %{"id_token" => "forged"})

      assert body["error"] == "unauthenticated"
    end
  end

  describe "the harness API" do
    test "answers what the user may see, and nothing else", context do
      team = team_with_grant("engineering", "dev", name: "engineering")
      ada = person("ada@example.test", ["engineering"])
      grace = person("grace@example.test", ["engineering"])

      mine = session!("s-mine", ada, team)
      hidden = session!("s-hidden", grace, team)

      token = plane_token(context, "ada@example.test", "engineering")

      assert {:ok, %{status: 200, body: body}} = rpc(context, token, "sessions.list", %{})
      ids = body["result"]["sessions"] |> Enum.map(& &1["id"])

      assert mine.id in ids
      refute hidden.id in ids

      assert {:ok, %{status: 200, body: me}} = rpc(context, token, "me", %{})
      assert me["result"]["subject"] == "ada@example.test"
      assert me["result"]["profiles"] == ["dev"]
    end

    test "without a token, nothing", context do
      assert {:ok, %{status: 401, body: body}} = post(context, "/rpc", %{"id" => 1, "method" => "me"})
      assert body["error"]["message"] == "unauthenticated"
    end

    test "an unknown method is a JSON-RPC error, not a 404", context do
      _team = team_with_grant("engineering", "dev", name: "engineering")
      _ada = person("ada@example.test", ["engineering"])
      token = plane_token(context, "ada@example.test", "engineering")

      assert {:ok, %{status: 200, body: body}} = rpc(context, token, "nonsense.list", %{})
      assert body["error"]["message"] == "method_not_found"
      assert body["id"] == 1
    end

    test "a profile listing shows the pods behind it", context do
      _team = team_with_grant("engineering", "dev", name: "engineering")
      _ada = person("ada@example.test", ["engineering"])
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable"})
      {:ok, _} = Bundles.publish("stable", %{"agents" => ["build"]}, announce: false)

      {:ok, _} =
        Fleet.enrol(%{
          profile: "dev",
          namespace: "troupe-w-dev",
          pod_name: "troupe-w-dev-0",
          ordinal: 0,
          capacity: 4,
          disk_total_bytes: 1_000
        })

      token = plane_token(context, "ada@example.test", "engineering")

      assert {:ok, %{status: 200, body: body}} = rpc(context, token, "profiles.list", %{})
      assert [profile] = body["result"]["profiles"]
      assert profile["name"] == "dev"
      assert profile["capacity"] == 4
    end
  end

  describe "SCIM" do
    test "the provider's own credential is what gets in", context do
      user = %{
        "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
        "userName" => "ada@example.test",
        "displayName" => "Ada",
        "emails" => [%{"value" => "ada@example.test", "primary" => true}]
      }

      assert {:ok, %{status: 401}} = post(context, "/scim/v2/Users", user)

      assert {:ok, %{status: 200, body: body}} =
               post(context, "/scim/v2/Users", user, [{"authorization", "Bearer scim-secret"}])

      assert body["userName"] == "ada@example.test"
      assert Identity.get_user("ada@example.test")
    end

    test "a user's own token does not open the SCIM door", context do
      _team = team_with_grant("engineering", "dev", name: "engineering")
      _ada = person("ada@example.test", ["engineering"])
      token = plane_token(context, "ada@example.test", "engineering")

      # A perfectly good plane token, and the wrong credential for this endpoint. SCIM is
      # pushed by the identity provider with its own.
      assert {:ok, %{status: 401}} =
               post(context, "/scim/v2/Users", %{"userName" => "x"}, [{"authorization", "Bearer " <> token}])
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp fake_verify("good:" <> rest) do
    [subject, groups] = String.split(rest, ":", parts: 2)

    {:ok,
     %{
       "sub" => subject,
       "email" => subject,
       "name" => subject,
       "groups" => String.split(groups, ",", trim: true)
     }}
  end

  defp fake_verify(_token), do: {:error, :bad_signature}

  defp plane_token(context, subject, groups) do
    {:ok, %{status: 200, body: body}} =
      post(context, "/auth/exchange", %{"id_token" => "good:#{subject}:#{groups}"})

    body["token"]
  end

  defp session!(id, owner, team) do
    {:ok, session} =
      Sessions.create(%{
        id: id <> "-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        state: "active",
        epoch: 1
      })

    session
  end

  defp get(context, path) do
    Req.request(method: :get, url: context.url <> path, decode_body: true, retry: false)
  end

  defp post(context, path, body, headers \\ []) do
    Req.request(
      method: :post,
      url: context.url <> path,
      json: body,
      headers: headers,
      decode_body: true,
      retry: false
    )
  end

  defp rpc(context, token, method, params) do
    post(context, "/rpc", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}, [
      {"authorization", "Bearer " <> token}
    ])
  end
end
