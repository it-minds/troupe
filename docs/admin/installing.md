# Installing Troupe on a cluster that has nothing on it

For a Kubernetes cluster and nothing else: no CNI that enforces policy, no ingress, no
database, no object store, no key manager, no identity provider. On a laptop,
`scripts/remote-up` does all of this into kind and prints where everything is; it is the
same steps automated for one target, kept working by `mix troupe.e2e`. On a managed
cluster with a cloud's services beside it, [section 6](#6-a-worked-example-on-managed-services)
is a worked example.

## 0. Before the first command

| | why | without it |
| --- | --- | --- |
| Kubernetes ≥ 1.30 | `ValidatingAdmissionPolicy` | the operator still refuses a bad profile; the cluster no longer does |
| `kubectl`, `helm` | everything below | — |
| A CNI that enforces NetworkPolicy | a worker's isolation is a NetworkPolicy | **policies are accepted and enforced by nothing** (kind's default CNI) |
| Cilium, optionally | egress by hostname: a worker reaches its allowlist and nothing else | a worker reaches any public host on 443 and 80; the allowlist is checked at admission, not on the wire; a profile's own endpoint on another port, or given as an address, opens that port or that address; one at a loopback, unspecified, link-local or cloud metadata address is refused, as it is with Cilium |
| An ingress controller | how a client reaches a worker | sessions are created and cannot be attached to from outside |
| Nodes that allow unprivileged user namespaces, and the chart's seccomp profile on them | every command on a pod runs in bubblewrap, which builds its sandbox from a user namespace ([below](#the-workers-seccomp-profile)) | a pod refuses every command, saying bubblewrap could not start |
| Kubernetes ≥ 1.33, containerd ≥ 2.0 (runc ≥ 1.2), Linux ≥ 6.3, storage that takes idmapped mounts, `privileged` Pod Security in worker namespaces | each worker pod runs in a user namespace of its own with its `/proc` unmasked, which bubblewrap's own `/proc` needs ([below](#the-workers-user-namespaces)) | a worker pod is refused or does not start; with `worker.userNamespaces: false` it starts and refuses every command |

Label the ingress controller's namespace, or every worker drops its traffic:

```bash
kubectl label namespace ingress-nginx troupe.dev/ingress=true
```

## 1. What Troupe does not run for you

The chart installs none of these, deliberately: each is something an organisation already
has opinions about. `dev/kind/dependencies.yaml` installs a development-grade one of each —
read it as a worked example, not a production install.

- **PostgreSQL**: one database and a role that owns it. A Helm hook Job migrates it.
- **An object store**: one bucket, **with versioning on** — the one requirement here that
  is not a preference, because erasure destroys prior versions.
- **OpenBao** (or Vault): a transit mount for signing, a KV v2 mount, and a Kubernetes
  auth role or a token. A plane with neither fails to sign and says so.
- **An identity provider**: any OIDC provider that issues a group claim and the device
  grant. Troupe assigns no roles of its own; a platform admin is a member of a group you
  name. Requirements in detail: [integrations.md](integrations.md).

Create the Secrets the chart expects before installing ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)).

## 2. CRDs, then the chart

```bash
version=0.15.0-beta     # a release: https://github.com/it-minds/troupe/releases
chart=oci://ghcr.io/it-minds/charts/troupe
helm show crds "$chart" --version "$version" | kubectl apply --server-side -f -
helm upgrade --install troupe "$chart" --version "$version" \
  --namespace troupe-system --create-namespace --values my-values.yaml
```

Every release publishes the chart twice, as `oci://ghcr.io/it-minds/charts/troupe` and as
`troupe-<version>.tgz` on its release page, and either works as `$chart`; so does
`charts/troupe` in a checkout of the release's tag. The chart's image tags default to its
version, and the images it names are public on `ghcr.io/it-minds` (`troupe-plane`,
`troupe-operator`, `troupe-worker`, `troupe-a2a`, `troupe-gui`), so nothing needs a pull
secret. A cluster that pulls through a registry of its own copies them there and sets
each `*.image.repository`, `policy.allowedImageRepositories` and `imagePullSecrets`.

The chart makes `troupe-system` itself unless `createNamespace: false`. Where the namespace
is there before the chart (made for the Secrets of section 1, or for OpenBao), set it
false: Helm does not take over a namespace it did not make, and the install stops, saying
the namespace exists and is not the release's. Either way, uninstalling leaves the
namespace and everything in it ([section 7](#7-uninstalling)).

`WorkerProfile`, `TroupePolicy`, `TeamVolume` and `Trigger` go first because Helm does not
upgrade CRDs it installed. Start from `values.small.yaml` or `values.example.yaml`; what you cannot
leave unset:

```yaml
plane:
  host: troupe.example.com
  baseUrl: https://troupe.example.com   # where a client reaches this plane
  platformAdminGroup: <group id>        # whose members administer this
  oidc:
    issuer: https://login.example.com
    clientId: troupe
    deviceUrl: https://login.example.com/device
    tokenUrl: https://login.example.com/token
    secretName: troupe-plane-oidc       # for console sign-in
objectStore:
  endpoint: https://s3.example.com
  bucket: troupe-sessions
bao:
  address: https://bao.example.com
policy:
  workersDomain: workers.example.com    # where a worker pod is reached
  allowedEgress: ["*.anthropic.com", api.openai.com, github.com]
```

The database URL is the `troupe-plane-database` Secret. [../egress-allowlist.md](../egress-allowlist.md)
is generated from what each component declares it dials: read it before narrowing
`allowedEgress`, because a host the code needs and the policy refuses is a tool that fails
the first time somebody uses it.

### The workers' seccomp profile

Every command a session runs on a pod runs in bubblewrap, which builds its sandbox from an
unprivileged user namespace. A container runtime's default seccomp profile refuses one, so
a worker under it refuses every command ("bubblewrap could not start one here (bwrap: No
permissions to create new namespace ...)"). `worker.seccomp` chooses the worker
container's profile, and the default needs nothing from you:

```yaml
worker:
  seccomp:
    type: Localhost                       # or RuntimeDefault, or Unconfined
    localhostProfile: troupe/worker.json  # under the kubelet's seccomp directory
    install:
      enabled: true                       # the DaemonSet below
      kubeletSeccompDir: /var/lib/kubelet/seccomp
```

- **`Localhost`**, the default, is the profile the chart ships: the runtime's default plus
  the calls bubblewrap makes its user, mount and PID namespaces with, and never a network,
  cgroup or time namespace ([security.md §3](security.md#3-a-worker-isolation-and-egress)
  says what it allows and why). The kubelet reads it from the node, so it must be on every
  node that runs workers. The chart's DaemonSet `troupe-worker-seccomp` puts it there: one
  pod per node copies it from a ConfigMap and waits, ready while the file is in place. It
  mounts that one directory from the host (`/var/lib/kubelet/seccomp/troupe`) and nothing
  else, and runs as root with every capability dropped, because the directory is root's,
  so **`troupe-system` needs the `privileged` Pod Security level** for it. Where the
  kubelet runs with another `--root-dir`, set `kubeletSeccompDir` to `<root-dir>/seccomp`.
  A worker pod that reaches a node before the file waits in `CreateContainerError`
  ("cannot load seccomp profile") and starts once it is there:
  `kubectl -n troupe-system rollout status daemonset/troupe-worker-seccomp`.
- **With the Security Profiles Operator**, or nodes built with the file, set
  `install.enabled: false` and point `localhostProfile` at where it is. For the operator,
  apply a `SeccompProfile` in `troupe-system` whose spec is the rules of
  `charts/troupe/files/worker-seccomp.json` (`defaultAction`, `architectures`, `syscalls`),
  and set `localhostProfile: operator/troupe-system/<its name>.json`.
- **`RuntimeDefault`** keeps the runtime's own profile: workers start and run no command.
- **`Unconfined`** is no filter at all, for a development cluster (`dev/kind/values.yaml`).
  The `baseline` and `restricted` Pod Security levels refuse it.

### The workers' user namespaces

The profile is not all bubblewrap needs. It also mounts a fresh `/proc` for the sandbox,
and a container runtime masks paths under a container's own `/proc` (`/proc/kcore` and
others mounted over, `/proc/sys` read-only); the kernel refuses a new proc mount in a user
namespace while those hide part of the old one ("bwrap: Can't mount proc on /newroot/proc:
Operation not permitted"). Kubernetes unmasks a container's `/proc` only for a pod in a user
namespace of its own, so with `worker.userNamespaces: true`, the default, every worker pod
gets `hostUsers: false` and its worker container `procMount: Unmasked`, always together. The
container's root, and every other user in it, is then an unprivileged user on the node.

What the cluster needs for it:

| | |
| --- | --- |
| Kubernetes | 1.33 or later, where user namespaces are on by default |
| Container runtime | containerd 2.0 or later with runc 1.2 or later (CRI-O 1.25 or later with crun or runc should do; not tried) |
| Nodes | Linux 6.3 or later: the projected tokens and ConfigMaps are tmpfs, and idmapped tmpfs came in 6.3 |
| Storage | filesystems that take idmapped mounts. A block volume with ext4 or xfs does, and so do kind's and `local-path`'s directories. **NFS does not, and most RWX file storage is NFS**: a team volume there is expected to keep its pod in `ContainerCreating` or `CreateContainerError`, with the idmapped mount refused in the pod's events (not tried here) |
| Pod Security | `privileged` in the worker namespaces: `baseline` and `restricted` refuse `procMount: Unmasked` even in a user namespace, and every worker pod is then refused at creation, in a `FailedCreate` event on its StatefulSet. The operator labels no worker namespace, so they have the cluster's default level; label each `troupe-w-<profile>` where that default is higher |

A cluster that cannot have them sets `worker.userNamespaces: false`. Its workers start and
refuse every command, with bubblewrap's `/proc` sentence, until it can: a pod never runs a
command outside the sandbox.

**Check your cluster** before installing, with no secret and nothing of Troupe's but the
worker image. This makes a namespace, a volume on the storage class your profiles use, and
one pod as a worker pod would be, then runs a sandbox the way a worker does:

```bash
kubectl version | grep Server                    # 1.33 or later
kubectl get nodes -o custom-columns=NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion
kubectl create namespace troupe-check
kubectl label namespace troupe-check pod-security.kubernetes.io/enforce=privileged
kubectl apply -n troupe-check -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]       # ReadWriteMany and the class your team volumes use, to check those
  storageClassName: standard         # the class your profiles name
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: worker-check}
spec:
  hostUsers: false
  securityContext: {runAsNonRoot: true, runAsUser: 1000, fsGroup: 1000}
  containers:
    - name: worker
      image: ghcr.io/it-minds/troupe-worker:0.17.0-beta   # the release you install
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: {drop: ["ALL"]}
        seccompProfile: {type: Localhost, localhostProfile: troupe/worker.json}  # once the chart's DaemonSet has run; else Unconfined, for the check only
        procMount: Unmasked
      volumeMounts: [{name: data, mountPath: /var/lib/troupe}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: data}}]
YAML
kubectl -n troupe-check wait --for=condition=Ready pod/worker-check --timeout=120s
kubectl -n troupe-check exec worker-check -- sh -c '
  head -1 /proc/self/uid_map                     # not "0 0 4294967295"
  grep -c " /proc/" /proc/self/mountinfo         # 0: nothing masked
  touch /var/lib/troupe/ok && echo volume ok
  bwrap --unshare-pid --proc /proc --dev /dev --ro-bind /usr /usr --symlink usr/bin /bin \
    --symlink usr/lib /lib --symlink usr/lib64 /lib64 -- /bin/sh -c "cat /proc/1/comm"'   # bwrap
kubectl delete namespace troupe-check
```

A pod that never becomes ready says why in `kubectl -n troupe-check describe pod
worker-check`: `hostUsers` dropped or refused (Kubernetes or the runtime too old), an
idmapped mount refused (the storage), or the seccomp profile missing from the node.

## 3. Prove it is up

```bash
kubectl -n troupe-system get pods
curl -sS https://troupe.example.com/healthz
curl -sS https://troupe.example.com/.well-known/troupe | jq .plane.build
```

The build names the commit, time and version; if it is not what you deployed, the rollout
has not finished or the tag did not move.

Besides the API, the plane's host serves `/`, the page a person gets when they are handed
the URL, which says what this host is and the ways in; `/docs`, the concepts; `/admin`, the
console; and `/healthz`, for Kubernetes. `plane.appUrl` says where the graphical client is
(the chart's own at `/app` by default; a team with its own client sets `gui.enabled: false`
and points it there), and `plane.cliUrl` where the terminal client is published (empty,
the page says to ask an administrator).

## 4. The first administrator

Sign in at `https://troupe.example.com/admin`. You are a platform admin because you are in
the group `platformAdminGroup` names, so **a wrong group locks everybody out, including
you**. The console checks a group before saving it — how many people would administer the
platform afterwards, and whether you are one — and `TROUPE_BREAKGLASS_TOKEN`, if you set
one, opens `/admin/breakglass` ([roles-and-permissions.md §4](roles-and-permissions.md#4-break-glass)).

## 5. The rest is the console

`Troupe.Plane.ConsoleWalkthroughTest` drives this sequence on every build:

1. **Identity**: check the admin group.
2. **Policy**: save it, and the ceilings every team inherits.
3. **Teams**: turn a provider group into a team.
4. **Workers**, *New profile*: write a worker profile.
5. **Bundles**: publish what a session on it gets, reading the diff first.
6. **Teams**: grant the profile to the team.
7. **Identity**: a service principal for work nobody starts by hand.
8. **Triggers**: a schedule that fires as it.
9. **Budgets**: which ceiling would refuse, and for whom.

No `kubectl`, environment variable or database write in any of them, and every step is in
the audit trail with a diff. Then create the worker namespace's Secrets (object store, the
model key, pull secrets) and watch `kubectl -n troupe-system get wp -w`.

### The clients people install

People install `troupe` and the desktop app from the release page with the release's
installers ([quick start](../quick-start.md#1-install)), or from where `plane.cliUrl`
points. The apps carry no Apple or Microsoft signature yet (#656), so the first time:

- **macOS** refuses an app downloaded in a browser: **System Settings → Privacy &
  Security**, then **Open Anyway** beside the message about Troupe. `install.sh` downloads
  with `curl`, which Gatekeeper does not stop.
- **Windows** SmartScreen says "Windows protected your PC" for a setup downloaded in a
  browser: **More info**, then **Run anyway**, or `Unblock-File` on it first. `install.ps1`
  downloads with `Invoke-WebRequest`, which SmartScreen rarely stops.

Why that is safe, and how to check a first download against the release key:
[security.md §6](security.md#6-the-apps-are-not-os-code-signed). From then on `troupe
update` and the desktop app check every update against that key themselves, and follow the
versions the Policy page sets ([routine-tasks.md](routine-tasks.md#client-versions)).

## 6. A worked example on managed services

`charts/troupe/values.example.yaml` is this page on a managed Kubernetes cluster, with
every value that has to be yours marked `CHANGE ME`. It assumes this shape:

| Need | How | Why |
| --- | --- | --- |
| Kubernetes | a managed cluster, with Cilium as its CNI where that is offered | with Cilium the operator writes FQDN egress rules per profile; without it, egress to a named host is a wide CIDR rule |
| PostgreSQL | the provider's managed PostgreSQL, point-in-time recovery on | the session index, ledger, audit trail and identity mirror |
| Sealed session data | an S3-compatible object store, versioning **on** | erasure needs versioning |
| Worker disks | a block-storage class, `ReadWriteOnce` | one volume per pod |
| Team volumes | a file-storage class, `ReadWriteMany` | the only thing that needs it |
| Images | `ghcr.io/it-minds/troupe-*`, public | a mirror of your own names a pull secret |
| Ingress and TLS | ingress-nginx behind the provider's load balancer, and cert-manager | in the cluster |
| Keys | OpenBao, in the cluster | below |
| Identity | your existing provider | [integrations.md §1](integrations.md#1-identity-provider-oidc) |
| Models | your gateway, or the providers' own hosts | named in `policy.allowedEgress` |

**Two DNS names**, both pointing at the load balancer: the plane's (`troupe.example.com`)
and a wildcard for `*.workers.example.com`, because a client dials each pod directly at
`<ordinal>-<profile>.workers.<domain>`. The hyphen is what lets one wildcard record cover
every profile.

**ingress-nginx** needs longer timeouts and a larger body than its defaults, set in its
chart's values:

```yaml
controller:
  config:
    proxy-read-timeout: "3600"   # a session is a WebSocket, idle while a model thinks
    proxy-send-timeout: "3600"
    proxy-body-size: 16m         # the protocol's frame cap, so the worker refuses, not the proxy
```

Where the load balancer can send PROXY protocol, turn it on at both ends
(`use-proxy-protocol: "true"` here, and the provider's own annotation on the controller's
Service): without it every request arrives from the balancer's address, and the plane's
per-client rate limit becomes one bucket for everybody. Then label the controller's
namespace, as in section 0.

**cert-manager** issues every certificate from one ClusterIssuer, the `letsencrypt` both
`certIssuer` values in the example name:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com     # CHANGE ME
    privateKeySecretRef:
      name: letsencrypt-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

HTTP-01 needs no API token for whoever hosts the zone, so it works on any DNS host. It
costs one ACME order per pod hostname, against Let's Encrypt's fifty certificates per
registered domain per week; at a size where that matters, a wildcard in
`operator.tlsSecretName`, issued over DNS-01, is the answer.

**OpenBao stays yours.** Troupe needs KV v2 and a transit engine, which a cloud's key
manager rarely is, and OpenBao auto-unseals only through a few cloud KMS APIs or another
transit engine. One replica with Raft storage is enough: there is no quorum to lose, a
restart is a window in which no session can be *opened*, and live sessions keep their
keys in memory. Without a KMS it can use, the seal is Shamir and something has to unseal
it after every restart: a person, or a share kept in a Secret, which protects a stolen
volume and not against a cluster admin. Set `server.enableServiceLinks: false` in its
chart, so the `<SERVICE>_PORT` variables Kubernetes injects cannot collide with its own.
Then the transit key, Kubernetes auth with a reviewer JWT, and the two roles of
[integrations.md §2](integrations.md#2-openbao); `dev/kind/dependencies.yaml` has them as
working commands, in development shape.

**Every worker namespace** the operator creates needs its own copies: the object-store
Secret, the pull secret if there is one, the profile's model key (`llm.secretRef`, key
`api-key`) and `troupe-mcp-<server>` for every bundle MCP server with a `credential_ref`.
External Secrets Operator is how none is forgotten on a new profile.

**Sizing.** Sessions per pod sizes everything: a pod holds a process tree per *active*
session and nothing per dormant one. The example's plane is two replicas at 1 vCPU and
1 GiB each. `values.small.yaml` fits two nodes of about 3 vCPU and 4 GB: the plane, the
operator, OpenBao, ingress-nginx and cert-manager take about a node and a half at their
requests, and 2 GB nodes leave workers `Pending` without saying why.

**Not covered by CI.** The chart runs on kind there, not on a cloud's network, storage or
load balancer. Every worker pod is internet-facing by design, protected by a pod-bound
token, the ACL and the NetworkPolicy; a load-balancer ACL or a VPN in front of `*.workers`
deserves a look before production. The PITR drill (`scripts/pitr-drill`) is a script, not
a schedule.

After the first install, an upgrade is [routine-tasks.md](routine-tasks.md#upgrade).

## 7. Uninstalling

`helm uninstall troupe -n troupe-system` takes away the plane, the operator and the rest of
what the chart rendered, and leaves on purpose:

- **The namespace and everything else in it**: OpenBao, the Secrets, volume claims, the
  `WorkerProfile` resources. The chart marks the namespace `helm.sh/resource-policy: keep`,
  so neither an uninstall nor a GitOps controller's remediation that uninstalls takes the
  rest with it; one made with `createNamespace: false` was never the chart's to delete.
- **The CRDs**, which Helm never deletes, and the `TroupePolicy`, which is also marked keep.
- **The workers**: their namespaces are the operator's, and with the operator gone nothing
  removes them.

To take everything away, [decommission each profile](routine-tasks.md#decommission-a-profile)
while the operator still runs, which removes its namespace, then uninstall, look at what is
left (`kubectl -n troupe-system get all,secrets,pvc`), and `kubectl delete namespace
troupe-system`. The database and the bucket are yours and are not touched.

The keep is in the chart from 0.7.1. An install from an older chart gets it at its first
upgrade, and loses it again if rolled back to a revision from before.
