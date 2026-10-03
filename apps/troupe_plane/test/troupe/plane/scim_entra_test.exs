defmodule Troupe.Plane.SCIMEntraTest do
  @moduledoc """
  Microsoft Entra ID's provisioning client against the plane's SCIM endpoints (#340).

  The requests are the ones Microsoft documents for user and group provisioning, with
  `example.test` names, and with the ids the plane answered where Entra would use them: a
  filtered `GET` before anything is created, a `POST`, and a `PATCH` for every change
  after that, `Replace` with a capital R, with a path or a value object and `"False"` for
  `false`, and a group's members as `Add` and `Remove` on `members`. Each goes through the
  router as Entra sends it, `application/scim+json` with the connector's bearer, and the
  rows are read afterwards: one person and one group, with the right attributes and
  members.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Identity, Login, Principals}
  alias Troupe.Plane.Identity.ServicePrincipal
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Web.Router

  @error ["urn:ietf:params:scim:api:messages:2.0:Error"]

  # Object ids, which an Entra mapping sends as `externalId` (Decision 751).
  @ada_oid "3f2a6c1e-8b4d-4e7a-9c1b-2d5e8f0a7b6c"
  @bo_oid "7d1e2f3a-4b5c-4d6e-8f9a-0b1c2d3e4f5a"
  @eng_oid "8aa1a0c0-c4c3-4bc0-b4a5-2ef676900159"
  @design_oid "5c4b3a29-1807-4f6e-9d5c-4b3a29180716"

  setup do
    {_connector, token} = Connector.rotate("root@example.test")
    %{token: token}
  end

  describe "a filtered GET" do
    test "answers the one user it names, and nobody for a name nobody has", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      _bo = create_user(context, @bo_oid, "bo@example.test", "Bo Ek")
      id = ada["id"]

      assert {200, found} = filter(context, "Users", ~s(userName eq "ada@example.test"))
      assert found["totalResults"] == 1

      assert [%{"id" => ^id, "userName" => "ada@example.test", "externalId" => @ada_oid}] =
               found["Resources"]

      # Attribute names and the operator ignore case, and so does a userName (§3.4.2.2).
      assert {200, %{"Resources" => [%{"id" => ^id}]}} =
               filter(context, "Users", ~s(USERNAME Eq "Ada@Example.test"))

      assert {200, %{"Resources" => [%{"id" => ^id}]}} =
               filter(context, "Users", ~s(externalId eq "#{@ada_oid}"))

      # What Entra asks when an administrator tests the connection, and before each create.
      assert {200, %{"totalResults" => 0, "Resources" => []}} =
               filter(context, "Users", ~s(userName eq "non-existent user"))
    end

    test "finds a group by displayName or externalId, without its members when asked", context do
      eng = create_group(context, @eng_oid, "Engineering")
      _design = create_group(context, @design_oid, "Design")
      id = eng["id"]

      # Get Group by displayName, as Microsoft documents it.
      query =
        URI.encode_query(%{
          "excludedAttributes" => "members",
          "filter" => ~s(displayName eq "Engineering")
        })

      assert {200, found} = request(context, :get, "/scim/v2/Groups?" <> query)
      assert [%{"id" => ^id} = group] = found["Resources"]
      refute Map.has_key?(group, "members")

      assert {200, %{"Resources" => [%{"id" => ^id}]}} =
               filter(context, "Groups", ~s(externalId eq "#{@eng_oid}"))

      assert {200, %{"totalResults" => 0}} =
               filter(context, "Groups", ~s(displayName eq "Nobody"))
    end

    test "is refused as invalidFilter for anything but one attribute eq one string", context do
      _ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      for filter <- [
            ~s(userName sw "ada"),
            ~s(userName eq "ada@example.test" and active eq true),
            ~s(userName eq "ada@example.test" or userName eq "bo@example.test"),
            ~s(emails[type eq "work"].value eq "ada@example.test"),
            ~s(displayName eq "Ada Lovelace"),
            ~s(active eq true),
            ~s(userName eq ada@example.test),
            ~s(userName pr),
            ""
          ] do
        assert {400, error} = filter(context, "Users", filter)
        assert error["schemas"] == @error
        assert error["status"] == "400"
        assert error["scimType"] == "invalidFilter", "for #{inspect(filter)}"
      end

      for filter <- [~s(members eq "x"), ~s(userName eq "ada@example.test")] do
        assert {400, %{"scimType" => "invalidFilter"}} = filter(context, "Groups", filter)
      end
    end
  end

  describe "a GET by id" do
    test "reads a user and a group by the id the plane gave them", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      eng = create_group(context, @eng_oid, "Engineering")
      id = ada["id"]

      assert {204, nil} = patch(context, "/scim/v2/Groups/" <> eng["id"], [add_members([id])])

      assert {200, %{"id" => ^id, "userName" => "ada@example.test"}} =
               request(context, :get, "/scim/v2/Users/" <> id)

      assert {200, group} = request(context, :get, "/scim/v2/Groups/" <> eng["id"])
      assert group["displayName"] == "Engineering"
      assert [%{"value" => ^id}] = group["members"]

      assert {200, group} =
               request(
                 context,
                 :get,
                 "/scim/v2/Groups/" <> eng["id"] <> "?excludedAttributes=members"
               )

      refute Map.has_key?(group, "members")

      # A subject is not an id, and nor is anything else.
      assert {404, %{"schemas" => @error, "status" => "404"}} =
               request(context, :get, "/scim/v2/Users/" <> @ada_oid)

      assert {404, %{"schemas" => @error}} =
               request(context, :get, "/scim/v2/Groups/" <> @eng_oid)

      assert {404, _} = request(context, :get, "/scim/v2/Groups/not-an-id")
    end
  end

  describe "Entra's sequence for a user" do
    test "a filter, a POST and PATCHes leave one person as the provider has them", context do
      assert {200, %{"totalResults" => 0}} =
               filter(context, "Users", ~s(userName eq "ada@example.test"))

      created = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      id = created["id"]
      path = "/scim/v2/Users/" <> id

      # The next cycle matches before it changes anything, and finds her.
      assert {200, %{"Resources" => [%{"id" => ^id}]}} =
               filter(context, "Users", ~s(userName eq "ada@example.test"))

      # Update User [Multi-valued properties]. The family name is not kept; the address is.
      assert {200, patched} =
               patch(context, path, [
                 %{
                   "op" => "Replace",
                   "path" => ~s(emails[type eq "work"].value),
                   "value" => "ada.lovelace@example.test"
                 },
                 %{"op" => "Replace", "path" => "name.familyName", "value" => "King"}
               ])

      assert [%{"value" => "ada.lovelace@example.test"}] = patched["emails"]

      # Update User [Single-valued properties]: a new userName. Beside an externalId it is a
      # label, and the next match asks for it.
      assert {200, %{"userName" => "ada.king@example.test"}} =
               patch(context, path, [
                 %{"op" => "Replace", "path" => "userName", "value" => "ada.king@example.test"}
               ])

      assert {200, %{"Resources" => [%{"id" => ^id}]}} =
               filter(context, "Users", ~s(userName eq "ada.king@example.test"))

      assert {200, %{"totalResults" => 0}} =
               filter(context, "Users", ~s(userName eq "ada@example.test"))

      # Add and remove.
      assert {200, %{"displayName" => "Ada King"}} =
               patch(context, path, [
                 %{"op" => "Add", "path" => "displayName", "value" => "Ada King"}
               ])

      assert {200, %{"emails" => []}} =
               patch(context, path, [
                 %{"op" => "Remove", "path" => ~s(emails[type eq "work"].value)}
               ])

      assert {200, %{"emails" => [%{"value" => "ada.king@example.test"}]}} =
               patch(context, path, [
                 %{
                   "op" => "Add",
                   "path" => "emails",
                   "value" => [
                     %{"type" => "work", "value" => "ada.king@example.test", "primary" => true}
                   ]
                 }
               ])

      # What the plane does not keep is accepted and left, as in a POST.
      assert {200, _} =
               patch(context, path, [
                 %{"op" => "Add", "path" => "title", "value" => "Analyst"},
                 %{
                   "op" => "Replace",
                   "path" =>
                     "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User:employeeNumber",
                   "value" => "1815"
                 },
                 %{"op" => "Remove", "path" => ~s(phoneNumbers[type eq "mobile"].value)}
               ])

      # Disable User, as Microsoft documents it.
      assert {200, %{"active" => false}} = request(context, :patch, path, disable_user())

      assert [ada] = Identity.list_users()
      assert ada.id == id
      assert ada.subject == @ada_oid
      assert ada.external_id == @ada_oid
      assert ada.user_name == "ada.king@example.test"
      assert ada.email == "ada.king@example.test"
      assert ada.display_name == "Ada King"
      refute ada.active
    end

    test "takes a value object without a path, and \"False\" for false", context do
      created = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      path = "/scim/v2/Users/" <> created["id"]

      # Entra with the compliance flag: several attributes in one operation, keyed by path.
      assert {200, patched} =
               patch(context, path, [
                 %{
                   "op" => "replace",
                   "value" => %{
                     "displayName" => "Ada King",
                     "name.givenName" => "Ada",
                     ~s(emails[type eq "work"].value) => "ada.king@example.test",
                     "userName" => "ada.king@example.test",
                     "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" => %{
                       "employeeNumber" => "1815"
                     }
                   }
                 }
               ])

      assert patched["displayName"] == "Ada King"
      assert patched["userName"] == "ada.king@example.test"
      assert [%{"value" => "ada.king@example.test"}] = patched["emails"]

      # Entra without it: a boolean as a string.
      assert {200, %{"active" => false}} =
               patch(context, path, [%{"op" => "Replace", "path" => "active", "value" => "False"}])

      assert {200, %{"active" => true}} =
               patch(context, path, [%{"op" => "replace", "value" => %{"active" => true}}])

      assert [%{active: true, display_name: "Ada King"}] = Identity.list_users()
    end

    test "active false deactivates the person as a DELETE does", context do
      created = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      eng = create_group(context, @eng_oid, "Engineering")

      assert {204, nil} =
               patch(context, "/scim/v2/Groups/" <> eng["id"], [add_members([created["id"]])])

      {:ok, team} =
        Identity.enable_team(Identity.get_group_by_id(eng["id"]), %{name: "engineering"})

      {:ok, _} = Identity.grant(team, "dev")

      {:ok, principal, _secret} =
        Principals.create(team, %{name: "nightly", profiles: ["dev"], sponsor: @ada_oid}, "root")

      assert {200, %{"active" => false}} =
               request(context, :patch, "/scim/v2/Users/" <> created["id"], disable_user())

      refute Identity.get_user(@ada_oid).active
      assert ServicePrincipal.state(Principals.get(principal.subject)) == :needs_sponsor
      assert {:error, :deactivated} = Login.from_claims(%{"sub" => @ada_oid})
    end
  end

  describe "Entra's sequence for a group" do
    test "a POST and PATCHes on its members leave one group with exactly those", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      bo = create_user(context, @bo_oid, "bo@example.test", "Bo Ek")

      assert {200, %{"totalResults" => 0}} =
               filter(context, "Groups", ~s(displayName eq "Engineering"))

      eng = create_group(context, @eng_oid, "Engineering")
      assert eng["members"] == []
      path = "/scim/v2/Groups/" <> eng["id"]

      # Update Group [Add Members].
      assert {204, nil} = patch(context, path, [add_members([ada["id"], bo["id"]])])
      assert members(eng) == Enum.sort([ada["id"], bo["id"]])

      # Somebody already in is no change, and an id nobody has is nobody to add.
      assert {204, nil} = patch(context, path, [add_members([ada["id"], Ecto.UUID.generate()])])
      assert members(eng) == Enum.sort([ada["id"], bo["id"]])

      # Update Group [Remove Members].
      assert {204, nil} =
               patch(context, path, [
                 %{
                   "op" => "Remove",
                   "path" => "members",
                   "value" => [%{"$ref" => nil, "value" => bo["id"]}]
                 }
               ])

      assert members(eng) == [ada["id"]]

      # Entra with the compliance flag: one member, by a filter in the path.
      assert {204, nil} =
               patch(context, path, [
                 %{"op" => "remove", "path" => ~s(members[value eq "#{ada["id"]}"])}
               ])

      assert members(eng) == []

      # Update Group [Non-member attributes].
      assert {204, nil} =
               patch(context, path, [
                 %{
                   "op" => "Replace",
                   "path" => "displayName",
                   "value" => "Engineering and Research"
                 }
               ])

      assert [group] = Identity.list_groups()
      assert group.id == eng["id"]
      assert group.external_id == @eng_oid
      assert group.display_name == "Engineering and Research"
      assert length(Identity.list_users()) == 2
    end

    test "a DELETE empties the group and keeps it", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      eng = create_group(context, @eng_oid, "Engineering")

      assert {204, nil} =
               patch(context, "/scim/v2/Groups/" <> eng["id"], [add_members([ada["id"]])])

      assert {204, nil} = request(context, :delete, "/scim/v2/Groups/" <> eng["id"])

      assert members(eng) == []
      assert Identity.get_group(@eng_oid)
      assert {404, _} = request(context, :delete, "/scim/v2/Groups/" <> Ecto.UUID.generate())
    end

    test "a PUT of the whole group still replaces its members", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      bo = create_user(context, @bo_oid, "bo@example.test", "Bo Ek")
      eng = create_group(context, @eng_oid, "Engineering")

      assert {204, nil} =
               patch(context, "/scim/v2/Groups/" <> eng["id"], [add_members([ada["id"]])])

      whole = Map.put(entra_group(@eng_oid, "Engineering"), "members", [%{"value" => bo["id"]}])
      assert {200, _} = request(context, :put, "/scim/v2/Groups/" <> eng["id"], whole)
      assert members(eng) == [bo["id"]]
    end
  end

  describe "a PATCH the plane cannot apply" do
    test "on a user, is a 400 with SCIM's error body, and changes nothing", context do
      created = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      path = "/scim/v2/Users/" <> created["id"]

      for {operations, scim_type} <- [
            {[%{"op" => "Merge", "path" => "displayName", "value" => "x"}], "invalidSyntax"},
            {[%{"op" => "Remove"}], "noTarget"},
            {[%{"op" => "Replace", "path" => ~s(emails[type eq "work"), "value" => "x"}],
             "invalidPath"},
            {[%{"op" => "Replace", "path" => "active", "value" => "maybe"}], "invalidValue"},
            {[%{"op" => "Replace", "path" => "userName", "value" => 7}], "invalidValue"},
            {[%{"op" => "Remove", "path" => "userName"}], "mutability"},
            # Another externalId, or none and so the userName, would be another person.
            {[%{"op" => "Replace", "path" => "externalId", "value" => @bo_oid}], "mutability"},
            {[%{"op" => "Remove", "path" => "externalId"}], "mutability"},
            # Whole or not at all: the first operation is fine, the second is not.
            {[
               %{"op" => "Replace", "path" => "displayName", "value" => "Changed"},
               %{"op" => "Replace", "path" => "active", "value" => 3}
             ], "invalidValue"}
          ] do
        assert {400, error} = patch(context, path, operations)
        assert error["schemas"] == @error
        assert error["status"] == "400"
        assert error["scimType"] == scim_type, "for #{inspect(operations)}"
      end

      # Not a PatchOp at all: a whole user, with the wrong method.
      assert {400, %{"scimType" => "invalidSyntax"}} =
               request(
                 context,
                 :patch,
                 path,
                 entra_user(@ada_oid, "ada@example.test", "Ada Lovelace")
               )

      assert {404, %{"schemas" => @error}} =
               request(context, :patch, "/scim/v2/Users/" <> Ecto.UUID.generate(), disable_user())

      assert [ada] = Identity.list_users()
      assert ada.display_name == "Ada Lovelace"
      assert ada.external_id == @ada_oid
      assert ada.active
    end

    test "on a group, is a 400 with SCIM's error body, and changes nothing", context do
      ada = create_user(context, @ada_oid, "ada@example.test", "Ada Lovelace")

      eng = create_group(context, @eng_oid, "Engineering")
      path = "/scim/v2/Groups/" <> eng["id"]

      for {operations, scim_type} <- [
            # What a groups claim names the group by.
            {[%{"op" => "Replace", "path" => "externalId", "value" => @design_oid}],
             "mutability"},
            {[%{"op" => "Remove", "path" => "displayName"}], "mutability"},
            {[%{"op" => "Add", "path" => ~s(members[value eq "#{ada["id"]}"]), "value" => "x"}],
             "invalidPath"},
            {[%{"op" => "Remove", "path" => ~s(members[display eq "Ada Lovelace"])}],
             "invalidFilter"},
            {[%{"op" => "Add", "path" => "members", "value" => "#{ada["id"]}"}], "invalidValue"},
            {[
               add_members([ada["id"]]),
               %{"op" => "Replace", "path" => "displayName", "value" => 7}
             ], "invalidValue"}
          ] do
        assert {400, error} = patch(context, path, operations)
        assert error["schemas"] == @error
        assert error["scimType"] == scim_type, "for #{inspect(operations)}"
      end

      assert {404, %{"schemas" => @error}} =
               patch(context, "/scim/v2/Groups/" <> Ecto.UUID.generate(), [
                 add_members([ada["id"]])
               ])

      assert [%{external_id: @eng_oid, display_name: "Engineering"}] = Identity.list_groups()
      assert members(eng) == []
    end
  end

  # -- Microsoft's documented requests, with example.test names ----------------

  # Create User. `externalId` is the object id, as the mapping Decision 751 asks for sends it.
  defp entra_user(oid, user_name, name) do
    [given, family] = String.split(name, " ", parts: 2)

    %{
      "schemas" => [
        "urn:ietf:params:scim:schemas:core:2.0:User",
        "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"
      ],
      "externalId" => oid,
      "userName" => user_name,
      "active" => true,
      "emails" => [%{"primary" => true, "type" => "work", "value" => user_name}],
      "meta" => %{"resourceType" => "User"},
      "name" => %{"formatted" => name, "familyName" => family, "givenName" => given},
      "roles" => []
    }
  end

  # Create Group.
  defp entra_group(oid, display_name) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
      "externalId" => oid,
      "displayName" => display_name,
      "meta" => %{"resourceType" => "Group"}
    }
  end

  # Disable User.
  defp disable_user do
    %{
      "Operations" => [%{"op" => "Replace", "path" => "active", "value" => false}],
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"]
    }
  end

  # Update Group [Add Members].
  defp add_members(ids) do
    %{
      "op" => "Add",
      "path" => "members",
      "value" => Enum.map(ids, &%{"$ref" => nil, "value" => &1})
    }
  end

  # -- the client ---------------------------------------------------------------

  defp create_user(context, oid, user_name, name),
    do: create(context, "/scim/v2/Users", entra_user(oid, user_name, name))

  defp create_group(context, oid, display_name),
    do: create(context, "/scim/v2/Groups", entra_group(oid, display_name))

  defp create(context, path, resource) do
    assert {201, created} = request(context, :post, path, resource)
    created
  end

  defp filter(context, kind, filter),
    do: request(context, :get, "/scim/v2/#{kind}?" <> URI.encode_query(%{"filter" => filter}))

  defp patch(context, path, operations) do
    request(context, :patch, path, %{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      "Operations" => operations
    })
  end

  # As the client sends it: SCIM's JSON type and the bearer, straight into the router.
  defp request(context, method, path, body \\ nil) do
    conn =
      Plug.Test.conn(method, path, body && Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/scim+json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.token)
      |> Router.call(Router.init([]))

    {conn.status, if(conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body))}
  end

  defp members(%{"id" => id}) do
    id |> Identity.get_group_by_id() |> Identity.members_of() |> Enum.map(& &1.id) |> Enum.sort()
  end
end
