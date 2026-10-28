defmodule Troupe.Plane.Web.Endpoint do
  @moduledoc """
  The Phoenix endpoint the plane's host answers from.

  The plane's HTTP surface is `Troupe.Plane.Web.Router`, a plain `Plug.Router`: the API
  is a handful of routes and a SCIM path and gains nothing from a framework. What the
  endpoint adds around it is the listener's configuration, the request id and telemetry,
  the one body limit, the static files the front page needs, and the error page a browser
  sees when something inside has failed. The console that used to live here as a
  LiveView under `/admin` is an app of its own now, served beside the plane, and signs in
  as a public client straight to the provider; the plane keeps no browser session.
  """

  use Phoenix.Endpoint, otp_app: :troupe_plane

  alias Troupe.Plane.Web.{BodyLimit, Router}

  # Before anything that answers, so a static file, the API and a 404 all carry it:
  # nothing but this release's own files runs on this origin.
  plug(Troupe.Plane.Web.CSP)

  # The brand, and the theme the front page is painted in. `theme.css` is generated from
  # the Signal kit by `mix troupe.theme`; `brand/` is the mask, as SVG for the page and
  # as the two bitmap formats a favicon cannot avoid. `webfonts.js` switches the webfonts
  # on, rather than an `onload` attribute, because the origin runs no inline script.
  # Generated assets change only when the release does, and the document names them with
  # the release's version, so a year is safe and a reload is not a re-download.
  plug(Plug.Static,
    at: "/static",
    from: :troupe_plane,
    gzip: false,
    only: ~w(theme.css brand webfonts.js),
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:troupe, :plane, :endpoint])

  # Every body is read here, before the router sees the request, so this is where the
  # plane's one limit on a body holds: refused by its declared length before it is read,
  # and read no further than the limit when it declares none.
  plug(BodyLimit)

  # The GitHub App's webhook is signed over its body as it arrived, so `RawBody` keeps
  # those bytes for that route; the router's own parsers find the body read already.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: BodyLimit.bytes(),
    body_reader: {Troupe.Plane.Web.RawBody, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Router)
end
