defmodule Troupe.Plane.ArtifactsTest do
  @moduledoc """
  Artifacts (#62) as the plane keeps them: published as versions at one id, their files in
  the object store under `artifacts/<id>/<n>/`, seen by their owner, the organisation or a
  profile's people and by nobody else, deleted by their owner or taken down by a platform
  administrator, every publish and delete audited, and held to the size limits, the team's
  quota and the two settings. Through `Harness`, as a client's `/rpc` reaches them.

  Against the development MinIO, as `ReleasesTest` is. Serving them is `ArtifactsHostTest`;
  a pod's publish over its control link is in `ControlTest`.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Identity, Settings}

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :platform_admin_group, "platform")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :platform_admin_group)
      Application.delete_env(:troupe_plane, :artifacts)
    end)

    {:ok, group} = Identity.upsert_group(%{external_id: "platform", display_name: "platform"})
    {:ok, _team} = Identity.enable_team(group, %{name: "platform"})
    engineering = team_with_grant("engineering", "dev", name: "engineering")
    _research = team_with_grant("research", "lab", name: "research")

    store = ObjectStore.from_env()

    on_exit(fn -> ObjectStore.delete_prefix(store, "artifacts/") end)

    %{
      store: store,
      root: person("root@example.test", ["platform"]),
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      engineering: engineering
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp page(html, extra \\ []) do
    [
      %{"path" => "index.html", "content_type" => "text/html", "bytes" => Base.encode64(html)}
      | extra
    ]
  end

  defp publish(user, attrs) do
    call(
      user,
      "artifact.publish",
      Map.merge(%{"title" => "Report", "kind" => "html", "files" => page("<h1>Hi</h1>")}, attrs)
    )
  end

  describe "publishing" do
    test "keeps a version's files in the object store and its row with their hashes", context do
      css = %{"path" => "assets/site.css", "bytes" => Base.encode64("h1 { color: red }")}

      assert {:ok, artifact} =
               publish(context.ada, %{
                 "visibility" => "profile:dev",
                 "files" => page("<h1>Weekly</h1>", [css]),
                 "session_id" => "s-laptop-1",
                 "agent" => "agent:build"
               })

      assert artifact["id"] =~ ~r/\Aart-[a-z2-7]{16}\z/
      assert artifact["version"] == 1
      assert artifact["mine"]
      assert artifact["url"] == "https://artifacts.example.test/a/#{artifact["id"]}/"
      assert artifact["team"] == "engineering"

      assert artifact["origin"] == %{
               "session_id" => "s-laptop-1",
               "agent" => "agent:build",
               "where" => "laptop",
               "profile" => nil
             }

      assert [%{"n" => 1, "files" => files, "hash" => "sha256:" <> _}] = artifact["versions"]
      assert Enum.map(files, & &1["path"]) == ["assets/site.css", "index.html"]
      assert Enum.find(files, &(&1["path"] == "assets/site.css"))["content_type"] == "text/css"

      assert Enum.find(files, &(&1["path"] == "index.html"))["sha256"] ==
               Base.encode16(:crypto.hash(:sha256, "<h1>Weekly</h1>"), case: :lower)

      assert {:ok, "<h1>Weekly</h1>"} =
               ObjectStore.get(context.store, "artifacts/#{artifact["id"]}/1/index.html")
    end

    test "republishing makes the next version at the same address and keeps the last", context do
      {:ok, first} = publish(context.ada, %{"visibility" => "organisation"})

      assert {:ok, second} =
               publish(context.ada, %{
                 "id" => first["id"],
                 "visibility" => "profile:dev",
                 "files" => page("<h1>Two</h1>")
               })

      assert second["id"] == first["id"]
      assert second["url"] == first["url"]
      assert second["version"] == 2
      assert Enum.map(second["versions"], & &1["n"]) == [2, 1]

      assert {:ok, "<h1>Hi</h1>"} =
               ObjectStore.get(context.store, "artifacts/#{first["id"]}/1/index.html")

      assert {:ok, "<h1>Two</h1>"} =
               ObjectStore.get(context.store, "artifacts/#{first["id"]}/2/index.html")

      # Somebody else's is not theirs to republish, and the kind stays.
      assert {:error, %{message: "forbidden"}} =
               publish(context.bo, %{"id" => first["id"], "visibility" => "profile:dev"})

      assert {:error, %{message: "invalid_params"}} =
               publish(context.ada, %{
                 "id" => first["id"],
                 "visibility" => "profile:dev",
                 "kind" => "markdown",
                 "files" => [%{"path" => "a.md", "bytes" => Base.encode64("# A")}]
               })
    end

    test "is audited with who, the session and the visibility it moved from, never the content",
         context do
      {:ok, artifact} =
        publish(context.ada, %{"visibility" => "organisation", "session_id" => "s-1"})

      {:ok, _} = publish(context.ada, %{"id" => artifact["id"], "visibility" => "profile:dev"})

      rows =
        Audit.list()
        |> Enum.filter(&(&1.action == "artifact.publish"))
        |> Enum.sort_by(& &1.detail["version"])

      assert Enum.map(rows, &{&1.actor, &1.subject_id, &1.detail["version"]}) ==
               [{"ada@example.test", artifact["id"], 1}, {"ada@example.test", artifact["id"], 2}]

      assert hd(rows).detail["session"] == "s-1"
      assert List.last(rows).detail["visibility_from"] == "organisation"
      assert List.last(rows).detail["visibility"] == "profile:dev"
      refute inspect(rows) =~ "<h1>"
    end

    test "is refused where its shape is wrong, and nothing is kept", context do
      refused = [
        %{"visibility" => "team:core"},
        %{"visibility" => "organisation", "kind" => "pdf"},
        %{"visibility" => "organisation", "title" => "  "},
        %{"visibility" => "organisation", "files" => []},
        %{
          "visibility" => "organisation",
          "files" => [%{"path" => "../etc/passwd", "bytes" => "eA=="}]
        },
        %{
          "visibility" => "organisation",
          "files" => [%{"path" => "/abs.html", "bytes" => "eA=="}]
        },
        %{
          "visibility" => "organisation",
          "files" => [%{"path" => "v2/index.html", "bytes" => "eA=="}]
        },
        %{
          "visibility" => "organisation",
          "files" => [%{"path" => "index.html", "bytes" => "not base64!"}]
        },
        %{
          "visibility" => "organisation",
          "files" => [%{"path" => "notes.txt", "bytes" => "eA=="}]
        },
        %{
          "visibility" => "organisation",
          "kind" => "file",
          "files" => page("x", [%{"path" => "b.txt", "bytes" => "eA=="}])
        }
      ]

      for attrs <- refused do
        assert {:error, %{message: "invalid_params"}} = publish(context.ada, attrs),
               inspect(attrs)
      end

      assert {:ok, %{"artifacts" => []}} = call(context.ada, "artifact.list", %{})
    end

    test "holds a file to 16 MiB and a version to 64 MiB", context do
      big = Base.encode64(:binary.copy("a", 16 * 1024 * 1024 + 1))

      assert {:error, %{message: "payload_too_large", data: %{limit: 16_777_216}}} =
               publish(context.ada, %{
                 "visibility" => "organisation",
                 "files" => page("x", [%{"path" => "big.bin", "bytes" => big}])
               })

      chunk = Base.encode64(:binary.copy("b", 15 * 1024 * 1024))
      many = for i <- 1..5, do: %{"path" => "part#{i}.bin", "bytes" => chunk}

      assert {:error, %{message: "payload_too_large", data: %{limit: 67_108_864}}} =
               publish(context.ada, %{"visibility" => "organisation", "files" => page("x", many)})
    end

    test "counts against the team's quota, every version, as Budgets shows it", context do
      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.root), "engineering", %{
          "artifact_quota_bytes" => 100
        })

      {:ok, first} =
        publish(context.ada, %{
          "visibility" => "profile:dev",
          "files" => page(String.duplicate("x", 60))
        })

      assert Artifacts.usage(context.engineering) == 60

      assert {:error,
              %{message: "payload_too_large", data: %{quota: 100, used: 60, reason: reason}}} =
               publish(context.ada, %{
                 "id" => first["id"],
                 "visibility" => "profile:dev",
                 "files" => page(String.duplicate("y", 50))
               })

      assert reason =~ "past its quota"

      {:ok, teams} = Admin.teams_list(Admin.actor_for(context.root))
      engineering = Enum.find(teams, &(&1.name == "engineering"))
      assert engineering.artifact_bytes == 60
      assert engineering.artifact_quota_bytes == 100
    end

    test "needs a team, and a profile the publisher is covered by", context do
      nobody = person("nobody@example.test", [])

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               publish(nobody, %{"visibility" => "organisation"})

      assert reason =~ "needs a team"

      assert {:error, %{message: "forbidden"}} =
               publish(context.ada, %{"visibility" => "profile:lab"})
    end
  end

  describe "who sees one" do
    test "a profile's are its people's and the organisation's everybody's; nobody else's",
         context do
      {:ok, dev} = publish(context.ada, %{"title" => "For dev", "visibility" => "profile:dev"})
      {:ok, org} = publish(context.ada, %{"title" => "For all", "visibility" => "organisation"})

      # Bo is in dev's team; Cy is not.
      assert {:ok, %{"artifacts" => seen, "profiles" => ["dev"]}} =
               call(context.bo, "artifact.list", %{})

      assert Enum.sort(Enum.map(seen, & &1["title"])) == ["For all", "For dev"]
      assert {:ok, %{"id" => _}} = call(context.bo, "artifact.get", %{"id" => dev["id"]})

      assert {:ok, %{"artifacts" => [%{"title" => "For all"}], "profiles" => ["lab"]}} =
               call(context.cy, "artifact.list", %{})

      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.get", %{"id" => dev["id"]})

      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.open", %{"id" => dev["id"]})

      assert {:ok, _} = call(context.cy, "artifact.get", %{"id" => org["id"]})

      # Narrowed: theirs, one visibility.
      assert {:ok, %{"artifacts" => []}} = call(context.bo, "artifact.list", %{"mine" => true})

      assert {:ok, %{"artifacts" => [_, _]}} =
               call(context.ada, "artifact.list", %{"mine" => true})

      assert {:ok, %{"artifacts" => [%{"title" => "For dev"}]}} =
               call(context.bo, "artifact.list", %{"visibility" => "profile:dev"})

      # A person who leaves the profile's team stops seeing it at their next request.
      {:ok, _} = Identity.set_memberships(context.bo, [])

      assert {:error, %{message: "not_found"}} =
               call(context.bo, "artifact.get", %{"id" => dev["id"]})
    end

    test "only platform administrators publish to the whole organisation where the setting says so",
         context do
      {:ok, _} =
        Settings.put("artifacts_publish_organisation", "platform_admins", "root@example.test")

      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               publish(context.ada, %{"visibility" => "organisation"})

      assert reason =~ "profile:<name>"
      assert {:ok, _} = publish(context.ada, %{"visibility" => "profile:dev"})
      assert {:ok, _} = publish(context.root, %{"visibility" => "organisation"})
    end

    test "switched off, nothing is published, listed or opened", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "organisation"})
      {:ok, _} = Settings.put("artifacts_enabled", "false", "root@example.test")

      assert {:error, %{message: "forbidden"}} =
               publish(context.ada, %{"visibility" => "organisation"})

      assert {:ok, %{"enabled" => false, "artifacts" => []}} =
               call(context.ada, "artifact.list", %{})

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.get", %{"id" => artifact["id"]})
    end
  end

  describe "deleting" do
    test "is the owner's, or a platform administrator's takedown, and takes every byte",
         context do
      {:ok, artifact} =
        publish(context.ada, %{"visibility" => "profile:dev", "session_id" => "s-9"})

      {:ok, _} = publish(context.ada, %{"id" => artifact["id"], "visibility" => "profile:dev"})

      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.delete", %{"id" => artifact["id"]})

      assert {:ok, %{"may_delete" => false}} =
               call(context.bo, "artifact.get", %{"id" => artifact["id"]})

      # The platform administrator sees it, whatever their profiles, and takes it down.
      assert {:ok, %{"may_delete" => true}} =
               call(context.root, "artifact.get", %{"id" => artifact["id"]})

      assert {:ok, %{"deleted" => true}} =
               call(context.root, "artifact.delete", %{"id" => artifact["id"]})

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.get", %{"id" => artifact["id"]})

      assert {:ok, []} = ObjectStore.list(context.store, "artifacts/#{artifact["id"]}/")

      [row] = Enum.filter(Audit.list(), &(&1.action == "artifact.delete"))
      assert row.actor == "root@example.test"
      assert row.detail["by"] == "takedown"
      assert row.detail["session"] == "s-9"

      {:ok, own} = publish(context.ada, %{"visibility" => "profile:dev"})
      assert {:ok, _} = call(context.ada, "artifact.delete", %{"id" => own["id"]})

      assert Enum.any?(
               Audit.list(),
               &(&1.action == "artifact.delete" and &1.detail["by"] == "owner")
             )
    end
  end

  describe "the artifacts host's sign-in" do
    test "a ticket opens once, within a minute, as the person it was signed for", context do
      {:ok, artifact} = publish(context.ada, %{"visibility" => "profile:dev"})

      assert {:ok, %{"url" => url, "expires_in" => 60}} =
               call(context.bo, "artifact.open", %{"id" => artifact["id"]})

      assert "https://artifacts.example.test/enter?ticket=" <> ticket = url

      assert {:ok, %{subject: "bo@example.test", id: id, version: nil}} = Artifacts.redeem(ticket)
      assert id == artifact["id"]
      assert :error = Artifacts.redeem(ticket)
      assert :error = Artifacts.redeem(ticket <> "x")

      assert {:ok, %{"url" => _}} =
               call(context.bo, "artifact.open", %{"id" => artifact["id"], "version" => 1})

      assert {:error, %{message: "not_found"}} =
               call(context.bo, "artifact.open", %{"id" => artifact["id"], "version" => 7})

      cookie = Artifacts.viewer_cookie("bo@example.test")
      assert {:ok, %{subject: "bo@example.test"}} = Artifacts.viewer(cookie)
      assert :error = Artifacts.viewer(cookie <> "x")
      assert :error = Artifacts.viewer(nil)
    end

    test "no host deployed, there is nothing to open, and it says why", context do
      Application.put_env(:troupe_plane, :artifacts, [])
      {:ok, artifact} = publish(context.ada, %{"visibility" => "profile:dev"})
      assert artifact["url"] == nil

      assert {:error, %{message: "unavailable", data: %{reason: reason}}} =
               call(context.ada, "artifact.open", %{"id" => artifact["id"]})

      assert reason =~ "artifactsHost"
    end
  end
end
