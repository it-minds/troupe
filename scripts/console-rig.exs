# The plane, serving, in MIX_ENV=dev — a screenshot rig and nothing else.
#
# `config/runtime.exs` is gated on `config_env() == :prod`, which is right: a laptop
# should not open a port by accident. So the two switches that gate belongs behind are
# set here, before the application starts, rather than by loosening the gate.
endpoint = Application.get_env(:troupe_plane, Troupe.Plane.Web.Endpoint)

Application.put_env(:troupe_plane, Troupe.Plane.Web.Endpoint,
  Keyword.merge(endpoint,
    server: true,
    http: [ip: {0, 0, 0, 0}, port: 4000],
    url: [host: "localhost", scheme: "http", port: 4000],
    code_reloader: false,
    debug_errors: true
  )
)

Application.put_env(:troupe_plane, :autostart, true)
Application.put_env(:troupe_plane, :base_url, "http://localhost:4000")
Application.put_env(:troupe_plane, :issuer, "http://localhost:4000")
Application.put_env(:troupe_plane, :plane_name, "troupe-dev")
Application.put_env(:troupe_plane, :audience, "troupe-plane-api")
Application.put_env(:troupe_plane, :groups_claim, "groups")
Application.put_env(:troupe_plane, :platform_admin_group, "platform")

Application.put_env(:troupe_plane, :oidc,
  issuer: "http://localhost:9999",
  client_id: "troupe",
  authorization_endpoint: "http://localhost:9999/authorize",
  device_authorization_endpoint: "http://localhost:9999/devicecode",
  token_endpoint: "http://localhost:9999/token"
)

{:ok, _started} = Application.ensure_all_started(:troupe_plane)

IO.puts("plane serving on http://localhost:4000")
Process.sleep(:infinity)
