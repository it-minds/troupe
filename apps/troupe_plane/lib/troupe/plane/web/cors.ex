defmodule Troupe.Plane.Web.CORS do
  @moduledoc """
  Cross-origin access to the API, for a browser-hosted client and nobody else.

  The CLI does not need this: it is not a browser, and browsers are the only clients
  that enforce the same-origin policy. A GUI served from its own origin does, and the
  answer is an allowlist of exact origins — `https://gui.example.com`, or
  `tauri://localhost` for a desktop shell — each echoed back only to a request that
  presented it. Never `*`: a wildcard would let any page anywhere read a response the
  bearer token in the request unlocked. And never `Allow-Credentials`, because the API
  authenticates with a bearer header rather than a cookie, and a browser that could
  attach the admin panel's cookie to an `/rpc` call would be the CSRF the panel's own
  router exists to prevent.

  Only the routes a browser client calls: the discovery document, the JWKS, the login
  exchange and `/rpc`. SCIM is pushed by the identity provider, `/healthz` by the
  kubelet, and neither is a browser. An empty allowlist is the plug doing nothing at
  all, which is how a plane that serves only the CLI runs.
  """

  @behaviour Plug

  import Plug.Conn

  @allow_methods "GET, POST, OPTIONS"
  @allow_headers "authorization, content-type"
  # Ten minutes: long enough that a client polling `/rpc` does not preflight every call,
  # short enough that removing an origin from the allowlist takes effect the same day.
  @max_age "600"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case origins() do
      [] -> conn
      origins -> if browser_route?(conn), do: answer(conn, origins), else: conn
    end
  end

  defp origins, do: Application.get_env(:troupe_plane, :cors_origins, [])

  defp browser_route?(%Plug.Conn{path_info: ["rpc"]}), do: true
  defp browser_route?(%Plug.Conn{path_info: ["auth", "exchange"]}), do: true
  defp browser_route?(%Plug.Conn{path_info: [".well-known", _document]}), do: true
  defp browser_route?(_conn), do: false

  # `Vary: Origin` whenever the answer *could* depend on the origin, not only when it
  # did: a cache that stored a response to a request without an Origin header and
  # served it to one with an allowed origin would be serving a response with the
  # allow header missing, and the browser would refuse it.
  defp answer(conn, origins) do
    conn = vary_on_origin(conn)

    case matching_origin(conn, origins) do
      nil ->
        conn

      origin ->
        conn = put_resp_header(conn, "access-control-allow-origin", origin)

        if conn.method == "OPTIONS" do
          conn
          |> put_resp_header("access-control-allow-methods", @allow_methods)
          |> put_resp_header("access-control-allow-headers", @allow_headers)
          |> put_resp_header("access-control-max-age", @max_age)
          |> send_resp(204, "")
          |> halt()
        else
          conn
        end
    end
  end

  # Exact match. A browser serialises an origin as lowercase scheme and host with no
  # path, so the allowlist is written the same way and there is nothing to normalise —
  # and normalising would be a second opinion about what an origin is.
  defp matching_origin(conn, origins) do
    case get_req_header(conn, "origin") do
      [origin] -> if origin in origins, do: origin, else: nil
      _ -> nil
    end
  end

  defp vary_on_origin(conn) do
    case get_resp_header(conn, "vary") do
      [] -> put_resp_header(conn, "vary", "origin")
      [existing] -> put_resp_header(conn, "vary", existing <> ", origin")
    end
  end
end
