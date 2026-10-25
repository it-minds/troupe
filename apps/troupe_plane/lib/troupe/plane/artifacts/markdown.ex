defmodule Troupe.Plane.Artifacts.Markdown do
  @moduledoc """
  A Markdown artifact as the page the artifacts host serves (#62): rendered here, on the
  server, so the page needs no script of anybody's to be read.

  The Markdown people and agents write: headings, paragraphs, emphasis, code spans, links
  and images, lists (nested by indentation, with task boxes), quotes, rules, GitHub's
  tables, and fenced code, which is highlighted here as spans the page's stylesheet colours.
  A `mermaid` fence is drawn as a static SVG where it is a flowchart
  (`Troupe.Plane.Artifacts.Mermaid`) and shown as its source otherwise.

  **Nothing in the text becomes markup it did not ask for.** Raw HTML is shown as text,
  every character that means something in HTML is escaped before anything is made of it,
  and a link or an image goes only to the web, to mail, or within the artifact: a
  `javascript:` or `data:` address is shown as text. The page is served under the artifacts
  host's sandbox besides, which is what holds if this ever lets something through.
  """

  alias Troupe.Plane.Artifacts.{Highlight, Mermaid}

  @doc "The whole page for `text`, titled `title`."
  @spec page(String.t(), String.t()) :: String.t()
  def page(text, title) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{escape(title)}</title>
    <link rel="stylesheet" href="/_/document.css">
    </head>
    <body>
    <main class="document">
    #{render(text)}
    </main>
    </body>
    </html>
    """
  end

  @doc "The HTML for `text`'s blocks."
  @spec render(String.t()) :: String.t()
  def render(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\t", "    ")
    |> String.split("\n")
    |> blocks([])
    |> Enum.join("\n")
  end

  # -- blocks ---------------------------------------------------------------------

  defp blocks([], acc), do: Enum.reverse(acc)

  defp blocks([line | rest] = lines, acc) do
    if blank?(line) do
      blocks(rest, acc)
    else
      readers = [&fenced/1, &heading/1, &rule/1, &quoted/1, &listed/1, &tabled/1]
      {html, rest} = Enum.find_value(readers, & &1.(lines)) || paragraph(lines)
      blocks(rest, [html | acc])
    end
  end

  # Each block a reader of its own: the block's HTML and the lines after it, or `nil` where
  # the lines do not start one. A paragraph is what none of them takes.
  defp fenced([line | rest]) do
    with %{} = fence <- fence(line) do
      {body, rest} = until_fence(rest, fence, [])
      {code_block(body, fence.lang), rest}
    end
  end

  defp heading([line | rest]) do
    with [_, hashes, heading] <- Regex.run(~r/\A {0,3}(\#{1,6})\s+(.*?)\s*#*\s*\z/, line) do
      level = String.length(hashes)
      {"<h#{level} id=\"#{slug(heading)}\">#{inline(heading)}</h#{level}>", rest}
    end
  end

  defp rule([line | rest]) do
    if line =~ ~r/\A {0,3}([-*_])(\s*\1){2,}\s*\z/, do: {"<hr>", rest}
  end

  defp quoted([line | _] = lines) do
    if line =~ ~r/\A {0,3}>/ do
      {quoted, rest} = Enum.split_while(lines, &(&1 =~ ~r/\A {0,3}>/))
      inner = Enum.map(quoted, &Regex.replace(~r/\A {0,3}> ?/, &1, ""))
      {"<blockquote>\n#{render(Enum.join(inner, "\n"))}\n</blockquote>", rest}
    end
  end

  defp listed([line | _] = lines), do: if(list_marker(line), do: list(lines))
  defp tabled(lines), do: if(table?(lines), do: table(lines))

  defp paragraph([line | more] = lines) do
    {paragraph, rest} =
      case Enum.split_while(lines, &paragraph_line?/1) do
        {[], _rest} -> {[line], more}
        split -> split
      end

    {"<p>#{paragraph |> Enum.map_join("\n", &String.trim/1) |> inline()}</p>", rest}
  end

  defp blank?(line), do: String.trim(line) == ""

  defp paragraph_line?(line) do
    not blank?(line) and is_nil(fence(line)) and not (line =~ ~r/\A {0,3}(\#{1,6}\s|>)/) and
      is_nil(list_marker(line)) and not (line =~ ~r/\A {0,3}([-*_])(\s*\1){2,}\s*\z/)
  end

  defp fence(line) do
    case Regex.run(~r/\A( {0,3})(`{3,}|~{3,})\s*([\w+#.-]*)/, line) do
      [_, indent, marks, lang] ->
        %{marks: marks, indent: String.length(indent), lang: String.downcase(lang)}

      nil ->
        nil
    end
  end

  defp until_fence([], _fence, acc), do: {Enum.reverse(acc), []}

  defp until_fence([line | rest], fence, acc) do
    if String.trim(line) |> String.starts_with?(fence.marks) and
         String.trim(line) |> String.trim(String.at(fence.marks, 0)) == "",
       do: {Enum.reverse(acc), rest},
       else: until_fence(rest, fence, [strip_indent(line, fence.indent) | acc])
  end

  defp strip_indent(line, 0), do: line
  defp strip_indent(line, n), do: Regex.replace(~r/\A {0,#{n}}/, line, "")

  defp code_block(lines, "mermaid") do
    source = Enum.join(lines, "\n")

    case Mermaid.render(source) do
      {:ok, svg} ->
        "<figure class=\"diagram\">#{svg}</figure>"

      :unsupported ->
        "<figure class=\"diagram source\"><figcaption>A Mermaid diagram this page shows as its source: only flowcharts are drawn here.</figcaption>" <>
          "<pre><code class=\"language-mermaid\">#{escape(source)}</code></pre></figure>"
    end
  end

  defp code_block(lines, lang) do
    class = if lang == "", do: "", else: " class=\"language-#{escape(lang)}\""
    "<pre><code#{class}>#{Highlight.render(Enum.join(lines, "\n"), lang)}</code></pre>"
  end

  # -- lists ------------------------------------------------------------------------

  defp list_marker(line) do
    case Regex.run(~r/\A( *)([-*+]|\d{1,9}[.)])\s+(.*)\z/, line) do
      [_, indent, marker, text] ->
        %{
          indent: String.length(indent),
          ordered: marker =~ ~r/\d/,
          start: start(marker),
          text: text
        }

      nil ->
        nil
    end
  end

  defp start(marker) do
    case Integer.parse(marker) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp list([first | _] = lines) do
    marker = list_marker(first)
    {items, rest} = items(lines, marker, [])
    tag = if marker.ordered, do: "ol", else: "ul"
    start = if marker.ordered and marker.start != 1, do: " start=\"#{marker.start}\"", else: ""
    {"<#{tag}#{start}>\n#{Enum.join(items, "\n")}\n</#{tag}>", rest}
  end

  # One item: its marker's line, and every line after it indented past the marker or blank
  # between such lines, rendered again as the item's own blocks.
  defp items([line | rest] = lines, marker, acc) do
    case list_marker(line) do
      %{indent: indent, ordered: ordered} = this
      when indent <= marker.indent + 1 and ordered == marker.ordered ->
        {body, rest} = item_body(rest, indent, [])
        items(rest, marker, [item([this.text | body]) | acc])

      _other ->
        {Enum.reverse(acc), lines}
    end
  end

  defp items([], _marker, acc), do: {Enum.reverse(acc), []}

  defp item_body([line | rest] = lines, indent, acc) do
    cond do
      blank?(line) ->
        blank_in_item(rest, indent, acc)

      leading(line) > indent ->
        item_body(rest, indent, [
          String.slice(line, min(leading(line), indent + 2), String.length(line)) | acc
        ])

      true ->
        {Enum.reverse(acc), lines}
    end
  end

  defp item_body([], _indent, acc), do: {Enum.reverse(acc), []}

  # A blank line stays in the item only where the line after it is indented into it too.
  defp blank_in_item([next | _] = rest, indent, acc) do
    if leading(next) > indent,
      do: item_body(rest, indent, ["" | acc]),
      else: {Enum.reverse(acc), rest}
  end

  defp blank_in_item([], _indent, acc), do: {Enum.reverse(acc), []}

  defp leading(line), do: String.length(line) - String.length(String.trim_leading(line, " "))

  defp item([first | more]) do
    {box, first} =
      case Regex.run(~r/\A\[([ xX])\]\s+(.*)\z/, first) do
        [_, mark, text] ->
          checked = if mark == " ", do: "", else: " checked"
          {"<input type=\"checkbox\" disabled#{checked}> ", text}

        nil ->
          {"", first}
      end

    case Enum.drop_while(more, &blank?/1) do
      [] -> "<li>#{box}#{inline(first)}</li>"
      _nested -> "<li>#{box}#{inline(first)}\n#{render(Enum.join(more, "\n"))}</li>"
    end
  end

  # -- tables -------------------------------------------------------------------------

  defp table?([head, rule | _]),
    do:
      String.contains?(head, "|") and
        rule =~ ~r/\A\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*\z/

  defp table?(_lines), do: false

  defp table([head, rule | rest]) do
    {rows, rest} = Enum.split_while(rest, &(String.contains?(&1, "|") and not blank?(&1)))
    aligns = rule |> cells() |> Enum.map(&align/1)

    header =
      head
      |> cells()
      |> Enum.with_index()
      |> Enum.map_join("", fn {cell, i} -> "<th#{Enum.at(aligns, i, "")}>#{inline(cell)}</th>" end)

    body =
      Enum.map_join(rows, "\n", fn row ->
        cells =
          row
          |> cells()
          |> Enum.with_index()
          |> Enum.map_join("", fn {cell, i} ->
            "<td#{Enum.at(aligns, i, "")}>#{inline(cell)}</td>"
          end)

        "<tr>#{cells}</tr>"
      end)

    {"<table>\n<thead><tr>#{header}</tr></thead>\n<tbody>\n#{body}\n</tbody>\n</table>", rest}
  end

  defp cells(row) do
    row
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split(~r/(?<!\\)\|/)
    |> Enum.map(&(&1 |> String.replace("\\|", "|") |> String.trim()))
  end

  defp align(cell) do
    case {String.starts_with?(cell, ":"), String.ends_with?(cell, ":")} do
      {true, true} -> " style=\"text-align:center\""
      {false, true} -> " style=\"text-align:right\""
      _left -> ""
    end
  end

  # -- inline -------------------------------------------------------------------------

  @doc false
  @spec inline(String.t()) :: String.t()
  def inline(text) do
    {text, held} = hold(text, [])

    text
    |> escape()
    |> emphasis()
    |> restore(held)
  end

  # Code spans, images, links and autolinks first, kept aside as finished markup under a
  # placeholder, so neither emphasis nor escaping reaches inside them.
  defp hold(text, held) do
    patterns = [
      {~r/(`+)(.+?)\1/s, fn [_, _, code] -> "<code>#{escape(String.trim(code))}</code>" end},
      {~r/!\[([^\]]*)\]\(\s*([^)\s]+)(?:\s+"([^"]*)")?\s*\)/,
       fn [_, alt, src | title] -> image(alt, src, List.first(title)) end},
      {~r/\[([^\]]+)\]\(\s*([^)\s]+)(?:\s+"([^"]*)")?\s*\)/,
       fn [_, label, href | title] -> link(label, href, List.first(title)) end},
      {~r/<((?:https?:\/\/|mailto:)[^>\s]+)>/, fn [_, href] -> link(href, href, nil) end}
    ]

    Enum.reduce(patterns, {text, held}, fn {pattern, make}, {text, held} ->
      pattern
      |> Regex.split(text, include_captures: true)
      |> Enum.reduce({"", held}, &hold_part(&1, &2, pattern, make))
    end)
  end

  defp hold_part(part, {out, held}, pattern, make) do
    case Regex.run(pattern, part) do
      [^part | _] = match -> {out <> placeholder(length(held)), held ++ [make.(match)]}
      _text -> {out <> part, held}
    end
  end

  defp placeholder(n), do: "\u0000#{n}\u0000"

  defp restore(text, held) do
    Regex.replace(~r/\x{0}(\d+)\x{0}/u, text, fn _, n -> Enum.at(held, String.to_integer(n)) end)
  end

  defp emphasis(text) do
    text
    |> then(&Regex.replace(~r/\*\*(?=\S)(.+?)(?<=\S)\*\*/s, &1, "<strong>\\1</strong>"))
    |> then(
      &Regex.replace(~r/(?<![\w])__(?=\S)(.+?)(?<=\S)__(?![\w])/s, &1, "<strong>\\1</strong>")
    )
    |> then(&Regex.replace(~r/(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])/s, &1, "<em>\\1</em>"))
    |> then(&Regex.replace(~r/(?<![\w])_(?=\S)(.+?)(?<=\S)_(?![\w])/s, &1, "<em>\\1</em>"))
    |> then(&Regex.replace(~r/~~(?=\S)(.+?)(?<=\S)~~/s, &1, "<del>\\1</del>"))
  end

  defp link(label, href, title) do
    case safe_href(href) do
      {:ok, href} ->
        title = if title, do: " title=\"#{escape(title)}\"", else: ""
        "<a href=\"#{escape(href)}\"#{title}>#{label |> escape() |> emphasis()}</a>"

      :error ->
        escape("[#{label}](#{href})")
    end
  end

  defp image(alt, src, title) do
    case safe_href(src) do
      {:ok, src} ->
        title = if title, do: " title=\"#{escape(title)}\"", else: ""
        "<img src=\"#{escape(src)}\" alt=\"#{escape(alt)}\"#{title}>"

      :error ->
        escape("![#{alt}](#{src})")
    end
  end

  @doc """
  An address a link or an image may have: the web's, mail's, or one within the artifact (a
  path or a fragment). Anything else, `javascript:` and `data:` among them, is refused.
  """
  @spec safe_href(String.t()) :: {:ok, String.t()} | :error
  def safe_href(href) do
    scheme = Regex.run(~r/\A([A-Za-z][A-Za-z0-9+.-]*):/, href)

    case scheme do
      nil ->
        {:ok, href}

      [_, scheme] ->
        if String.downcase(scheme) in ~w(http https mailto), do: {:ok, href}, else: :error
    end
  end

  # -- plumbing ---------------------------------------------------------------------

  @doc "Text as HTML shows it, every character that could mean markup escaped."
  @spec escape(String.t()) :: String.t()
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp slug(heading) do
    heading
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/u, "")
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
    |> escape()
  end
end
