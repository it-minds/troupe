defmodule Troupe.Plane.ArtifactTeamsTest do
  @moduledoc """
  An artifact read by teams (#62, #1238): `teams: [<name>]`. Its publisher is in each team
  (a platform administrator publishes to any); its members list, get and open it; a team
  administrator of that team or a platform administrator takes it down; nobody else sees it;
  its bytes count against the quota of the team that owns it. Every row of `artifact.list` says which scope
  it is in, and `admin.artifacts.list` is the administrators' table of them. Through
  `Harness`, as `/rpc` reaches them, and the admin API as the console's Operate area calls it.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Identity}
  alias Troupe.Plane.Admin.API

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
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

  describe "publishing to a team" do
    test "is a member's, or a platform administrator's to any team", context do
      assert {:ok, artifact} = publish(context.ada, %{"teams" => ["engineering"]})
      assert artifact["visibility"] == "private"
      assert artifact["teams"] == ["engineering"]
      assert artifact["organisation"] == false
      assert artifact["team"] == "engineering"
      assert artifact["scope"] == "mine"
      # Who reads it does not make it the team's.
      assert artifact["owner_team"] == nil

      assert {:ok, %{"teams" => ["research"]}} = publish(context.root, %{"teams" => ["research"]})
    end

    test "a team the publisher may not give it to is refused with a sentence naming theirs", context do
      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               publish(context.ada, %{"teams" => ["research"]})

      assert reason =~ "may not give it to team research"
      assert reason =~ "engineering"

      # A team that is not there is told as one they may not give it to: whether it exists is
      # not theirs to learn.
      assert {:error, %{message: "forbidden"}} = publish(context.ada, %{"teams" => ["nowhere"]})
      assert {:error, %{message: "not_found"}} = publish(context.root, %{"teams" => ["nowhere"]})

      assert {:error, %{message: "invalid_params"}} =
               publish(context.ada, %{"teams" => ["Not A Team"]})

      # The audience of before, one team in the visibility, is refused naming the new way.
      assert {:error, %{message: "invalid_params", data: %{reason: old}}} =
               publish(context.ada, %{"visibility" => "team:engineering"})

      assert old =~ "artifact.access.set"

      assert {:ok, %{"artifacts" => []}} = call(context.ada, "artifact.list", %{})
    end

    test "counts against the quota of the team that owns it, whatever team the publisher is in first",
         context do
      both = person("fay@example.test", ["engineering", "research"])

      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.root), "research", %{
          "artifact_quota_bytes" => 15
        })

      assert {:ok, %{"team" => "research", "owner_team" => "research"}} =
               publish(both, %{"teams" => ["research"], "owner" => "team"})

      assert Artifacts.usage(context.research) == 11
      assert Artifacts.usage(context.engineering) == 0

      assert {:error, %{message: "payload_too_large", data: %{quota: 15}}} =
               publish(both, %{"teams" => ["research"], "owner" => "team"})

      # Engineering's quota is not research's, and a team that only reads it counts nothing.
      assert {:ok, %{"team" => "engineering"}} = publish(both, %{"teams" => ["research"]})
      assert Artifacts.usage(context.research) == 11

      # `team` is whose it is only where one team reads it.
      assert {:error, %{message: "invalid_params"}} =
               publish(both, %{"teams" => ["research", "engineering"], "owner" => "team"})
    end

    test "a version keeps who reads it: one naming teams is refused, and a change of readers moves no bytes",
         context do
      both = person("fay@example.test", ["engineering", "research"])
      {:ok, artifact} = publish(both, %{"visibility" => "organisation"})

      # An organisation's counts against the first of its publisher's teams by name.
      assert artifact["team"] == "engineering"

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               publish(both, %{"id" => artifact["id"], "teams" => ["research"]})

      assert reason =~ "artifact.access.set"

      assert {:ok, %{"teams" => [%{"name" => "research"}]}} =
               call(both, "artifact.access.set", %{"id" => artifact["id"], "teams" => ["research"]})

      assert {:ok, %{"team" => "engineering", "version" => 1}} =
               call(both, "artifact.get", %{"id" => artifact["id"]})

      assert Artifacts.usage(context.engineering) == 11
      assert Artifacts.usage(context.research) == 0
    end

    test "its owner moves it between private and organisation with a put that sends no files, as a version carrying them all",
         context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "organisation"})
      id = artifact["id"]

      assert {:ok, moved} =
               call(context.ada, "artifact.put", %{"id" => id, "base" => 1, "visibility" => "private"})

      assert moved["visibility"] == "private"
      assert moved["version"] == 2

      assert {:ok, %{"versions" => [second, first]}} = call(context.ada, "artifact.get", %{"id" => id})
      assert Enum.map(second["files"], & &1["sha256"]) == Enum.map(first["files"], & &1["sha256"])

      # The single audience of before is refused, naming where the teams went.
      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               call(context.ada, "artifact.put", %{"id" => id, "base" => 2, "visibility" => "team:engineering"})

      assert reason =~ "artifact.access.set"

      # Without a base there is nothing to carry, and a put with no files is refused as before;
      # and an edit made on a version since replaced is a conflict, as any put's is.
      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.put", %{"id" => id, "visibility" => "organisation"})

      assert {:error, %{message: "conflict"}} =
               call(context.ada, "artifact.put", %{"id" => id, "base" => 1, "visibility" => "organisation"})

      # Only its owner moves it.
      assert {:error, %{message: message}} =
               call(context.bo, "artifact.put", %{"id" => id, "base" => 2, "visibility" => "organisation"})

      assert message in ["forbidden", "not_found"]
    end
  end

  describe "who sees a team's" do
    test "its members list, get and open it; nobody else", context do
      # Ada's own, for the team: published as hers, not the team's.
      {:ok, artifact} = publish(context.ada, %{"teams" => ["engineering"], "owner" => "me"})
      id = artifact["id"]

      assert {:ok,
              %{
                "artifacts" => [%{"id" => ^id, "scope" => "team:engineering"}],
                "teams" => ["engineering"]
              }} =
               call(context.bo, "artifact.list", %{})

      assert {:ok, %{"role" => "view"}} = call(context.bo, "artifact.get", %{"id" => id})
      assert {:ok, %{"url" => _}} = call(context.bo, "artifact.open", %{"id" => id})

      assert {:ok, %{file: %{"path" => "index.html"}}} =
               Artifacts.fetch(id, :current, nil, context.bo)

      assert {:ok, %{"artifacts" => [], "teams" => ["research"]}} =
               call(context.cy, "artifact.list", %{})

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.open", %{"id" => id})
      assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, context.cy)

      # Another team's administrator is nobody to it.
      assert {:error, %{message: "not_found"}} = call(context.eve, "artifact.get", %{"id" => id})

      # Leaving the team takes it away at the next request.
      {:ok, _} = Identity.set_memberships(context.bo, [])
      assert {:error, %{message: "not_found"}} = call(context.bo, "artifact.get", %{"id" => id})
      assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, context.bo)
    end

    test "every row says its scope, and teams narrows to the teams' own", context do
      {:ok, team} = publish(context.ada, %{"title" => "Team", "teams" => ["engineering"], "owner" => "me"})
      {:ok, org} = publish(context.ada, %{"title" => "Org", "visibility" => "organisation"})
      {:ok, dev} = publish(context.ada, %{"title" => "Dev", "visibility" => "organisation", "teams" => ["engineering"]})
      {:ok, own} = publish(context.bo, %{"title" => "Bo's", "teams" => ["engineering"]})
      {:ok, lab} = publish(context.cy, %{"title" => "Lab", "teams" => ["research"]})

      {:ok, %{"token" => token}} =
        call(context.cy, "artifact.share", %{"id" => lab["id"], "role" => "view"})

      {:ok, _} = call(context.bo, "artifact.redeem", %{"token" => token})

      {:ok, %{"artifacts" => rows}} = call(context.bo, "artifact.list", %{})
      scopes = Map.new(rows, &{&1["id"], &1["scope"]})

      assert scopes == %{
               team["id"] => "team:engineering",
               org["id"] => "organisation",
               dev["id"] => "team:engineering",
               own["id"] => "mine",
               lab["id"] => "shared"
             }

      assert {:ok, %{"artifacts" => teams}} =
               call(context.bo, "artifact.list", %{"teams" => true})

      assert Enum.sort(Enum.map(teams, & &1["title"])) == ["Bo's", "Dev", "Team"]

      assert {:ok, %{"artifacts" => [%{"title" => "Lab"}]}} =
               call(context.cy, "artifact.list", %{"team" => "research"})

      # A platform administrator sees every team's, each in its team's scope.
      {:ok, %{"artifacts" => all}} = call(context.root, "artifact.list", %{"teams" => true})

      assert all |> Enum.map(& &1["scope"]) |> Enum.sort() ==
               ["organisation", "team:engineering", "team:engineering", "team:research"]
    end
  end

  describe "taking a team's down" do
    test "is its owner's, the team's administrator's or a platform administrator's", context do
      {:ok, first} = publish(context.ada, %{"teams" => ["engineering"], "owner" => "me"})
      {:ok, second} = publish(context.ada, %{"teams" => ["engineering"], "owner" => "me"})

      # A member who is not its owner may not, since Ada kept it hers; another team's
      # administrator does not see it.
      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.delete", %{"id" => first["id"]})

      assert {:error, %{message: "not_found"}} =
               call(context.eve, "artifact.delete", %{"id" => first["id"]})

      # The team's administrator sees it, and may take it down, though not in the team.
      assert {:ok, %{"may_delete" => true}} =
               call(context.dee, "artifact.get", %{"id" => first["id"]})

      assert {:ok, %{"deleted" => true}} =
               call(context.dee, "artifact.delete", %{"id" => first["id"]})

      assert {:ok, %{"deleted" => true}} =
               call(context.root, "artifact.delete", %{"id" => second["id"]})

      takedowns = Enum.filter(Audit.list(), &(&1.action == "artifact.delete"))

      assert takedowns |> Enum.map(&{&1.actor, &1.detail["by"]}) |> Enum.sort() ==
               [{"dee@example.test", "takedown"}, {"root@example.test", "takedown"}]
    end

    test "a team's administrator takes down no other kind of artifact", context do
      {:ok, dev} = publish(context.ada, %{"visibility" => "private"})
      {:ok, org} = publish(context.ada, %{"visibility" => "organisation"})

      assert {:error, %{message: "not_found"}} =
               call(context.dee, "artifact.delete", %{"id" => dev["id"]})

      assert {:error, %{message: "forbidden"}} =
               call(context.dee, "artifact.delete", %{"id" => org["id"]})
    end
  end

  describe "a private one" do
    test "is what a publish that says nothing makes, and its owner's alone", context do
      assert {:ok, artifact} =
               call(context.ada, "artifact.publish", %{
                 "title" => "Notes",
                 "kind" => "html",
                 "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<p>mine</p>")}]
               })

      id = artifact["id"]
      assert artifact["visibility"] == "private"
      assert artifact["scope"] == "private"

      assert {:ok, %{"artifacts" => [%{"id" => ^id, "scope" => "private"}]}} =
               call(context.ada, "artifact.list", %{})

      # Not a teammate, not the team's administrator, not a platform administrator.
      for other <- [context.bo, context.dee, context.root] do
        assert {:ok, %{"artifacts" => []}} = call(other, "artifact.list", %{})
        assert {:error, %{message: "not_found"}} = call(other, "artifact.get", %{"id" => id})
        assert {:error, %{message: "not_found"}} = call(other, "artifact.open", %{"id" => id})
        assert {:error, :not_found} = Artifacts.fetch(id, :current, nil, other)
      end

      assert {:error, %{message: "not_found"}} =
               call(context.dee, "artifact.delete", %{"id" => id})

      # A republish that says nothing keeps it private.
      assert {:ok, %{"visibility" => "private", "version" => 2}} =
               call(context.ada, "artifact.publish", %{
                 "id" => id,
                 "title" => "Notes",
                 "kind" => "html",
                 "files" => [%{"path" => "index.html", "bytes" => Base.encode64("<p>two</p>")}]
               })
    end

    test "is shared with a link, as any other is", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "private"})

      {:ok, %{"token" => token}} =
        call(context.ada, "artifact.share", %{"id" => artifact["id"], "role" => "view"})

      {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})

      assert {:ok, %{"artifacts" => [%{"scope" => "shared"}]}} =
               call(context.cy, "artifact.list", %{})

      assert {:ok, %{"role" => "view", "scope" => "shared"}} =
               call(context.cy, "artifact.get", %{"id" => artifact["id"]})
    end

    test "a platform administrator may still take one down, and it is audited", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "private"})

      assert {:ok, rows} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.root))
      assert [%{"visibility" => "private"}] = rows
      assert {:ok, []} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.dee))

      assert {:ok, %{"deleted" => true}} =
               call(context.root, "artifact.delete", %{"id" => artifact["id"]})

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.delete"))

      assert {row.actor, row.detail["by"], row.detail["visibility"]} ==
               {"root@example.test", "takedown", "private"}
    end
  end

  describe "admin.artifacts.list" do
    test "is every artifact for a platform administrator, and a team's for its administrator",
         context do
      {:ok, team} = publish(context.ada, %{"title" => "Eng", "teams" => ["engineering"]})
      {:ok, _dev} = publish(context.ada, %{"title" => "Dev", "visibility" => "private"})
      {:ok, _lab} = publish(context.cy, %{"title" => "Lab", "teams" => ["research"]})

      assert {:ok, rows} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.root))
      assert rows |> Enum.map(& &1["title"]) |> Enum.sort() == ["Dev", "Eng", "Lab"]
      assert Enum.all?(rows, & &1["may_take_down"])

      eng = Enum.find(rows, &(&1["title"] == "Eng"))
      assert eng["team"] == "engineering"
      assert {eng["visibility"], eng["teams"]} == {"private", ["engineering"]}
      assert eng["owner"]["subject"] == "ada@example.test"

      assert {:ok, [%{"title" => "Eng"}]} =
               API.call("admin.artifacts.list", %{}, Admin.actor_for(context.dee))

      assert {:error, %{message: "forbidden"}} =
               API.call("admin.artifacts.list", %{}, Admin.actor_for(context.ada))

      # And the administrators' takedown, from that table.
      assert {:error, %{message: "not_found"}} =
               API.call(
                 "admin.artifact.takedown",
                 %{"id" => team["id"]},
                 Admin.actor_for(context.eve)
               )

      assert {:ok, %{"deleted" => true}} =
               API.call(
                 "admin.artifact.takedown",
                 %{"id" => team["id"]},
                 Admin.actor_for(context.dee)
               )

      assert {:ok, [_, _]} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.root))
    end
  end

  describe "admin.artifact.get" do
    test "is a private one's page for a platform administrator, its shares and thread too, audited",
         context do
      {:ok, artifact} = publish(context.ada, %{"title" => "Hers", "visibility" => "private"})
      id = artifact["id"]
      {:ok, _link} = call(context.ada, "artifact.share", %{"id" => id, "role" => "view"})
      {:ok, _comment} = call(context.ada, "artifact.comment", %{"id" => id, "body" => "Draft."})

      assert {:ok, page} = API.call("admin.artifact.get", %{"id" => id}, Admin.actor_for(context.root))
      assert {page["title"], page["mine"], page["may_open"], page["may_delete"]} == {"Hers", false, false, true}
      assert [%{"n" => 1, "files" => [%{"path" => "index.html"}]}] = page["versions"]
      assert [%{"role" => "view"}] = page["shares"]
      assert [%{"body" => "Draft."}] = page["thread"]
      assert page["thumbnail_url"] == nil
      refute inspect(page) =~ "<h1>Hi</h1>"

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.read"))

      assert {row.actor, row.subject_id, row.detail["owner"], row.detail["visibility"]} ==
               {"root@example.test", id, "ada@example.test", "private"}

      # Reading it again is another row: one per read.
      {:ok, _} = API.call("admin.artifact.get", %{"id" => id}, Admin.actor_for(context.root))
      assert length(Enum.filter(Audit.list(), &(&1.action == "artifact.read"))) == 2
    end

    test "is a team administrator's for their teams' alone, and nobody else's", context do
      {:ok, eng} = publish(context.ada, %{"title" => "Eng", "teams" => ["engineering"]})
      {:ok, mine} = publish(context.ada, %{"title" => "Hers", "visibility" => "private"})

      assert {:ok, %{"title" => "Eng", "may_open" => true}} =
               API.call("admin.artifact.get", %{"id" => eng["id"]}, Admin.actor_for(context.dee))

      assert {:error, %{message: "not_found"}} =
               API.call("admin.artifact.get", %{"id" => eng["id"]}, Admin.actor_for(context.eve))

      assert {:error, %{message: "not_found"}} =
               API.call("admin.artifact.get", %{"id" => mine["id"]}, Admin.actor_for(context.dee))

      assert {:error, %{message: "forbidden"}} =
               API.call("admin.artifact.get", %{"id" => eng["id"]}, Admin.actor_for(context.bo))

      assert [%{actor: "dee@example.test"}] = Enum.filter(Audit.list(), &(&1.action == "artifact.read"))
    end
  end
end
