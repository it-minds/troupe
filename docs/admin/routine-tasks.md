# Routine tasks

> Audited against troupe-remote commit 4083b1f (branch main), 2026-09-13. See [AUDIT.md](../AUDIT.md).
>
> Commit `4083b1f` (`TROUPE_OIDC_MCP_SCOPE`, `plane.oidc.mcpScope`) landed while this track was being written and is covered; line numbers are from that tree.

> **Re-audited 2026-09-14.** The client apps were deleted; this repository ships four
> images and the chart. The `troupe admin …` commands used throughout this track are the
> **terminal client's** rendering of the admin API, and that client is published from its
> own repository — `plane.cliUrl` is where you tell the front page it lives. Every command
> shown has three equivalents that do ship here: an `admin.*` JSON-RPC method at
> `POST /rpc`, the same method as an MCP tool at `POST /mcp`, and a page in the console at
> `/admin`. [roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table)
> is the method table; a step written as a command is a step, not a dependency on a binary.

Step lists with the exact commands. Every `troupe admin …` command is one call to the plane's `/rpc` with the token `troupe login` stored; the methods behind those commands are in [roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table). `kubectl` and `helm` commands assume the release name `troupe` in namespace `troupe-system`. Images and chart delivery are in [../developer/deployment.md](../developer/deployment.md); the CLI itself is documented, deprecated, in [../user/cli-reference.md](../user/cli-reference.md).

Marked where a step relies on something outside the repository or on behaviour that could not be confirmed.

---

## 1. Install fresh

Prerequisites: a cluster with a `NetworkPolicy`-enforcing CNI (Cilium on Kapsule), Kubernetes ≥ 1.30 for the admission policy, ingress-nginx, cert-manager, a PostgreSQL, an S3 bucket **with versioning on**, OpenBao with transit + KV v2 + Kubernetes auth, an OIDC provider with the device grant, and images in a registry ([integrations.md](integrations.md)).

1. Ingress controller and issuer (Scaleway shapes):

   ```bash
   helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace --values deploy/scaleway/ingress-nginx.values.yaml
   ```

   ```bash
   kubectl apply -f deploy/scaleway/cluster-issuer.yaml
   ```

   (`deploy/scaleway/ingress-nginx.values.yaml:3-5`; `cluster-issuer.yaml:3`.) Point the plane's and the workers' DNS records at the load balancer.

2. **Label the ingress namespace** — the plane's and every worker's NetworkPolicy admit only namespaces carrying it (`network-policy.yaml:26-36`; `resources.ex:284-291`):

   ```bash
   kubectl label namespace ingress-nginx troupe.dev/ingress=true
   ```

3. OpenBao:

   ```bash
   helm upgrade --install openbao openbao/openbao --namespace troupe-system --create-namespace --values deploy/scaleway/openbao.values.yaml
   ```

   Then initialise and unseal it, enable `transit` with key `troupe-session-tokens` (`ecdsa-p256`), configure Kubernetes auth with a reviewer JWT, write the policies from `Troupe.KMS.Policy` and the roles `troupe-worker` (audience `troupe-kms`) and `troupe-plane` — the exact commands, in development shape, are `dev/kind/dependencies.yaml:228-274`. Outside the repository: the unseal share handling and per-profile worker policies ([integrations.md §2](integrations.md#2-openbao)).

4. Secrets in `troupe-system` ([configuration.md Part D](configuration.md#part-d--secrets-the-chart-expects)):

   ```bash
   kubectl -n troupe-system create secret generic troupe-plane-database --from-literal=url='ecto://USER:PASS@HOST:5432/troupe_plane'
   ```

   ```bash
   kubectl -n troupe-system create secret generic troupe-plane-secret-key-base --from-literal=value="$(openssl rand -base64 64 | tr -d '\n')"
   ```

   ```bash
   kubectl -n troupe-system create secret generic troupe-object-store --from-literal=access-key-id=… --from-literal=secret-access-key=…
   ```

   ```bash
   kubectl -n troupe-system create secret generic troupe-plane-oidc --from-literal=client-secret=…
   ```

   Plus a pull secret if the registry is private, and the plane's TLS secret if cert-manager is not issuing it for you.

5. CRDs, explicitly, because Helm installs them once and never upgrades them (`values.yaml:5-9`):

   ```bash
   kubectl apply -f charts/troupe/crds/
   ```

6. Copy `charts/troupe/values.small.yaml` or `values.scaleway.yaml`, fill the `CHANGE ME` placeholders (registry, host, base URL, OIDC endpoints, `allowedEgress` with your LLM gateway host, `workersDomain`), set `plane.oidc.secretName: troupe-plane-oidc` if the console is wanted, and install:

   ```bash
   helm upgrade --install troupe charts/troupe --namespace troupe-system --create-namespace --values my-values.yaml
   ```

   The migration Job runs as a pre-install hook (`plane-deployment.yaml:35-49`). Check it and the plane:

   ```bash
   kubectl -n troupe-system get jobs,pods
   ```

   ```bash
   curl -s https://<plane host>/.well-known/troupe
   ```

7. First login, from a machine with the `troupe` binary:

   ```bash
   troupe login https://<plane host>
   ```

   You are a platform admin if the token's group claim carries `platformAdminGroup` — it does not require a team to exist (`admin.ex:84-89`). Check:

   ```bash
   troupe admin identity check
   ```

8. Enable the first team from an identity-provider group id, grant it a profile, and create the profile:

   ```bash
   troupe admin team enable <group external id>
   ```

   ```bash
   troupe admin profile put profile.json
   ```

   ```bash
   troupe admin team grant <team> <profile>
   ```

   The JSON shape is in [profiles-and-policy.md §9](profiles-and-policy.md#9-troupe-admin-profile-). **Caveat**: if the answer says `state: not_applied, reason: no_cluster`, the plane has no Kubernetes connection ([AUDIT.md §3.1](../AUDIT.md)); apply the `WorkerProfile` yourself from `troupe admin profile show <profile>` with `kubectl apply`.

9. Secrets in the worker namespace the operator created:

   ```bash
   kubectl -n troupe-w-<profile> create secret generic troupe-object-store --from-literal=access-key-id=… --from-literal=secret-access-key=…
   ```

   ```bash
   kubectl -n troupe-w-<profile> create secret generic <llm.secretRef.name> --from-literal=api-key=…
   ```

   And the pull secret again if needed. Watch the profile come up:

   ```bash
   kubectl -n troupe-system get wp -w
   ```

---

## 2. Upgrade

1. Apply the CRDs first — a new spec field is invisible otherwise (`docs/deploying-on-scaleway.md:322-324`):

   ```bash
   kubectl apply -f charts/troupe/crds/
   ```

2. Set the new image tag in your values (`operator.image.tag`, `plane.image.tag`, `a2a.image.tag`; an empty tag means the chart's `appVersion`, `plane-deployment.yaml:164`), then:

   ```bash
   helm upgrade troupe charts/troupe --namespace troupe-system --values my-values.yaml
   ```

3. The `pre-upgrade` hook migrates before the new pods start; a failed Job is kept with its logs (`plane-deployment.yaml:44-49`):

   ```bash
   kubectl -n troupe-system logs job/troupe-plane-migrate
   ```

4. A single-replica plane rolls by `Recreate` — a few seconds without a plane, live sessions unaffected (`plane-deployment.yaml:131-138`).
5. Verify:

   ```bash
   kubectl -n troupe-system rollout status deployment/troupe-plane
   ```

   ```bash
   troupe admin overview
   ```

6. Worker images are per profile, not per chart: change `image` with `troupe admin profile put`, then see §9 for the restart, because the StatefulSet is `OnDelete`.

---

## 3. Add a team

A group must have been *seen* — carried in somebody's token at login, or pushed by SCIM — before it can be enabled (`login.ex:52-61`; `admin.ex:263-290`).

```bash
troupe admin team enable <group external id>
```

Then edit budget and retention with a JSON file of the fields in [roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-method-table):

```bash
troupe admin team update <team> team.json
```

`budget_period` must be `monthly` or `never` (`identity/team.ex:69`).

### Remove a team

Ask first what goes with it — the grants, administrators, service principals, triggers
and group links all hang off the team and are removed with it; the people, the groups and
the sessions stay, the sessions with no team and read-only:

```bash
troupe admin team disable preview <team>
troupe admin team disable <team>
```

The console's Teams table has the same two steps as *delete* on the team's row.

---

## 4. Grant a profile to a team

```bash
troupe admin team grant <team> <profile>
```

Effective for sessions started afterwards; the plane re-renders the profile's `teams` projection (`provision.ex:158-164`). To revoke — sessions on it become read-only:

```bash
troupe admin team revoke <team> <profile>
```

---

## 5. Add a team admin

The subject is what the provider issues as `sub` (`admin/api.ex:366-371`):

```bash
troupe admin team admin add <team> <subject>
```

```bash
troupe admin team admin remove <team> <subject>
```

---

## 6. Create or rotate a service principal

```bash
troupe admin principal create <team> <name> <profile1,profile2>
```

The secret is in the output once (`principals.ex:26-59`). Rotate (the old secret stops at once) or disable:

```bash
troupe admin principal rotate svc:<team>/<name>
```

```bash
troupe admin principal disable svc:<team>/<name>
```

Tell every trigger and A2A caller that used the old secret.

---

## 7. Publish a bundle

Lay out a directory as `agents/<name>.md`, `skills/<name>/SKILL.md`, `mcp.yaml` ([bundles-and-triggers.md §1](bundles-and-triggers.md#1-config-bundles)), then:

```bash
troupe admin bundle validate ./bundle
```

```bash
troupe admin bundle publish stable ./bundle
```

Pods on the channel are told at once; adoption shows per pod in:

```bash
troupe admin bundle show stable <version>
```

To take a version out of service for new sessions:

```bash
troupe admin bundle retire stable <version>
```

---

## 8. Add an MCP server

1. Check the host against the cluster policy:

   ```bash
   troupe admin mcp check https://mcp.example.com/mcp
   ```

   If refused, add the host to `policy.allowedEgress` in your values and `helm upgrade` (the CR has `helm.sh/resource-policy: keep`, so it is updated in place, `policy-default.yaml:10`). The plane's check is open when it has no `:k8s_conn` ([profiles-and-policy.md §7](profiles-and-policy.md#7-provisioning-how-the-planes-row-becomes-a-cr)); the Cilium rule is what enforces it.

2. Create the token Secret in **every** worker namespace whose profile follows the channel (`bundles.ex:24-31,484-486`):

   ```bash
   kubectl -n troupe-w-<profile> create secret generic troupe-mcp-<server> --from-literal=token=…
   ```

3. Add the server to `mcp.yaml` with a `credential_ref` (an env-var name, never a value) and publish (§7). The plane rewrites `mcpServers` on the profile, the operator injects the variable, marked optional, and rolls a new StatefulSet revision — which waits for §9.

---

## 9. Drain a pod, restart it, scale a profile

Drain (platform admin; sessions go dormant and are placed elsewhere; the pod answers 503 on `/health/ready` meanwhile):

```bash
troupe admin profiles
```

```bash
troupe admin pod drain <worker id from the listing>
```

Nothing in the repository deletes the pod afterwards ([AUDIT.md §3.13](../AUDIT.md)), and a drained pod that is left running stays out of its Service — its readiness probe answers 503 until it is deleted, so the Ingress answers 503 to every client. **Always follow a drain with the delete below**, even when there is no new revision. While it waits, the plane lists the pod as `draining` and neither places on it nor reads from it (Decision 633); the recreated pod lowers the flag itself by enrolling. To pick up a new image or env (`UpgradePending: True`), the same delete:

```bash
kubectl -n troupe-w-<profile> delete pod troupe-w-<profile>-<ordinal>
```

The StatefulSet recreates it on the new revision; its PVC is reused. Highest ordinal first (`drain.ex:11-12`). Scale by changing `replicas` in the profile JSON and putting it again; the operator prunes the Services and Ingresses of pods that no longer exist (`reconciler.ex:264-303`) — drain the highest ordinals before scaling down.

---

## 10. Change a platform setting

```bash
troupe admin settings
```

```bash
troupe admin setting set default_idle_timeout_seconds 3600
```

```bash
troupe admin setting reset default_idle_timeout_seconds
```

Visible on the writing replica at once and everywhere within 5 s (`settings.ex:31-38`). Before changing `platform_admin_group`, check the candidate:

```bash
troupe admin identity check <candidate group id>
```

The console refuses to save it until that check passes for the value in the field (`web/live/settings.ex:38,90`); the CLI does not stop you.

---

## 11. Repair a locked-out admin group

Nobody is a platform admin because `platform_admin_group` or `groups_claim` is wrong (`settings.ex:5-11`).

1. Turn break-glass on (§12) if it is not.
2. Open `https://<plane>/admin/breakglass`, enter the token. The session is a platform admin for `lifetimeSeconds` and is written to the audit log (`web/admin_auth.ex:253-265`).
3. Go to `/admin/settings`, run the identity check against the right group, save `platform_admin_group` (and `groups_claim` if that was the problem). Or from a terminal — break-glass is console-only, so a CLI repair needs a token that is already a platform admin.
4. Sign in normally to confirm, then turn break-glass off (§12).

---

## 12. Enable or disable break-glass

Enable (`values.yaml:157-169`; `plane-deployment.yaml:303-316`):

```bash
kubectl -n troupe-system create secret generic troupe-plane-breakglass --from-literal=token="$(openssl rand -base64 48 | tr -d '\n')"
```

Set in values:

```yaml
plane:
  breakglass:
    secretName: troupe-plane-breakglass
    lifetimeSeconds: 3600
```

```bash
helm upgrade troupe charts/troupe --namespace troupe-system --values my-values.yaml
```

A rollout, because the token is read at boot. Disable: set `secretName: ""`, upgrade, delete the Secret. While off, `/admin/breakglass` is a 404 (`web/admin_auth.ex:238-244`).

---

## 13. Enable SCIM

From the console: **Identity provider → SCIM connector → create a token**. The token is
shown once, in the notice at the top of the page. Paste it into the provider's
provisioning as the secret token, with the base URL the card shows
(`https://<plane>/scim/v2`), keying users on `externalId` = the token subject
([integrations.md §8](integrations.md#8-scim)). The card's *last sync* moves on the
provider's first request, which is its connection test.

```bash
troupe admin scim get                      # status, last sync, whether a token is set
troupe admin scim rotate                   # a new token, shown once; the old one stops now
troupe admin scim delete <base url>        # no token: every push answers 401
troupe admin scim update '{"teams_from_groups": true}'   # pushed groups become teams
```

*Create teams from SCIM groups* is off until somebody turns it on. On, a pushed group
becomes a team named from its display name with the platform's defaults, audited as
`scim`; a group that is already a team or whose name another team holds is left for you.

The deployment's own token still works if you would rather keep the credential in a
secret (`plane-deployment.yaml:296-302`):

```bash
kubectl -n troupe-system create secret generic troupe-plane-scim --from-literal=token="$(openssl rand -base64 48 | tr -d '\n')"
```

Either token opens the door; deleting the console's leaves the deployment's where it is.

---

## 14. Enable the A2A facade

Set `a2a.enabled: true`, `a2a.host`, `a2a.tlsSecretName` (or `publicUrl`), optionally `a2a.visibility: team` (`values.yaml:179-211`), and upgrade. Create a service principal for each caller (§6). The card is at:

```bash
curl -s https://<a2a host>/a2a/<profile>/.well-known/agent-card.json
```

See [../a2a.md](../a2a.md).

---

## 15. Rotate the OIDC client secret

Update the Secret, then restart the plane — the value is read into the environment at pod start (`plane-deployment.yaml:288-295`):

```bash
kubectl -n troupe-system create secret generic troupe-plane-oidc --from-literal=client-secret=… --dry-run=client -o yaml | kubectl apply -f -
```

```bash
kubectl -n troupe-system rollout restart deployment/troupe-plane
```

Only console (authorization-code) logins use it; the CLI's device flow and workers are unaffected (`settings.ex:164-166`).

---

## 16. Rotate object-store credentials

The credentials are environment variables in the plane and in **every worker pod**, read at start.

1. Update `troupe-object-store` in `troupe-system` and in every `troupe-w-<profile>` (§1 step 4 and 9 with `--dry-run=client -o yaml | kubectl apply -f -`).
2. Restart the plane:

   ```bash
   kubectl -n troupe-system rollout restart deployment/troupe-plane
   ```

3. Worker StatefulSets are `OnDelete`: drain and delete each pod (§9), highest ordinal first, one profile at a time. Until a pod restarts it keeps writing with the old key; revoke the old key only after the last pod is on the new one.

---

## 17. Check identity

```bash
troupe admin identity check
```

Four checks with timings and the redirect URI to compare against the registration by eye (`oidc.ex:221-243`; `admin.ex:494-530`). With a group argument it tests a candidate before you set it.

---

## 18. Read the audit log

```bash
troupe admin audit
```

The console's `/admin/audit` shows the same rows. Filters are `actor`, `kind`, `subject_id`, `since`, `limit` (`audit.ex:136-144`); pass them through `/rpc` or the MCP tool `admin_audit_list` — the CLI command takes no arguments.

---

## 19. Erase a session

Irreversible: the key is destroyed first, then every object version; the owner is not notified; spend stays in the ledger; the audit row survives with your name (`admin/api.ex:404-418`; `erasure.ex:1-21`).

```bash
troupe admin sessions
```

```bash
troupe admin session erase <session id>
```

If no healthy pod of the profile is reachable the erasure is recorded as pending and carried out when one enrols (`erasure.ex:70-76,126-150`).

---

## 20. Run the PITR drill

Development stack only (`scripts/pitr-drill:4-7`):

```bash
scripts/dev-up
```

```bash
scripts/pitr-drill
```

See [backup-restore.md §2](backup-restore.md#2-what-the-repository-provides).

---

## 21. Rebuild the session index

After a database restore, or whenever the index and object storage may disagree (`lib/mix/tasks/troupe.index.rebuild.ex:4-19`):

```bash
kubectl -n troupe-system exec deploy/troupe-plane -- /app/bin/troupe_plane eval 'IO.inspect(Troupe.Plane.Index.rebuild())'
```

Locally: `mix troupe.index.rebuild [--database-url URL]`. Unconfirmed against a live cluster.

---

## 22. Reconcile the ledger

Needs `:troupe_plane, :gateway` configured with `base_url` (or `spend_url`) and `key`, which nothing in the repository sets (`reconcile.ex:200-215`). Locally:

```bash
mix troupe.ledger.reconcile --days 1
```

Exits non-zero over 1 000 000 micros of drift (`reconcile.ex:40`; `troupe.ledger.reconcile.ex:63-65`).

---

## 23. Decommission a profile

1. Revoke it from every team, so no new session can start on it and existing ones go read-only:

   ```bash
   troupe admin team revoke <team> <profile>
   ```

2. Drain each pod so live sessions seal to object storage (§9).
3. Delete the profile; the operator deletes the whole `troupe-w-<profile>` namespace, PVCs included, and the plane removes the CR (`admin/api.ex:247-262`; `controller/worker_profile.ex:25-54`):

   ```bash
   troupe admin profile delete <profile>
   ```

4. Sessions that ran on it remain in object storage and in the index as read-only; erase them individually if they should go (§19). The Secrets in the namespace go with it; remove the profile's egress hosts from `allowedEgress` if nothing else uses them.
