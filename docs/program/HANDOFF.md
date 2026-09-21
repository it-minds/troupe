# Handoff

What was decided, what to read, and how the two repositories work while this lands.

Two briefs come out of this document and are what the teams actually work from:

* **[`docs/brief-remote.md`](brief-remote.md)** — nine work packages for `troupe-remote`.
* **[`docs/brief-gui.md`](brief-gui.md)** — six for `troupe-gui`.

Read this page once. Then read your brief, then the documents it names, then start.

---

## What happened

A September 2026 read of seventeen competing platforms, a collected release plan across both
repositories, a UX specification for the client, a specification for the console, and an
architecture review against one administrator's morning and one organisation's real scale
(five to eight profiles, a few hundred sessions a month).

The outcome is not a redesign. The harness and the platform are correct and proven; the
release work is almost entirely in the surfaces — what an administrator configures, what a
person sees, and what happens when demand exceeds a number somebody guessed.

---

## The documents, and which is authoritative

| document | authority over |
| --- | --- |
| `../../spec.md`, `../../clients/gui/spec.md` | **Invariants.** Nothing below weakens one. Where something is revised, it is named and argued. |
| `../../PROTOCOL.md` | The wire. Changes land here first, in `troupe-remote`, before any client implements them. |
| `../../ARCHITECTURE.md` | What is built and how. Updated per stage, before the stage. |
| [`RELEASE.md`](RELEASE.md) | What is left to 1.0, in seven workstreams, and in what order. |
| [`docs/orchestration-review.md`](orchestration-review.md) | Capacity, scaling, teams-to-groups, and the admin's morning. Supersedes `RELEASE.md` W4 where they differ. |
| [`docs/control-panel.md`](control-panel.md) | The console. |
| [`docs/client-ux.md`](client-ux.md) | The client. |
| [`docs/as-built.md`](as-built.md) | The target. Every claim in it must end up proven somewhere. |
| [`docs/landscape.md`](landscape.md) | Why. Read once; do not re-derive. |

Both repositories keep their own `DECISIONS.md` and `REPORT.md`. Nothing about that changes.

---

## Five revisions to the specs

Each was argued where it was made. Do not re-open them; do not quietly widen them either.

| # | revised | to | where argued |
| --- | --- | --- | --- |
| 1 | "No push channel to harness clients" | **presence only**, ephemeral, on the existing subscription, droppable without loss | `RELEASE.md` W3c |
| 2 | "Entitlements on a person — deferred" | answered **for spend only**; entitlements stay a team's | `RELEASE.md` W2c |
| 3 | The unargued assumption that **a worker is a pod** | a provisioner behind an interface; the missing guarantees named on screen and gated | `RELEASE.md` W4a |
| 4 | "Autoscaling — out of scope" | the plane sets `spec.replicas` and scales to zero; **not** a general autoscaler | `orchestration-review.md` |
| 5 | "A team **is** an IdP group enabled as a team" | a team **links to** any number of groups, N:M | `orchestration-review.md` finding 8 |

Revision 5's forbidden item is untouched: membership is still derived from the identity
provider and still never typed in Troupe.

---

## The working contract between the repositories

Unchanged from `../../clients/gui/spec.md` and restated because it governs every package here:

1. **Protocol first.** A new method or field lands in `../../PROTOCOL.md`, then in
   `troupe-remote` with its own tests, then the GUI implements it. Never the other way.
2. **Capability-gated clients.** The GUI offers a control when the server it is talking to
   announced the thing at `initialize` — never because the build was compiled with it. This
   is already how **Keep it private** works and it is the pattern for everything new.
3. **One version.** The chart's `appVersion` and the GUI's package version are the same
   string at a release tag.
4. **Additive only within a major.** `mix troupe.schema.diff` enforces it.

### What unblocks what

```
REMOTE                                   GUI
R1  floor: stage 6, sealer, e2e   ─────► G3  private sessions
R2  trigger + principal           ─────► G2  Me: spend, connections
R3  capacity: size classes, scale ─────► G5  pending / cold start
R4  teams link to groups          ─────► (console only)
R5  fork, shares, presence topic  ─────► G4  sharing, presence, fork
R7  ACP on the daemon socket      ─────► (no GUI work; editors are the client)
R8  console                              G1, G2 proceed in parallel throughout
```

G1 (**Home**) and G2 (**Me**) depend on nothing new and should start immediately. They are
the two the product is judged on and they are currently the furthest from the specification.

---

## Rules that apply to both teams

These are the repositories' own rules. They are not new and they are the ones most likely to
be lost in a handoff.

* **Work autonomously.** Do not ask questions that the documents answer. Record every
  judgment call in `DECISIONS.md`, newest at the bottom, with the reasoning.
* **Prove every done item with command output**, in `REPORT.md`. A done item without output
  is not done.
* **A passing response is not proof that an action was blocked.** Every negative claim is
  proven by an independent witness — an egress test shows the connection failing *from
  inside the pod*, not that a policy object exists.
* **Nothing is applied until its diff has been read**, computed by the same function that
  writes the audit record.
* **Absence means everything; deny wins.** From the entitlement table up through the whole
  policy ladder.
* **Idempotency is content-addressing.** A bundle is its hash, a trigger revision is its
  hash, a usage record is the gateway's request id, a workspace image is its bundle's hash.
* **The log is the record; a table is a projection.** Every table added must be rebuildable
  from something durable.
* **No client, including ours, gets a private door.** `mix troupe.boundaries` and the GUI's
  build boundaries both fail on it.

---

## Things neither team may do without coming back

Not open questions — decisions already made, listed because each is a natural-looking
shortcut that would undo an argument.

* **Do not merge WorkerProfile, bundle and grant into one object.** They are split for three
  independent reasons. The console *composes* them; the platform keeps them apart.
* **Do not add a person → profile grant.** A team that links to groups is the answer.
* **Do not widen the presence channel** to carry status, spend, or anything with a `seq`.
* **Do not put an administrative view in the client.** Administration is one link, gated on
  the `admin.overview` probe.
* **Do not put a router between a client and a worker.** It is why the StatefulSet stays.
* **Do not let a personal automation send anything without a person reading it first.**
* **Do not reintroduce `replicas` or `sessions per pod` to the admin surface.** They stay in
  the CR, written by the plane and by the size class.
* **Do not make the console able to read a session's content, or a secret's value.** Not for
  support, not for break-glass, not for an audit.

---

## Open questions — bring these back, do not decide them alone

| question | where |
| --- | --- |
| Write-only secrets through the console to OpenBao — better morning, real security tradeoff | `orchestration-review.md` finding 7 |
| Does a fork copy the parent's blobs, given cross-session dedup is forbidden? | `RELEASE.md` |
| Does an ACP subagent's permission model or the session's answer win? | `RELEASE.md` W5 |
| Whether the LiveView console or the GUI's admin section is canonical | `control-panel.md` |
| Who may set a person's spend cap when they are in several teams | `control-panel.md` |
| What a ceiling does mid-burst: queue the eleventh session or refuse it | `orchestration-review.md` |

Everything else in the open-question lists may be decided by whoever gets there, recorded in
`DECISIONS.md`.

---

## What "done" means for this handoff

`mix troupe.release.check` passes on a clean checkout of both repositories at the same tag:
`mix check`, `mix troupe.schema.diff` against the last tag, `mix troupe.e2e` twice, a
`kubeconform` pass on the chart, the GUI's Playwright suite against the same cluster, and the
generated egress allowlist checked against the chart's policy.

Then: `helm install` of the published chart on a cluster nobody prepared reaches a console
somebody can sign into, following only the install page — and a person following the
single-machine page reaches a first streamed token with no cluster at all.
