defmodule Troupe.Plane.Artifacts.Blocked do
  @moduledoc """
  What the artifacts host will block in a file of an artifact, read when the file is
  published (#1081), so the agent that published it is told while it can still publish a
  corrected version, and the person reading it is told why it looks broken.

  The rules are the host's own policy (`Web.Artifacts.CSP.sources/1`), never a second list:
  a stylesheet, script, image, font, frame, sound or film another site serves, an embedded
  object, an inline `<script>`, an inline event handler (`onclick=`), a `javascript:`
  address, and a connection a script names literally (`fetch`, `XMLHttpRequest`,
  `WebSocket`, `EventSource`, an `import`) to another site. A reference relative to the
  page is one of its own files; a `data:` one is whatever the policy says of `data:` for
  that kind (images and fonts, yes).

  A scan, not a browser: a tokenising pass over each HTML, CSS and JavaScript file, by its
  content type. It finds what a page says literally, never what a script builds at run time,
  and it says each finding's file, kind, reference and line. At most 25 findings a file
  are kept, the first ones in it.

  A Markdown document a Markdown artifact serves is the page the host renders from it, so
  it is read for what that page loads (`markdown/2`): an image from another site, which the
  page shows as a sentence in the image's place.
  """

  alias Troupe.Plane.Artifacts.Markdown
  alias Troupe.Plane.Web.Artifacts.CSP

  @max_per_file 25
  @max_reference 120
  # Past this, a file is read up to here: a page of several megabytes is rare, and what it
  # loads is near its top.
  @max_scanned 4 * 1024 * 1024

  # Each kind of finding and the directive of the host's policy that decides it.
  @directives %{
    "stylesheet" => "style-src",
    "script" => "script-src",
    "image" => "img-src",
    "font" => "font-src",
    "media" => "media-src",
    "frame" => "frame-src",
    "object" => "object-src",
    "connect" => "connect-src",
    "inline_script" => "script-src",
    "event_handler" => "script-src"
  }

  @fonts ~w(.woff2 .woff .ttf .otf .eot)

  @doc "The kinds a finding may be."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@directives)

  @doc "The directive of the host's policy that decides findings of `kind`."
  @spec directive(String.t()) :: String.t()
  def directive(kind), do: Map.fetch!(@directives, kind)

  @doc """
  What the host will block of the file at `path`, of `content_type`, with `body`: a list of
  `%{"file", "kind", "reference", "line"}`, empty for a file that loads only its own.
  """
  @spec scan(String.t(), String.t() | nil, binary()) :: [map()]
  def scan(path, content_type, body) when is_binary(body) do
    text = binary_part(body, 0, min(byte_size(body), @max_scanned))

    case read_as(content_type) do
      :html -> html(text)
      :css -> css(text, 0)
      :script -> script(text, 0)
      :none -> []
    end
    |> findings(path, text)
  end

  def scan(_path, _content_type, _body), do: []

  @doc """
  What the host will block of the Markdown document at `path` that a Markdown artifact
  serves rendered: each image from another site the page would show, found as the renderer
  finds them (`Markdown.images/1`), in the same shape as `scan/3`'s.
  """
  @spec markdown(String.t(), binary()) :: [map()]
  def markdown(path, body) when is_binary(body) do
    text = binary_part(body, 0, min(byte_size(body), @max_scanned))

    text
    |> Markdown.images()
    |> Enum.flat_map(fn {offset, address} -> reference({"image", address}, offset) end)
    |> findings(path, text)
  end

  def markdown(_path, _body), do: []

  @doc "Whether the host's policy blocks a page loading `address` as `kind`."
  @spec blocks?(String.t(), String.t()) :: boolean()
  def blocks?(kind, address), do: reference({kind, address}, 0) != []

  defp findings(found, path, text) do
    found
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@max_per_file)
    |> Enum.map(fn {offset, kind, reference} ->
      %{
        "file" => path,
        "kind" => kind,
        "reference" => shown(reference),
        "line" => line(text, offset)
      }
    end)
  end

  defp read_as(type) when is_binary(type) do
    case type |> String.split(";") |> hd() |> String.trim() |> String.downcase() do
      type when type in ["text/html", "application/xhtml+xml"] ->
        :html

      "text/css" ->
        :css

      type
      when type in ["text/javascript", "application/javascript", "application/x-javascript"] ->
        :script

      _other ->
        :none
    end
  end

  defp read_as(_type), do: :none

  # -- HTML ---------------------------------------------------------------------------

  @comment ~r/<!--.*?-->/s
  @script_block ~r/<script\b((?:[^>"']|"[^"]*"|'[^']*')*)>(.*?)<\/script\s*>/is
  @style_block ~r/<style\b(?:[^>"']|"[^"]*"|'[^']*')*>(.*?)<\/style\s*>/is
  @tag ~r/<([a-zA-Z][a-zA-Z0-9:-]*)(\s(?:[^>"']|"[^"]*"|'[^']*')*)?>/s
  @attribute ~r/([^\s=\/>"']+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+)))?/s

  defp html(text) do
    text =
      @comment
      |> Regex.scan(text, return: :index)
      |> Enum.reduce(text, fn [{at, length}], acc -> blank(acc, at, length) end)

    scripts = Regex.scan(@script_block, text, return: :index)
    styles = Regex.scan(@style_block, text, return: :index)

    in_scripts = Enum.flat_map(scripts, &script_block(text, &1))

    in_styles =
      Enum.flat_map(styles, fn [_whole, {at, length}] ->
        css(binary_part(text, at, length), at)
      end)

    # The tags, with what is inside a script or a style taken out, so markup a script writes
    # is not read as the page's.
    text =
      Enum.reduce(scripts ++ styles, text, fn match, acc ->
        {at, length} = List.last(match)
        blank(acc, at, length)
      end)

    in_tags =
      @tag
      |> Regex.scan(text, return: :index)
      |> Enum.flat_map(fn [{at, _}, name | attrs] ->
        attrs = Enum.map_join(attrs, &slice(text, &1))
        tag(String.downcase(slice(text, name)), attributes(attrs), at)
      end)

    in_scripts ++ in_styles ++ in_tags
  end

  defp script_block(text, [{at, _}, attrs, {body_at, body_length}]) do
    attrs = attributes(slice(text, attrs))
    body = binary_part(text, body_at, body_length)

    cond do
      Map.has_key?(attrs, "src") -> []
      not runs?(attrs["type"]) -> []
      String.trim(body) == "" -> []
      inline_allowed?("inline_script") -> script(body, body_at)
      true -> [{at, "inline_script", "<script>" <> body} | script(body, body_at)]
    end
  end

  # A `<script>` whose type is data (JSON, a template) is never run, so nothing blocks it.
  defp runs?(nil), do: true

  defp runs?(type),
    do:
      String.downcase(String.trim(type)) in ~w(text/javascript application/javascript module) or
        String.trim(type) == ""

  defp tag(name, attrs, at) do
    handlers =
      for {attribute, value} <- attrs,
          Regex.match?(~r/^on[a-z]+$/, attribute),
          not inline_allowed?("event_handler"),
          do: {at, "event_handler", ~s(#{attribute}="#{value}")}

    styles =
      if attrs["style"], do: Enum.map(css(attrs["style"], 0), &put_elem(&1, 0, at)), else: []

    scripted =
      for {attribute, value} <- attrs,
          attribute in ~w(href src action formaction data),
          javascript?(value),
          not inline_allowed?("inline_script"),
          do: {at, "inline_script", value}

    loads = name |> loads(attrs) |> Enum.flat_map(&reference(&1, at))

    handlers ++ styles ++ scripted ++ loads
  end

  # What a tag loads: `{kind, address}`, from its name and attributes.
  defp loads("link", attrs) do
    rel = attrs |> Map.get("rel", "") |> String.downcase() |> String.split()

    kind =
      cond do
        "stylesheet" in rel -> "stylesheet"
        "icon" in rel or "apple-touch-icon" in rel -> "image"
        "modulepreload" in rel -> "script"
        "preload" in rel -> preloaded(attrs["as"])
        true -> nil
      end

    if kind, do: [{kind, attrs["href"]}], else: []
  end

  defp loads("script", attrs), do: [{"script", attrs["src"]}]
  defp loads("img", attrs), do: [{"image", attrs["src"]} | srcset(attrs["srcset"])]
  defp loads("image", attrs), do: [{"image", attrs["href"] || attrs["xlink:href"]}]
  defp loads("source", attrs), do: [{"media", attrs["src"]} | srcset(attrs["srcset"])]
  defp loads("video", attrs), do: [{"media", attrs["src"]}, {"image", attrs["poster"]}]
  defp loads(name, attrs) when name in ~w(audio track), do: [{"media", attrs["src"]}]
  defp loads(name, attrs) when name in ~w(iframe frame), do: [{"frame", attrs["src"]}]
  defp loads("embed", attrs), do: [{"object", attrs["src"]}]
  defp loads("object", attrs), do: [{"object", attrs["data"]}]
  defp loads(_name, _attrs), do: []

  defp preloaded(as) do
    case as && String.downcase(as) do
      "style" -> "stylesheet"
      "script" -> "script"
      "font" -> "font"
      "image" -> "image"
      _other -> nil
    end
  end

  defp srcset(nil), do: []

  defp srcset(set) do
    set
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.split() |> List.first()))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{"image", &1})
  end

  defp reference({_kind, nil}, _at), do: []

  defp reference({kind, address}, at) do
    address = String.trim(address)

    cond do
      address == "" -> []
      javascript?(address) -> []
      allowed?(kind, address) -> []
      true -> [{at, kind, address}]
    end
  end

  # -- CSS ----------------------------------------------------------------------------

  @import ~r/@import\s+(?:url\(\s*)?(?:"([^"]*)"|'([^']*)'|([^"'\s;)]+))/i
  @url ~r/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)"']*))\s*\)/i

  defp css(text, offset) do
    imports = Regex.scan(@import, text, return: :index)
    spans = Enum.map(imports, fn [{at, length} | _] -> at..(at + length) end)

    imported =
      Enum.flat_map(imports, fn [{at, _} | groups] ->
        reference({"stylesheet", first(text, groups)}, offset + at)
      end)

    urls =
      @url
      |> Regex.scan(text, return: :index)
      |> Enum.reject(fn [{at, _} | _] -> Enum.any?(spans, &(at in &1)) end)
      |> Enum.flat_map(fn [{at, _} | groups] ->
        address = first(text, groups)
        reference({if(font?(address), do: "font", else: "image"), address}, offset + at)
      end)

    imported ++ urls
  end

  defp font?(nil), do: false

  defp font?(address) do
    address
    |> String.split(["?", "#"])
    |> hd()
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @fonts))
  end

  # -- JavaScript ---------------------------------------------------------------------

  @quoted ~S<(["'`])((?:https?:|wss?:)?//[^"'`]*)>
  @connections [
    {"connect", Regex.compile!(~S<\bfetch\s*\(\s*> <> @quoted)},
    {"connect", Regex.compile!(~S<\bnew\s+(?:WebSocket|EventSource)\s*\(\s*> <> @quoted)},
    {"connect", Regex.compile!(~S<\.open\s*\(\s*["'][A-Za-z]+["']\s*,\s*> <> @quoted)},
    {"script", Regex.compile!(~S<\bimport\s*(?:\(\s*|[\w*{}\s,$]+\s+from\s*)> <> @quoted)}
  ]

  defp script(text, offset) do
    Enum.flat_map(@connections, fn {kind, pattern} ->
      pattern
      |> Regex.scan(text, return: :index)
      |> Enum.flat_map(fn [{at, _}, _quote, address] ->
        reference({kind, slice(text, address)}, offset + at)
      end)
    end)
  end

  # -- the policy ---------------------------------------------------------------------

  # Whether the host's policy lets a page load `address` as `kind`: a reference with no
  # scheme and no host is the artifact's own file, `'self'`; one with a scheme is allowed
  # only where the directive names that scheme.
  defp allowed?(kind, address) do
    sources = CSP.sources(directive(kind))

    case scheme(address) do
      nil -> "'self'" in sources
      scheme -> "#{scheme}:" in sources or (scheme in ~w(http https ws wss) and "*" in sources)
    end
  end

  defp scheme("//" <> _), do: "https"

  defp scheme(address) do
    case Regex.run(~r/^([a-zA-Z][a-zA-Z0-9+.-]*):/, address) do
      [_, scheme] -> String.downcase(scheme)
      nil -> nil
    end
  end

  defp inline_allowed?(kind), do: "'unsafe-inline'" in CSP.sources(directive(kind))

  defp javascript?(value),
    do: value |> String.trim() |> String.downcase() |> String.starts_with?("javascript:")

  # -- plumbing -----------------------------------------------------------------------

  defp attributes(text) do
    @attribute
    |> Regex.scan(text, capture: :all_but_first)
    |> Map.new(fn
      [name | values] -> {String.downcase(name), Enum.find(values, "", &(&1 != ""))}
    end)
  end

  defp first(text, groups) do
    Enum.find_value(groups, fn
      {at, length} when at >= 0 and length > 0 -> binary_part(text, at, length)
      _empty -> nil
    end)
  end

  defp slice(_text, {-1, _}), do: ""
  defp slice(text, {at, length}), do: binary_part(text, at, length)

  # The bytes from `at` for `length`, spaces but for line ends, so offsets and lines hold.
  defp blank(text, at, length) do
    inside =
      for <<byte <- binary_part(text, at, length)>>,
        into: "",
        do: if(byte == ?\n, do: "\n", else: " ")

    binary_part(text, 0, at) <>
      inside <> binary_part(text, at + length, byte_size(text) - at - length)
  end

  defp line(text, offset), do: 1 + length(:binary.matches(binary_part(text, 0, offset), "\n"))

  defp shown(reference) do
    reference = reference |> String.replace_invalid() |> String.split() |> Enum.join(" ")

    if String.length(reference) > @max_reference,
      do: String.slice(reference, 0, @max_reference - 1) <> "…",
      else: reference
  end
end
