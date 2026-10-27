defmodule Troupe.Plane.ArtifactVersionsTest do
  @moduledoc """
  An artifact's versions (#62): a `put` is the next version at the same address, by its
  owner or by somebody holding an edit link, with a note and who and when; a rollback is a
  new version carrying an old one's files; the current version is the newest unless the
  owner pins one; a person edits one text file of it in the console and previews the edit
  on the artifacts host before saving; and a version too large for one call reaches the
  object store through an upload handle. Through `Harness`, as `/rpc` reaches them.

  Against the development MinIO, as `ArtifactsTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Audit, Harness, Repo}
  alias Troupe.Plane.Identity.Team

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      store = ObjectStore.from_env()
      ObjectStore.delete_prefix(store, "artifacts/")
      ObjectStore.delete_prefix(store, "artifact-uploads/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    _research = team_with_grant("research", "lab", name: "research")

    ada = person("ada@example.test", ["engineering"])

    {:ok, doc} =
      call(ada, "artifact.publish", %{
        "title" => "Notes",
        "kind" => "markdown",
        "visibility" => "profile:dev",
        "files" => [file("index.md", "# One"), file("figure.svg", "<svg/>", "image/svg+xml")]
      })

    %{
      store: ObjectStore.from_env(),
      ada: ada,
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      doc: doc
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp file(path, body, type \\ nil) do
    %{"path" => path, "bytes" => Base.encode64(body)}
    |> then(&if(type, do: Map.put(&1, "content_type", type), else: &1))
  end

  defp body(context, n, path) do
    {:ok, %{body: body}} =
      Artifacts.fetch(context.doc["id"], n, path, context.ada)

    body
  end

  describe "a put" do
    test "is the next version at the same address, with its note and who and when", context do
      id = context.doc["id"]

      assert {:ok, two} =
               call(context.ada, "artifact.put", %{
                 "id" => id,
                 "files" => [file("index.md", "# Two")],
                 "note" => "the second draft"
               })

      assert two["id"] == id
      assert two["url"] == context.doc["url"]
      assert two["version"] == 2
      assert two["current"] == 2
      assert two["visibility"] == "profile:dev"
      assert two["title"] == "Notes"

      assert [%{"n" => 2, "note" => "the second draft"} = v2, %{"n" => 1}] = two["versions"]
      assert v2["published_by"]["subject"] == "ada@example.test"
      assert v2["published_at"]
      assert v2["url"] == "https://artifacts.example.test/a/#{id}/v2/"

      # Without `base`, the files sent are the whole version.
      assert Enum.map(v2["files"], & &1["path"]) == ["index.md"]
      assert body(context, 2, "index.md") == "# Two"
      assert body(context, 1, "index.md") == "# One"
      assert body(context, :current, nil) == "# Two"

      {:ok, got} = call(context.bo, "artifact.get", %{"id" => id})
      assert Enum.map(got["versions"], &{&1["n"], &1["note"]}) == [{2, "the second draft"}, {1, nil}]
    end

    test "on a base carries the files it does not send, without copying them", context do
      id = context.doc["id"]

      assert {:ok, two} =
               call(context.ada, "artifact.put", %{
                 "id" => id,
                 "base" => 1,
                 "files" => [file("index.md", "# Edited")]
               })

      assert [%{"n" => 2, "files" => files} | _] = two["versions"]
      assert Enum.map(files, & &1["path"]) == ["figure.svg", "index.md"]
      assert Enum.find(files, &(&1["path"] == "figure.svg"))["content_type"] == "image/svg+xml"
      assert body(context, 2, "figure.svg") == "<svg/>"
      assert body(context, 2, "index.md") == "# Edited"

      # The carried file is the base version's object, not a second copy.
      assert {:error, :not_found} =
               ObjectStore.get(context.store, "artifacts/#{id}/2/figure.svg")

      assert two["bytes"] == byte_size("# Edited") + byte_size("<svg/>")
    end

    test "on a base that is not the newest is refused, since somebody published after it",
         context do
      id = context.doc["id"]
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 2")]})

      assert {:error, %{message: "conflict", data: %{reason: reason}}} =
               call(context.ada, "artifact.put", %{
                 "id" => id,
                 "base" => 1,
                 "files" => [file("index.md", "# stale")]
               })

      assert reason =~ "version 2"
    end

    test "is the owner's, or an edit link's holder's, and nobody else's", context do
      id = context.doc["id"]

      # Bo sees it, through the profile, and may not put to it.
      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.put", %{"id" => id, "files" => [file("index.md", "x")]})

      # Cy cannot see it at all.
      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.put", %{"id" => id, "files" => [file("index.md", "x")]})

      # A put keeps the kind, and an entry file.
      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.put", %{
                 "id" => id,
                 "files" => [file("notes.txt", "x")]
               })
    end

    test "is audited as a publish with the version and the note, never the content", context do
      id = context.doc["id"]

      {:ok, _} =
        call(context.ada, "artifact.put", %{
          "id" => id,
          "files" => [file("index.md", "# secret words")],
          "note" => "tidy"
        })

      assert %{detail: detail} =
               Enum.find(Audit.list(), &(&1.action == "artifact.publish" and &1.detail["version"] == 2))

      assert detail["note"] == "tidy"
      refute inspect(detail) =~ "secret words"
    end

    test "through publish with an id is the same put, by an edit link's holder too", context do
      id = context.doc["id"]
      {:ok, %{"token" => token}} = call(context.ada, "artifact.share", %{"id" => id, "role" => "edit"})
      {:ok, _} = call(context.cy, "artifact.redeem", %{"token" => token})

      assert {:ok, two} =
               call(context.cy, "artifact.publish", %{
                 "id" => id,
                 "title" => "Notes",
                 "kind" => "markdown",
                 "visibility" => "profile:dev",
                 "files" => [file("index.md", "# By Cy")]
               })

      assert two["version"] == 2
      assert hd(two["versions"])["published_by"]["subject"] == "cy@example.test"

      # Who may open it is its owner's to change.
      assert {:error, %{message: "forbidden", data: %{reason: reason}}} =
               call(context.cy, "artifact.publish", %{
                 "id" => id,
                 "title" => "Notes",
                 "kind" => "markdown",
                 "visibility" => "organisation",
                 "files" => [file("index.md", "# Wider")]
               })

      assert reason =~ "owner"
    end
  end

  describe "a rollback" do
    test "republishes an old version's files as the next one, audited as rolled back", context do
      id = context.doc["id"]
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 2")]})
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 3")]})

      assert {:ok, four} = call(context.ada, "artifact.rollback", %{"id" => id, "version" => 1})
      assert four["version"] == 4
      assert [%{"n" => 4, "note" => "rolled back to v1", "files" => files} | _] = four["versions"]
      assert Enum.map(files, & &1["path"]) == ["figure.svg", "index.md"]
      assert body(context, :current, nil) == "# One"

      assert %{detail: %{"version" => 4, "rolled_back_to" => 1}} =
               Enum.find(Audit.list(), &(&1.action == "artifact.rollback"))

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.rollback", %{"id" => id, "version" => 9})

      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.rollback", %{"id" => id, "version" => 1})
    end
  end

  describe "the current version" do
    test "is the newest unless the owner pins one", context do
      id = context.doc["id"]
      {:ok, _} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 2")]})

      assert {:ok, pinned} = call(context.ada, "artifact.pin", %{"id" => id, "version" => 1})
      assert pinned["pinned"] == 1
      assert pinned["current"] == 1
      assert pinned["version"] == 2
      assert body(context, :current, nil) == "# One"

      # A later version is published and the pin holds until the owner lets it go.
      {:ok, three} = call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 3")]})
      assert three["current"] == 1
      assert body(context, :current, nil) == "# One"

      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.pin", %{"id" => id, "version" => 2})

      assert {:ok, unpinned} = call(context.ada, "artifact.pin", %{"id" => id, "version" => nil})
      assert unpinned["pinned"] == nil
      assert unpinned["current"] == 3
      assert body(context, :current, nil) == "# 3"

      assert Enum.any?(Audit.list(), &(&1.action == "artifact.pin" and &1.detail["pinned"] == 1))
    end
  end

  describe "editing in the console" do
    test "reads one text file of a version for the editor", context do
      id = context.doc["id"]

      assert {:ok, read} = call(context.bo, "artifact.read", %{"id" => id, "path" => "index.md"})
      assert read["text"] == "# One"
      assert read["version"] == 1
      assert read["content_type"] =~ "markdown"

      assert {:error, %{message: "not_found"}} =
               call(context.cy, "artifact.read", %{"id" => id, "path" => "index.md"})

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.read", %{"id" => id, "path" => "nope.md"})
    end

    test "previews an edit on the artifacts host, for whoever may put", context do
      id = context.doc["id"]

      assert {:ok, %{"url" => url, "expires_in" => seconds}} =
               call(context.ada, "artifact.preview", %{
                 "id" => id,
                 "base" => 1,
                 "path" => "index.md",
                 "text" => "# Draft"
               })

      assert "https://artifacts.example.test/p/" <> token = url
      assert String.ends_with?(token, "/")
      assert seconds > 0

      token = String.trim_trailing(token, "/")
      assert {:ok, draft} = Artifacts.preview_file(token, "index.md")
      assert draft.body == "# Draft"
      assert {:ok, carried} = Artifacts.preview_file(token, "figure.svg")
      assert carried.body == "<svg/>"
      assert {:ok, entry} = Artifacts.preview_file(token, nil)
      assert entry.body == "# Draft"
      assert :error = Artifacts.preview_file(token <> "x", "index.md")

      assert {:error, %{message: "forbidden"}} =
               call(context.bo, "artifact.preview", %{
                 "id" => id,
                 "path" => "index.md",
                 "text" => "# Bo's"
               })

      # Nothing is published by a preview.
      {:ok, got} = call(context.ada, "artifact.get", %{"id" => id})
      assert got["version"] == 1
    end
  end

  describe "an upload handle" do
    test "takes a version's files straight into the object store, then a publish names it",
         context do
      big = :binary.copy("x", 5 * 1024 * 1024)

      assert {:ok, %{"upload" => handle, "urls" => urls, "expires_in" => _}} =
               call(context.ada, "artifact.upload.begin", %{
                 "files" => [
                   %{"path" => "index.html", "size" => 19, "content_type" => "text/html"},
                   %{"path" => "data.bin", "size" => byte_size(big)}
                 ]
               })

      assert [%{"path" => "data.bin", "url" => put_data}, %{"path" => "index.html", "url" => put_page}] =
               Enum.sort_by(urls, & &1["path"])

      assert %{status: 200} = Req.put!(put_page, body: "<h1>Big report</h1>", retry: false)
      assert %{status: 200} = Req.put!(put_data, body: big, retry: false)

      # Nobody else may spend it.
      assert {:error, %{message: "not_found"}} =
               call(context.bo, "artifact.publish", %{
                 "title" => "Big",
                 "kind" => "html",
                 "visibility" => "profile:dev",
                 "upload" => handle
               })

      assert {:ok, published} =
               call(context.ada, "artifact.publish", %{
                 "title" => "Big",
                 "kind" => "html",
                 "visibility" => "profile:dev",
                 "upload" => handle
               })

      assert published["bytes"] == byte_size(big) + 19

      assert {:ok, ^big} =
               ObjectStore.get(context.store, "artifacts/#{published["id"]}/1/data.bin")

      # Spent once, and its objects gone from the upload's prefix.
      assert {:ok, []} = ObjectStore.list(context.store, "artifact-uploads/#{handle}/")

      assert {:error, %{message: "not_found"}} =
               call(context.ada, "artifact.publish", %{
                 "title" => "Big",
                 "kind" => "html",
                 "visibility" => "profile:dev",
                 "upload" => handle
               })
    end

    test "refuses a file that is not the size it was announced at, and one past the limits",
         context do
      {:ok, %{"upload" => handle, "urls" => [%{"url" => url}]}} =
        call(context.ada, "artifact.upload.begin", %{
          "files" => [%{"path" => "index.md", "size" => 5}]
        })

      Req.put!(url, body: "# longer than five", retry: false)

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               call(context.ada, "artifact.put", %{"id" => context.doc["id"], "upload" => handle})

      assert reason =~ "index.md"

      assert {:error, %{message: "payload_too_large"}} =
               call(context.ada, "artifact.upload.begin", %{
                 "files" => [%{"path" => "a.bin", "size" => 16 * 1024 * 1024 + 1}]
               })

      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.upload.begin", %{
                 "files" => [%{"path" => "../a.bin", "size" => 1}]
               })
    end
  end

  describe "a publish that fails" do
    test "leaves no object behind it", context do
      id = context.doc["id"]

      # A team quota the version would cross: refused after the files were checked.
      Repo.update_all(Team, set: [artifact_quota_bytes: 1])

      assert {:error, %{message: "payload_too_large"}} =
               call(context.ada, "artifact.put", %{"id" => id, "files" => [file("index.md", "# 2")]})

      assert {:ok, []} = ObjectStore.list(context.store, "artifacts/#{id}/2/")

      # And a path's part past the 255 bytes the store keeps one to is refused before any
      # file is written, rather than by the store midway.
      Repo.update_all(Team, set: [artifact_quota_bytes: 0])
      long = "zzz/" <> String.duplicate("a", 300) <> ".md"

      assert {:error, %{message: "invalid_params"}} =
               call(context.ada, "artifact.put", %{
                 "id" => id,
                 "files" => [file("index.md", "# 2"), file(long, "no")]
               })

      assert {:ok, []} = ObjectStore.list(context.store, "artifacts/#{id}/2/")
    end
  end
end
