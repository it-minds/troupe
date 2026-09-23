# Worker profiles, policy and team volumes

A **profile** is one pool of workers: image, size, model endpoint, egress, bundle channel.
It exists twice — as a row in the plane's `profiles` table (what an admin asked for) and as
a `WorkerProfile` custom resource in `troupe-system` (what the operator reconciles). A
**TroupePolicy** is the cluster admin's ceiling on what any profile may ask for. A
**TeamVolume** declares a team's shared storage.

## 1. What an administrator sets

`admin.profile.put` takes the whole profile; read it with `admin.profile.get` and send it
back changed. `admin.profile.preview` returns the policy verdict and the diff without
writing, and the console's profile editor shows both before its one apply button.

| Field | Meaning |
|---|---|
| `name` | the profile, and the name of its `WorkerProfile` |
| `image` | `repository:tag` or `repository@sha256:…`, or `release` (below) |
| `size_class` | `standard` (several sessions share a worker) or `heavy` (fewer, with more CPU, memory and disk each). A resource question, not a safety one: sessions cannot see each other's files either way |
| `max_sessions` | how far it may grow, in sessions at once. Absent is no ceiling, bounded by the team's budget |
| `warm_workers` | workers kept up when nothing runs. `0` scales to zero, and the next session waits about half a minute |
| `spec` | the rest of the resource in its own camelCase: `llm`, `egress`, `mcpServers`, `configBundleChannel`, `orgMount` |

`replicas`, `sessionsPerPod`, `resources` and `storage` are the plane's: it writes them
from the size class and from what is running, and **refuses** a request that sends them
rather than dropping them. Replicas are recomputed every fifteen seconds as
`ceil((active + pending) / sessionsPerPod) + warm_workers`, clamped to `max_sessions`; a
profile idle for two minutes goes to its warm count.

**`"image": "release"`** means the worker image of the release the plane runs
(`worker.image.*` in the chart). The row keeps the word; the plane resolves it whenever it
renders the resource, and at start rewrites every such profile whose resource carries a
different image, audited as `profile.put` by `system:release`. Pods move only when they are
recreated (§3). `policy.allowedImageRepositories` must allow `worker.image.repository`.

Other `spec` fields:

| Field | Meaning |
|---|---|
| `llm.endpoint`, `.provider`, `.model` | becomes the worker's `TROUPE_BASE_URL`, `TROUPE_PROVIDER` (`openai` = Chat Completions, which a gateway serves; `anthropic`; `fake`), `TROUPE_MODEL`. The endpoint's host is an egress destination |
| `llm.secretRef.{name,key}` | the Secret in the worker namespace injected as `TROUPE_API_KEY` (key `api-key`), not optional |
| `egress.fqdns`, `egress.gitHosts` | extra hosts the pods may reach; each must match a policy pattern |
| `configBundleChannel` | which bundle channel the profile follows (`stable`) |
| `orgMount` | mount the policy's org volume at `/mnt/org`, always read-only |
| `mcpServers`, `teams` | **written by the plane** from the channel's bundle and from grants; do not set them |

A profile's `provisioner` decides who makes its workers exist: `kubernetes` (the default,
the operator) or `ssh`, machines that register themselves ([single-machine.md](single-machine.md)).

## 2. What the operator creates

`Troupe.Operator.Resources.for_profile/3` is a pure function from profile, policy and
settings to manifests. For profile `p` the namespace is `troupe-w-p`, holding: the
ServiceAccount `troupe-worker` (no automounted token); a PVC per granted team
(`team-<team>`, `ReadWriteMany` for `rw`, `ReadOnlyMany` for `ro`) and one for the org
volume; a headless Service and one Service and Ingress per pod (host
`<ordinal>-p.<workersDomain>`); a NetworkPolicy, and a `CiliumNetworkPolicy` when Cilium is
available; a PodDisruptionBudget (`maxUnavailable: 1`); and a StatefulSet with
`podManagementPolicy: Parallel`, `updateStrategy: OnDelete` and a `ReadWriteOnce` data
volume per pod.

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
| `UpgradePending` | the StatefulSet has a newer revision than the named pods run |

`SecretMissing` and `UpgradePending` do not affect `Ready`. `kubectl -n troupe-system get
wp` shows `Replicas`, `Ready`, `Violation`, `Age`.

## 3. Upgrades and drains

The StatefulSet is `OnDelete` because a pod holds live sessions, so a new image, env or
volume produces a new revision and `UpgradePending` and nothing else. `admin.pod.drain`
marks the pod draining, stops placing on it, and waits until every session on it is
dormant in object storage, highest ordinal first. **Nothing then restarts or removes a
drained pod** that scaling did not take away: its readiness answers 503 and the plane lists
it as `draining` and places nothing on it until it is deleted. So drain, then
`kubectl -n troupe-w-<p> delete pod troupe-w-<p>-<ordinal>`; the StatefulSet recreates it on
the new revision with the same volume, and it enrols as not draining.

## 4. TroupePolicy

Cluster-scoped (`tpol`), owned by a cluster admin; the plane may only read it. The chart
installs one named `policy.name` (keep it `default`: nothing sets `TROUPE_POLICY_NAME`).

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
LLM endpoint, its MCP servers and its git hosts. Plain NetworkPolicy cannot name a host, so
the external ones are one wide rule — public addresses on 443 and 80 — and the per-host
rules exist only in the `CiliumNetworkPolicy`. Without Cilium the policy is a check at
admission and reconcile, not on the wire.

## 5. TeamVolume

Namespaced (`tvol`): `team` and `size` required, optional `storageClassName`, `nfsPath`,
`nfsServer`. The operator only writes `status.claimName = team-<team>` and `Ready`; the
claims themselves are created by the profile reconcile from `spec.teams`. `rw` needs a
`ReadWriteMany` class (`scw-sfs` on Scaleway, not block storage).

Team volumes are mounted on pods but not yet into sessions: a session's mount table on a
pod is `session:/` and `skills:/`, so `publish` and `import` have nowhere to go there.

## 6. Provisioning: how the row becomes a resource

The plane renders the `WorkerProfile` from its row — name in `troupe-system`, label
`troupe.dev/managed-by: plane`, the stored spec merged with the image, the plane-written
fields and the `teams` projection — and re-applies it on every `admin.profile.put`, grant,
revoke and bundle publish or retire. The `provisioning_mode` setting decides how:

| Mode | What happens | Reported |
|---|---|---|
| `direct` | server-side apply as field manager `troupe-plane` | `applied` with the generation |
| `gitops` | `profiles/<name>.yaml` committed as `troupe-plane <subject>` and pushed | `pending` with the commit until the resource catches up |

A plane with no Kubernetes connection saves the row and reports `not_applied`,
`no_cluster`; the console then shows no conditions.

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
