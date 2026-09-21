# The console — one surface that configures the product

The admin surface was built once already and the record of it is
[`../plans/admin-surface.md`](../plans/admin-surface.md).
That work was right and this is not a rewrite of it: the context underneath, the four
renderings, the parity test, the diff keyed by path, the settings registry and the
`console.css` discipline all stand. What follows is what the console has to become for
[`../RELEASE.md`](RELEASE.md) to be a product rather than a platform.

---

## The complaint, restated precisely

The console configures the *platform*. It does not configure the *product*.

The difference is easiest to see by asking what an administrator cannot do today without
leaving it:

| they want to | today they must |
| --- | --- |
| Change what agents and skills a team gets | paste a JSON bundle document |
| See why a session was refused an agent | read a log |
| Set a spend ceiling for one person | nothing; there is no such thing |
| Know which rung decided a value | read `values.yaml`, then the settings table, then the profile spec |
| Edit a profile from a screen | nothing; `admin.profile.put` is in the client and on no screen |
| Register a worker that is not a pod | nothing; there is no such thing |
| See who has connected a personal credential to which server | nothing; there is no such thing |
| Prove the audit trail has not been altered | nothing; the integrity tab is drawn and not built |

Eight rows, and six of them are objects that [`../RELEASE.md`](RELEASE.md) creates. The
console is not behind because somebody neglected it; it is behind because the product grew
underneath it and the surface is where growth shows.

---

## What is already in place

Worth stating, because it is why this is a workstream and not a second product.

* **`Troupe.Plane.Admin`** is one context with thirty-odd functions and no private paths.
* **Four renderings** of it: the LiveView console, `POST /rpc`, `troupe admin`, and
  `POST /mcp`. `Troupe.Plane.AdminParityTest` enumerates the context and fails if a function
  is missing from any of the last three.
* **`mix troupe.boundaries`** fails if a LiveView reaches past `Admin` into `Fleet` or
  `Identity`. The console has no back door and cannot grow one by accident.
* **`Audit.diff/2`** walks nested maps and reports `spec.llm.model` rather than `spec`, and
  it is the same function that writes the audit record.
* **The settings registry** already declares, per setting, its type, its panel, a summary,
  the *consequence* of changing it, when it takes effect, whether the console may change it,
  and whether it is a secret. The page is generated from that list.
* **`platform_settings` is an override table, never a source.** Absent means "whatever this
  plane was deployed with", and reset deletes the row rather than freezing today's default
  into the database.
* **The design system** is written: a status vocabulary that works without colour, a budget
  shown as a bar with the figures beside it in text, no hex codes in `console.css`, every
  form with a stable id so a reconnect recovers what was typed.

Everything below is built on that and none of it is replaced.

---

## The organising idea: the ladder

One idea carries the whole console, and it is the one thing an administrator asks that no
screen currently answers: **what is the effective value, and who decided it?**

```
deployment    Helm values and environment. The floor. The console lists and never edits.
   ↓
platform      platform_settings. A platform admin. May narrow the deployment, never widen.
   ↓
team          team_settings. A team admin. May narrow the platform, never widen.
   ↓
profile       the WorkerProfile spec. A platform admin. Egress, MCP servers, org mount.
   ↓
session       resolved at create, recorded in session_created. Entitlements, mounts.
```

Two rules, and they are `stage-6.md` §2's rules promoted from one table to the whole ladder:

* **A lower rung may only narrow.** A team cannot raise a ceiling, allow a denied server, or
  lengthen a shortened retention. The resolver enforces it; the console shows the floor
  beside the field so the refusal is never a surprise.
* **Deny wins from any rung**, because the two ways of writing the same intent must not
  disagree and the safe reading is the one that grants less.

**Absence means everything.** A rung with no opinion does not participate. This is what makes
the ladder additive rather than a migration: every existing deployment has opinions at
exactly two rungs today and behaves identically tomorrow.

The console renders this as a **rung chip** — a small, colour-independent marker on every
effective value naming the rung that decided it — and an **effective-configuration view**
that lists, for one setting, the winner and every rung that had an opinion, with the values
they held. That view is the answer to "where is this plane's configuration", which the
settings page started and which only ever answered it for one rung.

---

## Fifteen screens

Grouped by what an administrator is doing, not by which table the data is in. Eleven exist;
four are new; several existing ones change substantially.

### Watch — what is happening

| screen | answers | state |
| --- | --- | --- |
| **Overview** | What needs doing, worst first. Four metrics, then everything unhealthy with one sentence of what and where and one action. | exists; gains provisioner health and unsponsored principals |
| **Sessions** | Every session as metadata only — never content. State, size, cost, pins, lineage, shares. | exists; gains fork lineage, share list, and the full erase dialog |
| **Review** | What ran unattended and needs a person: grouped by what fired it, worst outcome first. | exists in the GUI; moves to parity with the console |
| **Audit** | Who changed what, with the diff keyed by the path it changed — and proof the records are unaltered. | exists; gains the integrity tab |

### Configure — what the product is

| screen | answers | state |
| --- | --- | --- |
| **Policy** | The ladder. Every setting at every rung, the effective value, and who decided it. | **new** |
| **Bundles** | What a profile carries: agents, skills, MCP servers, ACP subagents. Edited, validated, diffed, published, adopted. | exists as publish-JSON; becomes an editor |
| **Profiles** | The whole `WorkerProfile` spec, on a screen, with the diff before apply. | exists in `troupe-remote`'s console; **new to the GUI** |
| **Triggers** | Every way a session starts, as one object with a revision, a sponsor, a source and a run history. | exists for cron; generalises to six sources |
| **Teams** | Grants, entitlements below the grant, ceilings, retention, defaults, administrators. Membership always read-only. | exists; gains entitlements and the ladder chips |
| **Identity** | The provider, the claims, the group that administers, SCIM state, and the check that says how many administrators remain. | half exists inside Settings; **becomes its own screen** |
| **Integrations** | Org-level MCP servers, the egress allowlist as an object, and outbound notification targets. | **new** |

### Operate — what it runs on

| screen | answers | state |
| --- | --- | --- |
| **Fleet** | Profiles, their workers, capacity, conditions, versions, bundle adoption. Drain. | exists; "pods" becomes "workers" |
| **Provisioners** | What can make a worker: Kubernetes, SSH hosts, their enrolment state, and which guarantee each does not give. | **new** |
| **Budgets** | Ceilings at every rung that has one, spend against each, and which ceiling is binding. | inside Teams today; **becomes its own screen** |
| **Connections** | Who has connected a personal credential to which server, in which sessions it was used, and revocation. | **new** |

---

## The four rules

Everything above is arrangement. These four are what make it a console.

### 1. Every effective value names the rung that decided it

Not a tooltip and not a debug view. The rung chip is part of the field, at every rung, on
every screen. An administrator changing a team's idle timeout sees that the platform set a
floor of 10 minutes, that the deployment's value was 30, and that what they type will be
clamped — before they type it.

The chip is text, not colour, for the same reason the status system is: the design doc's
"without colour" section applies to everything the console asserts, and "who decided this"
is an assertion.

### 2. Nothing is applied until its diff has been read

True for a profile today. Becomes true for a bundle, a policy change, a trigger, a
provisioner, a budget and a grant, computed by `Audit.diff/2` — the same function that
writes the audit record.

That identity is the point and is worth restating: **the thing you approved and the thing in
the trail are the same object.** A console that computes a preview one way and an audit
record another way has two descriptions of one change, and the one you read is not the one
that survives.

For a bundle this is the largest single improvement, because a bundle diff is what an
administrator actually wants to know: three skills added, one MCP server's URL changed, one
agent removed — and, crucially, **which teams lose something** because of an entitlement
that no longer resolves.

### 3. Irreversible means typing the thing's own name

Already true, and already the same rule the MCP surface applies to a model: a destructive
tool takes `confirm` and refuses unless it matches exactly. The console's dialogs and the
model's confirmation argument are the same discipline in two renderings, which is how it
should be — and the reason the check lives in the MCP layer rather than in the context is
that the context is also what the console's already-confirmed dialog calls.

What is owed here is one dialog: **erase**. The design specifies the typed identifier and
three second-order consequences and the screen has a two-step confirmation. The three
consequences are real and are what somebody needs:

* the key is destroyed in the KMS, all versions, so no backup of object storage,
  PostgreSQL or any volume can recover the content;
* every object version under the prefix goes, including prior versions in the versioned
  bucket;
* **children survive.** A fork is a separate session with its own key. Erasing a parent
  leaves the child readable, and the dialog names how many there are.

### 4. Coverage is asserted, not assumed

`AdminParityTest` proves the API, the CLI and the MCP tools agree with the context. Nothing
proves the *console* does, which is exactly why `admin.profile.put` is in the TypeScript
client and reachable from no screen.

The new assertion: **every `Plane.Admin` function is reachable from a named console screen,
or is listed as API-only with a reason.** The list is in the source beside the method table,
it is short, and a reason is a sentence — `admin.index.rebuild` is a recovery operation that
runs from a shell during an incident, not a button somebody might find.

That one test is what stops the console drifting behind the API again, which is the failure
this whole document is a response to.

---

## The screens that are new or substantially different

### Policy

One screen, the ladder rendered. Settings grouped by what they govern — identity, retention,
spend, permissions, egress, provisioning — and for each: the effective value, the rung chip,
and an expander listing every rung's opinion.

Two switches get first-class treatment because they are the two administrators ask for, and
both are taken from Claude Code's managed settings:

* **`managed_permission_rules_only`** — a session's own permission rules are ignored; only
  the platform's apply.
* **`managed_mcp_servers_only`** — a client may not register a personal MCP server;
  `tools.register` refuses with a reason the model can relay rather than a transport error.

Each carries its consequence in body text underneath, as every setting already does, because
every one of them names something outside Troupe.

**What Policy refuses to edit** stays listed rather than omitted: the issuer, the client id,
the audience and the base URL, with their values, read-only, for the reason the existing
design already gives — a lock's keyhole is not adjustable from inside the house, and a
missing field reads as a feature nobody built.

### Bundles, as an editor

A bundle stops being a document you paste and becomes a thing you edit, in the shape it
actually has: a list of agents, a list of skills, a list of MCP servers, a list of ACP
subagents. Each row is a form with its fields named and described. Validation is inline and
per-row, because `invalid_params` with one sentence per problem is what the plane already
returns and rendering it against the document is what makes it useful.

Three things stay exactly as they are, because they were right:

* **Validate and publish are two buttons.** Validate asks whether the document is
  publishable and changes nothing. Publish makes it the current version.
* **After a publish the question becomes "did it reach the workers"**, so adoption is polled
  until every worker on the channel reports the new hash.
* **A running session stays on its version.** The screen says so where it shows adoption,
  because the number will not reach 100% while long sessions run and that is correct
  behaviour, not a stall.

New: **the diff between two versions**, and beneath it, **who loses something** — the teams
whose entitlements name an entry this version removes. That is the question a publish
actually raises and nothing currently answers it.

### Triggers, with six sources and a sponsor

A trigger is one object regardless of what fires it:

| field | what |
| --- | --- |
| source | schedule · webhook · integration · CI · API · manual · agent |
| revision | the content hash of this document; runs name it, not the row |
| sponsor | the person answerable. Required. A trigger with no sponsor cannot be enabled. |
| principal | the service principal it runs as |
| target | profile, agent, and the prompt template |
| ingress | for webhook sources: the URL and its key, rotatable, shown once |

The run history shows, per run: what fired it, against which revision, what it cost, how it
ended, and whether anybody has reviewed it. **A run against an edited trigger still shows
the revision it ran**, which is `stage-6.md` §4's whole point and is the thing that is
currently impossible.

A trigger whose sponsor has left the identity provider is reported as needing a sponsor, not
as broken, and stops firing. That distinction matters: broken invites a restart, needs a
sponsor invites the correct action.

### Provisioners

What can make a worker exist.

| column | Kubernetes | SSH |
| --- | --- | --- |
| how a worker appears | the operator reconciles a StatefulSet | a host enrols with a secret issued here |
| enrolment proof | TokenReview on a projected ServiceAccount token, namespace decides the profile | a per-host secret, rotatable, profile-bound |
| egress | NetworkPolicy, and Cilium FQDN rules where available | **unenforced** |
| admission | ValidatingAdmissionPolicy against TroupePolicy | **none** |
| disruption budget | PodDisruptionBudget | **none** |

The right-hand column is the screen's most important content. An SSH worker is outside
Kubernetes and the guarantees Kubernetes was providing are not there — so the profile is
marked `unenforced egress`, and the ladder refuses to place a team on it unless a platform
admin has set `allow_unenforced_workers` for that team.

This is deliberate friction and the console should not soften it. The feature exists so a
developer with one laptop and a team with one build box can use the product; it is not a way
around the policy, and a screen that implied otherwise would be the most dangerous thing in
the console.

### Budgets

Ceilings at every rung that has one, spend against each, and — the useful part — **which
ceiling is binding**.

The existing design's rule about the bar applies and is worth quoting: a bar alone says
"quite full", which is not a number anybody can act on and is nothing at all without colour.
So every ceiling is a bar with the figures beside it in text, and the binding one is marked
in text too.

A refusal names its scope. "Budget exhausted" without a scope is a support ticket; "Ada's
personal cap, 40 of 40 euros this month, inside a team at 180 of 500" is an answer.

### Connections

Who has connected a personal credential to which MCP server.

This is the console half of `stage-6.md` §3 and it exists to make one thing visible that
people otherwise discover: **a session has one identity.** If two people are attached and a
server is person-mode, calls go out as the session's *owner*, fixed at activation. The panel
says so, per session, with the owner named.

It lists the server, who has connected, when, which sessions used it and under whose
authority — the `subject` and `actor` pair from `RELEASE.md` W2b, rendered as two names
rather than one field. An administrator can retire the server from the bundle and **cannot**
read or remove somebody's credential, and the screen says that where it lists who has
connected.

### Identity

The half that lives inside Settings today, as its own screen, plus what the ladder needs.

The existing check is the good idea and stays exactly as it is: the useful test is not "is
that a valid group" but **"how many people would administer this platform afterwards, and
are you one of them"** — so `admin.identity.check` answers against the value in the field,
and save is disabled until it has passed. Gated on that one check and not on all four,
because a plane whose provider is briefly unreachable should still be able to fix the group
that is locking everybody out.

Added: SCIM push state and last push time; the groups claim as configured versus as observed
in the last token; and a list of service principals with their sponsors, because a sponsor
is an identity fact and belongs where identity lives rather than scattered across Triggers.

### Integrations

Org-level things a profile's MCP server list cannot express.

* **MCP servers available to more than one profile**, with the secret reference and the
  reachability check the profile editor already has per row.
* **The egress allowlist as an object**, generated from what each component declares it
  dials, with the component that owns each host — and checked in CI against the chart's
  policy and the `TroupePolicy` defaults. `stage-6.md` §5d asks for exactly this file; this
  is the page that reads it.
* **Outbound notification targets**, absolute-only, validated against the allowlist at save
  and again at send, loopback refused. LangGraph shipped a 2026 advisory for the absence of
  precisely this check and it is cheaper to have than to explain.

---

## The rule the console adds to the product

**Scheduling implies a worker**, and the console and the client both say so at the moment of
scheduling.

A local or private session runs in the daemon on somebody's machine. It cannot be scheduled,
because the machine may be closed. Scheduling it promotes it to a team session on a worker —
a different filesystem, a different credential set, a different budget. Cowork states this
asymmetry plainly at the point of decision, and it is the cheapest thing in the whole
landscape read to copy and the most expensive to leave implicit, because the alternative is
a person discovering next Tuesday that their scheduled task cannot see their folder.

---

## What the console will never do

Unchanged from the spec's forbidden list, restated because a console is where these get
eroded:

* **No session content.** No admin role grants it. Reading content requires being on the
  session's ACL. The Sessions screen shows bytes and never a title that came from content.
* **No secret values.** References only. What is reported is whether a secret is set.
* **No team membership editing.** It comes from the identity provider.
* **No private path.** Every action goes through `Plane.Admin`; `mix troupe.boundaries`
  fails the build if a LiveView reaches past it.
* **No invented status.** A team at its ceiling is reported as what it does — new sessions
  refused — not as a thirteenth status.

---

## Done

1. Every `Plane.Admin` function is reachable from a named console screen, or listed as
   API-only with a one-sentence reason, asserted by a test that fails on a new method.
2. A platform admin configures a complete working deployment from the console alone —
   identity, a team, a policy, a bundle, a profile, a provisioner, a trigger, a budget — with
   no `kubectl`, no environment variable and no database write, and every step is in the
   audit trail with a diff keyed by path.
3. For a setting decided at three rungs, the effective-configuration view names the winner
   and both losers with their values, and a team's attempt to widen it is refused with the
   floor quoted.
4. Publishing a bundle version shows the diff against the current one and names every team
   that loses an entitlement, before the publish.
5. A run against a since-edited trigger shows the revision it ran, not the document as it
   now is.
6. The erase dialog requires the session's own identifier and names the three consequences,
   including how many forks survive.
7. Audit's integrity tab verifies the record chain and names the first bad row when one byte
   is flipped.
8. A profile on an SSH provisioner is marked `unenforced egress`, and granting it to a team
   without `allow_unenforced_workers` is refused with the missing guarantee named.
9. Connections lists a personal credential's owner and the session's owner as two names, and
   an administrator's attempt to read the credential is refused.
10. `console.css` still has no hex codes, every `var()` still resolves, and every form still
    has an id — the three checks that already exist and that every new screen passes.

---

## Open questions

* **Does the GUI's admin section or the LiveView console become the canonical one?** Both
  exist, both are renderings of `Plane.Admin`, and maintaining two is real cost. The LiveView
  console works with no client installed, which matters during an incident; the GUI is where
  a person already is. Probably both, with the coverage test naming which screens each must
  have — but that doubles the assertion and somebody should decide deliberately rather than
  by drift.
* **Should the rung chip appear in the CLI and the MCP tool results?** The ladder is a
  property of the value, not of the console. A model reading `admin.settings.get` and seeing
  only a value will reason about it as if nobody else had an opinion. Probably yes, as a
  sibling field, which costs one key per value.
* **Who may set a person's cap?** A team admin for their own team's members is the obvious
  answer, but a person is in several teams and the caps would compose confusingly. A
  platform-level cap per person is simpler and less useful. Unresolved, and it blocks
  Budgets' final shape.
* **Does Integrations' egress allowlist edit, or only display?** Generated from declarations
  is what makes it trustworthy; editable is what makes it useful when a team adds a vendor.
  Probably display-only with a link to where the declaration lives, because an allowlist
  edited in two places is an allowlist nobody trusts.
