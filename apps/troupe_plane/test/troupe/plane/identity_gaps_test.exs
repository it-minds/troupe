defmodule Troupe.Plane.IdentityGapsTest do
  @moduledoc """
  What a plane fed by SCIM and sign-in still got wrong after one row per person (#715).

  A sign-in or a push that finds nobody under its subject adopts the row SCIM gave that
  `externalId` only when the row's email or `userName` agrees with what it carries;
  otherwise nothing is merged, the refusal is audited and the pair is listed. A SCIM `PUT`
  replaces the person at the id in its path, never somebody its body names. A push under
  one of the plane's own subjects is refused, as a sign-in is. And a removed person's
  subject is named by nothing a person arriving later under it would inherit: no trigger
  tells them, and their spend this month is not theirs.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, Identity, Index, Ledger, Login, Sessions, Settings, Triggers}
  alias Troupe.Plane.Identity.{Tombstone, User}
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Plane.Triggers.Trigger
  alias Troupe.Plane.Web.Router
  alias Troupe.Sessions.Storage

  # Ada's `sub`, pairwise as Entra's is, and her `oid`.
  @sub "kX9vQ2pL7mN4rT8wY1zA3bC5dE6fG0hJ-pairwise"
  @oid "3f2a6c1e-8b4d-4e7a-9c1b-2d5e8f0a7b6c"

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}

  setup do
    {_connector, token} = Connector.rotate("root@example.test")
    subject_claim(nil)
    on_exit(fn -> Application.delete_env(:troupe_plane, :oidc) end)

    %{token: token, team: team_with_grant("g-eng", "dev", name: "engineering")}
  end

  # SCIM first, under `oid`, with the provider's mapping sending her `sub` as `externalId`;
  # her first sign-in moves SCIM's row to her `oid`; then the plane goes back to `sub`, so
  # the next sign-in under `@sub` finds nobody there and SCIM's row by its `externalId`.
  defp scim_row_under_oid(context) do
    subject_claim("oid")
    assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())
    {:ok, moved, _teams} = Login.from_claims(claims())
    assert moved.id == pushed["id"]
    assert moved.subject == @oid
    subject_claim(nil)
    pushed
  end

  describe "adopting the row SCIM gave a subject" do
    test "a sign-in whose email agrees adopts it", context do
      pushed = scim_row_under_oid(context)

      {:ok, back, _teams} = Login.from_claims(claims())
      assert back.id == pushed["id"]
      assert back.subject == @sub
      assert [_one] = Identity.list_users()
      assert audited("person.adopt_refused") == []
    end

    test "a sign-in whose userName agrees adopts it, whatever its email", context do
      pushed = scim_row_under_oid(context)

      claims =
        claims()
        |> Map.put("email", "a.lovelace@example.test")
        |> Map.put("preferred_username", "ADA@example.test")

      {:ok, back, _teams} = Login.from_claims(claims)
      assert back.id == pushed["id"]
      assert back.subject == @sub
    end

    test "a sign-in that agrees on neither gets a row of its own, audited and listed", context do
      pushed = scim_row_under_oid(context)

      # Somebody else's token whose subject is the `externalId` the provider gave Ada: a
      # mis-mapped provisioning attribute.
      mallory =
        claims()
        |> Map.put("email", "mallory@example.test")
        |> Map.put("preferred_username", "mallory")
        |> Map.put("name", "Mallory")

      {:ok, signed_in, _teams} = Login.from_claims(mallory)
      refute signed_in.id == pushed["id"]
      assert signed_in.subject == @sub

      # Ada's row is where it was, with everything on it.
      ada = Identity.get_user_by_id(pushed["id"])
      assert ada.subject == @oid
      assert ada.external_id == @sub
      assert length(Identity.list_users()) == 2

      assert [refused] = audited("person.adopt_refused")
      assert refused.subject_id == @sub
      assert refused.detail["row"] == ada.id
      assert refused.detail["row_subject"] == @oid
      assert refused.detail["via"] == "sign-in"
      refute inspect(refused.detail) =~ "example.test"

      assert {:ok, %{people: [pair]}} = Admin.identity_duplicates(@root)
      assert pair.by == "external_id"
      assert pair.people |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([ada.id, signed_in.id])
      assert pair.likely =~ "neither the email nor the userName"

      # The next sign-in is the row it made, and asks nothing again.
      {:ok, again, _teams} = Login.from_claims(mallory)
      assert again.id == signed_in.id
      assert [_one] = audited("person.adopt_refused")
    end

    test "a push that agrees updates SCIM's row; one that does not is refused, audited and listed",
         context do
      pushed = scim_row_under_oid(context)

      # The same record again, renamed: the email still agrees.
      renamed = Map.put(ada(), "displayName", "Ada King")
      assert {201, again, _} = scim(context, :post, "/scim/v2/Users", renamed)
      assert again["id"] == pushed["id"]
      assert Identity.get_user_by_id(pushed["id"]).display_name == "Ada King"

      other =
        ada()
        |> Map.put("userName", "mallory@example.test")
        |> Map.put("emails", [%{"value" => "mallory@example.test", "primary" => true}])

      assert {409, body, _} = scim(context, :post, "/scim/v2/Users", other)
      assert body["scimType"] == "uniqueness"
      assert body["detail"] =~ "admin.identity.duplicates"

      held = Identity.get_user_by_id(pushed["id"])
      assert held.user_name == "ada@example.test"
      assert held.subject == @oid
      assert [_one] = Identity.list_users()

      assert [refused] = audited("person.adopt_refused")
      assert refused.actor == "scim"
      assert refused.detail["via"] == "scim"

      assert {:ok, %{people: [pair]}} = Admin.identity_duplicates(@root)
      assert pair.by == "external_id"
      assert Enum.map(pair.people, & &1.id) == [held.id]
      assert pair.likely =~ "SCIM"
    end
  end

  describe "a refused pair, later" do
    # An MCP client's access token minted without the email or profile scopes carries
    # neither, so the first sign-in after the switch is refused and makes a row of its own.
    test "a token with neither email nor username, then one that agrees: the two are folded",
         context do
      pushed = scim_row_under_oid(context)
      bare = Map.drop(claims(), ["email", "name"])

      {:ok, signed_in, _teams} = Login.from_claims(bare)
      refute signed_in.id == pushed["id"]
      assert [_refused] = audited("person.adopt_refused")
      session = session!(context, signed_in)

      # The desktop app's sign-in carries the email the row has: the same rule an adoption
      # needs, met now. The row the bare token made is folded into SCIM's, which takes the
      # subject, and what was made under it comes along.
      {:ok, back, _teams} = Login.from_claims(claims())
      assert back.id == pushed["id"]
      assert back.subject == @sub
      assert [_one] = Identity.list_users()
      assert Repo.reload(session).owner_id == back.id
      assert Repo.reload(session).owner_subject == @sub

      assert [adopted] = audited("person.adopt")
      assert adopted.detail["via"] == "sign-in"
      assert adopted.detail["folded"]["id"] == signed_in.id
      assert {:ok, %{people: []}} = Admin.identity_duplicates(@root)

      # And nothing more on the next one.
      {:ok, again, _teams} = Login.from_claims(claims())
      assert again.id == back.id
      assert [_adopted] = audited("person.adopt")
    end

    test "a push onto the row a refused sign-in made is a 409 naming both, and listed",
         context do
      pushed = scim_row_under_oid(context)
      {:ok, signed_in, _teams} = Login.from_claims(Map.drop(claims(), ["email"]))

      # The provider pushes Ada again. Keyed on the subject, it finds the sign-in's row,
      # and the unique externalId refuses giving it SCIM's value too.
      assert {409, body, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert body["scimType"] == "uniqueness"
      assert body["detail"] =~ pushed["id"]
      assert body["detail"] =~ signed_in.id
      assert body["detail"] =~ "admin.identity.adopt"

      assert Identity.get_user_by_id(signed_in.id).external_id == nil
      assert Identity.get_user_by_id(pushed["id"]).subject == @oid

      assert [_, _] = audited("person.adopt_refused")
      refused = Enum.find(audited("person.adopt_refused"), &(&1.actor == "scim"))
      assert refused.detail["via"] == "scim"
      assert refused.detail["other"] == signed_in.id

      assert {:ok, %{people: [pair]}} = Admin.identity_duplicates(@root)

      assert pair.people |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([pushed["id"], signed_in.id])

      assert pair.row == pushed["id"]
      assert pair.subject == @sub
    end

    test "an administrator settles a sign-in's pair: its row is folded into SCIM's", context do
      pushed = scim_row_under_oid(context)
      mallory = mallory()
      {:ok, signed_in, _teams} = Login.from_claims(mallory)
      session = session!(context, signed_in)
      lead = %{subject: "lead@example.test", role: :team_admin, teams: ["engineering"]}

      assert {:error, %{message: "forbidden"}} =
               Admin.identity_adopt(lead, pushed["id"], @sub)

      assert {:ok, settled} = Admin.identity_adopt(@root, pushed["id"], @sub)
      assert settled["folded"]["id"] == signed_in.id
      assert settled["row_subject"] == @oid

      kept = Identity.get_user_by_id(pushed["id"])
      assert kept.subject == @sub
      assert kept.external_id == @sub
      assert Identity.get_user_by_id(signed_in.id) == nil
      assert Repo.reload(session).owner_id == kept.id

      assert [adopted] = audited("person.adopt")
      assert adopted.actor == "root@example.test"
      assert adopted.detail["via"] == "admin"
      assert {:ok, %{people: []}} = Admin.identity_duplicates(@root)

      # Settled once; the next sign-in under the subject is the kept row.
      assert {:error, %{message: "not_found"}} =
               Admin.identity_adopt(@root, pushed["id"], @sub)

      {:ok, again, _teams} = Login.from_claims(mallory)
      assert again.id == kept.id
    end

    test "an administrator settles a refused push: the next push adopts SCIM's row", context do
      pushed = scim_row_under_oid(context)

      # Her email and her username both changed at the provider.
      moved =
        ada()
        |> Map.put("userName", "ada.king@example.test")
        |> Map.put("emails", [%{"value" => "ada.king@example.test", "primary" => true}])

      assert {409, _body, _} = scim(context, :post, "/scim/v2/Users", moved)
      assert {:ok, settled} = Admin.identity_adopt(@root, pushed["id"], @sub)
      assert settled["folded"] == nil
      assert {:ok, %{people: []}} = Admin.identity_duplicates(@root)

      assert {201, again, _} = scim(context, :post, "/scim/v2/Users", moved)
      assert again["id"] == pushed["id"]
      held = Identity.get_user_by_id(pushed["id"])
      assert held.email == "ada.king@example.test"
      assert held.subject == @oid
      assert [_one] = Identity.list_users()
    end

    test "a refused push a later agreeing push resolves is no longer listed; refused again, it is",
         context do
      pushed = scim_row_under_oid(context)

      other =
        ada()
        |> Map.put("userName", "mallory@example.test")
        |> Map.put("emails", [%{"value" => "mallory@example.test", "primary" => true}])

      assert {409, _body, _} = scim(context, :post, "/scim/v2/Users", other)
      assert {:ok, %{people: [_pair]}} = Admin.identity_duplicates(@root)

      # The provider sends the right record again: it agrees, and updates SCIM's row.
      assert {201, again, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert again["id"] == pushed["id"]
      assert {:ok, %{people: []}} = Admin.identity_duplicates(@root)
      assert [_one] = audited("person.adopt_agreed")

      # Every push that agrees after it is the same answer, and audits nothing more.
      assert {201, _, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert [_still_one] = audited("person.adopt_agreed")

      # A later refusal is listed again: what resolved the first says nothing of it.
      assert {409, _body, _} = scim(context, :post, "/scim/v2/Users", other)
      assert {:ok, %{people: [pair]}} = Admin.identity_duplicates(@root)
      assert pair.row == pushed["id"]

      # And an agreeing push no longer moves a disagreeing one past the check.
      assert Identity.get_user_by_id(pushed["id"]).user_name == "ada@example.test"
    end

    test "a row SCIM named by another externalId is not folded into anybody", context do
      pushed = scim_row_under_oid(context)
      # Somebody SCIM provisioned under the value as their userName, with an externalId of
      # their own.
      {:ok, other} =
        Identity.upsert_user(%{subject: @sub, external_id: "someone-else", user_name: "eve"})

      assert {:error, refused} = Admin.identity_adopt(@root, pushed["id"], @sub)
      assert refused.data.reason =~ "is SCIM's for externalId someone-else"
      assert Identity.get_user_by_id(other.id)
      assert Identity.get_user_by_id(pushed["id"]).subject == @oid
    end
  end

  describe "a SCIM PUT" do
    test "replaces the person at the id in its path", context do
      assert {201, ada, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert {201, bo, _} = scim(context, :post, "/scim/v2/Users", bo())

      assert {200, replaced, _} =
               scim(context, :put, path(ada), Map.put(ada(), "displayName", "Ada King"))

      assert replaced["id"] == ada["id"]
      assert Identity.get_user_by_id(ada["id"]).display_name == "Ada King"
      assert Identity.get_user_by_id(bo["id"]).display_name == "Bo"
    end

    test "naming somebody else is refused, and changes nobody", context do
      assert {201, ada, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert {201, bo, _} = scim(context, :post, "/scim/v2/Users", bo())

      # Bo's resource, sent to Ada's id.
      assert {400, body, _} =
               scim(context, :put, path(ada), Map.put(bo(), "displayName", "Somebody"))

      assert body["scimType"] == "mutability"

      assert Identity.get_user_by_id(ada["id"]).display_name == "Ada Lovelace"
      assert Identity.get_user_by_id(bo["id"]).display_name == "Bo"
      assert length(Identity.list_users()) == 2
    end
  end

  describe "a SCIM push under one of the plane's own subjects" do
    test "is refused as invalidValue, and makes nobody", context do
      for subject <- ["removed:" <> Ecto.UUID.generate(), "svc:engineering/nightly"] do
        assert {400, body, _} =
                 scim(context, :post, "/scim/v2/Users", Map.put(ada(), "externalId", subject))

        assert body["scimType"] == "invalidValue"

        without_external_id = ada() |> Map.delete("externalId") |> Map.put("userName", subject)

        assert {400, %{"scimType" => "invalidValue"}, _} =
                 scim(context, :post, "/scim/v2/Users", without_external_id)
      end

      assert Identity.list_users() == []
    end
  end

  describe "a removed person's subject" do
    test "is dropped from notify lists, and their spend stays with the tombstone", context do
      %{team: team} = context
      assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())
      ada = Identity.get_user_by_id(pushed["id"])

      {:ok, session} =
        Sessions.create(%{
          id: "s-#{System.unique_integer([:positive])}",
          owner_id: ada.id,
          owner_subject: ada.subject,
          team_id: team.id,
          profile: "dev",
          state: "dormant",
          epoch: 1
        })

      {:ok, _} =
        Ledger.record(%{
          session_id: session.id,
          team_id: team.id,
          owner_subject: ada.subject,
          model: "m",
          cost_micros: 5,
          gateway_request_id: "req-#{System.unique_integer([:positive])}"
        })

      {:ok, principal, _secret} = principal!(team, %{name: "nightly", profiles: ["dev"]})

      {:ok, trigger} =
        Triggers.put(
          team,
          %{
            "name" => "nightly",
            "principal" => principal.subject,
            "profile" => "dev",
            "source" => %{"kind" => "webhook", "provider" => "generic"},
            "prompt_template" => "do the thing",
            "notify" => [ada.subject, "bo@example.test"]
          },
          "root@example.test"
        )

      assert Ledger.spent_micros_for(@sub) == 5
      team_spent = Ledger.spent_micros(team)

      assert {204, nil, _} = scim(context, :delete, path(pushed))
      [tombstone] = Repo.all(Tombstone)
      marker = Tombstone.marker(tombstone)

      assert Repo.get(Trigger, trigger.id).notify == ["bo@example.test"]
      assert Ledger.spent_micros_for(@sub) == 0
      assert Ledger.spent_micros_for(marker) == 5
      assert Ledger.spent_micros(team) == team_spent

      assert [removed] = audited("person.remove")
      assert removed.detail["notified_by"] == ["nightly"]

      # Somebody provisioned later under the same subject starts clean.
      assert {201, _again, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert %User{} = Identity.get_user(@sub)
      assert Ledger.spent_micros_for(@sub) == 0
      refute @sub in Repo.get(Trigger, trigger.id).notify
    end

    # A session parked as its owner was removed can have its manifest written after the
    # removal. A rebuild of a lost index read that as the subject's, and handed it to
    # whoever the provider sent later under the same subject.
    test "names the tombstone in a rebuilt index, however late the manifest was written",
         context do
      store = ObjectStore.from_env()
      assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())
      ada = Identity.get_user_by_id(pushed["id"])
      parked = session!(context, ada, "20261016T000000-e37a#{System.unique_integer([:positive])}")

      assert {204, nil, _} = scim(context, :delete, path(pushed))
      [tombstone] = Repo.all(Tombstone)
      marker = Tombstone.marker(tombstone)

      # Written after the removal, naming the subject the session's owner had.
      manifest!(store, parked.id, @sub)
      lose!(parked)
      assert {:ok, _} = Index.rebuild_one(store, parked.id)

      assert %{owner_subject: ^marker, owner_id: nil, state: "read_only"} =
               Sessions.get(parked.id)

      # Somebody new under the subject: a manifest they wrote is theirs, one written before
      # they arrived is still the tombstone's.
      Process.sleep(5)
      assert {201, again, _} = scim(context, :post, "/scim/v2/Users", ada())
      Process.sleep(5)

      theirs =
        session!(
          context,
          Identity.get_user_by_id(again["id"]),
          "20261016T000000-e37b#{System.unique_integer([:positive])}"
        )

      manifest!(store, theirs.id, @sub)
      lose!(theirs)
      lose!(parked)

      assert {:ok, _} = Index.rebuild_one(store, parked.id)
      assert {:ok, _} = Index.rebuild_one(store, theirs.id)
      assert Sessions.get(parked.id).owner_subject == marker
      assert %{owner_subject: @sub, state: "dormant"} = Sessions.get(theirs.id)
      assert Sessions.get(theirs.id).owner_id == again["id"]
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp subject_claim(claim) do
    Application.put_env(
      :troupe_plane,
      :oidc,
      [issuer: "https://login.example.test/v2.0", client_id: "troupe-cli"] ++
        if(claim, do: [subject_claim: claim], else: [])
    )

    Settings.invalidate()
  end

  defp claims do
    %{
      "sub" => @sub,
      "oid" => @oid,
      "email" => "ada@example.test",
      "name" => "Ada Lovelace",
      "groups" => ["g-eng"]
    }
  end

  defp ada do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "externalId" => @sub,
      "userName" => "ada@example.test",
      "displayName" => "Ada Lovelace",
      "emails" => [%{"value" => "ada@example.test", "primary" => true}],
      "active" => true
    }
  end

  defp bo do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "externalId" => "bo-external-id",
      "userName" => "bo@example.test",
      "displayName" => "Bo",
      "emails" => [%{"value" => "bo@example.test", "primary" => true}],
      "active" => true
    }
  end

  # Somebody else's token whose subject is the `externalId` the provider gave Ada.
  defp mallory do
    claims()
    |> Map.put("email", "mallory@example.test")
    |> Map.put("preferred_username", "mallory")
    |> Map.put("name", "Mallory")
  end

  # What a pod writes beside a session's segments: plaintext, and written now.
  defp manifest!(store, session_id, subject) do
    {:ok, _} =
      Storage.put_manifest(store, session_id, %{
        kind: "team",
        team: "engineering",
        owner_subject: subject,
        profile: "dev",
        epoch: 1,
        last_seq: 0
      })
  end

  # The index lost the row, as a restore from a backup older than the session loses it.
  defp lose!(session), do: Repo.delete_all(from(s in Session, where: s.id == ^session.id))

  defp session!(context, user, id \\ "s-#{System.unique_integer([:positive])}") do
    {:ok, session} =
      Sessions.create(%{
        id: id,
        owner_id: user.id,
        owner_subject: user.subject,
        team_id: context.team.id,
        profile: "dev",
        state: "dormant",
        epoch: 1
      })

    session
  end

  defp audited(action), do: Enum.filter(Audit.list(), &(&1.action == action))

  defp path(%{"meta" => %{"location" => location}}), do: location

  defp scim(context, method, path, body \\ nil) do
    conn =
      Plug.Test.conn(method, path, body && Jason.encode!(body))
      |> Plug.Conn.put_req_header("content-type", "application/scim+json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.token)
      |> Router.call(Router.init([]))

    body = if conn.resp_body == "", do: nil, else: Jason.decode!(conn.resp_body)
    {conn.status, body, conn |> Plug.Conn.get_resp_header("location") |> List.first()}
  end
end
