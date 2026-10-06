defmodule Troupe.Plane.Web.CSP do
  @moduledoc """
  The Content-Security-Policy on every response from this host (Decision 803).

  The web app the chart mounts at `/app/` keeps the local daemon's WebSocket token in
  `localStorage`, and the daemon admits this host's origin (Decision 797). So any script
  that ran on any page of this origin, the console's or the front page's as much as the
  app's, could read the token and drive somebody's daemon, which runs tools on their
  machine. What keeps that safe is that nothing but this release's own files ever runs
  here, and this header is where that is said to the browser:

    * **Scripts from this origin's files and nothing else.** No inline script, no event
      handler attribute, no `javascript:` URL, no `eval`, no other origin. The console's
      LiveView is `app.js`; the front page's one script switches its webfonts on.
    * **Styles may be inline.** The front page carries its stylesheet in a `<style>`, the
      sign-in pages and the console write `style` attributes, and a LiveView patch sets
      them on the budget bar; none of that can run anything. The webfonts' stylesheet and
      files come from their one host, as the pages already said.
    * **This host and nothing else** for a connection, an image, a frame's parent (none),
      a form's target, a `<base>` (none) and a plugin (none).

  First in the endpoint, before the static files and before the split between the console
  and the API, so a stylesheet, a 404 and a JSON answer carry it as a page does. The app
  at `/app/` is served by the GUI image, not by this endpoint, and its own server sends
  the app's copy of the policy (`clients/gui/docker/headers.conf`).

  With it, `nosniff`, so no answer here can be loaded as a script it is not: a JSON body
  named in a `<script src>` is refused rather than run, whatever it happens to parse as.
  """

  @behaviour Plug

  import Plug.Conn

  @policy [
    {"default-src", ["'self'"]},
    {"script-src", ["'self'"]},
    {"style-src", ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"]},
    {"font-src", ["'self'", "https://fonts.gstatic.com"]},
    {"img-src", ["'self'"]},
    {"connect-src", ["'self'"]},
    {"object-src", ["'none'"]},
    {"base-uri", ["'none'"]},
    {"form-action", ["'self'"]},
    {"frame-ancestors", ["'none'"]}
  ]

  @header Enum.map_join(@policy, "; ", fn {directive, sources} ->
            Enum.join([directive | sources], " ")
          end)

  @doc "The policy, as the header carries it."
  @spec policy() :: String.t()
  def policy, do: @header

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", @header)
    |> put_resp_header("x-content-type-options", "nosniff")
  end
end
