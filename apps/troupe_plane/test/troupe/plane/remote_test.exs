defmodule Troupe.Plane.RemoteTest do
  @moduledoc """
  A laptop's session offered to the plane and steered from another device (#58), from the plane's side: a laptop's one connection at `/v1/relay`, the people it
  shares a session with finding it in `remote.list` and attaching with `remote.open`'s
  token at `/v1/relay/session`, each relayed message checked on the way, no token ever
  reaching the laptop, a withdrawal ending every view, and a laptop that went shown
  offline since then with nothing queued for it.

  The laptop is played by the test, over a real socket, with the protocol's own client.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, Audit, Harness, Identity, Invites, Repo, Sessions}
  alias Troupe.Plane.Web.Router
  alias Troupe.Protocol.{Client, Relay, SessionId}

  @moduletag timeout: 60_000

  @ada "ada@example.test"
  @bea "bea@example.test"
  @cy "cy@example.test"

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

    ctx = %{url: "http://127.0.0.1:#{port}", ws: "ws://127.0.0.1:#{port}"}
    tokens = Map.new([@ada, @bea, @cy], &{&1, plane_token(ctx, &1)})
    session_id = SessionId.generate()

    Map.merge(ctx, %{tokens: tokens, session_id: session_id})
  end

  describe "offering and finding" do
    test "the owner and the people it is shared with find it; anybody else does not", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, synced} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      assert [%{"session_id" => id, "shares" => [%{"subject" => @bea, "role" => "control"}]}] =
               synced["offers"]

      assert id == ctx.session_id

      {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
      assert row["id"] == ctx.session_id
      assert row["kind"] == "remote"
      assert row["state"] == "online"
      assert row["your_role"] == "control"
      assert row["workspace"] == "project", "the plane keeps the workspace's name, not its path"
      assert row["shares"] == nil

      {:ok, %{"sessions" => [own]}} = rpc(ctx, @ada, "remote.list", %{})
      assert own["your_role"] == "owner"
      assert [%{"subject" => @bea}] = own["shares"]

      assert {:ok, %{"sessions" => []}} = rpc(ctx, @cy, "remote.list", %{})
      assert {:error, %{"message" => "not_found"}} = rpc(ctx, @cy, "remote.open", %{"session_id" => ctx.session_id})
    end

    test "a person the plane does not know is refused by name", ctx do
      laptop = laptop!(ctx, @ada)

      assert {:error, %{message: "not_found", data: %{"person" => "nobody@example.test"}}} =
               Client.call(laptop, "relay.offer", %{
                 "session_id" => ctx.session_id,
                 "share" => [%{"person" => "nobody@example.test", "role" => "observe"}]
               })
    end

    test "another person's session cannot be offered over it", ctx do
      ada = laptop!(ctx, @ada)
      {:ok, _} = sync(ada, ctx.session_id, [])
      cy = laptop!(ctx, @cy, "d-cy")

      assert {:error, %{message: "conflict"}} =
               Client.call(cy, "relay.offer", %{"session_id" => ctx.session_id, "share" => []})
    end

    test "a page in a browser is not a laptop", ctx do
      assert {:ok, %{status: 403}} =
               Req.request(
                 method: :get,
                 url: ctx.url <> "/v1/relay",
                 headers: [{"origin", "https://evil.example.test"}],
                 retry: false
               )
    end
  end

  describe "steering through the relay" do
    test "a shared person's messages reach the laptop checked, and no token ever does", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      assert opened["endpoint"] == "/v1/relay/session"
      assert opened["kind"] == "remote"

      viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")

      # A prompt goes through to the laptop, which answers it.
      task = Task.async(fn -> Client.call(viewer, "input.send", input(ctx)) end)
      {id, frame} = await_frame(laptop)
      assert frame["method"] == "input.send"
      answer(laptop, id, frame["id"], %{"accepted" => true})
      assert {:ok, %{"accepted" => true}} = Task.await(task)

      # Something about the laptop rather than the session is refused here, and the laptop
      # hears nothing of it.
      assert {:error, %{message: "forbidden"}} =
               Client.call(viewer, "fs.read", %{"session_id" => ctx.session_id, "path" => "a"})

      assert {:error, %{message: "forbidden"}} =
               Client.call(viewer, "input.send", %{input(ctx) | "session_id" => "s-other"})

      # A renewal is the plane's to answer, and its token stays here.
      {:ok, again} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      assert {:ok, %{"auth" => %{"expires_at" => _}}} =
               Client.call(viewer, "auth.refresh", %{"auth" => %{"token" => again["token"]}})

      refute_receive {:troupe_notification, "relay.frame", _}, 300
    end

    test "a person shared to observe is held to it on the plane", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "observe"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      viewer = viewer!(ctx, laptop, opened["token"], @bea, "observe")

      assert {:error, %{message: "forbidden", data: %{"required_scope" => "control"}}} =
               Client.call(viewer, "input.send", input(ctx))

      refute_receive {:troupe_notification, "relay.frame", _}, 300
    end

    test "a token for another door does not open a relayed session", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      assert {:error, %{message: "unauthenticated"}} =
               Client.connect(url: ctx.ws <> "/v1/relay/session", token: ctx.tokens[@bea])
    end
  end

  describe "a private session, offered with its owner's consent (#765)" do
    test "said private, audited, steered by a control invitee alone, and the plane keeps none of it",
         ctx do
      id = private!(ctx)
      invite!(id, @bea, "control")
      laptop = laptop!(ctx, @ada)

      # The laptop says private and names Bea and Cy; Cy holds no invitation.
      {:ok, _} =
        Client.call(laptop, "relay.offer", %{
          "session_id" => id,
          "workspace" => "/home/ada/project",
          "private" => true,
          "share" => [%{"person" => @bea, "role" => "control"}, %{"person" => @cy, "role" => "control"}]
        })

      {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
      assert row["id"] == id
      assert row["private"] == true
      assert row["your_role"] == "control"
      assert {:ok, %{"sessions" => []}} = rpc(ctx, @cy, "remote.list", %{})
      assert {:error, %{"message" => "not_found"}} = rpc(ctx, @cy, "remote.open", %{"session_id" => id})

      # Her invitation says it is offered.
      {:ok, %{"invites" => [invitation]}} = rpc(ctx, @bea, "invites.list", %{})
      assert invitation["offered"] == true

      [offered] = Enum.filter(Audit.list(), &(&1.action == "remote.offer" and &1.subject_id == id))
      assert offered.actor == @ada
      assert offered.detail["private"] == true

      # Bea steers it, and what passes says something nothing on the plane may keep.
      marker = "marker-" <> Base.encode16(:crypto.strong_rand_bytes(8))
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => id})
      viewer = viewer!(ctx, laptop, opened["token"], @bea, "control", id)

      task =
        Task.async(fn ->
          Client.call(viewer, "input.send", %{"command_id" => "c-1", "session_id" => id, "text" => marker})
        end)

      {viewer_id, frame} = await_frame(laptop)
      assert frame["params"]["text"] == marker
      answer(laptop, viewer_id, frame["id"], %{"accepted" => true, "echo" => marker})
      assert {:ok, %{"accepted" => true}} = Task.await(task)

      event = %{"seq" => 1, "type" => "assistant_message", "agent" => ["root"], "data" => %{"text" => marker}}
      params = %{"topic" => "session:#{id}", "session_id" => id, "event" => event}
      data = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "event", "params" => params})
      Client.notify(laptop, "relay.frame", %{"viewer" => viewer_id, "data" => data})
      assert_receive {:troupe_event, _topic, ^id, %{data: %{"text" => ^marker}}}, 5_000

      assert stored_anywhere(marker) == [], "the plane kept what a private session said"

      # Taking her invitation back closes her view at once, and refuses her after.
      Invites.uninvite(Sessions.get(id), @bea, @ada)
      taken_back = Relay.invitation_taken_back()
      assert_receive {:troupe_notification, "relay.closed", %{"reason" => ^taken_back}}, 5_000
      assert {:error, %{"message" => "not_found"}} = rpc(ctx, @bea, "remote.open", %{"session_id" => id})
    end

    test "the plane's own row makes an offer private, and withdrawing makes it sealed-only again", ctx do
      id = private!(ctx)
      invite!(id, @bea, "control")
      laptop = laptop!(ctx, @ada)

      # A laptop that did not say so is still offering a private session.
      {:ok, _} = sync(laptop, id, [%{"person" => @bea, "role" => "control"}])
      {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
      assert row["private"] == true

      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => id})
      _viewer = viewer!(ctx, laptop, opened["token"], @bea, "control", id)

      {:ok, %{"withdrawn" => true}} = Client.call(laptop, "relay.withdraw", %{"session_id" => id})
      withdrawn = Relay.private_withdrawn()
      assert_receive {:troupe_notification, "relay.closed", %{"reason" => ^withdrawn}}, 5_000

      assert {:ok, %{"sessions" => []}} = rpc(ctx, @bea, "remote.list", %{})
      assert {:error, %{"message" => "not_found"}} = rpc(ctx, @bea, "remote.open", %{"session_id" => id})
      {:ok, %{"invites" => [invitation]}} = rpc(ctx, @bea, "invites.list", %{})
      assert invitation["offered"] == false
      assert invitation["role"] == "control"
    end
  end

  describe "withdrawn and offline" do
    test "withdrawing ends every view at once", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")
      monitor = Process.monitor(viewer)

      {:ok, %{"withdrawn" => true}} = Client.call(laptop, "relay.withdraw", %{"session_id" => ctx.session_id})

      assert_receive {:troupe_notification, "relay.closed", %{"reason" => "withdrawn"}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      assert {:ok, %{"sessions" => []}} = rpc(ctx, @bea, "remote.list", %{})
    end

    test "a laptop that goes is shown offline since then, and nothing is queued for it", ctx do
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, opened} = rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})
      _viewer = viewer!(ctx, laptop, opened["token"], @bea, "control")

      Client.close(laptop)
      assert_receive {:troupe_notification, "relay.closed", %{"reason" => "the laptop went offline"}}, 5_000

      row =
        eventually(fn ->
          {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
          row["state"] == "offline" and row
        end)

      assert is_binary(row["offline_since"])

      assert {:error, %{"message" => "unavailable", "data" => %{"offline_since" => since}}} =
               rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      assert is_binary(since)

      # Back, it offers again what it still offers, and is found again.
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, %{"sessions" => [back]}} = rpc(ctx, @bea, "remote.list", %{})
      assert back["state"] == "online"
    end
  end

  describe "the laptop's own sign-in (slice 2)" do
    test "a grant asked with the person's token is exchanged for the laptop's door alone, for its device",
         ctx do
      {:ok, %{"grant" => "rg_" <> _ = grant, "device" => "d-ada"}} =
        rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})

      assert {:ok, %{status: 200, body: redeemed}} = redeem(ctx, grant)
      assert redeemed["subject"] == @ada
      assert redeemed["device"] == "d-ada"
      assert is_integer(redeemed["expires_at"])
      token = redeemed["token"]

      # The laptop's door takes it, for that device, and the offer is found.
      laptop = laptop!(ctx, token, "d-ada")
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])
      {:ok, %{"sessions" => [row]}} = rpc(ctx, @bea, "remote.list", %{})
      assert row["state"] == "online"

      # Renewed on the open socket with the next exchange, as a client's token is.
      {:ok, %{status: 200, body: again}} = redeem(ctx, grant)

      assert {:ok, %{"auth" => %{"expires_at" => _}}} =
               Client.call(laptop, "auth.refresh", %{"auth" => %{"token" => again["token"]}})

      # No other door takes it: not `/rpc`, not a viewer's, not the laptop's for another device.
      assert {:ok, %{status: 401}} =
               Req.request(
                 method: :post,
                 url: ctx.url <> "/rpc",
                 json: %{"jsonrpc" => "2.0", "id" => 1, "method" => "remote.list", "params" => %{}},
                 headers: [{"authorization", "Bearer " <> token}],
                 retry: false
               )

      assert {:error, %{message: "unauthenticated"}} =
               Client.connect(url: ctx.ws <> "/v1/relay/session", token: token)

      assert {:error, %{message: "unauthenticated"}} =
               Client.connect(
                 url: ctx.ws <> "/v1/relay",
                 token: token,
                 capabilities: %{"relay" => true, "device" => "d-somewhere-else"}
               )

      # The audit trail says the device signed in, and nothing of the grant.
      [granted] = Enum.filter(Audit.list(), &(&1.action == "remote.grant"))
      assert granted.actor == @ada
      assert granted.subject_id == "d-ada"
      refute inspect(granted.detail) =~ grant
    end

    test "a released grant, a forged one and one for a deactivated person are refused", ctx do
      {:ok, %{"grant" => grant}} = rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})

      assert {:ok, %{status: 401}} = redeem(ctx, grant <> "x")
      assert {:ok, %{status: 401}} = redeem(ctx, "rg_00000000-0000-0000-0000-000000000000.nope")
      assert {:ok, %{status: 401}} = redeem(ctx, "anything")

      assert {:ok, %{status: 204}} = release(ctx, grant)
      assert {:ok, %{status: 401}} = redeem(ctx, grant)
      assert {:ok, %{status: 204}} = release(ctx, grant), "a release of nothing is still 204"

      released = Enum.filter(Audit.list(), &(&1.action == "remote.release"))
      assert [%{actor: @ada, subject_id: "d-ada"}] = released

      {:ok, %{"grant" => again}} = rpc(ctx, @bea, "remote.grant", %{"device" => "d-bea"})
      {:ok, _} = Identity.get_user(@bea) |> Ecto.Changeset.change(active: false) |> Repo.update()
      assert {:ok, %{status: 403}} = redeem(ctx, again)
    end

    test "a second grant for the same device replaces the first", ctx do
      {:ok, %{"grant" => first}} = rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})
      {:ok, %{"grant" => second}} = rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})

      assert {:ok, %{status: 401}} = redeem(ctx, first)
      assert {:ok, %{status: 200}} = redeem(ctx, second)
    end
  end

  describe "a team's administrators may forbid offering" do
    setup ctx do
      Application.put_env(:troupe_plane, :platform_admin_group, "platform")
      on_exit(fn -> Application.delete_env(:troupe_plane, :platform_admin_group) end)

      {:ok, group} = Identity.upsert_group(%{external_id: "g-eng", display_name: "eng"})
      {:ok, team} = Identity.enable_team(group, %{name: "eng"})
      {:ok, _} = Identity.set_memberships(Identity.get_user(@ada), ["g-eng"])
      root = person("root@example.test", ["platform"])

      Map.merge(ctx, %{team: team, root: Admin.actor_for(root)})
    end

    test "switched off in the team, its people are refused a grant, an offer and an attach, naming the team",
         ctx do
      # An offer made while the team allowed it.
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      {:ok, %{changes: changes}} =
        Admin.team_update(ctx.root, "eng", %{"remote_offering_allowed" => false})

      assert changes["remote_offering_allowed"] == %{"from" => true, "to" => false}

      [update] = Enum.filter(Audit.list(), &(&1.action == "team.update"))
      assert update.actor == "root@example.test"
      assert update.detail["remote_offering_allowed"]["to"] == false

      assert {:error, %{"message" => "forbidden", "data" => %{"team" => "eng", "reason" => reason}}} =
               rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})

      assert reason =~ "eng's administrators do not allow offering"

      assert {:error, %{message: "forbidden", data: %{"team" => "eng"}}} =
               Client.call(laptop, "relay.offer", %{"session_id" => SessionId.generate(), "share" => []})

      assert {:error, %{"message" => "forbidden", "data" => %{"team" => "eng"}}} =
               rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      # Somebody in no such team offers as before.
      bea = laptop!(ctx, @bea, "d-bea")
      assert {:ok, _} = Client.call(bea, "relay.offer", %{"session_id" => SessionId.generate(), "share" => []})

      # On again, Ada offers again.
      {:ok, _} = Admin.team_update(ctx.root, "eng", %{"remote_offering_allowed" => true})
      assert {:ok, %{"grant" => _}} = rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})
    end

    test "a grant made before the switch is refused at its next exchange", ctx do
      {:ok, %{"grant" => grant}} = rpc(ctx, @ada, "remote.grant", %{"device" => "d-ada"})
      {:ok, _} = Admin.team_update(ctx.root, "eng", %{"remote_offering_allowed" => false})

      assert {:ok, %{status: 403, body: %{"reason" => reason}}} = redeem(ctx, grant)
      assert reason =~ "eng's administrators"
    end
  end

  describe "a person's watch on what is offered to them" do
    test "an offer, a new share, the laptop going and a withdrawal reach the people they concern at once",
         ctx do
      bea = watch!(ctx, @bea)
      cy = watch!(ctx, @cy, :cy)
      assert {:ok, %{"sessions" => []}} = Client.call(bea, "remote.list", %{})
      assert {:ok, %{"sessions" => []}} = Client.call(cy, "remote.list", %{})

      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      assert_receive {:troupe_notification, "remote.changed", %{"sessions" => [row]}}, 1_000
      assert row["id"] == ctx.session_id
      assert row["state"] == "online"
      assert row["your_role"] == "control"

      # Shared anew with Cy instead: Bea's list empties and Cy's has it.
      {:ok, _} =
        Client.call(laptop, "relay.offer", %{
          "session_id" => ctx.session_id,
          "workspace" => "project",
          "share" => [%{"person" => @cy, "role" => "observe"}]
        })

      assert_receive {:troupe_notification, "remote.changed", %{"sessions" => []}}, 1_000
      assert_receive {:cy, {:troupe_notification, "remote.changed", %{"sessions" => [seen]}}}, 1_000
      assert seen["your_role"] == "observe"

      # The laptop goes: offline since then, told; and back, and withdrawn.
      Client.close(laptop)
      assert_receive {:cy, {:troupe_notification, "remote.changed", %{"sessions" => [away]}}}, 1_000
      assert away["state"] == "offline"
      assert is_binary(away["offline_since"])

      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @cy, "role" => "observe"}])
      assert_receive {:cy, {:troupe_notification, "remote.changed", %{"sessions" => [%{"state" => "online"}]}}}, 1_000

      {:ok, _} = Client.call(laptop, "relay.withdraw", %{"session_id" => ctx.session_id})
      assert_receive {:cy, {:troupe_notification, "remote.changed", %{"sessions" => []}}}, 1_000

      # Bea heard none of what concerned only Cy.
      refute_received {:troupe_notification, "remote.changed", _}
      Client.close(bea)
      Client.close(cy)
    end

    test "a member who administers nothing lists, watches and opens only what is offered to them",
         ctx do
      refute Admin.admin?(Admin.actor_for(Identity.get_user(@cy)))
      refute Admin.admin?(Admin.actor_for(Identity.get_user(@bea)))
      laptop = laptop!(ctx, @ada)
      {:ok, _} = sync(laptop, ctx.session_id, [%{"person" => @bea, "role" => "control"}])

      cy = watch!(ctx, @cy)

      assert {:ok, %{"sessions" => []}} = rpc(ctx, @cy, "remote.list", %{})
      assert {:ok, %{"sessions" => []}} = Client.call(cy, "remote.list", %{})

      assert {:error, %{"message" => "not_found"}} =
               rpc(ctx, @cy, "remote.open", %{"session_id" => ctx.session_id})

      assert {:ok, %{"token" => token, "your_role" => "control"}} =
               rpc(ctx, @bea, "remote.open", %{"session_id" => ctx.session_id})

      # A relay token is for one session's door, not for a person's watch.
      assert {:error, %{message: "unauthenticated"}} =
               Client.connect(url: ctx.ws <> "/v1/relay/watch", token: token)
    end

    test "a page from an origin the plane does not admit is refused", ctx do
      assert {:ok, %{status: 403}} =
               Req.request(
                 method: :get,
                 url: ctx.url <> "/v1/relay/watch",
                 headers: [{"origin", "https://evil.example.test"}],
                 retry: false
               )
    end
  end

  # -- the laptop ---------------------------------------------------------------

  # A person's watch, whose notifications reach the test as they are, or tagged.
  defp watch!(ctx, subject, tag \\ nil) do
    test = self()

    owner =
      if tag,
        do: spawn_link(fn -> forward(test, tag) end),
        else: test

    {:ok, watch} =
      Client.connect(
        url: ctx.ws <> "/v1/relay/watch",
        token: ctx.tokens[subject],
        client_info: %{"name" => "troupe-console", "version" => "1"},
        owner: owner
      )

    on_exit(fn -> Client.close(watch) end)
    watch
  end

  defp forward(test, tag) do
    receive do
      message ->
        send(test, {tag, message})
        forward(test, tag)
    end
  end

  defp laptop!(ctx, subject_or_token, device \\ "d-ada") do
    {:ok, laptop} =
      Client.connect(
        url: ctx.ws <> "/v1/relay",
        token: ctx.tokens[subject_or_token] || subject_or_token,
        client_info: %{"name" => "troupe-daemon", "version" => "1"},
        capabilities: %{"relay" => true, "device" => device}
      )

    on_exit(fn -> Client.close(laptop) end)
    laptop
  end

  defp redeem(ctx, grant) do
    Req.request(method: :post, url: ctx.url <> "/auth/relay", json: %{"grant" => grant}, retry: false)
  end

  defp release(ctx, grant) do
    Req.request(method: :post, url: ctx.url <> "/auth/relay/release", json: %{"grant" => grant}, retry: false)
  end

  defp sync(laptop, session_id, share) do
    Client.call(laptop, "relay.sync", %{
      "offers" => [%{"session_id" => session_id, "workspace" => "/home/ada/project", "share" => share}]
    })
  end

  # Ada's private session, as her daemon registers it.
  defp private!(_ctx) do
    id = SessionId.generate()
    ada = Identity.get_user(@ada)

    {:ok, _row} =
      Harness.call(
        "session.register",
        %{"session_id" => id, "device" => "ada-laptop"},
        %{user: ada, platform_admin?: false}
      )

    id
  end

  # An invitation's row, as her daemon's `session.invite` leaves it; the keys are the
  # invites suite's.
  defp invite!(id, subject, role) do
    Repo.insert!(%Invites.Invite{
      session_id: id,
      subject: subject,
      role: role,
      invited_by: @ada,
      invited_at: DateTime.utc_now()
    })
  end

  # Every row of every table on the plane that holds `text` anywhere, as `table`.
  defp stored_anywhere(text) do
    %{rows: tables} =
      Repo.query!("""
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
      """)

    for [table] <- tables,
        %{rows: [[count]]} =
          Repo.query!(
            "SELECT count(*) FROM \"#{table}\" AS t WHERE t::text LIKE $1",
            ["%" <> text <> "%"]
          ),
        count > 0,
        do: table
  end

  # A viewer attaching: its `initialize` is relayed to the laptop, without its token, and
  # the laptop's answer goes back.
  defp viewer!(ctx, laptop, token, subject, role, session_id \\ nil) do
    test = self()

    task =
      Task.async(fn ->
        Client.connect(url: ctx.ws <> "/v1/relay/session", token: token, owner: test)
      end)

    assert_receive {:troupe_notification, "relay.open", opened}, 5_000
    assert opened["session_id"] == (session_id || ctx.session_id)
    assert opened["person"]["subject"] == subject
    assert opened["role"] == role

    {viewer_id, initialize} = await_frame(laptop)
    assert viewer_id == opened["viewer"]
    assert initialize["method"] == "initialize"
    refute Map.has_key?(initialize["params"], "auth"), "a token reached the laptop"

    answer(laptop, viewer_id, initialize["id"], %{
      "protocol_version" => "1",
      "principal" => %{"subject" => subject},
      "scopes" => ["observe"]
    })

    {:ok, viewer} = Task.await(task)
    viewer
  end

  defp await_frame(_laptop) do
    assert_receive {:troupe_notification, "relay.frame", %{"viewer" => id, "data" => data}}, 5_000
    {id, Jason.decode!(data)}
  end

  defp answer(laptop, viewer_id, id, result) do
    data = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    Client.notify(laptop, "relay.frame", %{"viewer" => viewer_id, "data" => data})
  end

  defp input(ctx) do
    %{"command_id" => "c-1", "session_id" => ctx.session_id, "text" => "hello from the train"}
  end

  # -- the rest -----------------------------------------------------------------

  defp eventually(fun, deadline \\ 5_000) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if deadline <= 0, do: flunk("condition never held")
        Process.sleep(50)
        eventually(fun, deadline - 50)

      truthy ->
        truthy
    end
  end

  defp fake_verify("good:" <> subject) do
    {:ok, %{"sub" => subject, "email" => subject, "name" => subject, "groups" => []}}
  end

  defp fake_verify(_token), do: {:error, :bad_signature}

  defp plane_token(ctx, subject) do
    {:ok, %{status: 200, body: body}} =
      Req.request(
        method: :post,
        url: ctx.url <> "/auth/exchange",
        json: %{"id_token" => "good:#{subject}"},
        retry: false
      )

    body["token"]
  end

  defp rpc(ctx, subject, method, params) do
    {:ok, %{body: body}} =
      Req.request(
        method: :post,
        url: ctx.url <> "/rpc",
        json: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params},
        headers: [{"authorization", "Bearer " <> ctx.tokens[subject]}],
        retry: false
      )

    case body do
      %{"result" => result} -> {:ok, result}
      %{"error" => error} -> {:error, error}
    end
  end
end
