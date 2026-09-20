# A provider that answers discovery the way a real one does, on a port of its own.
defmodule Troupe.Plane.ProviderSettingsTest.FakeProvider do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/.well-known/openid-configuration" do
    base = "http://#{conn.host}:#{conn.port}"

    json(conn, %{
      "issuer" => base,
      "jwks_uri" => base <> "/keys",
      "token_endpoint" => base <> "/token",
      "device_authorization_endpoint" => base <> "/device",
      "authorization_endpoint" => base <> "/authorize"
    })
  end

  get "/keys" do
    json(conn, %{"keys" => [%{"kty" => "oct", "kid" => "k1", "k" => "c2VjcmV0"}]})
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end

defmodule Troupe.Plane.ProviderSettingsTest do
  @moduledoc """
  The identity provider is a setting: stored over the deployment, read everywhere from one
  description, saved behind a check, undone with reset, and never a credential in an answer.

  What is being protected: a value saved on the console has to win in every place the
  provider is read — the discovery document clients start from, the console's own
  authorize request, the verifier's issuer — or a plane would sign people in against one
  provider and tell its clients about another. And the thing that made these read-only,
  the lock-out, has to stay impossible to do by accident: a candidate the provider does
  not stand behind is refused unless somebody says save anyway.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Audit, Identity, OIDC, Settings}
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.Error

  @deployed [
    issuer: "https://deployed.example.test",
    client_id: "deployed-client",
    client_secret: "deployed-secret",
    device_authorization_endpoint: "https://deployed.example.test/device",
    token_endpoint: "https://deployed.example.test/token"
  ]

  setup do
    start_supervised!(Troupe.Plane.Singleton)

    {:ok, listener} =
      start_supervised({Bandit, plug: __MODULE__.FakeProvider, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :base_url, "https://plane.example.test")
    Application.put_env(:troupe_plane, :oidc, @deployed)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :base_url)
      Application.delete_env(:troupe_plane, :oidc)
      Settings.invalidate()
    end)

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["backend"])
    team = team_with_grant("backend", "dev", name: "engineering")
    {:ok, _} = Identity.add_team_admin(team, lead.subject, root.subject)

    %{root: Admin.actor_for(root), lead: Admin.actor_for(lead), fake: "http://127.0.0.1:#{port}"}
  end

  defp discovery do
    conn = Router.call(Plug.Test.conn(:get, "/.well-known/troupe"), Router.init([]))
    Jason.decode!(conn.resp_body)
  end

  defp candidate(fake) do
    %{
      "issuer" => fake,
      "client_id" => "console-client",
      "token_endpoint" => fake <> "/token",
      "device_authorization_endpoint" => fake <> "/device"
    }
  end

  describe "one description, read everywhere" do
    test "the deployment is what everything reads until something is stored", context do
      assert %{issuer: "https://deployed.example.test", client_id: "deployed-client"} =
               OIDC.configured()

      assert %{"issuer" => "https://deployed.example.test", "client_id" => "deployed-client"} =
               discovery()

      assert {:ok, %{settings: settings, urls: urls, protocol: "oidc"}} =
               Admin.provider_get(context.root)

      assert Enum.all?(settings, &(&1.source in [:deployed, :unset]))
      assert urls.redirect == "https://plane.example.test/admin/callback"
      assert urls.discovery == "https://plane.example.test/.well-known/troupe"
    end

    test "a stored provider wins in the discovery document, the verifier and the console's own sign-in",
         context do
      assert {:ok, %{changes: changes}} =
               Admin.provider_put(context.root, candidate(context.fake))

      assert changes["issuer"]["to"] == context.fake
      assert changes["client_id"] == %{"from" => "deployed-client", "to" => "console-client"}

      # The discovery document clients start from.
      assert %{"issuer" => issuer, "client_id" => "console-client", "token_endpoint" => token} =
               discovery()

      assert issuer == context.fake
      assert token == context.fake <> "/token"

      # The verifier's issuer.
      assert OIDC.configured().issuer == context.fake

      # The console's own authorize request: the browser is sent to the stored provider,
      # as the stored client, with the scopes the discovery document publishes.
      conn = get(context.conn, "/admin/login")
      location = conn |> Plug.Conn.get_resp_header("location") |> hd()
      assert location =~ context.fake <> "/authorize?"
      assert location =~ "client_id=console-client"
      assert location =~ "offline_access"

      # And the settings say where each came from.
      {:ok, %{settings: settings}} = Admin.provider_get(context.root)
      assert %{source: :stored} = Enum.find(settings, &(&1.key == "issuer"))
      assert %{source: :deployed} = Enum.find(settings, &(&1.key == "client_secret"))
      assert %{source: :unset} = Enum.find(settings, &(&1.key == "authorization_endpoint"))
    end

    test "reset puts the deployment back", context do
      {:ok, _} = Admin.provider_put(context.root, candidate(context.fake))
      assert OIDC.configured().issuer == context.fake

      assert {:ok, %{changes: changes}} = Admin.provider_reset(context.root)
      assert changes["issuer"]["to"] == "https://deployed.example.test"
      assert OIDC.configured().issuer == "https://deployed.example.test"
      assert discovery()["client_id"] == "deployed-client"

      [event] = Enum.filter(Audit.list(), &(&1.action == "provider.reset"))
      assert event.actor == "root@example.test"
    end
  end

  describe "the check gates the save" do
    test "a provider that does not answer is refused, and force saves it anyway", context do
      dead = "http://127.0.0.1:9"

      assert {:error, %Error{message: "invalid_params", data: %{checks: checks}}} =
               Admin.provider_put(context.root, %{"issuer" => dead})

      assert Enum.any?(checks, &(&1.name == "Discovery" and not &1.ok))
      assert OIDC.configured().issuer == "https://deployed.example.test"

      assert {:ok, _} = Admin.provider_put(context.root, %{"issuer" => dead}, true)
      assert OIDC.configured().issuer == dead
    end

    test "endpoints that disagree with what the provider publishes are a refusal", context do
      wrong = Map.put(candidate(context.fake), "token_endpoint", "https://v1.example.test/token")

      assert {:error, %Error{data: %{checks: checks}}} = Admin.provider_put(context.root, wrong)
      assert %{ok: false, detail: detail} = Enum.find(checks, &(&1.name == "Endpoints"))
      assert detail =~ "v1.example.test"

      # Nothing was written, not even the fields that were fine.
      assert OIDC.configured().issuer == "https://deployed.example.test"
    end

    test "check tests the candidate against today's values and writes nothing", context do
      assert {:ok, %{ok: true, checks: checks}} =
               Admin.provider_check(context.root, candidate(context.fake))

      assert Enum.map(checks, & &1.name) == ["Discovery", "Signing keys", "Endpoints"]
      assert OIDC.configured().issuer == "https://deployed.example.test"

      # Without a candidate it is the current configuration that is checked.
      assert {:ok, %{ok: false}} = Admin.provider_check(context.root)
    end
  end

  describe "the secret" do
    test "is set, never shown, and not in the audit trail", context do
      assert {:ok, %{settings: settings, changes: changes}} =
               Admin.provider_put(context.root, %{"client_secret" => "sh-do-not-print"}, true)

      secret = Enum.find(settings, &(&1.key == "client_secret"))
      assert secret.set
      assert secret.source == :stored
      refute Map.has_key?(secret, :value)

      # Set before (the deployment's) and set after: a diff of "set" to "set" is nothing,
      # so the entry says which secret was given rather than pretending nothing happened.
      refute Map.has_key?(changes, "client_secret")
      assert changes["rotated"] == ["client_secret"]

      [event] = Enum.filter(Audit.list(), &(&1.action == "provider.put"))
      assert event.detail["rotated"] == ["client_secret"]
      refute inspect(event.detail) =~ "sh-do-not-print"

      refute inspect(Admin.provider_get(context.root)) =~ "sh-do-not-print"
      refute inspect(Admin.settings_list(context.root)) =~ "sh-do-not-print"

      # And the plane itself reads the stored one.
      assert Settings.get("client_secret") == "sh-do-not-print"
    end

    test "a blank field leaves it as it was", context do
      {:ok, _} = Admin.provider_put(context.root, %{"client_secret" => "kept"}, true)
      {:ok, _} = Admin.provider_put(context.root, %{"client_id" => "other", "client_secret" => ""}, true)

      assert Settings.get("client_secret") == "kept"
      assert Settings.get("client_id") == "other"
    end
  end

  describe "who may" do
    test "a team admin reads it and changes nothing", context do
      assert {:ok, _} = Admin.provider_get(context.lead)
      assert {:ok, _} = Admin.provider_check(context.lead, candidate(context.fake))

      assert {:error, %Error{message: "forbidden"}} =
               Admin.provider_put(context.lead, candidate(context.fake))

      assert {:error, %Error{message: "forbidden"}} = Admin.provider_reset(context.lead)
      assert OIDC.configured().issuer == "https://deployed.example.test"
    end

    test "nothing to save is refused rather than audited", context do
      assert {:error, %Error{message: "invalid_params"}} =
               Admin.provider_put(context.root, %{"client_secret" => ""}, true)

      assert Enum.filter(Audit.list(), &(&1.action == "provider.put")) == []
    end
  end

  describe "the console" do
    test "the card shows the URLs and the deployment's values, checks, saves and resets", context do
      conn = sign_in(context.conn, "root@example.test")
      {:ok, view, html} = live(conn, "/admin/provider")

      assert html =~ "https://plane.example.test/admin/callback"
      assert html =~ ~s(value="https://deployed.example.test")
      assert html =~ "from the deployment"
      refute html =~ "deployed-secret"

      # Check: the list appears and nothing is saved.
      html =
        view
        |> element(~s(button[phx-click="check"]))
        |> render_click(candidate(context.fake))

      assert html =~ ~s(id="sign-in-checks")
      assert OIDC.configured().issuer == "https://deployed.example.test"

      # Save, against the fake provider that answers.
      html = view |> form("#sign-in-form", candidate(context.fake)) |> render_submit()
      assert html =~ "Saved: client_id, device_authorization_endpoint, issuer, token_endpoint"
      assert html =~ "changed here"
      assert OIDC.configured().issuer == context.fake

      # A save the provider refuses shows the checks and keeps what was typed.
      html =
        view
        |> form("#sign-in-form", %{"issuer" => "http://127.0.0.1:9"})
        |> render_submit()

      assert html =~ "did not stand behind"
      assert html =~ ~s(value="http://127.0.0.1:9")
      assert OIDC.configured().issuer == context.fake

      # Back to the deployment, in two steps.
      html = view |> element(~s(button[phx-click="confirm-reset"])) |> render_click()
      assert html =~ "read again"
      assert OIDC.configured().issuer == context.fake

      html = view |> element(~s(button[phx-click="reset"])) |> render_click()
      assert html =~ "back to what this plane was deployed with"
      assert OIDC.configured().issuer == "https://deployed.example.test"
    end

    test "the Policy page no longer renders the group, and a team admin sees the card read-only",
         context do
      {:ok, _view, html} = context.conn |> sign_in("root@example.test") |> live("/admin/policy")
      refute html =~ "Where people sign in"
      refute html =~ ~s(id="sign-in-form")

      {:ok, _view, html} = context.conn |> sign_in("lead@example.test") |> live("/admin/provider")
      assert html =~ ~s(id="sign-in-form")
      assert html =~ "disabled"
      refute html =~ ~s(phx-click="confirm-reset")
      refute html =~ ~s(type="submit")
    end
  end
end
