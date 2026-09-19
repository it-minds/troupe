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
        # The whole URL, not a bare host. `<ordinal>-<profile>.<domain>` is what the
        # operator gave this pod's Ingress, and the scheme and port are how that Ingress
        # is actually reached — which the pod is told rather than the client guessing. A
        # client is handed this and dials it directly; the plane is not in the path.
        #
        # The hyphen keeps the whole thing one DNS label under `<domain>`, so a single
        # `*.workers.<domain>` record and a single wildcard certificate cover every
        # profile. `Troupe.Operator.Names.host/3` composes the same name and says why;
        # the two must agree and cannot share a function across the app boundary.
        if ordinal && profile && domain do
          scheme = System.get_env("TROUPE_WORKERS_SCHEME", "wss")
          port = presence.(System.get_env("TROUPE_WORKERS_PORT"))
          authority = "#{ordinal}-#{profile}.#{domain}" <> if(port, do: ":#{port}", else: "")

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
      object_store_region: System.get_env("TROUPE_OBJECT_REGION", "us-east-1"),
      ingress_class_name: System.get_env("TROUPE_INGRESS_CLASS", "nginx"),
      tls_secret_name: presence.(System.get_env("TROUPE_WORKERS_TLS_SECRET")),
      cert_issuer: presence.(System.get_env("TROUPE_WORKERS_CERT_ISSUER")),
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
    # The break-glass door into the panel. Absent means there is no door: the routes
    # answer 404 and nothing about the deployment says otherwise. Set it only where
    # somebody has decided they want one, and put it in a Secret rather than a values
    # file — `Troupe.Plane.Web.Breakglass` says what it does and does not buy.
    config :troupe_plane, :breakglass,
      token: presence.(System.get_env("TROUPE_BREAKGLASS_TOKEN")),
      subject: System.get_env("TROUPE_BREAKGLASS_SUBJECT", "breakglass"),
      lifetime_seconds:
        String.to_integer(System.get_env("TROUPE_BREAKGLASS_LIFETIME_SECONDS", "3600"))

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

    oidc_scopes =
      case System.get_env("TROUPE_OIDC_SCOPES") do
        nil -> nil
        value -> value |> String.split([",", " "], trim: true) |> Enum.map(&String.trim/1)
      end

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

    # How the plane reaches Kubernetes, which until now it could not. `Provision` and
    # `ClusterPolicy` both read `:k8s_conn` and nothing ever set it, so every profile a
    # console applied was recorded and never written — reported honestly as `not_applied`
    # with `:no_cluster`, and just as honestly ignored — and every policy check answered
    # "no policy configured, allow everything".
    #
    # An MFA rather than a built connection, because it is then rebuilt per call: a
    # projected ServiceAccount token is rotated roughly hourly, and a connection built
    # once at boot would outlive the token inside it.
    #
    # Left unset where there is no cluster to reach. A plane on a laptop drafting profiles
    # should say it did not apply them, and the absence is what makes it say so.
    kubernetes =
      cond do
        path = presence.(System.get_env("TROUPE_KUBECONFIG")) ->
          {K8s.Conn, :from_file, [path]}

        File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token") ->
          {K8s.Conn, :from_service_account, []}

        true ->
          nil
      end

    if kubernetes do
      config :troupe_plane, k8s_conn: kubernetes
    end

    config :troupe_plane,
      autostart: true,
      base_url: System.get_env("TROUPE_BASE_URL"),
      # Where the index page sends a browser looking for the graphical client. The GUI
      # is a separate release with its own chart, mounted at `/app` on this host by
      # default; an empty value is a plane that ships without one, and the index then
      # offers no door rather than one that answers 404.
      app_url: System.get_env("TROUPE_APP_URL", "/app"),
      # And where the terminal client is published. Nothing here builds one — this
      # repository is deployed to a cluster and installs on no machine — so there is no
      # sensible default: unset, the page says to ask an administrator; set, it links.
      cli_url: System.get_env("TROUPE_CLI_URL", ""),
      issuer: base_url,
      cors_origins: cors_origins,
      control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      groups_claim: System.get_env("TROUPE_GROUPS_CLAIM", "groups"),
      scim_token: presence.(System.get_env("TROUPE_SCIM_TOKEN")),
      platform_admin_group: System.get_env("TROUPE_PLATFORM_ADMIN_GROUP"),
      audience: System.get_env("TROUPE_PLANE_AUDIENCE", "troupe-plane-api"),
      # Spelled out rather than `String.to_existing_atom/1`: under `bin/troupe_plane eval`
      # the release boots `start_clean` in interactive mode, no application module is
      # loaded yet, and `:direct` is not an atom that exists — so every eval recipe in the
      # admin docs died in this config provider (Decision 634).
      provisioning_mode:
        case System.get_env("TROUPE_PROVISIONING_MODE", "direct") do
          "direct" -> :direct
          "gitops" -> :gitops
          other -> raise ArgumentError, "TROUPE_PROVISIONING_MODE must be direct or gitops, got #{inspect(other)}"
        end,
      oidc: [
        issuer: oidc_required.("TROUPE_OIDC_ISSUER"),
        client_id: oidc_required.("TROUPE_OIDC_CLIENT_ID"),
        client_secret: System.get_env("TROUPE_OIDC_CLIENT_SECRET"),
        authorization_endpoint: System.get_env("TROUPE_OIDC_AUTHORIZE_URL"),
        # Absent means the four OIDC scopes the router defaults to. Set it only for a
        # provider that needs something else; a scope the provider does not recognise
        # fails every sign-in before a password is typed.
        scopes: oidc_scopes,
        # What an MCP client asks for. Absent means `<base_url>/mcp/admin`, which is the
        # scope named after the resource itself — the only name a client is allowed to send
        # as RFC 8707's `resource`. Set it where the registration exposes another.
        mcp_scope: presence.(System.get_env("TROUPE_OIDC_MCP_SCOPE")),
        device_authorization_endpoint: oidc_required.("TROUPE_OIDC_DEVICE_URL"),
        token_endpoint: oidc_required.("TROUPE_OIDC_TOKEN_URL")
      ]

    if store = object_store.() do
      config :troupe_protocol, object_store: store
    end
  end

  # How a worker proves which worker it is.
  #
  # A pod's is a projected ServiceAccount token at a fixed path, rotated in place, and is
  # the default. A machine registered on the Provisioners screen has neither a projection
  # nor a rotation, so it presents the secret that registration minted — from a file where
  # one is named, and from the environment where one is not.
  #
  # The file is the better of the two and is listed first for that reason: an environment
  # variable is readable in `/proc` and in `ps` output by anybody on that machine, which a
  # laptop has more of than a pod does.
  worker_token = fn
    nil ->
      nil

    plane_opts ->
      cond do
        path = presence.(System.get_env("TROUPE_TOKEN_PATH")) ->
          Keyword.put(plane_opts, :token, {:file, path})

        secret = presence.(System.get_env("TROUPE_HOST_SECRET")) ->
          Keyword.put(plane_opts, :token, secret)

        true ->
          plane_opts
      end
  end

  # -- a worker pod ---------------------------------------------------------

  if System.get_env("TROUPE_WORKER_AUTOSTART") == "true" do
    plane = presence.(System.get_env("TROUPE_PLANE_CONTROL"))

    # Where a session's model calls are recorded for the plane's ledger. Configured for
    # a pod and for nothing else: on a laptop there is no plane to report to, and a
    # session must behave identically with no sink at all.
    config :troupe_core, usage_sink: Troupe.Worker.Usage

    config :troupe_worker,
      autostart: true,
      profile: System.get_env("TROUPE_PROFILE"),
      # 4000 is what the operator's Ingress and both probes point at; 4100 is the same
      # NDJSON the local daemon speaks, for anything inside the cluster that would rather
      # not carry an HTTP stack.
      http_port: String.to_integer(System.get_env("TROUPE_HTTP_PORT", "4000")),
      harness_port: String.to_integer(System.get_env("TROUPE_HARNESS_PORT", "4100")),
      sessions_per_pod: String.to_integer(System.get_env("TROUPE_SESSIONS_PER_POD", "4")),
      # The profile's MCP servers, as the operator wrote them into the pod spec: the same
      # shape a bundle carries, so a pod knows its servers before its first bundle arrives
      # and a bundle that names the same server simply agrees with it.
      mcp_servers: Jason.decode!(System.get_env("TROUPE_MCP_SERVERS", "[]")),
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
      plane: enrolment.(plane_control.(plane)) |> worker_token.(),
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

  # -- the A2A facade -------------------------------------------------------

  if System.get_env("TROUPE_A2A_AUTOSTART") == "true" do
    # What the facade calls itself in the URLs it hands out: the card's `url` and every
    # artifact's `uri`. There is no default worth having — a pod cannot know the host
    # its Ingress answers on, and a card that names the wrong URL is a card nobody can
    # call — so a facade that is actually serving refuses to start without one.
    public_url =
      presence.(System.get_env("TROUPE_A2A_PUBLIC_URL")) ||
        raise("""
        TROUPE_A2A_PUBLIC_URL is not set.

        The facade puts this in every agent card and every artifact URI. It is the
        origin the Ingress serves the facade on, such as https://a2a.example.com.
        """)

    config :troupe_a2a,
      autostart: true,
      port: String.to_integer(System.get_env("TROUPE_A2A_PORT", "4002")),
      # The plane's in-cluster Service. The facade is a client of `/rpc` like any other
      # and could as well be given the public URL; the Service saves a trip through the
      # Ingress for every call.
      plane_url:
        System.get_env("TROUPE_A2A_PLANE_URL", "http://troupe-plane.troupe-system.svc:4000"),
      public_url: public_url,
      max_streams: String.to_integer(System.get_env("TROUPE_A2A_MAX_STREAMS", "200")),
      # The visibility a task's session is created with. `team` lets a person audit what
      # other agents asked of the team's profiles; `private` keeps it to the principal.
      visibility: System.get_env("TROUPE_A2A_VISIBILITY", "private")
  end
end
