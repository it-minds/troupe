defmodule Troupe.Plane.Web.Endpoint do
  @moduledoc """
  The Phoenix endpoint the admin panel lives behind.

  Separate from `Troupe.Plane.Web.Router`, which is the plane's API and is plain
  `Plug.Router`: the API is five routes and a SCIM path and would gain nothing from a
  framework, while the panel needs sockets, sessions and live reloading. Both are served
  from here, with the API mounted as a plug — one port, two surfaces, and no ambiguity
  about which is which since the panel is all under `/admin`.
  """

  use Phoenix.Endpoint, otp_app: :troupe_plane

  alias Troupe.Plane.Web.{AdminRouter, Router}

  @session_options [
    store: :cookie,
    key: "_troupe_plane",
    # Signed, not encrypted: what is in it is a subject, which the browser's own user
    # already knows. Signing is what stops it being *changed*.
    signing_salt: "troupe-plane-admin",
    same_site: "Lax"
  ]

  # A mebibyte per frame. What the panel sends up a LiveView socket is events — a form,
  # a click — and the largest of those is a profile editor's YAML; a frame bigger than
  # this is not the panel, and without a ceiling the socket would buffer it in full
  # before finding that out.
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 1_048_576]
  )

  # `tokens.css` is generated from the design tokens and `app.js` is vendored from the
  # Phoenix dependencies; both by a mix task, both committed. The allowlist named only
  # `app.css` — a file that has never existed — while the document asked for `app.js`,
  # so the panel served a 404 for its own script and every LiveView was inert.
  plug(Plug.Static,
    at: "/admin/static",
    from: :troupe_plane,
    gzip: false,
    only: ~w(app.js tokens.css console.css),
    # Generated assets change only when the release does, and the document names them
    # with the release's version, so a year is safe and a reload is not a re-download.
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  # The brand, and the theme the front page is painted in. Off the root rather than under
  # `/admin`, because the page that uses them is the one a person sees *before* they can
  # sign in — a stylesheet behind the console's door would 404 for exactly that reader.
  # `theme.css` is generated from the Signal kit by `mix troupe.theme`; `brand/` is the
  # mask, as SVG for the page and as the two bitmap formats a favicon cannot avoid.
  plug(Plug.Static,
    at: "/static",
    from: :troupe_plane,
    gzip: false,
    only: ~w(theme.css brand),
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:troupe, :plane, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)

  # One port, two surfaces, split by path rather than chained: chaining them would mean
  # every panel request that the panel answered still ran through the API's router, which
  # would then try to 404 a response that had already been sent.
  plug(:route)

  # The panel is all under `/admin`; everything else is the API.
  defp route(%Plug.Conn{path_info: ["admin" | _rest]} = conn, _opts) do
    AdminRouter.call(conn, AdminRouter.init([]))
  end

  defp route(conn, _opts) do
    Router.call(conn, Router.init([]))
  end

  @doc "The session options, which the socket and the plug pipeline must agree on."
  @spec session_options() :: keyword()
  def session_options, do: @session_options
end
