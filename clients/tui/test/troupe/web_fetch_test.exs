defmodule Troupe.WebFetchTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Tool.Context
  alias Troupe.Tools.WebFetch

  @html """
  <!doctype html>
  <html>
    <head><title>Docs</title><style>body { color: red }</style></head>
    <body>
      <script>window.analytics = 1</script>
      <h1>Rate limits</h1>
      <p>Requests are capped at 100&nbsp;per&nbsp;minute &amp; then rejected.</p>
      <ul>
        <li>Read the <a href="/guide/retries">retry guide</a>.</li>
        <li>See <a href="https://example.com/status">status</a>.</li>
      </ul>
    </body>
  </html>
  """

  defp ctx, do: %Context{workspace: File.cwd!()}

  defp serve(handler) do
    {pid, base} = Troupe.TestHTTP.start(handler)
    on_exit(fn -> Process.exit(pid, :kill) end)
    base
  end

  test "fetches an HTML page as readable text with links and without scripts or styles" do
    base = serve(fn "/docs" -> {200, "text/html; charset=utf-8", @html} end)

    assert {:ok, out} = WebFetch.run(%{"url" => base <> "/docs"}, ctx())

    assert out =~ "GET #{base}/docs → 200 text/html"
    assert out =~ "# Rate limits"
    assert out =~ "Requests are capped at 100 per minute & then rejected."
    assert out =~ "- Read the retry guide (#{base}/guide/retries)."
    assert out =~ "- See status (https://example.com/status)."
    refute out =~ "window.analytics"
    refute out =~ "color: red"
    refute out =~ "<p>"
  end

  test "returns JSON and plain text verbatim" do
    base =
      serve(fn
        "/api" -> {200, "application/json", ~s({"ok": true, "items": [1, 2]})}
        "/raw" -> {200, "text/plain", "line one\nline two"}
      end)

    assert {:ok, json} = WebFetch.run(%{"url" => base <> "/api"}, ctx())
    assert json =~ ~s({"ok": true, "items": [1, 2]})
    assert {:ok, text} = WebFetch.run(%{"url" => base <> "/raw"}, ctx())
    assert text =~ "line one\nline two"
  end

  test "follows redirects" do
    base =
      serve(fn
        "/old" -> {:redirect, "/new"}
        "/new" -> {200, "text/plain", "arrived"}
      end)

    assert {:ok, out} = WebFetch.run(%{"url" => base <> "/old"}, ctx())
    assert out =~ "arrived"
  end

  test "a failure status is an error carrying the body as explanation" do
    base = serve(fn "/missing" -> {404, "text/plain", "no such page"} end)

    assert {:error, msg} = WebFetch.run(%{"url" => base <> "/missing"}, ctx())
    assert msg =~ "→ 404"
    assert msg =~ "no such page"
  end

  test "binary content is refused rather than dumped into the transcript" do
    base = serve(fn "/img" -> {200, "image/png", <<137, 80, 78, 71, 13, 10, 26, 10, 0, 1>>} end)

    assert {:error, msg} = WebFetch.run(%{"url" => base <> "/img"}, ctx())
    assert msg =~ "not text"
  end

  test "only absolute http(s) urls are accepted" do
    assert {:error, msg} = WebFetch.run(%{"url" => "file:///etc/passwd"}, ctx())
    assert msg =~ "only speaks http and https"
    assert {:error, msg} = WebFetch.run(%{"url" => "example.com/docs"}, ctx())
    assert msg =~ "must be absolute"
    assert {:error, "url is required"} = WebFetch.run(%{}, ctx())
  end

  test "a connection that goes nowhere is an error tool result, not a crash" do
    # port 1 on loopback: nothing listens, so this is a refused connection
    assert {:error, msg} = WebFetch.run(%{"url" => "http://127.0.0.1:1/"}, ctx())
    assert msg =~ "failed:"
  end

  describe "to_text/2" do
    test "decodes entities, keeps heading levels and collapses blank runs" do
      html = """
      <h2>A &amp; B</h2>


      <p>caf&#233; &#x2014; &quot;quoted&quot;</p>
      <div>one</div><div>two</div>
      """

      assert WebFetch.to_text(html) == "## A & B\n\ncafé — \"quoted\"\n\none\ntwo"
    end

    test "drops in-page and javascript hrefs but keeps the link text" do
      html = ~S|<a href="#top">top</a> <a href="javascript:void(0)">go</a>|
      assert WebFetch.to_text(html) == "top go"
    end

    test "a link whose text is already the url is not doubled" do
      html = ~S|<a href="https://example.com/x">https://example.com/x</a>|
      assert WebFetch.to_text(html) == "https://example.com/x"
    end

    test "unknown entities and stray angle brackets survive" do
      assert WebFetch.to_text("<p>a &notreal; b</p>") == "a &notreal; b"
    end
  end

  test "an agent can call web_fetch and gets the page back as a tool result" do
    base = serve(fn "/page" -> {200, "text/html", "<h1>Hello</h1><p>world</p>"} end)
    ws = tmp_workspace()

    scripts = %{
      "code-1" => [
        {:tool, "web_fetch", %{"url" => base <> "/page"}},
        {:finish, "read it"}
      ]
    }

    {sid, _, _} = start_session!(workspace: ws, scripts: scripts, auto_approve: true)
    {:ok, "code-1"} = Troupe.dispatch(sid, "code", "read that page")
    await_state("code-1", :done_unread)

    [call | _] = events_of(sid, "code-1", :tool_call_completed)
    assert call.data.ok
    assert call.data.content =~ "# Hello"
    assert call.data.content =~ "world"

    # the transcript line for the call is the URL, not the encoded arguments
    model = Troupe.UI.TUI.Model.rebuild(sid, ws, Troupe.events(sid))
    lines = Troupe.UI.TUI.Model.tile_lines(model.windows["code-1"], 0, 0, false)

    assert Enum.any?(lines, fn {_kind, segs} ->
             is_list(segs) and Enum.any?(segs, &(&1 == {:tool_arg, " " <> base <> "/page"}))
           end)
  end
end
