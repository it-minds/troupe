defmodule Troupe.Plane.ArtifactAccessTest do
  @moduledoc """
  An artifact's readers are a set (#1238): its owner, the teams in it, the people it is
  shared with by name, the organisation switch and its links, kept across versions. The
  set is read whole with `artifact.access.get` and changed by its owner with
  `artifact.access.set`, each team or person added or taken off one audit row; the teams an
  owner may add are theirs and those granted the profile its session ran on, which
  `profile.teams` names; the people search for an artifact finds that profile's people; a
  person it is shared with is told on their watch's channel; and the migration turns the
  single audiences of before into the set. Through `Harness`, as `/rpc` reaches them.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Identity, Repo}
  alias Troupe.Plane.Artifacts.People
  alias Troupe.Plane.Sessions.Session

  @moduletag timeout: 60_000

  @migration Path.expand(
               "../../../priv/repo/migrations/20261128001121_artifact_teams.exs",
               __DIR__
             )

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    engineering = team_with_grant("engineering", "dev", name: "engineering")
    research = team_with_grant("research", "lab", name: "research")
    # Billing runs lab too, which Ada is in neither of.
    billing = team_with_grant("billing", "lab", name: "billing")

    %{
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      di: person("di@example.test", ["billing"]),
      engineering: engineering,
      research: research,
      billing: billing
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp page, do: [%{"path" => "index.html", "bytes" => Base.encode64("<h1>Hi</h1>")}]

  defp publish(user, attrs, opts \\ []) do
    Artifacts.publish(
      user,
      Map.merge(%{"title" => "Report", "kind" => "html", "files" => page()}, attrs),
      opts
    )
  end

  # As a pod's session on `profile` publishes: its profile on the row.
  defp from_pod(user, team, profile, attrs),
    do:
      publish(user, attrs,
        session: %Session{id: "s-#{profile}", profile: profile, team_id: team.id}
      )

  defp audited(action), do: Enum.filter(Audit.list(), &(&1.action == action))

  describe "the set" do
    test "is read by every team in it, and by nobody those teams leave out", context do
      both = person("fay@example.test", ["engineering", "research"])
      {:ok, artifact} = publish(both, %{"teams" => ["engineering", "research"]})
      id = artifact["id"]

      assert artifact["teams"] == ["engineering", "research"]

      for reader <- [context.bo, context.cy] do
        assert {:ok, %{"role" => "view"}} = call(reader, "artifact.get", %{"id" => id})
        assert {:ok, %{file: _}} = Artifacts.fetch(id, :current, nil, reader)
      end

      assert {:error, %{message: "not_found"}} = call(context.di, "artifact.get", %{"id" => id})

      # Each reader's tab is their own team's.
      assert {:ok, %{"artifacts" => [%{"scope" => "team:research"}]}} =
               call(context.cy, "artifact.list", %{})

      # A new version keeps them.
      {:ok, two} = publish(both, %{"id" => id})
      assert {two["version"], two["teams"]} == {2, ["engineering", "research"]}
      assert {:ok, _} = call(context.cy, "artifact.get", %{"id" => id})
    end
  end

  describe "artifact.access.get and artifact.access.set" do
    test "read the whole set, and apply a change as its difference, one audit row each",
         context do
      {:ok, artifact} = publish(context.ada, %{"teams" => ["engineering"]})
      id = artifact["id"]

      assert {:ok, access} = call(context.ada, "artifact.access.get", %{"id" => id})
      assert access["owner"]["subject"] == "ada@example.test"
      assert [%{"name" => "engineering", "granted_by" => "ada@example.test"}] = access["teams"]
      assert {access["people"], access["organisation"], access["links"]} == {[], false, []}
      assert access["words"] == "the engineering team"
      assert access["may_add"] == ["engineering"]

      assert {:ok, changed} =
               call(context.ada, "artifact.access.set", %{
                 "id" => id,
                 "teams" => [],
                 "people" => [%{"subject" => "cy@example.test", "role" => "comment"}],
                 "organisation" => true
               })

      assert {changed["teams"], changed["organisation"]} == {[], true}
      assert [%{"subject" => "cy@example.test", "role" => "comment"}] = changed["people"]
      assert changed["words"] == "the whole organisation and 1 person"

      # The same set again changes nothing and writes nothing.
      shares = length(audited("artifact.share"))

      assert {:ok, _} =
               call(context.ada, "artifact.access.set", %{
                 "id" => id,
                 "people" => [%{"subject" => "cy@example.test", "role" => "comment"}],
                 "organisation" => true
               })

      assert length(audited("artifact.share")) == shares

      assert [%{detail: %{"team" => "engineering"}}] = audited("artifact.unshare")

      assert [%{detail: %{"person" => "cy@example.test", "role" => "comment"}}] =
               audited("artifact.share")

      assert [%{detail: %{"visibility" => "organisation", "visibility_from" => "private"}}] =
               audited("artifact.visibility")

      # No version was made of any of it.
      assert {:ok, %{"version" => 1, "visibility" => "organisation"}} =
               call(context.ada, "artifact.get", %{"id" => id})

      # Cy reads it by name; taking Cy off takes that away.
      assert {:ok, %{"role" => "comment"}} = call(context.cy, "artifact.get", %{"id" => id})

      {:ok, _} =
        call(context.ada, "artifact.access.set", %{
          "id" => id,
          "people" => [],
          "organisation" => false
        })

      assert {:error, %{message: "not_found"}} = call(context.cy, "artifact.get", %{"id" => id})
      assert Enum.any?(audited("artifact.unshare"), &(&1.detail["person"] == "cy@example.test"))
    end

    test "refuse a team the owner may not give it to, and change nothing", context do
      {:ok, artifact} = publish(context.ada, %{"teams" => ["engineering"]})
      id = artifact["id"]

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.ada, "artifact.access.set", %{
                 "id" => id,
                 "teams" => ["research"],
                 "organisation" => true
               })

      assert reason =~ "may not give it to team research"

      assert {:ok, %{"teams" => [%{"name" => "engineering"}], "organisation" => false}} =
               call(context.ada, "artifact.access.get", %{"id" => id})

      # Only an owner reads or changes it: a reader may not, nor may a stranger learn of it.
      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.access.get", %{"id" => id})

      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.access.set", %{"id" => id, "teams" => []})

      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.access.set", %{"id" => id, "teams" => []})

      assert audited("artifact.share") == []
    end

    test "let the owner give it to a team granted its session's profile, though not in it",
         context do
      {:ok, artifact} = from_pod(context.cy, context.research, "lab", %{})
      id = artifact["id"]

      assert {:ok, %{"may_add" => ["billing", "research"]}} =
               call(context.cy, "artifact.access.get", %{"id" => id})

      assert {:ok, %{"teams" => [%{"name" => "billing"}]}} =
               call(context.cy, "artifact.access.set", %{"id" => id, "teams" => ["billing"]})

      assert {:ok, %{"role" => "view"}} = call(context.di, "artifact.get", %{"id" => id})

      # So may a publish from that session; a team neither the owner's nor the profile's may not.
      assert {:ok, %{"teams" => ["billing", "research"]}} =
               from_pod(context.cy, context.research, "lab", %{"teams" => ["billing", "research"]})

      assert {:error, %{message: "forbidden"}} =
               from_pod(context.cy, context.research, "lab", %{"teams" => ["engineering"]})

      # And artifact.share takes a team the same way.
      assert {:ok, %{"team" => "research"}} =
               call(context.cy, "artifact.share", %{"id" => id, "team" => "research"})

      assert {:ok, %{"teams" => ["billing", "research"]}} =
               call(context.cy, "artifact.get", %{"id" => id})

      assert {:ok, %{"revoked" => true}} =
               call(context.cy, "artifact.unshare", %{"id" => id, "team" => "billing"})

      assert {:ok, %{"teams" => ["research"]}} = call(context.cy, "artifact.get", %{"id" => id})
    end

    test "tell a person it is shared with, on their watch's channel", context do
      {:ok, artifact} = publish(context.ada, %{})
      :ok = People.subscribe()

      {:ok, _} =
        call(context.ada, "artifact.access.set", %{
          "id" => artifact["id"],
          "people" => [%{"subject" => "bo@example.test", "role" => "view"}]
        })

      assert_receive {:artifact_shared, "bo@example.test",
                      %{"id" => id, "role" => "view", "by" => "ada@example.test"}}

      assert id == artifact["id"]

      {:ok, _} =
        call(context.ada, "artifact.share", %{
          "id" => artifact["id"],
          "person" => "cy@example.test",
          "role" => "edit"
        })

      assert_receive {:artifact_shared, "cy@example.test", %{"role" => "edit"}}
    end
  end

  describe "profile.teams and people.search" do
    test "profile.teams names a profile's teams for whoever may run it or owns an artifact from it",
         context do
      assert {:ok, %{"teams" => ["billing", "research"]}} =
               call(context.cy, "profile.teams", %{"profile" => "lab"})

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "profile.teams", %{"profile" => "lab"})

      # An artifact from a lab session, given to Ada's team and handed to her, is hers to share.
      {:ok, artifact} =
        from_pod(context.cy, context.research, "lab", %{"owner" => "team:research"})

      {1, _} =
        Repo.update_all(from(a in Artifacts.Artifact, where: a.id == ^artifact["id"]),
          set: [owner_team_id: context.engineering.id]
        )

      assert {:ok, %{"teams" => ["billing", "research"]}} =
               call(context.ada, "profile.teams", %{"profile" => "lab"})
    end

    test "people.search with an artifact finds the people its profile covers, for its owner alone",
         context do
      {:ok, artifact} = from_pod(context.cy, context.research, "lab", %{})

      assert {:ok, %{"people" => []}} = call(context.cy, "people.search", %{"query" => "di"})

      assert {:ok, %{"people" => [%{"subject" => "di@example.test"}]}} =
               call(context.cy, "people.search", %{"query" => "di", "artifact" => artifact["id"]})

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "people.search", %{"query" => "di", "artifact" => artifact["id"]})
    end
  end

  describe "the migration" do
    test "turns team:<name> and profile:<name> into the set, private, and nobody loses it",
         context do
      Code.ensure_loaded?(Troupe.Plane.Repo.Migrations.ArtifactTeams) ||
        Code.require_file(@migration)

      {:ok, team} = publish(context.ada, %{"title" => "Team"})
      {:ok, profile} = publish(context.cy, %{"title" => "Profile"})
      {:ok, nobody} = publish(context.ada, %{"title" => "Nobody's profile"})
      {:ok, gone} = publish(context.ada, %{"title" => "Gone team"})
      {:ok, org} = publish(context.ada, %{"title" => "Org", "visibility" => "organisation"})

      # As the rows were before: one audience in the visibility, no team in the set.
      for {artifact, visibility} <- [
            {team, "team:engineering"},
            {profile, "profile:lab"},
            {nobody, "profile:nowhere"},
            {gone, "team:gone"}
          ] do
        Repo.query!("UPDATE artifacts SET visibility = $1 WHERE id = $2", [
          visibility,
          artifact["id"]
        ])
      end

      convert = Module.concat(["Troupe.Plane.Repo.Migrations.ArtifactTeams"])
      assert convert.convert(Repo) == %{"team" => 2, "profile" => 2, "no_team" => 2}

      teams_of = fn artifact ->
        Repo.get!(Artifacts.Artifact, artifact["id"]) |> Artifacts.Teams.names()
      end

      assert teams_of.(team) == ["engineering"]
      assert teams_of.(profile) == ["billing", "research"]
      assert teams_of.(nobody) == []
      assert teams_of.(gone) == []

      assert Repo.all(from(a in Artifacts.Artifact, select: a.visibility)) |> Enum.frequencies() ==
               %{"private" => 4, "organisation" => 1}

      # Who read them before reads them now.
      assert {:ok, _} = call(context.bo, "artifact.get", %{"id" => team["id"]})
      assert {:ok, _} = call(context.di, "artifact.get", %{"id" => profile["id"]})
      assert {:ok, _} = call(context.cy, "artifact.get", %{"id" => org["id"]})

      # Nothing is left to convert the second time.
      assert convert.convert(Repo) == %{"team" => 0, "profile" => 0, "no_team" => 0}
      assert Identity.get_team("engineering")
    end
  end
end
