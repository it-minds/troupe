# Administrator documentation

For whoever operates a Troupe deployment: the Helm chart, the PostgreSQL, object storage,
OpenBao and identity provider beside it, and the teams, profiles, policy, bundles, triggers
and backups on top.

| Document | What it covers |
|---|---|
| [installing.md](installing.md) | A cluster with nothing on it, to a first team in the console |
| [configuration.md](configuration.md) | Every environment variable, Helm value, platform setting, expected Secret, port and NetworkPolicy |
| [roles-and-permissions.md](roles-and-permissions.md) | Identity from the provider, admin roles, service principals, break-glass, session roles, how each surface authenticates, RBAC, OpenBao policies, the admin methods |
| [profiles-and-policy.md](profiles-and-policy.md) | Worker profiles, what the operator creates, conditions, upgrades and drains, `TroupePolicy`, team volumes, provisioning, sizing |
| [bundles-and-triggers.md](bundles-and-triggers.md) | Config bundles and MCP servers, triggers and the scheduler, unattended terms, budgets |
| [integrations.md](integrations.md) | What the identity provider, OpenBao, PostgreSQL, object storage, the LLM gateway, Kubernetes, MCP, SCIM and the GUI require |
| [authentik.md](authentik.md) | Moving a plane's sign-in and provisioning to Authentik, in order |
| [single-machine.md](single-machine.md) | A worker on a machine you already have, and what it gives up |
| [backup-restore.md](backup-restore.md) | Where state lives, what can be rebuilt, restore procedures |
| [monitoring.md](monitoring.md) | Health endpoints, signals, the audit log, logs worth alerting on, a troubleshooting table |
| [routine-tasks.md](routine-tasks.md) | Step lists: upgrades, teams, principals, bundles, drains, settings, lock-outs, SCIM, rotations, erasure |

Also: [../deploying-on-scaleway.md](../deploying-on-scaleway.md), [../a2a.md](../a2a.md)
and [../egress-allowlist.md](../egress-allowlist.md).

## Before the first `helm install`

1. **Troupe creates no Secrets.** Every one in
   [configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects) must exist
   first, and the object-store, model, MCP and pull secrets in **every** worker namespace as
   well as `troupe-system`.
2. **CRDs are installed once by Helm and never upgraded**: `kubectl apply -f
   charts/troupe/crds/` on every upgrade.
3. **Label the ingress namespace** `troupe.dev/ingress=true`, or every worker Ingress
   answers 503.
4. **Platform admin comes from an identity-provider group** carried in a claim, never a
   scope: ask Entra for a `groups` scope and it refuses every sign-in.
5. **Bucket versioning must be on**, or erasure's promise means nothing.
6. **Do not trust `SecretMissing`**: the operator has no RBAC on Secrets.
7. **Nothing restarts a drained worker pod.** After `admin.pod.drain`, delete the pod.
8. **Triggers, principals, settings and the audit trail live only in PostgreSQL.** The
   session index can be rebuilt from object storage; they cannot.
9. **There is no metrics exporter, backup CronJob, OpenBao snapshot or webhook endpoint**
   in the repository.
