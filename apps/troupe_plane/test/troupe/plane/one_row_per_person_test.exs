defmodule Troupe.Plane.OneRowPerPersonTest do
  @moduledoc """
  One row per person and per group on a plane fed by both SCIM and sign-in, and a SCIM
  `DELETE` that removes what it names (#707).

  The sequence a real plane goes through, in order: somebody signs in, the provider
  pushes them, the plane switches `subject_claim`, the provider pushes them again with
  the `externalId` it has always sent, and finally deletes them. Every step keeps one row,
  and the delete leaves a tombstone rather than a person.

  Then the planes that already hold duplicates: the migration that merges them, keeping
  SCIM's row, before the index that keeps them merged; and the people and groups that only
  look alike, which nothing merges and the admin API reports.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Identity, Login, Principals, Sessions, Settings}
  alias Troupe.Plane.Identity.{ServicePrincipal, Tombstone, User}
  alias Troupe.Plane.SCIM.Connector
  alias Troupe.Plane.Web.Router

  @migration Path.expand(
               "../../../priv/repo/migrations/20261013000899_one_row_per_person.exs",
               __DIR__
             )

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

  describe "a plane fed by SCIM and sign-in" do
    test "holds one row through a sign-in, a push, a claim switch and the next push, and a delete removes it",
         context do
      %{team: team} = context

      # Signed in first, then pushed with the `externalId` the provider maps from `sub`.
      {:ok, ada, _teams} = Login.from_claims(claims())
      assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert pushed["id"] == ada.id

      session = session!(ada, team)
      {:ok, _} = Identity.add_team_admin(team, ada.subject, "root@example.test")

      {:ok, principal, _secret} =
        principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

      # The plane switches to `oid`, and her next sign-in moves her there.
      subject_claim("oid")
      {:ok, moved, _teams} = Login.from_claims(claims())
      assert moved.id == ada.id
      assert moved.subject == @oid

      # The provider still sends what it always sent, and finds her.
      assert {200, again, _} = scim(context, :put, path(pushed), ada())
      assert again["id"] == ada.id
      assert [one] = Identity.list_users()
      assert one.subject == @oid
      assert one.external_id == @sub

      # Removed: the row goes, and its id is nobody's.
      assert {204, nil, _} = scim(context, :delete, path(pushed))
      assert {404, _, _} = scim(context, :get, path(pushed))
      assert {200, %{"totalResults" => 0}, _} = scim(context, :get, filter("externalId", @sub))
      assert Identity.list_users() == []

      # What outlives her is under the tombstone.
      assert [tombstone] = Repo.all(Tombstone)
      assert tombstone.former_id == ada.id
      assert tombstone.subject == @oid
      assert tombstone.kms_name == @sub

      kept = Sessions.get(session.id)
      assert kept.state == "read_only"
      assert kept.owner_subject == Tombstone.marker(tombstone)
      assert kept.owner_id == nil
      assert Identity.kms_name_of(kept.owner_subject) == @sub

      assert Identity.admins_of(team) == []
      assert ServicePrincipal.state(Principals.get(principal.subject)) == :needs_sponsor

      # The audit trail keeps her name.
      assert [removed] = audited("person.remove")
      assert removed.actor == "scim"
      assert removed.subject_id == @oid
      assert removed.detail["sessions"] == 1
      assert removed.detail["team_admin_of"] == ["engineering"]

      # Back under the same subject is somebody new, who inherits none of it.
      {:ok, back, _teams} = Login.from_claims(claims())
      refute back.id == ada.id
      assert back.kms_name == @oid
      assert Sessions.visible_to(back) |> Enum.filter(&(&1.id == session.id)) == []
      assert %{role: :none} = Admin.actor_for(back)
    end

    test "a sign-in finds the person SCIM knows by the externalId its subject is", context do
      subject_claim("oid")
      assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())

      # Under `oid`, her first sign-in moves SCIM's row from her `sub` to her `oid`.
      {:ok, moved, _teams} = Login.from_claims(claims())
      assert moved.id == pushed["id"]
      assert moved.subject == @oid

      # The plane goes back to `sub`. Nobody is under it now, but SCIM calls her by it.
      subject_claim(nil)
      {:ok, back, _teams} = Login.from_claims(claims())

      assert back.id == pushed["id"]
      assert back.subject == @sub
      assert [_one] = Identity.list_users()
      assert [_, _] = audited("person.rekey")
    end

    test "somebody removed and pushed again is new, and not named as the removed one", context do
      assert {201, pushed, _} = scim(context, :post, "/scim/v2/Users", ada())
      assert {204, nil, _} = scim(context, :delete, path(pushed))

      assert {201, again, _} = scim(context, :post, "/scim/v2/Users", ada())
      refute again["id"] == pushed["id"]

      # What the first one stored at the key manager is under their subject, and stays
      # theirs until it is erased.
      user = Identity.get_user(@sub)
      assert user.kms_name == user.id
      assert [%Tombstone{kms_name: @sub}] = Repo.all(Tombstone)
    end

    test "a group's delete removes it and disables the team drawn from it alone", context do
      %{team: engineering} = context
      eng = Identity.get_group("g-eng")
      {:ok, ops} = Identity.upsert_group(%{external_id: "g-ops", display_name: "Operations"})

      # A second team, enabled from the same group and drawing from another one too.
      {:ok, mixed} = Identity.enable_team(eng, %{name: "mixed"})
      {:ok, _link} = Identity.link_group(mixed, ops, "root@example.test")

      lead = person("lead@example.test", ["g-eng"])
      session = session!(lead, engineering)

      assert {204, nil, _} = scim(context, :delete, "/scim/v2/Groups/" <> eng.id)
      assert {404, _, _} = scim(context, :get, "/scim/v2/Groups/" <> eng.id)
      refute Identity.get_group("g-eng")

      refute Identity.get_team("engineering")
      assert Sessions.get(session.id).state == "read_only"

      mixed = Identity.get_team("mixed")
      assert mixed.group_id == ops.id
      assert Enum.map(Identity.links_of(mixed), & &1.group.external_id) == ["g-ops"]

      assert [disabled] = audited("team.disable")
      assert disabled.actor == "scim"
      assert disabled.subject_id == "engineering"

      assert [%{detail: %{"teams_disabled" => ["engineering"], "teams_kept" => ["mixed"]}}] =
               audited("group.delete")
    end
  end

  describe "a plane that already holds duplicates" do
    setup do
      Code.ensure_loaded?(Troupe.Plane.Repo.Migrations.OneRowPerPerson) ||
        Code.require_file(@migration)

      # As the plane was before the migration: the index on `external_id` not unique.
      Repo.query!("DROP INDEX users_external_id_index")
      Repo.query!("CREATE INDEX users_external_id_index ON users (external_id)")
      :ok
    end

    test "are merged into SCIM's row, audited and reported, and the index then builds",
         context do
      %{team: team} = context
      hour_ago = DateTime.add(DateTime.utc_now(), -3600)

      # The row a sign-in under `oid` moved, which still carries the `externalId` it was
      # pushed with, and the row the next push made under that value.
      moved =
        Repo.insert!(%User{
          subject: @oid,
          external_id: @sub,
          user_name: "ada@example.test",
          email: "ada@example.test",
          kms_name: @sub,
          budget_micros: 5_000_000,
          inserted_at: hour_ago,
          updated_at: hour_ago
        })

      id = Ecto.UUID.generate()

      pushed =
        Repo.insert!(%User{
          id: id,
          subject: @sub,
          external_id: @sub,
          user_name: "ada@example.test",
          email: "ada@example.test",
          kms_name: id
        })

      bo = person("bo@example.test")
      session = session!(moved, team)
      {:ok, _} = Sessions.grant_access(session.id, @oid, "viewer", @oid)
      {:ok, _} = Identity.add_team_admin(team, @oid, "root@example.test")

      assert [merged] = merge()

      assert merged == %{
               "external_id" => @sub,
               "kept" => pushed.id,
               "subject" => @sub,
               "folded" => [%{"id" => moved.id, "subject" => @oid}],
               "kms_names_left" => [pushed.id]
             }

      # SCIM's row, with what the moved one had, under the name it stored things under.
      assert [ada, also_bo] = Enum.sort_by(Identity.list_users(), & &1.email)
      assert also_bo.id == bo.id
      assert ada.id == pushed.id
      assert ada.kms_name == @sub
      assert ada.budget_micros == 5_000_000

      session = Sessions.get(session.id)
      assert session.owner_id == ada.id
      assert session.owner_subject == @sub
      assert Identity.admins_of(team) == [@sub]

      # Who granted what keeps the name it was written with.
      assert Repo.one(
               from(a in "session_acls", where: a.session_id == ^session.id, select: a.granted_by)
             ) == @oid

      assert [event] = audited("person.merge")
      assert event.actor == "migration:one_row_per_person"
      assert event.detail == merged
      assert Audit.verify().result == :ok

      Repo.query!("DROP INDEX users_external_id_index")

      Repo.query!(
        "CREATE UNIQUE INDEX users_external_id_index ON users (external_id) WHERE external_id IS NOT NULL"
      )

      assert merge() == []

      # And a person under the moved one's `oid` signs in as SCIM's row, moved back once.
      subject_claim("oid")
      {:ok, signed_in, _teams} = Login.from_claims(claims())
      assert signed_in.id == pushed.id
    end
  end

  describe "people and groups that only look alike" do
    test "are reported with the mismatch they most likely come from, and not merged", context do
      # A sign-in under `sub`, and a push whose `externalId` is her `oid`.
      {:ok, _signed_in, _teams} = Login.from_claims(Map.put(claims(), "groups", ["Platform"]))

      assert {201, _pushed, _} =
               scim(context, :post, "/scim/v2/Users", Map.put(ada(), "externalId", @oid))

      # A groups claim naming a group by its name, and SCIM pushing it by its id.
      uuid = "1b2c3d4e-5f60-4a7b-8c9d-0e1f2a3b4c5d"

      assert {201, _group, _} =
               scim(context, :post, "/scim/v2/Groups", %{
                 "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Group"],
                 "externalId" => uuid,
                 "displayName" => "Platform",
                 "members" => []
               })

      assert {:ok, %{people: [people], groups: [groups]}} = Admin.identity_duplicates(@root)

      assert people.by == "email"
      assert people.people |> Enum.map(& &1.origin) |> Enum.sort() == ["scim", "sign-in"]
      assert people.likely =~ "sub claim"

      assert groups.groups |> Enum.map(& &1.external_id) |> Enum.sort() ==
               Enum.sort(["Platform", uuid])

      assert groups.likely =~ "groups claim names this group by its name"

      assert {:ok, listed} = Admin.groups_list(@root)
      flagged = Map.new(listed, &{&1.external_id, &1.looks_duplicated})
      assert flagged["Platform"].others == [uuid]
      assert flagged[uuid].others == ["Platform"]
      assert flagged["g-eng"] == nil

      assert length(Identity.list_users()) == 2

      assert {:error, %{message: "forbidden"}} =
               Admin.identity_duplicates(%{
                 subject: "lead",
                 role: :team_admin,
                 teams: ["engineering"]
               })
    end
  end

  # -- helpers ----------------------------------------------------------------

  # The migration's merge, loaded from its file: migrations are not compiled with the app.
  defp merge, do: Module.concat(["Troupe.Plane.Repo.Migrations.OneRowPerPerson"]).merge(Repo)

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

  # Ada as a provider whose `externalId` mapping is the `sub` a plane on `sub` signs in by.
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

  defp session!(%User{} = owner, team) do
    {:ok, session} =
      Sessions.create(%{
        id: "s-#{System.unique_integer([:positive])}",
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        state: "dormant",
        epoch: 1
      })

    session
  end

  defp audited(action), do: Enum.filter(Audit.list(), &(&1.action == action))

  defp path(%{"meta" => %{"location" => location}}), do: location

  defp filter(attribute, value) do
    "/scim/v2/Users?" <> URI.encode_query(%{"filter" => ~s(#{attribute} eq "#{value}")})
  end

  # As a provider sends it, straight into the router.
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
