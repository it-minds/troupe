# Brief — troupe-gui

This extends `spec.md` and assumes stages 1, 2 and 4 are built and deployed. Same rules
apply: work autonomously, do not ask questions the documents answer, record every judgment
call in `DECISIONS.md`, and prove every done item with command output in `REPORT.md`.

Read [`../HANDOFF.md`](../HANDOFF.md) first. The binding document for everything below is
[`client-ux.md`](client-ux.md); `docs/design/DESIGN.md` remains the authority on how it
looks.

Six packages. **G0, G1 and G2 depend on no server change and start immediately.**

| | package | size | depends on |
| --- | --- | --- | --- |
| **G0** | [Three debts](#g0--three-debts) | medium | — |
| **G1** | [Home: four kinds, one list](#g1--home) | medium | — |
| **G2** | [Me, which is not an admin menu](#g2--me) | large | R2 for spend and connections |
| **G3** | [Private sessions](#g3--private-sessions) | medium | remote R1 |
| **G4** | [Sharing, presence, forks](#g4--sharing-presence-forks) | medium | remote R5 |
| **G5** | [Waiting is not failing](#g5--waiting-is-not-failing) | small | remote R3 |
| **G6** | [Stretch goals](#g6--stretch-goals) | — | each names its own |

---

## The one rule

> **The client is the person's. The console is the platform's.**

Everything here answers "what am I working on, and how do I work". Nothing configures the
organisation. When a package starts to grow a screen that belongs to an administrator, it has
gone wrong — see G2.

And the vocabulary rule, which is testable and should be tested: **no screen a person sees
contains the words profile, pod, worker, bundle, grant, principal, channel, epoch or head
hash.** Those exist and they are the console's words.

---

## G0 — Three debts

Named in `REPORT.md`'s own known-limitations sections. Pay them before building on top.

1. **A fake plane, and tests for the admin views.** Stage 4 shipped six admin panels with no
   tests and no call ever made against a running plane, because nobody had completed a
   sign-in on the live deployment. `REPORT.md` estimates a fake plane worth having at a day's
   work. It is the prerequisite for G2, because G2 moves and reshapes that surface.
2. **Client-hosted MCP servers** — stage 2's done item 5, not built.
   `Troupe.Session.ClientTools` is implemented server-side and offered by no client. This is
   **My tools** in G2 and it is the oldest debt here.
3. **Profiles are read-only.** `admin.profile.put` and `admin.profile.delete` are in
   `@troupe/client` and reachable from no screen. Do **not** fix this by adding a profile
   editor to the GUI — decide first, with the customer, whether the LiveView console or the
   GUI's admin section is canonical (`control-panel.md`, open questions). Until then, list it
   as API-only with a reason, which is what the console's coverage test will demand anyway.

---

## G1 — Home

One list. Every session the person can see, newest use first.

### The four kinds, and the mark

The design system's rule is binding: **a status is a glyph, then a word, then a colour**, and
colour is never the only signal. Kind gets all three.

> **Square means this machine. Diamond means the platform.**
> **Filled means only you. Hollow means a team. Split means someone else's, and you are in
> it.**

| kind | mark | word in the row | token |
| --- | --- | --- | --- |
| local | `▫` | **On this machine** | `kind.local` *(new)* |
| private | `◆` | **Private** | `status.private` *(exists)* |
| team | `◇` | the team's name | `kind.team` *(new)* |
| shared | `◈` | **Shared by Mette** | `kind.shared` *(new)* |

Three new tokens, each clearing the contrast floor in all three themes — Signal, Footlight and
Limelight — and colliding with neither the reserved colour nor `color.person.1…6`. Add them
to `themes/THEMES.md`'s audit table.

**Kind and status never share a shape.** Kind is the leading mark plus a 2px left rail;
status stays the pill on the right. A session has both and they are read in different places.

### Sorting

Newest activity first across all four kinds. Grouping by kind is a *filter*, not a layout:
four toggles plus search, all on by default, remembered per machine. The filter row stays
visible whenever it is not at its default, with a one-click reset — a person who filters to
one team and forgets will otherwise think sessions vanished.

One exception to pure recency: **needs you** sorts above everything as one labelled,
collapsible group, because the reserved colour means a person must decide and a decision
below the fold does not happen.

### What is different on another computer

The client answers this without being asked, because the honest answer is a feature and the
guessed answer is a bug report.

> Everything except **On this machine** is the same on every computer you sign in on. That is
> not synchronisation. It is where the sessions live.

**No ghost rows for sessions on other machines.** The daemon does not register plain local
sessions with the plane and must not start. A greyed row for something unreachable is worse
than an explanation. The explanation lives in the **On this machine** filter's own
description and in the first-run note on a fresh machine.

### The promotion path

The difference between the two personal kinds is exactly *does it follow you*, so **Make
private** is on every local session, in its header and its row menu, phrased as consequence.
The reverse is not offered — un-syncing would mean deleting copies on machines that are not
in front of you. What is offered is **Erase**.

**Give this to Design** forks a private session into a team; the copy says the original stays
the person's and is not changed.

### New session

Unchanged from `DESIGN.md` §6a — owner, tools, output, each as a consequence — with **On this
machine** added at the top of the owner list, above **Private — only you**.

And one sentence that must appear on the schedule control of a local or private session, at
the moment it is used:

> Sessions on this machine cannot be scheduled — this computer may be closed. Scheduling
> moves it to a team worker, with the team's tools and the team's files, not yours.

### Signed out

The sessions on this machine are still listed and still work; the daemon does not need the
plane. Show them rather than blanking the screen. It is the client's strongest promise and
the only moment it is visible.

### Done

1. All four kinds in one list, newest first, each with mark, word and colour — and the list
   is readable with colour removed.
2. **Needs you** sorts above everything, labelled and collapsible.
3. Signing in on a second machine shows identical team, shared and private rows, no local
   rows, and the explanation once.
4. **Make private** produces a session that opens on the second machine with its chain
   verified and zero agents started.
5. The schedule consequence appears before the action, not after.
6. Signed out, local sessions list and run.

---

## G2 — Me

Where the admin menu is not. Eight panels, and the word *admin* appears in none of them.

```
Account       who you are, your teams, your devices, sign out everywhere
Appearance    theme, density, which of the three palettes          (exists)
My tools      personal MCP servers, for sessions on this machine   (debt G0.2)
My skills     skills you have installed, and where they came from
My agents     coding agents installed on this machine
My spend      what you have used, against which ceiling            (needs R2)
Connections   credentials of yours that org tools are using        (needs R2)
This machine  the daemon, storage, worktrees, watch mode
```

Details in [`client-ux.md`](client-ux.md). Four rules that are easy to lose:

* **A panel the platform has switched off is present and says why**, not hidden. With
  `managed_mcp_servers_only`, **My tools** shows the reason where the list would be. A
  missing panel reads as a feature nobody built.
* **My spend is the person's own**, with the binding ceiling named in words and the figures
  beside the bar in text. Team totals belong to the team's administrator.
* **Connections states one fact people otherwise discover**: a session uses its *owner's*
  credentials, so in someone else's session their Jira account is used, not yours.
  **Disconnect** works here and no administrator can do it.
* **Administration is one link at the bottom**, gated on the existing `admin.overview` probe.
  Not a section, not nested navigation, not views that shadow the console's. Refusal is an
  answer, so the link is simply not offered.

### Done

1. **Me** contains no administrative view; `admin.*` is called exactly once, as the probe.
2. A person who administers nothing sees no link; a team admin and a platform admin both see
   the same single link.
3. With `managed_mcp_servers_only`, **My tools** is present, empty, and says why.
4. A personal MCP server is registered only after the consent challenge is confirmed, served
   through `tool.invoke`, and shows as `session_tainted` to a second client.
5. **My spend** names the binding ceiling, and a refusal elsewhere in the client names the
   same one.
6. A test over rendered strings finds none of the nine forbidden platform words.

---

## G3 — Private sessions

Stage 3, unblocked by remote R1. The client side is mostly built already: `FleetRow` carries
`kind: "private"` and a `sync` state, the store merges the plane row with the daemon's copy
(daemon wins), the list renders **Synced**, **Syncing**, **Here only** and **Conflict** with
the conflict naming the device that holds the copy that counts, and the create dialog's
control sits behind its capability gate.

**Keep the gate exactly as it is.** The control appears when the daemon's `initialize`
reports `private_sessions` and not because the build has the code. That pattern is the one
every later capability in this brief uses.

Remaining work is the other-device flow: open from the plane rows, download manifest and live
segments through presigned GETs, verify the chain, serve history with no agent started,
**Resume here**, **Bind to a directory**, and the conflict state.

### Done

`spec.md` stage 3's seven done items, unchanged.

---

## G4 — Sharing, presence, forks

Unblocked by remote R5.

**Share, with a grade.** One control, two choices, phrased as consequence:

> **Can watch** — They see everything as it happens. They cannot send anything.
> **Can watch and prompt** — They can also send instructions and answer approvals.

The link expires and says when. A link for somebody the team would not admit is refused
**at creation, naming the person**, not when they try to open it.

**Presence, now live rather than fetched.** `DESIGN.md` §7 already specifies the rendering —
up to three rings, then "+n", a plain sentence, your own ring dashed. What is new: when it is
dropped under load the rings and the sentence **disappear**. They do not freeze at a stale
list. A presence indicator showing somebody who left is worse than none.

**Forks.** A forked session shows one line at the top of its transcript — "Continued from
Parser rewrite at 14:02" — linking back. The parent shows nothing; it does not know.

### Done

1. A watch link cannot send input; a prompt link can; both appear in the session's log.
2. A refused link names the person at creation.
3. Two clients see each other's presence within 500 ms; with the outbound queue saturated,
   presence disappears and the event order is still identical on both.
4. A forked session renders parent history and child continuation as one transcript.

---

## G5 — Waiting is not failing

Unblocked by remote R3, and small.

A session created on a cold or full-but-growing profile comes back with an id and no
endpoint. The client must treat that as *starting*, not as *failed*.

Reuse what exists. `DESIGN.md` §8 already has the honest pattern for waking a dormant
session: an indeterminate bar, no fake percentage, and a sentence — *"Waking the session.
This usually takes twenty seconds."* A cold profile gets the same bar and its own sentence.

A refusal is different and only happens where a human set a ceiling, so it quotes them:

> Design's GDPR worker allows 10 sessions at once and 10 are running.

That is actionable. `at_capacity` is not, and must never reach a person.

### Done

1. Creating on a cold profile shows the starting state, then streams, with no error anywhere
   in the path.
2. A ceiling refusal names the ceiling and who set it.
3. Reading a dormant session on a cold profile renders full history with zero agents started.

---

## G6 — Stretch goals

Eight, specified in [`client-ux.md`](client-ux.md). **None is client-only except S3 and S6**,
so none starts before its server half is agreed.

| | what | needs |
| --- | --- | --- |
| S1 | Publish an artifact to the org or a team | an artifact object, re-encryption under the scope's key, discovery — remote |
| S2 | My own automations | a personal principal and a fifth trigger rung — remote |
| S3 | Two attempts side by side | fork (R5), then **client only** |
| S4 | Steer mid-run | a pause that is not a cancel — remote |
| S5 | Work that found you | inbound tracker mapping to a person — remote |
| S6 | While you were away | a follow list on the plane, then **client only** |
| S7 | Turn this into a skill | drafting, and a proposal path to a bundle — both |
| S8 | Hand it over | ownership transfer and the credential switch — remote |

**S3 and S6 are the two to build first** when there is room: both are folds over data the
client already receives, and S6 in particular is nearly free because the summary projection
and the plane's index already carry everything it needs.

**Two warnings that are not negotiable.**

* **S1**: a session's blobs are encrypted with the session key *so that erasing the session
  destroys them*. An artifact outlives its session, so publishing means re-encrypting under
  the scope's key — and the erase dialog gains a fourth consequence naming how many artifacts
  survive. Do not ship a publish that leaves an artifact decryptable only by a key that is
  about to be destroyed, and do not ship one that quietly keeps a session's content alive
  after an erase.
* **S2**: a person writing a nightly instruction against their own credentials has been handed
  an unattended agent with their access. The controls are the personal cap, platform-admin
  visibility of personal triggers, and **the output being a draft a person reads before it
  goes anywhere**. Any design that lets a personal automation send a message without a human
  reading it first should be refused.
