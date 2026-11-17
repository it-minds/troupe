defmodule Troupe.Plane.Artifacts.BlockedTest do
  @moduledoc """
  What the artifacts host will block in a published file (#1081), read from the host's own
  policy: each kind found where a page says it, nothing found in a page that loads only its
  own files, and every verdict the same as the header the host sends.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Artifacts.Blocked
  alias Troupe.Plane.Web.Artifacts.CSP

  defp kinds(findings), do: Enum.map(findings, &{&1["kind"], &1["reference"]})

  describe "an HTML page" do
    test "names each reference the host blocks, with its file and line" do
      page = """
      <!doctype html>
      <html><head>
        <link rel="stylesheet" href="https://cdn.example.test/lib.css">
        <link rel="preconnect" href="https://fonts.example.test">
        <script src="//cdn.example.test/lib.js"></script>
        <style>@import url("https://fonts.example.test/css"); body { background: url(https://img.example.test/bg.png) }</style>
      </head><body>
        <img src="https://img.example.test/a.png" srcset="small.png 1x, https://img.example.test/b.png 2x">
        <iframe src="https://video.example.test/embed"></iframe>
        <video src="https://media.example.test/a.mp4" poster="poster.png"></video>
        <button onclick="go()">Go</button>
        <a href="javascript:void(0)">nothing</a>
        <div style="background-image: url('https://img.example.test/c.png')"></div>
        <script>
          go();
        </script>
      </body></html>
      """

      found = Blocked.scan("index.html", "text/html; charset=utf-8", page)

      assert Enum.all?(found, &(&1["file"] == "index.html"))

      assert MapSet.new(kinds(found)) ==
               MapSet.new([
                 {"stylesheet", "https://cdn.example.test/lib.css"},
                 {"script", "//cdn.example.test/lib.js"},
                 {"stylesheet", "https://fonts.example.test/css"},
                 {"image", "https://img.example.test/bg.png"},
                 {"image", "https://img.example.test/a.png"},
                 {"image", "https://img.example.test/b.png"},
                 {"frame", "https://video.example.test/embed"},
                 {"media", "https://media.example.test/a.mp4"},
                 {"event_handler", ~s|onclick="go()"|},
                 {"inline_script", "javascript:void(0)"},
                 {"image", "https://img.example.test/c.png"},
                 {"inline_script", "<script> go();"}
               ])

      assert %{"line" => 3} =
               Enum.find(found, &(&1["reference"] == "https://cdn.example.test/lib.css"))

      assert %{"line" => 11} = Enum.find(found, &(&1["kind"] == "event_handler"))

      assert %{"line" => 14} =
               Enum.find(found, &(&1["kind"] == "inline_script" and &1["line"] > 12))
    end

    test "finds nothing in a page that loads only its own files" do
      page = """
      <html><head>
        <link rel="stylesheet" href="style.css">
        <link rel="icon" href="data:image/png;base64,iVBORw0KGgo=">
        <script src="app.js" defer></script>
        <script type="application/json" id="data">{"a": 1}</script>
        <style>body { font-family: x; background: url(img/bg.png) } @font-face { src: url(data:font/woff2;base64,AAAA) }</style>
      </head><body style="color: red">
        <!-- <script>commented()</script> <img src="https://img.example.test/x.png"> -->
        <img src="data:image/png;base64,iVBORw0KGgo=" alt="chart">
        <a href="https://example.test/elsewhere">a link out</a>
        <svg><rect fill="url(#gradient)"/></svg>
      </body></html>
      """

      assert Blocked.scan("index.html", "text/html", page) == []
    end

    test "does not read markup a script writes as the page's" do
      page =
        ~s(<script src="app.js"></script><script type="text/template"><img src="https://x.example.test/a.png"></script>)

      assert Blocked.scan("index.html", "text/html", page) == []
    end
  end

  describe "a stylesheet and a script" do
    test "a stylesheet's imports and fonts from another site" do
      css = """
      @import "https://fonts.example.test/css2?family=Inter";
      @font-face { src: url(https://fonts.example.test/inter.woff2) format("woff2"); }
      .logo { background: url("logo.svg") }
      """

      assert kinds(Blocked.scan("css/site.css", "text/css", css)) == [
               {"stylesheet", "https://fonts.example.test/css2?family=Inter"},
               {"font", "https://fonts.example.test/inter.woff2"}
             ]
    end

    test "a script's literal connections to another site, and not its own" do
      js = """
      fetch("data.json");
      fetch('https://api.example.test/v1/items');
      const socket = new WebSocket(`wss://live.example.test/feed`);
      const xhr = new XMLHttpRequest(); xhr.open("GET", "https://api.example.test/old");
      import("https://cdn.example.test/chart.mjs");
      """

      assert [
               %{
                 "kind" => "connect",
                 "reference" => "https://api.example.test/v1/items",
                 "line" => 2
               },
               %{"kind" => "connect", "reference" => "wss://live.example.test/feed", "line" => 3},
               %{"kind" => "connect", "reference" => "https://api.example.test/old", "line" => 4},
               %{
                 "kind" => "script",
                 "reference" => "https://cdn.example.test/chart.mjs",
                 "line" => 5
               }
             ] = Blocked.scan("app.js", "text/javascript", js)
    end

    test "other files are not read" do
      assert Blocked.scan("a.png", "image/png", "<script>x()</script>") == []
      assert Blocked.scan("notes.md", "text/markdown", "<script>x()</script>") == []
    end

    test "keeps the first 25 of a file" do
      page = String.duplicate(~s|<b onclick="x()">x</b>\n|, 40)
      found = Blocked.scan("index.html", "text/html", page)
      assert length(found) == 25
      assert hd(found)["line"] == 1
    end
  end

  describe "the rules are the host's policy" do
    # The header the host sends, read as a browser reads it: a fetch directive it does not
    # name falls back to default-src.
    defp header_sources(directive) do
      directives =
        nil
        |> CSP.policy()
        |> String.split(";")
        |> Map.new(fn part ->
          [name | sources] = String.split(part)
          {name, sources}
        end)

      Map.get(directives, directive) || Map.fetch!(directives, "default-src")
    end

    test "every kind found is one the header blocks, and what is let through the header allows" do
      for kind <- Blocked.kinds() do
        sources = header_sources(Blocked.directive(kind))
        assert CSP.sources(Blocked.directive(kind)) == sources

        if kind in ["inline_script", "event_handler"],
          do: refute("'unsafe-inline'" in sources),
          else:
            refute(
              Enum.any?(sources, &(&1 in ["*", "https:", "http:"])),
              "#{kind} from another site"
            )
      end

      # What the scan lets through: inline style and data: images and fonts.
      assert "'unsafe-inline'" in header_sources("style-src")
      assert "data:" in header_sources("img-src")
      assert "data:" in header_sources("font-src")
      refute "data:" in header_sources("media-src")
      assert "'none'" in header_sources("object-src")
    end

    test "an embedded object is blocked even from the artifact's own files" do
      assert [%{"kind" => "object"}] =
               Blocked.scan("index.html", "text/html", ~s(<embed src="chart.swf">))
    end
  end
end
