defmodule Troupe.Plane.ScimConnectorTest do
  @moduledoc """
  The SCIM connector: a token rotated from the console, the deployment's as the floor,
  last sync stamped only for the provider, and a switch that makes pushed groups teams.

  What is being protected: rotating the credential must not need a rollout; a plane that
  never had a row must keep working; "last sync" must mean the provider and never somebody
  with the wrong token; and a group the provider pushes must become a team only when an
  administrator said so, and never by merging into a team that happens to share its name.
  """

  use Troupe.Plane.PanelCase, async: false

  alias Troupe.Plane.{Admin, Audit, Identity, Settings}
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.Error

  @base "https://plane.example.test"

  setup do
    start_supervised!(Troupe.Plane.Singleton)

    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :base_url, @base)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :base_url)
      Application.delete_env(:troupe_plane, :scim_token)
    end)

    root = person("root@example.test", ["platform"])
    lead = person("lead@example.test", ["backend"])
    team = team_with_grant("backend", "dev", name: "engineering")
    {:ok, _} = Identity.add_team_admin(team, lead.subject, root.subject)

    %{root: Admin.actor_for(root), lead: Admin.actor_for(lead)}
  end

  # A push the way the provider makes one: JSON, a bearer, straight into the router.
  defp push(method, path, body, token) do
    conn =
      Plug.Test.conn(method, path, Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = if token, do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Router.call(conn, Router.init([]))
  end

  defp user(subject) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "userName" => subject,
      "externalId" => subject,
      "displayName" => subject,
      "emails" => [%{"value" => subject, "primary" => true}]
    }
  end

  defp group(external_id, display_name) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "externalId" => external_id,
      "displayName" => display_name,
      "members" => []
    }
  end

  describe "the token" do
    test "a rotated token opens the door, and the one before it stops", context do
      assert push(:post, "/scim/v2/Users", user("ada@example.test"), nil).status == 401

      assert {:ok, %{token: first, token_set: true, status: :never_pushed}} =
               Admin.scim_rotate(context.root)

      assert push(:post, "/scim/v2/Users", user("ada@example.test"), first).status in [200, 201]

      assert {:ok, %{token: second}} = Admin.scim_rotate(context.root)
      refute first == second

      assert push(:post, "/scim/v2/Users", user("bea@example.test"), first).status == 401
      assert push(:post, "/scim/v2/Users", user("bea@example.test"), second).status in [200, 201]
      assert Identity.get_user("bea@example.test")
    end

    test "is never in the answer except the once", context do
      assert {:ok, rotated} = Admin.scim_rotate(context.root)
      assert {:ok, shown} = Admin.scim_get(context.root)

      refute Map.has_key?(shown, :token)
      assert shown.token_set
      assert shown.rotated_by == "root@example.test"

      # Nor in the audit trail.
      [event] = Enum.filter(Audit.list(), &(&1.action == "scim.rotate"))
      refute inspect(event.detail) =~ rotated.token
    end

    test "the deployment's token is the floor, before and after a rotate", context do
      Application.put_env(:troupe_plane, :scim_token, "deployed-secret")

      # No row at all: what every plane upgrading into this looks like.
      refute Connector.current()
      assert push(:post, "/scim/v2/Users", user("ada@example.test"), "deployed-secret").status in [200, 201]

      # And it says so.
      assert {:ok, %{token_set: false, deployed_token_set: true, status: :connected}} =
               Admin.scim_get(context.root)

      assert {:ok, %{token: stored}} = Admin.scim_rotate(context.root)
      assert push(:post, "/scim/v2/Users", user("bea@example.test"), "deployed-secret").status in [200, 201]
      assert push(:post, "/scim/v2/Users", user("cyd@example.test"), stored).status in [200, 201]
    end

    test "delete closes the stored door and leaves the deployment's where it was", context do
      Application.put_env(:troupe_plane, :scim_token, "deployed-secret")
      assert {:ok, %{token: stored}} = Admin.scim_rotate(context.root)

      # Confirmed by the base URL, and the wrong one does nothing.
      assert {:error, %Error{message: "invalid_params", data: %{base_url: expected}}} =
               Admin.scim_delete(context.root, "https://elsewhere.example.test/scim/v2")

      assert expected == @base <> "/scim/v2"
      assert push(:post, "/scim/v2/Users", user("ada@example.test"), stored).status in [200, 201]

      assert {:ok, %{token_set: false, deployed_token_set: true}} =
               Admin.scim_delete(context.root, @base <> "/scim/v2")

      assert push(:post, "/scim/v2/Users", user("bea@example.test"), stored).status == 401
      assert push(:post, "/scim/v2/Users", user("bea@example.test"), "deployed-secret").status in [200, 201]

      # With neither, the card says off.
      Application.delete_env(:troupe_plane, :scim_token)
      assert {:ok, %{status: :no_token}} = Admin.scim_get(context.root)
    end

    test "rotating, deleting and the switch are a platform administrator's", context do
      assert {:ok, _} = Admin.scim_get(context.lead)
      assert {:error, %Error{message: "forbidden"}} = Admin.scim_rotate(context.lead)
      assert {:error, %Error{message: "forbidden"}} = Admin.scim_delete(context.lead, @base <> "/scim/v2")

      assert {:error, %Error{message: "forbidden"}} =
               Admin.scim_update(context.lead, %{teams_from_groups: true})

      refute Connector.current()
    end
  end

  describe "last sync" do
    test "moves on an authorised push and never on a refused one", context do
      assert {:ok, %{token: token, last_seen_at: nil}} = Admin.scim_rotate(context.root)

      assert push(:get, "/scim/v2/Users", %{}, token).status == 200
      assert {:ok, %{last_seen_at: %DateTime{} = seen, last_seen_op: "GET /Users", status: :connected}} =
               Admin.scim_get(context.root)

      assert push(:post, "/scim/v2/Users", user("ada@example.test"), "wrong").status == 401
      assert {:ok, %{last_seen_at: ^seen}} = Admin.scim_get(context.root)
    end
  end

  describe "teams from groups" do
    test "off, a pushed group is a group; on, it is a team with the platform's defaults", context do
      assert {:ok, %{token: token}} = Admin.scim_rotate(context.root)

      assert push(:post, "/scim/v2/Groups", group("grp-data", "Data Platform"), token).status in [200, 201]
      assert Identity.get_group("grp-data")
      refute Identity.get_team("data-platform")

      assert {:ok, %{teams_from_groups: true, changes: changes}} =
               Admin.scim_update(context.root, %{teams_from_groups: true})

      assert changes == %{"teams_from_groups" => %{"from" => false, "to" => true}}

      # The same group again — the provider re-pushes on every sync — becomes the team now.
      assert push(:post, "/scim/v2/Groups", group("grp-data", "Data Platform"), token).status in [200, 201]

      assert %{enabled_by: "scim"} = team = Identity.get_team("data-platform")
      assert Identity.links_of(team) |> Enum.map(& &1.group.external_id) == ["grp-data"]
      assert team.budget_micros == Settings.get("default_budget_micros")

      assert [event] = Enum.filter(Audit.list(), &(&1.action == "team.enable"))
      assert event.actor == "scim"
      assert event.detail["group"] == "grp-data"

      # Pushing it a third time changes nothing: one group, one team.
      assert push(:post, "/scim/v2/Groups", group("grp-data", "Data Platform"), token).status in [200, 201]
      assert length(Identity.list_teams()) == 2
    end

    test "never merges a pushed group into a team that happens to share its name", context do
      assert {:ok, %{token: token}} = Admin.scim_rotate(context.root)
      assert {:ok, _} = Admin.scim_update(context.root, %{teams_from_groups: true})

      # "Engineering" would default to the name of the team that already exists over
      # `backend`. Enabling it the ordinary way would have linked the strangers in.
      assert push(:post, "/scim/v2/Groups", group("grp-eng", "Engineering"), token).status in [200, 201]

      engineering = Identity.get_team("engineering")
      assert Identity.links_of(engineering) |> Enum.map(& &1.group.external_id) == ["backend"]
      assert Identity.teams_drawing_from(Identity.get_group("grp-eng")) == []
    end

    test "turning it off creates no more and deletes none", context do
      assert {:ok, %{token: token}} = Admin.scim_rotate(context.root)
      assert {:ok, _} = Admin.scim_update(context.root, %{teams_from_groups: true})
      assert push(:post, "/scim/v2/Groups", group("grp-data", "Data Platform"), token).status in [200, 201]
      assert Identity.get_team("data-platform")

      assert {:ok, %{teams_from_groups: false}} =
               Admin.scim_update(context.root, %{teams_from_groups: false})

      assert push(:post, "/scim/v2/Groups", group("grp-ops", "Operations"), token).status in [200, 201]
      refute Identity.get_team("operations")
      assert Identity.get_team("data-platform")
    end
  end

  describe "the console" do
    test "shows the card, the token once, the two-step delete and the switch", context do
      conn = sign_in(context.conn, "root@example.test")
      {:ok, view, html} = live(conn, "/admin/provider")

      assert html =~ @base <> "/scim/v2"
      assert html =~ "off — no token anywhere"

      html = view |> element(~s(button[phx-click="rotate-token"])) |> render_click()
      assert html =~ "shown once"
      assert html =~ "waiting — a token exists"
      assert %{token_set: true} = Connector.describe()

      [_, token] = Regex.run(~r/paste it into the provider now: ([A-Za-z0-9_-]+)/, html)
      assert Connector.authorised?(token)

      # The switch, both ways, from the form — and the token is in no page after the
      # next event.
      html = view |> form("#teams-from-groups") |> render_change(%{"teams_from_groups" => "true"})
      assert Connector.teams_from_groups?()
      refute html =~ token
      view |> form("#teams-from-groups") |> render_change(%{"teams_from_groups" => "false"})
      refute Connector.teams_from_groups?()

      # Delete asks first, and the first click does nothing.
      html = view |> element(~s(button[phx-click="confirm-delete-token"])) |> render_click()
      assert html =~ "answers 401"
      assert %{token_set: true} = Connector.describe()

      html = view |> element(~s(button[phx-click="delete-token"])) |> render_click()
      assert html =~ "The token is gone"
      assert %{token_set: false} = Connector.describe()
    end

    test "a team admin sees the card and none of the buttons", context do
      conn = sign_in(context.conn, "lead@example.test")
      {:ok, _view, html} = live(conn, "/admin/provider")

      assert html =~ @base <> "/scim/v2"
      refute html =~ ~s(phx-click="rotate-token")
      refute html =~ ~s(id="teams-from-groups")
    end
  end
end
