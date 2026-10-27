defmodule Troupe.Plane.ArtifactTeamsTest do
  @moduledoc """
  An artifact may be a team's (#62): `visibility: team:<name>`. Its publisher is in the team
  (a platform administrator publishes to any); its members list, get and open it; a team
  administrator of that team or a platform administrator takes it down; nobody else sees it;
  its bytes count against that team's quota. Every row of `artifact.list` says which scope
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
      assert {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})
      assert artifact["visibility"] == "team:engineering"
      assert artifact["team"] == "engineering"
      assert artifact["scope"] == "mine"

      assert {:ok, %{"team" => "research"}} =
               publish(context.root, %{"visibility" => "team:research"})
    end

    test "a team the publisher is not in is refused with a sentence naming theirs", context do
      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               publish(context.ada, %{"visibility" => "team:research"})

      assert reason =~ "not in team research"
      assert reason =~ "engineering"

      # A team that is not there is told as one they are not in: whether it exists is not
      # theirs to learn.
      assert {:error, %{message: "forbidden"}} =
               publish(context.ada, %{"visibility" => "team:nowhere"})

      assert {:error, %{message: "not_found"}} =
               publish(context.root, %{"visibility" => "team:nowhere"})

      assert {:error, %{message: "invalid_params"}} =
               publish(context.ada, %{"visibility" => "team:Not A Team"})

      assert {:ok, %{"artifacts" => []}} = call(context.ada, "artifact.list", %{})
    end

    test "counts against that team's quota, whatever team the publisher is in first", context do
      both = person("fay@example.test", ["engineering", "research"])

      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.root), "research", %{
          "artifact_quota_bytes" => 15
        })

      assert {:ok, %{"team" => "research"}} = publish(both, %{"visibility" => "team:research"})
      assert Artifacts.usage(context.research) == 11
      assert Artifacts.usage(context.engineering) == 0

      assert {:error, %{message: "payload_too_large", data: %{quota: 15}}} =
               publish(both, %{"visibility" => "team:research"})

      # Engineering's quota is not research's.
      assert {:ok, %{"team" => "engineering"}} =
               publish(both, %{"visibility" => "team:engineering"})
    end

    test "moving one to a team takes its bytes to that team", context do
      both = person("fay@example.test", ["engineering", "research"])
      {:ok, artifact} = publish(both, %{"visibility" => "organisation"})

      # An organisation's counts against the first of its publisher's teams by name; moved to
      # the other, every byte of it goes there.
      assert artifact["team"] == "engineering"
      {from, to} = {context.engineering, context.research}

      assert {:ok, moved} =
               publish(both, %{"id" => artifact["id"], "visibility" => "team:#{to.name}"})

      assert moved["team"] == to.name
      assert Artifacts.usage(to) == 22
      assert Artifacts.usage(from) == 0
    end

    test "its owner moves it with a put that sends no files, as a version carrying them all",
         context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "organisation"})
      id = artifact["id"]

      assert {:ok, moved} =
               call(context.ada, "artifact.put", %{"id" => id, "base" => 1, "visibility" => "team:engineering"})

      assert moved["visibility"] == "team:engineering"
      assert moved["version"] == 2

      assert {:ok, %{"versions" => [second, first]}} = call(context.ada, "artifact.get", %{"id" => id})
      assert Enum.map(second["files"], & &1["sha256"]) == Enum.map(first["files"], & &1["sha256"])

      # Without a base there is nothing to carry, and a put with no files is refused as before;
      # and an edit made on a version since replaced is a conflict, as any put's is.
      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.put", %{"id" => id, "visibility" => "private"})

      assert {:error, %{message: "conflict"}} =
               call(context.ada, "artifact.put", %{"id" => id, "base" => 1, "visibility" => "private"})

      # Only its owner moves it.
      assert {:error, %{message: message}} =
               call(context.bo, "artifact.put", %{"id" => id, "base" => 2, "visibility" => "private"})

      assert message in ["forbidden", "not_found"]
    end
  end

  describe "who sees a team's" do
    test "its members list, get and open it; nobody else", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "team:engineering"})
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
      {:ok, team} = publish(context.ada, %{"title" => "Team", "visibility" => "team:engineering"})
      {:ok, org} = publish(context.ada, %{"title" => "Org", "visibility" => "organisation"})
      {:ok, dev} = publish(context.ada, %{"title" => "Dev", "visibility" => "profile:dev"})
      {:ok, own} = publish(context.bo, %{"title" => "Bo's", "visibility" => "team:engineering"})
      {:ok, lab} = publish(context.cy, %{"title" => "Lab", "visibility" => "team:research"})

      {:ok, %{"token" => token}} =
        call(context.cy, "artifact.share", %{"id" => lab["id"], "role" => "view"})

      {:ok, _} = call(context.bo, "artifact.redeem", %{"token" => token})

      {:ok, %{"artifacts" => rows}} = call(context.bo, "artifact.list", %{})
      scopes = Map.new(rows, &{&1["id"], &1["scope"]})

      assert scopes == %{
               team["id"] => "team:engineering",
               org["id"] => "organisation",
               dev["id"] => "profile:dev",
               own["id"] => "mine",
               lab["id"] => "shared"
             }

      assert {:ok, %{"artifacts" => teams}} =
               call(context.bo, "artifact.list", %{"teams" => true})

      assert Enum.sort(Enum.map(teams, & &1["title"])) == ["Bo's", "Team"]

      assert {:ok, %{"artifacts" => [%{"title" => "Lab"}]}} =
               call(context.cy, "artifact.list", %{"visibility" => "team:research"})

      # A platform administrator sees every team's, each in its team's scope.
      {:ok, %{"artifacts" => all}} = call(context.root, "artifact.list", %{"teams" => true})

      assert all |> Enum.map(& &1["scope"]) |> Enum.sort() ==
               ["team:engineering", "team:engineering", "team:research"]
    end
  end

  describe "taking a team's down" do
    test "is its owner's, the team's administrator's or a platform administrator's", context do
      {:ok, first} = publish(context.ada, %{"visibility" => "team:engineering"})
      {:ok, second} = publish(context.ada, %{"visibility" => "team:engineering"})

      # A member who is not its owner may not; another team's administrator does not see it.
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
      {:ok, dev} = publish(context.ada, %{"visibility" => "profile:dev"})
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
      {:ok, team} = publish(context.ada, %{"title" => "Eng", "visibility" => "team:engineering"})
      {:ok, _dev} = publish(context.ada, %{"title" => "Dev", "visibility" => "profile:dev"})
      {:ok, _lab} = publish(context.cy, %{"title" => "Lab", "visibility" => "team:research"})

      assert {:ok, rows} = API.call("admin.artifacts.list", %{}, Admin.actor_for(context.root))
      assert rows |> Enum.map(& &1["title"]) |> Enum.sort() == ["Dev", "Eng", "Lab"]
      assert Enum.all?(rows, & &1["may_take_down"])

      eng = Enum.find(rows, &(&1["title"] == "Eng"))
      assert eng["team"] == "engineering"
      assert eng["visibility"] == "team:engineering"
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
end
