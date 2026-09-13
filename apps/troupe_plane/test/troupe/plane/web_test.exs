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

  alias Troupe.Plane.{Bundles, Fleet, Identity, OIDC, Principals, Sessions, Tokens}
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.Token

  @moduletag timeout: 60_000

  setup do
    {:ok, listener} =
      start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})

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

  # The root used to answer `404 not found`, which is right for an API and useless to the
  # person who was handed the URL. What matters here is that the page is written against
  # *this* plane rather than a placeholder, and that it does not offer a door to something
  # that is not mounted.
  describe "the index" do
    setup do
      on_exit(fn ->
        Application.delete_env(:troupe_plane, :base_url)
        Application.delete_env(:troupe_plane, :app_url)
      end)
    end

    test "names the clients and both applications", context do
      assert {:ok, %{status: 200, body: body}} = get(context, "/")

      assert body =~ "<!DOCTYPE html>"
      assert body =~ "troupe login"
      assert body =~ "/rpc"
      assert body =~ ~s(href="/admin")
      assert body =~ ~s(href="/app")
    end

    test "is html, so a browser renders it rather than downloading it", context do
      assert {:ok, %{headers: headers}} = get(context, "/")
      assert ["text/html" <> _] = headers["content-type"]
    end

    test "writes its commands against the plane's own URL", context do
      Application.put_env(:troupe_plane, :base_url, "https://troupe.example.test/")

      assert {:ok, %{body: body}} = get(context, "/")

      # Trailing slash trimmed: `https://troupe.example.test//rpc` is a URL a reader would
      # copy and a plane would not answer.
      assert body =~ "troupe login https://troupe.example.test"
      assert body =~ "https://troupe.example.test/rpc"
      refute body =~ "troupe.example.test//"
    end

    # A plane started without `TROUPE_BASE_URL` still has to print a URL that works, and
    # the request's own host is the one the reader just used.
    test "falls back to the host the request arrived on", context do
      assert {:ok, %{body: body}} = get(context, "/")

      assert body =~ "troupe login " <> context.url
    end

    # The GUI is a separate release and the plane cannot tell whether one is mounted.
    test "offers no app door where no app is mounted", context do
      Application.put_env(:troupe_plane, :app_url, "")

      assert {:ok, %{status: 200, body: body}} = get(context, "/")

      refute body =~ ~s(href="/app")
      assert body =~ "No graphical client is mounted"
      assert body =~ ~s(href="/admin")
    end

    test "still 404s everything that is not a route", context do
      assert {:ok, %{status: 404}} = get(context, "/nope")
    end
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

    # `groups` is not a scope anywhere. Group membership is a claim the provider is
    # configured to put in the token — `TROUPE_GROUPS_CLAIM` names it — and asking for it
    # as a scope is refused outright by Microsoft Entra with AADSTS650053, which fails
    # every sign-in, the CLI's device grant included, before a password is typed.
    test "asks only for scopes a provider actually has", context do
      assert {:ok, %{status: 200, body: body}} = get(context, "/.well-known/troupe")

      assert body["scopes"] == ["openid", "profile", "email", "offline_access"]
      refute "groups" in body["scopes"]
    end

    test "lets a deployment name its own scopes", context do
      oidc = Application.get_env(:troupe_plane, :oidc)

      Application.put_env(
        :troupe_plane,
        :oidc,
        Keyword.put(oidc, :scopes, ["openid", "api://troupe/.default"])
      )

      on_exit(fn -> Application.put_env(:troupe_plane, :oidc, oidc) end)

      assert {:ok, %{status: 200, body: body}} = get(context, "/.well-known/troupe")
      assert body["scopes"] == ["openid", "api://troupe/.default"]
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
               post(context, "/auth/exchange", %{
                 "id_token" => "good:ada@example.test:engineering"
               })

      assert body["subject"] == "ada@example.test"
      assert body["teams"] == ["engineering"]
      assert body["profiles"] == ["dev"]
      assert is_binary(body["token"])
      assert body["expires_at"] > System.system_time(:second)

      # The token is for the plane, not for a pod: presenting it to a worker fails on
      # audience, which is the point of the audience being there.
      {:ok, jwks} = Tokens.jwks()
      assert {:ok, _} = Token.verify(body["token"], jwks, audience: OIDC.audience())

      assert {:error, :wrong_audience} =
               Token.verify(body["token"], jwks, audience: "worker-dev-0")
    end

    test "a token the provider does not vouch for is refused", context do
      assert {:ok, %{status: 401, body: body}} =
               post(context, "/auth/exchange", %{"id_token" => "forged"})

      assert body["error"] == "unauthenticated"
    end
  end

  describe "a service principal" do
    test "exchanges its secret for a plane token, and is a user with no role", context do
      team = team_with_grant("engineering", "dev", name: "engineering")

      {:ok, principal, secret} =
        Principals.create(team, %{name: "nightly", profiles: ["dev"]}, "root")

      assert {:ok, %{status: 200, body: body}} =
               post(context, "/auth/exchange", %{
                 "client_id" => principal.subject,
                 "client_secret" => secret
               })

      assert body["subject"] == "svc:engineering/nightly"
      assert body["kind"] == "service"
      assert body["teams"] == ["engineering"]
      assert body["profiles"] == ["dev"]
      token = body["token"]

      {:ok, jwks} = Tokens.jwks()
      assert {:ok, claims} = Token.verify(token, jwks, audience: OIDC.audience())
      assert claims["kind"] == "service"
      assert claims["team"] == "engineering"

      assert {:ok, %{status: 200, body: me}} = rpc(context, token, "me", %{})
      assert me["result"]["kind"] == "service"
      assert me["result"]["profiles"] == ["dev"]
      refute me["result"]["platform_admin"]

      # It administers nothing, not even its own team.
      assert {:ok, %{status: 200, body: refused}} = rpc(context, token, "admin.overview", %{})
      assert refused["error"]["message"] == "forbidden"

      # The wrong secret, and a secret for a subject that does not exist, are the same
      # refusal.
      assert {:ok, %{status: 401}} =
               post(context, "/auth/exchange", %{
                 "client_id" => principal.subject,
                 "client_secret" => "nope"
               })

      assert {:ok, %{status: 401}} =
               post(context, "/auth/exchange", %{
                 "client_id" => "svc:engineering/ghost",
                 "client_secret" => secret
               })
    end

    test "disabled, it is unauthenticated at its next call and its next exchange", context do
      team = team_with_grant("engineering", "dev", name: "engineering")

      {:ok, principal, secret} =
        Principals.create(team, %{name: "nightly", profiles: ["dev"]}, "root")

      {:ok, %{status: 200, body: %{"token" => token}}} =
        post(context, "/auth/exchange", %{
          "client_id" => principal.subject,
          "client_secret" => secret
        })

      assert {:ok, %{status: 200, body: %{"result" => _}}} = rpc(context, token, "me", %{})

      {:ok, _} = Principals.disable(principal)

      # The token is still perfectly signed and well inside its lifetime, and it is the
      # subject that is refused.
      assert {:ok, %{status: 401, body: body}} = rpc(context, token, "me", %{})
      assert body["error"]["message"] == "unauthenticated"

      assert {:ok, %{status: 401}} =
               post(context, "/auth/exchange", %{
                 "client_id" => principal.subject,
                 "client_secret" => secret
               })
    end

    test "a rotated secret replaces the old one at once", context do
      team = team_with_grant("engineering", "dev", name: "engineering")

      {:ok, principal, old} =
        Principals.create(team, %{name: "nightly", profiles: ["dev"]}, "root")

      {:ok, _, new} = Principals.rotate(principal)

      assert {:ok, %{status: 401}} =
               post(context, "/auth/exchange", %{
                 "client_id" => principal.subject,
                 "client_secret" => old
               })

      assert {:ok, %{status: 200}} =
               post(context, "/auth/exchange", %{
                 "client_id" => principal.subject,
                 "client_secret" => new
               })
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
      assert {:ok, %{status: 401, body: body}} =
               post(context, "/rpc", %{"id" => 1, "method" => "me"})

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
               post(context, "/scim/v2/Users", %{"userName" => "x"}, [
                 {"authorization", "Bearer " <> token}
               ])
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
    post(
      context,
      "/rpc",
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
      [
        {"authorization", "Bearer " <> token}
      ]
    )
  end
end
