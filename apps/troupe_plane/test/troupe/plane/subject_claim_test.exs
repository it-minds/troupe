defmodule Troupe.Plane.SubjectClaimTest do
  @moduledoc """
  Which claim in a token is the person (Decision 751).

  Entra's `sub` is pairwise: a different string in every app registration, and not one its
  SCIM client can send. Its `oid` is the same in every registration of the tenant and is
  what SCIM sends as `externalId` once the attribute mapping says so. The tokens here have
  that shape — `sub` pairwise, `oid` and `tid` beside it — and the SCIM users carry the
  `oid` as their `externalId`.

  Against a real server over a real socket, as `WebTest` is: the exchange, the SCIM door
  and `/rpc` are the three places a person arrives, and the claim has to mean the same
  thing at each.
  """

  use Troupe.Plane.DataCase, async: false

  import ExUnit.CaptureLog

  alias Troupe.Plane.{Admin, Audit, Identity, Ledger, Principals, Sessions, Settings, Triggers}
  alias Troupe.Plane.Triggers.Trigger
  alias Troupe.Plane.Web.Router

  @moduletag timeout: 60_000

  @tenant "9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4"
  @ada_oid "3f2a6c1e-8b4d-4e7a-9c1b-2d5e8f0a7b6c"
  @ada_sub "kX9vQ2pL7mN4rT8wY1zA3bC5dE6fG0hJ-pairwise"

  setup do
    {:ok, listener} =
      start_supervised({Bandit, plug: Router, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    subject_claim(nil)
    Application.put_env(:troupe_plane, :oidc_verifier, &entra/1)
    Application.put_env(:troupe_plane, :scim_token, "scim-secret")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :oidc)
      Application.delete_env(:troupe_plane, :oidc_verifier)
      Application.delete_env(:troupe_plane, :scim_token)
    end)

    %{url: "http://127.0.0.1:#{port}"}
  end

  describe "with subject_claim oid" do
    test "a person SCIM provisioned from Entra and the same person signing in are one person",
         context do
      subject_claim("oid")

      assert {:ok, %{status: 200, body: provisioned}} = scim_user(context, entra_user())

      assert {:ok, %{status: 200, body: signed_in}} = exchange(context, "ada")
      assert signed_in["subject"] == @ada_oid

      assert [ada] = people_called("ada@example.test")
      assert ada.id == provisioned["id"]
      assert ada.subject == @ada_oid
      refute Identity.get_user(@ada_sub)
    end

    test "a token without the claim is refused, and says which claim it wanted", context do
      subject_claim("oid")

      assert {:ok, %{status: 401, body: body}} = exchange(context, "ada-without-oid")
      assert body["error"] == "unauthenticated"
      assert body["reason"] =~ "oid"
      assert people_called("ada@example.test") == []
    end

    test "is the deployment's to set, and the console's to read" do
      assert Settings.get("subject_claim") == "sub"

      subject_claim("oid")
      assert Settings.get("subject_claim") == "oid"
      assert {:error, :not_editable} = Settings.put("subject_claim", "email", "root@example.test")

      setting = Enum.find(Settings.all(), &(&1.key == "subject_claim"))
      assert setting.group == :sign_in
      refute setting.editable
    end
  end

  describe "the default" do
    test "is sub, and a provider whose sub lines up with SCIM sees no change", context do
      # Authentik with the subject mode set to the user's UUID: `sub` is what SCIM sends.
      uuid = "0b7e8a4c-2f1d-4c3b-9a6e-5d4c3b2a1f0e"

      bo = %{
        entra_user()
        | "externalId" => uuid,
          "userName" => "bo@example.test",
          "displayName" => "Bo",
          "emails" => [%{"primary" => true, "value" => "bo@example.test"}]
      }

      assert {:ok, %{status: 200}} = scim_user(context, bo)

      assert {:ok, %{status: 200, body: body}} = exchange(context, "uuid:" <> uuid)
      assert body["subject"] == uuid
      assert [_bo] = people_called("bo@example.test")

      # An Entra-shaped token under the default is keyed on its `sub`, as it always was.
      assert {:ok, %{status: 200, body: ada}} = exchange(context, "ada")
      assert ada["subject"] == @ada_sub
      assert rekeys() == []
    end
  end

  describe "switching on an installation that already has people" do
    setup context do
      team = team_with_grant("g-eng", "dev", name: "engineering")

      # Ada signed in before the switch, so the plane knows her by her pairwise `sub`.
      {:ok, %{status: 200, body: before}} = exchange(context, "ada")
      ada = Identity.get_user(@ada_sub)

      {:ok, session} =
        Sessions.create(%{
          id: "s-ada-#{System.unique_integer([:positive])}",
          owner_id: ada.id,
          owner_subject: ada.subject,
          team_id: team.id,
          profile: "dev",
          state: "dormant",
          epoch: 1
        })

      {:ok, _} = Identity.add_team_admin(team, ada.subject, "root@example.test")

      %{ada: ada, team: team, session: session, old_token: before["token"]}
    end

    test "re-keys her once, at her next sign-in, keeping her session, grant and team", context do
      subject_claim("oid")

      {{:ok, %{status: 200, body: body}}, log} = with_log(fn -> exchange(context, "ada") end)

      assert body["subject"] == @ada_oid
      assert body["teams"] == ["engineering"]
      assert body["profiles"] == ["dev"]

      # The same row under its new key, and nobody left under the old one.
      rekeyed = Identity.get_user(@ada_oid)
      assert rekeyed.id == context.ada.id
      refute Identity.get_user(@ada_sub)

      # Her session is hers: on its row, and in what she is shown.
      assert Sessions.get(context.session.id).owner_subject == @ada_oid
      assert {:ok, %{status: 200, body: listed}} = rpc(context, body["token"], "sessions.list")
      assert context.session.id in Enum.map(listed["result"]["sessions"], & &1["id"])

      # The team she administers, and the team she is in.
      assert %{role: :team_admin, teams: ["engineering"]} = Admin.actor_for(rekeyed)
      assert Enum.map(Identity.teams_for(rekeyed), & &1.name) == ["engineering"]

      # Logged and audited with the two identifiers and nothing else from the token.
      assert [event] = rekeys()
      assert event.detail == %{"from" => @ada_sub, "to" => @ada_oid, "claim" => "oid"}
      assert log =~ @ada_sub and log =~ @ada_oid
      refute log =~ @tenant
      refute log =~ "ada@example.test"
    end

    test "moves what names her everywhere else, and leaves what she did as it was", context do
      %{ada: ada, team: team, session: session} = context
      {:ok, _} = Sessions.grant_access(session.id, ada.subject, "viewer", ada.subject)

      {:ok, _share, _secret} =
        Sessions.mint_share(session.id, %{
          role: "observe",
          created_by: ada.subject,
          expires_at: DateTime.add(DateTime.utc_now(), 3600),
          audience: ada.subject
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

      {:ok, _} = Ledger.reserve(team.id, session.id, ada.subject, 1_000)

      {:ok, principal, _secret} =
        principal!(team, %{name: "nightly", profiles: ["dev"], sponsor: ada.subject})

      {:ok, run} =
        Sessions.create(%{
          id: "s-run-#{System.unique_integer([:positive])}",
          owner_subject: principal.subject,
          team_id: team.id,
          profile: "dev",
          state: "dormant",
          epoch: 1,
          origin: %{
            "kind" => "trigger",
            "principal" => %{"subject" => ada.subject, "actor" => principal.subject}
          }
        })

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

      subject_claim("oid")
      assert {:ok, %{status: 200}} = exchange(context, "ada")

      assert column("session_acls", :subject, session.id) == [@ada_oid]
      assert column("session_shares", :audience, session.id) == [@ada_oid]
      assert column("usage_records", :owner_subject, session.id) == [@ada_oid]
      assert column("budget_reservations", :owner_subject, session.id) == [@ada_oid]
      assert Ledger.spent_micros_for(@ada_oid) == 5
      assert Principals.get(principal.subject).sponsor_subject == @ada_oid

      assert Sessions.get(run.id).origin["principal"] == %{
               "subject" => @ada_oid,
               "actor" => principal.subject
             }

      assert Repo.get(Trigger, trigger.id).notify == [@ada_oid, "bo@example.test"]

      # Who did what is history, and keeps the name it was written with.
      assert [%{created_by: @ada_sub}] = Sessions.shares_of(session.id)

      assert Repo.one(
               from(a in "session_acls", where: a.session_id == ^session.id, select: a.granted_by)
             ) == @ada_sub
    end

    test "a second sign-in does not re-key her again", context do
      subject_claim("oid")

      assert {:ok, %{status: 200}} = exchange(context, "ada")
      assert {:ok, %{status: 200, body: again}} = exchange(context, "ada")

      assert again["subject"] == @ada_oid
      assert Identity.get_user(@ada_oid).id == context.ada.id
      assert length(rekeys()) == 1
    end

    test "a plane token minted before the re-key is refused as naming nobody", context do
      subject_claim("oid")
      assert {:ok, %{status: 200}} = rpc(context, context.old_token, "me")

      assert {:ok, %{status: 200}} = exchange(context, "ada")

      assert {:ok, %{status: 401, body: body}} = rpc(context, context.old_token, "me")
      assert body["error"]["message"] == "unauthenticated"
    end

    test "when SCIM got there first, her old row is folded into the one SCIM made", context do
      subject_claim("oid")
      {:ok, %{status: 200, body: provisioned}} = scim_user(context, entra_user())

      assert {:ok, %{status: 200, body: body}} = exchange(context, "ada")
      assert body["subject"] == @ada_oid
      assert body["teams"] == ["engineering"]

      assert [ada] = people_called("ada@example.test")
      assert ada.id == provisioned["id"]
      refute Identity.get_user(@ada_sub)

      session = Sessions.get(context.session.id)
      assert session.owner_id == ada.id
      assert session.owner_subject == @ada_oid
      assert %{role: :team_admin} = Admin.actor_for(ada)

      assert [event] = rekeys()
      assert event.detail["from"] == @ada_sub
      assert event.detail["merged"] == true
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp subject_claim(claim) do
    Application.put_env(
      :troupe_plane,
      :oidc,
      [
        issuer: "https://login.example.test/#{@tenant}/v2.0",
        client_id: "troupe-cli",
        device_authorization_endpoint: "https://login.example.test/devicecode",
        token_endpoint: "https://login.example.test/token"
      ] ++ if(claim, do: [subject_claim: claim], else: [])
    )
  end

  # What Entra's id_token carries for Ada, and what it carries when `oid` is left out —
  # a v2 token without the `profile` scope has none.
  defp entra("ada"), do: {:ok, ada_claims()}
  defp entra("ada-without-oid"), do: {:ok, Map.delete(ada_claims(), "oid")}

  defp entra("uuid:" <> uuid) do
    {:ok, %{"sub" => uuid, "email" => "bo@example.test", "name" => "Bo", "groups" => []}}
  end

  defp entra(_token), do: {:error, :bad_signature}

  defp ada_claims do
    %{
      "sub" => @ada_sub,
      "oid" => @ada_oid,
      "tid" => @tenant,
      "email" => "ada@example.test",
      "name" => "Ada Lovelace",
      "preferred_username" => "ada@example.test",
      "groups" => ["g-eng"]
    }
  end

  # The user Entra's provisioning client sends once `externalId` is mapped from `objectId`.
  defp entra_user do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:User"],
      "externalId" => @ada_oid,
      "userName" => "ada@example.test",
      "active" => true,
      "displayName" => "Ada Lovelace",
      "name" => %{"givenName" => "Ada", "familyName" => "Lovelace"},
      "emails" => [%{"primary" => true, "type" => "work", "value" => "ada@example.test"}]
    }
  end

  defp column(table, name, session_id) do
    Repo.all(from(r in table, where: r.session_id == ^session_id, select: field(r, ^name)))
  end

  defp people_called(email) do
    Enum.filter(Identity.list_users(), &(&1.email == email))
  end

  defp rekeys, do: Enum.filter(Audit.list(), &(&1.action == "person.rekey"))

  defp exchange(context, id_token), do: post(context, "/auth/exchange", %{"id_token" => id_token})

  defp scim_user(context, resource) do
    post(context, "/scim/v2/Users", resource, [{"authorization", "Bearer scim-secret"}])
  end

  defp rpc(context, token, method) do
    post(context, "/rpc", %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => %{}}, [
      {"authorization", "Bearer " <> token}
    ])
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
end
