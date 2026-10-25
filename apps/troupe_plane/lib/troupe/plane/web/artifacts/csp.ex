defmodule Troupe.Plane.Web.Artifacts.CSP do
  @moduledoc """
  The policy on every answer of the artifacts host (#62), which is what makes an artifact a
  page that can touch nothing.

    * **Sandboxed**, without `allow-same-origin`: the page runs in an origin of no site, so
      `document.cookie` and storage throw, an answer from this host is another origin's it
      cannot read, and it cannot navigate the tab that holds it. It may run its scripts, open
      a link in a new tab and offer a download, which a report needs.
    * **Its own files, and no script but those**: `default-src 'self'`, `script-src 'self'`,
      no inline script and no `eval`; styles may be inline, which runs nothing; images may be
      `data:` as a chart in a report often is.
    * **Nowhere to connect but here**: no `connect-src` to the plane or anywhere else, and no
      form may be sent anywhere.
    * **Framed by the plane's own pages and nothing else** (`frame-ancestors`), so no other
      site can put an artifact under its own words.

  Beside it `nosniff`, so nothing here is run as a script it is not, and no referrer, so a
  link out of an artifact tells nobody where it was.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "The policy, as the header carries it, framed by `plane` (an origin) or by nothing."
  @spec policy(String.t() | nil) :: String.t()
  def policy(plane) do
    [
      {"default-src", ["'self'"]},
      {"script-src", ["'self'"]},
      {"style-src", ["'self'", "'unsafe-inline'"]},
      {"img-src", ["'self'", "data:"]},
      {"font-src", ["'self'", "data:"]},
      {"media-src", ["'self'"]},
      {"connect-src", ["'self'"]},
      {"object-src", ["'none'"]},
      {"base-uri", ["'none'"]},
      {"form-action", ["'none'"]},
      {"frame-ancestors", [plane || "'none'"]},
      {"sandbox",
       ["allow-scripts", "allow-popups", "allow-popups-to-escape-sandbox", "allow-downloads"]}
    ]
    |> Enum.map_join("; ", fn {directive, sources} -> Enum.join([directive | sources], " ") end)
  end

  @doc "The plane's own origin, which alone may frame an artifact, or `nil`."
  @spec plane_origin() :: String.t() | nil
  def plane_origin do
    with base when is_binary(base) and base != "" <- Application.get_env(:troupe_plane, :base_url),
         %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) <-
           URI.parse(base) do
      port = if uri.port && uri.port != URI.default_port(scheme), do: ":#{uri.port}", else: ""
      "#{scheme}://#{host}#{port}"
    else
      _none -> nil
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", policy(plane_origin()))
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
