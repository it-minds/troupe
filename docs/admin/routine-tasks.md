# Routine tasks

Step lists for the common changes. Each administrative step names the `admin.*` method it
is; run it from its console page at `/admin`, as the MCP tool of the same name with
underscores (`admin_team_enable`) on `/mcp`, or as JSON-RPC on `/rpc` with a plane token.
Arguments and their meanings are in the method table
([roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-methods)). `kubectl` and
`helm` assume the release `troupe` in `troupe-system`. A fresh install is
[installing.md](installing.md).

## Upgrade

1. `kubectl apply -f charts/troupe/crds/` — Helm never upgrades CRDs, and a new field is
   invisible without it.
2. Set the image tags in your values (empty means the chart's `appVersion`) and
   `helm upgrade troupe charts/troupe -n troupe-system --values my-values.yaml`. The
   `pre-upgrade` hook migrates first; `kubectl -n troupe-system logs job/troupe-plane-migrate`
   if it fails. A single plane replica rolls by `Recreate`: seconds without a plane, live
   sessions unaffected.
3. `kubectl -n troupe-system rollout status deployment/troupe-plane`, then `admin.overview`.
4. Profiles whose image is `release` follow the chart; the others keep theirs until
   `admin.profile.put`. Pods move only when recreated — drain and delete them (below).

A release from this repository deploys itself; this is for a deployment of your own.

## Teams

- **Add**: a group must have been seen — in somebody's token at sign-in, or pushed by
  SCIM — before `admin.team.enable` can make it a team. Edit budget, period (`monthly` or
  `never`), idle timeout and retention with `admin.team.update`. A team can draw its members
  from more groups: `admin.team.link`, `admin.team.unlink` (with `admin.team.unlink.preview`).
- **Remove**: `admin.team.disable.preview` says what goes with it — grants, admins,
  principals, triggers and group links — and what stays: people, groups, and the sessions,
  which lose their team and become read-only. Then `admin.team.disable`.
- **Grant a profile**: `admin.team.grant`, effective for sessions started afterwards.
  `admin.team.revoke` makes the team's sessions on it read-only.
- **Team admins**: `admin.team.admin.add` / `remove`, by subject — the string the provider
  issues as the person.

## Service principals

`admin.principal.create` with the team, a name and the profiles it may use; the secret is
in the answer once. `admin.principal.rotate` (the old secret stops at once) and
`admin.principal.disable`. Tell every trigger and A2A caller that used the old secret.

## Bundles and MCP servers

1. Check the server's host against the policy: `admin.mcp.check {url}`. If it is refused,
   add the host to `policy.allowedEgress` and `helm upgrade`.
2. Create the token Secret in every worker namespace whose profile follows the channel:
   `kubectl -n troupe-w-<profile> create secret generic troupe-mcp-<server> --from-literal=token=…`
3. Add the server to the bundle with a `credential_ref`, then `admin.bundle.validate` and
   `admin.bundle.publish {channel, content}`. Pods on the channel are told at once;
   `admin.bundle.get` shows adoption per pod. `admin.bundle.retire` takes a version out of
   service for new sessions. The new MCP variable is a new StatefulSet revision, which waits
   for the restart below.

## Drain, restart, scale

`admin.profiles.list` names the pods; `admin.pod.drain {worker_id}` sends their sessions to
dormancy, to be placed elsewhere. **Always follow a drain with**

```bash
kubectl -n troupe-w-<profile> delete pod troupe-w-<profile>-<ordinal>
```

because nothing else restarts a drained pod. The same delete picks up a new image or env
(`UpgradePending: True`); the volume is kept. Highest ordinal first. Scale with
`max_sessions` and `warm_workers` on `admin.profile.put`; the plane computes replicas.

## Settings

`admin.settings.list`, `admin.setting.put {key, value}`, `admin.setting.reset {key}`,
visible on the writing replica at once and everywhere within 5 s. Before changing
`platform_admin_group`, `admin.identity.check {group}` with the candidate; the console will
not save it otherwise.

## Locked out of the console

Nobody is a platform admin because `platform_admin_group` or `groups_claim` is wrong:

1. Turn break-glass on if it is not: a Secret with key `token`
   (`openssl rand -base64 48`), `plane.breakglass.secretName` naming it, `helm upgrade`.
2. Open `https://<plane>/admin/breakglass` and enter the token. You are a platform admin
   for the lifetime, marked on every page and in the audit log.
3. Check the right group and save it on the settings page.
4. Sign in normally to confirm; turn break-glass off (`secretName: ""`, upgrade, delete the
   Secret).

## SCIM

On the console's **Identity provider** card, *create a token* (`admin.scim.rotate`): shown
once. Give the provider the token and the base URL `https://<plane>/scim/v2`, keyed on
`externalId` = the subject. `admin.scim.get` shows the last request; `admin.scim.update
{teams_from_groups: true}` makes pushed groups teams; `admin.scim.delete` removes the
token. The deployment's `troupe-plane-scim` Secret (`plane.scim.enabled`) opens the door
too. Authentik, step by step: [authentik.md §4](authentik.md#4-scim-dry-run-first).

## The identity provider

The **Identity provider** card (`admin.provider.get`, `admin.provider.check`,
`admin.provider.put`, `admin.provider.reset`) changes the issuer, client, secret,
endpoints and scopes behind a check against what the provider publishes; it overrides the
deployment until reset. To rotate the client secret in the deployment instead, update
`troupe-plane-oidc` and `kubectl -n troupe-system rollout restart deployment/troupe-plane`.
Only console sign-in uses the secret.

## Rotate object-store credentials

Update `troupe-object-store` in `troupe-system` and in every worker namespace, restart the
plane, then drain and delete each worker pod, one profile at a time. Revoke the old key only
after the last pod runs on the new one.

## Erase a session

`admin.session.erase.preview`, then `admin.session.erase {session_id}`. Irreversible: the
key is destroyed first, then every object version; the owner is not told; spend stays in
the ledger; the audit row keeps your name. With no healthy pod of the profile the erasure is
pending until one enrols.

## Decommission a profile

1. `admin.team.revoke` it from every team: no new sessions, existing ones read-only.
2. Drain every pod.
3. `admin.profile.delete`: the operator deletes the `troupe-w-<profile>` namespace, volumes
   and Secrets included.
4. Its sessions stay in object storage and the index, read-only; erase any that should go,
   and drop its hosts from `allowedEgress` if nothing else uses them.

## Machines and hosts

`admin.host.register` (the secret is shown once), `admin.host.rotate`,
`admin.host.enabled`, `admin.hosts.list`, `admin.provisioners.list`:
[single-machine.md](single-machine.md).
