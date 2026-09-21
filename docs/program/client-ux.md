# The client — UX

What a person sees. Not what an administrator sees; that is
[`control-panel.md`](control-panel.md), and the two are deliberately different products
wearing the same design system.

This builds on [`../../troupe-gui/docs/design/DESIGN.md`](../../troupe-gui/docs/design/DESIGN.md)
and does not restate it. Three of its rules are load-bearing here and are quoted rather
than re-decided:

* **A status is a glyph, then a word, then a colour.** Colour is never the only signal.
* **Reserved colour means one thing.** Amber in Footlight, magenta in Signal, lime in
  Limelight — in all three it means *stopped, a person must decide*, and is used for
  nothing else.
* **Consequences, not settings.** "Everyone on Sales can open this session and answer its
  approvals", not a padlock icon.

---

## Who this is for

One person, on one machine, who has work to do and did not ask to learn a platform.

They have a team, or several. They have a laptop. They may have a second laptop. They do
not have a cluster, do not know what a WorkerProfile is, and should never need to. The
word "profile" should not appear on any screen they see; "worker", "pod", "bundle",
"grant", "principal" and "channel" likewise.

**They are not an administrator, even when they are.** Sofie from
[`as-built.md`](as-built.md) administers the platform and also writes code. When she opens
the client she is a person with sessions, and the administration she does is somewhere
else — one link, not a menu section. Mixing the two is how a client becomes a console.

---

## The one rule

> **The client is the person's. The console is the platform's.**

Everything in the client answers "what am I working on, and how do I work". Nothing in it
configures the organisation. When the person needs both, they are two places, because the
mental mode is different and merging them makes the common case pay for the rare one.

---

## Home

One list. Every session the person can see, newest use first, nothing else sorted above
it.

```
Sessions                                                 ⌘K  ·  New session

◆  Tax return notes                    Private        sleeping      3 d
▫  troupe-gui                          On this machine   running     now
◇  Parser rewrite                      Design         needs you    2 min   0.42
◈  Invoice import                      Shared by Mette   running     11 min
◇  Nightly triage                      Design         needs review  6 h    0.08
▫  Scratch                             On this machine   sleeping    2 d
```

### Four kinds, and the mark that carries them

The mark encodes two true things and nothing else:

> **Square means this machine. Diamond means the platform.**
> **Filled means only you. Hollow means a team. Split means someone else's, and you are in it.**

| kind | mark | the word in the row | colour token | what it means |
| --- | --- | --- | --- | --- |
| **local** | `▫` | **On this machine** | `kind.local` | Runs in the daemon in front of you. Nobody else can see it. It does not leave. |
| **private** | `◆` | **Private** | `status.private` | Yours alone, but sealed under your own key and listed by the platform, so it follows you. |
| **team** | `◇` | the team's name — **Design** | `kind.team` | Runs on a team worker. Everyone on the team can open it and answer its approvals. |
| **shared** | `◈` | **Shared by Mette** | `kind.shared` | Somebody put you in a session that is not otherwise yours. The row says who. |

Four rules keep this honest:

* **The word is always present.** The mark is a shorthand for people who have learned it,
  never the only carrier — which is the design system's rule and applies to kind exactly
  as it applies to status.
* **Kind and status are different systems and never share a shape.** Kind is the leading
  mark and a 2px left rail on the row. Status is the pill on the right. A session has both
  and they are read in different places.
* **`kind.local`, `kind.team` and `kind.shared` are new tokens** and must clear the same
  contrast floor in all three themes, and must not collide with the reserved colour or
  with `color.person.1…6`.
* **Shared names the person, not the mechanism.** "Shared by Mette", never "ACL grant" and
  never "collaborator role". The role is stated in the session itself, in words, which the
  design system already requires.

### Sorted by latest use, and nothing clever

Newest activity first, across all four kinds, one list, no default grouping. A session that
just moved is at the top whether it is on this machine or on a worker.

Grouping by kind is a *filter*, not a layout. The filter row is four toggles and a text
search, and the default is all four on. A person who wants only their team's work turns
three off and the client remembers it per machine — which is a per-viewer convenience, not
state anybody else sees.

The one exception to pure recency: a session whose status is **needs you** sorts above
everything, because the reserved colour means a person must decide and a decision that is
below the fold is a decision that does not happen. It is one group, labelled, at the top,
and it collapses.

### What is different on another computer

This is the question the client must answer without being asked, because the honest answer
is a feature and the guessed answer is a bug report.

> **Everything except *On this machine* is the same on every computer you sign in on.**
> That is not synchronisation. It is where the sessions live.

Concretely:

| kind | on your second machine |
| --- | --- |
| team | identical — it was never on your machine |
| shared | identical — same reason |
| private | identical history, and **Resume here** brings the workspace with it |
| local | **not there, and not listed anywhere** |

A local session is only on the machine it runs on. It is not hidden on the second machine;
it does not exist there. The client says so, once, where it matters — in the empty state on
a fresh machine, and in the **On this machine** filter's own description:

> Sessions on this machine stay here. They are not listed on your other computers and the
> platform does not know they exist. To take one with you, make it private.

No ghost rows for sessions on other machines. The daemon does not register plain local
sessions with the plane and should not start; a greyed row for something unreachable is
worse than an explanation.

### The promotion path, which is the whole point of two kinds

The difference between **On this machine** and **Private** is exactly one thing: *does it
follow you*. So the control is on every local session, in its header and in its row menu:

> **Make private** — Keeps it yours, and takes it with you. Your work is sealed with a key
> only you can read; the platform stores it and cannot open it. About a minute for a
> session this size.

And afterwards, the reverse is *not* offered, because un-syncing would mean deleting
copies on machines that are not in front of you. What is offered is **Erase**, with the
full dialog.

The one promotion that does not go backwards either: **Move to a team**. A private session
becomes a team session by fork, under the team's key, with the original staying the
person's. The copy says so in a sentence rather than implying a move:

> **Give this to Design** — Design gets a copy from here on. Your private session stays
> yours and is not changed.

### New session

Unchanged from the design system's §6a — owner, tools, output, each phrased as a
consequence — with one addition the four kinds require. The owner list gains **On this
machine** at the top, above **Private — only you**:

```
Where should this run?

  ▫  On this machine          Fast, free, and stays here. Uses your own tools.
  ◆  Private — only you       Follows you to your other computers. Nobody else can open it.
  ◇  Design                   Everyone on Design can open it and answer its approvals.
  ◇  Platform
```

Local is first because it is the cheapest and the one a developer with a directory open
wants. Private is second because it is the safest answer for anything that is not code.

**One consequence must be stated at the moment it becomes true**, and it is the rule the
landscape read insisted on:

> Sessions on this machine cannot be scheduled — this computer may be closed. Scheduling
> moves it to a team worker, with the team's tools and the team's files, not yours.

That sentence appears on the schedule control of a local or private session, not in
documentation, not after the fact.

### Empty and first-run

* **Nothing at all** — one sentence on what a session is, and one action. It does not
  apologise. The design system's rule.
* **Fresh machine, existing account** — the team, shared and private sessions are already
  there, so this is never truly empty. What it shows instead is the note above about local
  sessions, once, dismissible.
* **Signed out** — the sessions on this machine are still listed and still work. The
  daemon does not need the plane. This is worth showing rather than blanking the screen:
  it is the client's strongest promise and the only moment it is visible.

---

## The session

The design system covers the session screen and this changes three things.

**Presence, now that it has a transport.** Up to three avatar rings, then "+n", then a
plain sentence — "Mette, Jonas and you are here" — and your own ring dashed, all as
specified. What is new is that it is live rather than fetched. And when it is dropped under
load, the rings disappear and the sentence goes with them. They do not freeze at a stale
list, because a presence indicator showing somebody who left is worse than none.

**Share, with a grade.** One control, two choices, phrased as consequence:

> **Can watch** — They see everything as it happens. They cannot send anything.
> **Can watch and prompt** — They can also send instructions and answer approvals.

The link expires and says when. It cannot admit somebody the team would not admit, and the
refusal happens when you try to create it, naming the person, not when they try to open it.

**Attempts.** A forked session shows one line at the top of its transcript — "Continued
from Parser rewrite at 14:02" — linking back. The parent shows nothing; it does not know.
Two attempts side by side is a stretch goal below.

---

## Me

Where the admin menu is not. Seven panels, and the word "admin" appears in none of them.

```
Me
  Account          who you are, your teams, the platform you are signed into
  Appearance       theme, density, and which of the three palettes
  My tools         personal MCP servers, for sessions on this machine
  My skills        skills you have installed, and where they came from
  My agents        coding agents installed on this machine
  My spend         what you have used, and against which ceiling
  Connections      credentials of yours that org tools are using
  This machine     the daemon, storage, worktrees, watch mode
```

### Account

Your name and subject, your teams, and the platform. Devices you have signed in on, from
your private sessions' registrations, with the last time each was seen — and a **Sign out
everywhere** that does what it says.

Not: roles, grants, entitlements, or anything an administrator set. Those are the *reason*
things are the way they are, and the place to explain them is where they bite. A tool the
administrator pinned is explained on the tool, at reduced opacity with the reason in place
of the description, which the design system already specifies.

### My tools

Personal MCP servers, offered per session, for sessions on this machine.

Read from the person's own `mcp.json`, listed with what each can reach in plain words, and
registered into a session only after the consent challenge is confirmed. Registering taints
the session and every participant sees it — which is correct and is said here in advance,
not discovered:

> Tools you add are yours and run on this computer. Anyone else in the session will see
> that you added them.

**When the platform has turned this off**, the panel is present and says so, with the
reason where the list would be:

> Your organisation does not allow personal tools in sessions. Tools come from your team's
> setup instead.

Present rather than hidden, because a missing panel reads as a feature nobody built — the
same argument the console makes for listing the fields it will not edit.

### My skills

Skills the person has installed for their own sessions, each with where it came from: a
file they wrote, a folder they pointed at, or the team's bundle. Team skills are listed and
not editable, and say which team.

The action that matters is **Use in this session**, not **Install** — a skill that is
installed and never reached is the most common failure of every product in this space.

### My agents

ACP agents installed on this machine, for local and private sessions. Detected, not
configured: the client finds what is on the PATH and offers it, the way it finds
`mcp.json`. Each row says what it is and where it came from.

A team session's agents come from the team and are listed there, read-only, with the team
named. Two sources, one list, always attributed — never a merged list where you cannot tell
what your organisation chose from what you did.

### My spend

What the person has used this month, and against which ceiling — with the binding one
named.

```
Design                   182.40 of 500.00 EUR
You, this month           38.10 of  40.00 EUR      ← this is the one that will stop you
```

Two bars with the figures beside them in text, because the design system says a bar alone
says "quite full", which is not a number anybody can act on. The binding ceiling is marked
in words.

This is the only money in the client and it is the person's own. Team totals belong to the
team's admin, not to every member.

### Connections

Credentials of the person's that organisation tools are using — the client half of the
person-mode MCP server.

Per server: when they connected, and which of their sessions used it. One fact stated
plainly because people otherwise discover it:

> A session uses its owner's credentials. When you are in someone else's session, their
> Jira account is used, not yours.

**Disconnect** is here and works. Nobody else can do it — an administrator can retire the
server and cannot touch this, which the console says on its side and which is worth saying
on this side too.

### This machine

The daemon, honestly described. Running or not, its port, how long it has been up, and a
restart that explains what restarting does to running sessions (nothing — they restore from
their logs).

Storage used by local sessions, by session, with the largest first and an erase per row.
Worktrees, and removing one, refusing a dirty tree unless forced. Watch mode, which is
exclusive per workspace and says so.

### And administration is a link

If `admin.overview` succeeds for this person, one item appears at the bottom of **Me**:

```
  Administer the platform  ↗
```

One link, opening the console. Not a section, not a nested navigation, not a set of views
that shadow the console's. The probe is the existing pattern and is right: `platform_admin`
is a claim a client can read, `team_admin` is not, so the cheapest administrative read is
what decides — and refusal is an answer, not an error, so the link is simply not offered.

---

## What the client never shows

* **Anybody else's spend**, beyond their own team's ceiling on their own spend panel.
* **Platform vocabulary.** No profile, pod, worker, bundle, grant, principal, channel,
  epoch or head hash on a screen a person sees. They exist and are the console's words.
* **A setting whose consequence it cannot state.** If the sentence underneath cannot be
  written, the control does not ship.
* **A greyed-out thing it could have explained.** Disabled with a reason in place of the
  description, or absent — never disabled and silent.
* **Content from a session the person is not in.** Including in search, including in
  notifications, including in the row title.

---

## Stretch goals

Not supported today. Each says what the person does, where the idea comes from, what it
needs that does not exist, and which repository pays for it.

| | what | needs | lands in |
| --- | --- | --- | --- |
| **S1** | [Publish an artifact to the org or a team](#s1--publish-an-artifact) | an artifact store with scope, and a discovery surface | remote + client |
| **S2** | [My own automations](#s2--my-own-automations) | a personal principal and a trigger scope below a team | remote + client |
| **S3** | [Two attempts, side by side](#s3--two-attempts-side-by-side) | fork (W3a) plus a compare view | client |
| **S4** | [Steer mid-run](#s4--steer-mid-run) | a pause that is not a cancel | remote + client |
| **S5** | [Work that found you](#s5--work-that-found-you) | inbound issue-tracker mapping to a person | remote + client |
| **S6** | [While you were away](#s6--while-you-were-away) | a digest fold over the log | client |
| **S7** | [Turn this into a skill](#s7--turn-this-into-a-skill) | skill authoring from a transcript, and a path to the team | remote + client |
| **S8** | [Hand it over](#s8--hand-it-over) | ownership transfer with context | remote + client |

---

### S1 — Publish an artifact

**What the person does.** A session produced something — a report, a spreadsheet, a
diagram, a document. They publish it, choosing who gets it: the whole organisation, or one
team. Later, somebody else finds it by searching, without knowing which session made it or
who ran it.

**Why it is here.** This is the request. It is also the gap nobody in the landscape fills:
every control surface's answer to "the agent made something" is a pull request, and a pull
request is a terrible answer for a spreadsheet. Augment's shared virtual filesystem is the
closest and is memory for agents, not a library for people.

**What it needs that does not exist.**

* **An artifact is a first-class object**, not a file in a session's workspace. It has an
  id, a content hash, a producing session, a publisher, a scope (`org` | `team:<name>`), a
  title somebody wrote, and a version. Publishing is a durable event
  (`artifact_published`) and unpublishing is another.
* **A store with a different key than the session.** A session's blobs are encrypted with
  the session's key, which exists so that erasing the session destroys them. An artifact
  must outlive its session, so it is re-encrypted under the scope's key on publish — the
  team's, or the org's. That is the real work and it is cryptographic, not cosmetic.
  *Erasing a session must not silently erase what was published from it*, and the erase
  dialog gains a fourth consequence naming how many artifacts survive.
* **Discovery.** A search over titles, scopes and tags — metadata only, never content,
  because the invariant that no admin role reads content applies to an index as much as to
  a screen. A person finds an artifact they may see; opening it is a presigned GET against
  the scope they are in.
* **The A2A facade already has "an artifact is a published file"**, which is the same word
  for a narrower thing. These must be reconciled rather than left as two meanings.

**Where.** `troupe-remote` for the object, the re-encryption and the scope; the client for
publish-from-session and the library.

---

### S2 — My own automations

**What the person does.**

> **Daily, 08:30** — Pull my team's hour registrations and their allocations, compare them,
> and prepare a message I can send in the team chat about anybody who looks like they
> missed one.

They write that sentence, pick which of their tools it may use, and it runs. Every morning
there is a draft waiting. They read it, edit it, send it — or they do not, and nothing
happened.

**Why it is here.** This is the request, and it is the single strongest pattern in the
landscape: Nimbalyst's automations are markdown files with a schedule in the frontmatter;
Warp, Cursor, Superset and Emdash all ship scheduled agent runs; Cowork's scheduled tasks
run in the cloud with your laptop closed. What none of them has is a *personal* automation
that is governed — they are all either fully personal and ungoverned, or fully
administered.

**What it needs that does not exist.**

* **A personal service principal.** Today a principal is created by an administrator and
  sponsored by a person. This needs the inverse: a principal that *is* a person, acting
  with their grants and nothing more, drawing on their own cap. It cannot be a person's
  refresh token — the whole point is that it runs while they are asleep — so it is a
  principal whose sponsor and whose subject are the same person, and whose scopes are a
  subset of theirs, frozen at creation and re-checked at every fire.
* **A trigger scope below a team.** `RELEASE.md` W2's trigger object is a platform object
  an administrator manages. A personal trigger is the same object at a fifth rung, visible
  only to its owner, counted against their cap, and — this is the part administrators will
  ask for — **listable and disable-able by a platform admin**, because a personal
  automation that runs nightly against Jira is an organisation's business even when it is
  one person's idea.
* **A worker, which the person may not have.** Scheduling implies a worker; this is exactly
  the rule from Home. A personal automation runs on a team worker with the team's
  credentials, or it does not run. The client must say which team and which tools *before*
  the person writes the sentence, not after.
* **A place for the result.** The output is a draft for a human, which is the pattern that
  makes this valuable and is not the same as a session that ran. Review exists for
  unattended team runs; this needs the personal version — one inbox, "three drafts waiting
  for you", each openable, editable and dismissible.

**Where.** `troupe-remote` for the personal principal and the fifth trigger rung; the client
for the sentence, the tool picker and the drafts inbox.

**The honest risk**, worth writing down before anybody builds it: a person who can write a
nightly instruction against their own credentials has just been handed an unattended agent
with their access. The compensating controls are the cap, the platform admin's visibility,
and the fact that the output is a draft rather than a send. Any design that lets a personal
automation send a message without a person reading it first should be refused.

---

### S3 — Two attempts, side by side

**What the person does.** Forks a stuck session twice, gives each a different instruction,
and watches both. When one wins, they keep it and erase the other, or keep both.

**Why it is here.** Orca forks sessions; Zed runs parallel threads; Conductor, Superset and
Emdash all give an attempt its own worktree. Every one of them then leaves the comparison to
the person's eyes across two windows. Troupe can do better because both attempts are folds
over a shared prefix, so the client knows exactly where they diverged.

**What it needs.** Fork is `RELEASE.md` W3a and is planned. The stretch is client-only: a
two-pane view anchored at the fork point, with the shared history collapsed to one line and
only the divergence shown — plus a file-level diff between the two attempts' workspaces,
which `fs.list` and `fs.read` already support.

**Where.** Client.

---

### S4 — Steer mid-run

**What the person does.** The agent is going the wrong way. They stop it *without losing
the turn*, add a sentence, and let it continue from where it was.

**Why it is here.** GitHub's mission control ships pause, refine and restart mid-run and it
is the single most-praised thing about it. Troupe has cancel, which throws the turn away,
and queued input, which waits politely until the wrong answer has finished being computed.

**What it needs that does not exist.** A pause that is not a cancel: the turn stops at the
next tool boundary, its state stays in the actor tree, an input is accepted and appended,
and the turn resumes with it in context. Durably: `turn_paused`, `input_accepted`,
`turn_resumed`. The hard part is not the protocol; it is that a paused turn holds a slot,
a budget reservation and possibly an open tool call, and a pause that is never resumed must
time out into a cancel with the same guarantees a cancel has today.

**Where.** `troupe-remote` mostly; the client is one button and one composer state.

---

### S5 — Work that found you

**What the person does.** Opens the client and finds, beside their sessions, the things
assigned to them elsewhere — a Jira ticket, a GitHub issue, a pull request wanting review —
each with **Start a session on this**, which opens with the item's full context already
read.

**Why it is here.** Emdash ingests issues from eight trackers; Cursor's Slack integration
reads the entire thread before starting so the agent has the conversation and not just the
mention. The combination — a personal inbox plus context-on-start — is the shape, and
nobody has it as a first-class surface.

**What it needs that does not exist.** An inbound integration that maps an external item to
a *person* rather than to a team or a trigger, using that person's own connected credential
— which means S2's personal principal, or at least its credential half. Plus the
context-read: the prompt that starts the session includes the thread, the description and
the comments, fetched at start rather than left for the agent to go and find.

**Where.** `troupe-remote` for the integration and the mapping; client for the inbox.

---

### S6 — While you were away

**What the person does.** Comes back after a night or a week and reads one screen: what
finished, what is stuck, what it cost, what changed in the sessions they follow.

**Why it is here.** Nobody in the landscape does this and every one of them needs it. The
closest is Conductor's follower list, which tells you *that* something moved, not what. For
Troupe it is unusually cheap: the summary projection already folds a session into per-agent
state, current todo, active tool, tokens, cost, pending approvals and last error, and the
plane's index already carries status, done reason, cost and open approvals without
replaying anything.

**What it needs.** A fold over "everything since the cursor I last read", which is a client
concern given the data it already receives — plus one thing the server does not have: a
**follow** list distinct from ownership, so "sessions I care about" is not the same as
"sessions I started". Conductor's followers, taken as a data model rather than as avatars.

**Where.** Client, plus a small follow table on the plane.

---

### S7 — Turn this into a skill

**What the person does.** A session did something well and they want it again. They press
one thing, review a draft skill the client wrote from the transcript, edit it, and keep it
in **My skills**. If it is good, they offer it to a team, where an administrator publishes
it into the bundle or does not.

**Why it is here.** Nimbalyst's automations are markdown with frontmatter — a file a person
can read and edit — and Cowork's skills are the same idea at organisation scale. The
missing rung everywhere is the path from *one person did a thing well* to *the team does it
this way*, which is the actual mechanism by which an organisation gets better at this and
which currently runs through Slack.

**What it needs that does not exist.** Drafting a skill from a transcript, which is a model
task and should be honest about being one — the draft is a proposal a person edits, never
something installed silently. Then a **propose to team** path: a skill a person submits
appears in the console's Bundles screen as a pending proposal with its author and the
session it came from, and publishing it is the administrator's ordinary publish with its
ordinary diff.

**Where.** Client for the draft and **My skills**; `troupe-remote` for proposals and the
console row.

---

### S8 — Hand it over

**What the person does.** Gives a session to a colleague — not a share, a handover. The
colleague becomes the owner. The person who handed it over drops to watching, or leaves.

**Why it is here.** Every product's answer to "I am going on holiday and this is
half-finished" is a pull request and a Slack message. Troupe already has most of it —
several harnesses on one session, ACLs as durable events, roles mapping to scopes — and is
missing only the transfer.

**What it needs that does not exist.** Ownership is currently fixed at activation and is
what a person-mode credential authenticates as, so a handover changes which credential
outbound calls use — mid-session, which is exactly the kind of quiet change the platform
exists to make loud. So: a durable `owner_transferred` event, the new owner's explicit
acceptance before it takes effect, a visible marker in the transcript at the point it
happened, and the old owner's credentials stopping at that line. The GUI spec's note that
"the fleet store must not assume a session has one owner forever" was written for exactly
this and is already honoured.

**Where.** `troupe-remote` for the transfer and the credential switch; client for the ask
and the accept.

---

## Done, for the part that is supported

1. Home lists all four kinds in one list, newest use first, each with its mark, its word
   and its colour, and the list is readable with colour removed.
2. **Needs you** sorts above everything, is labelled, and collapses.
3. Signing in on a second machine shows identical team, shared and private rows, no local
   rows, and the explanation once.
4. A local session's **Make private** produces a session that opens on the second machine
   with its chain verified and zero agents started.
5. The schedule control on a local or private session states the worker consequence before
   it is used, not after.
6. **Me** has no administrative view; `admin.*` is called exactly once, as the probe, and a
   person who administers nothing sees no link.
7. With `managed_mcp_servers_only` on, **My tools** is present, empty, and says why.
8. **My spend** names the binding ceiling in words, and a refusal elsewhere in the client
   names the same one.
9. Presence appears within 500 ms and disappears entirely under load rather than going
   stale.
10. No screen a person sees contains the words profile, pod, worker, bundle, grant,
    principal, channel, epoch or head hash — asserted by a test over the rendered strings.

---

## Open questions

* **Is "shared" a kind or a badge on a team session?** A session shared by link from a team
  the person is *also* in is both. Probably: kind is what explains why you can see it, so
  team wins when both are true and the badge says a link exists. Undecided, and it changes
  the filter row.
* **Does the local filter survive a reinstall?** It is a per-viewer convenience and belongs
  in browser storage, which can come back empty. Fine. But a person who filters to one team
  and forgets will think sessions vanished — so probably the filter row is always visible
  when not at its default, with a one-click reset.
* **Where does a draft from a personal automation live before it is sent?** A session, which
  makes it a session in the list that is not really work. Or an inbox, which is a second
  place things live. Leaning inbox, with the session behind it one click away — but this is
  the decision that shapes S2's whole surface.
* **Should the client show a person their own audit trail?** Everything they did is in it,
  and it is theirs. It is also the first step toward the client growing a console, which is
  the thing this document exists to prevent.
