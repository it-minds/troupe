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
            # Where the CA of the plane's control certificate is, as the chart mounts it in
            # the operator: `ca.crt` alone, out of the Secret the plane serves from, and never
            # its key. Set, every worker namespace is given that CA and every pod dials the
            # control port with TLS against it, checking the name it dials; unset, pods dial
            # in plaintext, as they did before.
            plane_ca_path: nil,
            # What that file holds, read again on every pass (`with_plane_ca/1`), so a CA
            # cert-manager renews reaches the worker namespaces at the next one.
            plane_ca: nil,
            bao_address: "http://openbao.troupe-system.svc:8200",
            # Whether the installation made an OpenBao role per profile (Decision 753).
            # Then each profile's pods log in as `troupe-worker-<profile>`, the role its
            # own policy is bound to; otherwise every pod logs in as `troupe-worker`.
            bao_role_per_profile: false,
            object_store_endpoint: "http://minio.troupe-system.svc:9000",
            object_store_bucket: "troupe-sessions",
            # The region every signature over that bucket claims. It matters even
            # where the endpoint already names the region: SigV4 signs the region
            # string, so a pod that says `us-east-1` to a bucket in `eu-west-1` is
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
            # The seccomp profile on every worker container: `"Localhost"`, with the path
            # of the profile under the kubelet's seccomp directory, `"RuntimeDefault"` or
            # `"Unconfined"`. Every command on a pod runs in bubblewrap, which builds its
            # sandbox from a user namespace, and a container runtime's default profile
            # refuses one: under it a pod refuses every command. The chart ships a profile
            # that is the runtime's default plus what bubblewrap needs, and sets it here;
            # without the chart this stays on the runtime's default, which keeps a filter
            # and refuses rather than runs.
            worker_seccomp_type: "RuntimeDefault",
            worker_seccomp_profile: nil,
            # The name of the AppArmor profile, loaded on the nodes, that every worker
            # container runs under (`Localhost`), or nil for the runtime's default. Where a
            # node enforces AppArmor, the runtime's default profile refuses the mounts
            # bubblewrap builds its sandbox with, and with no profile at all a kernel that
            # restricts unprivileged user namespaces refuses the sandbox's uid map: under
            # either a pod refuses every command. The chart ships a profile that allows the
            # sandbox and loads it, and names it here; never `Unconfined`.
            worker_apparmor_profile: nil,
            # Whether a worker pod runs in a user namespace of its own (`hostUsers: false`)
            # with its `/proc` unmasked (`procMount: Unmasked`). Bubblewrap mounts a fresh
            # `/proc` for the sandbox, and the kernel refuses that inside a user namespace
            # while the container's own `/proc` has paths masked over; Kubernetes unmasks it
            # only for a pod in a user namespace, where the container's root is nobody on
            # the node. The chart turns it on; off, a pod refuses every command, as it
            # always did.
            worker_user_namespaces: false,
            cilium_available: false,
            drain_timeout_seconds: 300

  @type t :: %__MODULE__{}

  @doc "Settings from application configuration, which Helm renders into the operator's env."
  @spec from_env() :: t()
  def from_env do
    config = Application.get_env(:troupe_operator, :settings, [])
    struct(__MODULE__, config)
  end

  @doc """
  These settings with the plane's CA as it is now, read from `plane_ca_path`: the
  certificates in the file, written out again on their own, so whatever else the file
  might hold, a key above all, never reaches a worker namespace. `nil` where there is no
  path, or no certificate in the file yet, as before cert-manager has issued one.
  """
  @spec with_plane_ca(t()) :: t()
  def with_plane_ca(%__MODULE__{plane_ca_path: nil} = settings), do: %{settings | plane_ca: nil}

  def with_plane_ca(%__MODULE__{plane_ca_path: path} = settings) do
    certificates =
      case File.read(path) do
        {:ok, pem} ->
          for {:Certificate, _der, :not_encrypted} = entry <- :public_key.pem_decode(pem),
              do: entry

        {:error, _reason} ->
          []
      end

    case certificates do
      [] -> %{settings | plane_ca: nil}
      certificates -> %{settings | plane_ca: :public_key.pem_encode(certificates)}
    end
  end

  @doc """
  The worker container's `seccompProfile`, as these settings name it.

  A type that is none of the three, or a `Localhost` profile without its path, is raised
  rather than read as something else: the pods it would make are refused by the API server
  or the kubelet, which says so only in an event on the StatefulSet. `config/runtime.exs`
  refuses both when the operator starts.
  """
  @spec worker_seccomp(t()) :: map()
  def worker_seccomp(%__MODULE__{worker_seccomp_type: "Localhost", worker_seccomp_profile: path})
      when is_binary(path) and path != "",
      do: %{"type" => "Localhost", "localhostProfile" => path}

  def worker_seccomp(%__MODULE__{worker_seccomp_type: type})
      when type in ["RuntimeDefault", "Unconfined"],
      do: %{"type" => type}

  def worker_seccomp(%__MODULE__{worker_seccomp_type: type}) do
    raise ArgumentError,
          "the worker's seccomp profile #{inspect(type)} is not Localhost with a path, " <>
            "RuntimeDefault or Unconfined"
  end

  @doc """
  The worker container's `appArmorProfile`, as these settings name it: the named profile
  as `Localhost`, or nil, which leaves the field off and the container on the runtime's
  default. Never `Unconfined`: a name is all these settings hold.
  """
  @spec worker_apparmor(t()) :: map() | nil
  def worker_apparmor(%__MODULE__{worker_apparmor_profile: name})
      when is_binary(name) and name != "",
      do: %{"type" => "Localhost", "localhostProfile" => name}

  def worker_apparmor(%__MODULE__{}), do: nil
end
