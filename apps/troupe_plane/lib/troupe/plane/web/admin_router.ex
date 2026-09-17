defmodule Troupe.Plane.Web.AdminRouter do
  @moduledoc """
  The panel's routes, and the login that stands in front of them.

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

    live_session :admin, on_mount: {Live.Auth, :admin} do
      live("/", Live.Overview)
      live("/workers", Live.Workers)
      live("/workers/:profile", Live.Workers)
      live("/provisioners", Live.Provisioners)
      live("/teams", Live.Teams)
      live("/sessions", Live.Sessions)
      live("/budgets", Live.Budgets)
      live("/connections", Live.Connections)
      live("/bundles", Live.Bundles)
      live("/triggers", Live.Triggers)
      live("/triggers/:team", Live.Triggers)
      live("/audit", Live.Audit)
      # Readable by a team admin and writable only by a platform admin, which the page
      # enforces per field rather than by not being routed: a team admin who cannot see
      # what the platform is configured with cannot tell whether their problem is theirs.
      live("/policy", Live.Policy)

      # The address it had when it was only one rung of the ladder. Kept because it is in
      # the deployment notes, in the runbook and in at least one bookmark, and a 404 on
      # the page somebody was told to open is a worse answer than the page.
      live("/settings", Live.Policy)
    end

    live_session :platform, on_mount: {Live.Auth, :platform_admin} do
      live("/profile/new", Live.ProfileEditor)
      live("/profile/:profile", Live.ProfileEditor)
    end
  end
end
