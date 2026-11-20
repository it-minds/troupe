defmodule Troupe.Plane.ArtifactBlockedReferencesTest do
  @moduledoc """
  A published page that loads what the artifacts host blocks (#1081): the publish succeeds,
  its answer names each blocked reference by file, kind and reference, the version keeps
  them, and every row says how many the version in force has. A put is read the same way,
  and a version that carries a file carries what was found in it.

  Against the development MinIO, as `ArtifactsTest` is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Harness}

  @moduletag timeout: 60_000

  @broken """
  <html><head>
    <link rel="stylesheet" href="https://cdn.example.test/lib.css">
  </head><body>
    <button onclick="go()">Go</button>
    <script>go()</script>
  </body></html>
  """

  @clean """
  <html><head><link rel="stylesheet" href="style.css"><script src="app.js"></script></head>
  <body style="margin: 0"><img src="data:image/png;base64,iVBORw0KGgo=" alt=""></body></html>
  """

  setup do
    Application.put_env(:troupe_plane, :artifacts, url: "https://artifacts.example.test")

    on_exit(fn ->
      Application.delete_env(:troupe_plane, :artifacts)
      ObjectStore.delete_prefix(ObjectStore.from_env(), "artifacts/")
    end)

    _engineering = team_with_grant("engineering", "dev", name: "engineering")
    %{ada: person("ada@example.test", ["engineering"])}
  end

  defp call(user, method, params),
    do:
      Harness.call(method, params, %{
        user: user,
        platform_admin?: Admin.actor_for(user).role == :platform_admin
      })

  defp file(path, body, type),
    do: %{"path" => path, "content_type" => type, "bytes" => Base.encode64(body)}

  defp publish(user, files, attrs \\ %{}) do
    call(
      user,
      "artifact.publish",
      Map.merge(
        %{
          "title" => "Report",
          "kind" => "html",
          "visibility" => "team:engineering",
          "files" => files
        },
        attrs
      )
    )
  end

  defp row(user, id) do
    {:ok, %{"artifacts" => rows}} = call(user, "artifact.list", %{})
    Enum.find(rows, &(&1["id"] == id))
  end

  defp kinds(blocked), do: blocked |> Enum.map(&{&1["file"], &1["kind"]}) |> Enum.sort()

  test "a page with a stylesheet from another site, an inline script and an onclick publishes with the three named",
       context do
    {:ok, artifact} = publish(context.ada, [file("index.html", @broken, "text/html")])

    assert kinds(artifact["blocked"]) == [
             {"index.html", "event_handler"},
             {"index.html", "inline_script"},
             {"index.html", "stylesheet"}
           ]

    assert %{"reference" => "https://cdn.example.test/lib.css", "line" => 2} =
             Enum.find(artifact["blocked"], &(&1["kind"] == "stylesheet"))

    assert artifact["blocked_count"] == 3
    assert row(context.ada, artifact["id"])["blocked_count"] == 3

    {:ok, got} = call(context.ada, "artifact.get", %{"id" => artifact["id"]})
    assert got["blocked_count"] == 3
    assert [%{"n" => 1, "blocked" => blocked, "files" => [listed]}] = got["versions"]
    assert length(blocked) == 3
    refute Map.has_key?(listed, "blocked")
  end

  test "a page that loads only its own files publishes with none", context do
    {:ok, artifact} =
      publish(context.ada, [
        file("index.html", @clean, "text/html"),
        file("style.css", "body { background: url(bg.png) }", "text/css"),
        # Its data as a script that sets a global, which a page here can load; a `fetch` of
        # its own file it cannot.
        file("app.js", ~s|window.rows = [{"a": 1}]; render(window.rows)|, "text/javascript")
      ])

    assert artifact["blocked"] == []
    assert artifact["blocked_count"] == 0
    assert row(context.ada, artifact["id"])["blocked_count"] == 0
  end

  test "artifact.put is read the same way, and a version carries what its carried files had",
       context do
    {:ok, first} = publish(context.ada, [file("index.html", @broken, "text/html")])

    # A retitle sends no file: the page is the same, and so is what it loads.
    {:ok, retitled} =
      call(context.ada, "artifact.put", %{"id" => first["id"], "base" => 1, "title" => "Renamed"})

    assert kinds(retitled["blocked"]) == kinds(first["blocked"])
    assert row(context.ada, first["id"])["blocked_count"] == 3

    # A script added beside it that fetches another site; the page is carried as it was.
    {:ok, added} =
      call(context.ada, "artifact.put", %{
        "id" => first["id"],
        "base" => 2,
        "files" => [
          file("app.js", ~s{fetch("https://api.example.test/items")}, "text/javascript")
        ]
      })

    assert %{
             "file" => "app.js",
             "kind" => "connect",
             "reference" => "https://api.example.test/items"
           } in Enum.map(
             added["blocked"],
             &Map.take(&1, ~w(file kind reference))
           )

    assert added["blocked_count"] == 4

    # The page corrected: none left.
    {:ok, fixed} =
      call(context.ada, "artifact.put", %{
        "id" => first["id"],
        "files" => [
          file("index.html", @clean, "text/html"),
          file("app.js", "go()", "text/javascript")
        ]
      })

    assert fixed["blocked"] == []
    assert row(context.ada, first["id"])["blocked_count"] == 0

    # A pin of the first version shows its count again, and a rollback brings its list back.
    {:ok, pinned} = call(context.ada, "artifact.pin", %{"id" => first["id"], "version" => 1})
    assert pinned["blocked_count"] == 3
    {:ok, _unpinned} = call(context.ada, "artifact.pin", %{"id" => first["id"], "version" => nil})

    {:ok, back} = call(context.ada, "artifact.rollback", %{"id" => first["id"], "version" => 1})
    assert kinds(back["blocked"]) == kinds(first["blocked"])
    assert back["blocked_count"] == 3
  end

  test "a Markdown document with an image from another site publishes with it named as a page's is",
       context do
    markdown = """
    # Q3

    ![Chart](https://cdn.example.test/q3.png) beside ![ours](q3-local.png)
    """

    {:ok, doc} =
      publish(context.ada, [file("index.md", markdown, "text/markdown")], %{"kind" => "markdown"})

    {:ok, page} =
      publish(context.ada, [
        file("index.html", ~s(<img src="https://cdn.example.test/q3.png">), "text/html")
      ])

    assert [found] = doc["blocked"]

    assert found == %{
             "file" => "index.md",
             "kind" => "image",
             "reference" => "https://cdn.example.test/q3.png",
             "line" => 3
           }

    assert Map.take(found, ~w(kind reference)) ==
             Map.take(hd(page["blocked"]), ~w(kind reference))

    assert doc["blocked_count"] == 1
    assert row(context.ada, doc["id"])["blocked_count"] == 1

    # A retitle carries the document and what was found in it.
    {:ok, retitled} =
      call(context.ada, "artifact.put", %{"id" => doc["id"], "base" => 1, "title" => "Q3 notes"})

    assert retitled["blocked"] == doc["blocked"]
  end

  test "a Markdown file beside a page is served as it is, so it is not read", context do
    {:ok, page} =
      publish(context.ada, [
        file("index.html", @clean, "text/html"),
        file("notes.md", "![x](https://cdn.example.test/x.png)", "text/markdown")
      ])

    assert page["blocked"] == []
  end
end
