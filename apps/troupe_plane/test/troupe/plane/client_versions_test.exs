defmodule Troupe.Plane.ClientVersionsTest do
  @moduledoc """
  The plane's version policy for its clients (#66 slice 1b, Decision 868): per component a
  recommended version, a minimum and a blocked list, kept in the plane's database, changed
  through `admin.clients.get` and `admin.clients.put`, and said to each client at
  `initialize`, where one below the minimum or on a blocked version is refused with
  `update_required` and what to run.
  """

  use Troupe.Plane.DataCase, async: false

  import Phoenix.ConnTest

  alias Troupe.Plane.{Admin, Audit, Harness, Identity, OIDC, Tokens}
  alias Troupe.Protocol.Token

  @endpoint Troupe.Plane.Web.Endpoint

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    {:ok, platform} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _} = Identity.enable_team(platform, %{name: "platform"})

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["engineering"])
    ada = person("ada@example.test", ["engineering"])
    {:ok, _} = Identity.add_team_admin(engineering, lead.subject, root.subject)

    %{root: root, lead: lead, ada: ada}
  end

  describe "admin.clients.get and admin.clients.put" do
    test "a fresh plane holds no policy for any component", context do
      assert %{"result" => %{"clients" => clients}} = rpc(context.root, "admin.clients.get", %{})

      assert Map.keys(clients) |> Enum.sort() == ["daemon", "desktop", "tui"]

      for {_component, policy} <- clients do
        assert %{"recommended" => nil, "minimum" => nil, "blocked" => []} = policy
      end
    end

    test "a platform admin sets a component's policy, and the change is audited", context do
      assert %{"result" => put} =
               rpc(context.root, "admin.clients.put", %{
                 "component" => "tui",
                 "policy" => %{
                   "recommended" => "0.13.1-beta",
                   "minimum" => "0.13.0-beta",
                   "blocked" => ["0.12.3-beta"]
                 }
               })

      assert put["recommended"] == "0.13.1-beta"
      assert put["changes"]["minimum"] == %{"from" => nil, "to" => "0.13.0-beta"}

      assert %{"result" => %{"clients" => clients}} = rpc(context.root, "admin.clients.get", %{})

      assert %{
               "recommended" => "0.13.1-beta",
               "minimum" => "0.13.0-beta",
               "blocked" => ["0.12.3-beta"],
               "updated_by" => "root@example.test"
             } = clients["tui"]

      # The others are their own: the daemon's policy is not the terminal's.
      assert clients["daemon"]["minimum"] == nil

      assert [%{action: "clients.put", subject_id: "tui"} = entry] =
               Audit.list(kind: "clients")

      assert entry.detail["recommended"]["to"] == "0.13.1-beta"
    end

    test "a put changes only the fields it sends, and null clears one", context do
      put!(context.root, "daemon", %{"recommended" => "0.13.1-beta", "minimum" => "0.13.0-beta"})
      put!(context.root, "daemon", %{"minimum" => nil})

      assert %{"result" => %{"clients" => %{"daemon" => daemon}}} =
               rpc(context.root, "admin.clients.get", %{})

      assert daemon["recommended"] == "0.13.1-beta"
      assert daemon["minimum"] == nil
    end

    test "a team admin may read the policy and not change it", context do
      assert %{"result" => %{"clients" => _}} = rpc(context.lead, "admin.clients.get", %{})

      assert %{"error" => error} =
               rpc(context.lead, "admin.clients.put", %{
                 "component" => "tui",
                 "policy" => %{"minimum" => "0.13.0-beta"}
               })

      assert error["message"] == "forbidden"
      assert error["data"]["required_role"] == "platform_admin"
    end

    test "somebody who administers nothing may do neither", context do
      assert %{"error" => %{"message" => "forbidden"}} =
               rpc(context.ada, "admin.clients.get", %{})
    end

    test "what cannot be a policy is refused, with nothing changed", context do
      for {component, policy, said} <- [
            {"tui", %{"minimum" => "thirteen"}, "minimum"},
            {"tui", %{"blocked" => ["0.12.0-beta", "latest"]}, "blocked"},
            {"tui", %{"recommended" => "0.12.0-beta", "minimum" => "0.13.0-beta"}, "minimum"},
            {"tui", %{"recommended" => "0.13.0-beta", "blocked" => ["0.13.0-beta"]},
             "recommended"},
            {"phone", %{"minimum" => "0.13.0-beta"}, "component"}
          ] do
        assert %{"error" => error} =
                 rpc(context.root, "admin.clients.put", %{
                   "component" => component,
                   "policy" => policy
                 })

        assert error["message"] == "invalid_params", inspect(policy)
        assert inspect(error["data"]) =~ said, inspect(error)
      end

      assert %{"result" => %{"clients" => clients}} = rpc(context.root, "admin.clients.get", %{})
      assert Enum.all?(clients, fn {_c, policy} -> policy["minimum"] == nil end)
    end

    test "a minimum is checked against a recommended already there", context do
      put!(context.root, "tui", %{"recommended" => "0.13.0-beta"})

      assert %{"error" => %{"message" => "invalid_params"}} =
               rpc(context.root, "admin.clients.put", %{
                 "component" => "tui",
                 "policy" => %{"minimum" => "0.14.0-beta"}
               })
    end
  end

  describe "initialize" do
    test "is answered on a plane with no policy, which asks nothing of anybody", context do
      assert %{"result" => result} =
               rpc(context.ada, "initialize", hello("troupe", "0.12.0-beta"))

      assert result["client_update"] == %{
               "component" => "tui",
               "recommended" => nil,
               "minimum" => nil,
               "blocked" => [],
               "action" => "none"
             }
    end

    test "carries the policy for the connecting client's component", context do
      put!(context.root, "tui", %{"recommended" => "0.13.1-beta", "minimum" => "0.12.0-beta"})

      assert %{"result" => result} =
               rpc(context.ada, "initialize", hello("troupe", "0.12.0-beta"))

      assert result["protocol_version"] == "1"
      assert result["server_info"]["name"] == "troupe-plane"
      assert result["principal"]["subject"] == "ada@example.test"

      assert result["client_update"] == %{
               "component" => "tui",
               "recommended" => "0.13.1-beta",
               "minimum" => "0.12.0-beta",
               "blocked" => [],
               "action" => "suggest"
             }
    end

    test "a client at the recommended version has nothing to do", context do
      put!(context.root, "tui", %{"recommended" => "0.13.1-beta"})

      assert %{"result" => %{"client_update" => %{"action" => "none"}}} =
               rpc(context.ada, "initialize", hello("troupe", "0.13.1-beta"))
    end

    test "a client below the minimum is refused with update_required and what to run",
         context do
      put!(context.root, "tui", %{"recommended" => "0.13.1-beta", "minimum" => "0.13.0-beta"})

      assert %{"error" => error} = rpc(context.ada, "initialize", hello("troupe", "0.12.0-beta"))

      assert error["code"] == -32_016
      assert error["message"] == "update_required"

      assert %{
               "component" => "tui",
               "version" => "0.12.0-beta",
               "minimum" => "0.13.0-beta",
               "recommended" => "0.13.1-beta",
               "blocked" => false,
               "run" => "troupe update"
             } = error["data"]

      assert error["data"]["reason"] =~ "0.13.0-beta or later"
      assert error["data"]["reason"] =~ "troupe update"
    end

    test "a blocked version is refused, though it is above the minimum", context do
      put!(context.root, "tui", %{"minimum" => "0.12.0-beta", "blocked" => ["0.12.3-beta"]})

      assert %{"error" => %{"message" => "update_required", "data" => data}} =
               rpc(context.ada, "initialize", hello("troupe-headless", "0.12.3-beta"))

      assert data["blocked"] == true
      assert data["reason"] =~ "blocked"
    end

    test "the daemon is held to the daemon's policy, not the terminal's", context do
      put!(context.root, "tui", %{"minimum" => "0.13.0-beta"})

      assert %{"result" => %{"client_update" => %{"component" => "daemon", "action" => "none"}}} =
               rpc(context.ada, "initialize", hello("troupe-daemon", "0.12.0-beta"))

      put!(context.root, "daemon", %{"minimum" => "0.13.0-beta"})

      assert %{"error" => %{"message" => "update_required", "data" => data}} =
               rpc(context.ada, "initialize", hello("troupe-daemon", "0.12.0-beta"))

      assert data["component"] == "daemon"
      assert data["reason"] =~ "troupe-daemon"
    end

    test "a client the plane cannot place is served with no client_update", context do
      put!(context.root, "tui", %{"minimum" => "0.13.0-beta"})

      assert %{"result" => %{"client_update" => nil}} =
               rpc(context.ada, "initialize", hello("somebody-elses-client", "1.0.0"))

      assert %{"result" => %{"client_update" => nil}} =
               rpc(context.ada, "initialize", %{"protocol_version" => "1"})
    end
  end

  describe "me.client_versions" do
    test "tells anybody signed in each component's policy, for troupe update", context do
      put!(context.root, "tui", %{"recommended" => "0.13.1-beta", "blocked" => ["0.13.0-beta"]})

      assert {:ok, %{"tui" => tui, "daemon" => daemon, "desktop" => _}} =
               Harness.call("me.client_versions", %{}, %{
                 user: context.ada,
                 platform_admin?: false
               })

      assert tui == %{
               "recommended" => "0.13.1-beta",
               "minimum" => nil,
               "blocked" => ["0.13.0-beta"]
             }

      assert daemon == %{"recommended" => nil, "minimum" => nil, "blocked" => []}
    end
  end

  defp put!(user, component, policy) do
    actor = Admin.actor_for(user)
    {:ok, _} = Admin.clients_put(actor, component, policy)
  end

  defp hello(name, version) do
    %{
      "protocol_version" => "1",
      "client_info" => %{"name" => name, "version" => version},
      "capabilities" => %{}
    }
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
end
