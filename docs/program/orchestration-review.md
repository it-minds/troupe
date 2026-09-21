# Orchestration review

A review of the architecture against one scenario and one scale, both of which are yours:

> Wake up, open the console, make a **GDPR sensitive employee worker**. Add the MCP
> servers and their connections to the data. Add skills from a catalogue. Add agents.
> Assign the teams and people who may use it. A user signs in, sees it, and starts a
> session on it.
>
> Five to eight of these for the whole organisation. Hundreds of sessions a month. Do not
> make me think about pods.

The architecture serves this well in the places that are hard and badly in the places that
are easy, which is the usual shape of a system built correctly from the bottom.

Nine findings, then what changes, then what does not.

---

## The dream scenario, walked

| step | today |
| --- | --- |
| Create a profile | **Works.** The console's profile editor writes the whole spec with a diff before apply. |
| Add MCP servers | **Partly.** The server and its egress go on the profile; the *tools it offers* go in the bundle. Two objects, two screens, two publishes, and an admin who does one and not the other gets tools whose host is blocked. |
| …with their connections to the data | **Friction.** The console stores a secret *reference* and cannot create the secret. That is the invariant working correctly, and it is still a step in your morning that needs somebody with cluster access. |
| Add skills from a catalogue | **Missing.** There is no catalogue. A skill is a hand-written entry in a bundle document. |
| Add agents | **Partly.** Also the bundle, not the profile. Same seam as MCP servers. |
| Assign teams | **Works.** A grant is team → profile, and `stage-6.md` §2 narrows it below the whole bundle. |
| Assign users | **Not needed, once a team is a Troupe object.** See finding 8: a team stops *being* an identity-provider group and starts *linking* to any number of them. |
| User signs in and sees it | **Works.** `profiles.list` shows what a profile carries — agents, skills, MCP servers, bundle version — before the session exists. |
| Never think about pods | **Fails.** The editor asks for `replicas`, `sessionsPerPod`, CPU and memory requests and limits, and disk size before it asks about anything you wanted to configure. |

The last row is most of this document.

---

## Finding 1 — one thing you mean is three objects the platform has

You said "make a worker profile and put the MCPs, skills, agents and teams in it". The
platform has three objects and you must touch all three:

| object | lives in | carries | changed by |
| --- | --- | --- | --- |
| **WorkerProfile** | Kubernetes | image, replicas, sessions per pod, resources, disk, LLM endpoint and credential, **MCP servers and their secrets**, egress FQDNs and git hosts, bundle channel, org mount | Profiles screen → CR |
| **Config bundle** | the plane, content-addressed | **agent definitions, skills, tool allowlists, MCP server entries** | Bundles screen → publish |
| **Grant** | the plane | which teams get it, and since `stage-6.md` §2, which entries of the bundle they get | Teams screen |

The split is principled and should not be undone. Infrastructure desired state belongs in
Kubernetes; organisational state belongs in the plane; a bundle is content-addressed
because a running session must be able to name the version it started under. Merging them
would break all three arguments.

**But the admin should not pay for it.** MCP servers appearing in two objects is not a
coincidence — the operator needs them for egress policy and secret mounting, the bundle
needs them for the tool list — and the consequence is a bug class: publish the bundle,
forget the profile, and the tools appear in a session and every call fails at the network.

**The fix is composition, not merging.** One console object called what you call it, which
writes to three places under one diff and one audit row. That is finding 1's whole answer
and it is specified below.

---

## Finding 2 — you are asked to solve a capacity problem the plane already has the data for

`Troupe.Plane.Placement` refuses when every worker is full, and its own documentation says
what should happen next:

> `{:error, :at_capacity}` … That is not a failure to retry blindly: **it means the profile
> needs more replicas**, and the caller should say so.
> — `apps/troupe_plane/lib/troupe/plane/placement.ex:35`

The system knows it needs another worker and its answer is to tell a human to go and type a
number. That comment is precisely your complaint, written by the person who built it.

Placement is already a per-profile capacity controller, serialised by `:global`, with counts
backed by Postgres. It has every input an autoscaler would want and more than a
CPU-based one would: it knows sessions, not utilisation. It is a controller that refuses
where it could request.

**And the refusal lands on the wrong person.** A user creating the 33rd session gets a
capacity error for a number their administrator guessed three weeks ago.

---

## Finding 3 — the StatefulSet is right; "pod" as an admin word is not

You suggested ReplicaSets rather than pods. The instinct is right and the mechanism is not,
and the distinction matters enough to be explicit.

**Why it is a StatefulSet.** Three things, and the first is load-bearing:

1. **Stable per-worker addressing.** The operator creates one Service *and one Ingress* per
   pod at `<ordinal>-<profile>.workers.<domain>`. `session.create` returns that endpoint
   and a token whose `aud` is that worker's id. The client connects **straight to the
   worker**; the plane is never in the data path. A ReplicaSet's pods are fungible behind
   one Service and cannot be addressed individually.
2. **A PVC per worker**, via `volumeClaimTemplates`, holding the open segment, active
   workspaces and dormant caches.
3. **Ordered drain**, which scale-down relies on: highest ordinal first, placements stop,
   turns finish, sessions go dormant, pod removed, PVC deletable, nothing stranded.

**What a ReplicaSet would cost.** Fungible pods mean session-to-pod affinity has to live
somewhere, which means a router between client and worker. That is a new component, a new
failure domain, and something in the data path — the exact category of mistake the
"plane is never in the data path" rule exists to prevent. It would buy nothing: you do not
want ReplicaSets, you want to stop being asked a capacity question.

**So the change is to the vocabulary, not the workload.** Kubernetes keeps its ordinals.
The words `pod`, `replica` and `sessions per pod` leave the admin surface entirely, and the
plane writes `spec.replicas` — which it is already permitted to do, since it is already the
only writer of `spec.teams`.

---

## Finding 4 — at eight profiles, scale-to-zero is worth more than scale-up

Your numbers, worked:

```
300 sessions / month ÷ 21 working days        ≈ 14 sessions per day
~45 min active before the idle timeout        ≈ 10.5 session-hours per day
spread over an 8-hour day                     ≈ 1.3 concurrent on average
bursty, so peak                               ≈ 5–6 concurrent
```

Against that, the current minimum to serve anything at all:

```
8 profiles × replicas 1 (the default)          = 8 pods, always running
8 pods × sessionsPerPod 4 (the default)        = capacity 32, for a peak of 6
```

And an administrator who sensibly wants headroom sets `replicas: 2`, which is 16 pods
permanently allocated for a mean load of 1.3 sessions.

**The distribution is worse than the average.** Your GDPR profile might see five sessions a
week. Its pod idles better than 99% of the time and cannot be zero, because a profile with
no worker cannot serve a session.

The conclusion is the opposite of what "autoscaling" usually means here:

> **The expensive mistake at your scale is the minimum, not the maximum.** A profile with
> no active sessions should have no workers.

This is already almost true. Scale-down drains, seals, goes dormant and strands nothing;
dormant sessions live in object storage; activation asks Placement for a worker. What is
missing is that nothing ever scales *to* zero, and nothing scales back *from* it.

**The cold start is affordable and already has a design language.** Scheduling a pod,
binding a PVC and fetching a bundle is roughly 15–45 seconds on a warm node. The client
already says, honestly, for a dormant session: *"Waking the session. This usually takes
twenty seconds."* — indeterminate bar, no fake percentage. A cold profile uses the same
words and the same bar. Somebody about to spend half an hour in a session will wait thirty
seconds; what they will not forgive is a refusal.

---

## Finding 5 — the isolation you want is already built, tested, and not a capacity setting

You want one thing from isolation:

> A session with person A cannot accidentally write to a file another session with person B
> is working on. The security boundary is the team; everybody on it may see the same data.

**That is `session:/`, and it is done.** The mount table is resolved at `session.create`,
recorded as a durable event, and every file tool resolves through it. `shell` runs under
bubblewrap with *only that session's mounts bound at their modes*, a private `/tmp` and
`/proc`, and `--die-with-parent`. A session does not fail to reach another session's
workspace — the workspace is not in its namespace at all.

The proof already exists as stage 2's done item 15:

> With the team volume granted read-only, `write_file` to it is rejected and shell writing
> to it fails with a read-only filesystem error. **Another team's volume and another
> session's workspace do not exist inside the sandbox.**

So two sessions on one pod cannot collide in their own work, and that holds whether they
belong to one person or two.

**The one place they share on purpose is the team volume.** `team:<name>/` is mounted into
both, read-write where the grant says so, and two sessions writing `report.xlsx` will
collide — as two people with the same shared drive would. That is a shared folder behaving
like a shared folder, and the platform already draws the line where it matters: `publish`
and `import` are the only tools that copy between `session:/` and a shared root, they
default to asking, and each copy is a durable event with source path, destination path and
hash.

**Therefore: no isolated size class.** I proposed pod-per-session for the GDPR profile on the
assumption that the boundary was between people. You have said it is between teams, and
teams already have volume-level and key-level separation — a worker's OpenBao role can only
read keys under the paths of its profile's granted teams. Adding a pod per session would buy
kernel separation you do not need, at a cold start per session and a pod count that tracks
concurrency.

`sessionsPerPod: 1` stays in the CR for anyone who ever does need it. It does not appear on
the admin surface.

### What the size class is actually for

One real reason survives, and it is not security: **a demanding session degrades its
neighbours.** A build, a large repository or a long-running tool on a shared pod takes
memory and CPU from the sessions beside it.

So two classes, and the choice is about resources, not safety:

| class | sessions per worker | for |
| --- | --- | --- |
| **Standard** | several | most work |
| **Heavy** | few | large repositories, builds, long or memory-hungry runs |

And the console says what it is for in those words, so nobody reaches for Heavy hoping it
makes their data safer.

### What to call it in the console

The separation you want is real and invisible, which means people will ask for it. It
belongs as one sentence on the profile, stated as fact rather than offered as a setting:

> Every session gets its own workspace. Sessions cannot see each other's files, even on the
> same worker and even for the same person. Files in the team folder are shared, as a shared
> folder is.

---

## Finding 6 — skills have no discovery

There is no catalogue. A skill is an entry somebody types into a bundle document.

The smallest honest version: the plane serves a catalogue assembled from two sources — a git
repository of skills the organisation maintains, refreshed on a schedule, and every skill
already published in any bundle on this plane. **Add from catalogue** writes the entry.

This is the administrator's half of the client's stretch goal S7 (*turn this into a skill*),
and the two meet: a person proposes a skill from a session, it appears as a pending proposal
with its author and origin, and publishing it is the ordinary publish with the ordinary
diff. That loop — one person does it well, the team does it this way — is the mechanism by
which an organisation gets better at this, and today it runs through Slack.

---

## Finding 7 — the console cannot create a secret, and that is correct

The invariant is *no secret values anywhere in the plane*, and it is load-bearing: it is why
compromising the plane gets an attacker requests that still pass policy rather than your
Jira token.

So "add the MCPs with their connections to the data" cannot be one click today, and the
console's job is to make the step short rather than to pretend it is not there: name exactly
what must exist, where, offer the command or the External Secrets path, and let the per-row
reachability check confirm it — which the profile editor already does.

**There is one option worth deciding rather than assuming.** A *write-only* path to OpenBao
would let an administrator paste a token in the console and have it go straight to the vault
— never in the plane's database, never readable back, with the plane's policy permitting
write and destroy but not read. It is the same shape as the existing policy, which already
permits destroying key metadata and forbids reading keys. The cost is that the value passes
through the plane's process memory in transit, which the invariant arguably already
tolerates for exactly nothing else. This materially improves your morning and it is a
security decision, not an ergonomics one. It is in the open questions and should not be
decided by whoever implements it.

---

## Finding 8 — a team should link to identity-provider groups, not be one

Today: *"A team is an IdP group that a platform admin has enabled as a team."* One group,
one team, forever, and the team has no identity of its own.

That is too rigid, and the rigidity is what made "assign users" look necessary. Make the
team a Troupe object that **links** to any number of groups and the problem disappears:

| shape | example |
| --- | --- |
| **1:1** | `itm-backend` → **Backend**. The common case, and what every existing team becomes. |
| **2:1** | `itm-backend` + `itm-platform` → **Engineering**. Small groups in the identity provider, joined into one team in Troupe. |
| **1:2** | `itm-consultants` → **Delivery** and **Timesheets**. One group, two different grants, budgets and retention policies. |

**The invariant is untouched.** "Membership always comes from the IdP and is never edited in
Troupe" said *derived, not typed*. It is still derived — from a union of groups instead of
from one. Nobody adds a person to a team in Troupe; they add a group, and the identity
provider decides who is in it.

And it answers your case exactly as you put it: you can make small groups in the identity
provider and join them into one bigger team in Troupe, which is cheaper than asking IT for a
new group every time a grant needs a different shape.

### The model

```
teams              id, name, display_name, budget, retention, default_visibility, …
team_group_links   team_id, group_id                      unique on the pair
```

* **Membership** is the union over a team's links. A person in two linked groups is in the
  team once.
* **A team with no links has no members**, which is a valid and useful state while you are
  setting one up. The console says "no members yet" rather than treating it as broken.
* **A person in two teams picks a context at session create**, which already exists — the
  spec asks for "the team context, when the user has several".
* **Everything a team owns moves to the team, not the group**: budget, ceiling, retention,
  default visibility, team volume, grants, team administrators. Today several of those are
  effectively pinned to a group by the 1:1 assumption; this is where they belong.
* **SCIM and JIT both feed groups, unchanged.** A push updates group membership;
  team membership recomputes. The JIT path maps `groups` claim entries to whichever teams
  link them.

### Unlinking is a high-consequence action

Removing a link removes access for everybody who was in the team *only* through that group,
and the console must say how many before it happens — with the identifier typed, like every
other irreversible action:

> Unlinking `itm-platform` from **Engineering** removes 14 people. 9 of them are in
> Engineering through another group and keep their access. 5 lose access to 2 profiles and
> 23 sessions they can currently open.

**Sessions do not move.** A session's team is recorded at create and stays. Unlinking
changes who may open it, not what it belongs to — which is the right behaviour and is the
kind of thing people assume the other way round, so the dialog says it.

### What this does not become

Not a second grant hierarchy. `stage-6.md`'s refusal stands: a grant is still team →
profile, entitlements still narrow it below the bundle, and there is still no person → profile
grant. The only change is that a team is now a thing you can shape, rather than a name
borrowed from somewhere else.

The one place the person scope is conceded remains spend, and only spend — `RELEASE.md` W2c.

---

## Finding 9 — there is no "today"

You want, at the end of the day, how many sessions and how much load. What exists:

| source | carries | problem |
| --- | --- | --- |
| usage ledger | one row per LLM call: session, team, owner, model, tokens, cost, gateway request id | no session-level view, no time axis |
| session index | current status, done reason, cost, bytes, last active | current state only |
| heartbeats | capacity, active sessions, disk usage, bundle hash | **not retained** |

Nothing anywhere records how many sessions were running at two o'clock on Tuesday.

`stage-6.md` deliberately deferred a rollup pipeline and that deferral is right at your
scale — 300 sessions a month at perhaps twenty calls each is six thousand ledger rows, which
is nothing. **The gap is not a pipeline. It is one sampled series and two screens.**

* **One series.** Active sessions per profile, sampled every minute, retained ninety days.
  Eight profiles is about a million rows a quarter, which Postgres will not notice. This is
  the only new data in the whole review.
* **Today**, on Overview: sessions started, finished, failed; peak concurrent; spend; the
  slowest cold start; and how many times a ceiling was reached.
* **Per profile, last thirty days**: sessions, median duration, peak concurrent, spend, cold
  starts — which is exactly what decides whether to keep a worker warm, and is what the
  console's recommendation should read from:

  > This profile started 63 sessions last month and was cold for 61 of them. Keeping one
  > worker warm costs about one pod and would have saved roughly thirty seconds each time.

---

## What changes

### The admin now answers two questions about capacity, not seven

Gone from the admin surface: `replicas`, `sessionsPerPod`, `resources.requests.cpu`,
`resources.requests.memory`, `resources.limits.cpu`, `resources.limits.memory`,
`storage.size`. They remain in the CR, written by the plane and the size class.

What is asked instead:

**1. How demanding is a session here?** — Standard or Heavy, a resource question and not a
safety one (finding 5).

**2. How far may this grow?** — a ceiling expressed in *sessions at once*, not workers,
because that is the number an administrator can reason about and the number a refusal can
quote. Default: no ceiling, bounded by the team's money.

**3. Keep one worker warm?** — optional, off by default, with the console's observed-use
recommendation beside it (finding 9).

### The plane scales the profile, and the profile is the only unit

You asked whether scaling can be per profile rather than per session. It can, it already is,
and dropping the isolated class (finding 5) removes the only thing that would have made it
otherwise. That is worth stating plainly because it makes the whole proposal smaller:

> **A pod is never created for a session.** The unit of scale is the profile's pool.
> Sessions are placed into it.

Placement stops refusing and starts requesting. It already serialises capacity per profile
in one `:global` process with Postgres-backed counts; it gains the other half:

* **Up:** once per interval, per profile, compute
  `want = ceil((active + pending) / sessions_per_worker) + warm`, clamp to the ceiling, and
  write `spec.replicas` if it differs. Same writer, same permission, same audit as
  `spec.teams` today.
* **To zero:** a profile with no active sessions and no warm-worker setting goes to zero
  after a grace period. Scale-down already drains, seals and strands nothing.
* **Back from zero:** the first `session.create` on a cold profile scales up and the session
  waits.

At eight profiles and a peak of half a dozen concurrent sessions this loop can run every
fifteen seconds and be arithmetic. There is no HPA, no metrics pipeline, no per-session pod
churn, and nothing that reacts faster than a person would notice. **Scaling stays boring**,
which at this scale is the correct amount of machinery.

### A session waits instead of being refused

`session.create` on a full-but-growing profile returns a session id and no endpoint. The row
is `pending`; the client shows the honest indeterminate bar it already has for waking a
dormant session; the endpoint arrives over the subscription the fleet store already holds.

**Refusal survives only where a human decided it**, and then it names them:

> Design's GDPR worker allows 10 sessions at once and 10 are running.

That is a refusal somebody can act on. `at_capacity, ask your administrator to add replicas`
is not.

### One console object, three writes, one diff

The Profiles screen edits what you mean by a profile: identity and image, the size class and
ceiling, the LLM endpoint, **MCP servers with their tools**, **skills from the catalogue**,
**agents**, egress, and the teams granted — writing the WorkerProfile, publishing the bundle
version and updating grants under one preview and one audit row.

The composed diff is the point. Adding an MCP server shows, in one place, the egress host
that opens, the secret that must exist, the tools that appear, and the teams that get them.
Today that is two screens and a bug when you do one of them.

### Data

The sampled series, the **Today** panel, and per-profile thirty-day figures (finding 9).

---

## What does not change

Nothing in the spec's forbidden list, and the four architectural facts the console is built
to carry:

* **The plane is never in the data path.** Clients still connect straight to a worker at a
  stable address. This is why the StatefulSet stays.
* **The plane still holds no cluster privilege beyond WorkerProfile and TeamVolume.**
  Writing `spec.replicas` is the permission it already has for `spec.teams`.
* **Kubernetes remains the authority on desired infrastructure state**, and the plane remains
  the authority on organisational state. The plane asks for capacity; the operator decides
  what that means and admission still refuses what policy forbids.
* **Size classes are bounded by `TroupePolicy`**, which is cluster-admin-owned and not
  writable by the plane. An organisation that wants a maximum still sets it where maxima
  belong, and the console shows it as the floor under the ceiling field.
* **No session content anywhere it is currently absent.** The sampled series is counts per
  profile — no ids, no owners, no titles.
* **Membership still comes from the identity provider**, and is still never typed in Troupe.
  Finding 8 changes what it is derived *from* — a union of groups instead of one — not that
  it is derived.
* **Session-to-session file separation is unchanged**, because finding 5 found it already
  built: the mount table, the sandbox, and stage 2's done item 15.

---

## What this revises

Two more entries for `RELEASE.md`'s revision list, a fourth and a fifth.

> **`../troupe-remote/spec.md`, out of scope: "autoscaling".**

Revised, narrowly and for a reason the spec could not have had: it was written for a cluster
serving one workload where an administrator sizing a fleet is a normal thing to ask. At
five to eight profiles serving a couple of hundred sessions a month, that same request makes
an administrator guess a number whose consequences they cannot evaluate, and makes a user
pay for the guess with a refusal.

What is added is not a general autoscaler. It is the second half of a controller that
already exists: Placement knows demand, is already serialised per profile, already has
durable counts, and currently responds to knowing it needs another worker by asking a human
to type a number.

**Scale-to-zero is the part that pays**, and it is the part a CPU-based HPA could never do,
because an idle agent session consumes almost nothing and is not idle.

> **`../troupe-remote/spec.md`, identity: "A team is an IdP group that a platform admin has
> enabled as a team."**

Revised by finding 8. A team becomes a Troupe object that links to any number of groups. The
spec's *forbidden* item — team membership edited in Troupe — is untouched and is the one
that was doing the work; the 1:1 sentence was a simplification that has now met an
organisation whose groups do not match its teams, which is every organisation eventually.

Every existing team migrates to a single link with the same name and the same members, so
the change is a no-op on any deployment that does not use it.

---

## Effort and order

Lands as an extension of `RELEASE.md` W4 (the substrate widens) and W6 (the console), and
is best done after W1's cluster suite exists, because every claim here is one only a cluster
can decide.

| | size | why |
| --- | --- | --- |
| Size classes, and the seven fields leaving the admin surface | small | a derivation table and an editor change |
| Placement scales up | medium | one new write and a controller loop in a process that exists |
| Scale to zero, and back | medium | drain exists; the cold path and the grace period do not |
| Pending sessions instead of refusals | medium | touches `session.create`'s contract and the client's start path |
| Teams link to groups, N:M | medium | one table, a resolution change, and a migration that makes every existing team a 1:1 link |
| The composed Profile screen | large | three writes, one diff, and a bundle editor |
| Skill catalogue | medium | a source, a refresh, and a picker |
| Sampled series and the two panels | small | one table and two queries |

If only two land: **size classes** and **scale to zero**. The first deletes the question you
do not want to answer; the second is where the money is at your scale.

---

## Open questions

* **Write-only secrets through the console.** Finding 7. It is the difference between your
  morning being one screen and being one screen plus a ticket, and it is a security
  decision. Somebody should make it deliberately.
* **What does a ceiling mean when it is reached during a burst?** Queue the eleventh session
  until one of ten finishes, or refuse it? Queueing is kinder and can strand somebody
  behind a session that runs for six hours. Probably refuse, and name the ceiling and the
  oldest running session so it can be ended.
* **Does scale-to-zero break the dormant-read path?** Reading a dormant session picks a
  worker of its profile, preferring one with a warm cache, and a profile at zero has none.
  The resolution is a distinction the spec already implies and never states: **activation is
  about the session, not about the pod.** "Subscribing to a dormant session never activates
  it" means no actor tree and no model call — a `Session.Reader` is neither. So a reader may
  start a worker without reserving capacity, and the client uses the honest indeterminate bar
  it already has. Worth writing into `PROTOCOL.md` explicitly, because the looser reading
  would forbid something harmless.
* **How long is the grace period before a profile goes to zero?** Long enough that a person
  closing a session and starting another does not pay a cold start twice; short enough that
  eight profiles are not eight idle pods all evening. Ten minutes is the obvious first guess
  and the observed-use data from finding 9 should replace the guess within a month.
* **Should the size class be per profile or per session?** Per profile is what an
  administrator can govern. Per session is what a user occasionally needs — this one job is a
  huge repository. Per profile, with Heavy as a second profile when it is really needed:
  you want eight of them and a ninth is cheap.
* **Can a team link to a group from a second identity provider?** The model does not forbid
  it and nothing else in the platform expects it. Probably out of scope, but the `group_id`
  should carry its issuer from the start so that deciding later is a migration and not a
  redesign.
* **What happens to a team whose last link is removed?** It keeps its sessions, its budget,
  its retention and its name, and has no members. That is correct for a team being
  reorganised and looks identical to one that was abandoned. The console should distinguish
  them by saying when the last link went, not by inventing a state.
