# Troupe 1.0, as built

Written in the present tense on purpose. Nothing here is aspiration: every claim maps to a
done item in [`../RELEASE.md`](../RELEASE.md) or
[`control-panel.md`](control-panel.md), and the release gate is a reviewer checking that
mapping by hand.

Read it as the product tour — one organisation, one week, six people who never meet in this
document but share a platform.

---

## What was installed

**IT Minds runs one deployment.** One Helm release on one Kubernetes cluster, one Postgres,
one object store, one OpenBao, one identity provider. Not a tenant of anything; the
organisation owns the keys and the cluster.

```
$ helm install troupe troupe/troupe --version 1.0.0 -f values.yaml
$ kubectl -n troupe-system get pods
NAME                         READY   STATUS
troupe-plane-0               1/1     Running
troupe-plane-1               1/1     Running
troupe-operator-0            1/1     Running
```

The plane comes up with no administrator and says so. The first sign-in with a member of the
group named in `values.yaml` becomes one, and from that point the console configures
everything else — which is the claim the install page makes and the release gate proves by
following it on a cluster nobody prepared.

---

## Monday: an administrator sets the platform up

Sofie signs in at `https://troupe.example.com/admin` and lands on **Overview**, which is
empty and says what is missing rather than showing four zeros.

### Identity

**Identity** is its own screen now. The issuer, client id, audience and base URL are listed
with their values and are not editable — the deployment owns them, and the screen says so
rather than omitting them, because "where is this plane's configuration" should have one
answer.

What she can change is the group that administers. She types a group name and the screen
does not let her save until the check has run. The check is not "is that a valid group":

```
admin.identity.check  group = itm-platform-admins
  → 4 people would administer this platform
  → you are one of them
```

That is the useful question and it is why the save button was disabled. Below it, SCIM
reports its last push nine minutes ago, 61 users and 12 groups, and the `groups` claim is
shown as configured and as observed in her own token — which is how a mismatch is found
before it becomes an evening.

### Policy

**Policy** is the screen that did not exist. Every setting, at every rung, with the value
that won and a chip naming who decided it.

```
Idle timeout                       30 min   [deployment]
  deployment   30 min
  platform     —
  team         —

Default session visibility         private  [deployment]

Personal MCP servers               allowed  [deployment]
  managed_mcp_servers_only  off
```

She narrows two. Retention drops to 6 months at the platform rung, and
`managed_mcp_servers_only` goes on — from now a client cannot register a personal MCP server
and `tools.register` refuses with a sentence a model can relay, rather than a transport
error nobody can act on.

The chips update. A team admin opening the same screen tomorrow will see `[platform]` beside
retention and a floor quoted underneath the field, so when they try to set 12 months the
refusal is not a surprise — it was on screen before they typed.

### A bundle

**Bundles** is an editor. Sofie adds an agent, three skills and two MCP servers as rows in a
form, each field described underneath it because each one names something outside Troupe.
One row has a URL and no name, and it is a row being typed, not a server — so validation
leaves it alone until she is done with it.

She clicks **Validate**. It changes nothing and answers one sentence per problem, against the
document. She fixes one, validates again, and only then does **Publish** become the question.

After publishing, the question stops being "did it publish" and becomes "did it reach the
workers", so adoption polls until every worker on the channel reports the new hash. Two of
three report within four seconds. The third is running a session on the old version, which
the screen says in a sentence, because a stalled number that is correct behaviour needs
explaining exactly once.

### A team, and what it gets

**Teams**. She enables the IdP group `itm-backend` as a team. Membership is read-only and
always will be — it comes from the identity provider.

She grants it the `dev` profile, and then narrows the grant: of the bundle's six skills, this
team gets four. Two rows, `kind: skill`, `mode: deny`. Absence would have meant everything,
which is what every existing grant means, which is why the migration that added this changed
nothing.

### Budgets

**Budgets** shows ceilings at every rung that has one.

```
Platform                  —
Team  itm-backend     500.00 EUR / month     0.00 used
Person                    —                   binding: team
```

She sets a person cap of 40 EUR for everyone in the team. The binding column now says
`person` for anybody who reaches theirs first, and a refusal will name which — because
"budget exhausted" without a scope is a support ticket.

### A provisioner

**Provisioners** lists Kubernetes, enrolled, reconciling. She registers a second: an SSH host
that the platform team already runs as a build box. It enrols with a secret issued on this
screen and shown once.

The row is marked, in text, `unenforced egress`. Beneath it, three lines saying what
Kubernetes was providing and this is not: no admission policy, no NetworkPolicy, no
disruption budget. When she tries to grant `itm-backend` a profile on it, the console refuses
and names the missing guarantee. She sets `allow_unenforced_workers` for that team
deliberately, and the audit row records that she did.

That friction is the design. The SSH provisioner exists so a team with one build box can use
the product, not so the policy can be walked around.

### Everything she did

**Audit** has nine rows. Each one has the diff keyed by the path it changed —
`spec.llm.model`, not `spec` — computed by the same function that rendered the preview she
approved. The thing she approved and the thing in the trail are the same object.

The **integrity** tab walks the record chain and reports it intact. It is the same mechanism
`troupe ctl verify` uses on a session log, pointed at the audit table.

---

## Tuesday: a developer who has never heard of any of this

Ada installs the client and opens it. It is one app.

### Signing in

She signs in once, against the organisation's provider, through the device grant. The refresh
token goes into the OS credential store because the desktop shell provides one. Nothing else
is written to disk — plane tokens and worker tokens are short-lived and live in memory.

### One list

```
Sessions

  ● parser rewrite            team · dev        running      0.42 EUR   2 min ago
  ○ nightly triage            team · dev        needs review 0.08 EUR   6 h ago
  ● troupe-gui                local             running      —          now
  ◐ tax return notes          private · synced  dormant      —          3 d ago
```

Four kinds of thing and one list: her team's sessions on workers, the one running in the
daemon on the machine in front of her, and a private one she started on her old laptop that
followed her here. The merge is client-side; no server merged anything.

She opens **tax return notes**. It renders in full — the chain verified, zero agents
started, no LLM call — because subscribing to a dormant session has never activated one.
**Resume here** restores the workspace tarball under this machine's state directory, appends
`session_resumed` with `moved: true` and the device name, and the next input continues the
conversation. Nothing was merged and nothing needed to be: the plane fenced the epoch, and
her old laptop's copy will go read-only the next time it signs in.

### Working locally

She starts a session in the directory she has open. It runs in the daemon on her machine. It
is not on a worker, has no team, costs nothing against a ceiling, and is hers.

She tries to schedule it and the client says, at the moment she asks:

> Scheduling runs this on a team worker, not on this machine. It will have the worker's
> filesystem and the team's credentials, not your folder. Continue?

That sentence is the whole of landscape item 7 and it exists so that she does not find out
next Tuesday.

### Her editor

Ada uses Zed. She adds Troupe as an external agent, and Zed drives the session over ACP
against the daemon's loopback socket — the same socket the client uses, selected by the
protocol announced at `initialize`. Streaming updates are the session's `detail`
subscription. A permission request is the approval flow, *allow for session* included. File
and terminal access resolves through the mount table.

She kills Zed mid-turn. The turn finishes. The session is not Zed's process and never was,
which is the difference between a harness and a plugin.

---

## Wednesday: two people on one session

Ada's session on `dev` is stuck on something in the payments code. She sends Bo a link.

The link has a grade. She picked **Can watch and prompt**; the other choice was **Can
watch**. The link could not have admitted Bo at all if `itm-backend`'s grant would not — a
share is bounded by the team ACL and is refused at mint, not at use.

Bo opens it. Both see the same transcript in the same order, because every input enters one
mailbox and the log order is the only order. Both see each other: an avatar, who is focused
on which agent, who is typing. That presence has no `seq`, is never persisted, and may be
dropped — and when the network degrades for ninety seconds it *is* dropped, the avatars
vanish, and the transcript stays exact on both screens.

The agent asks for approval. They both answer within a second. First one wins;
`approval_resolved` names who. The second client is told rather than silently ignored.

### A fork

They disagree about the fix. Ada forks the session at seq 4120.

```
session_forked
  parent  sess_8f2a… @ 4120  sha256:9c1e…
  reason  attempt
```

The child renders the parent's history and its own continuation as one transcript. The
parent does not know it was forked and is unchanged. Two attempts run side by side, each a
real session with its own key, its own budget draw and its own retention — and each verifying
independently with `troupe ctl verify`.

The fork inherited the entitlement set recorded in the parent's `session_created`, not the
bundle's current offering. A fork is not a way to get an agent your team was later denied.

Bo's attempt wins. Ada erases hers. The dialog asks her to type the session's identifier and
names three consequences, the third being that erasing a parent leaves children readable —
which here is moot, and which is exactly the case where somebody needs to be told.

---

## Thursday: things nobody started by hand

### A trigger

Sofie's **nightly triage** trigger has a sponsor: her. It has a revision — the content hash
of the trigger document — and its runs name the hash, not the row. She edited the prompt on
Tuesday, and Monday's run still shows what it actually ran.

Its source is `schedule`. Three others exist on this plane:

| trigger | source | fired by |
| --- | --- | --- |
| nightly triage | schedule | the scheduler singleton, on the minute |
| pr-followup | webhook | the CI system, `POST /trigger/…` with its own key |
| incident-summary | integration | an alert route |
| doc-refresh | agent | a session spawning a sibling over MCP |

All four produce the same object. One `sessions.list` filter finds all four. One audit path
covers all four. The custom-integration case — you own the webhook and the filtering, you
call the API — produces a first-class run and not a lesser one, with the same grant, the same
budget and the same retention.

The outbound notification target Sofie configured is absolute, was validated against the
egress allowlist when she saved it, and is validated again at send. Loopback is refused. That
check exists because somebody else shipped an advisory for its absence.

### Review

**Review** groups what ran unattended by what fired it, worst outcome first:
`budget_exhausted` and `llm_error`, then anything waiting on a person, then most recent.

A hundred unattended runs cost one request. The plane's index already carries status, done
reason, cost and how many approvals are open, so nothing replays a log. A session is opened
only when somebody answers an approval, in `read` mode.

One run is stuck on an approval from Tuesday night. Sofie answers it from Review without
opening the session; the turn continues from the resolved call, three simulated days after it
paused, because a pending approval is a durable event and dormancy never blocked it.

### An agent that started work

`doc-refresh` is a session that spawned a sibling. It went through `POST /mcp` — the small
in-system projection, not the administrative one — and its tool list contained nothing
destructive. The sibling's offering is a subset of the parent's, because entitlement
resolution runs at create and does not care who is asking.

An agent that is *not* Troupe's arrives differently: through the A2A facade, with its own
card, and its task becomes a session and its artifacts become published files. That boundary
is where A2A belongs and it has not moved.

---

## Friday: an auditor asks a question

> "In August, which of our people's own credentials were used, by what, and who was
> responsible?"

**Connections** answers the first two.

```
jira   person-mode
  ada@example.com      connected 4 Aug      used in 31 sessions
  bo@example.com       connected 11 Aug     used in 7 sessions
```

Each of those calls is in a session log as a pair, not a single field:

```
"principal": {"subject": "person:ada@example.com",
              "actor":   "principal:nightly-triage"}
```

Subject is whose authority was used; actor is what used it. Where a person acts for
themselves, both are written, so a reader never has to guess whether the field was omitted
because they matched or because nobody wrote it.

The third part of the question — who was responsible — is the sponsor. Every service
principal has one and it is a person in a granted team. A principal whose sponsor leaves is
disabled at the next SCIM push, and the console reports it as *needs a sponsor*, not as
broken, because broken invites a restart and needs a sponsor invites the correct action.

What the auditor cannot have, and is told plainly: **session content**. No admin role grants
it. Sofie cannot read it, cannot break glass into it, and cannot remove Ada's credential from
Jira — she can retire the server from the bundle, and the screen says exactly that where it
lists who has connected.

---

## The things that are true underneath all of it

Six properties that were invariants before this release and are still invariants after it.

**The log is the session.** Every view on every screen in this document is a fold over
durable events. A fork is a second cursor into that fold. A restart is the same fold. An
audit is the same fold. Nothing in 1.0 added a second source of truth, and every table it
added can be rebuilt from something durable — which `mix troupe.index.rebuild` proves against
an empty sessions table.

**The plane is never in the data path.** Sofie's console, Ada's client and Bo's shared link
all talk to workers directly. The plane lists, places, mints and presigns. Stopping it leaves
attached sessions running and sealing; it only stops new ones starting.

**No content crosses the boundaries it must not.** Not the control channel, not the plane
database, not the console, not a backup. A unique marker typed into a session appears in none
of them, which is a test and not a promise.

**Keys are where the plane cannot reach.** Team session keys under `teams/`, private session
keys under `people/` with a policy templated on the subject, and no plane credential that can
read either. The plane can destroy metadata — which is what makes erasure possible without
making reading possible. After an erase, no copy in object storage, Postgres, any volume or
any backup decrypts.

**Absence means everything; deny wins.** One rule, from the entitlement child table up
through the whole policy ladder. A rung with no opinion does not participate. The safe
reading is the one that grants less.

**What the console can do, the API, the CLI and a model can do.** Four renderings of one
context, proven by a parity test — and now a fifth assertion proving the console itself has a
screen for every function, or a written reason why not. That test is what keeps this document
true a year from now.

---

## What 1.0 still is not

Stated here because a tour that only shows the working parts is a brochure.

* **One deployment is one organisation.** No tenancy, no multi-cluster, no autoscaling.
* **No break-glass.** `Breakglass` exists as a module and gives nobody a path to content.
  If that changes it is a spec change, not a feature.
* **No mobile client.** Private sessions follow a person to another device through object
  storage they own, which covers the case a phone-pairing relay would cover, without a
  service in the middle.
* **No merge, ever.** Two devices, two forks, two shares: fencing decides, nothing is
  reconciled, and the loser is named rather than silently overwritten.
* **An SSH worker gives up real guarantees.** Named on screen, gated behind a platform
  setting, and never softened.
* **Sharing a private session means importing it.** It becomes a team session by fork, under
  the team's key. The original stays the person's. There is no third state where a private
  session is partly a team's.
