defmodule Troupe.Plane.ArtifactThumbnailsTest do
  @moduledoc """
  A gallery card's picture (#977): sent by the publisher with a version, kept beside its files
  in the object store, counted against the team's quota, and served by the artifacts host at
  the address a row of `artifact.list` gives its person, to that person alone while they may
  see the artifact. A version without one has none, so a card never shows a picture of a page
  that is not the one it opens.

  Against the development MinIO, over a socket against the artifacts host's own listener, as
  `ArtifactsHostTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Artifacts, Harness, Identity}
  alias Troupe.Plane.Web.Artifacts, as: Host

  @moduletag timeout: 60_000

  # The smallest PNG there is: one transparent pixel.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
       )

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
    _research = team_with_grant("research", "lab", name: "research")

    {:ok, pid} =
      start_supervised({Bandit, plug: Host, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    %{
      host: "http://127.0.0.1:#{port}",
      store: ObjectStore.from_env(),
      root: person("root@example.test", ["platform"]),
      ada: person("ada@example.test", ["engineering"]),
      bo: person("bo@example.test", ["engineering"]),
      cy: person("cy@example.test", ["research"]),
      engineering: engineering
    }
  end

  defp as(user), do: %{user: user, platform_admin?: Admin.actor_for(user).role == :platform_admin}
  defp call(user, method, params), do: Harness.call(method, params, as(user))

  defp page(html),
    do: [%{"path" => "index.html", "content_type" => "text/html", "bytes" => Base.encode64(html)}]

  defp picture(body \\ @png, type \\ "image/png"),
    do: %{"content_type" => type, "bytes" => Base.encode64(body)}

  defp publish(user, attrs) do
    call(
      user,
      "artifact.publish",
      Map.merge(
        %{"title" => "Report", "kind" => "html", "files" => page("<h1>Hi</h1>")}
        |> Map.merge(if(Map.has_key?(attrs, "id"), do: %{}, else: %{"teams" => ["engineering"]})),
        attrs
      )
    )
  end

  # The address's path on this listener: the row's address names the deployed host.
  defp fetch(context, "https://artifacts.example.test" <> path),
    do: Req.get!(context.host <> path, redirect: false, retry: false)

  defp row(user, id) do
    {:ok, %{"artifacts" => rows}} = call(user, "artifact.list", %{})
    Enum.find(rows, &(&1["id"] == id))
  end

  describe "publishing a picture with a version" do
    test "keeps it beside the files and puts its address on the rows", context do
      {:ok, artifact} = publish(context.ada, %{"thumbnail" => picture()})

      assert "https://artifacts.example.test/t/" <> _ = artifact["thumbnail_url"]
      assert {:ok, @png} = ObjectStore.get(context.store, "artifacts/#{artifact["id"]}/thumbnails/1")

      assert row(context.ada, artifact["id"])["thumbnail_url"] =~ "/t/"
      {:ok, got} = call(context.ada, "artifact.get", %{"id" => artifact["id"]})
      assert got["thumbnail_url"] =~ "/t/"

      # Not one of the page's files: the version's hash and file list are the page's alone.
      [version] = got["versions"]
      assert Enum.map(version["files"], & &1["path"]) == ["index.html"]
    end

    test "a version without one has none, whatever the one before had", context do
      {:ok, first} = publish(context.ada, %{"thumbnail" => picture()})
      assert first["thumbnail_url"] =~ "/t/"
      {:ok, plain} = publish(context.ada, %{})
      assert Map.has_key?(plain, "thumbnail_url")

      assert plain["thumbnail_url"] == nil
      assert row(context.ada, plain["id"])["thumbnail_url"] == nil

      {:ok, second} = publish(context.ada, %{"id" => first["id"], "files" => page("<h1>Changed</h1>")})
      assert second["version"] == 2
      assert second["thumbnail_url"] == nil
    end

    test "a version that sends no file keeps its base's picture, and a rollback its version's", context do
      {:ok, first} = publish(context.ada, %{"thumbnail" => picture()})
      {:ok, _two} = publish(context.ada, %{"id" => first["id"], "files" => page("<h1>Two</h1>")})

      {:ok, renamed} = call(context.ada, "artifact.put", %{"id" => first["id"], "base" => 2, "title" => "Renamed"})
      assert renamed["thumbnail_url"] == nil

      {:ok, back} = call(context.ada, "artifact.rollback", %{"id" => first["id"], "version" => 1})
      assert back["version"] == 4
      assert %{status: 200, body: @png} = fetch(context, back["thumbnail_url"])

      {:ok, retitled} = call(context.ada, "artifact.put", %{"id" => first["id"], "base" => 4, "title" => "Again"})
      assert %{status: 200, body: @png} = fetch(context, retitled["thumbnail_url"])

      # Carried, not copied: version 1's object is the only one.
      assert {:error, _} = ObjectStore.get(context.store, "artifacts/#{first["id"]}/thumbnails/4")
    end

    test "a pin shows the pinned version's picture", context do
      {:ok, first} = publish(context.ada, %{"thumbnail" => picture()})
      {:ok, _two} = publish(context.ada, %{"id" => first["id"], "files" => page("<h1>Two</h1>")})
      assert row(context.ada, first["id"])["thumbnail_url"] == nil

      {:ok, pinned} = call(context.ada, "artifact.pin", %{"id" => first["id"], "version" => 1})
      assert %{status: 200, body: @png} = fetch(context, pinned["thumbnail_url"])
    end

    test "is refused in words past 256 KiB, as another kind, or not the kind it says", context do
      big = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy("x", 256 * 1024)

      assert {:error, %{message: "invalid_params", data: %{reason: reason}}} =
               publish(context.ada, %{"thumbnail" => picture(big)})

      assert reason =~ "past the 262144 a thumbnail may be"

      assert {:error, %{data: %{reason: reason}}} =
               publish(context.ada, %{"thumbnail" => picture("GIF89a", "image/gif")})

      assert reason =~ "image/png, image/jpeg or image/webp"

      assert {:error, %{data: %{reason: reason}}} =
               publish(context.ada, %{"thumbnail" => picture("<script>alert(1)</script>")})

      assert reason =~ "not a PNG picture"

      assert {:error, %{data: %{reason: reason}}} = publish(context.ada, %{"thumbnail" => "shot.png"})
      assert reason =~ "{content_type, bytes}"

      assert {:error, %{data: %{reason: "the thumbnail's bytes are not base64"}}} =
               publish(context.ada, %{"thumbnail" => %{"content_type" => "image/png", "bytes" => "%%%"}})

      # Nothing was kept of any of them.
      {:ok, %{"artifacts" => []}} = call(context.ada, "artifact.list", %{})
    end

    test "counts against the team's quota as a file does", context do
      {:ok, _} =
        Admin.team_update(Admin.actor_for(context.root), "engineering", %{"artifact_quota_bytes" => 100})

      html = String.duplicate("x", 20)
      {:ok, _} = publish(context.ada, %{"files" => page(html), "thumbnail" => picture()})
      assert Artifacts.usage(context.engineering) == 20 + byte_size(@png)

      assert {:error, %{message: "payload_too_large", data: %{reason: reason}}} =
               publish(context.ada, %{"files" => page(html), "thumbnail" => picture()})

      assert reason =~ "past its quota"
    end
  end

  describe "the artifacts host serves it" do
    test "to the person whose row gave the address, with its type, under the host's policy", context do
      {:ok, artifact} = publish(context.ada, %{"thumbnail" => picture()})

      response = fetch(context, row(context.bo, artifact["id"])["thumbnail_url"])
      assert response.status == 200
      assert response.body == @png
      assert Req.Response.get_header(response, "content-type") == ["image/png"]
      assert Req.Response.get_header(response, "x-content-type-options") == ["nosniff"]
      [policy] = Req.Response.get_header(response, "content-security-policy")
      assert policy =~ "sandbox allow-scripts"
      refute policy =~ "allow-same-origin"
      # No cookie is asked for or set: the address is the key.
      assert Req.Response.get_header(response, "set-cookie") == []
    end

    test "to nobody who may not see it now, nor at an address made up or altered", context do
      # Ada's own, for her team: Bo reads it as a member, and owns nothing of it.
      {:ok, artifact} = publish(context.ada, %{"owner" => "me", "thumbnail" => picture()})
      url = row(context.ada, artifact["id"])["thumbnail_url"]

      # A stranger to the team has no row, and gets nothing at its address either.
      assert row(context.cy, artifact["id"]) == nil
      "https://artifacts.example.test/t/" <> token = url
      assert %{status: 404} = fetch(context, "https://artifacts.example.test/t/#{token}x")
      assert %{status: 404} = fetch(context, "https://artifacts.example.test/t/forged")

      # Taken from the team, Bo's address stops opening at once.
      bo_url = row(context.bo, artifact["id"])["thumbnail_url"]
      {:ok, _} = call(context.ada, "artifact.access.set", %{"id" => artifact["id"], "teams" => []})
      assert %{status: 200} = fetch(context, url)
      assert %{status: 404} = fetch(context, bo_url)
    end

    test "nothing once the artifact is deleted, and its picture is gone from the store", context do
      {:ok, artifact} = publish(context.ada, %{"thumbnail" => picture()})
      url = artifact["thumbnail_url"]
      {:ok, _} = call(context.ada, "artifact.delete", %{"id" => artifact["id"]})
      assert %{status: 404} = fetch(context, url)
      assert {:error, _} = ObjectStore.get(context.store, "artifacts/#{artifact["id"]}/thumbnails/1")
    end
  end
end
