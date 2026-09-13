# The admin surface — a fourth rendering, and a console that configures things

Built, not planned-then-built: this is the record of what changed and why, in the same
shape as the other plans so it can be read beside them.

Two complaints started it, and they turn out to be the same complaint:

* *"I need an admin MCP."* The person administering a platform of agents increasingly is
  one. Troupe already speaks MCP as a client — a session reaches a team's servers through
  `Troupe.MCP.Client` — and had nothing in the other direction.
* *"The admin panel is half done and I see no real configuration of anything."* Fair. The
  profile editor edited four of a profile's twenty fields; every platform-level setting
  was an environment variable; and there was no page that answered "what is this plane
  configured with".

The same complaint because both are about the *surface*: what the platform can be told to
do, by whom, through what. The context underneath was fine.

---

## What was already in place

`Troupe.Plane.Admin` is one context with thirty-odd functions, and three renderings of it:
the console, `POST /rpc`, and `troupe admin`. `Troupe.Plane.AdminParityTest` enumerates the
context and fails if a function is missing from any of them, and `mix troupe.boundaries`
fails if a LiveView reaches past `Admin` into `Fleet` or `Identity`.

That is a good foundation for adding a fourth surface and it is why this was a week and not
a quarter: nothing here reimplements an action, and nothing here gets a private path.

---

## 1. The admin MCP

### The problem

A model with a token can already call `/rpc`, if somebody writes it a client. What it
cannot do is *discover* the surface: the method table was a name, a function and a list of
argument names, which is everything a dispatcher needs and nothing a caller does.

### Design

**1a. The method table grew prose and types.** Each entry now carries a summary, a typed
argument list with a description per argument, a risk (`:read`, `:write`, `:destructive`)
and, for a destructive one, the name of the argument a caller must echo back. Object
arguments name their properties, because a caller told only "an object" sends `budget` to a
field called `budget_micros` and is told nothing is wrong — because nothing was: the update
changed no fields and said so.

The parity test grew four assertions: every method has a summary that is a sentence, every
argument and every named property has a description, every destructive method names an
argument to confirm and that argument exists, and every method is a tool whose name round
trips back to it.

**1b. `Troupe.Plane.Admin.MCP` projects the table.** `initialize`, `ping`, `tools/list`,
`tools/call`, and empty `resources/list` and `prompts/list` for clients that ask anyway. A
tool's name is its method with dots replaced by underscores, mechanically and reversibly,
so a call in a model's transcript can be found in the audit log where it is written the
other way. The schema sets `additionalProperties: false` on the method's own arguments and
leaves it open inside a spec or a bundle document, which carry more than Troupe names.

`initialize` returns instructions, which is the one place to say the things a model cannot
infer from a tool list: read before you write, a profile write replaces the spec, nobody
can read session content, a destructive tool means it, and a GitOps plane commits rather
than applies.

**1c. Confirmation is the only friction, so it is not optional.** A destructive tool takes
`confirm` and refuses unless it matches the identifier exactly. Checked in the MCP layer
rather than in the context, because the context is also what the console's
already-confirmed dialog calls. The test asserts both halves: that a wrong value is
refused, and that nothing happened when it was.

**1d. The transport is `POST /mcp` beside `/rpc`.** Same bearer token, same actor, same
dispatch. Stateless — no session id — so any replica answers any request. A notification
gets `202` and no body; `GET` and `DELETE` get `405`.

**1e. `troupe mcp` bridges it over stdio.** A plane token lasts fifteen minutes and is
minted from a refresh token the CLI already holds, so wiring a model to a plane without
this means pasting a credential into a configuration file where it is stale by lunchtime
and committed by Friday. The bridge interprets nothing — one JSON-RPC message per line,
posted, answer written back — because a bridge that understood the protocol would be a
second implementation of it. It renews the token at ten minutes rather than per message:
most providers rotate the refresh token on each use, so per-message renewal would also be
a credential file rewritten dozens of times a minute.

Not `troupe admin mcp`, because `admin mcp check` is already an admin method and this is
not a method at all.

### Done

* `POST /mcp` answers `initialize` with the protocol revision and instructions.
* `tools/list` has one tool per admin method, with a schema and annotations.
* A read tool answers as text and as structure, and the two agree once encoded.
* A destructive tool without a matching `confirm` refuses **and does not act**.
* A team admin calling a platform-admin tool gets `isError` naming the role wanted.
* `claude mcp add troupe -- troupe mcp` reaches a plane with no token in a file.

---

## 2. Platform settings

### The problem

`platform_admin_group`, `groups_claim`, `provisioning_mode` and the defaults a new team
gets were environment variables. That is the right home for what a *deployment* decides and
the wrong one for what an *operator* does, and the difference showed up the first time it
mattered: a plane whose admin group named a group nobody was in had no administrator, no
console, and no repair short of a Helm change and a rollout.

### Design

**2a. An override table, never a source.** `platform_settings` is one row per setting
somebody changed. Absent means "whatever this plane was deployed with", and `reset` deletes
the row rather than writing today's default into it — writing it back would freeze this
release's default into the database and make the next deployment's change invisible. The
deployment stays the floor and the worst a bad setting can do is be reset.

**2b. A registry, not a bag.** Each setting declares its type, its panel, a summary, the
*consequence* of changing it, when it takes effect, whether the console may change it at
all, and whether it is a secret. The page is generated from that, so adding a setting is a
change to one list.

**2c. What the console will not change.** The issuer, the client id, the audience and the
base URL are listed with their values and are read-only, for the same reason a lock's
keyhole is not adjustable from inside the house. They are listed rather than omitted
because "where is this plane's configuration" should have one answer, and a missing field
reads as a feature nobody built. Secrets are listed and never shown: what is reported is
whether one is set.

**2d. Verify before save, with a test worth passing.** The design says identity
configuration cannot be saved until a test has passed. The useful test is not "is that a
valid group" but "how many people would administer this platform afterwards, and are you
one of them" — so `admin.identity.check` takes a candidate group and answers against the
value in the field, and the save is disabled until it has. Gated on that one check and not
on all four: a plane whose provider is briefly unreachable should still be able to fix the
group that is locking everybody out.

**2e. Five seconds of cache.** `platform_admin_group` is read on every administrative
request and changes twice a year. The writer clears its own node, so a change is immediate
where it was made and within five seconds everywhere else. Cross-replica invalidation would
be a new distributed concern for a staleness window shorter than the time it takes to
notice.

### Done

* A stored value overrides the deployment; resetting goes back to the deployment's value
  and not to the release's default, proved by changing the deployment and resetting again.
* A value that does not fit its type, a setting nobody declared, and a setting the
  deployment owns are all refused.
* A secret is reported as set and its value is not in the answer or in the page.
* `Provision.mode/0` and `Admin.actor_for/1` read through settings, so changing the
  provisioning mode or the admin group takes effect on the next request.
* A new team starts with the platform's defaults rather than the schema's.
* Every change is in the audit trail with the actor and a diff.

---

## 3. A console that configures things

**3a. The profile editor edits the whole spec.** Scale, model endpoint and credential
reference, egress hosts and git hosts, per-pod disk, requests and limits, MCP servers with
a per-row "can a pod reach it?" check, bundle channel, org mount. Every field carries what
it is for underneath it, in body text, because every one of them names something outside
Troupe.

Three rules make that safe on one page. The form's state is one map and one list, rebuilt
on change and read by apply, so a button that is not a submit does not lose what has been
typed. A blank field is *absent* from the resource rather than empty in it. And nothing is
applied until the diff has been read, computed by the same function that writes the audit
record.

**3b. The diff is keyed by path.** `Audit.diff/2` walks nested maps and reports
`spec.llm.model` rather than `spec`. A top-level diff of a profile reports a model name
change as one twenty-line object becoming another, which is useless both before the apply
and six weeks later in the trail.

**3c. Overview leads with what needs doing.** Four metrics, then everything that is not
healthy, worst first, each with one sentence of what and where and one action. Over budget
is not a thirteenth status — inventing one is what the design forbids — so a team at its
ceiling is reported as what it does: new sessions refused, which is broken from that team's
side, and one approaching it is degraded.

**3d. Teams edits every field a team has**, each with its consequence, and shows spend
against the ceiling as a bar with the figures beside it in text. A bar alone says "quite
full", which is not a number anybody can act on and is nothing at all without colour.

### Done

* A profile round trips through the editor: read, change one field, see the path in the
  diff, apply, and the audit row says the same thing the form did.
* A blank field does not appear in the spec; a false boolean does.
* An MCP row with no URL is a row being typed, not a server.
* Every form has an id, so a reconnect recovers what was in it.
* `console.css` still has no hex codes and every `var()` still resolves.

---

## What is still owed

* **Identity and Integrations as their own screens.** The design draws both. What exists
  today is the identity half of Settings; there is no backend for org-level integrations
  beyond a profile's MCP servers.
* **The erase dialog's full text.** Sessions has a two-step confirmation, not the typed
  identifier and the three second-order consequences the design specifies.
* **Audit's integrity tab.** The change log is there; proving records unaltered by reading
  hashes is not.
* **Bundles as a diff.** Versions are listed and shown; the diff component now exists and
  is not yet used there.
* **A settings surface for the operator's own config.** `workers_domain`, the cert issuer
  and the object store are still deployment-only, correctly, but unlisted.
