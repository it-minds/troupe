defmodule Troupe.Tools.WebFetch do
  @moduledoc """
  Fetch a URL and return it as text.

  `:ask` by default: it is network egress and text from outside the repository entering
  the model's context, and a pod's policy may deny it outright. HTML is reduced to
  readable text; JSON, Markdown, XML and plain text come back as they are. Long content
  is capped and kept for `read_output`.
  """

  @behaviour Troupe.Tool

  alias Troupe.Tool
  alias Troupe.Tools.Output

  @download_cap 5_000_000
  @timeout_ms 30_000
  @redirects 5

  @impl Troupe.Tool
  def name, do: "web_fetch"

  @impl Troupe.Tool
  def description do
    "Fetch a URL over HTTP(S) and return its content as text. HTML comes back as " <>
      "readable text with the markup, scripts and styles removed and links kept as " <>
      "`text (url)`; JSON, Markdown, XML and plain text come back verbatim. GET only; " <>
      "long content is cut and the marker names the `read_output` call that returns the rest."
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "Absolute http:// or https:// URL."}
      },
      "required" => ["url"]
    }
  end

  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, url} <- Tool.fetch_string(args, "url"),
         {:ok, uri} <- validate(url) do
      uri |> get() |> render(uri, ctx)
    end
  end

  @doc "Whether a URL is one this tool will fetch: absolute, http or https, with a host."
  @spec validate(String.t()) :: {:ok, URI.t()} | {:error, String.t()}
  def validate(url) do
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
    Req.get(URI.to_string(uri),
      headers: [
        {"user-agent", "troupe/#{Application.spec(:troupe_core, :vsn)}"},
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
    type = content_type(resp)

    case text(body(resp), type, uri) do
      {:ok, text} ->
        {:ok, "GET #{uri} → #{status} #{type}\n\n" <> Output.cap(String.trim(text), cap(ctx), ctx)}

      {:error, reason} ->
        {:error, "GET #{uri} → #{status} #{type}: #{reason}"}
    end
  end

  defp render({:ok, %Req.Response{status: status} = resp}, uri, _ctx) do
    excerpt =
      case text(body(resp), content_type(resp), uri) do
        {:ok, text} -> text |> String.trim() |> String.slice(0, 500)
        {:error, _} -> ""
      end

    {:error, String.trim("GET #{uri} → #{status}\n\n#{excerpt}")}
  end

  defp render({:error, %{reason: reason}}, uri, _ctx), do: {:error, "GET #{uri} failed: #{inspect(reason)}"}
  defp render({:error, reason}, uri, _ctx), do: {:error, "GET #{uri} failed: #{inspect(reason)}"}

  defp body(%Req.Response{} = resp), do: resp.private[:troupe_body] || ""

  defp content_type(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "content-type") do
      [type | _] -> type |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      [] -> ""
    end
  end

  defp cap(%{config: nil}), do: 60_000
  defp cap(%{config: config}), do: config.tool_output_limit

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
  Reduces an HTML document to readable text: script, style and other non-content blocks
  are dropped whole, block tags become line breaks, headings keep their `#` markers,
  list items a `-`, and a link becomes `text (url)` with relative hrefs resolved against
  `base`. Entities are decoded and blank runs collapsed.
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
    |> String.replace(~r{</(p|div|section|article|tr|ul|ol|pre|blockquote|table)>}i, "\n")
    |> String.replace(~r{<(hr)\s*/?>}i, "\n\n")
    |> String.replace(~r{</?[a-z][^>]*>}is, "")
    |> unescape()
    |> collapse()
  end

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

  defp collapse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.map_join("\n", &(&1 |> String.replace(~r/[ \t\x{00A0}]+/u, " ") |> String.trim()))
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
