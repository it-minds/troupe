# Profiles from a repository

On a plane with `plane.provisioningMode: gitops`
([profiles-and-policy.md §6](profiles-and-policy.md#6-provisioning-direct-or-from-a-repository))
a repository holds the `WorkerProfile` manifests; Flux, Argo CD or a pipeline running
`kubectl apply --server-side` applies them, and the plane never writes git and holds no
credential for it (Decision 736). The same repository can hold the triggers
([bundles-and-triggers.md](bundles-and-triggers.md#triggers-from-a-repository)) and the
GitHub App's settings ([github.md §10](github.md#10-the-app-from-a-repository)). Teams, their
grants and service principals stay in the plane's database.

## What the plane reads

Every fifteen seconds the plane lists the `WorkerProfile` resources in its namespace and
makes its rows follow them. A new resource becomes a profile, a change changes it, and a
resource that goes takes its profile with it, its sessions becoming read-only as with a
delete; each is audited as `profile.put` or `profile.delete` by `system:gitops`. The
scaler's count is the plane's: a row takes `spec.replicas` from the resource when it is
made, and the scaler's number from then on. The same pass then reads the `Trigger`
resources (Decision 737) and the `GitHubApp`.

A resource is used only if the plane could have saved it itself: its annotations parse,
`spec.image` names a repository, `spec.sessionsPerPod` is a size class's (4 is `standard`,
2 is `heavy`), the cluster's `TroupePolicy` allows it, and it sets no field the plane
writes. One that fails is **refused**: a new one gets no profile, and a changed one leaves
the profile as the last version that passed, so a mistake in the repository does not take
down a running profile. The reasons are in the log once, in `admin.profiles.list` (each
profile carries `gitops`: the source, the generation it was read at, and a `problem` of
`refused`, `missing`, `plane_only` or `unwritten` with `reasons`; a refused resource with no
profile is listed with nothing running), and on the console's **Workers and pods** and the
profile's own page.

The console shows every profile read-only, marked **Locked to gitops** with
`plane.gitops.source`, and the Triggers page is locked too. `admin.profile.put` and
`admin.profile.delete` are refused as `managed_by_gitops` and audited with
`outcome: refused`. The plane writes its three fields (`spec.replicas`, `spec.teams`,
`spec.mcpServers`) onto a resource only where they differ from what it says, and only onto
one something else holds; its Role has no `create` or `delete` on `WorkerProfile`. A
`release` image is not followed: the manifest names its image.

What a profile takes from its resource:

| Profile | Resource |
|---|---|
| `image` | `spec.image`, as `repository:tag`, or `repository@digest` where it has one |
| `size_class` | `spec.sessionsPerPod`: 4 (the CRD's default) is `standard`, 2 is `heavy` |
| `max_sessions` | annotation `troupe.dev/max-sessions`; absent is no ceiling |
| `warm_workers` | annotation `troupe.dev/warm-workers`, 0 to 10; absent is 0 |
| `provisioner` | annotation `troupe.dev/provisioner`; absent is `kubernetes` |
| channel | `spec.configBundleChannel`; absent is `stable` |
| `budget_micros` | `spec.budgetMicros`; absent or 0 is none |
| `extends` | `spec.extends`, the one profile this one extends ([below](#a-manifest-that-extends-another)) |
| `spec` | the rest: `llm`, `egress`, `storage`, `resources`, `orgMount`, `repositoryOverridesBundle`, `personalTools`, `github`, `permissions`, `mcpIdentities` |

CPU, memory and disk are the manifest's to size, within the policy; the class the plane
places and scales by is read off `sessionsPerPod`.

## A profile in a repository

`admin.profiles.export` (the console's **Workers and pods**, **Manifests for a repository**)
gives every profile in this shape, the policy and every trigger. This one is written by hand:

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
scaler's), `spec.teams` (the grants', which stay in the plane's database),
`spec.mcpServers` (the channel's bundle's), `status`, or the annotation
`troupe.dev/drained`. The applier would put its value back at every reconcile, over the
plane's; a resource that sets one of the three is refused, naming who sets it. A resource
copied from `kubectl get -o yaml` also carries `metadata.managedFields`, `resourceVersion`,
`uid`, `generation` and `creationTimestamp`; the export leaves those out too.
`spec.mcpIdentities` is the repository's like the rest of the spec, so git says which
profile has which identity
([profiles-and-policy.md](profiles-and-policy.md#calling-an-mcp-server-as-the-profile)).

The policy is the chart's `policy.*` values, which are then the repository's already, or a
`TroupePolicy` manifest in the repository with `policy.install: false`; the export gives
one.

## A manifest that extends another

A manifest may name one profile it extends and say only what differs, by the rules of
[profiles-and-policy.md](profiles-and-policy.md#a-profile-that-extends-another) (Decision 913, #655):

```yaml
# profiles/data-team.yaml
apiVersion: troupe.dev/v1alpha1
kind: WorkerProfile
metadata:
  name: data-team
  namespace: troupe-system
spec:
  extends: standard
  llm:
    model: example-large-2
    secretRef: {name: troupe-llm-data, key: api-key}
  egress:
    fqdns: [warehouse.example.com]
  budgetMicros: 200000000
  permissions:
    deny: ["shell(curl)"]
```

Flux applies it as written: the image may be left to the parent, and nothing else is
required. At its next pass the plane reads every parent before the profiles that extend
it, resolves the chain against its rows, keeps the profile in effect as the child's, and
writes it flat into the resource's `status.effective`: the spec its pods run, the chain
(`[standard, data-team]`), `from` (each field and the profile it came from) and a
`revision`. The operator and the admission policy read the profile from there, with
`replicas`, `teams` and `mcpServers` from the spec as for any profile, so they only ever see
a flat profile. Flux owns the spec and the plane `status.effective`, so they never write the
same field; the plane's ServiceAccount may patch `workerprofiles/status` for this.

- **Before the plane has written the status** the child runs nothing: the operator says
  `Resolved: False, AwaitingPlane` and creates nothing, rather than make pods from what
  differs from the parent alone. Admission judges the manifest as written then (the image
  only where it names one), and the profile in effect at each later write that changes it.
- **A parent's change** reaches its children's status in the same pass, and their pods roll
  as for any change ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)).
  A change to the child's own manifest runs the last profile in effect until the plane's
  next pass has resolved it.
- **Refused**, and reported as any manifest is, with the last version that passed kept: a
  parent that is not a profile here, a cycle or a chain longer than four, a budget above the
  parent's, a rule the pods could not read, and a profile in effect the policy refuses. The
  parent is named in `spec.extends`; a `troupe.dev/extends` annotation is refused with that
  sentence.
- **Defaults are not the child's.** The API server fills `sessionsPerPod`,
  `configBundleChannel`, `orgMount` and `storage.size` into every resource from the CRD's
  defaults; in a child they count only where its manifest names them, so a default never
  replaces what the parent gives. `sessionsPerPod`, `resources` and `storage.size` are the
  repository's numbers here, inherited from the parent where the child sets none.
- **Stopping** is a manifest without `spec.extends`, whole again; the plane takes its block
  out of the status.

## The record of finished drains, under an applier

The plane records a finished drain
([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)) in the
annotation `troupe.dev/drained`, written server-side under a field manager of its own,
`troupe-plane-upgrade`. Flux's kustomize-controller also applies server-side, as
`kustomize-controller`, and owns only the fields its manifest names: an annotation the
manifest leaves out is the plane's alone, and every reconcile, drift correction included,
leaves it where it is. The same goes for the plane's three fields under `troupe-plane`. Two
things would break that: a manifest that names the annotation, which makes the applier its
co-owner, and listing the plane's field managers in kustomize-controller's
`--override-manager`, which hands their fields to Flux. `Troupe.Plane.GitopsTest` holds the
plane to this against a model of server-side apply's field ownership.

## Switching a running plane

**Direct to gitops.** Export the manifests, commit them, and let the applier apply them
while the plane is still in direct mode: it takes the fields over, and the workers do not
notice. Export with `admin.profiles.export` or the console's **Workers and pods**, not
`kubectl get workerprofiles`: a resource the plane wrote in direct mode has no field for a
profile's ceiling, warm count or provisioner, which the export gives as the
`troupe.dev/max-sessions`, `troupe.dev/warm-workers` and `troupe.dev/provisioner`
annotations, so a repository copied from the cluster resets all three at the switch, and
has no triggers. Then redeploy the plane with `plane.provisioningMode: gitops` and
`plane.gitops.source`. At its first pass the plane adopts every resource as it is:

- One only the plane has ever written (nothing applies it from a repository yet) is used as
  it is and reported `plane_only`, and the plane writes none of its fields until something
  else holds it: with nobody else owning the rest, a write of three fields would take them
  away.
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
- And the GitHub App, as a `GitHubApp` named `github`, never its key or webhook secret
  ([github.md §10](github.md#10-the-app-from-a-repository)). Until its manifest is
  committed the App is reported `missing` and goes on as it was; from the first pass that
  reads it, a team the manifest does not name lists no repository.

**Gitops to direct.** Stop the applier reconciling the profiles first (suspend the
Kustomization, or take them out of it), or it puts back the repository's version at its
next interval. Redeploy with `direct`. The profiles are what the plane last read; the
editor writes again, and each profile's first write applies the whole resource as
`troupe-plane`, taking its fields back. The three annotations stay on the resources,
unread. So do the `Trigger` resources: the triggers are what the plane last read, and the
console and `admin.trigger.put` change them again.
