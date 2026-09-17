defmodule Troupe.Tools.WebFetch do
  @moduledoc false
  @behaviour Troupe.Tool

  alias Troupe.Session.Outputs
  alias Troupe.Tool.{Bound, Context}

  # How many elements of a JSON array survive; the rest are replaced by a count,
  # so a long list is trimmed at its own boundaries rather than mid-structure.
  @json_items 50
  # What is read off the socket before the connection is dropped. Well above the
  # output cap, because the markup around the text is most of an HTML page.
  @download_cap 5_000_000
  @timeout_ms 30_000
  @redirects 5

  @impl true
  def name, do: "web_fetch"

  @impl true
  def description,
    do:
      "Fetch a URL over HTTP(S) and return its content as text. HTML comes back as readable text with the markup, scripts and styles removed and links kept as `text (url)`; JSON, Markdown, XML and plain text come back verbatim. GET only; long content is truncated and the marker names the `read_output` call that returns the rest."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "Absolute http:// or https:// URL"
        }
      },
      "required" => ["url"]
    }
  end

  # Reaching the network is outside the workspace and pulls text the user has not
  # seen into the agent's context, so the user sees the URL before it is fetched.
  @impl true
  def default_permission, do: :ask

  @impl true
  def preview(%{"url" => url}, _ctx), do: "GET #{url}"
  def preview(args, _ctx), do: Jason.encode!(args, pretty: true)

  @impl true
  def run(%{"url" => url}, ctx) when is_binary(url) do
    with {:ok, uri} <- validate(url) do
      uri |> get() |> render(uri, ctx)
    end
  end

  def run(_, _), do: {:error, "url is required"}

  defp validate(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: s, host: h} = uri when s in ["http", "https"] and is_binary(h) and h != "" ->
        {:ok, uri}

      %URI{scheme: nil} ->
        {:error, "url must be absolute and start with http:// or https://: #{url}"}

      %URI{scheme: s} ->
        {:error, "web_fetch only speaks http and https, not #{s}: #{url}"}
    end
  end

  defp get(uri) do
    # `compressed: false` because the collector below sees the bytes before Req's
    # decompression step: capping a gzip stream would leave an undecodable tail.
    Req.get(URI.to_string(uri),
      headers: [
        {"user-agent", user_agent()},
        {"accept", "text/html,text/plain,application/json;q=0.9,*/*;q=0.5"}
      ],
      compressed: false,
      decode_body: false,
      max_redirects: @redirects,
      receive_timeout: @timeout_ms,
      retry: false,
      into: &collect/2
    )
  end

  defp collect({:data, chunk}, {req, resp}) do
    body = (resp.private[:troupe_body] || "") <> chunk
    resp = Req.Response.put_private(resp, :troupe_body, body)
    if byte_size(body) >= @download_cap, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}
  end

  defp render({:ok, %Req.Response{status: status} = resp}, uri, ctx) when status in 200..299 do
    body = body(resp)
    type = content_type(resp)

    case text(body, type, uri) do
      {:ok, text} ->
        {:ok, "GET #{uri} → #{status} #{type}\n\n" <> bound(String.trim(text), type, ctx)}

      {:error, reason} ->
        {:error, "GET #{uri} → #{status} #{type}: #{reason}"}
    end
  end

  defp render({:ok, %Req.Response{status: status} = resp}, uri, _ctx) do
    # The body of a failure is usually the API's explanation of it; a short excerpt
    # tells the model whether to fix the request or give up.
    excerpt =
      case text(body(resp), content_type(resp), uri) do
        {:ok, text} -> text |> String.trim() |> String.slice(0, 500)
        {:error, _} -> ""
      end

    {:error, String.trim("GET #{uri} → #{status}\n\n#{excerpt}")}
  end

  defp render({:error, %{reason: reason}}, uri, _ctx),
    do: {:error, "GET #{uri} failed: #{inspect(reason)}"}

  defp render({:error, reason}, uri, _ctx), do: {:error, "GET #{uri} failed: #{inspect(reason)}"}

  defp body(%Req.Response{} = resp), do: resp.private[:troupe_body] || ""

  defp content_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _] -> type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> ""
    end
  end

  defp text(body, type, uri) do
    cond do
      not String.valid?(body) ->
        {:error, "the response is not text (#{byte_size(body)} bytes)"}

      type in ["text/html", "application/xhtml+xml"] ->
        {:ok, to_text(body, uri)}

      String.starts_with?(type, "text/") or String.ends_with?(type, "json") or
        String.ends_with?(type, "xml") or type in ["application/javascript", ""] ->
        {:ok, body}

      true ->
        {:error, "unsupported content type #{type}; web_fetch returns text"}
    end
  end

  @doc """
  Reduces an HTML document to readable text: script, style and other non-content
  blocks are dropped whole, block tags become line breaks, headings keep their
  `#` markers, list items a `-`, and a link becomes `text (url)` with relative
  hrefs resolved against `base`. Entities are decoded and blank runs collapsed.
  """
  @spec to_text(String.t(), URI.t() | String.t()) :: String.t()
  def to_text(html, base \\ "") do
    base = if is_binary(base), do: URI.parse(base), else: base

    html
    |> String.replace(~r{<(script|style|noscript|svg|template|head)\b[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r{<!--.*?-->}s, " ")
    |> String.replace(~r{<[!?][^>]*>}s, " ")
    |> links(base)
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{<li\b[^>]*>}i, "\n- ")
    |> headings()
    |> String.replace(~r{</(p|div|section|article|tr|ul|ol|li|pre|blockquote|table)>}i, "\n")
    |> String.replace(~r{<(hr)\s*/?>}i, "\n\n")
    |> String.replace(~r{</?[a-z][^>]*>}is, "")
    |> unescape()
    |> collapse()
  end

  # `text (url)`, and a link whose text is already the URL stays as it is.
  defp links(html, base) do
    Regex.replace(~r{<a\b[^>]*\bhref=["']([^"']+)["'][^>]*>(.*?)</a>}is, html, fn _, href, inner ->
      text = inner |> String.replace(~r{</?[a-z][^>]*>}is, "") |> unescape() |> collapse()
      url = absolute(href, base)

      cond do
        text == "" or url == "" -> text
        text == url -> text
        true -> "#{text} (#{url})"
      end
    end)
  end

  defp absolute(href, base) do
    href = href |> String.trim() |> unescape()

    cond do
      String.starts_with?(href, ["http://", "https://"]) -> href
      String.starts_with?(href, ["#", "javascript:", "mailto:", "data:"]) -> ""
      base.host in [nil, ""] -> ""
      true -> base |> URI.merge(href) |> URI.to_string()
    end
  rescue
    # A href that is not a URL at all is not worth failing the whole fetch over.
    _ -> ""
  end

  defp headings(html) do
    Regex.replace(~r{<h([1-6])\b[^>]*>(.*?)</h\1>}is, html, fn _, level, inner ->
      "\n\n" <> String.duplicate("#", String.to_integer(level)) <> " " <> inner <> "\n"
    end)
  end

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "rsquo" => "’",
    "lsquo" => "‘",
    "rdquo" => "”",
    "ldquo" => "“"
  }

  defp unescape(text) do
    Regex.replace(~r/&(#x?[0-9a-f]+|[a-z]+);/i, text, fn whole, name ->
      case entity(String.downcase(name)) do
        nil -> whole
        replacement -> replacement
      end
    end)
  end

  defp entity("#x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> codepoint(n)
      _ -> nil
    end
  end

  defp entity("#" <> digits) do
    case Integer.parse(digits) do
      {n, ""} -> codepoint(n)
      _ -> nil
    end
  end

  defp entity(name), do: Map.get(@entities, name)

  defp codepoint(n) when n in 0x20..0x10FFFF, do: <<n::utf8>>
  defp codepoint(n) when n in [0x09, 0x0A], do: <<n::utf8>>
  defp codepoint(_), do: nil

  # Trailing spaces and runs of blank lines are most of what is left of a page.
  defp collapse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &(&1 |> String.replace(~r/[ \t\x{00A0}]+/u, " ") |> String.trim()))
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # A fetch is neither free nor reliably repeatable, so whatever is cut is stored
  # for the rest of the session. JSON is trimmed by array element rather than by
  # character, which keeps the document parseable.
  defp bound(text, type, ctx) do
    limits = Context.limits(ctx)
    text = Bound.sanitize(text)

    result =
      if String.contains?(type, "json"),
        do: Bound.json(text, @json_items, limits.max_chars),
        else: Bound.chars(text, limits.max_chars)

    Outputs.store_and_mark(ctx.session_id, text, result, limits.max_chars)
  end

  defp user_agent, do: "troupe/#{Application.spec(:troupe, :vsn) || "dev"}"
end
