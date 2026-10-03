# Worker profiles, policy and team volumes

A **profile** is one pool of workers: image, size, model endpoint, egress, bundle channel.
It exists twice — as a row in the plane's `profiles` table (what an admin asked for) and as
a `WorkerProfile` custom resource in `troupe-system` (what the operator reconciles). A
**TroupePolicy** is the cluster admin's ceiling on what any profile may ask for. A
**TeamVolume** declares a team's shared storage.

## 1. What an administrator sets

`admin.profile.put` takes the whole profile; read it with `admin.profile.get` and send it
back changed. `admin.profile.preview` returns the policy verdict and the diff without
writing, and the console's profile editor shows both before its one apply button. On a
plane in gitops mode a repository holds the profiles instead, and the same fields are a
manifest's ([§6](#6-provisioning-direct-or-from-a-repository)).

| Field | Meaning |
|---|---|
| `name` | the profile, and the name of its `WorkerProfile` |
| `image` | `repository:tag` or `repository@sha256:…`, or `release` (below) |
| `size_class` | `standard` (several sessions share a worker) or `heavy` (fewer, with more CPU, memory and disk each). A resource question, not a safety one: sessions cannot see each other's files either way |
| `max_sessions` | how far it may grow, in sessions at once. Absent is no ceiling, bounded by the team's budget |
| `warm_workers` | workers kept up when nothing runs. `0` scales to zero, and the next session waits about half a minute |
| `spec` | the rest of the resource in its own camelCase: `llm`, `egress`, `mcpServers`, `configBundleChannel`, `orgMount`, and `storage.storageClassName`, the class a worker's disk comes from (one `allowedStorageClasses` names; absent is the cluster's default) |

`replicas`, `sessionsPerPod`, `resources` and `storage.size` are the plane's: it writes them
from the size class and from what is running, and **refuses** a request that sends them
rather than dropping them. Replicas are recomputed every fifteen seconds as
`ceil((active + pending) / sessionsPerPod) + warm_workers`, clamped to `max_sessions`; a
profile idle for two minutes goes to its warm count. A lower count drains the pods it
removes first ([§3](#3-upgrades-and-drains)).

**`"image": "release"`** means the worker image of the release the plane runs
(`worker.image.*` in the chart). The row keeps the word; the plane resolves it whenever it
renders the resource, and at start rewrites every such profile whose resource carries a
different image, audited as `profile.put` by `system:release`. Pods move only when they are
recreated (§3). `policy.allowedImageRepositories` must allow `worker.image.repository`.
Direct mode only: in gitops mode a manifest names its image, and a release reaches the
workers with a commit.

Other `spec` fields:

| Field | Meaning |
|---|---|
| `llm.endpoint`, `.provider`, `.model` | becomes the worker's `TROUPE_BASE_URL`, `TROUPE_PROVIDER` (`openai` = Chat Completions, which a gateway serves; `anthropic`; `fake`), `TROUPE_MODEL`. The endpoint's host is an egress destination |
| `llm.secretRef.{name,key}` | the Secret in the worker namespace injected as `TROUPE_API_KEY` (key `api-key`), not optional |
| `llm.prices` | dollars per million tokens by model, `{"qwen3-235b": {"input": …, "output": …}}` with optional `cacheRead` and `cacheWrite`, injected as `TROUPE_MODEL_PRICES`. For a model the gateway does not price, which with LiteLLM is every streamed call: without a price its calls cost nothing on the ledger and no money budget applies to them. What the gateway says still wins. Set through the API; the console's editor keeps it but does not show it |
| `egress.fqdns`, `egress.gitHosts` | extra hosts the pods may reach; each must match a policy pattern |
| `configBundleChannel` | which bundle channel the profile follows (`stable`) |
| `orgMount` | mount the policy's org volume at `/mnt/org`, always read-only |
| `mcpIdentities` | who the profile is at each MCP server its bundle calls with client credentials ([below](#calling-an-mcp-server-as-the-profile)). Yours to write, in direct and gitops mode alike; nothing in it is secret |
| `mcpServers`, `teams` | **written by the plane** from the channel's bundle and from grants; do not set them |

A profile's `provisioner` decides who makes its workers exist: `kubernetes` (the default,
the operator) or `ssh`, machines that register themselves ([single-machine.md](single-machine.md)).
An `ssh` profile has no pods: in `direct` mode the plane writes it no `WorkerProfile` and
takes away one left from before, and in `gitops` mode, where the repository holds it as a
`WorkerProfile` like any other, the plane writes `spec.replicas: 0` onto it.

### Calling an MCP server as the profile

Some MCP servers take machine callers only through OAuth client credentials, want the
client to prove itself with a signed assertion (a private key JWT, RFC 7523) rather than a
shared secret, and grant tools per client. For those, each profile gets its **own system
identity**: its own client at the identity provider, with its own certificate and its own
granted tools, so two profiles never share permissions (Decision 747). The bundle marks the
server `"credential_mode": "client_credentials"`
([bundles](bundles-and-triggers.md#1-config-bundles)); the profile says who it is there.

```yaml
spec:
  mcpIdentities:
    - server: jira                         # the bundle's name for the server
      clientId: 00000000-0000-0000-0000-000000000000
      scope: api://example-jira/.default   # optional
      tokenUrl: https://login.example.com/tenant/oauth2/v2.0/token   # optional
      transitKey: troupe-w-dev.jira        # <worker namespace>.<anything>
      keyVersion: 1                        # optional; absent is the key's latest
      certificateThumbprint: qIAESDPaFvTg7nQnau6q6AzzzpMg6PElJvINleJ0N2s
      algorithm: RS256                     # or PS256
```

A worker asks the token endpoint for a token with `grant_type=client_credentials`, the
client id, the scope and an assertion whose `iss` and `sub` are the client, whose `aud` is
the token endpoint, which lives five minutes and carries a unique `jti`, and whose header
names the certificate in `x5t#S256`. The assertion is signed by **OpenBao transit**: the
worker sends the signing input and gets the signature back, so the private key never
leaves OpenBao, not even into the worker's memory. The token is kept in the worker, one per
server, renewed a minute before it runs out (or at three quarters of its life, if that is
shorter), asked for again once after a `401`, and sent as `Authorization: Bearer` on every
call. It is never in a log, an error or the event log. Without `tokenUrl` the token
endpoint is the one the server's authorization server publishes (its protected-resource
metadata names the authorization server); `tokenUrl`'s host is egress the policy must
allow, and one found in metadata must be in `egress.fqdns`.

**Setting one up.**

1. Make a key and a certificate for the profile's client (or have your PKI issue one), and
   work out the thumbprint the profile names: base64url, without padding, of the SHA-256 of
   the certificate in DER. The 64 hex digits `openssl x509 -fingerprint -sha256` prints are
   taken too.

   ```sh
   openssl req -x509 -newkey rsa:2048 -nodes -keyout jira.key -out jira.crt \
     -days 365 -subj "/CN=troupe-w-dev jira"
   openssl x509 -in jira.crt -outform DER | openssl dgst -sha256 -binary \
     | basenc --base64url | tr -d '='
   ```

2. Import the key into transit under a name that starts with the profile's worker
   namespace and a dot, then delete every copy of `jira.key`. `bao transit import` wraps the
   key for you; the key is not exportable from then on.

   ```sh
   openssl pkcs8 -topk8 -nocrypt -in jira.key -outform DER | base64 -w0 > jira.key.b64
   bao transit import transit/keys/troupe-w-dev.jira @jira.key.b64 type=rsa-2048
   shred -u jira.key jira.key.b64
   ```

3. Register `jira.crt` with the identity provider as the client's credential, and grant the
   client the server's roles or scopes.

4. Write the identity on the profile, with `keyVersion: 1` and the thumbprint. The pods
   read it from a file (below) and use it from their next token; no restart.

The pods need to be allowed to sign with the key. The policy `Troupe.KMS.Policy.mcp_identity/2`
renders lets a pod sign with the keys named after its own namespace and with nothing else,
the plane's session-token key included; attach it to the Kubernetes-auth role the pods log
in with ([roles and permissions §8](roles-and-permissions.md#8-openbao-policies)).

**Rotating.** Make the new key and certificate as in step 1, register the new certificate
beside the old one, and import the key as the next version of the same transit key:

```sh
bao transit import-version transit/keys/troupe-w-dev.jira @jira-2.key.b64
```

Then change `keyVersion` and `certificateThumbprint` on the profile together, in one
change. A worker signs with the pinned version until it reads the new pair, then gets its
next token with the new key; there is no gap, because the identity provider holds both
certificates. Remove the old certificate at the identity provider once the old tokens have
run out, an hour later. With no `keyVersion` a worker signs with the latest version, so an
import before the profile names the new thumbprint fails token requests in between.

**What is reported.** A server the bundle marks `client_credentials` with no identity on
the profile, or an identity without its `clientId` or `transitKey`, with a thumbprint that
is not one, or with another algorithm, is reported rather than refused, as a missing Secret
is: by the operator's `MCPIdentityMissing` condition and by the plane in
`admin.profile.get` and `admin.profile.put`'s `identity_problems`. The pods start
regardless and offer that server's tools once both halves are there. A worker that cannot
get a token says which server and why: the token endpoint refused the client (with the
provider's error), the transit key is not in OpenBao, the pod may not sign with it, or the
server refused a tool the identity lacks.

## 2. What the operator creates

`Troupe.Operator.Resources.for_profile/3` is a pure function from profile, policy and
settings to manifests. For profile `p` the namespace is `troupe-w-p`, holding: the
ServiceAccount `troupe-worker` (no automounted token); a PVC per granted team
(`team-<team>`, `ReadWriteMany` for `rw`, `ReadOnlyMany` for `ro`) and one for the org
volume; a headless Service and one Service and Ingress per pod (host
`<ordinal>-p.<workersDomain>`); a NetworkPolicy, and a `CiliumNetworkPolicy` when Cilium is
available; a PodDisruptionBudget (`maxUnavailable: 1`); and a StatefulSet with
`podManagementPolicy: Parallel`, `updateStrategy: OnDelete` and a `ReadWriteOnce` data
volume per pod. A profile with `mcpIdentities` also gets the ConfigMap
`troupe-mcp-identities`, mounted as a directory at `/etc/troupe/mcp-identities` and named
in `TROUPE_MCP_IDENTITIES_PATH`: the kubelet replaces the file in place when the profile
changes, so a new identity or a rotation reaches running pods without a new revision.

The pod runs as non-root uid 1000 with seccomp `RuntimeDefault`, every capability dropped,
`enableServiceLinks: false`, readiness `/health/ready` and liveness `/health/live`. A
projected volume at `/var/run/secrets/troupe` carries two ServiceAccount tokens — audience
`troupe-plane` for enrolment and `troupe-kms` for OpenBao — the data volume is at
`/var/lib/troupe`, team volumes at `/mnt/teams/<team>`, the org volume at `/mnt/org`. The
environment is in [configuration.md A.3](configuration.md#a3-worker-troupe_worker).

Objects carry `app.kubernetes.io/managed-by=troupe-operator` and `troupe.dev/profile`
labels and no owner references (they cannot cross namespaces); the operator prunes labelled
objects that are no longer desired. Deleting a `WorkerProfile` deletes its namespace.

### Status conditions

| Condition | `True` means |
|---|---|
| `Ready` | every manifest applied; `False` with `PolicyViolation`, `NoPolicy` or `ApplyFailed` |
| `PolicyViolation` | the profile exceeds the policy, or no policy could be read; **nothing is created** |
| `SecretMissing` | a referenced Secret was not found in the worker namespace. The operator has no RBAC on Secrets, so do not rely on it |
| `MCPIdentityMissing` | a server the bundle calls with client credentials has no identity in `mcpIdentities`, or its identity is incomplete; the message says which ([above](#calling-an-mcp-server-as-the-profile)) |
| `UpgradePending` | the StatefulSet has a newer revision than the named pods run; each keeps its revision until the plane has drained it and the operator replaced it, and the message says how far each has got ([§3](#3-upgrades-and-drains)) |
| `EgressByHostname` | the `CiliumNetworkPolicy` was written and applied, so a worker reaches its allowlist and the installation's own OpenBao and object store by name, and nothing else outside the cluster; `False` with `NoCilium` or `CiliumPolicyNotApplied` ([egress](#4-troupepolicy)) |
| `EndpointUnreachable` | an endpoint the profile names is at a loopback or link-local address, which its workers do not reach with Cilium or without (`LoopbackOrLinkLocal`): the message names each and says what to do; `False` with `Reachable`, or `Cilium` where there is Cilium ([egress](#4-troupepolicy)) |

`SecretMissing`, `MCPIdentityMissing`, `UpgradePending`, `EgressByHostname` and
`EndpointUnreachable` do not affect `Ready`. `kubectl -n troupe-system get wp` shows
`Replicas`, `Ready`, `Violation`, `Age`.

## 3. Upgrades and drains

The StatefulSet is `OnDelete` because a pod holds live sessions, so a new image, env or
volume produces a new revision and `UpgradePending`, and the pods are replaced one at a
time as they empty (Decision 726):

1. The operator lists the pods on an older revision in the profile's `status.podsBehind`,
   each with its uid and revision.
2. The plane places new sessions on a pod on the current revision while one has room.
   Once a pod behind holds no active session, the plane drains it, one pod per profile at
   a time and the highest ordinal first. A pod whose sessions stay busy is left alone;
   they go dormant in their own time (ten minutes idle, unless somebody is reading).
3. When the pod is draining and holds nothing, the plane records it in the profile's
   `troupe.dev/drained` annotation, with the revision it ran.
4. The operator deletes a pod that is behind, recorded at the revision it still runs, and
   no longer Ready, one at a time and never while another is terminating or missing. The
   StatefulSet recreates it on the new revision with the same volume, and it enrols as
   not draining.

The `UpgradePending` message names each pod and its stage: `waits to be drained` (it still
holds a session, or waits its turn), `is draining`, `is drained and waits its turn`, `is
being replaced`. A profile with one pod keeps giving that pod new sessions, having nowhere
else to put them, and it rolls the first time they are all dormant; for the half-minute its
replacement takes to start, a session opened on the profile waits, as on a cold profile.
To roll a busy pod sooner, `admin.pod.drain` it: its sessions go dormant and the rest
follows. The plane needs the pod's uid from its enrolment token, so a pod that enrolled
with a plane older than 0.6.3 is drained only after it next connects.

`admin.pod.drain` on a pod that is not behind marks it draining, stops placing on it, and
waits until every session on it is dormant in object storage. **Nothing then restarts or
removes it** unless scaling takes it away: its readiness answers 503 and the plane lists it
as `draining` and places nothing on it until it is deleted. So drain, then
`kubectl -n troupe-w-<p> delete pod troupe-w-<p>-<ordinal>`.

**A scale-down drains first** (Decision 731). Once a profile has wanted fewer pods for two
minutes, the plane drains the pods above the new count, the highest ordinals, since those
are the ones a StatefulSet removes. They take no new session, a running turn gets up to five
minutes to finish (after that it is cancelled, with everything up to it sealed), and every
session is put to sleep in object storage. The count comes down past a pod only once the
plane counts no active session on it. If sessions come back meanwhile, the drained pod
still goes and the next tick asks for a fresh one, because a drained pod takes no session
until it restarts. A pod you drained yourself is left to you unless it is above the count
the profile wants.

**A pod stopped by anything else** (`kubectl delete pod`, a node drain, an eviction) drains
itself as it stops: running turns get 150 s, half the worker's drain timeout, and then its
sessions are put to sleep and reported, inside the pod's grace period
(`operator.drainTimeoutSeconds`). Keep that at 300 s or more; below it, the kill can come
before the sessions are asleep, as every stop did before 0.6.3.

## 4. TroupePolicy

Cluster-scoped (`tpol`), owned by a cluster admin; the plane may only read it. The chart
installs one named `policy.name` (keep it `default`: nothing sets `TROUPE_POLICY_NAME`), or
none with `policy.install: false`, for a repository that holds it as a manifest
([§6](#6-provisioning-direct-or-from-a-repository)). A plane in gitops mode checks against
this resource and nothing else.

| Field | Meaning | Operator default when absent |
|---|---|---|
| `allowedImageRepositories` | image repositories, compared without tag or digest, exactly or as a prefix `<repo>/` | none (every image refused) |
| `maxReplicas`, `maxSessionsPerPod` | ceilings | 10, 16 |
| `maxResources.cpu`, `.memory` | ceiling on **limits** | 4 CPU, 8Gi |
| `allowedEgress` | hostnames pods may reach, including the LLM endpoint and MCP servers; `*.example.com` matches one label; a bare `*` is refused | none |
| `allowedStorageClasses` | classes a team volume or pod disk may name | none |
| `orgVolume` | the org-wide read-only volume profiles may opt into | none |
| `namespacePrefix`, `workersDomain` | worker namespaces and hostnames | `troupe-w-`, `workers.example.test` |

It is enforced twice. **Admission**: a `ValidatingAdmissionPolicy` (Kubernetes ≥ 1.30,
`failurePolicy: Fail`, `Deny`) checks image, replicas, sessions per pod, limits, every
egress host, storage classes and `orgMount` on create and update. **The operator**
re-reads the policy on every reconcile and creates nothing for a violating profile. The
operator's storage check covers team entries only, so without admission a profile could
name a disallowed class for its own disk. The plane also checks the policy before it
applies a profile or publishes a bundle, which needs its Kubernetes connection
([configuration.md A.2](configuration.md#a2-plane-troupe_plane), `TROUPE_KUBECONFIG`).

**Egress.** A worker may reach DNS, the plane's control port, OpenBao, object storage, the
LLM endpoint, its MCP servers and its git hosts. Those in the cluster (a `*.svc` host) are
their namespace and port. Plain NetworkPolicy cannot name a host, so only the
`CiliumNetworkPolicy` names the external ones, and what a worker can reach depends on
whether Cilium is there:

- **With Cilium** (`operator.ciliumAvailable: true`) the allowlist is enforced on the
  wire. The NetworkPolicy reaches nothing outside the cluster, because Cilium admits the
  union of every policy on a pod and one wide rule would admit every public host. The
  `CiliumNetworkPolicy` admits the profile's hosts by name, and sends DNS through Cilium's
  proxy, which is how it learns the addresses a name resolves to. It also admits the
  installation's own OpenBao and object store (`bao.address`, `objectStore.endpoint`) by
  name when they are outside the cluster, a hosted S3 service say, on whatever port they
  name: they are the platform's, so the operator adds them itself, and they are not in
  the profile's allowlist, which holds the profile's own destinations and is what the
  plane shows and admission checks. They need no entry in `egress.fqdns`. A host given as
  an IP address, the profile's or the installation's, is admitted as that one address (a
  `toCIDR` of `/32` or `/128`), since no DNS answer names it, except a profile's at a
  loopback or link-local address, which is admitted by nothing (below); an address inside
  the cluster, a Service's cluster IP say, is not admitted that way, so name the Service
  (`*.svc`) instead. A host neither the profile nor the installation names does not
  connect.
- **Without Cilium** the external ones are one wide rule, public addresses on 443 and 80,
  and the policy is a check at admission and reconcile, not on the wire. Troupe writes no
  address list in its place: the allowlist holds names, not addresses. The installation's
  own OpenBao and object store, when they are outside the cluster, are admitted on the
  port they name as well: one given as an IP address, private or public, as that one
  address (an `ipBlock` of `/32` or `/128`), and one given by name on a port other than
  443 and 80 as public addresses on that port, so a worker then reaches any public host
  on that port. A NetworkPolicy cannot name a host, so a name that resolves to a private
  address is not reached. For such an endpoint, give its address instead (over TLS its
  certificate then has to name the address), add a NetworkPolicy of your own to each
  worker namespace that admits it (policies add up, and the operator removes only
  objects it labelled), or use Cilium.

  A profile's own endpoints, its LLM endpoint, its MCP servers (its own and those its
  channel's bundle gives it) and its `egress.fqdns` entries, are admitted the same way
  (Decision 752): one given as an IP address, private or public, as that one address on
  its port, and one given by name on a port other than 443 and 80 as public addresses on
  that port, so a gateway on 8443 opens 8443 to every public host for that profile's
  workers. An `egress.fqdns` entry says its port as `host:port`; one without is reached on
  443 and 80, an address as itself. A `*.svc` host is its namespace on its port, as above.
  A name that resolves to a private address is still not reached, and since what a name
  resolves to is not known where it is typed, nothing says so: give that endpoint as its
  address (over TLS its certificate then has to name the address), or use Cilium. An
  address inside the cluster, a Service's cluster IP say, is not dependably admitted by an
  `ipBlock`, so name the Service instead.

**Loopback and link-local**, with Cilium or without. A profile's endpoint at a loopback or
link-local address (`127.0.0.1`, `::1`, `169.254.169.254`, `fe80::1`, or the same written
as `::ffff:127.0.0.1`) gets no rule, neither in the NetworkPolicy nor as a `toCIDR` in the
`CiliumNetworkPolicy`, even where `allowedEgress` names it (Decision 758): from a pod,
loopback is the pod itself, and link-local is the node's, where a cloud's metadata service
answers. Such an endpoint is refused where it is set up (Decision 749): `admin.profile.put`
and the profile editor refuse a profile whose workers are pods with `invalid_params`,
naming each endpoint, counting the servers its channel's bundle gives it; publishing a
bundle that names such a server to a channel such a profile follows is refused the same
way. In `gitops` mode nothing can refuse what a repository holds, so the operator reports
it on the profile as `EndpointUnreachable`, which the console's **Workers** page shows; it
does in `direct` mode too, for a profile saved before. Give the endpoint as a pod reaches
it: by name, at another address, or, for one in the cluster, as its Service
(`<service>.<namespace>.svc`). A git host or an MCP identity's token endpoint at such an
address gets no rule either, but is neither refused nor named.

`ciliumAvailable: true` on a cluster without Cilium fails closed: a worker reaches nothing
outside the cluster, and the profile is `Ready: False` with `ApplyFailed` naming the
`CiliumNetworkPolicy`. Switching `ciliumAvailable` from `true` to `false` deletes the
`CiliumNetworkPolicy` the operator wrote for each profile, at that profile's next reconcile.

The operator says which on each profile, as the `EgressByHostname` condition, and the
plane reads it there: the console's **Provisioners** screen and `admin.profiles.list` give
a profile egress by hostname only where the condition is `True`, and otherwise name it as
missing with the allowlist checked at admission in its place. A team is still granted such
a profile without `allow_unenforced_workers`, which is for substrates outside Kubernetes.

## 5. TeamVolume

Namespaced (`tvol`): `team` and `size` required, optional `storageClassName`, `nfsPath`,
`nfsServer`. The operator only writes `status.claimName = team-<team>` and `Ready`; the
claims themselves are created by the profile reconcile from `spec.teams`. `rw` needs a
`ReadWriteMany` class (a file-storage class, not block storage).

Team volumes are mounted on pods but not yet into sessions: a session's mount table on a
pod is `session:/` and `skills:/`, so `publish` and `import` have nowhere to go there.

## 6. Provisioning: direct, or from a repository

`plane.provisioningMode` (`TROUPE_PROVISIONING_MODE`) decides who writes a profile's
`WorkerProfile`. It is the deployment's: the console's Policy page shows it and cannot
change it, and a value stored there before 0.7.0 is not read.

| Mode | The profiles are | The plane writes | Reported |
|---|---|---|---|
| `direct` (default) | the plane's rows, edited in the console and the admin API | the whole resource, server-side applied as field manager `troupe-plane` | `applied` with the generation |
| `gitops` | the `WorkerProfile` resources a repository holds and something else applies | `spec.replicas`, `spec.teams`, `spec.mcpServers` and nothing else | `projected`, or `unchanged` where the resource already says it |

**Direct.** The plane renders the `WorkerProfile` from its row — name in `troupe-system`,
label `troupe.dev/managed-by: plane`, the stored spec merged with the image, the
plane-written fields and the `teams` projection — and re-applies it on every
`admin.profile.put`, grant, revoke, bundle publish or retire, and scale. A plane with no
Kubernetes connection saves the row and reports `not_applied`, `no_cluster`; the console
then shows no conditions.

**Gitops** (Decision 736). A repository holds the manifests; Flux, Argo CD or a pipeline
running `kubectl apply --server-side` applies them; the plane never writes git and holds
no credential for it. Every fifteen seconds it lists the `WorkerProfile` resources in its
namespace and makes its rows follow them. A new resource becomes a profile, a change
changes it, and a resource that goes takes its profile with it, its sessions becoming
read-only as with a delete; each is audited as `profile.put` or `profile.delete` by
`system:gitops`. The scaler's count is the plane's: a row takes `spec.replicas` from the
resource when it is made, and the scaler's number from then on.

A resource is used only if the plane could have saved it itself: its annotations parse,
`spec.image` names a repository, `spec.sessionsPerPod` is a size class's (4 is `standard`,
2 is `heavy`), the cluster's `TroupePolicy` allows it, and it does not set a field the
plane writes. One that fails is **refused**: a new one gets no profile, and a changed one
leaves the profile as the last version that passed, so a mistake in the repository does
not take down a profile that was running. The reasons are in the log once, in
`admin.profiles.list` (each profile carries `gitops`: the source, the generation it was
read at, and a `problem` of `refused`, `missing`, `plane_only` or `unwritten` with
`reasons`; a refused resource with no profile is listed with nothing running), and on the
console's Workers page and the profile's own.

In this mode the console shows every profile read-only, marked **Locked to gitops** with
`plane.gitops.source`, and `admin.profile.put` and `admin.profile.delete` are refused as
`managed_by_gitops` and audited with `outcome: refused`. The plane writes its three fields
onto a resource only where they differ from what it says, and only onto one something
else holds, and its Role has no `create` or `delete` on `WorkerProfile`. A `release` image
is not followed: the manifest names its image.

The same pass reads the triggers, after the profiles: in this mode a repository holds them
as `Trigger` resources named `<team>.<trigger>`, the console's Triggers page is locked too,
and running one by hand and minting its key still work (Decision 737,
[bundles-and-triggers.md §2](bundles-and-triggers.md#triggers-from-a-repository)). Teams,
their grants and service principals stay in the plane's database.

What a profile takes from its resource:

| Profile | Resource |
|---|---|
| `image` | `spec.image`, as `repository:tag`, or `repository@digest` where it has one |
| `size_class` | `spec.sessionsPerPod`: 4 (the CRD's default) is `standard`, 2 is `heavy` |
| `max_sessions` | annotation `troupe.dev/max-sessions`; absent is no ceiling |
| `warm_workers` | annotation `troupe.dev/warm-workers`, 0 to 10; absent is 0 |
| `provisioner` | annotation `troupe.dev/provisioner`; absent is `kubernetes` |
| channel | `spec.configBundleChannel`; absent is `stable` |
| `spec` | the rest: `llm`, `egress`, `storage`, `resources`, `orgMount` |

CPU, memory and disk are the manifest's to size, within the policy; the class the plane
places and scales by is read off `sessionsPerPod`.

### A profile in a repository

`admin.profiles.export` (the console's Workers page, **Manifests for a repository**) gives
every profile in this shape, the policy and every trigger. This one is written by hand:

```yaml
# profiles/standard.yaml
apiVersion: troupe.dev/v1alpha1
kind: WorkerProfile
metadata:
  name: standard
  namespace: troupe-system
  annotations:
    troupe.dev/max-sessions: "16"
    troupe.dev/warm-workers: "1"
spec:
  image:
    repository: registry.example.com/troupe/troupe-worker
    tag: "0.7.0"
  sessionsPerPod: 4
  resources:
    requests: {cpu: 250m, memory: 1Gi}
    limits: {cpu: "2", memory: 4Gi}
  storage:
    size: 20Gi
    storageClassName: standard
  llm:
    endpoint: https://gateway.example.com/v1
    provider: openai
    model: example-large
    smallModel: example-small
    secretRef: {name: troupe-llm, key: api-key}
  egress:
    fqdns: [gateway.example.com]
  configBundleChannel: stable
```

Applied by Flux from a `GitRepository` named `fleet`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: troupe-profiles
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: fleet
  path: ./profiles
  prune: true
```

With `prune: true`, a manifest removed from the repository deletes its resource and the
plane then removes the profile; without it the resource stays, and so does the profile.

A manifest never holds what the plane or the cluster writes: `spec.replicas` (the
scaler's), `spec.teams` (the grants', which stay in the plane's database) and
`spec.mcpServers` (the channel's bundle's), `status`, or the annotation
`troupe.dev/drained`. The applier would put its value back at every reconcile, over the
plane's; a resource that sets one of the three is refused and names who sets it. Copied
from `kubectl get -o yaml`, a resource also carries `metadata.managedFields`,
`resourceVersion`, `uid`, `generation` and `creationTimestamp`; the export leaves those
out too. `spec.mcpIdentities` is the repository's like the rest of the spec, so git says
which profile has which identity ([above](#calling-an-mcp-server-as-the-profile)).

The policy is the chart's `policy.*` values, which are then the repository's already, or
a `TroupePolicy` manifest in the repository with `policy.install: false`; the export gives
one.

### The record of finished drains, under an applier

The plane records a finished drain (§3) in the annotation `troupe.dev/drained`, written
server-side under a field manager of its own, `troupe-plane-upgrade`. Flux's
kustomize-controller also applies server-side, as `kustomize-controller`, and owns only
the fields its manifest names: an annotation the manifest leaves out is nobody's but the
plane's, and every reconcile, drift correction included, leaves it where it is. The same
goes for the plane's three fields under `troupe-plane`. Two things would break that: a
manifest that names the annotation, which makes the applier its co-owner, and listing the
plane's field managers in kustomize-controller's `--override-manager`, which hands their
fields to Flux. `Troupe.Plane.GitopsTest` holds the plane to it against a model of
server-side apply's field ownership.

### Switching a running plane

**Direct to gitops.** Export the manifests, commit them, and let the applier apply them
while the plane is still in direct mode: it takes the fields over, and the workers do not
notice. Export them with `admin.profiles.export` or the Workers page, not
`kubectl get workerprofiles`: a resource the plane wrote in direct mode has no field for a
profile's ceiling, its warm count or its provisioner, which the export gives as the
`troupe.dev/max-sessions`, `troupe.dev/warm-workers` and `troupe.dev/provisioner`
annotations (Decision 736), so a repository copied from the cluster resets all three at the
switch, and has no triggers. Then redeploy the plane with `plane.provisioningMode: gitops` and
`plane.gitops.source`. At its first pass the plane adopts every resource as it is:

- One only the plane has ever written — nothing applies it from a repository yet — is
  used as it is and reported `plane_only`, and the plane writes none of its fields until
  something else holds it: with nobody else owning the rest, a write of three fields would
  take them away.
- A profile the cluster has no resource for is reported `missing` and kept. Commit its
  manifest, or `admin.profile.delete` it, which in gitops mode deletes such a row and
  nothing else.
- At its first write to a resource after that, the plane gives up every field it wrote in
  direct mode but its three, so from then on a field the repository drops leaves the
  cluster.
- The export has the triggers too. A trigger whose resource is there is read into the row
  it came from, key and runs included; one the cluster has no resource for is reported
  `missing`, kept and still firing, until its manifest is committed or
  `admin.trigger.delete` deletes it.

**Gitops to direct.** Stop the applier reconciling the profiles first — suspend the
Kustomization, or take them out of it — or it puts back the repository's version at its
next interval. Redeploy with `direct`. The profiles are what the plane last read; the
editor writes again, and each profile's first write applies the whole resource as
`troupe-plane`, taking its fields back. The `troupe.dev/max-sessions`,
`troupe.dev/warm-workers` and `troupe.dev/provisioner` annotations stay on the resources,
unread. So do the `Trigger` resources: the triggers are what the plane last read, and the
console and `admin.trigger.put` change them again.

## 7. Sizing

- **Sessions per pod** sizes everything: a pod holds a process tree per *active* session
  and nothing per dormant one. The size class sets it.
- **Disk**: placement skips a pod above 80 % disk; the worker evicts caches above 70 %.
- **`+Q`**: every BEAM here sets its port table by hand (`*.maxPorts`, 65536), because a
  container runtime's `RLIMIT_NOFILE` would make it 1.5 GB.
- `values.small.yaml` explains its numbers: the plane's limit is three times its request
  because an OOMKilled single plane is the only plane there is, and two small nodes hold the
  plane, operator, OpenBao, ingress and cert-manager with room for about three worker pods.
  A profile that asks for more than a node can give is admitted and never scheduled.
