# Routine tasks

Step lists for the common changes. Each administrative step names the `admin.*` method it
is; run it from its console page at `/admin`, as the MCP tool of the same name with
underscores (`admin_team_enable`) on `/mcp`, or as JSON-RPC on `/rpc` with a plane token.
Arguments and their meanings are in the method table
([roles-and-permissions.md §9](roles-and-permissions.md#9-the-admin-methods)). `kubectl` and
`helm` assume the release `troupe` in `troupe-system`. A fresh install is
[installing.md](installing.md).

## Upgrade

1. `helm show crds "$chart" --version "$version" | kubectl apply --server-side
   --force-conflicts -f -`, with `$chart` and `$version` as in
   [installing.md §2](installing.md#2-crds-then-the-chart) — Helm never upgrades CRDs,
   and a new field is invisible without it.
2. Set the image tags in your values (empty means the chart's `appVersion`) and
   `helm upgrade troupe "$chart" --version "$version" -n troupe-system --values
   my-values.yaml --wait --timeout 10m --rollback-on-failure` (`--atomic` on Helm 3).
   The `pre-upgrade` hook migrates first; `kubectl -n troupe-system logs
   job/troupe-plane-migrate` if it fails. A single plane replica rolls by `Recreate`:
   seconds without a plane, live sessions unaffected.
3. `kubectl -n troupe-system rollout status deployment/troupe-plane`, then
   `curl -sS https://<plane host>/.well-known/troupe | jq .plane.build`: the version and
   commit must be the ones you rolled, or the rollout has not finished or a tag did not
   move. `kubectl -n troupe-system get pods -o
   custom-columns='POD:.metadata.name,IMAGE:.status.containerStatuses[0].imageID'` shows
   the digest each pod runs: a tag that already existed with `IfNotPresent` leaves the old
   image serving while Helm reports success. Then `admin.overview`.
4. Profiles whose image is `release` follow the chart; the others keep theirs until
   `admin.profile.put`. A pod moves to a new revision once it holds no active session: the
   plane drains it and the operator replaces it, one at a time; `admin.pod.drain` rolls a
   busy one sooner ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)).

**Upgrading to 0.17.0 from earlier, with workers running.** Workers before it ran under
the runtime's default seccomp profile and with the runtime's masked `/proc`, which between
them refuse bubblewrap its user namespace and its own `/proc`, so their pods refused every
command. The chart now gives the worker container its own seccomp profile
(`worker.seccomp`) and a DaemonSet to put it on the nodes, and runs each worker pod in a
user namespace of its own with its `/proc` unmasked (`worker.userNamespaces`)
([installing.md](installing.md#the-workers-seccomp-profile)). Before upgrading:

1. Run the cluster check in
   [installing.md](installing.md#the-workers-user-namespaces): Kubernetes 1.33 or later,
   containerd 2.0 or later, Linux 6.3 or later, and storage, team volumes' included, that
   takes idmapped mounts. A cluster that cannot sets `worker.userNamespaces: false`, and
   its workers go on refusing commands.
2. Give each worker namespace (`troupe-w-<profile>`) the `privileged` Pod Security level
   where the cluster's default is higher, or every replacement pod is refused, and the same
   for `troupe-system`, where the DaemonSet runs; or set
   `worker.seccomp.install.enabled: false` and install the profile another way.

After step 2 of the upgrade, `kubectl -n troupe-system rollout status
daemonset/troupe-worker-profiles` (`troupe-worker-seccomp` before 0.19.0). Both settings
change every profile's pod template, so each reports `UpgradePending` and its pods are
replaced as they empty (step 4); a pod replaced before the DaemonSet reached its node waits
in `CreateContainerError` until it has.

**Upgrading to 0.19.0 from earlier, with workers running.** On nodes that enforce
AppArmor (Ubuntu's), workers before it ran under the runtime's default AppArmor profile,
which refuses bubblewrap's mounts ("Failed to make / slave"), so their pods refused every
command there. The chart now gives the worker container an AppArmor profile of its own
(`worker.appArmor`, on by default) and loads it into every node's kernel
([installing.md](installing.md#the-workers-apparmor-profile)). The node sysctl
`kernel.apparmor_restrict_unprivileged_userns` stays as the node has it. What changes:

1. The DaemonSet is now `troupe-worker-profiles` (Helm removes `troupe-worker-seccomp` and
   makes it), and it has a second container, `apparmor`, with **a new privilege**: root in
   the node's user namespace with the `MAC_ADMIN` capability, no AppArmor profile of its own
   (`Unconfined`), and the host's `/sys/kernel/security` mounted. `troupe-system` already
   needs the `privileged` Pod Security level for the DaemonSet; nothing else is needed.
2. The operator's image carries `apparmor_parser` for it, and the DaemonSet runs that image.
3. Where the nodes run no AppArmor (most non-Ubuntu node images), set
   `worker.appArmor.enabled: false`: the kubelet refuses a pod that asks for a profile on a
   node without it ("Cannot enforce AppArmor"). Where something else loads the profile,
   set `worker.appArmor.install.enabled: false` and `worker.appArmor.profile` to its name.

The setting changes every profile's pod template: each reports `UpgradePending` and its
pods are replaced as they empty, under the profile. `kubectl -n troupe-system rollout status
daemonset/troupe-worker-profiles` says every node has it.

**Upgrading to 0.20.0 from earlier.** The control port now takes TLS only by default
(`plane.controlTls.requireTls: true`): a worker that dials it in plaintext is closed
before it is read, and cannot reach the plane until it is replaced. Every pod a 0.19
operator made dials with TLS, so check first that none older is left:

1. `kubectl -n troupe-system logs <plane pod> | grep 'enrolled as'` on every plane
   replica: each pod says once, when it enrols, whether it came "over TLS" or "in
   plaintext", and every pod enrols again when the plane restarts. A pod whose last line
   says "in plaintext" and that still runs is one an operator before 0.19 made;
   `admin.pod.drain` it, or wait for it to empty and be replaced, until none is left.
2. Or upgrade with `plane.controlTls.requireTls: false`, and turn it on once the log is
   clear. An installation without TLS on the control port
   (`plane.controlTls.enabled: false`) sets `requireTls: false` too, or the chart refuses
   to render.

After the upgrade, a pod still dialling in plaintext shows as a warning, "refused a
plaintext control connection", once a minute per address with the count of the rest. A
profile whose namespace has no `troupe-plane-ca` yet says so in its `PlaneCAMissing`
condition.

**Identity, from 0.20.0.** A sign-in or a SCIM push that finds nobody under its subject
adopts the row SCIM gave that `externalId` only when the row's email or `userName` agrees
with the token's or the push's. Otherwise the sign-in gets a row of its own, a push is
refused (`409`, `uniqueness`), the refusal is audited as `person.adopt_refused`, and
`admin.identity.duplicates` lists the pair ([§SCIM](#scim)). A SCIM `PUT` to
`/Users/<id>` changes the person at that id, and a push under a `removed:` or `svc:`
subject is refused. A person SCIM deletes comes off every trigger's `notify` list, and
their spend stays with their tombstone.

A release publishes the chart and the images and deploys nothing; every deployment rolls
it this way, from wherever it keeps its own values.

## Teams

- **Add**: a group must have been seen — in somebody's token at sign-in, or pushed by
  SCIM — before `admin.team.enable` can make it a team. Edit budget, period (`monthly` or
  `never`), idle timeout and retention with `admin.team.update`. A team can draw its members
  from more groups: `admin.team.link`, `admin.team.unlink` (with `admin.team.unlink.preview`).
- **Remove**: `admin.team.disable.preview` says what goes with it — grants, admins,
  principals, triggers and group links — and what stays: people, groups, and the sessions,
  which lose their team and become read-only. Then `admin.team.disable`.
- **Grant a profile**: `admin.team.grant`, effective for sessions started afterwards.
  `admin.team.revoke` makes the team's sessions on it read-only: the running ones are put
  to sleep on their pods, and the ones waiting for a worker are never started.
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
dormancy, to be placed elsewhere. A pod on an older revision (`UpgradePending: True`, after
a new image or env) needs nothing more: once it is drained, by you or by the plane when it
holds no session, the operator replaces it, one at a time, with its volume kept
([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)). **Follow a
drain of any other pod with**

```bash
kubectl -n troupe-w-<profile> delete pod troupe-w-<profile>-<ordinal>
```

because nothing else restarts a drained pod that is current. Scale with `max_sessions` and
`warm_workers` on `admin.profile.put`; the plane computes replicas, and drains the pods a
lower count removes before it removes them ([profiles-and-policy.md §3](profiles-and-policy.md#3-upgrades-and-drains)).

## Settings

`admin.settings.list`, `admin.setting.put {key, value}`, `admin.setting.reset {key}`,
visible on the writing replica at once and everywhere within 5 s. Before changing
`platform_admin_group`, `admin.identity.check {group}` with the candidate; the console will
not save it otherwise. What people's own machines start from and may not go past is the
`client_*` settings and `client_enforced`
([configuration.md](configuration.md#defaults-and-limits-for-peoples-machines)). Whether
people may offer their own signed-in tools to a profile's pods is the profile's
`personalTools` (`admin.profile.put`, or the profile editor's switch).

## Client versions

Which versions of troupe, troupe-daemon and the desktop app this plane serves, per
component (`tui`, `daemon`, `desktop`): a **recommended** version, a **minimum** and a
**blocked** list (Decision 868). The **Client versions** panel on the console's Policy page
is `admin.clients.get` and `admin.clients.put {component, policy: {recommended, minimum,
blocked}}`; a platform admin's to change, a team admin's to read, audited as `clients.put`.
Nothing set serves every version.

- **Hold the fleet to a release**: set `minimum`. A client below it is refused when it
  connects (`update_required`) with one sentence that says to run `troupe update`; nothing
  it is running is stopped, and the refusal is at its next connection.
- **Move the fleet**: set `recommended`. `troupe update` on a machine signed in here installs
  that version, rather than the latest, and only if the release key signed it.
- **Retire a bad release**: put its version in `blocked`, and recommend a good one. A client
  on it is refused whatever its number. `troupe update` installs a newer recommended version
  by itself; to go back to an older one it names the `--version` and leaves the choice to
  the person, so a plane cannot walk machines back to an old release. The recommended
  version may not be blocked, and the minimum may not be newer than it.

The desktop app follows the same policy (Decision 874). Signed in here, it calls the
plane's `initialize` as `troupe-gui` with its version when it starts and once a day: on a
blocked version or below `minimum` it says the refusal's sentence, keeps to the sessions
on its own computer, and offers **Update now**; below `recommended` it offers the update
quietly. It updates itself, and the troupe-daemon beside it, to the `desktop` component's
recommended version (the latest release when there is none), never to a blocked one or one
below the minimum, never backwards, and only from a release the release key signed. It
asks the person before it restarts.

Write versions as releases are numbered (`0.13.0-beta`): they are ordered as SemVer orders
them, which puts `0.13.0-beta` before `0.13.0`. A client from before 0.13 does not say its
version and is not held to any of this, and neither is a desktop app from before 0.15;
nor is anything that calls `/rpc` without saying which client it is.

## Locked out of the console

Nobody is a platform admin because `platform_admin_group` or `groups_claim` is wrong:

1. Turn break-glass on if it is not: a Secret with key `token`
   (`openssl rand -base64 48`), `plane.breakglass.secretName` naming it, `helm upgrade`.
2. Open `https://<plane>/admin/breakglass` and enter the token. You are a platform admin
   for the lifetime, marked on every page and in the audit log.
3. Check the right group and save it on the **Policy** page.
4. Sign in normally to confirm; turn break-glass off (`secretName: ""`, upgrade, delete the
   Secret).

## SCIM

On the console's **Identity provider** card, *create a token* (`admin.scim.rotate`): shown
once. Give the provider the token and the base URL `https://<plane>/scim/v2`, keyed on
`externalId` = the subject. `admin.scim.get` shows the last request; `admin.scim.update
{attrs: {teams_from_groups: true}}` makes pushed groups teams; `admin.scim.delete` removes the
token. The deployment's `troupe-plane-scim` Secret (`plane.scim.enabled`) opens the door
too. Authentik, step by step: [authentik.md §4](authentik.md#4-scim-dry-run-first).

`admin.identity.duplicates` lists people held twice. A set `by: "external_id"` is an
adoption the plane refused: a sign-in or a push under a value SCIM gave another row as its
`externalId`, whose email and `userName` both differ from that row's. If they are one
person, make the email or `userName` agree at the provider; if they are two, the
provider's `externalId` mapping gives two people one value, and is what to fix.

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
plane destroys the key first, then every object version goes; the owner is not told; spend
stays in the ledger; the audit row keeps your name. The answer's `state` says whether the
key went: `erased`, or `erasure_pending` when OpenBao refused or could not be reached,
which also shows in the session list. Erase it again to retry; the plane also retries every
five minutes (Decision 811). A team session's objects are deleted by a pod of its profile:
with no healthy pod they wait until one enrols, and so do any the object store would not
delete; the pod's log says how many were left and why (Decision 804).

A team session's key is destroyed by the plane from 0.9.0 on, and keys left by earlier
erasures are destroyed once on upgrade: the first erasure pass after the plane starts
destroys the key of every team session with a tombstone, and its log line says how many it
destroyed and how many it could not, which are tried again every five minutes.

A person's private session has no pod. The plane destroys its key the same way, and the
owner's daemon retries it too the next time it is signed in. Its objects go once the owner's
daemon has connected and dropped its own copy; until then they are unreadable, because the
key is gone (Decision 756). Any the object store refuses to delete are tried again at that
daemon's next connection, and the plane's log says how many were left and why (Decision 804).

## Decommission a profile

1. `admin.team.revoke` it from every team: no new sessions, existing ones read-only.
2. Drain every pod.
3. `admin.profile.delete`: the operator deletes the `troupe-w-<profile>` namespace, volumes
   and Secrets included.
4. Its sessions stay in object storage and the index, read-only; erase any that should go,
   and drop its hosts from `allowedEgress` if nothing else uses them.

## Machines and hosts

`admin.host.register` (the secret is shown once, with the CA the machine pins),
`admin.host.rotate`,
`admin.host.enabled`, `admin.hosts.list`, `admin.provisioners.list`:
[single-machine.md](single-machine.md).
