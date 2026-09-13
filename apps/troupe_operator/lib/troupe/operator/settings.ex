defmodule Troupe.Operator.Settings do
  @moduledoc """
  What the operator knows about the cluster it is running in.

  Everything here comes from Helm values rather than from a `WorkerProfile`, because it
  is true of the installation and not of any one pool of workers: where the plane
  listens, where OpenBao is, which ingress class to use. A profile that could set these
  could point its workers at another installation's plane.
  """

  defstruct plane_control_host: "troupe-plane-control.troupe-system.svc",
            plane_control_port: 4001,
            plane_namespace: "troupe-system",
            bao_address: "http://openbao.troupe-system.svc:8200",
            object_store_endpoint: "http://minio.troupe-system.svc:9000",
            object_store_bucket: "troupe-sessions",
            # The region every signature over that bucket claims. It matters even
            # where the endpoint already names the region: SigV4 signs the region
            # string, so a pod that says `us-east-1` to a bucket in `fr-par` is
            # refused by a provider that checks. The plane has always been given
            # this; the pods, which write far more of a session's log than the
            # plane ever does, were left on the default.
            object_store_region: "us-east-1",
            ingress_class_name: "nginx",
            tls_secret_name: nil,
            # A cert-manager ClusterIssuer, where the deployment has one. Then every pod
            # gets its own certificate for its own hostname over HTTP-01, and
            # `tls_secret_name` is not read at all.
            #
            # What that replaces is one wildcard certificate for `*.workers.<domain>`,
            # which is fewer certificates and one more dependency: a wildcard can only be
            # issued over DNS-01, DNS-01 needs an API token for whoever hosts the zone,
            # and most registrars have no cert-manager solver at all. A hostname that
            # already resolves to the ingress controller can always answer HTTP-01, so
            # this works on any DNS host and the wildcard does not.
            cert_issuer: nil,
            # How a pod is actually reached, which it tells the plane when it enrols and
            # the plane hands to clients. `wss` on 443 is the deployment this is built
            # for; a cluster reached through a port mapping says so here rather than
            # every client guessing.
            # The BEAM's port table is sized from `RLIMIT_NOFILE` unless `+Q` says
            # otherwise, and a container runtime's default makes that 1.5GB.
            max_ports: 65_536,
            # The secret a pod reads its object-store credentials from, in the pod's own
            # namespace. Troupe creates no secrets; this names the one somebody else put
            # there, the same way a profile names its LLM secret.
            object_store_secret_name: "troupe-object-store",
            workers_scheme: "wss",
            workers_port: nil,
            # The pull secrets, by name, put on every worker pod. The same names the chart
            # puts on the plane and the operator: a registry that needs a credential to
            # pull one image needs it for all three, and the secret has to exist in each
            # worker namespace, which — like the object-store secret — is somebody else's
            # job on purpose.
            image_pull_secrets: [],
            # The browser origins a worker admits on its WebSocket, passed to every pod
            # as `TROUPE_ALLOWED_ORIGINS`. Empty admits every origin — the token is what
            # actually admits a connection — and an installation that knows which origins
            # host its GUI names them once, here, rather than in every profile.
            worker_allowed_origins: [],
            cilium_available: false,
            drain_timeout_seconds: 300

  @type t :: %__MODULE__{}

  @doc "Settings from application configuration, which Helm renders into the operator's env."
  @spec from_env() :: t()
  def from_env do
    config = Application.get_env(:troupe_operator, :settings, [])
    struct(__MODULE__, config)
  end
end
