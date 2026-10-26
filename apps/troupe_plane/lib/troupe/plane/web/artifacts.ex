defmodule Troupe.Plane.Web.Artifacts do
  @moduledoc """
  The artifacts host (#62): where a published artifact is read, on an origin of its own and
  a port of its own, and nothing else.

      GET /enter?ticket=<t>           a ticket from `artifact.open`, for the cookie, then the artifact
      GET /a/<id>/                    the current version
      GET /a/<id>/<path>              a file of the current version
      GET /a/<id>/v<n>/[<path>]       a version, and its files
      GET /s/<token>                  a link: its role for the viewer signed in here, then the artifact
      GET /s/<token>/[<path>]         a public link's artifact, where public links are on
      GET /p/<nonce>/[<path>]         an edit's preview, which the console frames
      GET /_/document.css             the stylesheet a Markdown artifact's page uses
      GET /healthz                    liveness

  **What an artifact can touch: nothing.** Every answer carries `CSP.policy/0`: the page runs
  sandboxed, in an origin of no site at all, so it cannot read a cookie (this host's or
  anybody's), cannot read an answer from this host or any other, and cannot connect
  anywhere but here; scripts are only its own files, never inline; and only the plane's own
  pages may frame it. And this host is not the plane's: it is another listener on another
  port, behind an Ingress for another hostname, with no route to `/rpc`, the console or the
  plane's cookie. The plane's token never reaches it (the console keeps that to itself) and
  the plane's cookie is never sent to it (it is the plane's host's, host-only).

  **Who reads it.** The viewer this host's own cookie names, and only while they may see
  the artifact now, as `Artifacts.visible/3` reads it at every request. The cookie comes from
  `/enter`, which takes a ticket the plane signed for a signed-in person a minute ago and
  nobody has redeemed, so the only way onto this host is through the plane. A viewer with no
  cookie, or an expired one, is sent to the console, which signs them in and opens the
  artifact again with a fresh ticket.

  **A link** (`/s/<token>`) is the same door: a viewer signed in here is given its role and
  opens the artifact; anybody else is sent to the console with the link, which signs them in
  at the plane and spends it for them there. Only a public link, which exists while an
  administrator allows them, opens without a sign-in, and then under its own address, so
  nothing it serves carries a cookie. An edit's preview (`/p/<nonce>/`) is served under the
  same policy and checked against who may put, at every request.
  """

  use Plug.Router

  alias Troupe.Plane.Artifacts
  alias Troupe.Plane.Artifacts.Markdown
  alias Troupe.Plane.Web.Artifacts.CSP

  @cookie "troupe_artifact_viewer"

  plug(CSP)
  plug(Plug.Head)
  plug(:match)
  plug(:dispatch)

  get("/healthz", do: send_resp(conn, 200, "ok"))

  get "/_/document.css" do
    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> send_resp(200, stylesheet())
  end

  # A ticket in, this host's cookie out, and on to what it opens. A ticket that is forged,
  # old or spent is a 403 with a sentence, never a cookie.
  get "/enter" do
    conn = Plug.Conn.fetch_query_params(conn)

    case Artifacts.redeem(conn.query_params["ticket"]) do
      {:ok, %{subject: subject, id: id, version: version}} ->
        to = if version, do: "/a/#{id}/v#{version}/", else: "/a/#{id}/"

        conn
        |> put_resp_cookie(@cookie, Artifacts.viewer_cookie(subject), cookie_options())
        |> put_resp_header("location", to)
        |> send_resp(303, "")

      :error ->
        text(
          conn,
          403,
          "This link has been used, or is more than a minute old. Open the artifact again from the console."
        )
    end
  end

  # A version's address ends in a slash, as a directory's does, so the page's own relative
  # links resolve within it; one without is sent to the one with.
  get "/a/:id/*rest" do
    cond do
      not Artifacts.enabled?() ->
        not_found(conn)

      directory?(rest) and not String.ends_with?(conn.request_path, "/") ->
        conn |> put_resp_header("location", conn.request_path <> "/") |> send_resp(301, "")

      true ->
        serve(conn, id, rest)
    end
  end

  # A link's own address. Signed in here, the viewer takes its role and goes to the
  # artifact; not, to the console, which signs them in at the plane and spends it there.
  # A public one is the artifact itself, under the link's address.
  get "/s/:token/*rest" do
    case Artifacts.link?(token) do
      {:ok, :public} when rest == [] ->
        if String.ends_with?(conn.request_path, "/"),
          do: public(conn, token, nil),
          else: conn |> put_resp_header("location", "/s/#{token}/") |> send_resp(301, "")

      {:ok, :public} ->
        public(conn, token, join(rest))

      {:ok, :signed_in} ->
        enter_by_link(conn, token)

      :error ->
        not_found(conn)
    end
  end

  # An edit's preview: the edited file over the version it was made on. Its address is its
  # key for an hour, and whether its person may still put is read at every request.
  get "/p/:nonce/*rest" do
    if rest == [] and not String.ends_with?(conn.request_path, "/") do
      conn |> put_resp_header("location", conn.request_path <> "/") |> send_resp(301, "")
    else
      case Artifacts.preview_file(nonce, join(rest)) do
        {:ok, found} -> answer(conn, found)
        :error -> not_found(conn)
      end
    end
  end

  match(_, do: not_found(conn))

  defp public(conn, token, path) do
    case Artifacts.public(token, path) do
      {:ok, found} -> answer(conn, found)
      :error -> not_found(conn)
    end
  end

  defp enter_by_link(conn, token) do
    conn = Plug.Conn.fetch_cookies(conn)

    with {:ok, viewer} <- Artifacts.viewer(conn.cookies[@cookie]),
         {:ok, id} <- Artifacts.use_link(token, viewer) do
      conn |> put_resp_header("location", "/a/#{id}/") |> send_resp(303, "")
    else
      _not_here ->
        case Artifacts.console_url() do
          nil ->
            text(
              conn,
              401,
              "Sign in to your Troupe plane's console, and open this link again from there."
            )

          console ->
            conn
            |> put_resp_header("location", "#{console}#/artifacts/link/#{token}")
            |> send_resp(302, "")
        end
    end
  end

  # -- serving ------------------------------------------------------------------------

  defp serve(conn, id, rest) do
    conn = Plug.Conn.fetch_cookies(conn)

    case Artifacts.viewer(conn.cookies[@cookie]) do
      {:ok, viewer} ->
        {version, path} = address(rest)

        case Artifacts.fetch(id, version, path, viewer) do
          {:ok, found} -> answer(conn, found)
          {:error, :not_found} -> not_found(conn)
        end

      :error ->
        sign_in(conn, id)
    end
  end

  # `[]` is the current version's entry, `["v3"]` version 3's, `["v3", ...]` a file of it,
  # and anything else a file of the current version. A path never starts with `v<n>`: a
  # publish refuses one.
  defp address([]), do: {:current, nil}

  defp address(["v" <> n = segment | path]) do
    case Integer.parse(n) do
      {number, ""} when number > 0 -> {number, join(path)}
      _not_a_version -> {:current, join([segment | path])}
    end
  end

  defp address(path), do: {:current, join(path)}

  defp directory?([]), do: true
  defp directory?(["v" <> n]), do: match?({number, ""} when number > 0, Integer.parse(n))
  defp directory?(_path), do: false

  defp join([]), do: nil
  defp join(path), do: Enum.join(path, "/")

  # A Markdown artifact's own document is a page rendered here; everything else is served
  # as it was published, with the type it was published with.
  defp answer(conn, %{artifact: artifact, file: file, body: body}) do
    conn =
      if String.starts_with?(conn.request_path, "/p/"),
        do: register_before_send(conn, &put_resp_header(&1, "cache-control", "no-store")),
        else: conn

    if artifact.kind == "markdown" and markdown?(file["path"]) do
      conn
      |> put_resp_content_type("text/html")
      |> private()
      |> send_resp(200, Markdown.page(body, artifact.title))
    else
      raw(conn, file, body)
    end
  end

  defp raw(conn, file, body) do
    conn
    |> put_resp_header("content-type", file["content_type"] || "application/octet-stream")
    |> private()
    |> send_resp(200, body)
  end

  defp markdown?(path), do: String.downcase(Path.extname(path)) in [".md", ".markdown"]

  # What a viewer reads is theirs to read now, and not a cache's.
  defp private(conn), do: put_resp_header(conn, "cache-control", "private, no-cache")

  # Signed out: the console, which signs the viewer in at the plane and opens the artifact
  # again with a ticket. A plane with no address of its own says where to go instead.
  defp sign_in(conn, id) do
    case console_url() do
      nil ->
        text(
          conn,
          401,
          "Sign in to your Troupe plane's console and open this artifact from its Artifacts page."
        )

      console ->
        conn
        |> put_resp_header("location", "#{console}#/artifacts/#{URI.encode_www_form(id)}")
        |> send_resp(302, "")
    end
  end

  defp console_url, do: Artifacts.console_url()

  # Host-only (no `Domain`), so no other host is sent it, and out of every script's reach.
  # `SameSite=None` where it can be `Secure`: a sandboxed page is a document of no site, and
  # its own stylesheets and scripts are fetched as from another one, which a `Lax` cookie is
  # not sent with. Over plain HTTP, which only a machine of one's own serves, `Lax`.
  defp cookie_options do
    secure = secure?()

    [
      http_only: true,
      secure: secure,
      same_site: if(secure, do: "None", else: "Lax"),
      path: "/",
      max_age: Artifacts.viewer_seconds()
    ]
  end

  defp secure? do
    case Artifacts.host_url() && URI.parse(Artifacts.host_url()) do
      %URI{scheme: "https"} ->
        true

      # A browser holds this machine's own addresses secure over plain HTTP too.
      %URI{scheme: "http", host: host} ->
        host in ["localhost", "127.0.0.1"] or String.ends_with?(host || "", ".localhost")

      _other ->
        false
    end
  end

  defp not_found(conn),
    do: text(conn, 404, "There is no such artifact here, or it is not yours to see.")

  defp text(conn, status, sentence) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, sentence <> "\n")
  end

  @stylesheet """
  :root { color-scheme: light dark; --fg: #1c1d21; --bg: #ffffff; --muted: #5b5f6b; --line: #d9dbe1; --code: #f4f5f7; --k: #8a3ffc; --s: #1a7f37; --c: #6e7781; --n: #b35900; --accent: #2f5bd3; }
  @media (prefers-color-scheme: dark) { :root { --fg: #e6e7ea; --bg: #16171b; --muted: #a0a4ae; --line: #33363e; --code: #1f2127; --k: #c39bff; --s: #6fd28a; --c: #8b929e; --n: #f0a35a; --accent: #8fb0ff; } }
  html { background: var(--bg); color: var(--fg); }
  body { margin: 0; font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
  .document { max-width: 46rem; margin: 0 auto; padding: 2rem 1rem 4rem; }
  h1, h2, h3, h4 { line-height: 1.25; margin: 1.6em 0 0.5em; }
  h1 { font-size: 2rem; } h2 { font-size: 1.5rem; border-bottom: 1px solid var(--line); padding-bottom: 0.2em; }
  a { color: var(--accent); }
  code { font: 0.9em/1.4 ui-monospace, "Cascadia Code", Menlo, monospace; background: var(--code); padding: 0.1em 0.3em; border-radius: 3px; }
  pre { background: var(--code); padding: 0.8rem 1rem; overflow-x: auto; border-radius: 6px; }
  pre code { background: none; padding: 0; }
  blockquote { margin: 1em 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--line); }
  table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
  th, td { border: 1px solid var(--line); padding: 0.35em 0.7em; }
  img { max-width: 100%; }
  hr { border: none; border-top: 1px solid var(--line); margin: 2em 0; }
  .k { color: var(--k); } .s { color: var(--s); } .c { color: var(--c); font-style: italic; } .n { color: var(--n); }
  figure.diagram { margin: 1.5em 0; overflow-x: auto; }
  figure.diagram figcaption { color: var(--muted); font-size: 0.9em; }
  svg.mermaid { max-width: 100%; height: auto; font: 14px system-ui, sans-serif; }
  .m-node { fill: var(--code); stroke: var(--accent); stroke-width: 1.5; }
  .m-text, .m-label { fill: var(--fg); }
  .m-label-box { fill: var(--bg); }
  .m-edge { stroke: var(--muted); stroke-width: 1.5; }
  .m-dotted { stroke-dasharray: 4 4; } .m-thick { stroke-width: 3; }
  .m-head { fill: var(--muted); }
  """

  defp stylesheet, do: @stylesheet
end
