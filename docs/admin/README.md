# Administrator documentation

For whoever operates a Troupe deployment: the Helm chart, the PostgreSQL, object storage,
OpenBao and identity provider beside it, and the teams, profiles, policy, bundles, triggers
and backups on top.

| Document | What it covers |
|---|---|
| [installing.md](installing.md) | A cluster with nothing on it, to a first team in the console; a worked example on managed services |
| [configuration.md](configuration.md) | Every environment variable, Helm value, platform setting, expected Secret, port and NetworkPolicy |
| [console.md](console.md) | The console at `/console`: where it is, how it is signed in to, and what each area does |
| [roles-and-permissions.md](roles-and-permissions.md) | Identity from the provider, admin roles, service principals, break-glass, session roles, how each surface authenticates, RBAC, OpenBao policies, the admin methods |
| [profiles-and-policy.md](profiles-and-policy.md) | Worker profiles, what the operator creates, conditions, upgrades and drains, `TroupePolicy`, team volumes, provisioning, sizing |
| [gitops.md](gitops.md) | Profiles held in a repository: what the plane reads, the manifests, and switching a running plane |
| [bundles-and-triggers.md](bundles-and-triggers.md) | Config bundles and MCP servers, triggers and the scheduler, unattended terms, budgets |
| [integrations.md](integrations.md) | What the identity provider, OpenBao, PostgreSQL, object storage, the LLM gateway, Kubernetes, MCP, SCIM and the GUI require |
| [openbao.md](openbao.md) | What OpenBao must grant the plane, generated from the code that checks it at start and on the Overview, and the lines an OpenBao administrator runs |
| [github.md](github.md) | The plane's GitHub App: registering and installing it, giving the plane its key, the read-only token a session clones its repository with, and the fix loop: a `troupe/*` branch, a draft pull request and its CI, never a merge |
| [authentik.md](authentik.md) | Connecting a plane's sign-in and provisioning to Authentik, in order |
| [single-machine.md](single-machine.md) | A worker on a machine you already have, and what it gives up |
| [upgrading.md](upgrading.md) | From one release to the next: the backup, the CRDs, the chart and its migration, what to watch, what the plane checks, going back, and the restore |
| [backup-restore.md](backup-restore.md) | Where state lives, what can be rebuilt, restore procedures |
| [monitoring.md](monitoring.md) | Health endpoints, signals, the audit log, logs worth alerting on, a troubleshooting table |
| [routine-tasks.md](routine-tasks.md) | Step lists: upgrades, teams, principals, bundles, drains, settings, lock-outs, SCIM, rotations, erasure |
| [security.md](security.md) | For a security reviewer: what Troupe does unasked and never does, isolation, keys, signed releases, unsigned apps, the limits' strength, logs and erasure |

Also: [../a2a.md](../a2a.md) and [../egress-allowlist.md](../egress-allowlist.md).

## Before the first `helm install`

1. **Troupe creates no Secrets.** Every one in
   [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects) must exist
   first, and the object-store, model, MCP and pull secrets in **every** worker namespace as
   well as `troupe-system`.
2. **CRDs are installed once by Helm and never upgraded**: `kubectl apply -f
   charts/troupe/crds/` on every upgrade.
3. **Label the ingress namespace** `troupe.dev/ingress=true`, or the network policies
   keep the ingress controller from the console, the API, `/app` and every worker.
4. **Platform admin comes from an identity-provider group** carried in a claim; whether
   the claim needs a scope is the provider's ([integrations.md §1](integrations.md#1-identity-provider-oidc)).
5. **Bucket versioning must be on**, or erasure's promise means nothing.
6. **Do not trust `SecretMissing`**: the operator has no RBAC on Secrets.
7. **Nothing restarts a drained worker pod** on the current revision. After
   `admin.pod.drain`, delete the pod; one behind a new revision the operator replaces.
8. **Principals, settings, the audit trail and triggers live only in PostgreSQL** (in
   gitops mode a trigger's definition is the repository's). The session index can be
   rebuilt from object storage; they cannot.
9. **There is no metrics exporter, backup CronJob or OpenBao snapshot** in the repository.
10. **Read [security.md](security.md)** before people install the clients: what Troupe
    does unasked, how releases are verified, and how to open the unsigned apps.
