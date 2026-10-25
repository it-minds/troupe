defmodule Troupe.Plane.ArtifactLinksHostTest do
  @moduledoc """
  The artifacts host's side of a link and of an edit's preview (#62), over a socket against
  the host's own listener, as `ArtifactsHostTest` holds the rest of it:

    * `/s/<token>` gives a signed-in viewer the link's role and opens the artifact, and sends
      a viewer with no sign-in here to the console, which signs them in at the plane; a link
      that expired or was revoked opens nothing;
    * a public link (`/s/<token>/`) is served without a sign-in, under the same policy, only
      while the administrator's setting and the artifact's own switch are on;
    * `/p/<token>/` is an edit's preview, the edited file over the version it was made on,
      under the same policy, so the console frames it and never draws it itself.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Harness, Settings}
  alias Troupe.Plane.Web.Artifacts

  @moduletag timeout: 60_000

  setup do
    Application.put_env(:troupe_plane, :base_url, "https://plane.example.test")
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :base_url)
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _dev = team_with_grant("engineering", "dev", name: "engineering")
    _lab = team_with_grant("research", "lab", name: "research")

    {:ok, pid} =
      start_supervised(
        {Bandit, plug: Artifacts, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    ada = person("ada@example.test", ["engineering"])

    {:ok, artifact} =
      call(ada, "artifact.publish", %{
        "title" => "Notes",
        "kind" => "markdown",
        "visibility" => "profile:dev",
        "files" => [
          %{"path" => "index.md", "bytes" => Base.encode64("# Notes\n\nSee [the figure](figure.svg).")},
          %{"path" => "figure.svg", "bytes" => Base.encode64("<svg/>"), "content_type" => "image/svg+xml"}
        ]
      })

    %{
      host: "http://127.0.0.1:#{port}",
      ada: ada,
      cy: person("cy@example.test", ["research"]),
      artifact: artifact
    }
  end

  defp call(user, method, params), do: Harness.call(method, params, %{user: user, platform_admin?: false})

  defp get(context, path, cookie \\ nil) do
    headers = if cookie, do: [{"cookie", "troupe_artifact_viewer=#{cookie}"}], else: []
    Req.get!(context.host <> path, headers: headers, redirect: false, retry: false)
  end

  defp header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  defp path_of("https://artifacts.example.test" <> path), do: path

  # Signed in on the host as `user`, through a ticket for an artifact they may open.
  defp cookie_for(context, user, id) do
    {:ok, %{"url" => url}} = call(user, "artifact.open", %{"id" => id})
    response = get(context, path_of(url))
    [set_cookie] = Req.Response.get_header(response, "set-cookie")
    [_, cookie] = Regex.run(~r/troupe_artifact_viewer=([^;]+)/, set_cookie)
    cookie
  end

  defp share(context, params),
    do: call(context.ada, "artifact.share", Map.put(params, "id", context.artifact["id"]))

  describe "a link" do
    test "with no sign-in on this host sends the viewer to the console with it", context do
      {:ok, %{"url" => url, "token" => token}} = share(context, %{"role" => "view"})
      response = get(context, path_of(url))
      assert response.status == 302

      assert header(response, "location") ==
               "https://plane.example.test/console#/artifacts/link/#{token}"

      # Nothing is recorded until the plane says who it is.
      {:ok, got} = call(context.ada, "artifact.get", %{"id" => context.artifact["id"]})
      assert [%{"used_by" => []}] = got["shares"]
    end

    test "with a sign-in here gives that viewer its role and opens the artifact", context do
      id = context.artifact["id"]
      {:ok, %{"url" => url}} = share(context, %{"role" => "view"})

      # Cy is signed in on this host, for an artifact of their own team's.
      {:ok, theirs} =
        call(context.cy, "artifact.publish", %{
          "title" => "Lab",
          "kind" => "file",
          "visibility" => "profile:lab",
          "files" => [%{"path" => "a.txt", "bytes" => Base.encode64("a")}]
        })

      cookie = cookie_for(context, context.cy, theirs["id"])
      assert get(context, "/a/#{id}/", cookie).status == 404

      response = get(context, path_of(url), cookie)
      assert response.status == 303
      assert header(response, "location") == "/a/#{id}/"
      assert get(context, "/a/#{id}/", cookie).status == 200

      {:ok, got} = call(context.ada, "artifact.get", %{"id" => id})
      assert [%{"used_by" => [%{"person" => %{"subject" => "cy@example.test"}}]}] = got["shares"]
    end

    test "that was revoked opens nothing", context do
      {:ok, %{"url" => url, "share" => %{"id" => share_id}}} = share(context, %{"role" => "view"})
      {:ok, _} = call(context.ada, "artifact.unshare", %{"id" => context.artifact["id"], "share" => share_id})
      response = get(context, path_of(url))
      assert response.status == 404
      assert header(response, "content-security-policy") =~ "sandbox"
    end
  end

  describe "a public link" do
    test "is served with no sign-in, under the same policy, while both switches are on", context do
      {:ok, _} = Settings.put("artifacts_public_links", "true", "root@example.test")
      soon = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      {:ok, %{"url" => url}} = share(context, %{"role" => "view", "public" => true, "expires" => soon})
      path = path_of(url)
      assert String.ends_with?(path, "/")

      response = get(context, path)
      assert response.status == 200
      assert response.body =~ "<h1"
      assert header(response, "content-security-policy") =~ "sandbox allow-scripts"
      assert header(response, "set-cookie") == nil

      figure = get(context, path <> "figure.svg")
      assert figure.status == 200
      assert header(figure, "content-type") =~ "image/svg+xml"

      assert get(context, String.trim_trailing(path, "/")).status == 301

      {:ok, _} = call(context.ada, "artifact.public", %{"id" => context.artifact["id"], "enabled" => false})
      assert get(context, path).status == 404

      {:ok, _} = call(context.ada, "artifact.public", %{"id" => context.artifact["id"], "enabled" => true})
      {:ok, _} = Settings.put("artifacts_public_links", "false", "root@example.test")
      assert get(context, path).status == 404
    end
  end

  describe "an edit's preview" do
    test "is the edited file over its version, rendered as the host renders it", context do
      {:ok, %{"url" => url}} =
        call(context.ada, "artifact.preview", %{
          "id" => context.artifact["id"],
          "base" => 1,
          "path" => "index.md",
          "text" => "# Draft heading\n\n<script>alert(1)</script>"
        })

      path = path_of(url)
      response = get(context, path)
      assert response.status == 200
      assert response.body =~ "Draft heading"
      refute response.body =~ "<script>alert"
      assert header(response, "content-security-policy") =~ "sandbox allow-scripts"
      assert header(response, "content-security-policy") =~ "frame-ancestors https://plane.example.test"
      assert header(response, "cache-control") =~ "no-store"

      assert get(context, path <> "figure.svg").status == 200
      assert get(context, "/p/forged/").status == 404
    end
  end
end
