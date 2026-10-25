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

  # The seccomp profile of every worker container, `worker.seccomp` in the chart. Unset is
  # the runtime's default, as it always was, which keeps a filter and lets no command run
  # on a pod. Anything else that is not a profile the kubelet takes stops the operator
  # here, with the reason, rather than in an event on every StatefulSet it writes.
  worker_seccomp_type =
    presence.(System.get_env("TROUPE_WORKER_SECCOMP_TYPE")) || "RuntimeDefault"

  worker_seccomp_profile = presence.(System.get_env("TROUPE_WORKER_SECCOMP_PROFILE"))

  cond do
    worker_seccomp_type not in ["Localhost", "RuntimeDefault", "Unconfined"] ->
      raise """
      TROUPE_WORKER_SECCOMP_TYPE is #{inspect(worker_seccomp_type)}, and a worker container's \
      seccomp profile is Localhost, RuntimeDefault or Unconfined (worker.seccomp.type in the chart).
      """

    worker_seccomp_type == "Localhost" and is_nil(worker_seccomp_profile) ->
      raise """
      TROUPE_WORKER_SECCOMP_TYPE is Localhost and TROUPE_WORKER_SECCOMP_PROFILE names no \
      profile: set the path under the kubelet's seccomp directory \
      (worker.seccomp.localhostProfile in the chart).
      """

    true ->
      :ok
  end

  # The AppArmor profile every worker container runs under (`worker.appArmor` in the
  # chart), by the name it is loaded under on the nodes. Unset leaves the container on the
  # runtime's default, as it always was. A name the kubelet would not take stops the
  # operator here rather than in an event on every StatefulSet.
  worker_apparmor_profile = presence.(System.get_env("TROUPE_WORKER_APPARMOR_PROFILE"))

  if worker_apparmor_profile &&
       not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, worker_apparmor_profile) do
    raise """
    TROUPE_WORKER_APPARMOR_PROFILE is #{inspect(worker_apparmor_profile)}, and it is the name \
    of an AppArmor profile loaded on the nodes, letters, digits, dots, dashes and \
    underscores (worker.appArmor.profile in the chart).
    """
  end

  config :troupe_operator,
    autostart: System.get_env("TROUPE_OPERATOR_AUTOSTART") == "true",
    settings: [
      plane_control_host:
        System.get_env("TROUPE_PLANE_CONTROL_HOST", "troupe-plane-control.troupe-system.svc"),
      plane_control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      plane_namespace: System.get_env("TROUPE_PLANE_NAMESPACE", "troupe-system"),
      # The plane's control CA, `ca.crt` alone, as the chart mounts it from the plane's
      # Secret (`plane.controlTls`). Set, every worker namespace is given it and every pod
      # dials the control port with TLS; unset, pods dial in plaintext.
      plane_ca_path: presence.(System.get_env("TROUPE_PLANE_CONTROL_CA")),
      # Whether the plane takes TLS only on that port (`plane.controlTls.requireTls`), so a
      # pod that dials in plaintext is one the plane can never drain.
      plane_require_tls: System.get_env("TROUPE_PLANE_CONTROL_REQUIRE_TLS") == "true",
      bao_address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
      bao_role_per_profile: System.get_env("TROUPE_BAO_WORKER_ROLE_PER_PROFILE") == "true",
      bao_auth_path: presence.(System.get_env("TROUPE_BAO_AUTH_PATH")) || "kubernetes",
      object_store_endpoint:
        System.get_env("TROUPE_OBJECT_ENDPOINT", "http://minio.troupe-system.svc:9000"),
      object_store_bucket: System.get_env("TROUPE_OBJECT_BUCKET", "troupe-sessions"),
      object_store_region: System.get_env("TROUPE_OBJECT_REGION", "us-east-1"),
      ingress_class_name: System.get_env("TROUPE_INGRESS_CLASS", "nginx"),
      # The ingress controller's namespace (`operator.ingressNamespace`), which the operator
      # labels `troupe.dev/ingress=true` unless told not to; unset, some namespace carrying
      # the label is a precondition each profile checks.
      ingress_namespace: presence.(System.get_env("TROUPE_INGRESS_NAMESPACE")),
      label_ingress_namespace: System.get_env("TROUPE_INGRESS_NAMESPACE_LABEL") != "false",
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
      worker_seccomp_type: worker_seccomp_type,
      worker_seccomp_profile: worker_seccomp_profile,
      worker_apparmor_profile: worker_apparmor_profile,
      # A user namespace for every worker pod and its `/proc` unmasked
      # (`worker.userNamespaces` in the chart). Unset is off, as it always was.
      worker_user_namespaces: System.get_env("TROUPE_WORKER_USER_NAMESPACES") == "true",
      # The Pod Security labels on every worker namespace (`podSecurity.labels` in the
      # chart). Unset is off, as it always was.
      pod_security_labels: System.get_env("TROUPE_POD_SECURITY_LABELS") == "true",
      # Comma-separated names, as the chart joins them; an unset variable and an empty
      # one both mean no pull secrets.
      image_pull_secrets:
        "TROUPE_IMAGE_PULL_SECRETS"
        |> System.get_env("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "")),
      # The same shape: the browser origins every worker pod admits on its WebSocket
      # besides the desktop app's own. None admits no page; `*` admits every one.
      worker_allowed_origins:
        "TROUPE_WORKER_ALLOWED_ORIGINS"
        |> System.get_env("")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    ]

  # -- the plane ------------------------------------------------------------

  # Where the plane writes its WorkerProfiles and Triggers, the chart's `namespace`, and the
  # prefix every worker namespace carries, its `policy.namespacePrefix`, which enrolment
  # takes off a pod's namespace to name its profile. Outside the autostart gate below, like
  # the operator's settings, so that what a release reads can be read without a plane.
  config :troupe_plane,
    namespace: System.get_env("TROUPE_PLANE_NAMESPACE", "troupe-system"),
    namespace_prefix: System.get_env("TROUPE_NAMESPACE_PREFIX", "troupe-w-")

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
      # And where the administrative console is, which the index's console door and the
      # LiveView console's landing page point at. The chart serves it at `/console` on
      # this host; an empty value is a plane without one, and both then keep `/admin`.
      console_url: System.get_env("TROUPE_CONSOLE_URL", "/console"),
      # And where the terminal client is published. Nothing here builds one — this
      # repository is deployed to a cluster and installs on no machine — so there is no
      # sensible default: unset, the page says to ask an administrator; set, it links.
      cli_url: System.get_env("TROUPE_CLI_URL", ""),
      # The worker image of this release, which is what a profile whose image is `release`
      # runs. The chart sets it from `worker.image` and its own version, so an upgrade
      # moves those profiles with it; unset, the plane refuses `release` rather than
      # writing a WorkerProfile with no image.
      worker_image: presence.(System.get_env("TROUPE_WORKER_IMAGE")),
      issuer: base_url,
      cors_origins: cors_origins,
      control_port: String.to_integer(System.get_env("TROUPE_PLANE_CONTROL_PORT", "4001")),
      # Where the control port's certificate is: the Secret cert-manager writes for the
      # control Service, mounted by the chart. Unset, the port speaks plaintext alone and
      # no machine can be registered, since a machine enrols over TLS only.
      control_tls: presence.(System.get_env("TROUPE_PLANE_CONTROL_TLS_DIR")),
      # Whether the port takes TLS only, pods included: a plaintext connection is closed
      # before any of it is read. Unset is on wherever the port has a certificate, as the
      # chart's default is; `"false"` takes plaintext from pods beside TLS, and says so in
      # the log when the port starts.
      control_require_tls:
        (case System.get_env("TROUPE_PLANE_CONTROL_REQUIRE_TLS") do
           "true" -> true
           "false" -> false
           _unset -> nil
         end),
      groups_claim: System.get_env("TROUPE_GROUPS_CLAIM", "groups"),
      scim_token: presence.(System.get_env("TROUPE_SCIM_TOKEN")),
      platform_admin_group: System.get_env("TROUPE_PLATFORM_ADMIN_GROUP"),
      # The ceiling on everything this plane spends in a month, in millionths; 0 is none.
      # The deployment's, and the floor of the argument: a platform admin's own may narrow
      # it from the console and never raise it (`Troupe.Plane.PlatformBudget`).
      deployment_budget_micros:
        String.to_integer(System.get_env("TROUPE_DEPLOYMENT_BUDGET_MICROS", "0")),
      audience: System.get_env("TROUPE_PLANE_AUDIENCE", "troupe-plane-api"),
      # Spelled out rather than `String.to_existing_atom/1`: under `bin/troupe_plane eval`
      # the release boots `start_clean` in interactive mode, no application module is
      # loaded yet, and `:direct` is not an atom that exists — so every eval recipe in the
      # admin docs died in this config provider (Decision 634).
      provisioning_mode:
        (case System.get_env("TROUPE_PROVISIONING_MODE", "direct") do
           "direct" ->
             :direct

           "gitops" ->
             :gitops

           other ->
             raise ArgumentError,
                   "TROUPE_PROVISIONING_MODE must be direct or gitops, got #{inspect(other)}"
         end),
      # Where the profiles and triggers come from in gitops mode, as the console shows it
      # beside "Locked to gitops": a repository and a path. Display only; the plane never
      # reads it.
      gitops_source: presence.(System.get_env("TROUPE_GITOPS_SOURCE")),
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
        # Which claim is the person. Absent means `sub`; `oid` for Entra ID, whose `sub`
        # differs per app registration and is not what its SCIM client sends (Decision 751).
        subject_claim: presence.(System.get_env("TROUPE_OIDC_SUBJECT_CLAIM")),
        device_authorization_endpoint: oidc_required.("TROUPE_OIDC_DEVICE_URL"),
        token_endpoint: oidc_required.("TROUPE_OIDC_TOKEN_URL")
      ]

    if store = object_store.() do
      config :troupe_protocol, object_store: store
    end

    # The artifacts host (#62): where published pages are read, on a hostname that is not
    # the plane's and a port of its own (`plane.artifactsHost` in the chart). Without a
    # URL there is nowhere to open one, and `artifact.open` says so; without a port the
    # listener does not start. The same host as the plane's would put every published page
    # in the plane's origin, so a plane told that refuses to start.
    artifacts_url = presence.(System.get_env("TROUPE_ARTIFACTS_URL"))

    if artifacts_url && URI.parse(artifacts_url).host == URI.parse(base_url).host do
      raise """
      TROUPE_ARTIFACTS_URL names the plane's own host (#{URI.parse(base_url).host}).

      Artifacts run what people and agents published, so they are served from a host of
      their own, which can reach nothing of the plane's. Give them another hostname: best
      a domain of its own (artifacts.example.org beside plane.example.com), or a sibling
      of the plane's (artifacts.example.com).
      """
    end

    config :troupe_plane, :artifacts,
      url: artifacts_url,
      port:
        (case presence.(System.get_env("TROUPE_ARTIFACTS_PORT")) do
           nil -> nil
           port -> String.to_integer(port)
         end)
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

  # And the CA it trusts for the plane's certificate: the one a machine's registration
  # answered, which it pins. With one the link dials with TLS; a machine's secret is never
  # sent without it. The name the certificate must carry is the one dialled, unless the
  # machine dials through a tunnel or an address the certificate does not name.
  worker_tls = fn
    nil ->
      nil

    plane_opts ->
      plane_opts
      |> Keyword.put(:ca, presence.(System.get_env("TROUPE_PLANE_CA_PATH")))
      |> Keyword.put(:server_name, presence.(System.get_env("TROUPE_PLANE_SERVER_NAME")))
  end

  # -- a worker pod ---------------------------------------------------------

  if System.get_env("TROUPE_WORKER_AUTOSTART") == "true" do
    plane = presence.(System.get_env("TROUPE_PLANE_CONTROL"))

    # Where a session's model calls are recorded for the plane's ledger. Configured for
    # a pod and for nothing else: on a laptop there is no plane to report to, and a
    # session must behave identically with no sink at all.
    config :troupe_core, usage_sink: Troupe.Worker.Usage

    # Every command a session starts runs in the sandbox here, whatever its mounts or
    # bundle: a pod's sessions share its volume, and a namespace holding one
    # session's mounts is what keeps each from the others' files. The worker's, not a
    # setting: one that cannot start bubblewrap refuses the command rather than run it
    # outside.
    config :troupe_core, sandbox: :always

    # The fix loop's tools: a session created with a GitHub repository pushes its troupe/*
    # branch, opens its draft pull request, comments on it and reads its CI through these,
    # as the plane's App and with a token the agent's shell never holds. A session with no
    # repository is not offered them.
    config :troupe_core,
      extra_tools: [
        Troupe.Worker.Tools.GitPush,
        Troupe.Worker.Tools.PrOpen,
        Troupe.Worker.Tools.PrComment,
        Troupe.Worker.Tools.PrChecks
      ]

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
      # Who the profile is at the servers it calls with client credentials (Decision 747):
      # a file the operator mounts from a ConfigMap, read again whenever a token is asked
      # for, so a rotation reaches the pod without a restart.
      mcp_identities_path: presence.(System.get_env("TROUPE_MCP_IDENTITIES_PATH")),
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
      plane: enrolment.(plane_control.(plane)) |> worker_token.() |> worker_tls.(),
      kms: [
        address: System.get_env("TROUPE_BAO_ADDR", "http://openbao.troupe-system.svc:8200"),
        token: presence.(System.get_env("TROUPE_BAO_TOKEN")),
        mount: System.get_env("TROUPE_BAO_MOUNT", "secret"),
        # The Kubernetes-auth role this pod logs in under (Decision 753): its profile's own
        # where the installation makes one per profile, which the operator then names here,
        # and otherwise `troupe-worker`, the one role every pod shares.
        role: presence.(System.get_env("TROUPE_BAO_ROLE")) || "troupe-worker",
        # The Kubernetes-auth mount, which the operator names where the installation's is
        # not `kubernetes`, as the plane's own follows `bao.authPath`.
        auth_path: presence.(System.get_env("TROUPE_BAO_AUTH_PATH")) || "kubernetes"
      ]

    if store = object_store.() do
      config :troupe_protocol, object_store: store
    end

    # The WebSocket a client attaches through. A frame is a whole message and the socket
    # refuses one larger than this before it is assembled — a ceiling for a connection
    # that has not yet shown a token, not the protocol's message limit. The origin list
    # is for browsers: a page not on it does not get an upgrade, and empty admits no page.
    # The desktop app's own origin is admitted beside it (`Troupe.Worker.Harness`), and a
    # client that is not a browser names none. `*` admits every page.
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
