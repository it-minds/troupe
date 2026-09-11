import Config

# An unset environment variable and one set to the empty string mean the same thing
# here: a Helm value that was left blank renders as `""`.
presence = fn
  nil -> nil
  "" -> nil
  value -> value
end

# `host:port`, as the operator sets it, or nothing.
plane_control = fn
  nil ->
    nil

  value ->
    case String.split(value, ":") do
      [host, port] -> [host: host, port: String.to_integer(port)]
      [host] -> [host: host, port: 4001]
    end
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

  # -- a worker pod ---------------------------------------------------------

  if System.get_env("TROUPE_WORKER_AUTOSTART") == "true" do
    plane = presence.(System.get_env("TROUPE_PLANE_CONTROL"))

    config :troupe_worker,
      autostart: true,
      profile: System.get_env("TROUPE_PROFILE"),
      # 4000 is what the operator's Ingress and both probes point at; 4100 is the same
      # NDJSON the local daemon speaks, for anything inside the cluster that would rather
      # not carry an HTTP stack.
      http_port: String.to_integer(System.get_env("TROUPE_HTTP_PORT", "4000")),
      harness_port: String.to_integer(System.get_env("TROUPE_HARNESS_PORT", "4100")),
      sessions_per_pod: String.to_integer(System.get_env("TROUPE_SESSIONS_PER_POD", "4")),
      drain_timeout_seconds:
        String.to_integer(System.get_env("TROUPE_DRAIN_TIMEOUT_SECONDS", "300")),
      worker_id: presence.(System.get_env("TROUPE_POD_ORDINAL")),
      # The keys this pod verifies session tokens against. The plane pushes them over the
      # control channel, and a cached copy on disk is what lets a pod that restarted
      # before its plane is reachable still say yes or no — which is the whole claim
      # `Worker.Auth` makes.
      jwks_path: presence.(System.get_env("TROUPE_JWKS_PATH")),
      token_issuer: presence.(System.get_env("TROUPE_TOKEN_ISSUER")),
      # Absent means there is no plane to dial. A pod configured without one does not
      # start the link at all rather than retrying a name that does not resolve.
      plane: plane_control.(plane),
      kms: [
        address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
        token: presence.(System.get_env("TROUPE_BAO_TOKEN")),
        mount: System.get_env("TROUPE_BAO_MOUNT", "secret")
      ]

    if endpoint = presence.(System.get_env("TROUPE_OBJECT_ENDPOINT")) do
      config :troupe_protocol,
        object_store: [
          endpoint: endpoint,
          bucket: System.get_env("TROUPE_OBJECT_BUCKET", "troupe-sessions"),
          access_key_id: presence.(System.get_env("TROUPE_OBJECT_ACCESS_KEY_ID")),
          secret_access_key: presence.(System.get_env("TROUPE_OBJECT_SECRET_ACCESS_KEY")),
          region: System.get_env("TROUPE_OBJECT_REGION", "us-east-1")
        ]
    end
  end

  # -- the local daemon -----------------------------------------------------

  config :troupe_gateway, autostart: System.get_env("TROUPE_DAEMON_AUTOSTART") == "true"
end
