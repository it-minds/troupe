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

# What a pod tells the plane about itself when it enrols. None of it is *trusted* — the
# profile and the namespace come from the TokenReview, and the pod name from the token's
# own claim where Kubernetes provides one — but the plane has no other way to learn where
# a client should dial this pod, or how many sessions it will take.
enrolment = fn
  nil ->
    nil

  control ->
    pod = System.get_env("TROUPE_POD_ORDINAL")
    profile = System.get_env("TROUPE_PROFILE")
    domain = System.get_env("TROUPE_WORKERS_DOMAIN")

    ordinal =
      case pod && pod |> String.split("-") |> List.last() |> Integer.parse() do
        {ordinal, ""} -> ordinal
        _ -> nil
      end

    claims =
      %{"capacity" => String.to_integer(System.get_env("TROUPE_SESSIONS_PER_POD", "4"))}
      |> then(fn claims -> if pod, do: Map.put(claims, "pod_name", pod), else: claims end)
      |> then(fn claims ->
        node = System.get_env("TROUPE_NODE_NAME")
        if node, do: Map.put(claims, "node_name", node), else: claims
      end)
      |> then(fn claims ->
        # The whole URL, not a bare host. `<ordinal>.<profile>.<domain>` is what the
        # operator gave this pod's Ingress, and the scheme and port are how that Ingress
        # is actually reached — which the pod is told rather than the client guessing. A
        # client is handed this and dials it directly; the plane is not in the path.
        if ordinal && profile && domain do
          scheme = System.get_env("TROUPE_WORKERS_SCHEME", "wss")
          port = presence.(System.get_env("TROUPE_WORKERS_PORT"))
          authority = "#{ordinal}.#{profile}.#{domain}" <> if(port, do: ":#{port}", else: "")

          Map.put(claims, "endpoint", "#{scheme}://#{authority}/v1/socket")
        else
          claims
        end
      end)

    control ++ [claims: claims]
end

# The object store is the plane's and the workers' alike: the plane rebuilds its index
# from it and never decrypts anything, workers read and write sealed segments.
object_store = fn ->
  case presence.(System.get_env("TROUPE_OBJECT_ENDPOINT")) do
    nil ->
      nil

    endpoint ->
      [
        endpoint: endpoint,
        bucket: System.get_env("TROUPE_OBJECT_BUCKET", "troupe-sessions"),
        access_key_id: presence.(System.get_env("TROUPE_OBJECT_ACCESS_KEY_ID")),
        secret_access_key: presence.(System.get_env("TROUPE_OBJECT_SECRET_ACCESS_KEY")),
        region: System.get_env("TROUPE_OBJECT_REGION", "us-east-1")
      ]
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
      max_ports: String.to_integer(System.get_env("TROUPE_MAX_PORTS", "65536")),
      object_store_secret_name:
        presence.(System.get_env("TROUPE_OBJECT_SECRET_NAME")) || "troupe-object-store",
      workers_scheme: System.get_env("TROUPE_WORKERS_SCHEME", "wss"),
      workers_port: presence.(System.get_env("TROUPE_WORKERS_PORT")),
      drain_timeout_seconds:
        String.to_integer(System.get_env("TROUPE_DRAIN_TIMEOUT_SECONDS", "300"))
    ]

  # -- the plane ------------------------------------------------------------

  # The database is configured whenever there is one to configure, and *not* inside the
  # autostart gate below: `bin/troupe_plane eval Troupe.Plane.Release.migrate()` is a
  # release that reaches its repo and serves nothing, and gating the database on whether
  # the plane is serving would make a migration impossible to run.
  if url = presence.(System.get_env("DATABASE_URL")) do
    config :troupe_plane, Troupe.Plane.Repo,
      url: url,
      pool_size: String.to_integer(System.get_env("TROUPE_POOL_SIZE", "10")),
      ssl: System.get_env("TROUPE_DB_SSL") == "true"
  end

  if System.get_env("TROUPE_PLANE_AUTOSTART") == "true" do
    presence.(System.get_env("DATABASE_URL")) ||
      raise("""
      DATABASE_URL is not set.

      The plane keeps its index, its ledger and its audit trail in PostgreSQL. There is
      no default worth having: a plane that silently started against localhost would
      come up empty and look like data loss.
      """)

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
      control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      groups_claim: System.get_env("TROUPE_GROUPS_CLAIM", "groups"),
      scim_token: presence.(System.get_env("TROUPE_SCIM_TOKEN")),
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

    if store = object_store.() do
      config :troupe_protocol, object_store: store
    end
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
      # The token this pod authenticates to the key manager with. Projected by the
      # operator for the key manager's audience alone, so it is no use anywhere else.
      service_account_token_path:
        System.get_env("TROUPE_KMS_TOKEN_PATH", "/var/run/secrets/troupe/kms-token"),
      token_issuer: presence.(System.get_env("TROUPE_TOKEN_ISSUER")),
      # Absent means there is no plane to dial. A pod configured without one does not
      # start the link at all rather than retrying a name that does not resolve.
      plane: enrolment.(plane_control.(plane)),
      kms: [
        address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
        token: presence.(System.get_env("TROUPE_BAO_TOKEN")),
        mount: System.get_env("TROUPE_BAO_MOUNT", "secret")
      ]

    if store = object_store.() do
      config :troupe_protocol, object_store: store
    end
  end

  # -- the local daemon -----------------------------------------------------

  config :troupe_gateway, autostart: System.get_env("TROUPE_DAEMON_AUTOSTART") == "true"
end
