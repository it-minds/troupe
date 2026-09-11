import Config

# An unset environment variable and one set to the empty string mean the same thing
# here: a Helm value that was left blank renders as `""`.
presence = fn
  nil -> nil
  "" -> nil
  value -> value
end

# Read at boot, not at build: an image is built once and run in several clusters, and
# everything here is a property of the cluster rather than of the code.

if config_env() == :prod do
  # -- the operator ---------------------------------------------------------

  config :troupe_operator,
    autostart: System.get_env("TROUPE_OPERATOR_AUTOSTART") == "true",
    settings: [
      plane_control_host:
        System.get_env("TROUPE_PLANE_CONTROL_HOST", "troupe-plane-control.troupe-system.svc"),
      plane_control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      plane_namespace: System.get_env("TROUPE_PLANE_NAMESPACE", "troupe-system"),
      bao_address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
      object_store_endpoint:
        System.get_env("TROUPE_OBJECT_ENDPOINT", "http://minio.troupe-system.svc:9000"),
      object_store_bucket: System.get_env("TROUPE_OBJECT_BUCKET", "troupe-sessions"),
      ingress_class_name: System.get_env("TROUPE_INGRESS_CLASS", "nginx"),
      tls_secret_name: presence.(System.get_env("TROUPE_WORKERS_TLS_SECRET")),
      cilium_available: System.get_env("TROUPE_CILIUM_AVAILABLE") == "true",
      drain_timeout_seconds:
        String.to_integer(System.get_env("TROUPE_DRAIN_TIMEOUT_SECONDS", "300"))
    ]

  # -- the plane ------------------------------------------------------------

  if System.get_env("TROUPE_PLANE_AUTOSTART") == "true" do
    secret =
      System.get_env("TROUPE_SECRET_KEY_BASE") ||
        raise """
        TROUPE_SECRET_KEY_BASE is not set.

        It signs the admin panel's session cookies. There is a development default in
        config.exs and using it in a cluster would mean anybody who has read this
        repository can forge one, so a plane that is actually serving refuses to start
        without its own.
        """

    config :troupe_plane, Troupe.Plane.Web.Endpoint,
      server: true,
      secret_key_base: secret,
      http: [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("TROUPE_HTTP_PORT", "4000"))
      ],
      url: [host: System.get_env("TROUPE_HOST", "localhost"), scheme: "https", port: 443]

    config :troupe_plane,
      autostart: true,
      base_url: System.get_env("TROUPE_BASE_URL"),
      platform_admin_group: System.get_env("TROUPE_PLATFORM_ADMIN_GROUP"),
      audience: System.get_env("TROUPE_PLANE_AUDIENCE", "troupe-plane-api"),
      provisioning_mode:
        String.to_existing_atom(System.get_env("TROUPE_PROVISIONING_MODE", "direct")),
      oidc: [
        issuer: System.get_env("TROUPE_OIDC_ISSUER"),
        client_id: System.get_env("TROUPE_OIDC_CLIENT_ID"),
        client_secret: System.get_env("TROUPE_OIDC_CLIENT_SECRET"),
        authorization_endpoint: System.get_env("TROUPE_OIDC_AUTHORIZE_URL"),
        device_authorization_endpoint: System.get_env("TROUPE_OIDC_DEVICE_URL"),
        token_endpoint: System.get_env("TROUPE_OIDC_TOKEN_URL")
      ]
  end

  # -- the local daemon -----------------------------------------------------

  config :troupe_gateway, autostart: System.get_env("TROUPE_DAEMON_AUTOSTART") == "true"
end
