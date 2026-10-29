# Worker profiles, policy and team volumes

A **profile** is one pool of workers: image, size, model endpoint, egress, bundle channel.
It exists twice: as a row in the plane's `profiles` table (what an admin asked for) and as
a `WorkerProfile` custom resource in `troupe-system` (what the operator reconciles). A
**TroupePolicy** is the cluster admin's ceiling on what any profile may ask for. A
**TeamVolume** declares a team's shared storage.

## 1. What an administrator sets

`admin.profile.put` takes the whole profile: read it with `admin.profile.get` and send it
back changed. `admin.profile.preview` returns the policy verdict and the diff without
writing, and the console's profile editor shows both before its apply button. In gitops
mode a repository holds the profiles, with the same fields in a manifest
([§6](#6-provisioning-direct-or-from-a-repository)).

| Field | Meaning |
|---|---|
| `name` | the profile, and the name of its `WorkerProfile` |
| `extends` | the one profile this one extends, or none ([a profile's options](profile-options.md#a-profile-that-extends-another)) |
| `image` | `repository:tag`, `repository@sha256:…`, or `release` (below) |
| `size_class` | `standard` (several sessions share a worker) or `heavy` (fewer, each with more CPU, memory and disk). A resource question, not a safety one: sessions cannot see each other's files either way |
| `max_sessions` | how far it may grow, in sessions at once. Absent is no ceiling but the team's budget |
| `budget_micros` | what its sessions may spend in a calendar month (UTC), in millionths of a dollar, whoever starts them and in whichever team ([bundles-and-triggers.md §4](bundles-and-triggers.md#4-budgets)). Absent or `0` is none |
| `warm_workers` | workers kept up when nothing runs. `0` scales to zero, and the next session waits about half a minute |
| `spec` | the rest of the resource, in its own camelCase (the next table) |

`replicas`, `sessionsPerPod`, `resources` and `storage.size` are the plane's: it writes them
from the size class and the load, and **refuses** a request that sends them. Every fifteen
seconds it sets replicas to `ceil((active + pending) / sessionsPerPod) + warm_workers`,
clamped to `max_sessions`; a profile idle for two minutes goes to its warm count. A lower
count drains the pods it removes first ([§3](#3-upgrades-and-drains)).

**`"image": "release"`** is the worker image of the release the plane runs
(`worker.image.*` in the chart). The row keeps the word and the plane resolves it at every
render; at start it rewrites every such profile whose resource carries another image,
audited as `profile.put` by `system:release`. Pods move only when they are recreated (§3).
`policy.allowedImageRepositories` must allow `worker.image.repository`. Direct mode only: in
gitops mode a manifest names its image, and a release reaches the workers with a commit.

| `spec` field | Meaning |
|---|---|
| `llm.endpoint`, `.provider`, `.model` | the worker's `TROUPE_BASE_URL`, `TROUPE_PROVIDER` (one of the [provider types](../user/configuration.md#provider-types); absent is `openai`, Chat Completions, which a gateway serves) and `TROUPE_MODEL`. The endpoint's host is an egress destination. Every other `llm` field needs `llm.endpoint`, because the pods are given the `llm` settings only with one: the plane and the resource's schema refuse a profile that sets any without it, naming them |
| `llm.secretRef.{name,key}` | the Secret injected as `TROUPE_API_KEY` (key `api-key`); not optional. Kept in `troupe-system` labelled `troupe.dev/worker-secret=true`, it is copied into the worker namespace ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)) |
| `llm.prices` | dollars per million tokens by model, `{"qwen3-235b": {"input": …, "output": …}}` with optional `cacheRead` and `cacheWrite`, injected as `TROUPE_MODEL_PRICES`, for models the gateway does not price (with LiteLLM, every streamed call). An unpriced call costs nothing on the ledger and no money budget applies to it; the gateway's price wins where it gives one. Set through the API: the console's editor keeps it but does not show it |
| `egress.fqdns`, `egress.gitHosts` | extra hosts the pods may reach, each matching a policy pattern. A wildcard is one leading label (`*.example.com`) and passes only a policy holding that same wildcard; any other star, a bare `*` included, is refused by name ([§4](#4-troupepolicy)) |
| `storage.storageClassName` | the class a worker's disk comes from, one `allowedStorageClasses` names; absent is the cluster's default |
| `configBundleChannel` | the bundle channel the profile follows (`stable`) |
| `orgMount` | mount the policy's org volume at `/mnt/org`, always read-only |
| `repositoryOverridesBundle` | `true` lets a working copy's agents and skills replace the bundle's, and Troupe's built-in agents, of the same name ([a profile's options](profile-options.md#a-repositorys-agents-and-skills-on-a-pod)) |
| `personalTools` | `allow` (the default) or `forbid`: whether a person may offer a session on these pods the tools of MCP servers they signed in to on their own machine ([a profile's options](profile-options.md#a-persons-own-tools-on-a-pod)) |
| `permissions` | per-tool `deny`, `ask` and `allow` rules every session on these pods obeys ([a profile's options](profile-options.md#per-tool-rules-on-a-profile)) |
| `agents` | which agents exist on these pods, built-ins included: `allow` and `deny` lists of names, a grant narrowing only what they leave ([a profile's options](profile-options.md#which-agents-a-profile-has)) |
| `github.*` | what a session's token may do on GitHub beyond cloning (`permissions`, [github.md §5](github.md#5-let-a-profile-reach-github)) and how far the fix loop goes (`allowPublic`, `denyPaths`, `maxPushes`, `maxRuns`, `maxAttempts`, [github.md §9](github.md#9-how-far-a-run-may-go)) |
| `mcpIdentities` | who the profile is at each MCP server its bundle calls with client credentials ([a profile's options](profile-options.md#calling-an-mcp-server-as-the-profile)). Yours to write in direct and gitops mode alike; nothing in it is secret |
| `mcpServers` | MCP servers the profile adds to its bundle's (Decision 910). The resource's list, which its pods load, is its channel's bundle's with these added by name; one named like a bundle server replaces it only with `"override": true`. A publish to the channel composes the two again and keeps the profile's own. `admin.profile.get` answers the own ones in `spec`, and a put that sends back the resource's whole list has the bundle's dropped |
| `teams` | **written by the plane** from grants; do not set it |

A profile's `provisioner` decides who makes its workers exist: `kubernetes` (the default,
the operator) or `ssh`, machines that register themselves ([single-machine.md](single-machine.md)).
An `ssh` profile has no pods: in direct mode the plane writes it no `WorkerProfile` and
removes one left from before; in gitops mode, where the repository holds it as a
`WorkerProfile` like any other, the plane writes `spec.replicas: 0` onto it.

The rest of what a profile can say is on a page of its own, [a profile's
options](profile-options.md):

- <a id="a-profile-that-extends-another"></a>[A profile that extends another](profile-options.md#a-profile-that-extends-another):
  one standard profile, and a team's that says only what differs; what a child inherits,
  adds or may only narrow.
- <a id="calling-an-mcp-server-as-the-profile"></a>[Calling an MCP server as the profile](profile-options.md#calling-an-mcp-server-as-the-profile):
  `mcpIdentities`, an OAuth client of the profile's own whose assertion OpenBao transit
  signs; setting one up, rotating it, and what is reported.
- <a id="a-repositorys-agents-and-skills-on-a-pod"></a>[A repository's agents and skills on a pod](profile-options.md#a-repositorys-agents-and-skills-on-a-pod):
  the bundle's and the built-ins beat a working copy's of the same name unless
  `repositoryOverridesBundle` is `true`.
- <a id="a-persons-own-tools-on-a-pod"></a>[A person's own tools on a pod](profile-options.md#a-persons-own-tools-on-a-pod):
  `personalTools: forbid` refuses the tools a person offers from their own machine.
- <a id="per-tool-rules-on-a-profile"></a>[Per-tool rules on a profile](profile-options.md#per-tool-rules-on-a-profile):
  `permissions`, the `deny`, `ask` and `allow` rules every session on the pods obeys.
- <a id="which-agents-a-profile-has"></a>[Which agents a profile has](profile-options.md#which-agents-a-profile-has):
  `agents`, the `allow` and `deny` lists of names that say which agents exist on the pods.

## 2. What the operator creates

`Troupe.Operator.Resources.for_profile/3` is a pure function from profile, policy and
settings to manifests. For profile `p` the namespace is `troupe-w-p`, holding: the
ServiceAccount `troupe-worker` (no automounted token); a PVC per granted team that has a
volume storage class (`troupe-team-<team>`, `ReadWriteMany` for `rw`, `ReadOnlyMany` for
`ro`) and one for the org volume; a headless Service and one Service and Ingress per pod
(host `<ordinal>-p.<workersDomain>`); a NetworkPolicy, and a `CiliumNetworkPolicy` when
Cilium is available; a PodDisruptionBudget (`maxUnavailable: 1`); and a StatefulSet with
`podManagementPolicy: Parallel`, `updateStrategy: OnDelete` and a `ReadWriteOnce` data
volume per pod. A profile with `mcpIdentities` also gets the ConfigMap
`troupe-mcp-identities`, mounted as a directory at `/etc/troupe/mcp-identities` and named in
`TROUPE_MCP_IDENTITIES_PATH`: the kubelet replaces the file in place when the profile
changes, so a new identity or a rotation reaches running pods without a new revision. And
the Secrets its pods mount, copied from `troupe-system` by `Troupe.Operator.WorkerSecrets`
([configuration.md](configuration.md#a-worker-namespaces-secrets)).

The pod runs as non-root uid 1000 with seccomp `RuntimeDefault`, by default in a user
namespace of its own (`hostUsers: false`); its worker container has the installation's
`worker.seccomp` and `worker.appArmor` profiles and, in that user namespace, an unmasked
`/proc`, which together let bubblewrap start
([worker-sandbox.md](worker-sandbox.md#the-workers-seccomp-profile)). Every capability is dropped,
`enableServiceLinks: false`, readiness `/health/ready` and liveness `/health/live`. A
projected volume at `/var/run/secrets/troupe` carries two ServiceAccount tokens, audience
`troupe-plane` for enrolment and `troupe-kms` for OpenBao; the data volume is at
`/var/lib/troupe`, team volumes at `/mnt/teams/<team>`, the org volume at `/mnt/org`. The
environment is in [configuration.md A.3](configuration.md#a3-worker-troupe_worker).

Objects carry `app.kubernetes.io/managed-by=troupe-operator` and `troupe.dev/profile`
labels and no owner references (they cannot cross namespaces); the operator prunes labelled
objects that are no longer desired. Deleting a `WorkerProfile` deletes its namespace.

### What a worker can reach

A summary; the detail is where each part is set.

- **The network:** what the profile's `TroupePolicy` admits ([§4](#4-troupepolicy)): its
  `allowedEgress` names and its endpoints (the model, the MCP servers, the installation's
  OpenBao and object store). Never a loopback, unspecified, link-local or cloud metadata
  address (`169.254.169.254`, `fd00:ec2::254`, `100.100.100.200`), by literal address or,
  with Cilium, by any name that resolves there; without Cilium the public rule leaves out
  link-local, the private ranges and `100.64.0.0/10` (Decisions 758 and 0856). The plane is
  not a worker and its egress is not restricted; a trigger's `notify_url` has checks of its
  own ([bundles-and-triggers.md §2](bundles-and-triggers.md#2-triggers)).
- **Kubernetes and secrets:** no ServiceAccount token is mounted; the two projected tokens
  are for enrolment and OpenBao, where the pod reads only what its role allows
  ([roles-and-permissions.md §8](roles-and-permissions.md#8-openbao-policies)).
- **Commands:** every command a session runs on a pod runs in bubblewrap, and a pod that
  cannot start it refuses the command (Decision 832).
- **What a person may do there:** a session token's scopes follow the person's role on the
  session ([roles-and-permissions.md §5](roles-and-permissions.md#5-session-roles-and-scopes)),
  checked against the plane's access list at every command.
- **A person's own tools** run on their machine with their token; the pod sees the names,
  schemas, arguments and results, never the token, and `personalTools: forbid` refuses them
  (Decisions 862 and 879, [a profile's options](profile-options.md#a-persons-own-tools-on-a-pod)).

### Status conditions

| Condition | `True` means |
|---|---|
| `Ready` | every manifest applied; `False` with `PolicyViolation`, `NoPolicy`, `ApplyFailed` or `AwaitingPlane` |
| `Resolved` | only on a profile that extends another: the operator runs the profile in effect the plane wrote into `status.effective`, and the message names the chain. `False` with `AwaitingPlane` while the plane has written none: **nothing is created**, rather than pods made from what differs from the parent alone ([gitops.md](gitops.md#a-manifest-that-extends-another)) |
| `PolicyViolation` | the profile exceeds the policy, or no policy could be read; **nothing is created** |
| `SecretMissing` | a Secret the pods mount is in the worker namespace neither as the operator's copy from `troupe-system` nor as one of yours; the message names each, where it was looked for, and the `kubectl label` line for one the operator may not copy yet ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)) |
| `IngressNamespaceMissing` | no namespace that runs a pod carries `troupe.dev/ingress=true`, or the one `operator.ingressNamespace` names does not, so no ingress controller may reach a worker; the message gives the `kubectl label namespace` line |
| `MCPIdentityMissing` | a server the bundle calls with client credentials has no identity in `mcpIdentities`, or an incomplete one; the message says which ([a profile's options](profile-options.md#calling-an-mcp-server-as-the-profile)) |
| `UpgradePending` | the StatefulSet has a newer revision than the named pods run; each keeps its revision until the plane has drained it and the operator replaced it, and the message says how far each has got ([§3](#3-upgrades-and-drains)) |
| `EgressByHostname` | the `CiliumNetworkPolicy` was written and applied, so a worker reaches its allowlist and the installation's own OpenBao and object store by name, and nothing else outside the cluster; `False` with `NoCilium` or `CiliumPolicyNotApplied` ([§4](#4-troupepolicy)) |
| `PlaneCAMissing` | the installation gives pods the plane's CA (`plane.controlTls.enabled`) and the worker namespace has no `troupe-plane-ca` ConfigMap yet, because the operator has read no certificate from the CA file the chart mounts; the pods wait for it before they dial the plane (`NotWritten`). `False` with `Present`, or `NotGiven` where pods are given no CA |
| `EndpointUnreachable` | an endpoint the profile names is at a loopback, unspecified, link-local or cloud metadata address, which its workers do not reach with Cilium or without (`LoopbackOrLinkLocal`); the message names each and says what to do. `False` with `Reachable`, or `Cilium` where there is Cilium ([§4](#4-troupepolicy)) |

The last seven do not affect `Ready`. `kubectl -n troupe-system get wp` shows `Replicas`, `Ready`, `Violation`,
`Age`.

## 3. Upgrades and drains

The StatefulSet is `OnDelete` because a pod holds live sessions, so a new image, env or
volume makes a new revision and `UpgradePending`, and the pods are replaced one at a time
as they empty (Decision 726):

1. The operator lists the pods on an older revision in the profile's `status.podsBehind`,
   each with its uid and revision.
2. The plane places new sessions on a pod on the current revision while one has room. Once
   a pod behind holds no active session, the plane drains it, one pod per profile at a
   time, highest ordinal first. A pod whose sessions stay busy is left alone until they go
   dormant (ten minutes idle, unless somebody is reading).
3. When the pod is draining and holds nothing, the plane records it, with the revision it
   ran, in the profile's `troupe.dev/drained` annotation.
4. The operator deletes a pod that is behind, recorded at the revision it still runs, and
   no longer Ready, one at a time and never while another is terminating or missing. The
   StatefulSet recreates it on the new revision with the same volume, and it enrols as not
   draining.

The `UpgradePending` message names each pod's stage: `waits to be drained` (it still holds
a session, or waits its turn), `is draining`, `is drained and waits its turn`, `is being
replaced`. A profile with one pod keeps giving it new sessions, having nowhere else to put
them, and it rolls the first time they are all dormant; for the half-minute its replacement
takes to start, a new session on the profile waits, as on a cold profile. To roll a busy
pod sooner, `admin.pod.drain` it. The plane needs the pod's uid from its enrolment token, so
a pod that enrolled with a plane older than 0.6.3 is drained only after it next connects.

`admin.pod.drain` on a pod that is not behind marks it draining, stops placing on it, and
waits until every session on it is dormant in object storage. **Nothing then restarts or
removes it** unless scaling does: its readiness answers 503 and the plane lists it as
`draining` until it is deleted. So drain, then
`kubectl -n troupe-w-<p> delete pod troupe-w-<p>-<ordinal>`.

**A scale-down drains first** (Decision 731). Once a profile has wanted fewer pods for two
minutes, the plane drains the pods above the new count, the highest ordinals, which are the
ones a StatefulSet removes. They take no new session, a running turn gets up to five
minutes (then it is cancelled, with everything up to it sealed), and every session is put
to sleep in object storage. The count comes down past a pod only once the plane counts no
active session on it. If sessions come back meanwhile, the drained pod still goes and the
next tick asks for a fresh one, because a drained pod takes no session until it restarts. A
pod you drained yourself is left to you unless it is above the count the profile wants.

**A pod stopped by anything else** (`kubectl delete pod`, a node drain, an eviction) drains
itself as it stops: running turns get 150 s, half the worker's drain timeout, then its
sessions are put to sleep and reported, inside the pod's grace period
(`operator.drainTimeoutSeconds`). Keep that at 300 s or more; below it, the kill can come
before the sessions are asleep, as every stop did before 0.6.3.

## 4. TroupePolicy

Cluster-scoped (`tpol`), owned by a cluster admin; the plane may only read it. The chart
installs one named `policy.name` (keep it `default`: nothing sets `TROUPE_POLICY_NAME`), or
none with `policy.install: false`, for a repository that holds it as a manifest
([gitops.md](gitops.md#a-profile-in-a-repository)). A plane in gitops mode checks against
this resource and nothing else.

| Field | Meaning | Operator default when absent |
|---|---|---|
| `allowedImageRepositories` | image repositories, compared without tag or digest, exactly or as a prefix `<repo>/` | none (every image refused) |
| `maxReplicas`, `maxSessionsPerPod` | ceilings | 10, 16 |
| `maxResources.cpu`, `.memory` | ceiling on **limits** | 4 CPU, 8Gi |
| `allowedEgress` | hostnames pods may reach, including the LLM endpoint and MCP servers; `*.example.com` matches one label. An entry's port is compared apart from its host: `api.example.com` or `*.example.com` covers a profile's `api.example.com:8443`, `api.example.com:8443` covers that port alone. A star anywhere else is refused, in the policy and in a profile's egress alike: a bare `*`, `**.example.com`, `*.*`, `a.*.example.com`, `*example.com`. The CRD refuses such an entry when the policy is written; a policy that holds one anyway (an older CRD) admits no profile, at admission or in the operator, until it is removed, and the refusal names it (Decision 883) | none |
| `allowedStorageClasses` | classes a team volume or pod disk may name | none |
| `orgVolume` | the org-wide read-only volume profiles may opt into | none |
| `namespacePrefix`, `workersDomain` | worker namespaces and hostnames | `troupe-w-`, `workers.example.test` |

It is enforced twice. **Admission**: a `ValidatingAdmissionPolicy` (Kubernetes ≥ 1.30,
`failurePolicy: Fail`, `Deny`) checks image, replicas, sessions per pod, limits, every egress
host, storage classes and `orgMount` on create and update. **The operator** re-reads the
policy on every reconcile and creates nothing for a violating profile; its storage check
covers team entries only, so without admission a profile could name a disallowed class for
its own disk. The plane also checks the policy before it applies a profile or publishes a
bundle, which needs its Kubernetes connection
([configuration.md A.2](configuration.md#a2-plane-troupe_plane), `TROUPE_KUBECONFIG`).

**Egress.** A worker may reach DNS, the plane's control port, OpenBao, object storage, the
LLM endpoint, its MCP servers and its git hosts. Those in the cluster (a `*.svc` host) are
admitted as their namespace and port. Plain NetworkPolicy cannot name a host, so only the
`CiliumNetworkPolicy` names the external ones, and what a worker reaches depends on whether
Cilium is there (the rules themselves: [configuration.md Part E](configuration.md#part-e--ports-and-network-policy)):

- **With Cilium** (`operator.ciliumAvailable: true`) the allowlist is enforced on the wire.
  The NetworkPolicy reaches nothing outside the cluster, because Cilium admits the union of
  every policy on a pod and one wide rule would admit every public host. The
  `CiliumNetworkPolicy` admits the profile's hosts by name, learning their addresses through
  Cilium's DNS proxy. It also admits the installation's own OpenBao and object store
  (`bao.address`, `objectStore.endpoint`) when they are outside the cluster, on whatever
  port they name: they are the platform's, so they need no entry in `egress.fqdns`, which
  holds the profile's own destinations. A host given as an IP address is admitted as that
  one address (`toCIDR`). A host is admitted on any port, except an `egress.fqdns` entry
  written `host:port`, which is that host on that port alone (a `toPorts` beside it), as
  without Cilium. An address inside the cluster, a Service's cluster IP say, is not
  admitted that way: name the Service (`*.svc`). A host nobody names does not connect.
- **Without Cilium** the external ones are one wide rule, public addresses on 443 and 80,
  and the allowlist is a check at admission and reconcile, not on the wire. The
  installation's own OpenBao and object store outside the cluster, and the profile's own
  endpoints (its LLM endpoint, its MCP servers, its bundle's included, its MCP identities'
  `tokenUrl`s, and its `egress.fqdns` entries; Decision 752) are admitted on the port they name: an IP address,
  private or public, as that one address, and a name on a port other than 443 and 80 as
  public addresses on that port, so a gateway on 8443 opens 8443 to every public host for
  that profile's workers. An `egress.fqdns` entry says its port as `host:port`; one without
  is reached on 443 and 80. A name that resolves to a private address is not reached, and
  nothing can say so where it is typed. For such an endpoint give its address (over TLS its
  certificate then has to name the address), add a NetworkPolicy of your own to each worker
  namespace that admits it (policies add up, and the operator removes only objects it
  labelled), or use Cilium. An address inside the cluster is not dependably admitted
  either: name the Service.

**Loopback, link-local and metadata addresses**, with Cilium or without. A profile's
endpoint at a loopback or link-local address (`127.0.0.1`, `::1`, `169.254.169.254`,
`fe80::1`, or the same written as `::ffff:127.0.0.1`), at the unspecified address
(`0.0.0.0`, `::`), or at one of the two cloud metadata addresses outside link-local
(`fd00:ec2::254`, `100.100.100.200`) gets no rule, even where `allowedEgress` names it
(Decision 758): from a pod, loopback and the unspecified address are the pod itself, and
link-local is the node's, where a cloud's metadata service answers. `admin.profile.put` and
the profile editor refuse such an endpoint on a profile whose workers are pods, with
`invalid_params` naming each, its channel's bundle's servers included, and a bundle publish
that would give one to such a profile is refused the same way (Decision 749). What a
repository holds cannot be refused, so the operator reports it as `EndpointUnreachable`
(on the console's **Workers** page), as it does for a profile saved before. Give the
endpoint as a pod reaches it: by name, at another address, or as its Service
(`<service>.<namespace>.svc`). An MCP identity's token endpoint (`tokenUrl`) is refused and
named as a server is. A git host at such an address gets no rule either, but is neither
refused nor named.

No name gets there either (Decision 856): with Cilium the `CiliumNetworkPolicy` denies
link-local and the metadata addresses whatever a name resolves to, and without it the
public rule leaves out link-local and the shared address space `100.64.0.0/10`, so an
endpoint there is reached only when given as its address (the ranges and their exceptions:
[configuration.md Part E](configuration.md#part-e--ports-and-network-policy)).

`ciliumAvailable: true` on a cluster without Cilium fails closed: a worker reaches nothing
outside the cluster, and the profile is `Ready: False` with `ApplyFailed` naming the
`CiliumNetworkPolicy`. Switching it from `true` to `false` deletes each profile's
`CiliumNetworkPolicy` at that profile's next reconcile.

The operator says which applies to each profile in its `EgressByHostname` condition, and
the plane reads it there: the console's **Provisioners** screen and `admin.profiles.list`
give a profile egress by hostname only where the condition is `True`, and otherwise name it
as missing, with the allowlist checked at admission in its place. A team is still granted
such a profile without `allow_unenforced_workers`, which is for substrates outside
Kubernetes.

## 5. TeamVolume

Namespaced (`tvol`): `team` and `size` required, optional `storageClassName`, `nfsPath`,
`nfsServer`. The operator only writes `status.claimName = team-<team>` and `Ready`; the
claims themselves come from the profile reconcile, from `spec.teams`. `rw` needs a
`ReadWriteMany` class (file storage, not block storage).

Team volumes are mounted on pods but not yet into sessions: a session's mount table on a
pod is `session:/` and `skills:/`, so `publish` and `import` have nowhere to go there.

## 6. Provisioning: direct, or from a repository

`plane.provisioningMode` (`TROUPE_PROVISIONING_MODE`) decides who writes a profile's
`WorkerProfile`. It is the deployment's: the console's **Policy and settings** shows it and
cannot change it, and a value stored there before 0.7.0 is not read.

| Mode | The profiles are | The plane writes | Reported |
|---|---|---|---|
| `direct` (default) | the plane's rows, edited in the console and the admin API | the whole resource, server-side applied as field manager `troupe-plane` | `applied` with the generation |
| `gitops` | the `WorkerProfile` resources a repository holds and something else applies | `spec.replicas`, `spec.teams`, `spec.mcpServers` and nothing else | `projected`, or `unchanged` where the resource already says it |

**Direct.** The plane renders the `WorkerProfile` from its row (name in `troupe-system`,
label `troupe.dev/managed-by: plane`, the stored spec merged with the image, the
plane-written fields and the `teams` projection) and re-applies it on every
`admin.profile.put`, grant, revoke, bundle publish or retire, and scale. A plane with no
Kubernetes connection saves the row and reports `not_applied`, `no_cluster`; the console
then shows no conditions.

**Gitops** (Decision 736) is [gitops.md](gitops.md): what the plane reads from the
repository, what a manifest may and may not hold, and how to switch a running plane.

## 7. Sizing

- **Sessions per pod** sizes everything: a pod holds a process tree per *active* session
  and nothing per dormant one. The size class sets it.
- **Disk**: placement skips a pod above 80 % disk; the worker evicts caches above 70 %.
- **`+Q`**: every BEAM here sets its port table by hand (`*.maxPorts`, 65536), because a
  container runtime's `RLIMIT_NOFILE` would make it 1.5 GB.
- **`values.small.yaml`** fits two nodes of about 3 vCPU and 4 GB: the plane, the operator,
  OpenBao, ingress-nginx and cert-manager take about a node and a half at their requests,
  leaving room for about three worker pods, and 2 GB nodes leave workers `Pending` without
  saying why. The plane's limit is three times its request because an OOMKilled single
  plane is the only plane there is.
- A profile that asks for more than a node can give is admitted and never scheduled.
