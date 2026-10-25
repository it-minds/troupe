defmodule Troupe.Plane.InvitesTest do
  @moduledoc """
  A person invites another into their session by name (#765).

  A pod session's invitation is its grant made visible: the ACL row, the pod told, the
  log's line through the pod, a row that says who invited whom and when, and the invitee
  told over their watch. Only a person the session's profile covers may be invited, or a
  platform administrator.

  A private session's key follows the invitation, which is proven against the development
  OpenBao rather than our belief about it: the owner's daemon puts the key in the invitee's
  own slot, the plane holds the path with a credential that can destroy what is there and
  cannot read it, the invitee's credential reads it and the owner's cannot, taking it back
  destroys that copy and re-keys forward, and an erasure destroys every copy.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.KMS
  alias Troupe.KMS.{OpenBao, Policy}

  alias Troupe.Plane.{
    Audit,
    Erasure,
    FakePod,
    Fleet,
    Harness,
    Identity,
    Invites,
    PersonAuth,
    Sessions,
    Tokens
  }

  alias Troupe.Plane.Control.{Connections, Listener}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.{Client, SessionId}

  @moduletag timeout: 60_000

  @auth_path "jwt-invites"
  @role "troupe-person"
  @issuer "https://plane.test.invalid"

  setup do
    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    %{port: Listener.port()}
  end

  describe "a pod session" do
    test "an owner invites a member of the profile's teams by email, and the grant is made visible",
         %{port: port} do
      team = team_with_grant("eng", "dev", name: "eng")
      ada = person("ada@example.test", ["eng"])
      bea = person("bea@example.test", ["eng"])
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)

      assert {:error, %{message: "not_found"}} =
               Harness.call("session.get", %{"session_id" => session.id}, as(bea))

      assert {:ok, answer} =
               Harness.call(
                 "session.invite",
                 %{
                   "session_id" => session.id,
                   "subject" => "BEA@example.test@example.test",
                   "role" => "observe"
                 },
                 as(ada)
               )

      assert answer["invite"]["subject"] == bea.subject
      assert answer["invite"]["role"] == "observe"
      assert answer["invite"]["invited_by"] == ada.subject
      assert answer["pushed"]

      # The grant, pushed to the pod so an open connection sees it now, and the log's line.
      assert_receive {:pushed, "acl.changed", %{"changes" => [change]}}, 5_000
      assert change == %{"session_id" => session.id, "subject" => bea.subject, "role" => "viewer"}

      assert_receive {:pushed, "invite.changed", pushed}, 5_000
      assert pushed["type"] == "session_invited"

      assert pushed["invite"] == %{
               "subject" => bea.subject,
               "display_name" => bea.display_name,
               "role" => "observe",
               "by" => ada.subject,
               "by_name" => ada.display_name
             }

      # She sees it as a viewer, and in her own list of invitations.
      assert {:ok, %{"your_role" => "viewer"}} =
               Harness.call("session.get", %{"session_id" => session.id}, as(bea))

      assert {:ok, %{"invites" => [invited]}} = Harness.call("invites.list", %{}, as(bea))
      assert invited["session_id"] == session.id
      assert invited["role"] == "observe"
      assert invited["owner"] == ada.subject
      assert invited["invited_by_name"] == ada.display_name
      assert invited["kind"] == "team"

      # Everybody present is named, to anybody who may see the session.
      assert {:ok, %{"invites" => [named]}} =
               Harness.call("session.invites", %{"session_id" => session.id}, as(bea))

      assert named["subject"] == bea.subject

      # Asked again for control, the role changes and stays one invitation.
      assert {:ok, %{"invite" => %{"role" => "control"}}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => bea.subject, "role" => "control"},
                 as(ada)
               )

      assert_receive {:pushed, "acl.changed", %{"changes" => [%{"role" => "collaborator"}]}},
                     5_000

      assert [_one] = Invites.of_session(session.id)

      assert {:ok, %{"your_role" => "collaborator"}} =
               Harness.call("session.get", %{"session_id" => session.id}, as(bea))

      assert audited?(ada.subject, "session.invite", session.id)
    end

    test "nobody the profile does not cover is invited, and nothing is written", %{port: port} do
      team = team_with_grant("eng", "dev", name: "eng")
      _design = team_with_grant("design", "ux", name: "design")
      ada = person("ada@example.test", ["eng"])
      dan = person("dan@example.test", ["design"])
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)

      assert {:error, refused} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => dan.subject},
                 as(ada)
               )

      assert refused.message == "forbidden"
      assert refused.data.reason == "not on this profile's teams"
      assert refused.data.profile == "dev"
      assert Invites.of_session(session.id) == []
      assert Sessions.role_for(dan, session) == nil
      refute_received {:pushed, "acl.changed", _}

      assert {:error, %{message: "not_found"}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => "nobody@example.test"},
                 as(ada)
               )

      # Ada is the owner, not an invitee; and a role nobody defined is refused.
      assert {:error, %{message: "invalid_params"}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => ada.subject},
                 as(ada)
               )
    end

    test "a platform administrator may be invited by anybody", %{port: port} do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      team = team_with_grant("eng", "dev", name: "eng")
      ada = person("ada@example.test", ["eng"])
      root = person("root@example.test", ["platform"])
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)

      assert {:ok, %{"invite" => %{"subject" => "root@example.test"}}} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => session.id, "subject" => root.subject, "role" => "control"},
                 as(ada)
               )
    end

    test "only the owner or the team's admin invites; a collaborator and a stranger do not",
         %{port: port} do
      team = team_with_grant("eng", "dev", name: "eng")
      ada = person("ada@example.test", ["eng"])
      bea = person("bea@example.test", ["eng"])
      cy = person("cy@example.test", ["eng"])
      lead = person("lead@example.test", ["eng"])
      stranger = person("nobody@example.test", [])
      {:ok, _} = Identity.add_team_admin(team, lead.subject, "root@example.test")
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)

      {:ok, _} = invite(ada, session, bea, "control")

      assert {:error, %{message: "forbidden"}} = invite(bea, session, cy, "observe")
      assert {:error, %{message: "not_found"}} = invite(stranger, session, cy, "observe")
      assert {:ok, _} = invite(lead, session, cy, "observe")
    end

    test "taking it back ends the grant, tells the pod and the log, and the invitee loses it",
         %{port: port} do
      team = team_with_grant("eng", "dev", name: "eng")
      ada = person("ada@example.test", ["eng"])
      bea = person("bea@example.test", ["eng"])
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)
      {:ok, _} = invite(ada, session, bea, "control")
      assert_receive {:pushed, "invite.changed", %{"type" => "session_invited"}}, 5_000

      :ok = Invites.subscribe()

      assert {:ok, answer} =
               Harness.call(
                 "session.uninvite",
                 %{"session_id" => session.id, "subject" => bea.email},
                 as(ada)
               )

      assert answer["subject"] == bea.subject
      assert answer["rekey_due"] == false

      assert_receive {:pushed, "acl.changed",
                      %{"changes" => [%{"subject" => subject, "role" => nil}]}},
                     5_000

      assert subject == bea.subject

      assert_receive {:pushed, "invite.changed",
                      %{"type" => "session_uninvited", "invite" => removed}},
                     5_000

      assert removed["subject"] == bea.subject
      refute Map.has_key?(removed, "role")
      assert_receive {:invites_changed, [^subject]}, 1_000

      assert {:error, %{message: "not_found"}} =
               Harness.call("session.get", %{"session_id" => session.id}, as(bea))

      assert {:ok, %{"invites" => []}} = Harness.call("invites.list", %{}, as(bea))
      assert audited?(ada.subject, "session.uninvite", session.id)

      # Twice is a person not invited.
      assert {:error, %{message: "not_found"}} =
               Harness.call(
                 "session.uninvite",
                 %{"session_id" => session.id, "subject" => bea.subject},
                 as(ada)
               )
    end

    test "a picker finds people by the start of their name, only among those the caller may invite or meets",
         %{port: port} do
      team = team_with_grant("eng", "dev", name: "eng")
      _design = team_with_grant("design", "ux", name: "design")
      ada = person("ada@example.test", ["eng"])
      _bea = person("bea@example.test", ["eng"])
      _ben = person("ben@example.test", ["eng"])
      _bob = person("bob@example.test", ["design"])
      pod = FakePod.enrol(port, "dev-token", "troupe-w-dev-0")
      session = running(ada, team, pod)

      assert {:ok, %{"people" => people}} =
               Harness.call(
                 "people.search",
                 %{"query" => "Be", "session_id" => session.id},
                 as(ada)
               )

      assert Enum.map(people, & &1["subject"]) == ["bea@example.test", "ben@example.test"]

      assert {:ok, %{"people" => []}} =
               Harness.call("people.search", %{"query" => "bob"}, as(ada))

      assert {:ok, %{"people" => [_one]}} =
               Harness.call("people.search", %{"query" => "be", "limit" => 1}, as(ada))

      assert {:ok, %{"people" => []}} =
               Harness.call("people.search", %{"query" => "ada"}, as(ada))
    end
  end

  describe "a person's watch" do
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

      on_exit(fn ->
        Application.delete_env(:troupe_plane, :oidc)
        Application.delete_env(:troupe_plane, :oidc_verifier)
      end)

      %{http: "http://127.0.0.1:#{port}", ws: "ws://127.0.0.1:#{port}"}
    end

    test "tells the invitee of an invitation and of it taken back, and nobody else", ctx do
      bea_token = plane_token(ctx, "bea@example.test")
      cy_token = plane_token(ctx, "cy@example.test")
      team = team_with_grant("eng", "dev", name: "eng")
      ada = person("ada@example.test", ["eng"])
      bea = person("bea@example.test", ["eng"])
      _cy = person("cy@example.test", ["eng"])

      pod =
        FakePod.enrol(ctx.port, "dev-token", "troupe-w-dev-0",
          notify: spawn(fn -> Process.sleep(:infinity) end)
        )

      session = running(ada, team, pod)

      {:ok, watch} =
        Client.connect(
          url: ctx.ws <> "/v1/relay/watch",
          token: bea_token,
          client_info: %{"name" => "t", "version" => "1"}
        )

      on_exit(fn -> Client.close(watch) end)
      cy_owner = spawn_link(fn -> collect([]) end)

      {:ok, cy_watch} =
        Client.connect(
          url: ctx.ws <> "/v1/relay/watch",
          token: cy_token,
          client_info: %{"name" => "t", "version" => "1"},
          owner: cy_owner
        )

      on_exit(fn -> Client.close(cy_watch) end)

      assert {:ok, %{"invites" => []}} = Client.call(watch, "invites.list", %{})

      {:ok, _} = invite(ada, session, bea, "observe")
      assert_receive {:troupe_notification, "invites.changed", %{"invites" => [row]}}, 1_000
      assert row["session_id"] == session.id
      assert row["role"] == "observe"

      {:ok, _} =
        Harness.call(
          "session.uninvite",
          %{"session_id" => session.id, "subject" => bea.subject},
          as(ada)
        )

      assert_receive {:troupe_notification, "invites.changed", %{"invites" => []}}, 1_000

      send(cy_owner, {:report, self()})
      assert_receive {:cy_saw, []}, 1_000
    end
  end

  describe "a private session" do
    setup context do
      if PersonAuth.reachable?(),
        do: with_bao(context),
        else: no_bao()
    end

    test "its key is put in the invitee's own slot: the plane and the owner cannot read it there, the invitee can",
         %{plane: plane} = context do
      requires_bao(context)
      %{ada: ada, bea: bea, id: id, k1: k1, group: group} = private_session(context)

      assert {:ok, answer} = invite_private(ada, id, bea, "observe")
      assert answer["invite"]["subject"] == bea.subject
      refute answer["pushed"]

      # What the plane keeps is where the key is, in Bea's subtree, and not the key.
      assert [%{key_version: 1, slot: slot}] = Invites.keys_for(id, bea.subject)
      assert String.starts_with?(slot, "troupe/people/#{User.kms_name(bea)}/invited/#{id}/k1-")

      # The plane's own credential cannot read it, knowing exactly where it is.
      assert {:error, :forbidden} =
               OpenBao.fetch_at(slot, token: plane, address: PersonAuth.address())

      # Nor can the owner who put it there, nor put another over it: giving is all it may.
      ada_token = login(ada, id)

      assert {:error, :forbidden} =
               OpenBao.fetch_at(slot, token: ada_token, address: PersonAuth.address())

      refute :ok ==
               OpenBao.put_at(slot, :crypto.strong_rand_bytes(32),
                 token: ada_token,
                 address: PersonAuth.address()
               )

      # Nor anybody else invited into nothing, with a sign-in of their own.
      cy = person("cy-#{unique()}@example.test", [group])

      assert {:error, :forbidden} =
               OpenBao.fetch_at(slot, token: own_login(cy), address: PersonAuth.address())

      # Bea's daemon, with her own sign-in at the key manager, reads it.
      assert {:ok, keys} = Harness.call("session.keys", %{"session_id" => id}, as(bea))
      assert keys["key_version"] == 1
      assert [%{"key_version" => 1, "slot" => ^slot}] = keys["keys"]
      {:ok, %{token: bea_token}} = spend(keys)
      assert {:ok, ^k1} = OpenBao.fetch_at(slot, token: bea_token, address: PersonAuth.address())

      # And she may fetch the sealed copy, and never write to it.
      key = "sessions/#{id}/segments/000000000001-000000000001-000000000003.seg"

      assert {:ok, %{"urls" => %{^key => _url}}} =
               Harness.call(
                 "session.presign",
                 %{"session_id" => id, "method" => "get", "keys" => [key]},
                 as(bea)
               )

      assert {:ok, %{"keys" => _}} =
               Harness.call("session.objects", %{"session_id" => id}, as(bea))

      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.presign",
                 %{"session_id" => id, "method" => "put", "keys" => [key]},
                 as(bea)
               )

      # Listed to her, and not as a session of her own.
      assert {:ok, %{"invites" => [%{"session_id" => ^id, "kind" => "private"}]}} =
               Harness.call("invites.list", %{}, as(bea))

      assert {:ok, %{"sessions" => []}} = Harness.call("sessions.list", %{}, as(bea))

      assert {:ok, %{"invites" => [%{"subject" => subject}]}} =
               Harness.call("session.invites", %{"session_id" => id}, as(bea))

      assert subject == bea.subject
    end

    test "is invited only from the machine that seals it, with every key it has had, in the invitee's slot",
         context do
      requires_bao(context)
      %{ada: ada, bea: bea, id: id} = private_session(context)

      assert {:error, refused} =
               Harness.call(
                 "session.invite",
                 %{"session_id" => id, "subject" => bea.subject},
                 as(ada)
               )

      assert refused.message == "invalid_params"
      assert refused.data.field == "keys"
      assert Invites.of_session(id) == []

      # A path outside her slot is not hers to be given, and not the plane's to destroy later.
      elsewhere = "troupe/people/#{User.kms_name(bea)}/mcp/jira"

      assert {:error, %{message: "invalid_params", data: %{field: "keys"}}} =
               Harness.call(
                 "session.invite",
                 %{
                   "session_id" => id,
                   "subject" => bea.subject,
                   "keys" => [%{"key_version" => 1, "slot" => elsewhere}]
                 },
                 as(ada)
               )

      # Somebody who shares no team with her is not invited, and is told so before anything
      # is put anywhere.
      stranger = person("dan-#{unique()}@example.test", ["elsewhere-#{unique()}"])

      assert {:error,
              %{message: "forbidden", data: %{reason: "shares no team with this session's owner"}}} =
               Harness.call(
                 "session.invite_slot",
                 %{"session_id" => id, "subject" => stranger.subject},
                 as(ada)
               )

      # And nobody but the owner asks where to put it.
      assert {:error, %{message: "forbidden"}} =
               Harness.call(
                 "session.invite_slot",
                 %{"session_id" => id, "subject" => bea.subject},
                 as(bea)
               )

      # To steer it, which its owner's offer makes possible while it stands.
      assert Invites.of_session(id) == []
      assert {:ok, _} = invite_private(ada, id, bea, "control")
      assert [%{subject: subject, role: "control"}] = Invites.of_session(id)
      assert subject == bea.subject
    end

    test "taking an invitation back re-keys forward: what follows is under a key the person removed never gets",
         context do
      requires_bao(context)
      %{ada: ada, bea: bea, id: id, k1: k1, root: root, group: group} = private_session(context)
      cy = person("cy-#{unique()}@example.test", [group])
      {:ok, _} = invite_private(ada, id, bea, "observe")
      {:ok, _} = invite_private(ada, id, cy, "observe")
      [%{slot: bea_slot}] = Invites.keys_for(id, bea.subject)
      assert key_present?(root, bea_slot)

      assert {:ok, %{"rekey_due" => true}} =
               Harness.call(
                 "session.uninvite",
                 %{"session_id" => id, "subject" => bea.subject},
                 as(ada)
               )

      # Her copy is destroyed in her slot, and nothing more is handed to her.
      refute key_present?(root, bea_slot)
      assert Sessions.get(id).rekey_due
      assert Invites.keys_for(id, bea.subject) == []

      assert {:error, %{message: "not_found"}} =
               Harness.call("session.keys", %{"session_id" => id}, as(bea))

      assert {:error, %{message: "forbidden"}} =
               Harness.call("session.objects", %{"session_id" => id}, as(bea))

      # The owner's daemon seals under the next generation, put in Cy's slot: Cy is still in.
      token = login(ada, id)
      path2 = KMS.path({:person, User.kms_name(ada)}, KMS.generation(id, 2))

      {:ok, k2} =
        OpenBao.create({:person, User.kms_name(ada)}, KMS.generation(id, 2),
          token: token,
          address: PersonAuth.address()
        )

      refute k2 == k1
      assert key_present?(root, path2)

      # Not without everybody still invited.
      assert {:error, %{message: "invalid_params", data: %{missing: [missing]}}} =
               Harness.call(
                 "session.rekeyed",
                 %{"session_id" => id, "key_version" => 2, "keys" => []},
                 as(ada)
               )

      assert missing == cy.subject

      cy_slot = put_for(ada, id, cy, 2, k2)

      assert {:ok, row} =
               Harness.call(
                 "session.rekeyed",
                 %{
                   "session_id" => id,
                   "key_version" => 2,
                   "keys" => [%{"subject" => cy.subject, "slot" => cy_slot}]
                 },
                 as(ada)
               )

      assert row["key_version"] == 2
      assert row["rekey_due"] == false

      # Cy has both keys, and reads all of it.
      assert {:ok, keys} = Harness.call("session.keys", %{"session_id" => id}, as(cy))
      assert Enum.map(keys["keys"], & &1["key_version"]) == [1, 2]
      {:ok, %{token: cy_token}} = spend(keys)

      assert [{:ok, ^k1}, {:ok, ^k2}] =
               Enum.map(
                 keys["keys"],
                 &OpenBao.fetch_at(&1["slot"], token: cy_token, address: PersonAuth.address())
               )

      # Bea, invited again, is given every key there is, or is not invited.
      assert {:error, %{message: "invalid_params"}} =
               invite_private(ada, id, bea, "observe", [k1])

      assert {:ok, _} = invite_private(ada, id, bea, "observe", [k1, k2])
    end

    test "an erasure destroys every generation of its key and every copy in an invitee's slot",
         context do
      requires_bao(context)
      %{ada: ada, bea: bea, id: id, k1: k1, root: root} = private_session(context)
      {:ok, _} = invite_private(ada, id, bea, "observe")

      {:ok, _} =
        Harness.call("session.uninvite", %{"session_id" => id, "subject" => bea.subject}, as(ada))

      {:ok, k2} =
        OpenBao.create({:person, User.kms_name(ada)}, KMS.generation(id, 2),
          token: login(ada, id),
          address: PersonAuth.address()
        )

      {:ok, _} =
        Harness.call(
          "session.rekeyed",
          %{"session_id" => id, "key_version" => 2, "keys" => []},
          as(ada)
        )

      {:ok, _} = invite_private(ada, id, bea, "observe", [k1, k2])
      slots = for key <- Invites.keys_for(id, bea.subject), do: key.slot
      assert length(slots) == 2

      paths = for v <- [1, 2], do: KMS.path({:person, User.kms_name(ada)}, KMS.generation(id, v))
      assert Enum.all?(paths ++ slots, &key_present?(root, &1))

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      refute Enum.any?(paths ++ slots, &key_present?(root, &1))
      assert Invites.keys_for(id, bea.subject) == []
      assert Invites.of_session(id) == []
      assert {:ok, %{"invites" => []}} = Harness.call("invites.list", %{}, as(bea))
    end

    test "an erasure stays pending while a copy in an invitee's slot cannot be destroyed",
         context do
      requires_bao(context)
      %{ada: ada, bea: bea, id: id, root: root} = private_session(context)
      {:ok, _} = invite_private(ada, id, bea, "observe")
      [%{slot: slot}] = Invites.keys_for(id, bea.subject)

      # A plane given its erasure policy and not the invitations grant.
      transit = Application.get_env(:troupe_plane, :transit, [])
      narrow = token_for(root, [Policy.plane("secret"), Policy.signing()])
      Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, narrow))

      assert {:ok, %{"erased" => false, "state" => "erasure_pending"}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      assert key_present?(root, slot)
      assert [_kept] = Invites.keys_for(id, bea.subject)

      Application.put_env(:troupe_plane, :transit, transit)

      assert {:ok, %{"erased" => true}} =
               Harness.call("session.erase", %{"session_id" => id}, as(ada))

      refute key_present?(root, slot)
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp as(user), do: %{user: user, platform_admin?: false}

  defp no_bao do
    IO.puts(
      :stderr,
      "\nSKIPPED: no OpenBao (#{PersonAuth.address()}); bring one up with `scripts/dev-up`.\n"
    )

    {:ok, skip: "no OpenBao"}
  end

  defp with_bao(context) do
    Application.put_env(:troupe_plane, :issuer, @issuer)
    Application.put_env(:troupe_plane, :person_auth_path, @auth_path)

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :issuer)
      Application.delete_env(:troupe_plane, :person_auth_path)
    end)

    :ok = PersonAuth.configure(@auth_path, @role, @issuer)

    # The plane's credential for the length of each test: its policies, the invites grant
    # among them, and nothing more. The root token stays in hand for what an operator writes.
    transit = Application.get_env(:troupe_plane, :transit, [])
    root = transit[:token]
    plane = token_for(root, [Policy.plane("secret"), Policy.signing(), Policy.invites()])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :token, plane))
    on_exit(fn -> Application.put_env(:troupe_plane, :transit, transit) end)

    start_supervised!({Task.Supervisor, name: Erasure.Tasks})
    {:ok, Map.merge(context, %{root: root, plane: plane})}
  end

  # A session of the team's on the fake pod, as a placement leaves one.
  defp running(owner, team, pod) do
    {:ok, session} =
      Sessions.create(%{
        id: SessionId.generate(),
        owner_id: owner.id,
        owner_subject: owner.subject,
        team_id: team.id,
        profile: "dev",
        visibility: "private",
        state: "active",
        epoch: 1
      })

    {:ok, placed} = Sessions.place(session.id, Fleet.get_worker(pod.worker_id))
    placed
  end

  # A watch's owner that keeps what it was told, and says so when asked.
  defp collect(seen) do
    receive do
      {:troupe_notification, "invites.changed", %{"invites" => invites}} ->
        collect([invites | seen])

      {:report, to} ->
        send(to, {:cy_saw, seen})

      _other ->
        collect(seen)
    end
  end

  defp invite(by, session, invitee, role) do
    Harness.call(
      "session.invite",
      %{"session_id" => session.id, "subject" => invitee.subject, "role" => role},
      as(by)
    )
  end

  defp audited?(actor, action, session_id) do
    Repo.exists?(
      from(a in Audit.Event,
        where: a.actor == ^actor and a.action == ^action and a.subject_id == ^session_id
      )
    )
  end

  # Ada's private session, registered, with the first key her daemon makes for it; Bea in a
  # team with her.
  defp private_session(context) do
    group = "eng-#{unique()}"
    _team = team_with_grant(group, "dev", name: group)
    ada = person("ada-#{unique()}@example.test", [group])
    bea = person("bea-#{unique()}@example.test", [group])
    id = SessionId.generate()

    {:ok, _row} =
      Harness.call("session.register", %{"session_id" => id, "device" => "ada-laptop"}, as(ada))

    token = login(ada, id)

    {:ok, k1} =
      OpenBao.create({:person, User.kms_name(ada)}, id,
        token: token,
        address: PersonAuth.address()
      )

    Map.merge(context, %{ada: ada, bea: bea, id: id, k1: k1, group: group})
  end

  # What the owner's daemon does to invite: ask where, put each key in the invitee's slot
  # with its own sign-in, and tell the plane the paths. Every key the session has had, by
  # default.
  defp invite_private(owner, id, invitee, role, keys \\ nil) do
    keys = keys || for v <- 1..Sessions.get(id).key_version, do: login_key(owner, id, v)

    slots =
      keys
      |> Enum.with_index(1)
      |> Enum.map(fn {key, version} ->
        %{"key_version" => version, "slot" => put_for(owner, id, invitee, version, key)}
      end)

    Harness.call(
      "session.invite",
      %{"session_id" => id, "subject" => invitee.subject, "role" => role, "keys" => slots},
      as(owner)
    )
  end

  defp put_for(owner, id, invitee, version, key) do
    {:ok, where} =
      Harness.call(
        "session.invite_slot",
        %{"session_id" => id, "subject" => invitee.subject},
        as(owner)
      )

    slot =
      where["prefix"] <>
        "k#{version}-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    :ok = OpenBao.put_at(slot, key, token: login(owner, id), address: PersonAuth.address())
    slot
  end

  # A person's own sign-in at the key manager, as any client of theirs gets one.
  defp own_login(user) do
    {:ok, assertion, _claims} = Tokens.mint_kms_assertion(User.kms_name(user))
    {:ok, %{token: token}} = OpenBao.jwt_login(PersonAuth.address(), @auth_path, @role, assertion)
    token
  end

  defp login_key(owner, id, version) do
    {:ok, key} =
      OpenBao.fetch({:person, User.kms_name(owner)}, KMS.generation(id, version),
        token: login(owner, id),
        address: PersonAuth.address()
      )

    key
  end

  # The owner's daemon's sign-in at the key manager, as `session.assertion` gives it one.
  defp login(owner, id) do
    {:ok, grant} = Harness.call("session.assertion", %{"session_id" => id}, as(owner))
    {:ok, %{token: token}} = spend(grant)
    token
  end

  defp spend(%{"assertion" => assertion, "key_manager" => manager}) do
    OpenBao.jwt_login(manager["address"], manager["auth_path"], manager["role"], assertion)
  end

  defp requires_bao(%{skip: reason}), do: flunk("skipped: #{reason}")
  defp requires_bao(_context), do: :ok

  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp key_present?(root, path) do
    case Req.request(
           method: :get,
           url: PersonAuth.address() <> "/v1/secret/metadata/#{encode(path)}",
           headers: [{"x-vault-token", root}],
           retry: false
         ) do
      {:ok, %{status: 200}} -> true
      {:ok, %{status: 404}} -> false
    end
  end

  defp token_for(root, policies) do
    names =
      for policy <- policies do
        name = "test-#{unique()}"
        :ok = as_root(root, "/v1/sys/policies/acl/#{name}", %{"policy" => policy})
        name
      end

    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: PersonAuth.address() <> "/v1/auth/token/create",
        headers: [{"x-vault-token", root}],
        json: %{"policies" => names, "ttl" => "10m", "no_parent" => true},
        decode_body: true,
        retry: false
      )

    get_in(body, ["auth", "client_token"])
  end

  # The root token's own write, since the plane's configuration holds the plane's token for
  # the length of a test.
  defp as_root(root, path, body) do
    case Req.request(
           method: :post,
           url: PersonAuth.address() <> path,
           headers: [{"x-vault-token", root}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end

  defp fake_verify("good:" <> subject) do
    {:ok, %{"sub" => subject, "email" => subject, "name" => subject, "groups" => ["eng"]}}
  end

  defp fake_verify(_token), do: {:error, :bad_signature}

  defp plane_token(ctx, subject) do
    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: ctx.http <> "/auth/exchange",
        json: %{"id_token" => "good:#{subject}"},
        retry: false
      )

    body["token"]
  end
end
