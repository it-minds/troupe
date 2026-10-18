defmodule Troupe.Plane.SigningTest do
  @moduledoc """
  The plane's own signing key (#657): an Ed25519 key in OpenBao's transit engine, made on
  first use and never exportable, served at `/.well-known/troupe-signing-key`, signing
  `me.client_versions` and `me.client_defaults`, shown and rotated through
  `admin.signing.get` and `admin.signing.rotate`; and the release files the plane hands
  out at `/downloads`.

  Against the development OpenBao and object store, for real. Each test has a transit key
  of its own, since OpenBao is not rolled back as the database is.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  alias Troupe.KMS.Policy
  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, ClientVersions, OIDC, Settings, Signing, Tokens}
  alias Troupe.Plane.Admin.API
  alias Troupe.Protocol.{PlaneSignature, Token}

  @endpoint Troupe.Plane.Web.Endpoint

  @moduletag timeout: 60_000

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @lead %{subject: "lead@example.test", role: :team_admin, teams: ["engineering"]}

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    name = "troupe-plane-signing-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :plane_signing_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    ada = person("ada@example.test", ["engineering"])

    %{ada: ada, transit: transit, name: name}
  end

  describe "the key" do
    test "is made on first use, not exportable, and served with its fingerprint", context do
      assert {:error, {:unexpected_status, _, _}} = bao_read(context.transit, context.name)

      served = build_conn() |> get("/.well-known/troupe-signing-key") |> json_response(200)

      assert served["algorithm"] == "ed25519"
      assert served["version"] == 1
      assert is_binary(served["created_at"])
      assert {:ok, key} = PlaneSignature.read_key(served)
      assert served["fingerprint"] == key.fingerprint

      assert {:ok, %{"data" => data}} = bao_read(context.transit, context.name)
      assert data["type"] == "ed25519"
      assert data["exportable"] == false
      assert data["allow_plaintext_backup"] == false

      # The discovery document says where it is, so a client knows this plane signs.
      discovery = build_conn() |> get("/.well-known/troupe") |> json_response(200)
      assert discovery["plane"]["signing_key"] == "/.well-known/troupe-signing-key"
    end

    test "the plane's own policy is enough to make it, sign with it and rotate it, and nothing exports it",
         context do
      policy = "troupe-plane-signing-test-#{System.unique_integer([:positive])}"

      {:ok, _} =
        bao_write(context.transit, "/v1/sys/policies/acl/#{policy}", %{
          "policy" => Policy.plane_signing("transit", context.name)
        })

      {:ok, %{"auth" => %{"client_token" => token}}} =
        bao_write(context.transit, "/v1/auth/token/create", %{
          "policies" => [policy],
          "ttl" => "5m"
        })

      narrow = [token: token]

      assert {:ok, %{"version" => 1}} = Signing.key(narrow)

      assert {:ok, %{"document" => _}} =
               Signing.sign("client_versions", %{"versions" => %{}}, narrow)

      assert {:ok, %{now: %{"version" => 2}}} = Signing.rotate(narrow)

      assert {:error, {403, _}} =
               bao_get(context.transit, token, "/v1/transit/export/signing-key/#{context.name}")

      assert {:error, {403, _}} =
               bao_write(
                 context.transit,
                 "/v1/transit/keys/#{context.name}/config",
                 %{"exportable" => true},
                 token
               )
    end
  end

  describe "what it signs" do
    test "me.client_versions: the policy and where releases are, signed as client_versions",
         context do
      {:ok, _} = Admin.clients_put(@root, "tui", %{"recommended" => "0.22.0-beta"})

      {:ok, _} =
        Settings.put(
          "client_release_url",
          "https://plane.example.test/downloads/",
          "root@example.test"
        )

      answer = rpc(context.ada, "me.client_versions", %{})["result"]
      key = key!()

      # As clients from before read it, and the release beside it.
      assert answer["tui"]["recommended"] == "0.22.0-beta"
      assert answer["release"] == %{"url" => "https://plane.example.test/downloads"}

      assert {:ok, %{body: body}} =
               PlaneSignature.verify(answer["signed"], key, "client_versions")

      assert body["versions"]["tui"]["recommended"] == "0.22.0-beta"

      assert body["versions"]["daemon"] == %{
               "recommended" => nil,
               "minimum" => nil,
               "blocked" => []
             }

      assert body["release"] == %{"url" => "https://plane.example.test/downloads"}

      # Not something to pass off as the organisation's document.
      assert {:error, {:wrong_kind, "client_versions"}} =
               PlaneSignature.verify(answer["signed"], key, "client_defaults")
    end

    test "me.client_defaults: the organisation's document, signed as client_defaults", context do
      {:ok, _} = Settings.put("client_enforced", ~s({"max_turns": 40}), "root@example.test")

      answer = rpc(context.ada, "me.client_defaults", %{})["result"]

      assert {:ok, %{body: body, expires_at: expires_at}} =
               PlaneSignature.verify(answer["signed"], key!(), "client_defaults")

      assert body["enforced"] == %{"max_turns" => 40}
      assert body == Map.delete(answer, "signed")
      {:ok, expires, _} = DateTime.from_iso8601(expires_at)
      assert DateTime.diff(expires, DateTime.utc_now()) > 6 * 24 * 3600
    end

    test "an answer the plane cannot sign goes out unsigned, and says so in its log", context do
      # A key transit holds that is not an Ed25519 one: the session-token key.
      Application.put_env(
        :troupe_plane,
        :transit,
        Keyword.put(context.transit, :plane_signing_key, "troupe-session-tokens")
      )

      log =
        capture_log(fn ->
          assert rpc(context.ada, "me.client_versions", %{})["result"]["signed"] == nil
        end)

      assert log =~ "client_versions goes out unsigned"
    end
  end

  describe "admin.signing" do
    test "either admin reads the key; only a platform admin rotates it, by its fingerprint",
         _context do
      assert {:ok, read} = API.call("admin.signing.get", %{}, @lead)
      assert read["algorithm"] == "ed25519"
      assert [%{"version" => 1}] = read["versions"]

      assert {:error, %{message: "forbidden"}} =
               API.call("admin.signing.rotate", %{"fingerprint" => read["fingerprint"]}, @lead)

      assert {:error, %{message: "invalid_params", data: data}} =
               API.call("admin.signing.rotate", %{"fingerprint" => "SHA256:nope"}, @root)

      assert data.fingerprint == read["fingerprint"]
      assert {:ok, %{"version" => 1}} = Signing.key()

      assert {:ok, rotated} =
               API.call("admin.signing.rotate", %{"fingerprint" => read["fingerprint"]}, @root)

      assert rotated["version"] == 2
      assert rotated["fingerprint"] != read["fingerprint"]
      assert Enum.map(rotated["versions"], & &1["version"]) == [2, 1]

      assert [%{action: "signing.rotate", actor: "root@example.test"} = entry] =
               Audit.list(kind: "signing")

      assert entry.detail["fingerprint"] == %{
               "from" => read["fingerprint"],
               "to" => rotated["fingerprint"]
             }
    end

    test "after a rotation, a client holding the old key refuses what the new one signs, naming it",
         context do
      {:ok, old} = Signing.key()
      {:ok, pinned} = PlaneSignature.read_key(old)
      {:ok, _} = Signing.rotate()
      {:ok, now} = Signing.key()

      answer = rpc(context.ada, "me.client_defaults", %{})["result"]
      assert answer["signed"]["fingerprint"] == now["fingerprint"]

      assert {:error, {:other_key, fingerprint}} =
               PlaneSignature.verify(answer["signed"], pinned, "client_defaults")

      assert fingerprint == now["fingerprint"]
    end
  end

  describe "/downloads" do
    test "hands out a release's file for a version the plane serves, as a presigned URL",
         _context do
      store = ObjectStore.from_env()

      {:ok, _} =
        ObjectStore.put(
          store,
          "releases/v0.22.0-beta/manifest.json",
          ~s({"version":"0.22.0-beta"})
        )

      conn = build_conn() |> get("/downloads/v0.22.0-beta/manifest.json")
      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "releases/v0.22.0-beta/manifest.json"

      assert {:ok, %{status: 200, body: body}} =
               Req.get(location, retry: false, decode_body: false)

      assert body == ~s({"version":"0.22.0-beta"})
    end

    test "refuses a version every component blocks or is below, and anything that is not a release's file",
         _context do
      for component <- ["tui", "daemon", "desktop"] do
        {:ok, _} =
          Admin.clients_put(@root, component, %{
            "minimum" => "0.20.0-beta",
            "blocked" => ["0.21.0-beta"]
          })
      end

      assert build_conn() |> get("/downloads/v0.21.0-beta/manifest.json") |> Map.fetch!(:status) ==
               404

      assert build_conn() |> get("/downloads/v0.19.0-beta/manifest.json") |> Map.fetch!(:status) ==
               404

      assert build_conn() |> get("/downloads/v0.22.0-beta/manifest.json") |> Map.fetch!(:status) ==
               302

      for path <- [
            "/downloads/0.22.0-beta/manifest.json",
            "/downloads/vnope/manifest.json",
            "/downloads/v0.22.0-beta/..%2Fsecret",
            "/downloads/v0.22.0-beta/.hidden"
          ] do
        assert build_conn() |> get(path) |> Map.fetch!(:status) == 404, path
      end
    end

    test "the release URL setting takes an http or https URL and nothing else", _context do
      assert {:error, _} =
               Settings.put(
                 "client_release_url",
                 "ftp://mirror.example.test",
                 "root@example.test"
               )

      assert {:error, _} = Settings.put("client_release_url", "not a url", "root@example.test")

      assert {:ok, _} =
               Settings.put(
                 "client_release_url",
                 "https://mirror.example.test/troupe/",
                 "root@example.test"
               )

      assert ClientVersions.release_url() == "https://mirror.example.test/troupe"
    end
  end

  # -- helpers ------------------------------------------------------------------------

  defp key! do
    {:ok, served} = Signing.published()
    {:ok, key} = PlaneSignature.read_key(served)
    key
  end

  defp rpc(user, method, params) do
    {:ok, token, _payload} =
      Tokens.mint(
        %{
          "sub" => user.subject,
          "name" => user.display_name,
          "scopes" => Enum.map(Token.scopes_for("owner"), &Atom.to_string/1)
        },
        audience: OIDC.audience()
      )

    build_conn()
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> post(
      "/rpc",
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params})
    )
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp bao_read(transit, name), do: bao_get(transit, transit[:token], "/v1/transit/keys/#{name}")

  defp bao_get(transit, token, path) do
    case Req.get(transit[:address] <> path, headers: [{"x-vault-token", token}], retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} when status == 403 -> {:error, {403, body}}
      {:ok, %{status: status, body: body}} -> {:error, {:unexpected_status, status, body}}
    end
  end

  defp bao_write(transit, path, body, token \\ nil) do
    case Req.post(transit[:address] <> path,
           headers: [{"x-vault-token", token || transit[:token]}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
    end
  end

  defp delete_transit_key(transit, name) do
    bao_write(transit, "/v1/transit/keys/#{name}/config", %{"deletion_allowed" => true})

    Req.delete(transit[:address] <> "/v1/transit/keys/#{name}",
      headers: [{"x-vault-token", transit[:token]}],
      retry: false
    )
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    is_binary(address) and
      match?({:ok, %{status: 200}}, Req.request(url: address <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end
end
