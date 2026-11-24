# Triggers from a repository

In `gitops` mode ([gitops.md](gitops.md)) a repository holds the triggers as well as the
profiles (Decision 737): `Trigger` resources in the plane's namespace, applied by Flux or
anything like it. Every fifteen seconds, after the profiles, the plane lists them and makes
its triggers follow. A new resource becomes a trigger, a change changes it and makes a
revision as an edit does, and a resource that goes takes its trigger with it, runs and key
included. Each is audited as `trigger.put` or `trigger.delete` by `system:gitops`, with the
revision it made.

One resource per trigger, named **`<team>.<trigger>`**: a trigger's name is unique within
its team and a resource's within its namespace, a dot is in neither, and a team said once
has no second field to disagree with. The principal is named by subject.

```yaml
# triggers/platform/nightly-digest.yaml
apiVersion: troupe.dev/v1alpha1
kind: Trigger
metadata:
  name: platform.nightly-digest
  namespace: troupe-system
spec:
  principal: svc:platform/nightly
  profile: standard
  agent: reviewer
  enabled: true
  source:
    kind: schedule
    cron: "0 3 * * 1-5"
    tz: UTC
  promptTemplate: |
    Summarise yesterday's merged pull requests for the platform team.
  terms:
    budgetMicros: 2000000
    maxTurns: 30
    approvals: deny
  visibility: team
  review: required
  notify: [lead@example.com]
  notifyUrl: https://hooks.example.com/troupe
  concurrency: 1
```

| Trigger | Resource |
|---|---|
| `team`, `name` | `metadata.name`, split at its dot |
| `principal` | `spec.principal`: `svc:<team>/<name>`, a service principal of that team |
| `profile`, `agent`, `enabled`, `source`, `visibility`, `review`, `notify`, `concurrency` | the same names, with the defaults in [the table of fields](bundles-and-triggers.md#2-triggers) |
| `prompt_template` | `spec.promptTemplate` |
| `notify_url` | `spec.notifyUrl` |
| `terms` ([terms](bundles-and-triggers.md#3-unattended-session-terms)) | `spec.terms`, spelt `budgetMicros`, `maxTurns`, `wallClockSeconds`, `approvals` |

A field the manifest leaves out is its default, not what the trigger said before.

**What is used.** A resource is used only if `admin.trigger.put` would have saved it (its
name, source and cron, the keys of its terms, its visibility, review, cap and notification
target) and what it names is here: a team the plane has, a service principal of that team,
and a profile the plane has. Profiles are read first in the same pass, so a trigger and its
profile can arrive in one commit. A spec field a `Trigger` has not got is refused too: the
CRD keeps unknown fields so that a misspelt `promptTemplate` reaches the plane rather than
making a trigger that asks for nothing. One that fails is **refused**: a new one gets no
trigger, and a changed one leaves the trigger as the last version that passed, still firing.
The reasons are in the log once, in `admin.triggers.list` (each trigger carries `gitops`:
the resource, the generation it was read at, and a `problem` of `refused` or `missing` with
`reasons`; a refused resource with no trigger is listed by name, to a platform admin with
`team` null where it names no team the plane has), and on the console's Triggers page.

**Locked.** The Triggers page is marked **Held in a repository**, with no form, no switch and
no delete, and `admin.trigger.put` (switching one on or off included) and
`admin.trigger.delete` are refused as `managed_by_gitops` and audited with
`outcome: refused`. Switching a trigger off is a commit that sets `enabled: false`. In a
hurry, suspend the applier and patch the resource, which the plane follows within fifteen
seconds, or disable the trigger's principal, which stays the console's. A trigger the
cluster has no resource for (`missing` after a switch, [gitops.md](gitops.md#switching-a-running-plane)) may still be deleted.

**What stays the plane's.** Running one now (`admin.trigger.run`), its revisions and runs,
and its **key**, which is never in a resource: a key in a manifest would be a credential in
a repository, and a reference to a Kubernetes Secret would give the internet-facing plane a
grant on Secrets its Role deliberately lacks, only to hash a value it can mint itself. A
rotation also answers a leak, which cannot wait for a review and an applier's interval, so
`admin.trigger.key.rotate` works in `gitops` mode as in `direct`. A trigger's row is changed
in place when its resource changes, so its URL (`/trigger/<id>`) and its key survive every
commit; a trigger removed from the repository and added again is a new trigger, with a new
URL and no key.

**Teams, principals and grants** stay in the plane's database, and a trigger names them.
Enable the team and make the principal before the manifest merges, or the resource is
reported until they exist. Disabling a team deletes its triggers; their resources are then
reported as naming a team the plane does not have, until they leave the repository.

**On a direct plane** the same resources are listed and never followed: an administrator
copies one into a row (`admin.trigger.copy`) and copies it again when it changes, and the
console says which rows have drifted ([gitops.md](gitops.md#triggers-from-a-repository-on-a-direct-plane)).

**From a running plane.** `admin.profiles.export` gives every trigger as
`triggers/<team>/<trigger>.yaml`, beside the profiles and the policy, with its document and
nothing the plane keeps; a trigger with a key says so in a note, and the key keeps working
after the switch ([gitops.md](gitops.md#switching-a-running-plane)).

Applied by Flux in a Kustomization of its own, after the profiles':

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: troupe-triggers
  namespace: flux-system
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: fleet
  path: ./triggers
  prune: true
  dependsOn:
    - name: troupe-profiles
```

Of its own because Flux applies a Kustomization as a whole, and a trigger the API server
refuses should not hold back a profile. With `prune: true`, a manifest removed from the
repository deletes its resource and the plane then removes the trigger. A directory per
team is also what a `CODEOWNERS` file can give each team to review.
