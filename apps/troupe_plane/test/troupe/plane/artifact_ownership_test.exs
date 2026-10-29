defmodule Troupe.Plane.ArtifactOwnershipTest do
  @moduledoc """
  An artifact may be a team's, whose members own it (#62). One published to a team is the
  team's unless its publisher says `owner: "me"`; every member and administrator of the
  owning team publishes versions, pins, moves, shares and deletes it as an owner, whatever
  its visibility; nobody else sees a private one; `artifact.transfer` gives a person's own
  to a team they are in (a platform administrator any to any), and an administrator of the
  owning team or a platform administrator takes it back, a plain member not; every row
  says `owner_team` and `may_transfer`; a team that is deleted hands its artifacts back to
  each one's person; and the artifacts host serves a team's to a member. Through
  `Harness`, as `/rpc` reaches them, and over the host's own listener.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Identity}
  alias Troupe.Plane.Admin.API
  alias Troupe.Plane.Web.Artifacts, as: Host

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :base_url, "https://plane.example.test")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :base_url)
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})
    engineering = team_with_grant("engineering", "dev", name: "engineering")
    research = team_with_grant("research", "lab", name: "research")

    # Dee administers engineering without being in it; Eve administers research.
    {:ok, _} = Identity.add_team_admin(engineering, "dee@example.test", "root@example.test")
    {:ok, _} = Identity.add_team_admin(research, "eve@example.test", "root@example.test")

    %{
      root: person("root@example.test", ["platform"]),
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      dee: person("dee@example.test", []),
      eve: person("eve@example.test", []),
      engineering: engineering,
      research: research
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp publish(user, attrs) do
    call(
      user,
      "artifact.publish",
      Map.merge(
        %{
          "title" => "Report",
          "kind" => "html",
          "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Hi</h1>")}]
        },
        attrs
      )
    )
  end

  defp audited(action), do: Enum.filter(Audit.list(), &(&1.action == action))

  describe "publishing" do
    test "to a team makes the artifact the team's, unless the publisher says owner: me",
         context do
      assert {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})
      assert artifact["owner_team"] == "engineering"
      assert artifact["owner"]["subject"] == "ada@example.test"
      assert artifact["role"] == "owner"
      assert artifact["mine"]
      assert artifact["scope"] == "mine"

      assert {:ok, own} =
               publish(context.ada, %{"visibility" => "team:engineering", "owner" => "me"})

      assert own["owner_team"] == nil
      assert own["owner"]["subject"] == "ada@example.test"

      # One published to nobody in particular is its publisher's own.
      assert {:ok, %{"owner_team" => nil}} = publish(context.ada, %{})

      [first | _] = Enum.sort_by(audited("artifact.publish"), & &1.detail["title"])
      assert Enum.find(audited("artifact.publish"), &(&1.detail["owner_team"] == "engineering"))
      assert first.actor == "ada@example.test"
    end

    test "owner: team names the team it is for, and owner: team:<name> one the publisher is in",
         context do
      assert {:ok, %{"owner_team" => "engineering"}} =
               publish(context.ada, %{"visibility" => "team:engineering", "owner" => "team"})

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               publish(context.ada, %{"visibility" => "private", "owner" => "team"})

      assert reason =~ "owner is \"team\" only for an artifact published to a team"

      # A private artifact that a team owns: its members open it, nobody else.
      assert {:ok,
              %{"owner_team" => "engineering", "visibility" => "private", "scope" => "private"}} =
               publish(context.ada, %{"owner" => "team:engineering"})

      # A team the publisher is not in is refused in the words a publish to it is refused.
      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               publish(context.ada, %{"owner" => "team:research"})

      assert reason ==
               "you are not in team research, so you cannot publish to its people; you are in team:engineering"

      assert {:error, %{message: "forbidden"}} =
               publish(context.ada, %{"owner" => "team:nowhere"})

      assert {:error, %{message: "not_found"}} =
               publish(context.root, %{"owner" => "team:nowhere"})

      assert {:ok, %{"owner_team" => "research"}} =
               publish(context.root, %{"owner" => "team:research"})

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               publish(context.ada, %{"owner" => "them"})

      assert reason == "owner is me, team or team:<name>, not \"them\""

      assert {:error, %{message: "invalid_params"}} =
               publish(context.ada, %{"owner" => "team:Not A Team"})
    end

    test "a new version does not move whose it is", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               publish(context.ada, %{"id" => artifact["id"], "owner" => "me"})

      assert reason ==
               "whose an artifact is does not change with a version; artifact.transfer moves it"

      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.put", %{
                 "id" => artifact["id"],
                 "base" => 1,
                 "owner" => "me"
               })

      assert {:ok, %{"owner_team" => "engineering", "version" => 2}} =
               publish(context.ada, %{"id" => artifact["id"]})
    end
  end

  describe "a team's artifact" do
    test "is every member's to publish, pin, move, share and delete, as an owner", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})
      id = artifact["id"]

      assert {:ok, row} = call(context.bo, "artifact.get", %{"id" => id})
      assert row["role"] == "owner"
      assert row["mine"]
      assert row["may_edit"]
      assert row["may_delete"]
      assert row["owner_team"] == "engineering"
      # The person who published it stays recorded, on the row and on the version.
      assert row["owner"]["subject"] == "ada@example.test"
      assert [%{"published_by" => %{"subject" => "ada@example.test"}}] = row["versions"]
      # Who holds a link to it is an owner's to read.
      assert row["shares"] == []

      assert {:ok,
              %{
                "version" => 2,
                "versions" => [%{"published_by" => %{"subject" => "bo@example.test"}} | _]
              }} =
               publish(context.bo, %{"id" => id, "note" => "bo's turn"})

      assert {:ok, %{"version" => 3}} =
               call(context.bo, "artifact.put", %{
                 "id" => id,
                 "base" => 2,
                 "title" => "Report, retitled"
               })

      assert {:ok, %{"version" => 4, "versions" => [%{"rolled_back_to" => 1} | _]}} =
               call(context.bo, "artifact.rollback", %{"id" => id, "version" => 1})

      assert {:ok, %{"pinned" => 2, "current" => 2}} =
               call(context.bo, "artifact.pin", %{"id" => id, "version" => 2})

      assert {:ok,
              %{"visibility" => "organisation", "owner_team" => "engineering", "scope" => "mine"}} =
               call(context.bo, "artifact.put", %{
                 "id" => id,
                 "base" => 4,
                 "visibility" => "organisation"
               })

      assert {:ok, %{"token" => token, "share" => %{"id" => share}}} =
               call(context.bo, "artifact.share", %{"id" => id, "role" => "view"})

      assert {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})

      assert {:ok, %{"revoked" => true}} =
               call(context.bo, "artifact.unshare", %{"id" => id, "share" => share})

      assert {:ok, %{"public_links" => false}} =
               call(context.bo, "artifact.public", %{"id" => id, "enabled" => false})

      # Versions published by somebody else than its person are an owner's, not an edit link's.
      refute Enum.any?(audited("artifact.publish"), &(&1.detail["by"] == "edit link"))

      assert {:ok, %{"deleted" => true}} = call(context.bo, "artifact.delete", %{"id" => id})

      assert [%{actor: "bo@example.test", detail: %{"by" => "owner"}}] =
               audited("artifact.delete")
    end

    test "is its team's administrator's as an owner's too, in the team or not", context do
      {:ok, artifact} =
        publish(context.ada, %{"visibility" => "private", "owner" => "team:engineering"})

      id = artifact["id"]

      assert {:ok, %{"role" => "owner", "may_transfer" => true}} =
               call(context.dee, "artifact.get", %{"id" => id})

      assert {:ok, %{"deleted" => true}} = call(context.dee, "artifact.delete", %{"id" => id})

      assert [%{actor: "dee@example.test", detail: %{"by" => "owner"}}] =
               audited("artifact.delete")
    end

    test "a private one is seen by its team alone, and a leaver loses it", context do
      {:ok, artifact} = publish(context.ada, %{"owner" => "team:engineering"})
      id = artifact["id"]

      assert {:ok, %{"artifacts" => [%{"id" => ^id, "scope" => "private", "role" => "owner"}]}} =
               call(context.bo, "artifact.list", %{})

      assert {:ok, %{file: %{"path" => "index.html"}}} =
               Artifacts.fetch(id, :current, nil, context.bo)

      # Not another team's member, not its administrator, not a platform administrator.
      for other <- [context.cy, context.eve, context.root] do
        assert {:ok, %{"artifacts" => []}} = call(other, "artifact.list", %{})
        assert {:error, %{message: "not_found"}} = call(other, "artifact.get", %{"id" => id})
        assert {:error, %{message: "not_found"}} = call(other, "artifact.open", %{"id" => id})
        assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, other)
      end

      # Its person leaving the team changes nothing for the artifact: it is the team's.
      {:ok, _} = Identity.set_memberships(context.ada, [])
      assert {:error, %{message: "not_found"}} = call(context.ada, "artifact.get", %{"id" => id})

      assert {:ok, %{"artifacts" => [%{"id" => ^id}]}} =
               call(context.bo, "artifact.list", %{"mine" => true})
    end

    test "the team's is under mine, never shared, and for a leaver what its visibility says",
         context do
      {:ok, org} =
        publish(context.ada, %{
          "title" => "Org",
          "visibility" => "organisation",
          "owner" => "team:engineering"
        })

      {:ok, own} =
        publish(context.ada, %{
          "title" => "Own",
          "visibility" => "team:engineering",
          "owner" => "me"
        })

      {:ok, %{"token" => token}} =
        call(context.ada, "artifact.share", %{"id" => org["id"], "role" => "edit"})

      {:ok, _} = call(context.bo, "artifact.redeem", %{"token" => token})

      assert {:ok, %{"artifacts" => rows}} = call(context.bo, "artifact.list", %{"mine" => true})

      assert Enum.map(rows, &{&1["title"], &1["scope"], &1["owner_team"], &1["may_transfer"]}) ==
               [{"Org", "mine", "engineering", false}]

      assert {:ok, %{"artifacts" => []}} = call(context.bo, "artifact.list", %{"shared" => true})

      assert {:ok, %{"artifacts" => all}} = call(context.bo, "artifact.list", %{})

      assert Map.new(all, &{&1["title"], &1["scope"]}) == %{
               "Org" => "mine",
               "Own" => "team:engineering"
             }

      # Ada's own, under mine with its team named; the team's, hers to move nowhere.
      assert {:ok, %{"artifacts" => mine}} = call(context.ada, "artifact.list", %{"mine" => true})
      assert Map.new(mine, &{&1["title"], &1["may_transfer"]}) == %{"Org" => false, "Own" => true}

      # Out of the team, Ada reads the organisation's one as anybody does, and hers is still hers.
      {:ok, _} = Identity.set_memberships(context.ada, [])
      assert {:ok, %{"artifacts" => left}} = call(context.ada, "artifact.list", %{})

      assert Map.new(left, &{&1["title"], {&1["scope"], &1["role"]}}) == %{
               "Org" => {"organisation", "view"},
               "Own" => {"mine", "owner"}
             }

      id = own["id"]

      assert {:ok, %{"artifacts" => [%{"id" => ^id}]}} =
               call(context.ada, "artifact.list", %{"mine" => true})
    end

    test "the administrators' table names the team that owns one", context do
      {:ok, _} = publish(context.ada, %{"title" => "Private", "owner" => "team:engineering"})

      {:ok, _} =
        publish(context.ada, %{
          "title" => "Own",
          "visibility" => "team:engineering",
          "owner" => "me"
        })

      assert {:ok, rows} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.dee))

      assert Map.new(rows, &{&1["title"], &1["owner_team"]}) == %{
               "Private" => "engineering",
               "Own" => nil
             }

      assert {:ok, []} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.eve))
    end
  end

  describe "artifact.transfer" do
    test "gives a person's own to a team they are in, and it is audited", context do
      {:ok, artifact} = publish(context.ada, %{})
      id = artifact["id"]
      assert artifact["may_transfer"]

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.ada, "artifact.transfer", %{"id" => id, "to" => "team:research"})

      assert reason ==
               "you are not in team research, so you cannot give it an artifact; you are in team:engineering"

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               call(context.ada, "artifact.transfer", %{"id" => id, "to" => "me"})

      assert reason == "this artifact is not a team's, so there is nothing to take back"

      assert {:error,
              %{message: "invalid_params", data: %{reason: "to is me or team:<name>, not nil"}}} =
               call(context.ada, "artifact.transfer", %{"id" => id})

      assert {:ok, moved} =
               call(context.ada, "artifact.transfer", %{"id" => id, "to" => "team:engineering"})

      assert moved["owner_team"] == "engineering"
      assert moved["owner"]["subject"] == "ada@example.test"
      assert moved["role"] == "owner"
      refute moved["may_transfer"]

      assert {:ok, %{"role" => "owner", "mine" => true}} =
               call(context.bo, "artifact.get", %{"id" => id})

      assert [%{actor: "ada@example.test", detail: detail}] = audited("artifact.transfer")
      assert detail == %{"from" => "person", "to" => "team:engineering", "title" => "Report"}

      # Somebody who is not an owner may not, and an owner in no team has nowhere to give it.
      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.transfer", %{"id" => id, "to" => "me"})

      {:ok, alone} = publish(context.ada, %{"visibility" => "organisation"})

      assert {:error,
              %{
                message: "forbidden",
                data: %{reason: "only its owner gives an artifact to a team"}
              }} =
               call(context.cy, "artifact.transfer", %{
                 "id" => alone["id"],
                 "to" => "team:research"
               })

      {:ok, _} = Identity.set_memberships(context.ada, [])

      assert {:ok, %{"may_transfer" => false, "role" => "owner"}} =
               call(context.ada, "artifact.get", %{"id" => alone["id"]})

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.ada, "artifact.transfer", %{
                 "id" => alone["id"],
                 "to" => "team:engineering"
               })

      assert reason ==
               "you are not in team engineering, so you cannot give it an artifact; you are in no team"
    end

    test "is taken back by an administrator of the owning team, not by a member", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})
      id = artifact["id"]

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.bo, "artifact.transfer", %{"id" => id, "to" => "me"})

      assert reason ==
               "only an administrator of team engineering, or a platform administrator, takes an artifact back from the team"

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.bo, "artifact.transfer", %{"id" => id, "to" => "team:engineering"})

      assert reason =~
               "this artifact is team engineering's; only a platform administrator gives a team's artifact to another team"

      # Another team's administrator does not see it; its own takes it back and is its person now.
      assert {:error, %{message: "not_found"}} =
               call(context.eve, "artifact.transfer", %{"id" => id, "to" => "me"})

      assert {:ok, back} = call(context.dee, "artifact.transfer", %{"id" => id, "to" => "me"})
      assert back["owner_team"] == nil
      assert back["owner"]["subject"] == "dee@example.test"
      assert back["role"] == "owner"

      assert [%{actor: "dee@example.test", detail: %{"from" => "team:engineering", "to" => "me"}}] =
               audited("artifact.transfer")

      # Bo is a reader of it now, by its visibility, and Ada too.
      assert {:ok, %{"role" => "view", "may_transfer" => false}} =
               call(context.bo, "artifact.get", %{"id" => id})

      assert {:ok, %{"role" => "view", "scope" => "team:engineering"}} =
               call(context.ada, "artifact.get", %{"id" => id})
    end

    test "a platform administrator gives any artifact to any team and takes any back", context do
      {:ok, artifact} = publish(context.cy, %{"visibility" => "private"})
      id = artifact["id"]

      # A private one they cannot read, still theirs to move, as a takedown is.
      assert {:error, %{message: "not_found"}} = call(context.root, "artifact.get", %{"id" => id})

      assert {:ok, %{"owner_team" => "engineering"}} =
               call(context.root, "artifact.transfer", %{"id" => id, "to" => "team:engineering"})

      assert {:ok, %{"owner_team" => "research"}} =
               call(context.root, "artifact.transfer", %{"id" => id, "to" => "team:research"})

      assert {:error, %{message: "not_found", data: %{reason: "there is no team nowhere"}}} =
               call(context.root, "artifact.transfer", %{"id" => id, "to" => "team:nowhere"})

      assert {:ok, %{"owner_team" => nil, "owner" => %{"subject" => "root@example.test"}}} =
               call(context.root, "artifact.transfer", %{"id" => id, "to" => "me"})

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      # Newest first.
      assert Enum.map(audited("artifact.transfer"), &{&1.detail["from"], &1.detail["to"]}) ==
               [
                 {"team:research", "me"},
                 {"team:engineering", "team:research"},
                 {"person", "team:engineering"}
               ]
    end
  end

  describe "a team that is deleted" do
    test "hands its artifacts back to each one's person", context do
      {:ok, artifact} = publish(context.ada, %{"owner" => "team:engineering"})
      id = artifact["id"]
      assert {:ok, %{"role" => "owner"}} = call(context.bo, "artifact.get", %{"id" => id})

      {:ok, _} = Identity.disable_team(context.engineering)

      assert {:ok,
              %{
                "owner_team" => nil,
                "role" => "owner",
                "owner" => %{"subject" => "ada@example.test"}
              }} =
               call(context.ada, "artifact.get", %{"id" => id})

      assert {:error, %{message: "not_found"}} = call(context.bo, "artifact.get", %{"id" => id})
    end
  end

  describe "the artifacts host" do
    test "serves a team's artifact to a member, and not to anybody else", context do
      {:ok, pid} =
        start_supervised(
          {Bandit, plug: Host, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      host = "http://127.0.0.1:#{port}"
      {:ok, artifact} = publish(context.ada, %{"owner" => "team:engineering"})
      id = artifact["id"]

      {:ok, %{"url" => url}} = call(context.bo, "artifact.open", %{"id" => id})
      "https://artifacts.example.test" <> path = url
      entered = Req.get!(host <> path, redirect: false, retry: false)
      assert entered.status == 303
      [set_cookie] = Req.Response.get_header(entered, "set-cookie")
      [_, cookie] = Regex.run(~r/troupe_artifact_viewer=([^;]+)/, set_cookie)

      page =
        Req.get!(host <> "/a/#{id}/",
          headers: [{"cookie", "troupe_artifact_viewer=#{cookie}"}],
          retry: false
        )

      assert page.status == 200
      assert page.body =~ "<h1>Hi</h1>"

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.open", %{"id" => id})
    end
  end
end
