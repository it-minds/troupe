# Worker profiles, policy and team volumes

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree. `resources.ex`, `reconciler.ex`, `names.ex`, `settings.ex` are under `apps/troupe_operator/lib/troupe/operator/`; `provision.ex`, `cluster_policy.ex`, `bundles.ex`, `admin.ex` under `apps/troupe_plane/lib/troupe/plane/`; the CRDs under `charts/troupe/crds/`.

A **profile** is one pool of worker pods: image, size, model endpoint, egress, bundle channel, disks. It exists twice — as a row in the plane's `profiles` table (what an admin asked for) and as a `WorkerProfile` custom resource in `troupe-system` (what the operator reconciles). A **TroupePolicy** is the cluster admin's ceiling on what any profile may ask for. A **TeamVolume** declares a team's shared storage. The rationale is in `ARCHITECTURE.md` §7 and [../whitepaper.md](../whitepaper.md).

---

## 1. WorkerProfile spec

`charts/troupe/crds/workerprofile.yaml`, group `troupe.dev/v1alpha1`, namespaced, short name `wp`, status subresource (`:9-22`). `spec.image` is the only required field (`:30`).

| Field | Type / constraint | Default | Meaning | CRD line |
|---|---|---|---|---|
| `image.repository` | string, required | — | image repository; must match a `TroupePolicy.allowedImageRepositories` entry exactly or as a prefix `<repo>/` | 32-36 |
| `image.tag` | string | — | tag | 37 |
| `image.digest` | string | — | wins over `tag` when both are given | 38-40 |
| `replicas` | integer ≥ 0 | 1 | pods; one Service + Ingress each. **Written by the plane**, not by an administrator — see §1.1 | 41 |
| `sessionsPerPod` | integer ≥ 1 | 4 | capacity a pod claims; placement fills the next pod past it. **Written by the plane** from the size class | 42 |
| `resources` | free-form object | — | container requests/limits; `limits.cpu` drives `+S`, and limits are what policy checks. **Written by the plane** from the size class | 43-45 |
| `llm.endpoint` | string | — | becomes `TROUPE_BASE_URL` on the pod; its host is an egress destination | 49 |
| `llm.provider` | enum `anthropic`, `openai`, `fake` | `openai` | adapter; `openai` is plain Chat Completions, which a gateway serves | 50-54 |
| `llm.model` | string | — | `TROUPE_MODEL` | 55 |
| `llm.smallModel` | string | — | injected as `TROUPE_SMALL_MODEL` but read by nothing ([AUDIT.md §3.3](../AUDIT.md)) | 56-58 |
| `llm.secretRef.name` / `.key` | strings | key `api-key` | Secret in the worker namespace injected as `TROUPE_API_KEY`, not optional | 59-63 |
| `mcpServers[]` | array; each `{name*, url*, secretRef{name, key=token}, credentialRef (^[A-Z][A-Z0-9_]*$, default TROUPE_MCP_<NAME>_TOKEN), header (default authorization), timeoutMs ≥ 1}` | — | **written by the plane** from the channel's bundle on every publish/retire; do not edit by hand | 64-89 |
| `egress.fqdns[]`, `egress.gitHosts[]` | string lists | — | extra hosts the pods may reach; each must match a policy pattern | 90-98 |
| `configBundleChannel` | string | `stable` | which bundle channel the profile follows | 99 |
| `storage.size` | string quantity | `20Gi` | each pod's own PVC; **immutable once the StatefulSet exists** — changing it is a new pool | 100-109 |
| `storage.storageClassName` | string | cluster default | must be in `allowedStorageClasses` (admission checks it; the operator does not — §5) | 110-114 |
| `orgMount` | boolean | false | mount the policy's org volume at `/mnt/org`, always read-only | 115-118 |
| `teams[]` | array of `{name*, claimName, storageClassName, size, mode ro/rw (default ro)}` | — | **a projection of the plane's grants**, rewritten by the plane; nothing else edits it | 119-135 |

Status: `observedGeneration`, `readyReplicas` (declared but never written by the operator), `namespace`, `conditions[]` (`:136-153`). Printer columns: `Replicas`, `Ready`, `Violation`, `Age` (`:154-166`).

The parser the plane and operator share is `Troupe.WorkerProfile.from_resource/1` (`apps/troupe_protocol/lib/troupe/worker_profile.ex:100-128`); `egress_destinations/1` (`:171-179`) is the list policy checks: LLM host, every MCP host, `fqdns`, `gitHosts`.

---


### 1.1 Seven fields the plane writes

`replicas`, `sessionsPerPod`, the four numbers under `resources`, and `storage.size` are
in the custom resource and are not on the admin surface. `admin.profile.put` refuses them
rather than ignoring them, because a number somebody typed and the platform dropped is a
number they will believe is in force.

What an administrator answers instead is three questions:

| field | meaning |
|---|---|
| `size_class` | `standard` (four sessions a worker) or `heavy` (two, with more CPU, memory and disk each). A question about resources, not about safety: sessions cannot see each other's files whatever the class |
| `max_sessions` | how far the profile may grow, **in sessions at once rather than workers**. Absent is no ceiling, bounded by the team's budget |
| `warm_workers` | how many workers to keep up when nothing is running. `0` scales to zero |

`replicas` is then the plane's, computed every fifteen seconds as
`ceil((active + pending) / sessionsPerPod) + warm`, clamped to `max_sessions`, and written
through the same path and the same RBAC that already writes `spec.teams`. A profile with
nothing running goes to zero after two minutes idle; the next session brings a worker back
and waits for it.

The storage **class** is still an administrator's field: how much disk is a size question
and which storage it comes from is a fact about the cluster.

A `TroupePolicy` still refuses a size class that exceeds it, at admission — which is where
a maximum belongs, since the plane cannot write that document.

## 2. What the operator creates for one profile

`Troupe.Operator.Resources.for_profile/3` is a pure function from profile, policy and settings to manifests (`resources.ex:20-38`). Discrepancy: `ARCHITECTURE.md:323` names it `for_profile/2`. For profile `p` with the default prefix the namespace is `troupe-w-p` (`names.ex:11-13`).

| Object | Name | Notable spec | `resources.ex` |
|---|---|---|---|
| Namespace | `troupe-w-<p>` | labels `troupe.dev/workers=true` plus the managed labels | 65-73 |
| ServiceAccount | `troupe-worker` | `automountServiceAccountToken: false` | 79-86 |
| PVC per granted team | `team-<team>` | `ReadWriteMany` for `rw`, `ReadOnlyMany` for `ro`; size from the team entry or `10Gi`; class from the entry | 93-104,122-139 |
| PVC for org | `org` | only when `orgMount` and the policy has `orgVolume`; `ReadOnlyMany`, size `orgVolume.size` or `10Gi` | 106-120 |
| headless Service | `troupe-w-<p>` | `clusterIP: None`, port `harness` 4000 | 143-155 |
| Service per pod | `<p>-<ordinal>` | selector adds `statefulset.kubernetes.io/pod-name`, port 4000 | 160-179 |
| Ingress per pod | `<p>-<ordinal>` | host `<ordinal>-<p>.<workersDomain>` → Service port 4000; TLS per pod `<p>-<ordinal>-tls` with a cert issuer, or the shared secret; nginx annotations `proxy-read/send-timeout 3600`, `limit-connections 50`; `cert-manager.io/cluster-issuer` when set | 181-266 |
| NetworkPolicy | `troupe-w-<p>` | ingress: TCP 4000 from `troupe.dev/ingress=true` namespaces; egress: kube-dns 53, plane namespace on the control port, `0.0.0.0/0` minus RFC 1918 and link-local on 443/80, plus namespace rules for OpenBao and object storage when their hosts are `*.svc` | 275-383 |
| CiliumNetworkPolicy | `troupe-egress` | only with `ciliumAvailable`; `toFQDNs` per egress destination (`matchPattern` for a wildcard, `matchName` otherwise) and kube-dns | 385-417 |
| PodDisruptionBudget | `troupe-w-<p>` | `maxUnavailable: 1` | 419-433 |
| StatefulSet | `troupe-w-<p>` | `podManagementPolicy: Parallel`, `updateStrategy: OnDelete`, `volumeClaimTemplates: [data]` (`ReadWriteOnce`, `storage.size` or `20Gi`, `storage.storageClassName` when set) | 437-476 |

The pod (`resources.ex:478-530`): ServiceAccount `troupe-worker`, no automounted token, `runAsNonRoot`, uid/fsGroup 1000, seccomp `RuntimeDefault`, `enableServiceLinks: false`, `terminationGracePeriodSeconds` = the operator's drain timeout, `imagePullSecrets` from the operator's list; one container `worker` with port 4000, readiness `/health/ready` and liveness `/health/live` every 5 s after 5 s, all capabilities dropped.

Volumes and mounts (`resources.ex:700-780`): a projected volume `enrolment-token` with two ServiceAccount tokens — `token` (audience `troupe-plane`) and `kms-token` (audience `troupe-kms`), 3600 s — at `/var/run/secrets/troupe`; the `data` PVC at `/var/lib/troupe`; each team PVC at `/mnt/teams/<team>` (read-only for `ro`); `org` at `/mnt/org` read-only whatever the profile asked.

Environment injected: the full list with what reads it is [configuration.md A.3](configuration.md#a3-worker-release-troupe_worker). In short: `TROUPE_WORKER_AUTOSTART`, `TROUPE_PROFILE`, `TROUPE_NAMESPACE`, `TROUPE_WORKERS_DOMAIN`, `TROUPE_WORKERS_SCHEME`, `TROUPE_PLANE_CONTROL`, `TROUPE_BAO_ADDR`, `TROUPE_OBJECT_ENDPOINT`, `TROUPE_OBJECT_BUCKET`, `TROUPE_SESSIONS_PER_POD`, `TROUPE_CONFIG_CHANNEL`, `TROUPE_POD_ORDINAL` (the pod name), optionally `TROUPE_WORKERS_PORT` and `TROUPE_ALLOWED_ORIGINS`, object-store credentials from `TROUPE_OBJECT_SECRET_NAME` (optional), `TROUPE_BASE_URL`/`TROUPE_PROVIDER`/`TROUPE_MODEL`/`TROUPE_SMALL_MODEL`/`TROUPE_API_KEY` from `llm`, `TROUPE_MCP_SERVERS` as JSON and one optional variable per MCP `secretRef`, plus `TROUPE_SCHEDULERS` and `ERL_FLAGS` (`resources.ex:532-698`).

Labels on everything the operator writes: `app.kubernetes.io/name=troupe-worker`, `app.kubernetes.io/instance=<p>`, `app.kubernetes.io/managed-by=troupe-operator`, `troupe.dev/profile=<p>`, and `troupe.dev/managed=operator` on objects the operator wrote directly (`names.ex:86-110`). **No owner references**: they cannot cross namespaces, so the operator prunes Services, PVCs, Ingresses, NetworkPolicies and PDBs that carry its labels and are no longer desired (`resources.ex:40-57`; `reconciler.ex:29-37,264-303`). Discrepancy: `resources.ex:10-12` (moduledoc) still says every object carries an owner reference ([AUDIT.md §2](../AUDIT.md)). Deleting a `WorkerProfile` deletes the whole namespace (`controller/worker_profile.ex:25-54`).

---

## 3. Status conditions

Written by the reconciler on every pass (`reconciler.ex`), with `lastTransitionTime` moving only when the status changes and `observedGeneration` naming the spec generation (`status.ex:1-32`).

| Condition | `True` means | `False` means | Reasons | Source |
|---|---|---|---|---|
| `Ready` | every manifest applied (`Reconciled`, message counts resources and prunes) | `PolicyViolation`, `NoPolicy`, or `ApplyFailed` with the failing kinds | `Reconciled`, `ApplyFailed`, `PolicyViolation`, `NoPolicy` | 106-118, 152-177, 320-331 |
| `PolicyViolation` | the profile exceeds the policy; **nothing is created** — no namespace, no pods (`OutsidePolicy`), or no `TroupePolicy` could be read at all (`NoPolicy`) | `WithinPolicy` | `OutsidePolicy`, `NoPolicy`, `WithinPolicy` | 101-118, 157, 318-331 |
| `SecretMissing` | a referenced LLM or MCP Secret was not found — **in `troupe-system`**, and via a `get` the operator's RBAC does not allow — so treat `True` as uninformative | `SecretsPresent` | `SecretsMissing`, `SecretsPresent` | 179-209; [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects) |
| `UpgradePending` | the StatefulSet's `updateRevision` differs from `currentRevision` and the named pods still carry the old `controller-revision-hash` (`WaitingForIdle`) | `UpToDate` | `WaitingForIdle`, `UpToDate` | 211-257 |

`SecretMissing` and `UpgradePending` do not affect `Ready` (`reconciler.ex:201-205,211-214`).

```bash
kubectl -n troupe-system get workerprofiles
```

```bash
kubectl -n troupe-system get workerprofile <profile> -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

---

## 4. How an upgrade works

The StatefulSet is `OnDelete` because a pod holds live sessions (`resources.ex:448-450`). Changing the image, env or volumes therefore produces a new revision and `UpgradePending: True` naming the pods behind (`reconciler.ex:211-257`) — and nothing else. The operator **never deletes a pod** (its RBAC allows it, `operator-rbac.yaml:25-27`, but no code path does); the plane's `admin.pod.drain` marks the pod draining, pushes `drain` with the timeout, waits for the pod to report empty and checks its own index (`apps/troupe_plane/lib/troupe/plane/drain.ex:25-60`), but the plane's Role has no pod delete either (`plane-rbac.yaml:17-24`). `Drain`'s moduledoc says removing the pod "is the operator's business" (`drain.ex:14-16`); the operator has no such code. **Confirmed: nothing restarts a drained pod** — on 2026-09-19 `troupe-w-dev-0` had sat Not Ready for five days after a console drain ([AUDIT.md §3.13](../AUDIT.md), Decision 633). The procedure is therefore: drain with `troupe admin pod drain`, then `kubectl delete pod` by hand, every time ([routine-tasks.md §9](routine-tasks.md#9-drain-a-pod-restart-it-scale-a-profile)). Until the pod is deleted the plane lists it as `draining`, places nothing on it and reads nothing from it; the recreated pod reports itself not draining when it enrols, which is what lowers the flag.

Sessions on a pod being upgraded are not lost: drain moves them to dormancy (sealed to object storage), and the highest ordinal drains first because a StatefulSet removes pods in that order (`drain.ex:3-12`).

---

## 5. TroupePolicy

Cluster-scoped, short name `tpol`, owned by a cluster admin; the plane may only read it (`crds/troupepolicy.yaml:1-19`; `plane-rbac.yaml:41-52`). The chart installs one named `policy.name` with `helm.sh/resource-policy: keep` (`templates/policy-default.yaml`).

| Field | Meaning | Default when absent (operator) | CRD line |
|---|---|---|---|
| `allowedImageRepositories[]` | repositories a profile's image may come from, compared without tag or digest; exact match or prefix `<repo>/` | `[]` (every image refused) | 31-34 |
| `maxReplicas` (≥ 1) | ceiling on `spec.replicas` | 10 | 35 |
| `maxSessionsPerPod` (≥ 1) | ceiling on `sessionsPerPod` | 16 | 36 |
| `maxResources.cpu`, `.memory` | ceiling on **limits** (requests are not checked) | 4 CPU, 8Gi | 37-41 |
| `allowedEgress[]` | hostnames the pods may reach, including the LLM endpoint and MCP servers; `*.example.com` matches exactly one label; a bare `*` is not accepted | `[]` | 42-47 |
| `allowedStorageClasses[]` | classes a team volume or the pod disk may name | `[]` | 48-50 |
| `orgVolume {storageClassName, size, nfsPath, nfsServer}` | the org-wide read-only volume profiles may opt into | none (any `orgMount: true` is a violation) | 51-58 |
| `namespacePrefix` | worker namespace prefix; also what enrolment strips to find the profile | `troupe-w-` | 59 |
| `workersDomain` | domain of every pod hostname | `workers.example.test` | 60 |

Operator defaults are in `Troupe.Policy` (`apps/troupe_protocol/lib/troupe/policy.ex:19-29,44-59`).

### Enforced twice

1. **Admission**: a `ValidatingAdmissionPolicy` with `paramKind: TroupePolicy`, `failurePolicy: Fail`, bound with `validationActions: [Deny]` and `parameterNotFoundAction: Deny` (`templates/admission-policy.yaml:12-27,129-141`). It refuses on CREATE/UPDATE of a `WorkerProfile`: image repository (`:61-66`), replicas (`:68-70`), sessionsPerPod (`:72-77`), cpu and memory **limits** (`:79-99`), every host in LLM endpoint + MCP URLs + `fqdns` + `gitHosts` against `allowedEgress` (`:33-49,104-117`), storage classes named by **team entries and `spec.storage`** (`:54-59,119-123`), and `orgMount` without `orgVolume` (`:125-127`). Needs Kubernetes ≥ 1.30 (`values.yaml:251-255`).
2. **The operator**: `Troupe.Policy.violations/2` runs on every reconcile with the policy re-read each pass (`reconciler.ex:94-118,305-316`); a violation writes `PolicyViolation: True` and creates nothing.

Asymmetry: the operator's storage check covers **team entries only** (`policy.ex:171-178`), not `spec.storage.storageClassName`; admission covers both. With admission unavailable, a profile can name a disallowed class for its own disk and still be reconciled. Also, the plane's fast-feedback check reads the policy through `Troupe.Plane.ClusterPolicy`, which needs `:k8s_conn` (§7) and otherwise allows every host with one warning (`cluster_policy.ex:57-60,99-107`).

The policy name every reader uses is `TROUPE_POLICY_NAME` or `default` (`reconciler.ex:310`; `cluster_policy.ex:94-97`); the chart never sets that variable, so `policy.name` must stay `default` ([configuration.md A.7](configuration.md#a7-variables-with-two-meanings-and-variables-nobody-reads)).

---

## 6. TeamVolume

`crds/teamvolume.yaml`: namespaced, short name `tvol`, `spec.team` and `spec.size` required, optional `storageClassName`, `nfsPath`, `nfsServer`; status `claimName` and conditions (`:26-51`).

What the operator does with one: writes `status.claimName = team-<team>` and `Ready: True (Declared)` and nothing else (`reconciler.ex:76-90`). The claims that bind a team's storage into a namespace are created by the **profile** reconcile from `spec.teams` (§2), with the access mode `ReadWriteMany` for `rw` — which on Scaleway needs the File Storage class `scw-sfs`, not block storage (`values.scaleway.yaml:145-151`). Discrepancy: `crds/teamvolume.yaml:1-2` says the plane creates one when a team is enabled; the plane writes only `WorkerProfile` (`provision.ex:166-185`; [AUDIT.md §2](../AUDIT.md)). The plane's grant carries a `volume` name `troupe-team-<team>` and a `mode` (`provision.ex:187-200`) while the operator's claim is `team-<team>` (`names.ex:66-68`) — the CRD field is `claimName`, so the manifest key `volume` is not the one the operator reads (`worker_profile.ex:142-150`). Unconfirmed whether that mismatch is intended; a `claimName` set by hand would be honoured.

**Team volumes are mounted on pods but not into sessions.** The pod has `/mnt/teams/<name>` and `/mnt/org`, but `Troupe.Worker.Session.Restore.start/3` passes no `:mounts`, so a session's mount table is `session:/` plus `skills:/` only and `publish`/`import` have nowhere to go on a pod today ([AUDIT.md §3.2, §4.11](../AUDIT.md)). Grant volumes for what they will become, not for what they do now.

---

## 7. Provisioning: how the plane's row becomes a CR

The plane keeps a `profiles` row (name, image, size_class, max_sessions, warm_workers, replicas, sessions_per_pod, `spec`) and renders the CR from it (`provision.ex:166-200`): `metadata.name` = the profile name in namespace `troupe-system` with label `troupe.dev/managed-by: plane`, `spec` = the stored spec merged with `image` (split into repository and tag or digest, `:99-123`), `replicas`, `sessionsPerPod` and the `teams` projection from grants. Every `admin.profile.put`, `admin.team.grant`/`revoke` (`sync_teams`, `:158-164`) and every bundle publish/retire (`bundles.ex:418-449`) re-renders and re-applies.

Two modes, the `provisioning_mode` setting (`provision.ex:33-35`):

| Mode | What `apply/2` does | Reported state | Source |
|---|---|---|---|
| `direct` | server-side apply with field manager `troupe-plane`, `force: true`; delete is a plain delete and NotFound counts as success | `applied` with the generation | `provision.ex:204-238` |
| `gitops` | writes `profiles/<name>.yaml` in the configured repository, commits as `troupe-plane <subject>` and pushes if there is a remote | `pending` with the commit sha until `status.observedGeneration` catches up | `provision.ex:256-341` |

**The `:k8s_conn` caveat.** Direct mode needs `Application.get_env(:troupe_plane, :k8s_conn)` (`provision.ex:242-250`); the policy reader needs the same (`cluster_policy.ex:66-72`); GitOps needs `:gitops[:path]` (`provision.ex:318-323`). Nothing under `config/` or `apps/*/lib` sets any of them. In a deployed plane a direct `profile.put` is therefore saved in the database and reported `state: :not_applied, reason: :no_cluster` rather than failing (`admin.ex:899-912`; `bundles.ex:438-449`), and every bundle egress check allows every host with one warning. Enrolment builds its own connection and is unaffected (`enrolment.ex:169-185`). **Unconfirmed** whether a release hook sets it or the deployed plane only drafts profiles — [AUDIT.md §3.1, §4.3](../AUDIT.md). Until confirmed, apply the CR yourself:

```bash
troupe admin profile show <profile>
```

then write the `spec` into a `WorkerProfile` manifest and `kubectl apply` it, or apply from the GitOps path.

Conditions the console shows are read from the live CR when there is a connection and are empty otherwise (`provision.ex:343-367`).

---

## 8. The console profile editor

`/admin/profile/new` and `/admin/profile/:profile`, platform admins only (`web/admin_router.ex:58-61`). The full spec is a form; a blank field is absent from the resource rather than empty in it; the policy verdict and the diff are computed by `admin.profile.preview` before the single apply button, which is labelled for what `provisioning_mode` will actually do (`ARCHITECTURE.md:651-664`). The diff shown is the one the audit row records (`audit.ex:56-98`).

---

## 9. `troupe admin profile …`

| Command | Method | Notes |
|---|---|---|
| `troupe admin profile put FILE` | `admin.profile.put` | FILE is a JSON object; the plane reads it as the `profile` argument. **Absent fields are not preserved** (`admin/api.ex:221-229`) |
| `troupe admin profile check FILE` | `admin.profile.preview` | policy verdict, diff and mode, nothing written |
| `troupe admin profile show NAME` | `admin.profile.get` | spec, verdict, bundle state, conditions |
| `troupe admin profile delete NAME` | `admin.profile.delete` | sessions become read-only; the namespace is deleted by the operator |
| `troupe admin profiles` | `admin.profiles.list` | pods, conditions, load |

A `profile.json` built from the CRD fields (`admin/api.ex:44-75` for the top level, `crds/workerprofile.yaml` for `spec`):

```json
{
  "name": "dev",
  "image": "rg.fr-par.scw.cloud/troupe/troupe-worker:0.2.0",
  "replicas": 2,
  "sessions_per_pod": 4,
  "spec": {
    "resources": {
      "requests": {"cpu": "500m", "memory": "1Gi"},
      "limits": {"cpu": "2", "memory": "4Gi"}
    },
    "llm": {
      "endpoint": "https://llm-gw.itmindsinternal.dk/v1",
      "provider": "openai",
      "model": "code-default",
      "secretRef": {"name": "llm-credentials", "key": "api-key"}
    },
    "egress": {"fqdns": [], "gitHosts": ["github.com"]},
    "configBundleChannel": "stable",
    "storage": {"size": "20Gi", "storageClassName": "scw-bssd"},
    "orgMount": false
  }
}
```

`image` is one string (`repository:tag` or `repository@sha256:…`); the plane splits it (`provision.ex:99-123`). Do not put `mcpServers` or `teams` in `spec`: the plane overwrites both from the bundle and from grants. The endpoint host, `gitHosts` entries and every MCP host must match `allowedEgress`; the limits must be within `maxResources`; the storage class within `allowedStorageClasses`.

---

## 10. Egress model

A worker pod may reach six kinds of destination plus DNS (`ARCHITECTURE.md:349-360`; `resources.ex:297-335`): the plane's control port, OpenBao, object storage, the LLM endpoint, the profile's MCP servers, and its git hosts. Plain `NetworkPolicy` cannot name a hostname, so the external ones are one wide rule — `0.0.0.0/0` except private and link-local ranges, ports 443 and 80 — and the precise per-host rules exist only in the `CiliumNetworkPolicy` written when `operator.ciliumAvailable: true` (`resources.ex:270-274,385-417`). Without Cilium, a pod can reach any public host on 443/80 regardless of `allowedEgress`; the policy is then a check at admission and reconcile, not on the wire ([configuration.md Part E](configuration.md#part-e--ports-and-network-policy)). A wildcard pattern means one label everywhere: `Troupe.Policy.matches?/2` (`policy.ex:146-167`), the CEL (`admission-policy.yaml:101-109`) and Cilium's `matchPattern` (`resources.ex:406-417`).

---

## 11. Sizing

- **Sessions per pod** is the number that sizes everything: a pod holds a process tree per *active* session and nothing per dormant one (`docs/deploying-on-scaleway.md:249-251`). `values.small.yaml:146-149` reasons that four concurrent sessions share 4Gi comfortably and eight would not.
- **Pod disk**: `storage.size`, default `20Gi`, `ReadWriteOnce`, one per pod from the volume claim template; immutable afterwards (`resources.ex:461-476`; CRD `:100-114`). Placement skips a pod above 80 % disk and the worker evicts caches above 70 % (`apps/troupe_plane/lib/troupe/plane/fleet.ex:152-158`; `apps/troupe_worker/lib/troupe/worker/disk/watch.ex:27`).
- **`+Q`**: every BEAM in the deployment sets the port table by hand because a container runtime's `RLIMIT_NOFILE` would make it 1.5 GB (`plane-deployment.yaml:178-189`):

| Component | `+Q` from | Default |
|---|---|---|
| worker pods | `TROUPE_MAX_PORTS` ← `operator.maxPorts` | 65536 (`resources.ex:554`) |
| plane and migration Job | `plane.maxPorts` | 65536 (`plane-deployment.yaml:86,203-205`) |
| operator | `operator.maxPorts` | 65536 (`operator-deployment.yaml:60`) |
| a2a | `a2a.maxPorts` | 65536 (`a2a-deployment.yaml:81`) |

- **Requests and limits** from `values.small.yaml`, with the reasons written there: operator 50m/96Mi → 300m/256Mi ("idles at a few tens of MiB … 256Mi is the ceiling for a resync of every profile at once", `:31-36`); plane 100m/256Mi → 500m/768Mi ("the limit is deliberately three times the request because a plane that is OOMKilled restarts as the only plane there is", `:78-86`); policy ceiling 3 replicas × 4 sessions × 2 CPU / 4Gi per pod, because "two small nodes hold the plane, the operator, OpenBao, the ingress controller and cert-manager with room for about three worker pods" (`:140-155`). A profile that asks for more than a node can give is admitted and never scheduled (`:150-152`).
- The default `values.yaml` allows 8 replicas, 8 sessions per pod and 4 CPU / 8Gi per pod (`values.yaml:237-241`).
