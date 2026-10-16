defmodule Troupe.Plane.Web.AdminRouter do
  @moduledoc """
  The routes under `/admin`: the read-only page, the sign-in and the break-glass door in
  front of it, and where each page that is the console's now went.

  Behind OIDC: `/admin` with no session sends you to the provider, and the callback puts
  the subject in a signed cookie. The role is *not* in the cookie — it is worked out on
  every LiveView mount from the subject — so an administrator whose role was taken away
  loses the panel at their next page rather than at the expiry of a cookie they are still
  holding.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias Troupe.Plane.Web.Live

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Troupe.Plane.Web.Live.Root, :root})

    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/admin" do
    pipe_through(:browser)

    get("/login", Troupe.Plane.Web.AdminAuth, :login)
    get("/callback", Troupe.Plane.Web.AdminAuth, :callback)
    get("/denied", Troupe.Plane.Web.AdminAuth, :denied)
    get("/logout", Troupe.Plane.Web.AdminAuth, :logout)

    # The break-glass door. Always routed, and a 404 from the controller where no token
    # is configured — routing it conditionally would make the route table depend on
    # runtime configuration, and a 404 either way tells a stranger the same thing.
    get("/breakglass", Troupe.Plane.Web.AdminAuth, :breakglass)
    post("/breakglass", Troupe.Plane.Web.AdminAuth, :breakglass_submit)

    live_session :admin,
      on_mount: {Live.Auth, :admin},
      session: {Troupe.Plane.Web.Index, :live_session, []} do
      live("/", Live.Overview)
    end

    # Where the LiveView console's editors were. They are the console's now, at
    # `/console`, and a bookmark, a runbook or the deployment notes that name one of these
    # is sent to the same place there rather than to a 404.
    get("/:page", Troupe.Plane.Web.AdminMoved, :moved)
    get("/:page/:within", Troupe.Plane.Web.AdminMoved, :moved)
  end
end
