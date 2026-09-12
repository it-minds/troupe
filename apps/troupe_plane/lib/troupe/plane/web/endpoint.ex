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
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 1_048_576]

  plug Plug.Static, at: "/admin/static", from: :troupe_plane, gzip: false, only: ~w(app.css)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:troupe, :plane, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # One port, two surfaces, split by path rather than chained: chaining them would mean
  # every panel request that the panel answered still ran through the API's router, which
  # would then try to 404 a response that had already been sent.
  plug :route

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
