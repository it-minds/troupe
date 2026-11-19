defmodule Troupe.Plane.Artifacts.MarkdownTest do
  @moduledoc """
  The page a Markdown artifact is rendered as, where an image is concerned (#1091): one from
  another site, which the artifacts host's policy blocks, is a sentence naming the site in
  its place; one of the artifact's own is an image; a `data:` one and raw HTML stay text.
  """

  use ExUnit.Case, async: true

  alias Troupe.Plane.Artifacts.Markdown

  @sentence "is not shown: this page shows only its own files"

  test "an image from another site is a sentence naming its site, never its address" do
    html = Markdown.render(~s|See ![Q3 chart](https://cdn.example.test/charts/q3.png?key=abc "Q3").|)

    assert html =~
             ~s(<span class="not-shown" title="Q3 chart">An image from cdn.example.test #{@sentence}</span>)

    refute html =~ "<img"
    refute html =~ "charts/q3.png"
    refute html =~ "key=abc"
  end

  test "a protocol-relative image is another site's too" do
    html = Markdown.render("![](//img.example.test/x.png)")
    assert html =~ ~s(<span class="not-shown">An image from img.example.test #{@sentence}</span>)
    refute html =~ "<img"
  end

  test "an image of the artifact's own is an image, and a data: one stays text as before" do
    html = Markdown.render("![own](img/chart.png) ![inline](data:image/png;base64,iVBORw0KGgo=)")

    assert html =~ ~s(<img src="img/chart.png" alt="own">)
    assert html =~ "![inline](data:image/png;base64,iVBORw0KGgo=)"
    refute html =~ "not-shown"
  end

  test "a raw <img> is shown as text, as all raw HTML is, and loads nothing" do
    html = Markdown.render(~s(<img src="https://cdn.example.test/raw.png">))
    assert html =~ "&lt;img src=&quot;https://cdn.example.test/raw.png&quot;&gt;"
    refute html =~ "<img"
    refute html =~ "not-shown"
  end

  test "an image in a code span or a fence is code" do
    html = Markdown.render("`![a](https://cdn.example.test/a.png)`\n\n```\n![b](https://cdn.example.test/b.png)\n```\n")
    refute html =~ "not-shown"
    assert html =~ "<code>![a](https://cdn.example.test/a.png)</code>"
  end

  test "images/1 finds what the renderer makes an image of, where it is in the text" do
    text = "x ![a](https://cdn.example.test/a.png)\n![b](b.png) `![c](c.png)`"

    assert Markdown.images(text) == [{2, "https://cdn.example.test/a.png"}, {39, "b.png"}]
  end
end
