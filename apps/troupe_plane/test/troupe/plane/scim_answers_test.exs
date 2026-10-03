defmodule Troupe.Plane.SCIMAnswersTest do
  @moduledoc """
  What the plane's SCIM endpoints answer, as RFC 7644 has it, whichever provider asks
  (#356): a create is `201` with where the resource now is (section 3.3), a replace `200`
  (3.5.1), a delete `204`, and `404` for an id the plane does not have (3.6).

  And a deactivation is one thing however it arrives. A `PUT` of the whole user with
  `active: false` stops the principals the person sponsors, as a `DELETE` and a `PATCH`
  do, once; a `PUT` that keeps them active leaves those principals alone.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Identity, Login, Principals}
  alias Troupe.Plane.Identity.ServicePrincipal
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Web.Router

  @error ["urn:ietf:params:scim:api:messages:2.0:Error"]

  setup do
    {_connector, token} = Connector.rotate("root@example.test")
    %{token: token}
  end

  describe "a create" do
    test "answers 201 with the user, and where it is in Location and meta", context do
      assert {201, user, location} = request(context, :post, "/scim/v2/Users", user("ada"))

      assert location == "/scim/v2/Users/" <> user["id"]
      assert user["meta"]["location"] == location
      assert user["userName"] == "ada@example.test"
      assert {200, %{"id" => _}, _} = request(context, :get, location)
    end

    test "answers 201 with the group, and where it is", context do
      assert {201, group, location} = request(context, :post, "/scim/v2/Groups", group("eng"))

      assert location == "/scim/v2/Groups/" <> group["id"]
      assert group["meta"]["location"] == location
      assert group["displayName"] == "Engineering"
    end

    test "of somebody who signed in first is still a create, of the person the plane has",
         context do
      {:ok, ada, _teams} = Login.from_claims(%{"sub" => "idp|ada", "email" => "ada@example.test"})

      assert {201, user, location} = request(context, :post, "/scim/v2/Users", user("ada"))
      assert user["id"] == ada.id
      assert location == "/scim/v2/Users/" <> ada.id
      assert [_one] = Identity.list_users()
    end
  end

  describe "a replace" do
    test "answers 200 with the resource, and no Location", context do
      {201, user, _} = request(context, :post, "/scim/v2/Users", user("ada"))
      {201, group, _} = request(context, :post, "/scim/v2/Groups", group("eng"))

      renamed = Map.put(user("ada"), "displayName", "Ada King")

      assert {200, %{"displayName" => "Ada King"}, nil} =
               request(context, :put, path(user), renamed)

      members = Map.put(group("eng"), "members", [%{"value" => user["id"]}])
      assert {200, %{"members" => [_ada]}, nil} = request(context, :put, path(group), members)
    end
  end

  describe "a delete" do
    test "answers 204 for somebody the plane has, and 404 for an id it does not", context do
      {201, user, _} = request(context, :post, "/scim/v2/Users", user("ada"))

      assert {204, nil, _} = request(context, :delete, path(user))
      refute Identity.get_user("idp|ada").active

      for id <- [Ecto.UUID.generate(), "not-an-id"] do
        assert {404, %{"schemas" => @error, "status" => "404"}, _} =
                 request(context, :delete, "/scim/v2/Users/" <> id)

        assert {404, %{"schemas" => @error}, _} =
                 request(context, :delete, "/scim/v2/Groups/" <> id)
      end

      assert [_ada] = Identity.list_users()
    end
  end

  describe "a PUT that deactivates" do
    setup context do
      team = team_with_grant("eng", "dev", name: "engineering")
      {201, user, _} = request(context, :post, "/scim/v2/Users", user("ada"))
      :ok = Identity.set_group_members(Identity.get_group("eng"), [user["id"]])

      {:ok, principal, _secret} =
        Principals.create(team, %{name: "nightly", profiles: ["dev"], sponsor: "idp|ada"}, "root")

      %{user: user, principal: principal}
    end

    test "stops the principals the person sponsors, as a DELETE does, once", context do
      leaving = Map.put(user("ada"), "active", false)

      assert {200, %{"active" => false}, _} = request(context, :put, path(context.user), leaving)

      refute Identity.get_user("idp|ada").active
      stopped = Principals.get(context.principal.subject)
      assert ServicePrincipal.state(stopped) == :needs_sponsor
      assert {:error, :deactivated} = Login.from_claims(%{"sub" => "idp|ada"})

      # The next sync sends the same whole user again, and nothing more stops.
      assert {200, _, _} = request(context, :put, path(context.user), leaving)
      assert Principals.get(context.principal.subject).disabled_at == stopped.disabled_at
    end

    test "with active true, or without it, leaves the principals running", context do
      for resource <- [Map.put(user("ada"), "active", true), Map.delete(user("ada"), "active")] do
        assert {200, %{"active" => true}, _} =
                 request(context, :put, path(context.user), resource)
      end

      assert ServicePrincipal.enabled?(Principals.get(context.principal.subject))
    end
  end

  defp user(name) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "externalId" => "idp|" <> name,
      "userName" => name <> "@example.test",
      "displayName" => String.capitalize(name),
      "emails" => [%{"value" => name <> "@example.test", "primary" => true}],
      "active" => true
    }
  end

  defp group("eng") do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "externalId" => "eng",
      "displayName" => "Engineering",
      "members" => []
    }
  end

  defp path(%{"meta" => %{"location" => location}}), do: location

  # As a provider sends it, straight into the router; the answer with its Location header.
  defp request(context, method, path, body \\ nil) do
    conn =
      Plug.Test.conn(method, path, body && Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/scim+json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.token)
      |> Router.call(Router.init([]))

    body = if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
    {conn.status, body, conn |> Plug.Conn.get_resp_header("location") |> List.first()}
  end
end
