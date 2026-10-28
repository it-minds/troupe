defmodule Troupe.Plane.ArtifactsHostTest do
  @moduledoc """
  The artifacts host (#62): a published page served from an origin of its own, where it can
  touch nothing of the plane's.

  The isolation is held here by the headers and the cookie scope, over a real socket against
  the host's own listener, precisely:

    * every answer's policy runs the page sandboxed without `allow-same-origin` (so a
      script's `document.cookie` throws and an answer from any host, this one included, is
      another origin's it cannot read), lets it connect to this host alone (no `connect-src`
      to the plane), runs only its own script files (no inline script, no `eval`), and lets
      only the plane's own origin frame it;
    * the cookie that signs a viewer in here is this host's alone (no `Domain`), `HttpOnly`,
      and set only from a ticket the plane signed; the plane's own cookie is its host's alone,
      so it is never sent here;
    * nothing of the plane's answers here (`/rpc`, the console, the API), and the plane's
      listener serves no artifact.

  That a browser holds a published page to it, `fetch` of the plane's `/rpc` and
  `document.cookie` both refused, is shown in Chromium against the development plane (the
  pull request says how); this test is what CI holds.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.Artifacts, as: Published
  alias Troupe.Plane.{Harness, Identity, Settings}
  alias Troupe.Plane.Web.{Artifacts, Endpoint}
  alias Troupe.Plane.Web.Artifacts.CSP

  @moduletag timeout: 60_000

  @probe """
  <!doctype html><html><head><title>Probe</title><script src="probe.js"></script></head>
  <body><h1>Probe</h1><script>document.title = "inline ran"</script></body></html>
  """

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
      Harness.call(
        "artifact.publish",
        %{
          "title" => "Probe",
          "kind" => "html",
          "visibility" => "profile:dev",
          "files" => [
            file("index.html", @probe, "text/html"),
            file(
              "probe.js",
              "fetch('https://plane.example.test/rpc'); document.cookie",
              "text/javascript"
            )
          ]
        },
        %{user: ada, platform_admin?: false}
      )

    %{
      host: "http://127.0.0.1:#{port}",
      ada: ada,
      cy: person("cy@example.test", ["research"]),
      artifact: artifact
    }
  end

  defp file(path, body, type),
    do: %{"path" => path, "bytes" => Base.encode64(body), "content_type" => type}

  defp get(context, path, cookie \\ nil) do
    headers = if cookie, do: [{"cookie", "troupe_artifact_viewer=#{cookie}"}], else: []
    Req.get!(context.host <> path, headers: headers, redirect: false, retry: false)
  end

  defp header(response, name), do: response |> Req.Response.get_header(name) |> List.first()

  # In through the door a viewer has: a ticket from the plane, redeemed for the cookie.
  defp signed_in(context, user, params \\ %{}) do
    {:ok, %{"url" => url}} =
      Harness.call("artifact.open", Map.put(params, "id", context.artifact["id"]), %{
        user: user,
        platform_admin?: false
      })

    "https://artifacts.example.test" <> path = url
    response = get(context, path)
    assert response.status == 303
    [set_cookie] = Req.Response.get_header(response, "set-cookie")
    [_, cookie] = Regex.run(~r/troupe_artifact_viewer=([^;]+)/, set_cookie)
    {cookie, set_cookie, header(response, "location")}
  end

  describe "the policy on every answer" do
    test "sandboxes the page, keeps it to its own files, connects nowhere else, framed by the plane alone",
         context do
      {cookie, _set, _to} = signed_in(context, context.ada)
      id = context.artifact["id"]

      for path <- [
            "/a/#{id}/",
            "/a/#{id}/probe.js",
            "/a/#{id}/v1/",
            "/a/#{id}/nothing",
            "/_/document.css",
            "/enter",
            "/rpc"
          ] do
        response = get(context, path, cookie)
        policy = header(response, "content-security-policy")
        assert policy, "#{path} has no policy"

        directives =
          Map.new(String.split(policy, "; "), fn d ->
            d |> String.split(" ") |> then(&{hd(&1), tl(&1)})
          end)

        assert directives["sandbox"] == [
                 "allow-scripts",
                 "allow-popups",
                 "allow-popups-to-escape-sandbox",
                 "allow-downloads"
               ]

        refute "allow-same-origin" in directives["sandbox"]
        refute "allow-top-navigation" in directives["sandbox"]
        assert directives["default-src"] == ["'self'"]
        assert directives["script-src"] == ["'self'"]
        assert directives["connect-src"] == ["'self'"]
        refute policy =~ "plane.example.test/rpc"
        assert directives["frame-ancestors"] == ["https://plane.example.test"]
        assert directives["object-src"] == ["'none'"]
        assert directives["form-action"] == ["'none'"]
        assert header(response, "x-content-type-options") == "nosniff"
        assert header(response, "referrer-policy") == "no-referrer"
      end
    end

    test "with no plane address, nothing may frame it" do
      Application.delete_env(:troupe_plane, :base_url)

      assert CSP.policy(CSP.plane_origin()) =~
               "frame-ancestors 'none'"
    end
  end

  describe "the viewer's sign-in" do
    test "is this host's own cookie, from a ticket, out of a script's reach, sent nowhere else",
         context do
      {cookie, set_cookie, to} = signed_in(context, context.ada)
      assert to == "/a/#{context.artifact["id"]}/"

      attributes =
        set_cookie |> String.split(";") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))

      assert "httponly" in attributes
      assert "secure" in attributes
      assert "samesite=none" in attributes
      assert "path=/" in attributes
      refute Enum.any?(attributes, &String.starts_with?(&1, "domain="))
      assert Enum.any?(attributes, &String.starts_with?(&1, "max-age=3600"))

      response = get(context, "/a/#{context.artifact["id"]}/", cookie)
      assert response.status == 200
      assert response.body =~ "<h1>Probe</h1>"
    end

    test "a signed-out viewer is sent to the console's door for the artifact, and a forged cookie is signed out",
         context do
      id = context.artifact["id"]

      for cookie <- [
            nil,
            "forged",
            Published.viewer_cookie("ada@example.test") <> "x"
          ] do
        response = get(context, "/a/#{id}/", cookie)
        assert response.status == 302

        # The door that signs them in and comes back here, not the page about it.
        assert header(response, "location") ==
                 "https://plane.example.test/console#/artifacts/open/#{id}"
      end

      # A version's address comes back to that version; a file's, to its version's entry.
      assert header(get(context, "/a/#{id}/v1/", nil), "location") ==
               "https://plane.example.test/console#/artifacts/open/#{id}/v1"

      assert header(get(context, "/a/#{id}/v1/style.css", nil), "location") ==
               "https://plane.example.test/console#/artifacts/open/#{id}/v1"

      assert header(get(context, "/a/#{id}/style.css", nil), "location") ==
               "https://plane.example.test/console#/artifacts/open/#{id}"
    end

    test "a ticket opens once", context do
      {:ok, %{"url" => "https://artifacts.example.test" <> path}} =
        Harness.call("artifact.open", %{"id" => context.artifact["id"]}, %{
          user: context.ada,
          platform_admin?: false
        })

      assert get(context, path).status == 303
      assert get(context, path).status == 403
      assert get(context, "/enter?ticket=forged").status == 403
      assert get(context, "/enter").status == 403
    end
  end

  describe "what it serves" do
    test "the current version at its address, and each version at its own", context do
      id = context.artifact["id"]

      {:ok, _} =
        Harness.call(
          "artifact.publish",
          %{
            "id" => id,
            "title" => "Probe",
            "kind" => "html",
            "visibility" => "profile:dev",
            "files" => [file("index.html", "<p>two</p>", "text/html")]
          },
          %{user: context.ada, platform_admin?: false}
        )

      {cookie, _set, _to} = signed_in(context, context.ada)
      assert get(context, "/a/#{id}/", cookie).body == "<p>two</p>"
      assert get(context, "/a/#{id}/v1/", cookie).body =~ "<h1>Probe</h1>"
      assert get(context, "/a/#{id}/v1/probe.js", cookie).body =~ "fetch("

      assert header(get(context, "/a/#{id}/v1/probe.js", cookie), "content-type") =~
               "text/javascript"

      assert get(context, "/a/#{id}/probe.js", cookie).status == 404
      assert get(context, "/a/#{id}/v9/", cookie).status == 404
      assert get(context, "/a/#{id}", cookie).status == 301
    end

    test "a viewer who may not see it is told there is none, as for one that is not there",
         context do
      cookie = Published.viewer_cookie(context.cy.subject)
      assert get(context, "/a/#{context.artifact["id"]}/", cookie).status == 404
      assert get(context, "/a/art-nonexistent/", cookie).status == 404

      # And one who leaves the profile's team, at their next request.
      bo = person("bo@example.test", ["engineering"])
      {bo_cookie, _set, _to} = signed_in(context, bo)
      assert get(context, "/a/#{context.artifact["id"]}/", bo_cookie).status == 200
      {:ok, _} = Identity.set_memberships(bo, [])
      assert get(context, "/a/#{context.artifact["id"]}/", bo_cookie).status == 404
    end

    test "nothing of the plane's answers here", context do
      {cookie, _set, _to} = signed_in(context, context.ada)

      for path <- ["/rpc", "/admin", "/console/", "/.well-known/troupe", "/v1/relay/watch", "/"] do
        assert get(context, path, cookie).status == 404, path
      end

      response =
        Req.post!(context.host <> "/rpc",
          json: %{"method" => "me"},
          redirect: false,
          retry: false
        )

      assert response.status == 404
    end

    test "the plane's own listener serves no artifact", context do
      {:ok, {_address, port}} = Endpoint.server_info(:http)

      response =
        Req.get!("http://127.0.0.1:#{port}/a/#{context.artifact["id"]}/",
          redirect: false,
          retry: false
        )

      assert response.status == 404
      refute inspect(response.body) =~ "Probe"
    end

    test "a Markdown document is rendered here, highlighted, its diagram drawn, its HTML only text",
         context do
      markdown = """
      # Findings

      Some **bold** text and a [link](https://example.test/x) and [a trap](javascript:alert(1)).

      <script>alert(1)</script>

      ```elixir
      def hello, do: "world" # greets
      ```

      ```mermaid
      graph LR
        A[Start] --> B{Ok?}
        B -->|yes| C(Done)
      ```
      """

      {:ok, doc} =
        Harness.call(
          "artifact.publish",
          %{
            "title" => "Notes",
            "kind" => "markdown",
            "visibility" => "profile:dev",
            "files" => [file("index.md", markdown, "text/markdown")]
          },
          %{user: context.ada, platform_admin?: false}
        )

      cookie = Published.viewer_cookie("ada@example.test")
      response = get(context, "/a/#{doc["id"]}/", cookie)
      assert response.status == 200
      assert header(response, "content-type") =~ "text/html"
      body = response.body

      assert body =~ ~s(<h1 id="findings">Findings</h1>)
      assert body =~ "<strong>bold</strong>"
      assert body =~ ~s(<a href="https://example.test/x">link</a>)
      refute body =~ ~s(href="javascript:)
      refute body =~ "<script>"
      assert body =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert body =~ ~s(<span class="k">def</span>)
      assert body =~ ~s(<span class="s">&quot;world&quot;</span>)
      assert body =~ ~s(<span class="c"># greets</span>)
      assert body =~ ~s(<svg class="mermaid")
      assert body =~ ">Start</text>"
      assert body =~ ">yes</text>"
      assert body =~ ~s(href="/_/document.css")

      assert get(context, "/_/document.css").status == 200
    end

    test "switched off, nothing is served", context do
      {cookie, _set, _to} = signed_in(context, context.ada)
      {:ok, _} = Settings.put("artifacts_enabled", "false", "root")
      assert get(context, "/a/#{context.artifact["id"]}/", cookie).status == 404
    end
  end
end
