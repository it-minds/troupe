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
        String.to_integer(System.get_env("TROUPE_DRAIN_TIMEOUT_SECONDS", "300")),
      # Comma-separated names, as the chart joins them; an unset variable and an empty
      # one both mean no pull secrets.
      image_pull_secrets:
        "TROUPE_IMAGE_PULL_SECRETS"
        |> System.get_env("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "")),
      # The same shape: the origins every worker pod admits on its WebSocket, or none
      # to admit them all.
      worker_allowed_origins:
        "TROUPE_WORKER_ALLOWED_ORIGINS"
        |> System.get_env("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    ]

  # -- the plane ------------------------------------------------------------

  # The database is configured whenever there is one to configure, and *not* inside the
  # autostart gate below: `bin/troupe_plane eval Troupe.Plane.Release.migrate()` is a
  # release that reaches its repo and serves nothing, and gating the database on whether
  # the plane is serving would make a migration impossible to run.
  if url = presence.(System.get_env("DATABASE_URL")) do
    # Verified TLS or none. `ssl: true` on its own encrypts the connection and accepts
    # whatever certificate is at the other end, which is not what anybody setting
    # TROUPE_DB_SSL=true means: a database behind a private CA, or a managed one, is
    # verified against that CA (TROUPE_DB_CACERT_FILE) or the system's roots. The name
    # checked is the host in DATABASE_URL, with the HTTPS wildcard rules, because a
    # managed provider's certificate is very often `*.<region>.<provider>`.
    ssl =
      if System.get_env("TROUPE_DB_SSL") == "true" do
        host = URI.parse(url).host || "localhost"

        roots =
          case presence.(System.get_env("TROUPE_DB_CACERT_FILE")) do
            nil -> [cacerts: :public_key.cacerts_get()]
            file -> [cacertfile: String.to_charlist(file)]
          end

        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ] ++ roots
      else
        false
      end

    # Per replica, not per plane: two replicas at the default hold twenty connections
    # between them, plus the migration's. A single small managed instance — the kind
    # that allows twenty-five in total — needs this lowered to leave room for anything
    # else that connects, and a plane that hits the instance's ceiling looks like a
    # database outage rather than like a pool that is too big.
    config :troupe_plane, Troupe.Plane.Repo,
      url: url,
      pool_size: String.to_integer(System.get_env("TROUPE_POOL_SIZE", "10")),
      ssl: ssl
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

    # A plane that is serving is a plane people log in to, and a login needs a provider.
    # Left unset, these would come up as `nil` and the failure would arrive later, as a
    # client told to visit a device-authorization URL that does not exist.
    oidc_required = fn name ->
      presence.(System.get_env(name)) ||
        raise """
        #{name} is not set.

        The plane is a relying party: `/auth/exchange` verifies provider tokens against
        the issuer's keys, and the discovery document at `/.well-known/troupe` tells a
        client which provider to run the device grant against. Without the issuer, the
        client id, the device authorization endpoint and the token endpoint, nobody can
        log in, so a plane that is actually serving refuses to start rather than come up
        with a login that cannot work.
        """
    end

    config :troupe_plane, Troupe.Plane.Web.Endpoint,
      server: true,
      secret_key_base: secret,
      http: [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("TROUPE_HTTP_PORT", "4000"))
      ],
      url: [host: System.get_env("TROUPE_HOST", "localhost"), scheme: "https", port: 443]

    # The plane's own OpenBao credential. A static token where one is given; otherwise
    # `Troupe.Plane.Tokens.Credential` exchanges the ServiceAccount token projected at
    # `jwt_path` for a client token under `role`. There is no default token: a plane
    # with neither fails to sign and says why, rather than trying a development root
    # token against the cluster's key manager.
    config :troupe_plane, :transit,
      address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
      token: presence.(System.get_env("TROUPE_BAO_TOKEN")),
      auth_path: System.get_env("TROUPE_BAO_AUTH_PATH", "kubernetes"),
      role: System.get_env("TROUPE_BAO_ROLE", "troupe-plane"),
      jwt_path: System.get_env("TROUPE_BAO_JWT_PATH", "/var/run/secrets/troupe/bao-token")

    # Where this plane is reached from outside, which is what a token it mints names as
    # its issuer. Only origins in the allowlist get a CORS answer, each one exactly as
    # a browser would send it; an empty list is CORS off, which is right for a plane
    # only ever reached by the CLI.
    base_url =
      presence.(System.get_env("TROUPE_BASE_URL")) ||
        "https://#{System.get_env("TROUPE_HOST", "localhost")}"

    cors_origins =
      "TROUPE_CORS_ORIGINS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # One JSON object per line where the log pipeline parses rather than reads. Only the
    # formatter changes; what is logged, and at which level, does not.
    if System.get_env("TROUPE_LOG_FORMAT") == "json" do
      config :logger, :default_handler,
        formatter: {Troupe.Plane.LogFormatter, %{metadata: [:request_id, :session_id]}}
    end

    # Erlang distribution, without which `replicas: 2` is not two replicas of one plane
    # but two planes. The cluster-unique actors — one `Placement` per profile, one
    # `TeamBudget` per team — are registered with `:global`, and `:global` spans a
    # cluster. Unclustered, each replica would place sessions and reserve budget as if it
    # were the only one.
    #
    # `mode: :ip` rather than a headless service: a pod's IP is what the API server
    # already knows, and the plane's RBAC grants exactly `pods` and `endpoints`.
    #
    # `kubernetes_ip_lookup_mode: :pods` is load-bearing. libcluster defaults to
    # `:endpoints`, which applies the selector to *Services* — and a Service carries
    # `component=plane` as its selector rather than as a label of its own, so the default
    # matches nothing, finds no peers, and says nothing about it. The pods are what we
    # want the selector applied to.
    if System.get_env("RELEASE_DISTRIBUTION") == "name" do
      config :troupe_plane,
        topologies: [
          plane: [
            strategy: Cluster.Strategy.Kubernetes,
            config: [
              mode: :ip,
              kubernetes_ip_lookup_mode: :pods,
              kubernetes_node_basename: System.get_env("TROUPE_NODE_BASENAME", "troupe-plane"),
              kubernetes_selector:
                System.get_env("TROUPE_PLANE_SELECTOR", "app.kubernetes.io/component=plane"),
              kubernetes_namespace: System.get_env("TROUPE_PLANE_NAMESPACE", "troupe-system"),
              polling_interval: 5_000
            ]
          ]
        ]
    end

    config :troupe_plane,
      autostart: true,
      base_url: System.get_env("TROUPE_BASE_URL"),
      issuer: base_url,
      cors_origins: cors_origins,
      control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      groups_claim: System.get_env("TROUPE_GROUPS_CLAIM", "groups"),
      scim_token: presence.(System.get_env("TROUPE_SCIM_TOKEN")),
      platform_admin_group: System.get_env("TROUPE_PLATFORM_ADMIN_GROUP"),
      audience: System.get_env("TROUPE_PLANE_AUDIENCE", "troupe-plane-api"),
      provisioning_mode:
        String.to_existing_atom(System.get_env("TROUPE_PROVISIONING_MODE", "direct")),
      oidc: [
        issuer: oidc_required.("TROUPE_OIDC_ISSUER"),
        client_id: oidc_required.("TROUPE_OIDC_CLIENT_ID"),
        client_secret: System.get_env("TROUPE_OIDC_CLIENT_SECRET"),
        authorization_endpoint: System.get_env("TROUPE_OIDC_AUTHORIZE_URL"),
        device_authorization_endpoint: oidc_required.("TROUPE_OIDC_DEVICE_URL"),
        token_endpoint: oidc_required.("TROUPE_OIDC_TOKEN_URL")
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

    # The WebSocket a client attaches through. A frame is a whole message and the socket
    # refuses one larger than this before it is assembled — a ceiling for a connection
    # that has not yet shown a token, not the protocol's message limit. The origin list
    # is for browsers: a page not on it does not get an upgrade. Empty admits every origin,
    # because the token is what actually admits a connection; a deployment that knows
    # which origins host its GUI names them here.
    config :troupe_gateway,
      max_frame_bytes: String.to_integer(System.get_env("TROUPE_MAX_FRAME_BYTES", "16777216")),
      allowed_origins:
        "TROUPE_ALLOWED_ORIGINS"
        |> System.get_env("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
  end

  # -- the local daemon -----------------------------------------------------

  config :troupe_gateway, autostart: System.get_env("TROUPE_DAEMON_AUTOSTART") == "true"
end
